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

# ── claude.sh: detects the JSON error marker, ignores clean output ──
( source "$AGENTS/claude.sh"
  printf '%s\n' '{"type":"error","error":{"message":"overloaded"}}' > "$log"
  agent_detect_error "$log" ) && ok "claude: detects \"type\":\"error\"" \
                              || bad "claude: should detect \"type\":\"error\""

( source "$AGENTS/claude.sh"
  printf '%s\n' 'all good, feature implemented' > "$log"
  agent_detect_error "$log" ) && bad "claude: false positive on clean log" \
                              || ok "claude: clean log not flagged"

# ── fallback: adapters without agent_detect_error rely on exit code ──
# Replicates the evolve.sh guard: define the fallback only if unset.
for adapter in codex opencode ollama; do
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
