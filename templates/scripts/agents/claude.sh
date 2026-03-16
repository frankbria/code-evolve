#!/bin/bash
# Agent adapter: Claude Code CLI

check_agent() {
    command -v claude &>/dev/null
}

agent_auth_check() {
    if [ "$CLAUDE_AUTH_MODE" = "oauth" ]; then
        if ! claude --version &>/dev/null; then
            echo "ERROR: Claude CLI not responding. Is your OAuth session active?" >&2
            echo "Run 'claude login' to re-authenticate." >&2
            return 1
        fi
    fi
}

# run_agent <prompt_file> <model> <timeout_cmd> <timeout>
run_agent() {
    local prompt_file="$1"
    local model="$2"
    local timeout_cmd="$3"
    local timeout="$4"

    agent_auth_check || return 1

    ${timeout_cmd:+$timeout_cmd "$timeout"} claude -p --model "$model" \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
        < "$prompt_file" 2>&1
}

agent_env_hint() {
    if [ "$CLAUDE_AUTH_MODE" = "oauth" ]; then
        echo "Run 'claude login' to authenticate via OAuth"
    else
        echo "ANTHROPIC_API_KEY"
    fi
}
