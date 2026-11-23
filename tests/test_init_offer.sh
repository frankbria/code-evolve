#!/bin/bash
# Test (#97): `code-evolve init` never prompts, even on a terminal. The agent/mode/interval pickers
# and the vision + spec interview offer are retired (the evolve-setup skill onboards instead); init
# keeps its flags and its manual "edit these files" guidance.
#
# Drives the real compiled CLI under `script`, so stdin and stdout are a terminal. A stub `claude`
# on PATH satisfies the dependency check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
[ -f "$CLI" ] || ( cd "$ROOT" && npm run build >/dev/null 2>&1 )

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

STUB=$(mktemp -d)
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$STUB/claude"
chmod +x "$STUB/claude"

in_terminal() {  # util-linux `script` takes -c; BSD/macOS `script` takes the command after the file
    if script -qec true /dev/null >/dev/null 2>&1; then
        printf '' | timeout 30 script -qec "PATH='$STUB:$PATH' $1" /dev/null
    else
        printf '' | timeout 30 script -q /dev/null env PATH="$STUB:$PATH" bash -c "$1"
    fi
}

# ── A terminal init asks nothing and finishes with the manual guidance ──
T1=$(mktemp -d)
( cd "$T1" && git init -q )
OUT1=$( cd "$T1" && in_terminal "node '$CLI' init" 2>&1 ) || true
check "terminal init finishes"                 "$(echo "$OUT1" | grep -c 'code-evolve initialized' || true)" "1"
check "it shows no agent picker"               "$(echo "$OUT1" | grep -c 'Which agent backend' || true)" "0"
check "it shows no execution-mode picker"      "$(echo "$OUT1" | grep -c 'Where should evolution run' || true)" "0"
check "it offers no interview"                 "$(echo "$OUT1" | grep -ci 'guided interview' || true)" "0"
check "it keeps the manual vision step"        "$(echo "$OUT1" | grep -c 'Edit .evolve/vision.md' || true)" "1"
check "it points to evolve-setup for drafting" "$(echo "$OUT1" | grep -c 'draft both from the repository: its evolve-setup skill' || true)" "1"
rm -rf "$T1"

# ── Flags still decide what the pickers used to ask ──
T2=$(mktemp -d)
( cd "$T2" && git init -q )
OUT2=$( cd "$T2" && in_terminal "node '$CLI' init --mode native" 2>&1 ) || true
check "a terminal init with --mode asks for no interval" "$(echo "$OUT2" | grep -c 'How often should evolution run' || true)" "0"
check "--mode is recorded"                               "$(grep -c '"mode": "native"' "$T2/.evolve/config.json" 2>/dev/null || true)" "1"
rm -rf "$T2"

rm -rf "$STUB"
echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
