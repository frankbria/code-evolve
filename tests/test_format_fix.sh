#!/bin/bash
# Test: format_fix_cmd in evolve.sh maps a format *check* command to its
# in-place *fix* equivalent for every stack detect_stack.sh emits (P2.3, #29).
# Extracts the real function from the real script — no copy, no toolchains.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
eval "$(sed -n '/^format_fix_cmd()/,/^}/p' "$ROOT/templates/scripts/evolve.sh")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

# check command → fix command
check "rust"       "$(format_fix_cmd 'cargo fmt -- --check')"        "cargo fmt"
check "deno"       "$(format_fix_cmd 'deno fmt --check')"            "deno fmt"
check "ruff (uv)"  "$(format_fix_cmd 'uv run ruff format --check .')" "uv run ruff format ."
check "ruff (pip)" "$(format_fix_cmd 'ruff format --check .')"        "ruff format ."
check "go (-l→-w)" "$(format_fix_cmd 'gofmt -l .')"                   "gofmt -w ."
check "dotnet"     "$(format_fix_cmd 'dotnet format --verify-no-changes')" "dotnet format"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
