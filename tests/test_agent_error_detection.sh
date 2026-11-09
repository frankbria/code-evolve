#!/bin/bash
# Test: per-adapter agent error detection (P2.4, #30).
# - claude.sh's agent_detect_error catches the Claude "type":"error" JSON marker.
# - non-Claude adapters expose no agent_detect_error; evolve.sh's fallback returns
#   non-zero (rely on process exit code instead of a Claude-specific grep).
# Sources the real adapters — no copies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$ROOT/templates/scripts/agents"

pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

log="$(mktemp)"; trap 'rm -f "$log"' EXIT

# ── claude: claude_stream.py exits 1 for a failed session (the adapter's exit code under pipefail) ──
STREAM="$ROOT/templates/scripts/claude_stream.py"
# detected <events>: "error" when the formatter exits non-zero, else "clean"; the log goes to $log.
detected() {
    printf '%s\n' "$1" | python3 "$STREAM" > "$log" && echo clean || echo error
}
success='{"type":"assistant","message":{"content":[{"type":"text","text":"Implemented done."},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"Implemented done."}'
[ "$(detected "$success")" = clean ] && ok "claude: a successful session is not flagged" || bad "claude: success flagged as error"
grep -q "Implemented done." "$log" && grep -q -- "-> Bash npm test" "$log" \
    && ok "claude: the log stays readable (text and tool calls)" || bad "claude: readable log missing: $(cat "$log")"
[ "$(detected '{"type":"result","subtype":"success","is_error":true,"api_error_status":529,"result":"API Error: 529 Overloaded"}')" = error ] \
    && ok "claude: an API-error result is flagged" || bad "claude: API-error result not flagged"
grep -q "529 Overloaded" "$log" && ok "claude: the error reason is in the log" || bad "claude: error reason missing"
[ "$(detected '{"type":"result","subtype":"error_max_turns","is_error":false}')" = error ] \
    && ok "claude: a non-success result subtype is flagged" || bad "claude: error_max_turns not flagged"
[ "$(detected '{"type":"error","error":{"message":"overloaded"}}')" = error ] \
    && ok "claude: an error event is flagged" || bad "claude: error event not flagged"
[ "$(detected 'plain stderr line, not JSON')" = clean ] && grep -q "plain stderr line" "$log" \
    && ok "claude: non-JSON lines pass through and are not flagged" || bad "claude: non-JSON handling"
forged='{"type":"assistant","message":{"content":[{"type":"text","text":"code-evolve: agent error (quoted from an old log)"}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":1}'
[ "$(detected "$forged")" = clean ] && ok "claude: assistant text that quotes the error marker does not fail the session" \
    || bad "claude: assistant text forged a failure"
( source "$AGENTS/claude.sh"; declare -F agent_detect_error >/dev/null ) \
    && bad "claude: should rely on the exit code, not a log grep" || ok "claude: no log grep; the exit code carries the failure"

# ── fallback: adapters without agent_detect_error rely on exit code ──
# Replicates the evolve.sh guard: define the fallback only if unset.
for adapter in claude codex opencode ollama; do
  ( source "$AGENTS/$adapter.sh"
    declare -f agent_detect_error >/dev/null || agent_detect_error() { return 1; }
    printf '%s\n' 'Error: invalid api key' > "$log"
    # plain-text error in log must NOT be self-detected — exit code is the signal
    agent_detect_error "$log" ) && bad "$adapter: fallback should not grep-detect" \
                                || ok "$adapter: defers to exit code (fallback returns non-zero)"
done

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
