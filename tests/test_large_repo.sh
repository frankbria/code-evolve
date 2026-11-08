#!/bin/bash
# Test (#73): a cycle on a repo with thousands of files must reach the agent (the tree
# snapshot used to die of SIGPIPE under pipefail), list 100 files plus the true total, and
# keep its scratch files in a private per-run directory instead of fixed /tmp paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap '[ -n "${KEEP_TEST_DIRS:-}" ] || rm -rf "$stub_dir" "$work_dir"' EXIT

# claude stub keeps the first (main-session) prompt; gh fails so no network is used.
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
if [ -e "$stub_dir/prompt.txt" ]; then cat >/dev/null; else cat > "$stub_dir/prompt.txt"; fi
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/gh"
export PATH="$stub_dir:$PATH"

cd "$work_dir"
git init -q
git config user.email test@example.com
git config user.name test
mkdir -p src
for index in $(seq 1 5000); do : > "src/file_$index.txt"; done
git add -A && git commit -qm "5000 files"
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed"

engine_status=0
ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine.log" 2>&1 || engine_status=$?

[ -s "$stub_dir/prompt.txt" ] \
    && ok "cycle on a 5000-file repo reached the agent" \
    || bad "agent never ran (exit $engine_status): $(tail -3 "$stub_dir/engine.log")"
listed=$(grep -c '^\./' "$stub_dir/prompt.txt" 2>/dev/null || true)
[ "$listed" = "100" ] && ok "prompt lists 100 files" || bad "prompt lists $listed files"
# 5000 source files plus the handful init and git add (README, .gitignore, ...).
grep -qE "\(50[0-9][0-9] files, first 100 shown\)" "$stub_dir/prompt.txt" 2>/dev/null \
    && ok "prompt states the true total" || bad "prompt header: $(grep 'Files in' "$stub_dir/prompt.txt" 2>/dev/null)"
grep -qE "50[0-9][0-9] files, first 100 shown in" "$stub_dir/engine.log" \
    && ok "engine log reports the true total" || bad "log: $(grep 'first 100\|files in' "$stub_dir/engine.log")"

! grep -nE '/tmp/' "$ROOT/templates/scripts/evolve.sh" >/dev/null \
    && ok "evolve.sh uses no fixed /tmp paths" \
    || bad "fixed /tmp paths remain: $(grep -nE '/tmp/' "$ROOT/templates/scripts/evolve.sh" | head -3)"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
