#!/bin/bash
# Test (#70): adapters must work under evolve.sh's `set -euo pipefail` with optional
# variables (CLAUDE_AUTH_MODE) unset, and `code-evolve run` with the default
# claude + API-key setup must reach the agent call.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$ROOT/templates/scripts/agents"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT

# Stub agent CLIs: record that they ran, swallow the prompt. `gh` fails so the
# engine skips GitHub calls instead of reaching the network.
for cli in claude codex opencode ollama; do
    printf '#!/bin/bash\ncat >/dev/null\necho "%s-stub-called" >> "%s/agent-calls"\n' "$cli" "$stub_dir" > "$stub_dir/$cli"
    chmod +x "$stub_dir/$cli"
done
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"; chmod +x "$stub_dir/gh"

prompt_file="$stub_dir/prompt"; echo "do the thing" > "$prompt_file"
clean_path="$stub_dir:$(dirname "$(command -v node)"):/usr/local/bin:/usr/bin:/bin"

# ── Each adapter: run_agent and agent_env_hint under strict mode, clean env ──
for adapter in claude codex opencode ollama; do
    output=$(env -i PATH="$clean_path" HOME="$HOME" bash -c '
        set -euo pipefail
        source "$1"
        run_agent "$2" some-model "" ""
        agent_env_hint >/dev/null
    ' _ "$AGENTS/$adapter.sh" "$prompt_file" 2>&1) && status=0 || status=$?
    if [ "$status" -eq 0 ] && ! grep -q "unbound variable" <<<"$output"; then
        ok "$adapter: run_agent + agent_env_hint succeed under set -u with clean env"
    else
        bad "$adapter: failed under set -u (exit $status): $output"
    fi
done

# ── End to end: `code-evolve run` (claude, API key, no CLAUDE_AUTH_MODE) ──
rm -f "$stub_dir/agent-calls"
cd "$work_dir"
git init -q
git config user.email test@example.com
git config user.name test
echo "# demo" > README.md
git add README.md && git commit -qm init
env -i PATH="$clean_path" HOME="$HOME" node "$CLI" init --agent claude >/dev/null 2>&1
run_output=$(env -i PATH="$clean_path" HOME="$HOME" ANTHROPIC_API_KEY=test-key \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
    timeout 120 node "$CLI" run --timeout 60 2>&1) || true

if grep -q "unbound variable" <<<"$run_output"; then
    bad "code-evolve run hit an unbound variable: $(grep 'unbound variable' <<<"$run_output")"
else
    ok "code-evolve run: no unbound-variable error"
fi
if grep -q "claude-stub-called" "$stub_dir/agent-calls" 2>/dev/null; then
    ok "code-evolve run reached the claude agent call"
else
    bad "code-evolve run never invoked the agent. Tail: $(tail -5 <<<"$run_output")"
fi
if grep -q "Agent error detected" <<<"$run_output"; then
    bad "code-evolve run treated the agent call as failed: $(grep "Agent error detected" <<<"$run_output")"
else
    ok "code-evolve run: agent call not treated as an error"
fi

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
