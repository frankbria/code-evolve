#!/bin/bash
# Agent adapter: Ollama (local models)

check_agent() {
    command -v ollama &>/dev/null
}

# run_agent <prompt_file> <model> <timeout_cmd> <timeout>
run_agent() {
    local prompt_file="$1"
    local model="$2"
    local timeout_cmd="$3"
    local timeout="$4"

    ${timeout_cmd:+$timeout_cmd "$timeout"} ollama run "$model" \
        < "$prompt_file" 2>&1
}

agent_env_hint() {
    echo "(none — Ollama runs locally. Ensure 'ollama serve' is running)"
}
