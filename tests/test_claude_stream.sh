#!/bin/bash
# Test (#90): a headless cycle reads Claude's stream-json events. An API-error result reported with
# exit code 0 marks the session failed; a successful result lets the cycle commit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"; mkdir -p "$stub_dir"
# claude stub: records its flags; makes a change, then streams events for STUB_OUTCOME (success|api-error).
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
echo "\$*" >> "$work/claude.args"
cat > /dev/null
echo "agent work" >> notes.txt
echo '{"type":"system","subtype":"init","model":"stub"}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Added a note."},{"type":"tool_use","name":"Write","input":{"file_path":"notes.txt"}}]}}'
if [ "\${STUB_OUTCOME:-success}" = api-error ]; then
    echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":529,"result":"API Error: 529 Overloaded"}'
else
    echo '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"result":"Added a note."}'
fi
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir"/*
export PATH="$stub_dir:$PATH"

project="$work/project"; mkdir -p "$project"; cd "$project"
git init -q; git config user.email t@example.com; git config user.name t
printf '{"name":"demo","scripts":{"test":"true"}}\n' > package.json
node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
git add -A && git commit -qm "baseline"
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }

commits_before="$(git rev-list --count HEAD)"
status=0; STUB_OUTCOME=api-error engine > "$work/error.log" 2>&1 || status=$?
check "an API error reported with exit 0 fails the cycle" "$status" "1"
check "the engine says it detected the agent error" "$(grep -c 'Agent error detected' "$work/error.log")" "1"
check "the error reason reaches the cycle log" "$(grep -c '529 Overloaded' "$work/error.log")" "1"
check "a failed session commits nothing" "$(git rev-list --count HEAD)" "$commits_before"
check "claude is asked for stream-json with explicit permissions" \
    "$(grep -c -- '--output-format stream-json --verbose --permission-mode dontAsk' "$work/claude.args")" "1"
git checkout -q -- . && git clean -qfd -e .evolve/run

status=0; STUB_OUTCOME=success engine > "$work/success.log" 2>&1 || status=$?
check "a successful session completes the cycle" "$status" "0"
check "the readable log shows the agent's text and tool calls" \
    "$(grep -q 'Added a note.' "$work/success.log" && grep -q -- '-> Write notes.txt' "$work/success.log" && echo yes || echo no)" "yes"
check "the successful session is committed" "$([ "$(git rev-list --count HEAD)" -gt "$commits_before" ] && echo yes || echo no)" "yes"
check "the session's change is in the history" "$(git log --oneline -- notes.txt | wc -l | tr -d ' ')" "1"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
