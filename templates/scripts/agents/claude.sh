#!/bin/bash
# Agent adapter: Claude Code CLI

check_agent() {
    command -v claude &>/dev/null
}

# run_agent <prompt_file> <model> <timeout_cmd> <timeout>
run_agent() {
    local prompt_file="$1"
    local model="$2"
    local timeout_cmd="$3"
    local timeout="$4"

    ${timeout_cmd:+$timeout_cmd "$timeout"} claude -p --model "$model" \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
        < "$prompt_file" 2>&1
}

agent_env_hint() {
    echo "ANTHROPIC_API_KEY"
}
