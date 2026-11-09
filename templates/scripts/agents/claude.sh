#!/bin/bash
# Agent adapter: Claude Code CLI

check_agent() {
    command -v claude &>/dev/null
}

agent_auth_check() {
    if [ "${CLAUDE_AUTH_MODE:-api-key}" = "oauth" ]; then
        if ! claude auth status &>/dev/null; then
            echo "ERROR: Claude not authenticated. Run 'claude auth login' to authenticate." >&2
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

    # Stream JSON events so a failed session is detectable even when claude exits 0: claude_stream.py
    # turns them back into a readable log and exits 1 for an error result, which pipefail makes this
    # function's exit code. dontAsk denies, rather than waits on, any tool not allowed.
    # The prompt names every runtime skill by path, so nothing depends on what --bare would skip.
    ${timeout_cmd:+$timeout_cmd "$timeout"} claude -p --model "$model" \
        --output-format stream-json --verbose \
        --permission-mode dontAsk \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
        < "$prompt_file" 2>&1 | python3 "$(dirname "${BASH_SOURCE[0]}")/../claude_stream.py"
}
