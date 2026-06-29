#!/bin/bash
# Agent adapter: OpenCode CLI
# Verified against opencode 1.17.8 (2026-06): `opencode run` reads the prompt from
# stdin and the model flag takes a "provider/model" string (e.g. "anthropic/claude-..."
# or "opencode/...-free"). A bare model name will not resolve. Exits non-zero on error.

check_agent() {
    command -v opencode &>/dev/null
}

# run_agent <prompt_file> <model> <timeout_cmd> <timeout>
run_agent() {
    local prompt_file="$1"
    local model="$2"
    local timeout_cmd="$3"
    local timeout="$4"

    ${timeout_cmd:+$timeout_cmd "$timeout"} opencode run --model "$model" \
        < "$prompt_file" 2>&1
}

agent_env_hint() {
    echo "OPENAI_API_KEY or ANTHROPIC_API_KEY (depends on configured provider)"
}
