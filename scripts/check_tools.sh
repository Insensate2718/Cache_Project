#!/usr/bin/env bash

set -euo pipefail

required_tools=(iverilog vvp gtkwave)
missing=0

for tool in "${required_tools[@]}"; do
    if tool_path="$(command -v "$tool")"; then
        printf '%-10s %s\n' "$tool" "$tool_path"
    else
        printf 'Missing required tool: %s\n' "$tool" >&2
        missing=1
    fi
done

if ((missing != 0)); then
    exit 1
fi

