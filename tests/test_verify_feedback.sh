#!/bin/bash
# Test (#92): each cycle records its own verification in .evolve/LAST_VERIFY.md (committed by the
# wrap-up), and the next session's prompt carries it. This closes the CI feedback loop on GitHub
# Actions, where pushes made with GITHUB_TOKEN start no other workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then echo "  ok: $3"; pass=$((pass+1)); else echo "  FAIL: $3 (missing '$2')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"; mkdir -p "$stub_dir"
# claude stub: saves each prompt it is given (numbered), changes nothing.
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
n=\$(ls "$work"/prompt.* 2>/dev/null | wc -l)
cat > "$work/prompt.\$((n + 1))"
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir"/*
export PATH="$stub_dir:$PATH"

project="$work/project"; mkdir -p "$project"; cd "$project"
git init -q; git config user.email t@example.com; git config user.name t
printf '{"name":"demo","scripts":{"test":"echo FAILING-TEST-MARKER >&2; exit 1"}}\n' > package.json
node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
git add -A && git commit -qm "baseline"
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }

# Cycle 1: the tests fail, the fix attempts don't help, the session is reverted.
engine > "$work/cycle1.log" 2>&1 || true
first_prompt="$work/prompt.1"
check "the first session's prompt has no previous verification" "$(grep -c "PREVIOUS SESSION VERIFICATION" "$first_prompt")" "0"
contains .evolve/LAST_VERIFY.md "verification failed" "the failed verification is recorded"
contains .evolve/LAST_VERIFY.md "FAILING-TEST-MARKER" "with the failing output"
check "the record is committed, so it reaches the next Actions run" "$(git status --porcelain -- .evolve/LAST_VERIFY.md)" ""
check "and is in the history" "$(git log --oneline -- .evolve/LAST_VERIFY.md | wc -l | tr -d ' ')" "1"

# Cycle 2: its prompt carries cycle 1's failure.
rm -f "$work"/prompt.*
engine > "$work/cycle2.log" 2>&1 || true
contains "$work/prompt.1" "PREVIOUS SESSION VERIFICATION" "the next session's prompt has the previous verification"
contains "$work/prompt.1" "FAILING-TEST-MARKER" "including the previous session's errors"

# A passing session records that too.
printf '{"name":"demo","scripts":{"test":"true"}}\n' > package.json
git add -A && git commit -qm "tests pass now"
engine > "$work/cycle3.log" 2>&1 || true
contains .evolve/LAST_VERIFY.md "verification passed" "a passing verification is recorded"
rm -f "$work"/prompt.*
engine > "$work/cycle4.log" 2>&1 || true
contains "$work/prompt.1" "verification passed" "and reaches the next session"

# The workflow can read CI runs, and the stale java comments are gone.
check "evolve.yml grants actions: read" "$(grep -c '^  actions: read' "$ROOT/templates/workflows/evolve.yml")" "1"
check "no stale 'java not emitted' comments remain" "$(grep -c 'not yet emitted by detect_stack' "$ROOT"/templates/workflows/*.yml | awk -F: '{s+=$2} END {print s}')" "0"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
