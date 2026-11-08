#!/bin/bash
# Test (#77): `evolve.sh prepare` does everything up to the agent call (preflight, stack, issues,
# baseline SHA, protected-path snapshot, prompt) and writes .evolve/run/PROMPT.md plus a
# sourceable .evolve/run/session.env, without running the agent. The full cycle is unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
echo "agent called" >> "$stub_dir/agent-calls"
cat >/dev/null
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/gh"
export PATH="$stub_dir:$PATH"

cd "$work_dir"
git init -q
git config user.email test@example.com
git config user.name test
printf '{"name":"demo","scripts":{"build":"true","test":"true"}}\n' > package.json
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed"
git add -A && git commit -qm "baseline"
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }

prepare_status=0
engine prepare > "$stub_dir/prepare.log" 2>&1 || prepare_status=$?
[ "$prepare_status" -eq 0 ] && ok "prepare exits 0" || bad "prepare exited $prepare_status: $(tail -3 "$stub_dir/prepare.log")"
[ ! -e "$stub_dir/agent-calls" ] && ok "prepare does not call the agent" || bad "prepare called the agent"
grep -q "=== PHASE 1: Assess Current State ===" .evolve/run/PROMPT.md 2>/dev/null \
    && ok "prepare writes the cycle prompt to .evolve/run/PROMPT.md" || bad "no prompt in .evolve/run/PROMPT.md"

# session.env is plain KEY=value (the engine never sources it), so read it the same way.
session_value() { sed -n "s/^$1=//p" .evolve/run/session.env 2>/dev/null; }
start_sha=$(session_value SESSION_START_SHA); day=$(session_value DAY); session_time=$(session_value SESSION_TIME)
nonce=$(session_value BOUNDARY_NONCE); stack=$(session_value STACK); build_cmd=$(session_value BUILD_CMD)
test_cmd=$(session_value TEST_CMD); snapshot=$(session_value PROTECTED_SNAPSHOT)
session_values="$start_sha|$day|$stack"
[ "$start_sha" = "$(git rev-parse HEAD)" ] && ok "session.env records the baseline SHA" || bad "SESSION_START_SHA='$start_sha' ($session_values)"
[ "$day" = "0" ] && [ -n "$session_time" ] && [ -n "$nonce" ] && ok "session.env records day, time and nonce" || bad "day/time/nonce: '$day' '$session_time' '$nonce'"
[ "$stack" = "javascript" ] && [ "$build_cmd" = "npm run build" ] && [ "$test_cmd" = "npm run test" ] \
    && ok "session.env records the detected stack commands" || bad "stack '$stack' build '$build_cmd' test '$test_cmd'"
[ -s "$snapshot/manifest" ] && grep -qxF ".evolve/IDENTITY.md" "$snapshot/manifest" \
    && ok "the protected-path snapshot survives the prepare process" || bad "no persisted snapshot at '$snapshot'"
issues_file=$(session_value ISSUES_FILE)
recorded_dirs="$(session_value EVOLVE_DIR)|$(session_value PROJECT_DIR)"
[ -n "$issues_file" ] && [ -r "$issues_file" ] \
    && ok "the issue list in session.env is still readable after prepare exits" || bad "ISSUES_FILE '$issues_file' is not readable"
[ "$recorded_dirs" = ".evolve|." ] && ok "session.env records EVOLVE_DIR and PROJECT_DIR" || bad "recorded dirs: '$recorded_dirs'"
grep -qvE '^[A-Z_]+=' .evolve/run/session.env \
    && bad "session.env has a line that is not KEY=value" || ok "session.env holds only KEY=value lines"
[ -z "$(git status --porcelain -- .evolve/run)" ] && ok ".evolve/run/ is ignored by git" || bad ".evolve/run shows in git status"

# A read-only git directory (some agent sandboxes) fails fast with a clear message.
rm -rf .evolve/run
chmod a-w .git
readonly_status=0; engine prepare > "$stub_dir/readonly.log" 2>&1 || readonly_status=$?
chmod u+w .git
[ "$readonly_status" -ne 0 ] && grep -q "is not writable, and a cycle must write there" "$stub_dir/readonly.log" \
    && ok "a read-only .git is reported clearly instead of as a lock failure" || bad "read-only .git: exit $readonly_status: $(tail -2 "$stub_dir/readonly.log")"

usage_status=0
engine finalise > "$stub_dir/usage.log" 2>&1 || usage_status=$?
[ "$usage_status" -eq 2 ] && grep -q "Usage" "$stub_dir/usage.log" \
    && ok "an unknown phase exits 2 with usage" || bad "unknown phase exited $usage_status"

# A full cycle skips while a prepared session is pending (#78), so clear it first.
rm -rf .evolve/run
cycle_status=0
engine > "$stub_dir/cycle.log" 2>&1 || cycle_status=$?
grep -q "agent called" "$stub_dir/agent-calls" 2>/dev/null && grep -q "Day 0 complete" "$stub_dir/cycle.log" \
    && ok "the default full cycle still runs the agent and completes" || bad "full cycle (exit $cycle_status): $(tail -3 "$stub_dir/cycle.log")"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
