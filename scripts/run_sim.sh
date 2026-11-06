#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

top="${TOP:-tb_smoke}"
test_file="${TEST:-tb/tests/${top}.sv}"
seed="${SEED:-1}"
wave="${WAVE:-build/${top}.vcd}"
output="build/${top}.vvp"
params="${PARAMS:-}"
param_args=()

if [[ -n "$params" ]]; then
    read -r -a param_args <<< "$params"
fi

if [[ ! -f "$test_file" ]]; then
    printf 'Testbench top not found: %s\n' "$test_file" >&2
    printf 'Set TOP and TEST, for example:\n' >&2
    printf '  make sim TOP=tb_smoke TEST=tb/tests/tb_smoke.sv\n' >&2
    exit 2
fi

mapfile -t rtl_sources < <(
    find rtl/cache -type f -name '*.v' -print | sort
)
mapfile -t common_sources < <(
    find tb/common tb/models -type f \
        \( -name '*.v' -o -name '*.sv' \) -print | sort
)

if ((${#rtl_sources[@]} == 0)); then
    printf 'No Verilog RTL sources were found under rtl/cache.\n' >&2
    exit 2
fi

mkdir -p build
mkdir -p "$(dirname "$wave")"

printf 'Compiling top=%s test=%s seed=%s\n' "$top" "$test_file" "$seed"

iverilog \
    -g2012 \
    -Wall \
    -Wimplicit \
    -s "$top" \
    -o "$output" \
    "${param_args[@]}" \
    "${rtl_sources[@]}" \
    "${common_sources[@]}" \
    "$test_file"

vvp "$output" "+SEED=${seed}" "+VCD=${wave}"
