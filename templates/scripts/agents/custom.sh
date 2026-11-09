#!/bin/bash
# Agent adapter: any headless CLI, driven by a command template from .evolve/config.json (#91).
#   AGENT_COMMAND        e.g. `copilot -p --allow-all-tools --model {model}`; the prompt arrives on stdin,
#                        or replaces `{prompt_file}` (a path) when the template contains it.
#   AGENT_ERROR_PATTERN  optional extended regex; a matching log line marks the session failed,
#                        for CLIs that exit 0 on errors.
# The template is the user's own config, run as one shell command; the values substituted into it
# (model, prompt path) are shell-quoted, so they can never add commands of their own.

check_agent() {
    [ -n "${AGENT_COMMAND:-}" ] && command -v "${AGENT_COMMAND%% *}" &>/dev/null
}

# run_agent <prompt_file> <model> <timeout_cmd> <timeout>
run_agent() {
    local prompt_file="$1"
    local model="$2"
    local timeout_cmd="$3"
    local timeout="$4"
    local command="${AGENT_COMMAND:-}"
    if [ -z "$command" ]; then
        echo "ERROR: AGENT=custom needs agentCommand in .evolve/config.json" >&2
        return 1
    fi

    command="${command//\{model\}/$(printf '%q' "$model")}"
    if [[ "$command" == *"{prompt_file}"* ]]; then
        command="${command//\{prompt_file\}/$(printf '%q' "$prompt_file")}"
        ${timeout_cmd:+$timeout_cmd "$timeout"} bash -c "$command" </dev/null 2>&1
    else
        ${timeout_cmd:+$timeout_cmd "$timeout"} bash -c "$command" < "$prompt_file" 2>&1
    fi
}

# agent_detect_error <logfile> — returns 0 when AGENT_ERROR_PATTERN matches the log.
agent_detect_error() {
    [ -n "${AGENT_ERROR_PATTERN:-}" ] && grep -Eq -- "$AGENT_ERROR_PATTERN" "$1" 2>/dev/null
}
