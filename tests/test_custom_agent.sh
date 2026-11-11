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
printf '%s' "\${CUSTOM_TOKEN:-<unset>}" > "$work/token-seen"
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
for template in "fakeagent --model '{model}' --file '{prompt_file}'" 'fakeagent --model "{model}" --file "{prompt_file}"'; do
    rm -f "$work/calls"
    adapter "$template" 'quoted model' >/dev/null
    check "a quoted placeholder still gets the real value: $template" "$(cat "$work/calls")" "via=file model=quoted model prompt=build the thing"
done
adapter 'fakeagent --file {prompt_file}' '' >/dev/null
check "a non-zero exit is the adapter's exit" "$(FAKE_EXIT=7 adapter 'fakeagent' '')" "7"
log="$work/log"; echo "Error: QUOTA EXCEEDED" > "$log"
check "the error pattern flags a matching log" "$( (AGENT_ERROR_PATTERN='QUOTA (EXCEEDED|LIMIT)'; source "$ADAPTER"; agent_detect_error "$log") && echo flagged || echo clean)" "flagged"
check "no pattern, no log-based flag" "$( (source "$ADAPTER"; agent_detect_error "$log") && echo flagged || echo clean)" "clean"
check "check_agent finds the binary of a command with leading or tab-separated whitespace" "$( (AGENT_COMMAND=$'  fakeagent\t--model {model}'; source "$ADAPTER"; check_agent) && echo found || echo missing)" "found"
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

node -e "const f='.evolve/config.json';const c=require('./'+f);delete c.agentCommand;require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
status=0; node "$CLI" run --timeout 60 </dev/null > "$work/run-nocmd.log" 2>&1 || status=$?
check "run with no configured command exits 3 with a config message" "$status:$(grep -c 'needs agentCommand' "$work/run-nocmd.log")" "3:1"
status=0; node "$CLI" start --every 6 </dev/null > "$work/start-nocmd.log" 2>&1 || status=$?
check "start with no configured command refuses to schedule" "$status" "3"
git checkout -q -- .evolve/config.json

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

# Credentials a custom CLI needs reach the cron .env through --agent-env.
CUSTOM_TOKEN='s3cret$value' node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-env 'CUSTOM_TOKEN, ' </dev/null > "$work/init-env.log" 2>&1
check "init saves the credential names" "$(node -p "JSON.stringify(require('./.evolve/config.json').agentEnvVars)")" '["CUSTOM_TOKEN"]'
check "the credential's value reaches the cron .env, quoted" "$(grep -c "export CUSTOM_TOKEN='s3cret\$value'" .evolve/.env)" "1"
status=0; node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-env 'BAD-NAME' </dev/null > "$work/init-badenv.log" 2>&1 || status=$?
check "an invalid variable name is rejected" "$status" "1"
CUSTOM_TOKEN='s3cret$value' node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-env '' </dev/null > "$work/init-emptyenv.log" 2>&1
check "an empty --agent-env keeps the saved credential names" "$(node -p "JSON.stringify(require('./.evolve/config.json').agentEnvVars)")" '["CUSTOM_TOKEN"]'
status=0; node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-env 'MODEL' </dev/null > "$work/init-reserved.log" 2>&1 || status=$?
check "a name the engine sets itself (MODEL) is rejected" "$status" "1"

# A credential this shell does not set keeps the value the cron .env already holds (#130).
unset CUSTOM_TOKEN OTHER_TOKEN
saved_token() { ( . ./.evolve/.env; printf '%s' "${CUSTOM_TOKEN-<absent>}" ); }
node "$CLI" start --every 6 </dev/null > "$work/start-unset.log" 2>&1
check "start without the credential set keeps the saved value" "$(saved_token)" 's3cret$value'
check "and warns that it kept it" "$(grep -c 'CUSTOM_TOKEN is not set in this shell; keeping the value saved in .evolve/.env' "$work/start-unset.log")" "1"
check "the warning does not print the value" "$(grep -c 's3cret' "$work/start-unset.log")" "0"
CUSTOM_TOKEN='rotated' node "$CLI" start --every 6 </dev/null > "$work/start-rotated.log" 2>&1
check "a value set in the shell replaces the saved one" "$(saved_token)" 'rotated'
check "with no warning" "$(grep -c 'not set in this shell' "$work/start-rotated.log")" "0"
tricky_token="it's "'"quoted" $HOME `id`'"
second line with '\\'' in it"
CUSTOM_TOKEN="$tricky_token" node "$CLI" start --every 6 </dev/null >/dev/null 2>&1
node "$CLI" start --every 6 </dev/null >/dev/null 2>&1
check "a saved value with quotes and a newline is kept exactly" "$(saved_token)" "$tricky_token"
CUSTOM_TOKEN='' node "$CLI" start --every 6 </dev/null > "$work/start-empty.log" 2>&1
check "a credential set to the empty string clears the saved value" "$(saved_token):$(grep -c 'not set in this shell' "$work/start-empty.log")" '<absent>:0'
CUSTOM_TOKEN='kept' node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-env 'CUSTOM_TOKEN,OTHER_TOKEN' </dev/null > "$work/init-two.log" 2>&1
check "init names a credential with no value anywhere" "$(grep -c "OTHER_TOKEN is not set in this shell and no value is saved in .evolve/.env; scheduled cycles won't get it" "$work/init-two.log")" "1"
node "$CLI" init --yes --agent custom --agent-command 'fakeagent --flag' </dev/null > "$work/init-unset.log" 2>&1
check "init re-installing the schedule keeps the saved value too" "$(saved_token):$(grep -c 'CUSTOM_TOKEN is not set in this shell; keeping the value saved' "$work/init-unset.log")" 'kept:1'
node "$CLI" start --every 6 </dev/null > "$work/start-two.log" 2>&1
check "start warns about a credential with no value anywhere, and still keeps the saved one" \
    "$(saved_token):$(grep -c "OTHER_TOKEN is not set in this shell and no value is saved" "$work/start-two.log"):$(grep -c 'OTHER_TOKEN' .evolve/.env)" 'kept:1:0'
printf "export OTHER_TOKEN='planted'\n" >> .evolve/.env
node "$CLI" init --yes --agent custom --agent-command 'fakeagent --flag' --agent-env 'CUSTOM_TOKEN' </dev/null >/dev/null 2>&1
check "a name no longer listed is not carried over" "$(saved_token):$(grep -c 'OTHER_TOKEN' .evolve/.env)" 'kept:0'
git config user.email t@example.com; git config user.name t; git add -A; git commit -qm "fresh install"
rm -f "$work/token-seen"
node "$CLI" start --every 6 --run-now </dev/null > "$work/runnow-unset.log" 2>&1 || true
check "start --run-now hands the kept value to the first cycle" "$(cat "$work/token-seen" 2>/dev/null)" 'kept'

# Validation uses the same grep the adapter runs (GNU grep, ugrep, BSD grep differ), so an
# unbalanced group, invalid in every grep -E, is the portable case to test.
node "$CLI" init --yes --agent custom --agent-command 'fakeagent --new-flag' </dev/null > "$work/init-change.log" 2>&1
check "re-running init with a new command refreshes the scheduled cron .env" "$(grep -c "AGENT_COMMAND='fakeagent --new-flag'" .evolve/.env 2>/dev/null || echo 0)" "1"

status=0; node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-error-pattern 'quota(' </dev/null > "$work/init-regex.log" 2>&1 || status=$?
check "a pattern this system's grep -E rejects is rejected at init" "$status" "1"
check "and the message names grep -E" "$(grep -c 'not a valid grep -E pattern' "$work/init-regex.log")" "1"

# A name every JavaScript object has (constructor, toString) is a variable like any other: unset
# unless the shell exports it (#154). process.env answers for such a name with a function.
status=0; node "$CLI" init --yes --agent custom --agent-command 'fakeagent' --agent-env 'constructor,toString' </dev/null > "$work/init-inherited.log" 2>&1 || status=$?
check "init schedules with a credential named constructor that is not set" \
    "$status:$(grep -c 'Could not install local cron job' "$work/init-inherited.log"):$(grep -c 'constructor is not set in this shell and no value is saved' "$work/init-inherited.log"):$(grep -c 'toString is not set in this shell and no value is saved' "$work/init-inherited.log")" "0:0:1:1"
check "and writes no line for it into the cron .env" "$(grep -c "AGENT_COMMAND='fakeagent'" .evolve/.env):$(grep -cE '^export (constructor|toString)=' .evolve/.env)" "1:0"
constructor='built' node "$CLI" start --every 6 </dev/null > "$work/start-inherited.log" 2>&1
check "a variable the shell really exports as constructor is saved" "$(grep -c "^export constructor='built'\$" .evolve/.env):$(grep -c 'constructor is not set' "$work/start-inherited.log")" "1:0"
node "$CLI" start --every 6 </dev/null > "$work/start-inherited-kept.log" 2>&1
check "and kept when a later start runs without it" "$(grep -c "^export constructor='built'\$" .evolve/.env):$(grep -c 'constructor is not set in this shell; keeping the value saved' "$work/start-inherited-kept.log")" "1:1"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
