#!/bin/bash
# Test: `code-evolve setup` is the guided onboarding front door to `init`, and is
# re-runnable — a second `setup` on an already-initialized repo reconfigures
# (auto --force) instead of erroring, and preserves evolution history/state.
# Regression test for issue #26 (P1.7 — unified setup wizard).
#
# Drives the REAL compiled CLI on piped (non-TTY) stdin, so no interactive
# pickers fire. A stub `claude` on PATH satisfies the dependency check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

[ -f "$CLI" ] || ( cd "$ROOT" && npm run build >/dev/null 2>&1 )

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

# Stub agent binary so checkDependencies('claude') passes without a real CLI.
STUB=$(mktemp -d)
cat > "$STUB/claude" <<'EOF'
#!/bin/bash
echo "claude 0.0.0-stub"
EOF
chmod +x "$STUB/claude"
export PATH="$STUB:$PATH"

# ── Case 1: setup on a fresh repo configures it (creates .evolve/) ──
T1=$(mktemp -d)
( cd "$T1" && git init -q )
OUT1=$( cd "$T1" && node "$CLI" setup </dev/null 2>&1 ) || true
check "setup prints the wizard banner"      "$(echo "$OUT1" | grep -c 'code-evolve setup' || true)" "1"
check "setup creates .evolve/"              "$( [ -d "$T1/.evolve" ] && echo yes || echo no )" "yes"
check "setup prints the you're-live outro"  "$(echo "$OUT1" | grep -c "You're live" || true)" "1"
check "setup ran the init flow"             "$(echo "$OUT1" | grep -c 'code-evolve initialized' || true)" "1"

# ── Case 2: re-running setup does NOT error and preserves state ──
# Seed a marker in JOURNAL.md; a re-run must keep it (init preserves state on --force).
echo "DAY 1: hello" >> "$T1/.evolve/JOURNAL.md"
OUT2=$( cd "$T1" && node "$CLI" setup </dev/null 2>&1 ); RC=$?
check "re-run setup exits 0 (re-runnable)"  "$RC" "0"
check "re-run does not hit greenfield guard" "$(echo "$OUT2" | grep -c 'already exists. Use --force' || true)" "0"
check "re-run preserves JOURNAL history"     "$(grep -c 'DAY 1: hello' "$T1/.evolve/JOURNAL.md" || true)" "1"
rm -rf "$T1"

rm -rf "$STUB"
echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
