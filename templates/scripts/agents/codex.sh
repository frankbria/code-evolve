#!/bin/bash
# Agent adapter: Codex CLI (OpenAI)
# Verified against codex-cli 0.141.0 (2026-06). The non-interactive entrypoint is
# `codex exec` (NOT the old `codex --quiet`, which no longer exists). `exec` reads
# the prompt from stdin when no PROMPT arg is given, runs with approvals disabled,
# and exits non-zero on API/auth errors (so evolve.sh's exit-code check suffices).

check_agent() {
    command -v codex &>/dev/null
}

# run_agent <prompt_file> <model> <timeout_cmd> <timeout>
run_agent() {
    local prompt_file="$1"
    local model="$2"
    local timeout_cmd="$3"
    local timeout="$4"

    # NOTE: --sandbox workspace-write lets the agent edit the repo + run most
    # build/test steps, but blocks network and out-of-workspace writes. Upgrade path:
    # swap for --dangerously-bypass-approvals-and-sandbox in externally-sandboxed CI.
    ${timeout_cmd:+$timeout_cmd "$timeout"} codex exec \
        --model "$model" \
        --sandbox workspace-write \
        --skip-git-repo-check \
        < "$prompt_file" 2>&1
}

agent_env_hint() {
    echo "OPENAI_API_KEY (or a ChatGPT login via 'codex login')"
}
