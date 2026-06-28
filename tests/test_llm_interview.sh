#!/bin/bash
# Test: `code-evolve vision`/`spec` draft via the configured agent adapter when one
# is available, and fall back to the static template when none is. Regression test
# for issue #23 (P1.4 — LLM-driven interview).
#
# Drives the REAL compiled CLI over piped (non-TTY) stdin. No real agent/API is
# used: a stub `.evolve/scripts/agents/claude.sh` adapter stands in for the LLM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

# Always rebuild so a stale dist/ can't produce a false pass.
( cd "$ROOT" && npm run build >/dev/null 2>&1 )

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fi; [ "$2" = "$3" ] || fail=$((fail+1)); }

# Install a stub agent adapter that echoes a fixed document to stdout, proving the
# LLM path was taken (its output replaces the static builder).
install_stub_adapter() {
  local dir="$1" body="$2"
  mkdir -p "$dir/.evolve/scripts/agents"
  printf '{"agent":"claude"}\n' > "$dir/.evolve/config.json"
  cat > "$dir/.evolve/scripts/agents/claude.sh" <<EOF
#!/bin/bash
run_agent() { cat <<'DOC'
$body
DOC
}
EOF
}

VISION_ANSWERS=(
  "A command line tool for managing notes" "Developers who live in the terminal daily"
  "They scatter notes across many files today" "When they cannot find an old note quickly"
  "They type a command and see results" "Fast full text search across all notes"
  "Not a heavyweight cloud knowledge base" "Cut sync and sharing for the first week"
  "Daily active use by the author themselves" "When search returns the right note instantly"
  "yes" "yes"
)
SPEC_ANSWERS=(
  "TypeScript Node.js Commander SQLite Jest" "A CLI tool using the command pattern"
  "Add task command" "List all tasks command" ""
  "Tasks stored as markdown files locally" "CLI subcommands add and list tasks"
  "Jest unit tests with coverage target" "Published to the npm registry package"
  "yes" "yes"
)

# ── Case 1: vision drafts via the agent adapter ──
T1=$(mktemp -d)
install_stub_adapter "$T1" "# Vision
## What We're Building
AGENT_DRAFTED_VISION_MARKER"
( cd "$T1"; printf '%s\n' "${VISION_ANSWERS[@]}" | ANTHROPIC_API_KEY=stub-key node "$CLI" vision >/dev/null 2>&1 ) || echo CRASH > "$T1/crash"
check "vision (agent) does not crash" "$( [ -f "$T1/crash" ] && echo CRASH || echo OK )" "OK"
check "vision (agent) writes vision.md" "$( [ -f "$T1/.evolve/vision.md" ] && echo YES || echo NO )" "YES"
check "vision uses agent-drafted output" "$(grep -c 'AGENT_DRAFTED_VISION_MARKER' "$T1/.evolve/vision.md" || true)" "1"
rm -rf "$T1"

# ── Case 2: vision falls back to the static template with no adapter ──
T2=$(mktemp -d)
( cd "$T2"; printf '%s\n' "${VISION_ANSWERS[@]}" | node "$CLI" vision >/dev/null 2>&1 ) || echo CRASH > "$T2/crash"
check "vision (fallback) does not crash" "$( [ -f "$T2/crash" ] && echo CRASH || echo OK )" "OK"
check "vision fallback uses static builder" "$(grep -c 'managing notes' "$T2/.evolve/vision.md" || true)" "1"
check "vision fallback has no agent marker" "$(grep -c 'AGENT_DRAFTED' "$T2/.evolve/vision.md" || true)" "0"
rm -rf "$T2"

# ── Case 3: spec drafts via the agent AND enforces the verbatim feature list ──
# The stub deliberately DROPS the second feature; enforcement must restore both
# while keeping the rest of the agent draft (marker + Deployment) intact.
T3=$(mktemp -d)
install_stub_adapter "$T3" "# Specification
## Tech Stack
SPEC_AGENT_MARKER
## Features (Priority Order)
- [ ] Add task command
## Deployment
ships to npm registry"
( cd "$T3"; printf '%s\n' "${SPEC_ANSWERS[@]}" | ANTHROPIC_API_KEY=stub-key node "$CLI" spec >/dev/null 2>&1 ) || echo CRASH > "$T3/crash"
check "spec (agent) does not crash" "$( [ -f "$T3/crash" ] && echo CRASH || echo OK )" "OK"
check "spec uses agent-drafted output" "$(grep -c 'SPEC_AGENT_MARKER' "$T3/.evolve/spec.md" || true)" "1"
check "spec restores dropped feature" "$(grep -c '^- \[ \] List all tasks command' "$T3/.evolve/spec.md" || true)" "1"
check "spec keeps first feature" "$(grep -c '^- \[ \] Add task command' "$T3/.evolve/spec.md" || true)" "1"
check "spec keeps rest of agent draft" "$(grep -c 'ships to npm registry' "$T3/.evolve/spec.md" || true)" "1"
rm -rf "$T3"

# ── Case 4: spec falls back to static template when adapter exists but key is unset ──
T4=$(mktemp -d)
install_stub_adapter "$T4" "SHOULD_NOT_APPEAR"
( cd "$T4"; env -u ANTHROPIC_API_KEY printf '%s\n' "${SPEC_ANSWERS[@]}" | env -u ANTHROPIC_API_KEY node "$CLI" spec >/dev/null 2>&1 ) || echo CRASH > "$T4/crash"
check "spec (no key) does not crash" "$( [ -f "$T4/crash" ] && echo CRASH || echo OK )" "OK"
check "spec fallback uses static builder" "$(grep -c 'TypeScript Node.js Commander' "$T4/.evolve/spec.md" || true)" "1"
check "spec fallback ignores adapter output" "$(grep -c 'SHOULD_NOT_APPEAR' "$T4/.evolve/spec.md" || true)" "0"
rm -rf "$T4"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
