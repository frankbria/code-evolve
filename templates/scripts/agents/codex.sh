#!/bin/bash
# Agent adapter: Codex CLI (OpenAI)

check_agent() {
    command -v codex &>/dev/null
}

# run_agent <prompt_file> <model> <timeout_cmd> <timeout>
run_agent() {
    local prompt_file="$1"
    local model="$2"
    local timeout_cmd="$3"
    local timeout="$4"

    ${timeout_cmd:+$timeout_cmd "$timeout"} codex --quiet \
        < "$prompt_file" 2>&1
}

agent_env_hint() {
    echo "OPENAI_API_KEY"
}
