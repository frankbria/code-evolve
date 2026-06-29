#!/bin/bash
# Test: `code-evolve init --every <hours>` applies the chosen cadence to BOTH
# the installed CI workflow (templated cron) and the local cron entry
# (schedule.json). Also checks an invalid interval is rejected.
# Regression test for issue #25 (P1.6).
#
# Drives the REAL compiled CLI, non-TTY (piped stdin) so no prompt fires. Stubs
# `claude` (satisfies the dependency check) and `crontab` (so the local install
# never touches the user's real crontab — keeping the test hermetic).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

[ -f "$CLI" ] || ( cd "$ROOT" && npm run build >/dev/null 2>&1 )

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

STUB=$(mktemp -d)
cat > "$STUB/claude" <<'EOF'
#!/bin/bash
echo "claude 0.0.0-stub"
EOF
# No-op crontab stub: `crontab -l` prints nothing (treated as empty), `crontab -`
# swallows stdin. Never mutates the real user crontab.
cat > "$STUB/crontab" <<'EOF'
#!/bin/bash
cat >/dev/null 2>&1 || true
exit 0
EOF
chmod +x "$STUB/claude" "$STUB/crontab"
export PATH="$STUB:$PATH"

# ── CI: --every templates the cron line in the installed evolve.yml ──
unset ANTHROPIC_API_KEY OPENAI_API_KEY
D=$(mktemp -d)
( cd "$D" && git init -q && node "$CLI" init --mode ci --every 6 </dev/null >/dev/null 2>&1 )
check "ci: cron templated to every 6h" "$(grep -c "cron: '0 \*/6 \* \* \*'" "$D/.github/workflows/evolve.yml")" "1"
check "ci: default 4h cron gone"        "$(grep -c "0 \*/4 \* \* \*" "$D/.github/workflows/evolve.yml")" "0"
rm -rf "$D"

D=$(mktemp -d)
( cd "$D" && git init -q && node "$CLI" init --mode ci --every 1 </dev/null >/dev/null 2>&1 )
check "ci: hourly cron for --every 1"   "$(grep -c "cron: '0 \* \* \* \*'" "$D/.github/workflows/evolve.yml")" "1"
rm -rf "$D"

# ── Local: --every reaches the cron entry (schedule.json every == chosen) ──
export ANTHROPIC_API_KEY="sk-test-stub"
D=$(mktemp -d)
( cd "$D" && git init -q && node "$CLI" init --mode local --every 6 </dev/null >/dev/null 2>&1 )
check "local: schedule.json every=6"    "$(node -e "console.log(require('$D/.evolve/schedule.json').every)")" "6"
rm -rf "$D"
unset ANTHROPIC_API_KEY

# ── Invalid intervals are rejected (out-of-range and non-integer) ──
for bad in 0 25 1.5 6abc; do
  D=$(mktemp -d)
  OUT=$( cd "$D" && git init -q && node "$CLI" init --mode ci --every "$bad" </dev/null 2>&1 ) && rc=0 || rc=$?
  check "invalid --every '$bad' exits non-zero" "$([ "${rc:-0}" -ne 0 ] && echo yes || echo no)" "yes"
  rm -rf "$D"
done

rm -rf "$STUB"
echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
