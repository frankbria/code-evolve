#!/bin/bash
# Test (#91): AGENT=custom runs any headless CLI from a command template in config.json. The prompt
# arrives on stdin or as {prompt_file}; {model} is substituted shell-quoted; a non-zero exit fails the
# session; agentErrorPattern catches CLIs that exit 0 on errors.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
ADAPTER="$ROOT/templates/scripts/agents/custom.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"; mkdir -p "$stub_dir"
# fakeagent [--file F] [--model M]: records how it got the prompt; FAKE_EXIT / FAKE_SAY control the result.
cat > "$stub_dir/fakeagent" <<STUB
#!/bin/bash
model=""; file=""
while [ \$# -gt 0 ]; do case "\$1" in --model) model="\$2"; shift 2 ;; --file) file="\$2"; shift 2 ;; *) shift ;; esac; done
if [ -n "\$file" ]; then prompt="\$(cat "\$file")"; via=file; else prompt="\$(cat)"; via=stdin; fi
printf 'via=%s model=%s prompt=%s\n' "\$via" "\$model" "\$(printf '%s' "\$prompt" | head -c 40 | tr '\n' ' ')" >> "$work/calls"
[ -n "\${FAKE_SAY:-}" ] && echo "\$FAKE_SAY"
exit "\${FAKE_EXIT:-0}"
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
printf '#!/bin/bash\necho "$*" >> "%s/crontab.calls"\n[ "${1:-}" = "-l" ] && { echo "no crontab for $USER" >&2; exit 1; }\ncat > /dev/null\n' "$work" > "$stub_dir/crontab"
chmod +x "$stub_dir"/*
export PATH="$stub_dir:$PATH"
prompt="$work/prompt.txt"; echo "build the thing" > "$prompt"

# adapter <command> <model>: run the adapter as the engine does; prints its exit status.
adapter() { ( AGENT_COMMAND="$1"; source "$ADAPTER"; run_agent "$prompt" "$2" "" "" >/dev/null ) && echo 0 || echo $?; }

rm -f "$work/calls"
check "a stdin command runs" "$(adapter 'fakeagent --model {model}' 'my-model')" "0"
check "the prompt arrives on stdin, with the model substituted" "$(cat "$work/calls")" "via=stdin model=my-model prompt=build the thing"
rm -f "$work/calls"
adapter 'fakeagent --file {prompt_file}' '' >/dev/null
check "{prompt_file} delivers the prompt as a file" "$(cat "$work/calls")" "via=file model= prompt=build the thing"
rm -f "$work/calls"
for hostile in "x; touch $work/pwned" "&touch $work/pwned" "\$(touch $work/pwned)" "\`touch $work/pwned\`" "a\\&b; touch $work/pwned"; do
    rm -f "$work/pwned" "$work/calls"
    adapter 'fakeagent --model {model}' "$hostile" >/dev/null
    check "a hostile model value cannot inject a command: $hostile" "$([ -e "$work/pwned" ] && echo injected || echo safe)" "safe"
    check "and reaches the agent unchanged: $hostile" "$(sed -n 's/^via=stdin model=\(.*\) prompt=.*/\1/p' "$work/calls")" "$hostile"
done
rm -f "$work/pwned"
adapter 'fakeagent --file {prompt_file}' '' >/dev/null
check "a non-zero exit is the adapter's exit" "$(FAKE_EXIT=7 adapter 'fakeagent' '')" "7"
log="$work/log"; echo "Error: QUOTA EXCEEDED" > "$log"
check "the error pattern flags a matching log" "$( (AGENT_ERROR_PATTERN='QUOTA (EXCEEDED|LIMIT)'; source "$ADAPTER"; agent_detect_error "$log") && echo flagged || echo clean)" "flagged"
check "no pattern, no log-based flag" "$( (source "$ADAPTER"; agent_detect_error "$log") && echo flagged || echo clean)" "clean"
check "check_agent needs the command's binary on PATH" "$( (AGENT_COMMAND='no-such-cli -p'; source "$ADAPTER"; check_agent) && echo found || echo missing)" "missing"

# CLI: init validates the command, run drives the engine with it.
project="$work/project"; mkdir -p "$project"; cd "$project"
git init -q; git config user.email t@example.com; git config user.name t
printf '{"name":"demo","scripts":{"test":"true"}}\n' > package.json
status=0; node "$CLI" init --yes --agent custom </dev/null > "$work/init-none.log" 2>&1 || status=$?
check "init --agent custom without a command exits 1" "$status" "1"
status=0; node "$CLI" init --yes --agent custom --agent-command 'no-such-cli -p' </dev/null > "$work/init-missing.log" 2>&1 || status=$?
check "init with a command whose binary is missing fails the dependency check" "$status" "3"
node "$CLI" init --yes --agent custom --agent-command 'fakeagent --model {model}' --agent-error-pattern 'QUOTA EXCEEDED' </dev/null >/dev/null 2>&1
check "init saves the command and pattern" "$(node -p "const c=require('./.evolve/config.json');c.agent+'|'+c.agentCommand+'|'+c.agentErrorPattern")" "custom|fakeagent --model {model}|QUOTA EXCEEDED"
git add -A && git commit -qm "custom install"

rm -f "$work/calls"
node "$CLI" run --timeout 60 </dev/null > "$work/run.log" 2>&1 || true
check "code-evolve run reaches the custom agent with the session prompt" "$(head -1 "$work/calls" | cut -c1-21)" "via=stdin model= prom"
git checkout -q -- . 2>/dev/null; git clean -qfd -e .evolve/run 2>/dev/null || true

status=0; FAKE_SAY="Error: QUOTA EXCEEDED" node "$CLI" run --timeout 60 </dev/null > "$work/quota.log" 2>&1 || status=$?
check "a matching error line fails the cycle even though the CLI exits 0" "$(grep -c 'Agent error detected' "$work/quota.log")" "1"

status=0; node "$CLI" start --every 6 </dev/null > "$work/start.log" 2>&1 || status=$?
check "start schedules a custom agent" "$status" "0"
check "the cron .env carries the command" "$(grep -c "AGENT_COMMAND='fakeagent --model {model}'" .evolve/.env)" "1"

rm -f "$work/calls"
node "$CLI" start --every 6 --run-now </dev/null > "$work/runnow.log" 2>&1 || true
check "start --run-now runs the custom agent" "$([ -s "$work/calls" ] && echo called || echo "not called")" "called"

# A fresh `init --mode local` schedules with this run's command (the config is written after scheduling).
fresh="$work/fresh"; mkdir -p "$fresh"; cd "$fresh"; git init -q
printf '{"name":"demo","scripts":{"test":"true"}}\n' > package.json
node "$CLI" init --yes --agent custom --agent-command 'fakeagent -p' --mode local --every 6 </dev/null > "$work/init-local.log" 2>&1
check "init --mode local writes the custom command into the cron .env" "$(grep -c "AGENT_COMMAND='fakeagent -p'" .evolve/.env 2>/dev/null || echo 0)" "1"

# Validation uses the same grep the adapter runs (GNU grep, ugrep, BSD grep differ), so an
# unbalanced group, invalid in every grep -E, is the portable case to test.
status=0; node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-error-pattern 'quota(' </dev/null > "$work/init-regex.log" 2>&1 || status=$?
check "a pattern this system's grep -E rejects is rejected at init" "$status" "1"
check "and the message names grep -E" "$(grep -c 'not a valid grep -E pattern' "$work/init-regex.log")" "1"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
