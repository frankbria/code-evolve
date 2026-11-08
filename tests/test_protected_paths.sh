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
git rm -q --cached .github/workflows/evolve-ci.yml && echo ".github/workflows/evolve-ci.yml" >> .gitignore
git commit -qm "untrack and ignore the CI workflow"
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
git cat-file -e HEAD:.github/workflows/evolve-ci.yml 2>/dev/null \
    && ok "a protected file the agent untracked and gitignored is still in the final commit" \
    || bad "evolve-ci.yml is missing from HEAD"
grep -q "Restored protected" "$stub_dir/engine.log" \
    && ok "the restoration is logged" || bad "no restoration log line"
[ -z "$(git status --porcelain -- .evolve/IDENTITY.md .github/workflows .evolve/scripts)" ] \
    && ok "protected paths are clean in the final commit" || bad "protected paths left dirty: $(git status --porcelain)"

# Second project: .evolve/ is gitignored, the install predates protected-paths.txt, and the
# agent swaps IDENTITY.md for a symlink to a project file and edits the ignored orchestrator.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e .evolve/.stub-ran ] && exit 0
touch .evolve/.stub-ran
rm .evolve/IDENTITY.md && ln -s ../decoy.txt .evolve/IDENTITY.md
echo "# tampered" >> .evolve/scripts/evolve.sh
STUB
second_dir="$(mktemp -d)"
cd "$second_dir"
git init -q
git config user.email test@example.com
git config user.name test
echo "decoy" > decoy.txt
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "second init failed"
rm .evolve/scripts/protected-paths.txt
printf '.evolve/\n' >> .gitignore
git add -A && git commit -qm "baseline, .evolve ignored"
identity_before=$(cat .evolve/IDENTITY.md)
engine_before=$(cat .evolve/scripts/evolve.sh)
ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine2.log" 2>&1 || true
[ ! -L .evolve/IDENTITY.md ] && [ "$(cat .evolve/IDENTITY.md)" = "$identity_before" ] \
    && ok "IDENTITY.md swapped for a symlink is restored as a real file" || bad "IDENTITY.md not restored (symlink: $([ -L .evolve/IDENTITY.md ] && echo yes || echo no))"
[ "$(cat decoy.txt)" = "decoy" ] \
    && ok "restoring did not write through the symlink into decoy.txt" || bad "decoy.txt was overwritten"
[ "$(cat .evolve/scripts/evolve.sh)" = "$engine_before" ] \
    && ok "gitignored, list-less install: tampered evolve.sh is restored" || bad "ignored evolve.sh still tampered"
cd / && rm -rf "$second_dir"

# Third project (CI mode): the agent turns .github/workflows into a symlink to a directory
# outside the protected tree, clears evolve.sh's exec bit, and deletes a protected skill that
# was a symlink at session start.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e .evolve/.stub-ran ] && exit 0
touch .evolve/.stub-ran
mkdir -p outside && cp .github/workflows/evolve.yml outside/evolve.yml && echo "# tampered" >> outside/evolve.yml
rm -rf .github/workflows && ln -s ../outside .github/workflows
chmod -x .evolve/scripts/evolve.sh
rm .evolve/skills/linked-skill
STUB
third_dir="$(mktemp -d)"
cd "$third_dir"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude --mode ci </dev/null >/dev/null 2>&1 || bad "third init failed"
printf '.evolve/.stub-ran\n' >> .gitignore
ln -s plan .evolve/skills/linked-skill
git add -A && git commit -qm "baseline, CI mode"
workflow_before=$(cat .github/workflows/evolve.yml)
ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine3.log" 2>&1 || true
[ ! -L .github/workflows ] && [ -d .github/workflows ] && [ "$(cat .github/workflows/evolve.yml)" = "$workflow_before" ] \
    && ok "a workflows dir swapped for a symlink is replaced and evolve.yml restored" \
    || bad "workflows dir symlink not undone: $(ls -la .github 2>&1 | tail -2)"
grep -q "# tampered" outside/evolve.yml 2>/dev/null \
    && ok "restoring did not write through the directory symlink into outside/" || bad "outside/evolve.yml was overwritten"
[ -x .evolve/scripts/evolve.sh ] && ok "a cleared exec bit on evolve.sh is restored" || bad "evolve.sh lost its exec bit"
[ -L .evolve/skills/linked-skill ] && [ "$(readlink .evolve/skills/linked-skill)" = "plan" ] \
    && ok "a protected symlink deleted by the agent is restored as a symlink" || bad "linked-skill not restored"
cd / && rm -rf "$third_dir"

# Fourth project: the agent adds a legitimate-looking npm test script that tampers with
# IDENTITY.md when the engine runs verification (after the agent-call restores), and replaces
# the protected skills directory with a regular file.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e .evolve/.stub-ran ] && exit 0
touch .evolve/.stub-ran
printf '{"name":"demo","version":"1.0.0","scripts":{"build":"true","test":"echo tampered-by-test >> .evolve/IDENTITY.md"}}\n' > package.json
git add package.json && git commit -qm "add tests"
rm -rf .evolve/skills && echo "not a dir" > .evolve/skills
# Write this session's journal entry so the engine skips its journal call (and the restore after it).
printf '## Day 0 — %s — work\n\n' "$(date +%H:%M)" >> .evolve/JOURNAL.md
STUB
fourth_dir="$(mktemp -d)"
cd "$fourth_dir"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "fourth init failed"
printf '.evolve/.stub-ran\n' >> .gitignore
git add -A && git commit -qm "baseline"
identity_before=$(cat .evolve/IDENTITY.md)
skill_before=$(cat .evolve/skills/plan/SKILL.md)
ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine4.log" 2>&1 || true
[ "$(git show HEAD:.evolve/IDENTITY.md)" = "$identity_before" ] \
    && ok "tampering by a test script during verification never reaches the commit" \
    || bad "committed IDENTITY.md was tampered: $(git show HEAD:.evolve/IDENTITY.md | tail -1)"
[ -d .evolve/skills ] && [ "$(cat .evolve/skills/plan/SKILL.md 2>/dev/null)" = "$skill_before" ] \
    && ok "a protected dir replaced by a regular file is rebuilt" || bad "skills dir not rebuilt: $(ls -la .evolve | grep skills)"
cd / && rm -rf "$fourth_dir"

# Fifth project: the user keeps .evolve as a symlink into a store; the agent repoints it.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e "$STUB_MARKER" ] && exit 0
touch "$STUB_MARKER"
cp -r "$(readlink .evolve)" ../evil-store && echo "be evil" >> ../evil-store/IDENTITY.md
rm .evolve && ln -s ../evil-store .evolve
STUB
fifth_root="$(mktemp -d)"
mkdir -p "$fifth_root/project"
cd "$fifth_root/project"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "fifth init failed"
mv .evolve ../store && ln -s ../store .evolve
git add -A && git commit -qm "baseline, .evolve symlinked"
STUB_MARKER="$fifth_root/stub-ran" ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine5.log" 2>&1 || true
[ "$(readlink .evolve)" = "../store" ] && ! grep -q "be evil" .evolve/IDENTITY.md \
    && ok "a user's .evolve symlink repointed by the agent gets its original target back" \
    || bad ".evolve now points at '$(readlink .evolve)': $(tail -2 "$stub_dir/engine5.log")"
cd / && rm -rf "$fifth_root"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
