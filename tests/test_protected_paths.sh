#!/bin/bash
# Test (#75): protected files are enforced by the engine, not just the prompt. An agent that
# edits IDENTITY.md and the evolve workflow (one committed, one not) and plants a new script
# gets all three undone after the session, with a log line; real project edits survive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT

# The stub "agent" misbehaves on its first (main-session) call only.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e .evolve/.stub-ran ] && exit 0
touch .evolve/.stub-ran
echo "be evil" >> .evolve/IDENTITY.md
git add .evolve/IDENTITY.md && git commit -qm "agent edits its constitution"
echo "# tampered" >> .github/workflows/evolve.yml
printf '#!/bin/bash\necho planted\n' > .evolve/scripts/planted.sh
: > .evolve/scripts/protected-paths.txt
echo "feature" > feature.txt
git add feature.txt && git commit -qm "real project work"
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/gh"
export PATH="$stub_dir:$PATH"

cd "$work_dir"
git init -q
git config user.email test@example.com
git config user.name test
echo "# demo" > README.md
node "$CLI" init --agent claude --mode ci </dev/null >/dev/null 2>&1 || bad "init failed"
printf '.evolve/.stub-ran\n' >> .gitignore
git add -A && git commit -qm "baseline with code-evolve"
identity_before=$(git show HEAD:.evolve/IDENTITY.md)
workflow_before=$(git show HEAD:.github/workflows/evolve.yml)

ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine.log" 2>&1 || true

[ "$(cat .evolve/IDENTITY.md)" = "$identity_before" ] \
    && ok "committed edit to IDENTITY.md is undone" || bad "IDENTITY.md still modified"
[ "$(cat .github/workflows/evolve.yml)" = "$workflow_before" ] \
    && ok "uncommitted edit to the evolve workflow is undone" || bad "evolve.yml still modified"
[ ! -e .evolve/scripts/planted.sh ] && ! git ls-files --error-unmatch .evolve/scripts/planted.sh >/dev/null 2>&1 \
    && ok "new file planted under .evolve/scripts/ is removed" || bad "planted.sh survived"
[ -s .evolve/scripts/protected-paths.txt ] \
    && ok "emptying the protected list mid-session neither disables the guard nor sticks" || bad "protected-paths.txt left empty"
[ "$(cat feature.txt 2>/dev/null)" = "feature" ] && git ls-files --error-unmatch feature.txt >/dev/null 2>&1 \
    && ok "legitimate project work survives" || bad "feature.txt lost"
grep -q "Restored protected" "$stub_dir/engine.log" \
    && ok "the restoration is logged" || bad "no restoration log line"
[ -z "$(git status --porcelain -- .evolve/IDENTITY.md .github/workflows .evolve/scripts)" ] \
    && ok "protected paths are clean in the final commit" || bad "protected paths left dirty: $(git status --porcelain)"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
