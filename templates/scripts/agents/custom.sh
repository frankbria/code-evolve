#!/bin/bash
# Agent adapter: any headless CLI, driven by a command template from .evolve/config.json (#91).
#   AGENT_COMMAND        e.g. `copilot -p --allow-all-tools --model {model}`; the prompt arrives on stdin,
#                        or replaces `{prompt_file}` (a path) when the template contains it.
#   AGENT_ERROR_PATTERN  optional extended regex; a matching log line marks the session failed,
#                        for CLIs that exit 0 on errors.
# The template is the user's own config, run as one shell command. The placeholders become fixed
# references to environment variables, so the model and prompt path never enter the command text
# and cannot add commands of their own, whatever characters they hold.

check_agent() {
    local binary=""
    # The first word, with surrounding whitespace (spaces or tabs) trimmed, as init reads it.
    read -r binary _ <<<"${AGENT_COMMAND:-}"
    [ -n "$binary" ] && command -v "$binary" &>/dev/null
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

    local model_reference='"$CODE_EVOLVE_MODEL"' prompt_file_reference='"$CODE_EVOLVE_PROMPT_FILE"' quoted
    # A placeholder the user quoted ('{model}' or "{model}") is unwrapped first: the reference is already
    # quoted, and inside single quotes it would reach the agent as literal text.
    for quoted in "'{model}'" '"{model}"'; do command="${command//"$quoted"/{model\}}"; done
    for quoted in "'{prompt_file}'" '"{prompt_file}"'; do command="${command//"$quoted"/{prompt_file\}}"; done
    command="${command//\{model\}/$model_reference}"
    if [[ "$command" == *"{prompt_file}"* ]]; then
        command="${command//\{prompt_file\}/$prompt_file_reference}"
        CODE_EVOLVE_MODEL="$model" CODE_EVOLVE_PROMPT_FILE="$prompt_file" \
            ${timeout_cmd:+$timeout_cmd "$timeout"} bash -c "$command" </dev/null 2>&1
    else
        CODE_EVOLVE_MODEL="$model" CODE_EVOLVE_PROMPT_FILE="$prompt_file" \
            ${timeout_cmd:+$timeout_cmd "$timeout"} bash -c "$command" < "$prompt_file" 2>&1
    fi
}

# agent_detect_error <logfile> — returns 0 when AGENT_ERROR_PATTERN matches the log.
agent_detect_error() {
    [ -n "${AGENT_ERROR_PATTERN:-}" ] && grep -Eq -- "$AGENT_ERROR_PATTERN" "$1" 2>/dev/null
}
