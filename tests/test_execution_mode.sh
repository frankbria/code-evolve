#!/bin/bash
# Test: `code-evolve init --mode <local|ci|both>` persists the execution mode to
# config.json and `code-evolve status` reports it. Also checks --mode drives the
# right artifacts (CI workflows for ci/both) and rejects an invalid mode.
# Regression test for issue #24 (P1.5).
#
# Drives the REAL compiled CLI, non-TTY (piped stdin) so no interactive prompt
# fires. A stub `claude` on PATH satisfies the dependency check. No env key is
# set, so the local cron job is deferred (not installed) — keeping the test
# hermetic (it never touches the user's crontab).
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
# Ensure no API key leaks in from the environment, so local mode defers cron.
unset ANTHROPIC_API_KEY OPENAI_API_KEY

run_init() {  # $1 = mode
  local dir; dir=$(mktemp -d)
  ( cd "$dir" && git init -q && node "$CLI" init --mode "$1" </dev/null >/dev/null 2>&1 )
  echo "$dir"
}

# ── ci mode: persisted + workflows installed ──
D=$(run_init ci)
check "ci: mode persisted to config" "$(node -e "console.log(require('$D/.evolve/config.json').mode)")" "ci"
check "ci: status reports mode"      "$(cd "$D" && node "$CLI" status 2>/dev/null | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d).mode))')" "ci"
check "ci: evolve workflow installed" "$([ -f "$D/.github/workflows/evolve.yml" ] && echo yes || echo no)" "yes"
rm -rf "$D"

# ── local mode: persisted; cron deferred (no key) so no workflows ──
D=$(run_init local)
check "local: mode persisted"        "$(node -e "console.log(require('$D/.evolve/config.json').mode)")" "local"
check "local: no CI workflow"        "$([ -f "$D/.github/workflows/evolve.yml" ] && echo yes || echo no)" "no"
check "local: cron deferred warning has no schedule.json" "$([ -f "$D/.evolve/schedule.json" ] && echo yes || echo no)" "no"
rm -rf "$D"

# ── both mode: persisted + workflows installed ──
D=$(run_init both)
check "both: mode persisted"         "$(node -e "console.log(require('$D/.evolve/config.json').mode)")" "both"
check "both: evolve workflow installed" "$([ -f "$D/.github/workflows/evolve.yml" ] && echo yes || echo no)" "yes"
rm -rf "$D"

# ── invalid mode: exits non-zero with a clear message ──
D=$(mktemp -d)
OUT=$( cd "$D" && git init -q && node "$CLI" init --mode bogus </dev/null 2>&1 ) && rc=0 || rc=$?
check "invalid mode exits non-zero"  "$([ "${rc:-0}" -ne 0 ] && echo yes || echo no)" "yes"
check "invalid mode explains"        "$(echo "$OUT" | grep -c 'Unknown mode')" "1"
rm -rf "$D"

# ── back-compat: --with-ci still installs workflows and persists mode=ci ──
D=$(mktemp -d)
( cd "$D" && git init -q && node "$CLI" init --with-ci </dev/null >/dev/null 2>&1 )
check "--with-ci installs workflow"  "$([ -f "$D/.github/workflows/evolve.yml" ] && echo yes || echo no)" "yes"
check "--with-ci persists mode=ci"   "$(node -e "console.log(require('$D/.evolve/config.json').mode)")" "ci"
rm -rf "$D"

rm -rf "$STUB"
echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
