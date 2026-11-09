#!/bin/bash
# Test (#88): `code-evolve upgrade` replaces the managed engine files with this version's, keeps every
# user-owned file byte-identical, records engineVersion, and refuses to run on a dirty tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
VERSION="$(node -p "require('$ROOT/package.json').version")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
same() { cmp -s "$1" "$2" && echo same || echo different; }

project="$(mktemp -d)"; stub_dir="$(mktemp -d)"
trap 'rm -rf "$project" "$stub_dir"' EXIT
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"; chmod +x "$stub_dir/claude"
# Never touch the real crontab: this stub records each call and holds an empty table.
printf '#!/bin/bash\necho "$*" >> "%s/crontab.calls"\n[ "${1:-}" = "-l" ] && { echo "no crontab for $USER" >&2; exit 1; }\ncat > /dev/null\n' "$stub_dir" > "$stub_dir/crontab"; chmod +x "$stub_dir/crontab"
export PATH="$stub_dir:$PATH"
cd "$project"
git init -q; git config user.email t@example.com; git config user.name t
node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
check "init records the engine version" "$(node -p "require('./.evolve/config.json').engineVersion")" "$VERSION"

# Turn it into an "older install": stale engine files, an unrecorded version, and real user content.
echo "# old engine" >> .evolve/scripts/evolve.sh
echo "# old skill" >> .evolve/skills/prove/SKILL.md
echo "# old constitution" >> .evolve/IDENTITY.md
node -e "const f='.evolve/config.json';const c=require('./'+f);delete c.engineVersion;require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
printf '# Vision\nOur own vision.\n' > .evolve/vision.md
printf '# Spec\n- [ ] our feature\n' > .evolve/spec.md
printf '# Journal\n\n## Day 3 - our entry\n' > .evolve/JOURNAL.md
printf '# Learnings\nour learning\n' > .evolve/LEARNINGS.md
printf '\n## REQ-0001: ours\n- **Status**: open\n' >> .evolve/REQUIREMENTS.md
echo 3 > .evolve/DAY_COUNT
git add -A && git commit -qm "older install"
user_files=(vision.md spec.md JOURNAL.md LEARNINGS.md REQUIREMENTS.md DAY_COUNT .birth_date)
saved="$stub_dir/saved"; mkdir "$saved"
for file in "${user_files[@]}"; do cp ".evolve/$file" "$saved/$file"; done
check "status reports the unrecorded engine version" "$(node "$CLI" status </dev/null | node -p "JSON.parse(require('fs').readFileSync(0)).engineVersion")" "null"

# A dirty tree is refused before anything changes.
echo "work in progress" > notes.txt
status=0; node "$CLI" upgrade </dev/null > "$stub_dir/dirty.log" 2>&1 || status=$?
check "upgrade refuses a dirty tree" "$status" "1"
check "the refusal says why" "$(grep -c 'Commit or stash' "$stub_dir/dirty.log")" "1"
check "a refused upgrade changes nothing" "$(grep -c '# old engine' .evolve/scripts/evolve.sh)" "1"
rm notes.txt

status=0; node "$CLI" upgrade </dev/null > "$stub_dir/upgrade.log" 2>&1 || status=$?
check "upgrade succeeds on a clean tree" "$status" "0"
check "the engine script is replaced" "$(same .evolve/scripts/evolve.sh "$ROOT/templates/scripts/evolve.sh")" "same"
check "runtime skills are replaced" "$(same .evolve/skills/prove/SKILL.md "$ROOT/templates/skills/prove/SKILL.md")" "same"
check "IDENTITY.md is replaced" "$(same .evolve/IDENTITY.md "$ROOT/templates/state/IDENTITY.md")" "same"
for file in "${user_files[@]}"; do
    check "$file is kept byte-identical" "$(same ".evolve/$file" "$saved/$file")" "same"
done
check "the agent choice is kept" "$(node -p "require('./.evolve/config.json').agent")" "claude"
check "engineVersion is recorded" "$(node -p "require('./.evolve/config.json').engineVersion")" "$VERSION"
check "status shows no drift afterwards" "$(node "$CLI" status </dev/null | node -p "JSON.stringify(JSON.parse(require('fs').readFileSync(0)).engineDrift)")" "[]"

# A CI install: the workflow is managed and refreshed, and every config key survives the upgrade.
ci_project="$(mktemp -d)"
(
    cd "$ci_project"
    git init -q; git config user.email t@example.com; git config user.name t
    node "$CLI" init --yes --agent claude --mode ci --every 6 </dev/null >/dev/null 2>&1
    shipped_workflow="$(cat .github/workflows/evolve.yml)"
    echo "# stale workflow" >> .github/workflows/evolve.yml
    node -e "const f='.evolve/config.json';const c=require('./'+f);c.engineVersion='0.0.1';c.model='custom-model';require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
    git add -A && git commit -qm "ci install"
    node -e "const c=require('./.evolve/config.json');delete c.engineVersion;console.log(JSON.stringify(c))" > "$stub_dir/config.before"
    node "$CLI" upgrade </dev/null >/dev/null 2>&1
    node -e "const c=require('./.evolve/config.json');delete c.engineVersion;console.log(JSON.stringify(c))" > "$stub_dir/config.after"
    [ "$(cat .github/workflows/evolve.yml)" = "$shipped_workflow" ] && echo refreshed > "$stub_dir/workflow" || echo stale > "$stub_dir/workflow"
    # `start` saves mode local without removing the CI workflows; they are still ours to refresh.
    node -e "const f='.evolve/config.json';const c=require('./'+f);c.mode='local';require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
    rm .github/workflows/evolve-ci.yml
    echo "# stale workflow" >> .github/workflows/evolve.yml
    git add -A && git commit -qm "switched to local"
    node "$CLI" upgrade </dev/null >/dev/null 2>&1
    [ "$(cat .github/workflows/evolve.yml)" = "$shipped_workflow" ] && echo refreshed > "$stub_dir/workflow.local" || echo stale > "$stub_dir/workflow.local"
    [ -e .github/workflows/evolve-ci.yml ] && echo present > "$stub_dir/ci-workflow.local" || echo absent > "$stub_dir/ci-workflow.local"
    # A symlinked workflow (shared outside the repo) is never written through.
    shared_workflow="$stub_dir/shared-evolve.yml"; cp .github/workflows/evolve.yml "$shared_workflow"; echo "# shared copy" >> "$shared_workflow"
    rm .github/workflows/evolve.yml && ln -s "$shared_workflow" .github/workflows/evolve.yml
    git add -A && git commit -qm "shared workflow" >/dev/null
    node "$CLI" upgrade </dev/null >/dev/null 2>&1
    tail -1 "$shared_workflow" > "$stub_dir/shared-workflow.tail"
    # Same for a symlinked parent directory: .github/workflows itself points outside the repo.
    shared_dir="$stub_dir/shared-workflows"; rm .github/workflows/evolve.yml; mv .github/workflows "$shared_dir"
    cp "$shared_workflow" "$shared_dir/evolve.yml"; ln -s "$shared_dir" .github/workflows
    git add -A && git commit -qm "shared workflows dir" >/dev/null
    node "$CLI" upgrade </dev/null >/dev/null 2>&1
    tail -1 "$shared_dir/evolve.yml" > "$stub_dir/shared-dir.tail"
)
rm -rf "$ci_project"
check "a CI install's evolve workflow is refreshed" "$(cat "$stub_dir/workflow")" "refreshed"
check "workflows installed earlier are refreshed after a switch to local mode" "$(cat "$stub_dir/workflow.local")" "refreshed"
check "local mode creates no workflow that was never installed" "$(cat "$stub_dir/ci-workflow.local")" "absent"
check "a symlinked workflow's target is not overwritten" "$(cat "$stub_dir/shared-workflow.tail")" "# shared copy"
check "a workflow under a symlinked .github/workflows is not overwritten" "$(cat "$stub_dir/shared-dir.tail")" "# shared copy"
check "every other config key survives the upgrade (mode, model, ...)" "$(cat "$stub_dir/config.after")" "$(cat "$stub_dir/config.before")"

# An unfinished cycle would restore the old engine from its snapshot, so upgrade waits for it.
git add -A && git commit -qm "upgraded"
mkdir -p .evolve/run && echo "DAY=3" > .evolve/run/session.env && printf '*\n' > .evolve/run/.gitignore
status=0; node "$CLI" upgrade </dev/null > "$stub_dir/session.log" 2>&1 || status=$?
check "upgrade refuses while an in-session cycle is prepared" "$status" "1"
check "the refusal says to finish or abandon the cycle" "$(grep -c 'evolve.sh finalize' "$stub_dir/session.log")" "1"
rm -rf .evolve/run
lock_file="$(git rev-parse --absolute-git-dir)/code-evolve.lock"
python3 -c "import fcntl,sys,time;f=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_EX);time.sleep(30)" "$lock_file" &
holder=$!
until python3 -c "import fcntl,sys;f=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)" "$lock_file" 2>/dev/null; [ $? -ne 0 ]; do sleep 0.1; done
status=0; node "$CLI" upgrade </dev/null > "$stub_dir/lock.log" 2>&1 || status=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
check "upgrade refuses while a cycle holds the run lock" "$status" "1"
check "the refusal says a cycle is running" "$(grep -c 'cycle is running' "$stub_dir/lock.log")" "1"

# The upgrade holds the run lock itself, so no cycle can start mid-upgrade and restore the old engine.
slow_bin="$stub_dir/slow"; mkdir -p "$slow_bin"
printf '#!/bin/bash\nsleep 2\necho "claude 0.0.0-stub"\n' > "$slow_bin/claude"; chmod +x "$slow_bin/claude"
PATH="$slow_bin:$PATH" node "$CLI" upgrade </dev/null >/dev/null 2>&1 &
upgrader=$!
held=no
for _ in $(seq 1 40); do
    if ! python3 -c "import fcntl,sys;f=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)" "$lock_file" 2>/dev/null; then held=yes; break; fi
    sleep 0.1
done
wait "$upgrader" || true
check "the run lock is held while the upgrade runs" "$held" "yes"
released=no
for _ in $(seq 1 20); do
    if python3 -c "import fcntl,sys;f=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)" "$lock_file" 2>/dev/null; then released=yes; break; fi
    sleep 0.1
done
check "the run lock is released after the upgrade" "$released" "yes"
git add -A && git commit -qm "upgraded again" >/dev/null || true

# A stopped engine stays stopped: `stop` removes schedule.json but keeps mode local.
node -e "const f='.evolve/config.json';const c=require('./'+f);c.mode='local';require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
rm -f .evolve/schedule.json "$stub_dir/crontab.calls"
git add -A && git commit -qm "stopped local engine" >/dev/null
ANTHROPIC_API_KEY=test-key node "$CLI" upgrade </dev/null > "$stub_dir/stopped.log" 2>&1
check "upgrade does not restart a stopped engine" "$(cat "$stub_dir/crontab.calls" 2>/dev/null | grep -cv '^-l' || true)" "0"
check "no schedule is recorded for a stopped engine" "$([ -e .evolve/schedule.json ] && echo present || echo absent)" "absent"
check "upgrade says the schedule stays stopped" "$(grep -c 'code-evolve start' "$stub_dir/stopped.log")" "1"
git add -A && git commit -qm "upgraded stopped engine" >/dev/null || true

# A symlinked IDENTITY.md (a constitution shared outside the repo) is left alone, never written through.
shared="$stub_dir/shared-identity.md"; printf '# Our shared constitution\n' > "$shared"
rm .evolve/IDENTITY.md && ln -s "$shared" .evolve/IDENTITY.md
git add -A && git commit -qm "shared constitution" >/dev/null
node "$CLI" upgrade </dev/null > "$stub_dir/symlink.log" 2>&1
check "a symlinked IDENTITY.md's target is not overwritten" "$(cat "$shared")" "# Our shared constitution"
check "the symlink itself is kept" "$([ -L .evolve/IDENTITY.md ] && echo symlink || echo replaced)" "symlink"
check "upgrade says it left the symlink alone" "$(grep -c 'IDENTITY.md is a symlink' "$stub_dir/symlink.log")" "1"
git add -A && git commit -qm "after symlink upgrade" >/dev/null || true
rm .evolve/IDENTITY.md && ln -s vision.md .evolve/IDENTITY.md
git add -A && git commit -qm "identity linked to vision" >/dev/null
node "$CLI" upgrade </dev/null >/dev/null 2>&1
check "an IDENTITY.md symlinked to a user file inside the project leaves that file alone" "$(same .evolve/vision.md "$saved/vision.md")" "same"
git add -A && git commit -qm "after inside-symlink upgrade" >/dev/null || true

# Engine scripts follow the same rule: a symlinked script (shared outside the repo) is not written through.
shared_script="$stub_dir/shared-detect.sh"; printf '# shared detect_stack\n' > "$shared_script"
rm .evolve/scripts/detect_stack.sh && ln -s "$shared_script" .evolve/scripts/detect_stack.sh
git add -A && git commit -qm "shared script" >/dev/null
node "$CLI" upgrade </dev/null >/dev/null 2>&1
check "a symlinked engine script's target is not overwritten" "$(cat "$shared_script")" "# shared detect_stack"
git add -A && git commit -qm "after shared script upgrade" >/dev/null || true

# A newer engine is never downgraded by an older CLI.
node -e "const f='.evolve/config.json';const c=require('./'+f);c.engineVersion='99.0.0';require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
git add -A && git commit -qm "newer engine"
status=0; node "$CLI" upgrade </dev/null > "$stub_dir/downgrade.log" 2>&1 || status=$?
check "upgrade refuses to downgrade a newer engine" "$status" "1"
check "the refusal points to the latest CLI" "$(grep -c 'code-evolve@latest' "$stub_dir/downgrade.log")" "1"

# A symlinked .evolve (supported by the engine) is still upgraded: the store it points at is the engine.
linked="$(mktemp -d)"
(
    cd "$linked"
    git init -q; git config user.email t@example.com; git config user.name t
    node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
    mv .evolve ../"$(basename "$linked")-store" && ln -s ../"$(basename "$linked")-store" .evolve
    echo "# old engine" >> .evolve/scripts/evolve.sh
    git add -A && git commit -qm "symlinked .evolve" >/dev/null
    node "$CLI" upgrade </dev/null >/dev/null 2>&1
    cmp -s .evolve/scripts/evolve.sh "$ROOT/templates/scripts/evolve.sh" && echo upgraded > "$stub_dir/linked-evolve" || echo skipped > "$stub_dir/linked-evolve"
)
rm -rf "$linked" "$linked-store"
check "a symlinked .evolve is still upgraded" "$(cat "$stub_dir/linked-evolve")" "upgraded"

plain="$(mktemp -d)"
status=0; (cd "$plain" && node "$CLI" upgrade </dev/null >/dev/null 2>&1) || status=$?
rm -rf "$plain"
check "upgrade outside an install exits 1" "$status" "1"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
