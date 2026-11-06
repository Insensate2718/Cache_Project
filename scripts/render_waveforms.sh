#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

vcd_file="${1:-build/regression/tb_smoke_ways4_parity1_seed1_cache16k.vcd}"
output_dir="docs/images"
temporary_dir="build/waveform_render"
tcl_script="scripts/render_waveforms.tcl"

for required_tool in xvfb-run gtkwave ps2pdf pdftoppm; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        printf 'Required waveform-rendering tool not found: %s\n' \
            "$required_tool" >&2
        exit 2
    fi
done

if [[ ! -f "$vcd_file" ]]; then
    printf 'Waveform not found: %s\n' "$vcd_file" >&2
    printf 'Run make regression before rendering documentation figures.\n' >&2
    exit 2
fi

mkdir -p "$output_dir" "$temporary_dir"

render_profile() {
    local profile="$1"
    local range_start="$2"
    local range_end="$3"
    local base_name="$4"
    local ps_file="${temporary_dir}/${base_name}.ps"
    local pdf_file="${temporary_dir}/${base_name}.pdf"

    WAVE_PROFILE="$profile" \
    WAVE_RANGE_START="$range_start" \
    WAVE_RANGE_END="$range_end" \
    WAVE_PS_OUTPUT="$ps_file" \
        xvfb-run -a gtkwave -f "$vcd_file" -S "$tcl_script"

    if [[ ! -s "$ps_file" ]]; then
        printf 'GTKWave did not produce %s\n' "$ps_file" >&2
        exit 1
    fi

    ps2pdf "$ps_file" "$pdf_file"
    pdftoppm \
        -png \
        -singlefile \
        -r 160 \
        "$pdf_file" \
        "${output_dir}/${base_name}"
}

render_profile cold_miss 90000 340000 cache_cold_miss
render_profile tag_parity 450000 930000 cache_tag_parity_faults

printf 'WAVEFORM_RENDER_PASS source=%s outputs=%s\n' \
    "$vcd_file" "$output_dir"
