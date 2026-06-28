#!/bin/bash
# Test: `code-evolve init` offers the vision + spec interviews on a TTY, but on
# piped (non-TTY) stdin it stays silent and keeps the manual "edit these files"
# guidance — so CI / scripted installs are unaffected.
# Regression test for issue #22 (P1.3).
#
# Drives the REAL compiled CLI. A stub `claude` on PATH satisfies the dependency
# check; no API key or real agent is needed.
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

# ── Case 1: non-TTY init does NOT offer interviews, keeps manual guidance ──
T1=$(mktemp -d)
( cd "$T1" && git init -q )
OUT1=$( cd "$T1" && node "$CLI" init </dev/null 2>&1 ) || true
check "non-TTY keeps manual vision guidance" "$(echo "$OUT1" | grep -c 'Edit .evolve/vision.md' || true)" "1"
check "non-TTY does not offer interview"      "$(echo "$OUT1" | grep -ci 'guided interview' || true)" "0"
rm -rf "$T1"

# ── Case 2 (pty): on a TTY, init offers the interviews; declining keeps guidance ──
# A Python helper drives the real pty, answering the agent/auth pickers then
# declining the interview offer. python3 is already a hard dependency.
T2=$(mktemp -d)
( cd "$T2" && git init -q )
OUT2=$( cd "$T2" && timeout 20 python3 "$ROOT/tests/_drive_init_pty.py" "$CLI" decline 2>&1 ) || true
check "TTY offers the interview"        "$(echo "$OUT2" | grep -ci 'guided interview' || true)" "1"
check "declining keeps manual guidance" "$(echo "$OUT2" | grep -c 'Edit .evolve/vision.md' || true)" "1"
rm -rf "$T2"

# ── Case 3 (pty): accept the offer but cancel the interviews -> guidance stays ──
# Accepting and then bailing out of each interview must NOT suppress the manual
# "edit these files" steps (the files are still empty templates). Regression
# guard for the per-file completion check.
T3=$(mktemp -d)
( cd "$T3" && git init -q )
OUT3=$( cd "$T3" && timeout 20 python3 "$ROOT/tests/_drive_init_pty.py" "$CLI" cancel 2>&1 ) || true
check "cancelled vision keeps its edit step" "$(echo "$OUT3" | grep -c 'Edit .evolve/vision.md' || true)" "1"
check "cancelled spec keeps its edit step"   "$(echo "$OUT3" | grep -c 'Edit .evolve/spec.md' || true)" "1"
rm -rf "$T3"

# ── Case 4 (pty): EOF (Ctrl-D) at the offer prompt follows the declined path ──
# Pressing Ctrl-D must not hang init — it defaults to "no" and still prints guidance.
T4=$(mktemp -d)
( cd "$T4" && git init -q )
OUT4=$( cd "$T4" && timeout 20 python3 "$ROOT/tests/_drive_init_pty.py" "$CLI" eof 2>&1 ) || true
check "EOF at offer still prints Next steps" "$(echo "$OUT4" | grep -c 'Next steps' || true)" "1"
rm -rf "$T4"

rm -rf "$STUB"
echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
