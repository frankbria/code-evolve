#!/bin/bash
# Test (#89): model and auth parity across adapters. Codex in ChatGPT-login mode runs without
# OPENAI_API_KEY (checked with `codex login status`), run/start honor config.model, and the engine's
# default model follows the agent, in step with the CLI's defaults.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"; mkdir -p "$stub_dir"
# codex stub: `login status` exits STUB_LOGIN_STATUS (default 0); `exec` records its arguments.
cat > "$stub_dir/codex" <<STUB
#!/bin/bash
case "\${1:-}" in
    --version) echo "codex-cli 0.0.0-stub" ;;
    login) [ "\${2:-}" = status ] && exit "\${STUB_LOGIN_STATUS:-0}" ;;
    exec) echo "\$*" >> "$work/codex.calls"; cat > /dev/null ;;
esac
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
# Never touch the real crontab: record calls, behave like an empty table.
printf '#!/bin/bash\necho "$*" >> "%s/crontab.calls"\n[ "${1:-}" = "-l" ] && { echo "no crontab for $USER" >&2; exit 1; }\ncat > /dev/null\n' "$work" > "$stub_dir/crontab"
chmod +x "$stub_dir"/*
export PATH="$stub_dir:$PATH"
unset OPENAI_API_KEY ANTHROPIC_API_KEY

# The engine's default model per agent matches the CLI's (src/utils/config.ts).
for agent in claude codex opencode ollama; do
    branch="$agent"; [ "$agent" = claude ] && branch='\*'  # claude is the engine's fallback branch
    engine_default="$(grep -E "^ *$branch\) +DEFAULT_MODEL=" "$ROOT/templates/scripts/evolve.sh" | sed -E 's/.*DEFAULT_MODEL="([^"]*)".*/\1/' || true)"
    check "engine default model for $agent matches the CLI" "$engine_default" "$(node -p "require('$ROOT/dist/utils/config').getDefaultModel('$agent')")"
done

project="$work/project"; mkdir -p "$project"; cd "$project"
git init -q; git config user.email t@example.com; git config user.name t
printf '{"name":"demo","scripts":{"build":"true","test":"true"}}\n' > package.json
node "$CLI" init --yes --agent codex --auth-mode chatgpt </dev/null >/dev/null 2>&1
check "init records the ChatGPT login mode for codex" "$(node -p "require('./.evolve/config.json').authMode")" "chatgpt"
node -e "const f='.evolve/config.json';const c=require('./'+f);c.model='my-codex-model';require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
git add -A && git commit -qm "codex install"

status=0; node "$CLI" run --timeout 60 </dev/null > "$work/run.log" 2>&1 || status=$?
check "a ChatGPT-login codex run without OPENAI_API_KEY reaches the agent" "$([ -s "$work/codex.calls" ] && echo called || echo "not called (exit $status: $(tail -2 "$work/run.log" | tr '\n' ' '))")" "called"
check "run uses the configured model" "$(grep -c -- '--model my-codex-model' "$work/codex.calls" || true)" "$(wc -l < "$work/codex.calls" | tr -d ' ')"

rm -f "$work/codex.calls"
status=0; STUB_LOGIN_STATUS=1 node "$CLI" run --timeout 60 </dev/null > "$work/nologin.log" 2>&1 || status=$?
check "without a codex login, run exits 3" "$status" "3"
check "and says how to log in" "$(grep -c 'codex login' "$work/nologin.log")" "1"
check "and never calls the agent" "$([ -e "$work/codex.calls" ] && echo called || echo "not called")" "not called"

# api-key mode still requires the key.
node -e "const f='.evolve/config.json';const c=require('./'+f);c.authMode='api-key';require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
status=0; node "$CLI" run --timeout 60 </dev/null > "$work/apikey.log" 2>&1 || status=$?
check "api-key mode without OPENAI_API_KEY exits 3" "$status" "3"

# start in ChatGPT-login mode: schedules without a key and keeps any key out of the cron .env.
node -e "const f='.evolve/config.json';const c=require('./'+f);c.authMode='chatgpt';require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
status=0; OPENAI_API_KEY=sk-should-not-be-saved node "$CLI" start --every 6 </dev/null > "$work/start.log" 2>&1 || status=$?
check "start in ChatGPT-login mode succeeds without needing a key" "$status" "0"
check "the cron .env holds no API key in a login mode" "$(grep -c 'OPENAI_API_KEY' .evolve/.env || true)" "0"
check "the cron .env carries the configured model" "$(grep -c "MODEL='my-codex-model'" .evolve/.env)" "1"

# init falls back to api-key when a login mode does not belong to the agent.
other="$work/other"; mkdir -p "$other"; cd "$other"; git init -q
node "$CLI" init --yes --agent codex --auth-mode oauth </dev/null > "$work/fallback.log" 2>&1
check "oauth on codex falls back to api-key" "$(node -p "require('./.evolve/config.json').authMode")" "api-key"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
