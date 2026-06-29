#!/bin/bash
# Test: `code-evolve init --agent <X> --with-ci` templates the bundled GitHub
# Actions workflow (evolve.yml) for the configured backend — installing the right
# CLI, wiring the right secret, and setting AGENT/MODEL so evolve.sh sources the
# matching adapter (not always Claude).
# Regression test for issue #37 (P2.7).
#
# Drives the REAL compiled CLI, non-TTY (piped stdin) so no interactive prompt
# fires. Stub agent binaries on PATH satisfy the dependency check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

[ -f "$CLI" ] || ( cd "$ROOT" && npm run build >/dev/null 2>&1 )

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
has()   { if echo "$2" | grep -qF -- "$3"; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (missing '$3')"; fail=$((fail+1)); fi }
hasnt() { if echo "$2" | grep -qF -- "$3"; then echo "  FAIL: $1 (unexpected '$3')"; fail=$((fail+1)); else echo "  ok: $1"; pass=$((pass+1)); fi }

# Stub all four agent binaries so checkDependencies passes for any --agent.
STUB=$(mktemp -d)
for b in claude codex opencode ollama; do
  printf '#!/bin/bash\necho "%s 0.0.0-stub"\n' "$b" > "$STUB/$b"
  chmod +x "$STUB/$b"
done
export PATH="$STUB:$PATH"
unset ANTHROPIC_API_KEY OPENAI_API_KEY

run_init() {  # $1 = agent
  local dir; dir=$(mktemp -d)
  ( cd "$dir" && git init -q && node "$CLI" init --agent "$1" --with-ci </dev/null >/dev/null 2>&1 )
  echo "$dir"
}

# ── codex: workflow installs Codex CLI, uses OPENAI_API_KEY, runs codex adapter ──
D=$(run_init codex)
WF="$D/.github/workflows/evolve.yml"
check "codex: workflow installed" "$([ -f "$WF" ] && echo yes || echo no)" "yes"
YML=$(cat "$WF" 2>/dev/null || echo "")
has   "codex: installs Codex CLI"     "$YML" "npm install -g @openai/codex"
has   "codex: uses OPENAI_API_KEY"    "$YML" "OPENAI_API_KEY: \${{ secrets.OPENAI_API_KEY }}"
has   "codex: sets AGENT=codex"       "$YML" "AGENT: codex"
has   "codex: sets MODEL=o4-mini"     "$YML" "MODEL: o4-mini"
hasnt "codex: no claude CLI install"  "$YML" "@anthropic-ai/claude-code"
hasnt "codex: no ANTHROPIC secret"    "$YML" "ANTHROPIC_API_KEY"
rm -rf "$D"

# ── claude: default backend still produces a valid Claude workflow ──
D=$(run_init claude)
YML=$(cat "$D/.github/workflows/evolve.yml" 2>/dev/null || echo "")
has   "claude: installs claude-code"  "$YML" "npm install -g @anthropic-ai/claude-code"
has   "claude: uses ANTHROPIC_API_KEY" "$YML" "ANTHROPIC_API_KEY: \${{ secrets.ANTHROPIC_API_KEY }}"
has   "claude: sets AGENT=claude"     "$YML" "AGENT: claude"
rm -rf "$D"

# ── opencode: installs opencode CLI, provider keys present ──
D=$(run_init opencode)
YML=$(cat "$D/.github/workflows/evolve.yml" 2>/dev/null || echo "")
has   "opencode: installs opencode"   "$YML" "npm install -g opencode-ai"
has   "opencode: sets AGENT=opencode" "$YML" "AGENT: opencode"
# opencode needs a provider-qualified model — a bare name won't resolve (agents/opencode.sh).
has   "opencode: provider-qualified MODEL" "$YML" "MODEL: anthropic/claude-sonnet-4-6"
rm -rf "$D"

# ── ollama: local-only — CI install is skipped (no workflow) ──
D=$(mktemp -d)
OUT=$( cd "$D" && git init -q && node "$CLI" init --agent ollama --with-ci </dev/null 2>&1 )
check "ollama: CI workflow skipped"   "$([ -f "$D/.github/workflows/evolve.yml" ] && echo yes || echo no)" "no"
has   "ollama: skip explained"        "$OUT" "local"
# Don't persist a CI mode that was refused — normalize to local (issue #37 review).
check "ollama: mode normalized off ci" "$(node -e "console.log(require('$D/.evolve/config.json').mode)")" "local"
rm -rf "$D"

rm -rf "$STUB"
echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
