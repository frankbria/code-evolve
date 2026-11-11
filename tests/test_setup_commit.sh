#!/bin/bash
# Test (#134): init leaves its files uncommitted, and the first session's `git add -A` used to put
# them into the first feature commit. The engine commits a new install on its own first, limited to
# what init wrote, so the feature commit holds only the feature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_root="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_root"' EXIT
# The agent stub does what the cycle prompt asks: one feature, committed with `git add -A`.
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat >/dev/null
# The engine calls the agent again later in the cycle (the journal); the feature is built once.
[ -e feature.txt ] && exit 0
echo "feature" > feature.txt
git add -A && git commit -qm "Day 0: add the feature"
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/gh"
export PATH="$stub_dir:$PATH"
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }
SETUP_SUBJECT="code-evolve: add the engine and setup files"
setup_commits() { git log --format=%s | grep -cxF "$SETUP_SUBJECT" || true; }
committed_files() { git show --format= --name-only "$1" | sort; }

new_repository() { # <name>: a repository with one commit
    mkdir "$work_root/$1" && cd "$work_root/$1"
    git init -q
    git config user.email test@example.com
    git config user.name test
    printf '{"name":"demo","scripts":{"build":"true","test":"true"}}\n' > package.json
    echo "# demo" > README.md
    git add -A && git commit -qm "baseline"
}
install() { node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed in $PWD"; }
new_project() { new_repository "$1"; install; } # nothing of the install is committed

# ── prepare (the in-session cycle) ──
new_project prepared
echo "edited by the user" >> README.md
echo "mine" > notes.txt
mkdir -p .claude/skills/mine && printf -- '---\nname: mine\ndescription: the user'"'"'s own skill\n---\n' > .claude/skills/mine/SKILL.md
baseline_sha=$(git rev-parse HEAD)
engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed: $(tail -3 "$stub_dir/prepare.log")"

[ "$(git log -1 --format=%s)" = "$SETUP_SUBJECT" ] && [ "$(git rev-parse HEAD~1)" = "$baseline_sha" ] \
    && ok "prepare commits a new install on its own" || bad "HEAD is '$(git log -1 --format=%s)'"
setup_files=$(committed_files HEAD)
for expected in .evolve/scripts/evolve.sh .evolve/spec.md .evolve/config.json .claude/skills/evolve-run/SKILL.md \
    .agents/skills/evolve-setup/SKILL.md AGENTS.md .gitignore; do
    grep -qxF "$expected" <<<"$setup_files" || bad "the setup commit lacks $expected"
done
grep -qxE 'README\.md|notes\.txt|package\.json|\.claude/skills/mine/SKILL\.md|\.evolve/run/.*' <<<"$setup_files" \
    && bad "the setup commit took files init did not write: $(grep -xE 'README\.md|notes\.txt|package\.json|\.claude/skills/mine/SKILL\.md|\.evolve/run/.*' <<<"$setup_files" | tr '\n' ' ')" \
    || ok "the setup commit holds only what init wrote"
status_now=$(git status --porcelain)
grep -qx " M README.md" <<<"$status_now" && grep -qx "?? notes.txt" <<<"$status_now" && grep -qxF "?? .claude/skills/mine/" <<<"$status_now" \
    && ok "the user's own uncommitted work is left as it was" || bad "status after prepare: $status_now"
[ "$(sed -n 's/^SESSION_START_SHA=//p' .evolve/run/session.env)" = "$(git rev-parse HEAD)" ] \
    && ok "the session baseline is the setup commit, so a revert keeps the install" || bad "baseline is not the setup commit"
grep -q "Committed the code-evolve install on its own" "$stub_dir/prepare.log" \
    && ok "prepare says that it made the commit" || bad "no line about the setup commit: $(tail -5 "$stub_dir/prepare.log")"

# ── a headless cycle ──
new_project cycle
engine > "$stub_dir/cycle.log" 2>&1 || bad "cycle failed: $(tail -3 "$stub_dir/cycle.log")"
feature_sha=$(git log --format=%H --grep="add the feature" | head -1)
[ -n "$feature_sha" ] && [ "$(committed_files "$feature_sha")" = "feature.txt" ] \
    && ok "the first feature commit holds only the feature" || bad "feature commit files: $(committed_files "${feature_sha:-HEAD}" | tr '\n' ' ')"
[ "$(setup_commits)" = "1" ] && [ "$(git log --format=%s "$feature_sha~1" -1)" = "$SETUP_SUBJECT" ] \
    && ok "the setup commit comes right before it" || bad "log: $(git log --format=%s | tr '\n' '|')"
echo "second" > .evolve/user-note.md
engine > "$stub_dir/cycle2.log" 2>&1 || bad "second cycle failed: $(tail -3 "$stub_dir/cycle2.log")"
[ "$(setup_commits)" = "1" ] && ok "a later cycle makes no second setup commit" || bad "setup commits after two cycles: $(setup_commits)"

# ── nothing to separate: a repository with no commit yet, and an install the user ignores ──
mkdir "$work_root/greenfield" && cd "$work_root/greenfield"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "greenfield: init failed"
sed -i.bak 's/<!--.*-->//' .evolve/spec.md .evolve/vision.md && rm -f .evolve/*.bak
printf -- '- [ ] one feature\n' >> .evolve/spec.md; echo "a vision" >> .evolve/vision.md
engine prepare > "$stub_dir/greenfield.log" 2>&1 || bad "greenfield prepare failed: $(tail -3 "$stub_dir/greenfield.log")"
[ "$(setup_commits)" = "0" ] && [ "$(git log --format=%s | tail -1)" = "code-evolve: initial commit" ] \
    && ok "a repository without commits keeps its single initial commit" || bad "greenfield log: $(git log --format=%s | tr '\n' '|')"

new_project ignored
git reset -q --hard && git clean -fdxq
echo ".evolve/" > .gitignore && git add .gitignore && git commit -qm "ignore the engine"
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "ignored: init failed"
engine prepare > "$stub_dir/ignored.log" 2>&1 || bad "ignored prepare failed: $(tail -3 "$stub_dir/ignored.log")"
[ "$(setup_commits)" = "0" ] && ok "an install the user keeps out of git is not committed" || bad "ignored install was committed: $(committed_files HEAD | head -5 | tr '\n' ' ')"

# A commit that cannot be made (a failing pre-commit hook) is reported and does not stop the cycle.
new_project hook
printf '#!/bin/sh\n[ -f feature.txt ] || exit 1\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
hook_status=0; engine prepare > "$stub_dir/hook.log" 2>&1 || hook_status=$?
[ "$hook_status" -eq 0 ] && grep -q "WARNING: could not commit the code-evolve install on its own" "$stub_dir/hook.log" && grep -q "  git said: " "$stub_dir/hook.log" && [ "$(setup_commits)" = "0" ] \
    && ok "a refused setup commit is a warning, and prepare still succeeds" || bad "hook: exit $hook_status: $(tail -3 "$stub_dir/hook.log")"

# An install the user staged (`git add -A`) without committing is still a new install, and what
# else they staged stays staged.
new_project staged
echo "mine" > notes.txt
git add -A
engine prepare > "$stub_dir/staged.log" 2>&1 || bad "staged prepare failed: $(tail -3 "$stub_dir/staged.log")"
[ "$(setup_commits)" = "1" ] && ! committed_files HEAD | grep -qx "notes.txt" && [ "$(git status --porcelain -- notes.txt)" = "A  notes.txt" ] \
    && ok "a staged install is committed on its own, and the user's staged file stays staged" \
    || bad "staged: commits $(setup_commits), notes.txt: '$(git status --porcelain -- notes.txt)'"

# init adds a section to AGENTS.md and lines to .gitignore. A file init alone changed belongs to
# the install; one that also has the user's uncommitted edits is left to the user.
new_repository shared_files
printf '# Rules\n\nBe kind.\n' > AGENTS.md
echo "node_modules/" > .gitignore
git add -A && git commit -qm "instructions and ignore rules"
echo "A rule I have not committed yet." >> AGENTS.md
install
engine prepare > "$stub_dir/shared.log" 2>&1 || bad "shared-files prepare failed: $(tail -3 "$stub_dir/shared.log")"
shared_files=$(committed_files HEAD)
grep -qx ".gitignore" <<<"$shared_files" && git show HEAD:.gitignore | grep -qx "node_modules/" && git show HEAD:.gitignore | grep -qxF ".evolve/.env" \
    && ok "a tracked .gitignore that only init changed is in the setup commit" || bad "setup commit files: $(tr '\n' ' ' <<<"$shared_files")"
! grep -qx "AGENTS.md" <<<"$shared_files" && [ "$(git status --porcelain -- AGENTS.md)" = " M AGENTS.md" ] \
    && grep -q "Left AGENTS.md out of the install commit" "$stub_dir/shared.log" \
    && ok "an AGENTS.md with the user's own uncommitted edit is left out, and prepare says so" \
    || bad "AGENTS.md: in commit=$(grep -cx AGENTS.md <<<"$shared_files"), status '$(git status --porcelain -- AGENTS.md)'"

new_repository tracked_instructions
printf '# Rules\n\nBe kind.\n' > AGENTS.md
git add -A && git commit -qm "instructions"
install
engine prepare > "$stub_dir/tracked.log" 2>&1 || bad "tracked-instructions prepare failed: $(tail -3 "$stub_dir/tracked.log")"
committed_files HEAD | grep -qx "AGENTS.md" && git show HEAD:AGENTS.md | grep -qx "Be kind." && git show HEAD:AGENTS.md | grep -qF "code-evolve:begin" \
    && ok "a tracked AGENTS.md that only init changed is in the setup commit" || bad "AGENTS.md was not committed with the install"

# A merge the user has not finished is left alone: adding a conflicted file would mark it resolved.
new_repository merging
printf '# Rules\n' > AGENTS.md && git add -A && git commit -qm "instructions"
git checkout -q -b other && echo "theirs" >> AGENTS.md && git commit -qam "theirs"
git checkout -q - && echo "ours" >> AGENTS.md && git commit -qam "ours"
git merge other >/dev/null 2>&1 || true
install
engine prepare > "$stub_dir/merging.log" 2>&1 || true
[ "$(setup_commits)" = "0" ] && [ "$(git status --porcelain -- AGENTS.md)" = "UU AGENTS.md" ] \
    && [ -z "$(git diff --cached --name-only -- .evolve)" ] && ! grep -q "could not commit the code-evolve install" "$stub_dir/merging.log" \
    && ok "an unfinished merge is left alone: nothing staged or committed, the conflict stays unresolved" \
    || bad "merging: commits $(setup_commits), AGENTS.md '$(git status --porcelain -- AGENTS.md)'"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
