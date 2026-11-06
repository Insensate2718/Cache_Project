#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output_dir="build/parameter_checks"
mkdir -p "$output_dir"

mapfile -t rtl_sources < <(
    find rtl/cache -type f -name '*.v' -print | sort
)

compile_configuration() {
    local output_name="$1"
    shift

    iverilog \
        -g2001 \
        -Wall \
        -Wimplicit \
        -s cache_top \
        -o "${output_dir}/${output_name}.vvp" \
        "$@" \
        "${rtl_sources[@]}"
}

expect_valid() {
    local name="$1"
    shift

    compile_configuration "$name" "$@" \
        > "${output_dir}/${name}_compile.log" 2>&1
    vvp "${output_dir}/${name}.vvp" \
        > "${output_dir}/${name}.log" 2>&1
    printf 'PARAMETER_PASS name=%s expected=valid\n' "$name"
}

expect_invalid() {
    local name="$1"
    local expected_message="$2"
    shift 2

    compile_configuration "$name" "$@" \
        > "${output_dir}/${name}_compile.log" 2>&1
    if vvp "${output_dir}/${name}.vvp" \
        > "${output_dir}/${name}.log" 2>&1; then
        printf 'Invalid configuration unexpectedly passed: %s\n' \
            "$name" >&2
        exit 1
    fi
    if ! grep -q "$expected_message" "${output_dir}/${name}.log"; then
        printf 'Configuration %s failed for the wrong reason\n' \
            "$name" >&2
        cat "${output_dir}/${name}.log" >&2
        exit 1
    fi
    printf 'PARAMETER_PASS name=%s expected=invalid\n' "$name"
}

expect_valid ways1 -Pcache_top.WAYS=1
expect_valid ways2 -Pcache_top.WAYS=2
expect_valid ways4 -Pcache_top.WAYS=4
expect_valid parity_disabled \
    -Pcache_top.WAYS=4 \
    -Pcache_top.TAG_PARITY_ENABLE=0

expect_invalid unsupported_ways \
    'WAYS must be 1, 2, or 4' \
    -Pcache_top.WAYS=3
expect_invalid invalid_parity_enable \
    'TAG_PARITY_ENABLE must be 0 or 1' \
    -Pcache_top.TAG_PARITY_ENABLE=2
expect_invalid wrong_line_size \
    'LINE_BYTES must be 32' \
    -Pcache_top.LINE_BYTES=16
expect_invalid non_power_cache \
    'CACHE_BYTES must be a power of two' \
    -Pcache_top.CACHE_BYTES=12288
expect_invalid undersized_cache \
    'SETS must be a power of two >= 2' \
    -Pcache_top.CACHE_BYTES=128
expect_invalid missing_tag_bits \
    'ADDR_WIDTH leaves no tag bits' \
    -Pcache_top.ADDR_WIDTH=12

printf 'PARAMETER_CHECK_PASS valid=4 invalid=6\n'
