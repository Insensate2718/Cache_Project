#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

read -r -a seeds <<< "${SEEDS:-1 17 20260802}"

report_dir="${REPORT_DIR:-reports/regression}"
log_dir="${report_dir}/logs"
wave_dir="build/regression"
summary_csv="${report_dir}/summary.csv"
summary_jsonl="${report_dir}/summary.jsonl"
git_commit="$(git rev-parse --verify HEAD)"
git_dirty="false"
iverilog_version="$(iverilog -V 2>/dev/null | head -n 1)"
iverilog_version="${iverilog_version//,/;}"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    git_dirty="true"
fi

mkdir -p "$log_dir" "$wave_dir"
printf '%s\n' \
    'schema_version,git_commit,git_dirty,iverilog_version,test,configuration,addr_width,cache_bytes,line_bytes,ways,tag_parity_enable,seed,status,log_path,vcd_path' \
    > "$summary_csv"
: > "$summary_jsonl"

case_count=0
pass_count=0
fail_count=0

record_result() {
    local test_name="$1"
    local configuration="$2"
    local addr_width="$3"
    local cache_bytes="$4"
    local line_bytes="$5"
    local ways="$6"
    local tag_parity="$7"
    local seed="$8"
    local status="$9"
    local log_path="${10}"
    local vcd_path="${11}"
    local addr_width_json="null"
    local cache_bytes_json="null"
    local line_bytes_json="null"
    local ways_json="null"
    local parity_json="null"

    if [[ "$addr_width" != "NA" ]]; then
        addr_width_json="$addr_width"
    fi
    if [[ "$cache_bytes" != "NA" ]]; then
        cache_bytes_json="$cache_bytes"
    fi
    if [[ "$line_bytes" != "NA" ]]; then
        line_bytes_json="$line_bytes"
    fi
    if [[ "$ways" != "NA" ]]; then
        ways_json="$ways"
    fi
    if [[ "$tag_parity" != "NA" ]]; then
        parity_json="$tag_parity"
    fi

    printf '2,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$git_commit" "$git_dirty" "$iverilog_version" \
        "$test_name" "$configuration" "$addr_width" "$cache_bytes" \
        "$line_bytes" "$ways" "$tag_parity" "$seed" "$status" \
        "$log_path" "$vcd_path" >> "$summary_csv"
    printf '{"schema_version":2,"git_commit":"%s",' \
        "$git_commit" >> "$summary_jsonl"
    printf '"git_dirty":%s,"iverilog_version":"%s",' \
        "$git_dirty" "$iverilog_version" >> "$summary_jsonl"
    printf '"test":"%s","configuration":"%s",' \
        "$test_name" "$configuration" >> "$summary_jsonl"
    printf '"addr_width":%s,"cache_bytes":%s,"line_bytes":%s,' \
        "$addr_width_json" "$cache_bytes_json" "$line_bytes_json" \
        >> "$summary_jsonl"
    printf '"ways":%s,' "$ways_json" >> "$summary_jsonl"
    printf '"tag_parity_enable":%s,"seed":%s,"status":"%s",' \
        "$parity_json" "$seed" "$status" >> "$summary_jsonl"
    printf '"log_path":"%s","vcd_path":"%s"}\n' \
        "$log_path" "$vcd_path" >> "$summary_jsonl"
}

run_case() {
    local test_name="$1"
    local ways="$2"
    local tag_parity="$3"
    local seed="$4"
    local params="$5"
    local configuration="${6:-unit}"
    local addr_width="${7:-NA}"
    local cache_bytes="${8:-NA}"
    local line_bytes="${9:-NA}"
    local case_name="${test_name}_seed${seed}"
    local status="FAIL"
    local simulator_status=0
    local log_path
    local vcd_path

    if [[ "$ways" != "NA" ]]; then
        case_name="${test_name}_ways${ways}_parity${tag_parity}_seed${seed}"
    fi
    if [[ "$configuration" != "unit" && "$configuration" != "small" ]]; then
        case_name="${case_name}_${configuration}"
    fi

    log_path="${log_dir}/${case_name}.log"
    vcd_path="${wave_dir}/${case_name}.vcd"

    printf 'REGRESSION_CASE test=%s ways=%s parity=%s seed=%s\n' \
        "$test_name" "$ways" "$tag_parity" "$seed"

    if TOP="$test_name" \
        TEST="tb/tests/${test_name}.sv" \
        SEED="$seed" \
        WAVE="$vcd_path" \
        PARAMS="$params" \
        ./scripts/run_sim.sh > "$log_path" 2>&1; then
        simulator_status=0
    else
        simulator_status=$?
    fi

    cat "$log_path"

    if ((simulator_status == 0)) && grep -q '^TEST_PASS' "$log_path"; then
        status="PASS"
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
    case_count=$((case_count + 1))

    record_result \
        "$test_name" "$configuration" "$addr_width" "$cache_bytes" \
        "$line_bytes" "$ways" "$tag_parity" "$seed" "$status" \
        "$log_path" "$vcd_path"
}

focused_tops=(
    tb_backing_memory_model
    tb_cache_controller
    tb_comparator
    tb_data_array
    tb_replacement_unit
    tb_scoreboard
    tb_tag_array
    tb_writeback_buffer
)

for top in "${focused_tops[@]}"; do
    for seed in "${seeds[@]}"; do
        run_case "$top" "NA" "NA" "$seed" "" "unit"
    done
done

for ways in 1 2 4; do
    for seed in "${seeds[@]}"; do
        run_case \
            tb_smoke "$ways" 1 "$seed" \
            "-Ptb_smoke.WAYS=${ways}" \
            "small" 16 "$((4 * ways * 32))" 32
    done
done

for seed in "${seeds[@]}"; do
    run_case \
        tb_smoke 4 0 "$seed" \
        "-Ptb_smoke.WAYS=4 -Ptb_smoke.TAG_PARITY_ENABLE=0" \
        "small" 16 512 32
done

for ways in 1 2 4; do
    for seed in "${seeds[@]}"; do
        run_case \
            tb_smoke "$ways" 1 "$seed" \
            "-Ptb_smoke.WAYS=${ways} -Ptb_smoke.CACHE_BYTES=16384 -Ptb_smoke.MEMORY_LINES=1024" \
            "cache16k" 16 16384 32
    done
done

for seed in "${seeds[@]}"; do
    run_case \
        tb_smoke 4 0 "$seed" \
        "-Ptb_smoke.WAYS=4 -Ptb_smoke.TAG_PARITY_ENABLE=0 -Ptb_smoke.CACHE_BYTES=16384 -Ptb_smoke.MEMORY_LINES=1024" \
        "cache16k" 16 16384 32
done

printf 'REGRESSION_SUMMARY cases=%d pass=%d fail=%d csv=%s jsonl=%s\n' \
    "$case_count" "$pass_count" "$fail_count" \
    "$summary_csv" "$summary_jsonl"

if ((fail_count != 0)); then
    exit 1
fi

printf 'REGRESSION_PASS seeds=%s geometries=small,16KiB parity_on_ways=1,2,4 parity_off_ways=4\n' \
    "${seeds[*]}"
