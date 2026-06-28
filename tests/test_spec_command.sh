#!/bin/bash
# Test: `code-evolve spec` runs an interview and writes a populated .evolve/spec.md,
# and `code-evolve spec --refine` reloads, edits, and preserves checkbox state.
# Regression test for issue #21 (P1.2).
#
# Drives the REAL compiled CLI over piped (non-TTY) stdin — no API key or agent needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

# Build if the CLI isn't compiled yet.
[ -f "$CLI" ] || ( cd "$ROOT" && npm run build >/dev/null 2>&1 )

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

# ── Case 1: fresh interview writes a populated spec with checkbox features ──
T1=$(mktemp -d)
( cd "$T1"
  printf '%s\n' \
    "TypeScript Node.js Commander SQLite Jest" \
    "A CLI tool using command pattern" \
    "Add task command" "List all tasks command" "Mark a task done command" "" \
    "Tasks stored as markdown files locally" \
    "CLI subcommands add list and done" \
    "Jest unit tests with coverage target" \
    "Published to the npm registry package" \
    "yes" "yes" | node "$CLI" spec >/dev/null 2>&1
) || echo CRASH > "$T1/crash"
check "fresh run does not crash" "$( [ -f "$T1/crash" ] && echo CRASH || echo OK )" "OK"
check "fresh run writes spec.md" "$( [ -f "$T1/.evolve/spec.md" ] && echo YES || echo NO )" "YES"
check "tech stack captured" "$(grep -c 'TypeScript Node.js Commander' "$T1/.evolve/spec.md" || true)" "1"
check "features rendered as checkboxes" "$(grep -c '^- \[ \] Add task command' "$T1/.evolve/spec.md" || true)" "1"

# ── Case 2: --refine reloads, edits one field, preserves checkbox state ──
sed -i 's/- \[ \] Add task command/- [x] Add task command/' "$T1/.evolve/spec.md"
( cd "$T1"
  # change tech stack; blank = keep for every other prompt (incl. "keep features")
  printf '%s\n' "Rust with Cargo and Clap framework" "" "" "" "" "" "" "yes" "yes" \
    | node "$CLI" spec --refine >/dev/null 2>&1
) || echo CRASH > "$T1/crash2"
check "refine does not crash" "$( [ -f "$T1/crash2" ] && echo CRASH || echo OK )" "OK"
check "refine applied the edit" "$(grep -c 'Rust with Cargo and Clap' "$T1/.evolve/spec.md" || true)" "1"
check "refine preserved [x] checkbox" "$(grep -c '^- \[x\] Add task command' "$T1/.evolve/spec.md" || true)" "1"
check "refine kept untouched field" "$(grep -c 'A CLI tool using command pattern' "$T1/.evolve/spec.md" || true)" "1"
rm -rf "$T1"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
