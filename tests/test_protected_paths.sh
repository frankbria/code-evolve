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

# Sixth project (#109): the engine is run by hand with an absolute EVOLVE_DIR.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e .evolve/.stub-ran ] && exit 0
touch .evolve/.stub-ran
echo "be evil" >> .evolve/IDENTITY.md
printf '#!/bin/bash\necho planted\n' > .evolve/scripts/planted.sh
STUB
sixth_dir="$(mktemp -d)"
cd "$sixth_dir"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "sixth init failed"
printf '.evolve/.stub-ran\n' >> .gitignore
git add -A && git commit -qm "baseline"
identity_before=$(cat .evolve/IDENTITY.md)
ANTHROPIC_API_KEY=k EVOLVE_DIR="$PWD/.evolve" PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh prepare > "$stub_dir/engine6-prepare.log" 2>&1 || true
grep -qx 'EVOLVE_DIR=.evolve' .evolve/run/session.env 2>/dev/null && [ -s .evolve/run/protected/manifest ] \
    && ok "prepare with an absolute EVOLVE_DIR records the relative path and a non-empty snapshot" \
    || bad "prepare with an absolute EVOLVE_DIR: $(grep EVOLVE_DIR .evolve/run/session.env 2>&1; tail -2 "$stub_dir/engine6-prepare.log")"
[ -z "$(git status --porcelain --ignored | grep -v '\.evolve/' || true)" ] \
    && ok "prepare with an absolute EVOLVE_DIR writes nothing outside .evolve" \
    || bad "stray files after prepare: $(git status --porcelain --ignored | grep -v '\.evolve/')"
rm -rf .evolve/run
git add -A && git commit -qm "state after prepare" >/dev/null 2>&1 || true
ANTHROPIC_API_KEY=k EVOLVE_DIR="$PWD/.evolve" PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine6.log" 2>&1 || true
[ -e .evolve/.stub-ran ] && [ "$(cat .evolve/IDENTITY.md)" = "$identity_before" ] \
    && ok "absolute EVOLVE_DIR: an edit to IDENTITY.md is undone" \
    || bad "absolute EVOLVE_DIR: IDENTITY.md not restored (agent ran: $([ -e .evolve/.stub-ran ] && echo yes || echo no))"
[ ! -e .evolve/scripts/planted.sh ] \
    && ok "absolute EVOLVE_DIR: a planted script is removed" || bad "absolute EVOLVE_DIR: planted.sh survived"
cd / && rm -rf "$sixth_dir"

# Seventh project (#109): the user keeps .evolve/skills as a symlink to a shared store. The
# agent edits a skill through the link, plants a file in the store, then repoints the link.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e "$STUB_MARKER" ] && exit 0
touch "$STUB_MARKER"
echo "be evil" >> .evolve/skills/plan/SKILL.md
echo "planted" > .evolve/skills/planted.md
cp -r ../shared-skills ../evil-skills && echo "more evil" >> ../evil-skills/evolve/SKILL.md
rm .evolve/skills && ln -s ../../evil-skills .evolve/skills
STUB
seventh_root="$(mktemp -d)"
mkdir -p "$seventh_root/project"
cd "$seventh_root/project"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "seventh init failed"
mv .evolve/skills ../shared-skills && ln -s ../../shared-skills .evolve/skills
git add -A && git commit -qm "baseline, skills symlinked to a shared store"
skill_before=$(cat ../shared-skills/plan/SKILL.md)
STUB_MARKER="$seventh_root/stub-ran" ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine7.log" 2>&1 || true
[ -e "$seventh_root/stub-ran" ] && [ "$(readlink .evolve/skills)" = "../../shared-skills" ] \
    && ok "a user's skills symlink repointed by the agent gets its original target back" \
    || bad ".evolve/skills is now '$(readlink .evolve/skills 2>&1)': $(tail -2 "$stub_dir/engine7.log")"
[ "$(cat ../shared-skills/plan/SKILL.md)" = "$skill_before" ] \
    && ok "a skill edited through the user's symlink is restored in the store" \
    || bad "the shared store's plan skill is still tampered"
[ ! -e ../shared-skills/planted.md ] \
    && ok "a file planted behind the user's symlink is removed" || bad "planted.md survived in the shared store"
cd / && rm -rf "$seventh_root"

# Eighth project (#109): one skill is a user symlink to a directory elsewhere, and the agent
# adds a directory symlink of its own next to it.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e "$STUB_MARKER" ] && exit 0
touch "$STUB_MARKER"
echo "be evil" >> .evolve/skills/shared/SKILL.md
ln -s ../../../outside .evolve/skills/agent-link
rm .evolve/skills/empty-link
rm .evolve/skills/loop
git rm -q --cached .evolve/skills/shared && echo ".evolve/skills/shared" >> .gitignore
git add .gitignore && git commit -qm "untrack and ignore the user's skill symlink"
STUB
eighth_root="$(mktemp -d)"
mkdir -p "$eighth_root/project" "$eighth_root/outside" "$eighth_root/shared-skill" "$eighth_root/empty"
echo "keep me" > "$eighth_root/outside/keep.txt"
echo "# shared skill" > "$eighth_root/shared-skill/SKILL.md"
cd "$eighth_root/project"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "eighth init failed"
ln -s ../../../shared-skill .evolve/skills/shared
ln -s ../../../empty .evolve/skills/empty-link
ln -s . .evolve/skills/loop
git add -A && git commit -qm "baseline, one skill symlinked"
STUB_MARKER="$eighth_root/stub-ran" ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine8.log" 2>&1 || true
[ -e "$eighth_root/stub-ran" ] && [ "$(cat ../shared-skill/SKILL.md)" = "# shared skill" ] \
    && [ "$(readlink .evolve/skills/shared)" = "../../../shared-skill" ] \
    && ok "a file behind a user's symlinked skill directory is restored and the link kept" \
    || bad "symlinked skill not restored: $(tail -1 ../shared-skill/SKILL.md)"
[ "$(git ls-tree HEAD .evolve/skills/shared | cut -d' ' -f1)" = "120000" ] \
    && ok "a user's directory symlink the agent untracked and gitignored is still in the final commit" \
    || bad "the skill symlink is missing from HEAD: $(git ls-tree HEAD .evolve/skills/shared)"
[ ! -e .evolve/skills/agent-link ] && [ ! -L .evolve/skills/agent-link ] \
    && ok "a directory symlink the agent adds under a protected path is removed" || bad "agent-link survived"
[ "$(cat ../outside/keep.txt 2>/dev/null)" = "keep me" ] \
    && ok "removing the agent's symlink leaves the directory it pointed at alone" || bad "outside/keep.txt was lost"
[ "$(readlink .evolve/skills/empty-link 2>/dev/null)" = "../../../empty" ] \
    && ok "a user's symlink to an empty directory deleted by the agent is put back" || bad "empty-link not restored"
[ "$(readlink .evolve/skills/loop 2>/dev/null)" = "." ] && grep -q "=== Day 0 complete ===" "$stub_dir/engine8.log" \
    && ok "a symlink that loops back on its own directory does not stop the session and is put back" \
    || bad "loop link: '$(readlink .evolve/skills/loop 2>&1)': $(tail -2 "$stub_dir/engine8.log")"
cd / && rm -rf "$eighth_root"

# Ninth project (#109): the engine directory lives outside the project, named by an absolute path.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e "$STUB_MARKER" ] && exit 0
touch "$STUB_MARKER"
echo "be evil" >> "$EVOLVE_DIR/IDENTITY.md"
printf '#!/bin/bash\necho planted\n' > "$EVOLVE_DIR/scripts/planted.sh"
STUB
ninth_root="$(mktemp -d)"
mkdir -p "$ninth_root/project"
cd "$ninth_root/project"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "ninth init failed"
mv .evolve ../store
git add -A && git commit -qm "baseline, engine directory outside the project"
identity_before=$(cat ../store/IDENTITY.md)
ANTHROPIC_API_KEY=k EVOLVE_DIR="$ninth_root/store" PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash ../store/scripts/evolve.sh prepare > "$stub_dir/engine9-prepare.log" 2>&1 || true
[ -s ../store/run/protected/manifest ] && [ -z "$(git status --porcelain --ignored)" ] \
    && ok "prepare with an outside EVOLVE_DIR keeps its snapshot there and adds nothing to the project" \
    || bad "outside prepare: $(git status --porcelain --ignored; tail -2 "$stub_dir/engine9-prepare.log")"
rm -rf ../store/run
STUB_MARKER="$ninth_root/stub-ran" ANTHROPIC_API_KEY=k EVOLVE_DIR="$ninth_root/store" PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash ../store/scripts/evolve.sh > "$stub_dir/engine9.log" 2>&1 || true
[ -e "$ninth_root/stub-ran" ] && [ "$(cat ../store/IDENTITY.md)" = "$identity_before" ] && [ ! -e ../store/scripts/planted.sh ] \
    && ok "an absolute EVOLVE_DIR outside the project is guarded in place" \
    || bad "outside EVOLVE_DIR not guarded: $(tail -2 "$stub_dir/engine9.log")"
cd / && rm -rf "$ninth_root"

# Tenth project (#109): the agent leaves the user's skills symlink alone but swaps the directory
# it points at for a symlink to an unrelated directory. Nothing there may be written or removed.
cat > "$stub_dir/claude" <<'STUB'
#!/bin/bash
[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
[ -e "$STUB_MARKER" ] && exit 0
touch "$STUB_MARKER"
mv ../shared-skills ../moved-skills && ln -s victim ../shared-skills
STUB
tenth_root="$(mktemp -d)"
mkdir -p "$tenth_root/project" "$tenth_root/victim"
echo "keep me" > "$tenth_root/victim/canary.txt"
cd "$tenth_root/project"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "tenth init failed"
mv .evolve/skills ../shared-skills && ln -s ../../shared-skills .evolve/skills
git add -A && git commit -qm "baseline, skills symlinked to a shared store"
STUB_MARKER="$tenth_root/stub-ran" ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine10.log" 2>&1 || true
[ -e "$tenth_root/stub-ran" ] && [ "$(cat ../victim/canary.txt 2>/dev/null)" = "keep me" ] && [ "$(ls ../victim)" = "canary.txt" ] \
    && ok "a swapped link target: nothing is deleted from or written to the directory it now leads to" \
    || bad "victim directory changed: $(ls ../victim 2>&1 | tr '\n' ' ')"
grep -q "WARNING: .evolve/skills no longer leads to" "$stub_dir/engine10.log" \
    && ok "a swapped link target is reported" || bad "no warning about the swapped target: $(tail -3 "$stub_dir/engine10.log")"
cd / && rm -rf "$tenth_root"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
