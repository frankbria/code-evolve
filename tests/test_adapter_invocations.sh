#!/bin/bash
# Test: each non-Claude adapter's run_agent invokes its CLI with the correct
# subcommand/flags (P2.5, #31). Offline — stubs each CLI on PATH and asserts the
# args run_agent passes, so no API key or network is needed. Sources the real
# adapters (no copies). Real end-to-end runs were verified manually against
# codex-cli 0.141.0, opencode 1.17.8, and ollama.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$ROOT/templates/scripts/agents"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stubdir="$(mktemp -d)"
prompt="$(mktemp)"; printf 'do the thing\n' > "$prompt"
trap 'rm -rf "$stubdir" "$prompt"' EXIT

# Stub every adapter CLI: print "ARGS:" + its argv, swallow stdin.
for cli in codex opencode ollama; do
    cat > "$stubdir/$cli" <<'STUB'
#!/bin/bash
cat >/dev/null   # consume the piped prompt
echo "ARGS: $*"
STUB
    chmod +x "$stubdir/$cli"
done

run() { # <adapter> -> captured invocation line
    ( PATH="$stubdir:$PATH"; source "$AGENTS/$1.sh"; run_agent "$prompt" "MODEL_X" "" "" )
}

assert_has()    { case "$2" in *"$1"*) ok "$3";;    *) bad "$3 — got: $2";; esac; }
assert_lacks()  { case "$2" in *"$1"*) bad "$4 — got: $2";; *) ok "$3";; esac; }

# ── codex: must use `exec`, workspace-write sandbox, and NOT the dead --quiet flag ──
out="$(run codex)"
assert_has  "exec"                  "$out" "codex: uses 'codex exec'"
assert_has  "--sandbox workspace-write" "$out" "codex: sandbox workspace-write"
assert_has  "--model MODEL_X"       "$out" "codex: forwards --model"
assert_lacks "--quiet"              "$out" "codex: no dead --quiet flag" "codex: still passes --quiet"

# ── opencode: `run --model <m>` (prompt via stdin) ──
out="$(run opencode)"
assert_has "run"            "$out" "opencode: uses 'opencode run'"
assert_has "--model MODEL_X" "$out" "opencode: forwards --model"

# ── ollama: `run <model>` (prompt via stdin) ──
out="$(run ollama)"
assert_has "run MODEL_X"   "$out" "ollama: 'ollama run <model>'"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
