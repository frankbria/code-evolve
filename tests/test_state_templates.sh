#!/bin/bash
# Test (#74): a fresh install starts at Day 0 with an empty journal, auto-captured REQs are
# numbered from 0001 (the template's REQ-NNNN example is not a REQ), and issue counts are a
# single integer even when nothing matches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
ENGINE="$ROOT/templates/scripts/evolve.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

work_dir="$(mktemp -d)"
stub_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir" "$stub_dir"' EXIT
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"; chmod +x "$stub_dir/claude"

(cd "$work_dir" && git init -q && PATH="$stub_dir:$PATH" node "$CLI" init --agent claude </dev/null >/dev/null 2>&1)
check "fresh install starts at Day 0" "$(cat "$work_dir/.evolve/DAY_COUNT")" "0"
check "fresh journal has no entries" "$(grep -c '^## Day' "$work_dir/.evolve/JOURNAL.md" || true)" "0"

eval "$(sed -n '/^next_req_number()/,/^}/p' "$ENGINE")"
check "first REQ in the template ledger is 0001" "$(next_req_number "$ROOT/templates/state/REQUIREMENTS.md")" "0001"
ledger="$work_dir/ledger.md"
cp "$ROOT/templates/state/REQUIREMENTS.md" "$ledger"
printf '\n## REQ-0001: a\n\n## REQ-0004: b\n' >> "$ledger"
check "next REQ is max + 1, not count + 1" "$(next_req_number "$ledger")" "0005"
check "missing ledger starts at 0001" "$(next_req_number "$work_dir/missing.md")" "0001"

eval "$(sed -n '/^count_lines_matching()/,/^}/p' "$ENGINE")"
printf 'no issues here\n' > "$work_dir/issues.md"
check "count of zero matches is a single 0" "$(count_lines_matching '^### Issue' "$work_dir/issues.md")" "0"
check "count of a missing file is 0" "$(count_lines_matching '^### Issue' "$work_dir/missing.md")" "0"
printf '### Issue 1\n### Issue 2\n' > "$work_dir/issues.md"
check "count of two matches is 2" "$(count_lines_matching '^### Issue' "$work_dir/issues.md")" "2"
check "no 'grep -c ... || echo 0' left in the engine" "$(grep -c 'grep -c .*|| echo 0' "$ENGINE" || true)" "0"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
