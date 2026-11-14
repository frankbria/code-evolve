#!/bin/bash
# Test (#145): the edges of the sync with the remote. A cycle starts from its upstream's state; the
# sync follows the push URL; a push that leaves the session's branch out is "not pushed"; issue
# comments cite the pushed commit; and the sync copes with a merge commit, a rebase git refuses,
# and two linked worktrees finalizing at once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

tools_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$tools_dir" "$work_dir"' EXIT
# npm is linked next to node because it is not always in a system directory (nvm installs).
ln -s "$(command -v node)" "$tools_dir/node"
ln -s "$(command -v npm)" "$tools_dir/npm"
# Records the issue comments and closes the engine asks for; every other gh call fails, as with no gh login.
cat > "$tools_dir/gh" <<GH
#!/bin/bash
if [ "\${1:-}" = "issue" ] && { [ "\${2:-}" = "comment" ] || [ "\${2:-}" = "close" ]; }; then
    printf '%s\n' "\$*" >> "$work_dir/gh-calls.log"
    exit 0
fi
exit 1
GH
chmod +x "$tools_dir/gh"
agentless_path="$tools_dir:/usr/local/bin:/usr/bin:/bin"
# The user's git configuration is kept out: push.default or pull.rebase would decide the result.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

new_project() { # <directory name>
    mkdir "$work_dir/$1"
    cd "$work_dir/$1"
    git init -q
    git config user.email test@example.com
    git config user.name test
    printf '{"name":"demo","scripts":{"build":"true","test":"true"}}\n' > package.json
    printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\ncat >/dev/null\n' > "$tools_dir/claude"
    chmod +x "$tools_dir/claude"
    PATH="$agentless_path" node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed"
    rm -f "$tools_dir/claude"
    git add -A && git commit -qm "baseline"
    branch="$(git symbolic-ref --short HEAD)"
}
# A bare remote that already has the project's branch, tracked by it.
new_pushed_remote() { # <remote name>
    git init -q --bare "$PWD-$1.git"
    git remote add "$1" "$PWD-$1.git"
    git push -q -u "$1" "$branch"
}
engine() { env -i PATH="$agentless_path" HOME="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 ${engine_tmpdir:+"TMPDIR=$engine_tmpdir"} \
    EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude bash .evolve/scripts/evolve.sh "$@"; }
start_session() {
    prepare_log="$work_dir/prepare-$(basename "$PWD").log"
    prepare_status=0; engine prepare > "$prepare_log" 2>&1 || prepare_status=$?
}
# The agent's part of an in-session cycle (one commit with its journal entry), then verify and finalize.
finish_session() { # <file to add>
    finalize_log="$work_dir/finalize-$(basename "$PWD")-$1.log"
    echo "$1" > "$1"
    { head -1 .evolve/JOURNAL.md; printf '\n## Day 0: entry for %s\n\nAdded %s.\n' "$1" "$1"; tail -n +2 .evolve/JOURNAL.md; } > "$work_dir/journal"
    cp "$work_dir/journal" .evolve/JOURNAL.md
    git add "$1" .evolve/JOURNAL.md && git commit -qm "Day 0: add $1"
    engine verify > "$work_dir/verify.log" 2>&1 || bad "verify failed: $(tail -2 "$work_dir/verify.log")"
    finalize_status=0; engine finalize --no-agent > "$finalize_log" 2>&1 || finalize_status=$?
}
run_session() { start_session; [ "$prepare_status" -eq 0 ] || bad "prepare failed: $(tail -2 "$prepare_log")"; finish_session "$1"; }
remote_branch_sha() { git ls-remote "$1" "refs/heads/$branch" | cut -f1; }
# Someone else's commit on the remote's branch, made from a clone of its own.
push_from_elsewhere() { # <remote url> <file> [content]
    local clone="$work_dir/elsewhere-$RANDOM"
    git clone -q "$1" "$clone"
    echo "${3:-$2}" > "$clone/$2"
    git -C "$clone" add "$2"
    git -C "$clone" -c user.email=other@example.com -c user.name=other commit -qm "someone else: $2"
    git -C "$clone" push -q origin "HEAD:$branch"
    elsewhere_sha="$(git -C "$clone" rev-parse HEAD)"
    rm -rf "$clone"
}
# Someone else's journal entry on top of the remote's journal.
push_entry_from_elsewhere() { # <remote url> <heading> <text>
    local clone="$work_dir/elsewhere-$RANDOM"
    git clone -q "$1" "$clone"
    { head -1 "$clone/.evolve/JOURNAL.md"; printf '\n## %s\n\n%s\n' "$2" "$3"; tail -n +2 "$clone/.evolve/JOURNAL.md"; } > "$work_dir/journal-elsewhere"
    cp "$work_dir/journal-elsewhere" "$clone/.evolve/JOURNAL.md"
    git -C "$clone" add .evolve/JOURNAL.md
    git -C "$clone" -c user.email=other@example.com -c user.name=other commit -qm "someone else: journal entry"
    git -C "$clone" push -q origin "HEAD:$branch"
    elsewhere_sha="$(git -C "$clone" rev-parse HEAD)"
    rm -rf "$clone"
}
# The journal's entries as "heading|text|" groups, to compare in one line.
journal_entries() { grep -A2 '^## Day 0: ' .evolve/JOURNAL.md | grep -v '^$\|^--$' | tr '\n' '|'; }

# ── A clone that is behind its upstream starts the cycle from the upstream's state ──
new_project behind
new_pushed_remote origin
push_from_elsewhere "$PWD-origin.git" theirs.txt
start_session
[ "$prepare_status" -eq 0 ] && [ -f theirs.txt ] && [ "$(git rev-parse HEAD)" = "$elsewhere_sha" ] \
    && ok "prepare fast-forwards a branch that is behind its upstream" || bad "behind: exit $prepare_status, $(tail -4 "$prepare_log")"
grep -q "Brought $branch up to date with 1 new commit(s) from origin" "$prepare_log" \
    && ok "prepare says what it brought in" || bad "log: $(grep -i "date\|fetch" "$prepare_log")"
grep -q "^SESSION_START_SHA=$elsewhere_sha$" .evolve/run/session.env \
    && ok "the session's baseline is the upstream's commit" || bad "session.env: $(grep SESSION_START_SHA .evolve/run/session.env)"
[ -z "$(git for-each-ref refs/code-evolve)" ] && ok "the start sync leaves no ref behind" || bad "left behind: $(git for-each-ref refs/code-evolve)"
finish_session ours.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && ! grep -q "Rebased" "$finalize_log" \
    && ok "that session is pushed without a second sync" || bad "finalize: exit $finalize_status, $(tail -4 "$finalize_log")"

# A branch that is up to date says nothing about it.
start_session
! grep -qi "up to date\|could not" "$prepare_log" && ok "an up-to-date branch is not mentioned" || bad "log: $(grep -i "date\|could not" "$prepare_log")"
finish_session quiet.txt

# ── A headless cycle starts from the upstream's state too ──
push_from_elsewhere "$PWD-origin.git" for-the-cycle.txt
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\ncat >/dev/null\n' > "$tools_dir/claude"; chmod +x "$tools_dir/claude"
cycle_status=0
env -i PATH="$agentless_path" HOME="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 ANTHROPIC_API_KEY=stub \
    node "$CLI" run > "$work_dir/cycle.log" 2>&1 || cycle_status=$?
rm -f "$tools_dir/claude"
[ "$cycle_status" -eq 0 ] && [ -f for-the-cycle.txt ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] \
    && grep -q "Brought $branch up to date" "$work_dir/cycle.log" && ! grep -q "Rebased" "$work_dir/cycle.log" \
    && ok "code-evolve run brings the branch up to date before the agent works" || bad "cycle: exit $cycle_status, $(tail -5 "$work_dir/cycle.log")"

# ── A shallow clone, as actions/checkout makes one, is brought up to date the same way ──
git clone -q --depth 1 "file://$PWD-origin.git" "$work_dir/shallow"
push_from_elsewhere "$PWD-origin.git" after-the-shallow-clone.txt
cd "$work_dir/shallow"
git config user.email shallow@example.com; git config user.name shallow
start_session
[ "$prepare_status" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$elsewhere_sha" ] && [ "$(git rev-parse --is-shallow-repository)" = true ] \
    && ok "a shallow clone that is behind is fast-forwarded" || bad "shallow: exit $prepare_status, $(tail -4 "$prepare_log")"
rm -rf .evolve/run

# ── Earlier cycles that were never pushed are rebased onto the upstream at the start ──
new_project unpushed-cycles
new_pushed_remote origin
printf '#!/bin/sh\necho "policy says no" >&2\nexit 1\n' > "$PWD-origin.git/hooks/pre-receive"
chmod +x "$PWD-origin.git/hooks/pre-receive"
run_session held-back.txt
[ "$finalize_status" -eq 4 ] || bad "setup: the refused cycle exited $finalize_status"
rm "$PWD-origin.git/hooks/pre-receive"
push_from_elsewhere "$PWD-origin.git" theirs.txt
start_session
[ "$prepare_status" -eq 0 ] && [ -f theirs.txt ] && [ -f held-back.txt ] && git merge-base --is-ancestor "$elsewhere_sha" HEAD \
    && [ "$(git rev-list --count "$elsewhere_sha..HEAD")" -ge 1 ] && [ ! -d .git/rebase-merge ] \
    && ok "prepare rebases unpushed cycles onto the upstream's new commits" || bad "unpushed: exit $prepare_status, $(tail -4 "$prepare_log")"
grep -q "entry for held-back.txt" .evolve/JOURNAL.md && ! grep -q '^[<=>]\{7\}' .evolve/JOURNAL.md \
    && ok "the unpushed cycle's journal entry survives the start sync" || bad "journal: $(head -12 .evolve/JOURNAL.md)"
finish_session next.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] \
    && git cat-file -e "$(remote_branch_sha origin):held-back.txt" \
    && ok "the next cycle pushes the held-back one with its own" || bad "finalize: exit $finalize_status, $(tail -4 "$finalize_log")"

# ── Unpushed commits that conflict with the upstream: the cycle says why and starts from the local branch ──
new_project start-conflict
new_pushed_remote origin
echo "ours" > shared.txt; git add shared.txt; git commit -qm "local, never pushed"
local_sha="$(git rev-parse HEAD)"
push_from_elsewhere "$PWD-origin.git" shared.txt "theirs"
start_session
[ "$prepare_status" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$local_sha" ] && [ "$(cat shared.txt)" = "ours" ] \
    && [ ! -d .git/rebase-merge ] && [ -z "$(git for-each-ref refs/code-evolve)" ] \
    && ok "a start sync that conflicts leaves the branch as it was and the cycle goes on" || bad "conflict: exit $prepare_status, $(git status -sb | head -3)"
grep -q "Could not bring $branch up to date.*shared.txt" "$prepare_log" && grep -q "starts from the local branch" "$prepare_log" \
    && grep -q "git pull --rebase" "$prepare_log" \
    && ok "it names the file and the command that resolves it" || bad "log: $(grep -i "could not\|local branch" "$prepare_log")"
finish_session after-conflict.txt
[ "$finalize_status" -eq 4 ] && ok "that cycle still ends as not pushed" || bad "finalize exited $finalize_status"

# ── Uncommitted edits in the way: the reason is git's, and the cycle goes on ──
new_project start-dirty
new_pushed_remote origin
push_from_elsewhere "$PWD-origin.git" package.json '{"name":"demo","scripts":{"build":"true","test":"true","lint":"true"}}'
printf '{"name":"edited","scripts":{"build":"true","test":"true"}}\n' > package.json
# With autoStash git would set the edit aside, fail to put it back and still report success.
git config merge.autoStash true; git config rebase.autoStash true
start_session
[ "$prepare_status" -eq 0 ] && [ "$(cat package.json)" = '{"name":"edited","scripts":{"build":"true","test":"true"}}' ] \
    && grep -q "Could not bring $branch up to date with origin: error: " "$prepare_log" && [ -z "$(git stash list)" ] \
    && ok "uncommitted edits the upstream would overwrite are kept, with git's reason" || bad "dirty: exit $prepare_status, $(grep -i "could not" "$prepare_log")"
rm -rf .evolve/run
# The same with a commit of this clone's own, where the update is a rebase.
git commit -q --allow-empty -m "local, never pushed"
start_session
[ "$prepare_status" -eq 0 ] && [ "$(cat package.json)" = '{"name":"edited","scripts":{"build":"true","test":"true"}}' ] \
    && grep -q "Could not bring $branch up to date with origin: " "$prepare_log" && [ -z "$(git stash list)" ] && [ ! -d .git/rebase-merge ] \
    && ok "a rebase at the start does not stash the edits either" || bad "dirty rebase: exit $prepare_status, $(grep -i "could not" "$prepare_log"); $(git status -sb | head -3)"
rm -rf .evolve/run

# ── The remote cannot be reached at the start ──
new_project start-unreachable
new_pushed_remote origin
git remote set-url origin "$work_dir/no-such-repository.git"
start_session
[ "$prepare_status" -eq 0 ] && grep -q "Could not fetch refs/heads/$branch from origin (.*); starting from the local branch" "$prepare_log" \
    && ok "an unreachable remote is reported and the cycle starts from the local branch" || bad "unreachable: exit $prepare_status, $(grep -i "fetch" "$prepare_log")"
rm -rf .evolve/run

# ── A branch pushed to a fork: fast-forwarded when it is only behind, never rebased ──
new_project start-fork
new_pushed_remote upstream
git init -q --bare "$PWD-origin.git"; git remote add origin "$PWD-origin.git"
git config "branch.$branch.pushRemote" origin
git config push.default current
push_from_elsewhere "$PWD-upstream.git" theirs.txt
start_session
[ "$prepare_status" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$elsewhere_sha" ] && grep -q "Brought $branch up to date with 1 new commit(s) from upstream" "$prepare_log" \
    && ok "a branch that pushes to a fork and is only behind its upstream is fast-forwarded" || bad "fork: $(tail -4 "$prepare_log")"
finish_session ours.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] \
    && ok "the fork takes that cycle" || bad "fork push: exit $finalize_status, $(tail -4 "$finalize_log")"
fork_head="$(git rev-parse HEAD)"
push_from_elsewhere "$PWD-upstream.git" more-of-theirs.txt
start_session
[ "$prepare_status" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$fork_head" ] && [ ! -f more-of-theirs.txt ] && [ -z "$(git for-each-ref refs/code-evolve)" ] \
    && grep -q "Could not bring $branch up to date with upstream: it has commits of its own and is not pushed to that upstream" "$prepare_log" \
    && ok "with commits of its own it is not rebased, and prepare says why" || bad "fork, diverged: $(grep -i "could not\|up to date" "$prepare_log")"
rm -rf .evolve/run

# ── A branch that tracks a local branch is fast-forwarded to it when it is only behind ──
new_project local-upstream
git checkout -q -b feature --track "$branch"
git checkout -q "$branch"
echo base > on-base.txt; git add on-base.txt; git commit -qm "the base branch moves on"
base_sha="$(git rev-parse HEAD)"
git checkout -q feature
start_session
[ "$prepare_status" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$base_sha" ] && [ "$(git symbolic-ref --short HEAD)" = feature ] \
    && grep -q "Brought feature up to date with 1 new commit(s) from \." "$prepare_log" && [ -z "$(git for-each-ref refs/code-evolve)" ] \
    && ok "a branch behind the local branch it tracks is fast-forwarded" || bad "local upstream: $(grep -i "up to date\|could not" "$prepare_log")"
finish_session ours.txt
# git's default push refuses a branch whose upstream is a local branch, so only the sync is checked here.
! grep -q "Rebased\|Sync failed\|Could not fetch" "$finalize_log" \
    && ok "finalize does not sync a branch with a local upstream" || bad "local upstream finalize: exit $finalize_status, $(tail -4 "$finalize_log")"

# ── A repository with no commits and an upstream (a clone of an empty repository) ──
git init -q --bare "$work_dir/empty-origin.git"
git clone -q "$work_dir/empty-origin.git" "$work_dir/empty-clone" 2>/dev/null
cd "$work_dir/empty-clone"
git config user.email test@example.com; git config user.name test
printf '{"name":"demo","scripts":{"build":"true","test":"true"}}\n' > package.json
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\ncat >/dev/null\n' > "$tools_dir/claude"; chmod +x "$tools_dir/claude"
PATH="$agentless_path" node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed"
rm -f "$tools_dir/claude"
start_session
[ "$prepare_status" -eq 0 ] && ! grep -qi "could not fetch" "$prepare_log" \
    && ok "a repository with no commits yet starts without a fetch complaint" || bad "empty clone: exit $prepare_status, $(grep -i "fetch" "$prepare_log")"

# ── The push URL names another repository: the session is synced with the side it is pushed to ──
new_project push-url
new_pushed_remote origin
git clone -q --bare "$PWD-origin.git" "$PWD-push-side.git"
git remote set-url --push origin "$PWD-push-side.git"
start_session
push_from_elsewhere "$PWD-push-side.git" on-push-side.txt
finish_session ours.txt
push_side_head="$(git ls-remote "$PWD-push-side.git" "refs/heads/$branch" | cut -f1)"
[ "$finalize_status" -eq 0 ] && [ "$push_side_head" = "$(git rev-parse HEAD)" ] && git merge-base --is-ancestor "$elsewhere_sha" HEAD \
    && ok "a session is rebased onto the push URL's branch and lands there" || bad "push url: exit $finalize_status, $(tail -5 "$finalize_log")"
[ -f on-push-side.txt ] && grep -q "Rebased the session onto 1 new commit(s) from origin" "$finalize_log" \
    && ok "the push side's commit is in the session's history" || bad "log: $(grep -i "rebased\|sync" "$finalize_log")"
# The same at the start of a cycle.
push_from_elsewhere "$PWD-push-side.git" later-on-push-side.txt
start_session
[ -f later-on-push-side.txt ] && ok "the start sync reads the push URL too" || bad "start: $(tail -3 "$prepare_log")"
# A push side that refuses is still "not pushed".
printf '#!/bin/sh\nexit 1\n' > "$PWD-push-side.git/hooks/pre-receive"; chmod +x "$PWD-push-side.git/hooks/pre-receive"
finish_session refused.txt
[ "$finalize_status" -eq 4 ] && grep -q "Push failed: .*rejected" "$finalize_log" \
    && ok "a push URL that refuses the session is reported as not pushed" || bad "exit $finalize_status: $(tail -4 "$finalize_log")"

# ── A push mapping that leaves the session's branch out: git reports success, the engine does not ──
new_project mapping-leaves-branch-out
new_pushed_remote origin
git branch other
git push -q origin other
git config remote.origin.push refs/heads/other:refs/heads/other
origin_before="$(remote_branch_sha origin)"
run_session only.txt
[ "$finalize_status" -eq 4 ] && [ "$(remote_branch_sha origin)" = "$origin_before" ] \
    && ok "a push that did not send the session's branch ends with exit status 4" || bad "mapping: exit $finalize_status, $(tail -5 "$finalize_log")"
grep -q "Push failed: git sent nothing for $branch" "$finalize_log" && tail -1 "$finalize_log" | grep -q "NOT pushed" \
    && [ "$(git tag --points-at HEAD | wc -l)" -eq 0 ] && ! grep -q "Tag push" "$finalize_log" \
    && ok "it says the branch was left out, and no tag goes out" || bad "log: $(grep -i "push\|tag" "$finalize_log")"
# The same mapping on a branch with no upstream.
new_project mapping-without-upstream
git init -q --bare "$PWD-origin.git"; git remote add origin "$PWD-origin.git"
git branch other
git config remote.origin.push refs/heads/other:refs/heads/other
run_session only.txt
[ "$finalize_status" -eq 4 ] && [ -z "$(remote_branch_sha origin)" ] && grep -q "Push failed: git sent nothing for $branch" "$finalize_log" \
    && ok "the same holds for a branch that was never pushed" || bad "mapping, no upstream: exit $finalize_status, $(tail -5 "$finalize_log")"
# A branch whose name has characters a pattern would misread.
new_project odd-branch-name
git checkout -q -b 'feature/v1.0+fix'
branch='feature/v1.0+fix'
new_pushed_remote origin
run_session only.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] \
    && ok "a branch name with dots, a plus and a slash is recognised as sent" || bad "odd name: exit $finalize_status, $(tail -4 "$finalize_log")"

# ── Issue comments are posted after the sync, and cite the commit that is on the remote ──
new_project issue-comment
new_pushed_remote origin
start_session
push_from_elsewhere "$PWD-origin.git" theirs.txt
printf 'issue_number: 7\nstatus: fixed\ncomment: Good catch, fixed.\n' > .evolve/ISSUE_RESPONSE.md
rm -f "$work_dir/gh-calls.log"
finish_session ours.txt
pushed_short="$(git rev-parse --short "$(remote_branch_sha origin)")"
[ "$finalize_status" -eq 0 ] && grep -q "Rebased" "$finalize_log" && grep -q "^issue comment 7 " "$work_dir/gh-calls.log" \
    && [ "$(grep "^Commit: " "$work_dir/gh-calls.log")" = "Commit: $pushed_short" ] \
    && ok "the comment cites the commit as it is on the remote after the rebase" || bad "gh calls: $(cat "$work_dir/gh-calls.log" 2>&1); remote: $pushed_short"
grep -q "^issue close 7 " "$work_dir/gh-calls.log" && ok "a fixed issue is closed" || bad "gh calls: $(cat "$work_dir/gh-calls.log" 2>&1)"
[ ! -e .evolve/ISSUE_RESPONSE.md ] && ! git cat-file -e HEAD:.evolve/ISSUE_RESPONSE.md 2>/dev/null \
    && ok "the response file is neither left behind nor committed" || bad "response file: $(git status --porcelain)"
# A cycle that was not pushed posts nothing: its commits are not on the remote.
printf '#!/bin/sh\nexit 1\n' > "$PWD-origin.git/hooks/pre-receive"; chmod +x "$PWD-origin.git/hooks/pre-receive"
start_session
printf 'issue_number: 8\nstatus: fixed\ncomment: Fixed.\n' > .evolve/ISSUE_RESPONSE.md
rm -f "$work_dir/gh-calls.log"
finish_session refused.txt
[ "$finalize_status" -eq 4 ] && [ ! -e "$work_dir/gh-calls.log" ] && grep -q "Issue responses not posted" "$finalize_log" \
    && ok "a cycle that was not pushed posts no issue comment and closes nothing" || bad "exit $finalize_status, gh calls: $(cat "$work_dir/gh-calls.log" 2>&1)"
# Neither does one whose push was skipped: with several remotes and none chosen, its commits are on no remote.
new_project issue-comment-push-skipped
git init -q --bare "$PWD-alpha.git"; git remote add alpha "$PWD-alpha.git"
git init -q --bare "$PWD-beta.git"; git remote add beta "$PWD-beta.git"
start_session
printf 'issue_number: 9\nstatus: fixed\ncomment: Fixed.\n' > .evolve/ISSUE_RESPONSE.md
rm -f "$work_dir/gh-calls.log"
finish_session only.txt
[ "$finalize_status" -eq 0 ] && grep -q "Push skipped" "$finalize_log" && [ ! -e "$work_dir/gh-calls.log" ] && grep -q "Issue responses not posted" "$finalize_log" \
    && ok "a cycle whose push was skipped posts no issue comment" || bad "exit $finalize_status, gh calls: $(cat "$work_dir/gh-calls.log" 2>&1)"

# ── A session that contains a merge commit keeps it through the sync ──
new_project merge-commit
new_pushed_remote origin
start_session
push_from_elsewhere "$PWD-origin.git" theirs.txt
git checkout -q -b side
echo side > side.txt; git add side.txt; git commit -qm "Day 0: side work"
git checkout -q "$branch"
echo main > main.txt; git add main.txt; git commit -qm "Day 0: main work"
git merge -q --no-ff -m "Day 0: merge side" side
finish_session after-merge.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && git merge-base --is-ancestor "$elsewhere_sha" HEAD \
    && ok "a session with a merge commit is rebased and pushed" || bad "merge commit: exit $finalize_status, $(tail -5 "$finalize_log")"
[ "$(git rev-list --merges --count "$elsewhere_sha..HEAD")" -eq 1 ] && [ -f side.txt ] && [ -f main.txt ] && [ -f theirs.txt ] \
    && ok "the merge commit is still a merge after the sync" || bad "merges after sync: $(git log --oneline --graph "$elsewhere_sha..HEAD" | head -8)"

# ── A rebase git refuses for a reason other than a conflict ──
new_project rebase-refused
new_pushed_remote origin
start_session
push_from_elsewhere "$PWD-origin.git" theirs.txt
printf '#!/bin/sh\necho "no rebases on this machine" >&2\nexit 1\n' > .git/hooks/pre-rebase; chmod +x .git/hooks/pre-rebase
origin_before="$(remote_branch_sha origin)"
finish_session ours.txt
[ "$finalize_status" -eq 4 ] && [ "$(remote_branch_sha origin)" = "$origin_before" ] && [ -f ours.txt ] && [ -z "$(git status --porcelain)" ] \
    && [ ! -d .git/rebase-merge ] && [ -z "$(git for-each-ref refs/code-evolve)" ] \
    && ok "a refused rebase ends with exit status 4 and keeps the session's commits" || bad "refused rebase: exit $finalize_status, $(git status -sb | head -3)"
grep -q "no rebases on this machine" "$finalize_log" && grep -q "^  Sync failed: " "$finalize_log" && ! grep -q "change the same lines" "$finalize_log" \
    && ok "git's own output is shown, and it is not called a conflict" || bad "log: $(grep -i "sync\|rebase" "$finalize_log")"

# ── Two cycles that each wrote a journal entry: both stay, even under an identical heading line ──
new_project journal-entries
new_pushed_remote origin
start_session
push_entry_from_elsewhere "$PWD-origin.git" "Day 0: their entry" "Their text"
finish_session ours.txt
[ "$finalize_status" -eq 0 ] && [ "$(journal_entries)" = "## Day 0: their entry|Their text|## Day 0: entry for ours.txt|Added ours.txt.|" ] \
    && ok "two cycles' journal entries both survive the sync" || bad "journal: exit $finalize_status, $(journal_entries)"
new_project journal-same-heading
printf '\nA note of mine that ends with {ours}\n' >> .evolve/JOURNAL.md && git commit -qam "a note"
new_pushed_remote origin
start_session
push_entry_from_elsewhere "$PWD-origin.git" "Day 0: entry for ours.txt" "Their text"
finish_session ours.txt
[ "$finalize_status" -eq 0 ] && [ "$(journal_entries)" = "## Day 0: entry for ours.txt|Their text|## Day 0: entry for ours.txt|Added ours.txt.|" ] \
    && ok "two entries with an identical heading line stay two entries" || bad "same heading: exit $finalize_status, $(journal_entries)"
! grep -q '{ours /\|{theirs /' .evolve/JOURNAL.md && ok "the merge leaves no marker in the journal" || bad "markers: $(head -12 .evolve/JOURNAL.md)"
grep -qxF "A note of mine that ends with {ours}" .evolve/JOURNAL.md \
    && ok "a line that already ended with the marker's text is kept as it was" || bad "note: $(grep -F "A note of mine" .evolve/JOURNAL.md)"

# ── A project's own merge rule for the engine's state files does not win over the engine's ──
# The override reads attributes from a tree (GIT_ATTR_SOURCE), which git 2.41 added.
git_version=$(git --version | sed 's/[^0-9.]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/')
if [ "${git_version%%.*}" -gt 2 ] || { [ "${git_version%%.*}" -eq 2 ] && [ "${git_version#*.}" -ge 41 ]; }; then
new_project project-merge-rule
printf '.evolve/JOURNAL.md merge=binary\n.evolve/DAY_COUNT merge=binary\n' > .gitattributes
git add .gitattributes && git commit -qm "the project's merge rules"
new_pushed_remote origin
start_session
push_entry_from_elsewhere "$PWD-origin.git" "Day 0: their entry" "Their text"
finish_session ours.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && [ "$(journal_entries)" = "## Day 0: their entry|Their text|## Day 0: entry for ours.txt|Added ours.txt.|" ] \
    && ok "a project's merge=binary rule on the journal does not make two cycles conflict" || bad "project rule: exit $finalize_status, $(tail -3 "$finalize_log")"
[ -z "$(git config --get-regexp '^merge\.' || true)" ] && [ ! -e .git/info/attributes ] && [ "$(cat .gitattributes | wc -l)" -eq 2 ] \
    && ok "the repository's configuration and attributes are untouched" || bad "config: $(git config --list --local | grep -i merge)"
else
    echo "  skip: a project's merge rule test needs git 2.41 or later (have $git_version)"
fi

# ── A session rebased onto newer cycles never takes the day count back ──
new_project day-count
new_pushed_remote origin
start_session
push_from_elsewhere "$PWD-origin.git" .evolve/DAY_COUNT 99
echo 5 > .evolve/DAY_COUNT && git commit -qam "Day 5: day count"
finish_session ours.txt
[ "$finalize_status" -eq 0 ] && [ "$(cat .evolve/DAY_COUNT)" = 99 ] && [ "$(git show "$(remote_branch_sha origin):.evolve/DAY_COUNT")" = 99 ] \
    && ok "DAY_COUNT keeps the larger day when the session is rebased" || bad "day count: exit $finalize_status, $(cat .evolve/DAY_COUNT), $(tail -3 "$finalize_log")"
# And the session's own day when that is the larger one.
start_session
push_from_elsewhere "$PWD-origin.git" .evolve/DAY_COUNT 100
echo 150 > .evolve/DAY_COUNT && git commit -qam "Day 150: day count"
finish_session more.txt
[ "$finalize_status" -eq 0 ] && [ "$(cat .evolve/DAY_COUNT)" = 150 ] \
    && ok "and takes the session's day when that is larger" || bad "day count: exit $finalize_status, $(cat .evolve/DAY_COUNT)"

# ── A repository whose path (and temporary directory) contains a space ──
mkdir "$work_dir/tmp with space"
engine_tmpdir="$work_dir/tmp with space"
new_project "spaced path"
new_pushed_remote origin
start_session
push_entry_from_elsewhere "$PWD-origin.git" "Day 0: their entry" "Their text"
push_from_elsewhere "$PWD-origin.git" .evolve/DAY_COUNT 99
echo 5 > .evolve/DAY_COUNT && git commit -qam "Day 5: day count"
finish_session ours.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && [ "$(cat .evolve/DAY_COUNT)" = 99 ] \
    && [ "$(journal_entries)" = "## Day 0: their entry|Their text|## Day 0: entry for ours.txt|Added ours.txt.|" ] \
    && ok "the sync's merge drivers work in a repository path with a space" || bad "spaced path: exit $finalize_status, $(tail -3 "$finalize_log")"
unset engine_tmpdir

# ── A push that loses a race against another scheduler is synced and tried once more ──
new_project push-race
new_pushed_remote origin
start_session
cat > .git/hooks/pre-push <<HOOK
#!/bin/sh
# The first push (and only that one) is overtaken: someone else pushes after git read the remote's branch.
[ -e "$work_dir/raced" ] && exit 0
touch "$work_dir/raced"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
git clone -q "$PWD-origin.git" "$work_dir/racer"
echo raced > "$work_dir/racer/raced.txt"
git -C "$work_dir/racer" add raced.txt
git -C "$work_dir/racer" -c user.email=other@example.com -c user.name=other commit -qm "someone else: raced.txt"
git -C "$work_dir/racer" push -q origin "HEAD:$branch"
exit 0
HOOK
chmod +x .git/hooks/pre-push
finish_session ours.txt
remote_head="$(remote_branch_sha origin)"
[ "$finalize_status" -eq 0 ] && [ -e "$work_dir/raced" ] && [ "$remote_head" = "$(git rev-parse HEAD)" ] \
    && git cat-file -e "$remote_head:raced.txt" && git cat-file -e "$remote_head:ours.txt" \
    && ok "a lost push race ends pushed, with both commits on the remote" || bad "race: exit $finalize_status, $(tail -8 "$finalize_log")"
grep -q "The remote moved during the push" "$finalize_log" \
    && [ "$(git ls-remote origin "refs/tags/day0-*^{}" | cut -f1)" = "$remote_head" ] \
    && ok "the session's tag is on the pushed commit" || bad "race tag: $(git ls-remote origin 'refs/tags/*'); $(grep -i "tag" "$finalize_log")"
rm -rf "$work_dir/racer"
# A refusal that is not a lost race is not retried.
new_project push-refused
new_pushed_remote origin
printf '#!/bin/sh\necho "policy says no" >&2\nexit 1\n' > "$PWD-origin.git/hooks/pre-receive"; chmod +x "$PWD-origin.git/hooks/pre-receive"
run_session held-back.txt
[ "$finalize_status" -eq 4 ] && ! grep -q "The remote moved" "$finalize_log" && ok "a push the remote refuses on policy is not retried" || bad "refused: $(tail -4 "$finalize_log")"

# Another ref the push configuration sends is refused while the session's branch goes through:
# not a lost race, so no second sync.
new_project other-ref-refused
new_pushed_remote origin
git branch side && git push -q origin side
side_clone="$work_dir/side-elsewhere"
git clone -q -b side "$PWD-origin.git" "$side_clone"
git -C "$side_clone" -c user.email=other@example.com -c user.name=other commit -q --allow-empty -m "side moves on"
git -C "$side_clone" push -q origin side
git config --add remote.origin.push "refs/heads/$branch:refs/heads/$branch"
git config --add remote.origin.push refs/heads/side:refs/heads/side
run_session ours-other-ref.txt
[ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && ! grep -q "The remote moved" "$finalize_log" \
    && ok "a refused ref other than the session's branch is not taken for a lost race" || bad "other ref: $(tail -6 "$finalize_log")"

# ── The session's tag name is taken: only on the remote, then also on this repository ──
date_binary="$(command -v date)"
printf '#!/bin/bash\nif [ "$*" = "+%%H:%%M" ]; then echo 12:34; else exec "%s" "$@"; fi\n' "$date_binary" > "$tools_dir/date"
chmod +x "$tools_dir/date"
new_project tag-taken
new_pushed_remote origin
# Another clone's session tag, on a commit of a branch this one never fetches.
other_commit="$(git -C "$PWD-origin.git" -c user.email=other@example.com -c user.name=other commit-tree -m "another clone" "$branch^{tree}")"
git -C "$PWD-origin.git" tag day0-12-34 "$other_commit"
run_session first.txt
[ "$finalize_status" -eq 0 ] && [ "$(git ls-remote origin 'refs/tags/day0-12-34-2^{}' | cut -f1)" = "$(git rev-parse HEAD)" ] \
    && ok "a tag name only the remote has (another clone's) is replaced by the next free one" || bad "remote tag: exit $finalize_status, $(grep -i "tag" "$finalize_log"); $(git ls-remote --tags origin)"
run_session second.txt
[ "$finalize_status" -eq 0 ] && [ "$(git ls-remote origin 'refs/tags/day0-12-34-3^{}' | cut -f1)" = "$(git rev-parse HEAD)" ] \
    && ok "a name taken both here and on the remote moves on again" || bad "second tag: exit $finalize_status, $(grep -i "tag" "$finalize_log")"
for serial in $(seq 4 30); do git tag "day0-12-34-$serial" HEAD; done
run_session third.txt
[ "$finalize_status" -eq 0 ] && [ "$(git rev-parse -q --verify 'refs/tags/day0-12-34-31^{}')" = "$(git rev-parse HEAD)" ] \
    && ok "a session takes the next free name however many are taken" || bad "many tags: exit $finalize_status, $(grep -i "tag" "$finalize_log")"
rm -f "$tools_dir/date"

# ── Two linked worktrees of one repository finalize at the same time ──
new_project worktrees
new_pushed_remote origin
for name in one two; do
    git worktree add -q -b "wt-$name" "$work_dir/worktree-$name"
    git -C "$work_dir/worktree-$name" push -q -u origin "wt-$name"
done
for name in one two; do
    ( cd "$work_dir/worktree-$name" && engine prepare > "$work_dir/prepare-wt-$name.log" 2>&1 ) || bad "worktree $name: prepare failed: $(tail -2 "$work_dir/prepare-wt-$name.log")"
done
for name in one two; do
    branch="wt-$name" push_from_elsewhere "$PWD-origin.git" "theirs-$name.txt"
    ( cd "$work_dir/worktree-$name" && echo "$name" > "ours-$name.txt" && git add "ours-$name.txt" && git commit -qm "Day 0: add ours-$name.txt" \
        && engine verify > "$work_dir/verify-wt-$name.log" 2>&1 ) || bad "worktree $name: verify failed"
done
( cd "$work_dir/worktree-one" && engine finalize --no-agent > "$work_dir/finalize-wt-one.log" 2>&1 ) & pid_one=$!
( cd "$work_dir/worktree-two" && engine finalize --no-agent > "$work_dir/finalize-wt-two.log" 2>&1 ) & pid_two=$!
status_one=0; wait "$pid_one" || status_one=$?
status_two=0; wait "$pid_two" || status_two=$?
[ "$status_one" -eq 0 ] && [ "$status_two" -eq 0 ] \
    && ok "both worktrees finalize" || bad "exits $status_one and $status_two: $(tail -3 "$work_dir/finalize-wt-one.log" "$work_dir/finalize-wt-two.log")"
landed=true
for name in one two; do
    head_sha="$(git -C "$work_dir/worktree-$name" rev-parse HEAD)"
    [ "$(git ls-remote origin "refs/heads/wt-$name" | cut -f1)" = "$head_sha" ] && git cat-file -e "$head_sha:theirs-$name.txt" && git cat-file -e "$head_sha:ours-$name.txt" \
        && grep -q "Rebased the session onto 1 new commit(s)" "$work_dir/finalize-wt-$name.log" || landed=false
done
[ "$landed" = true ] && ok "each worktree's session is rebased onto its own upstream and pushed" \
    || bad "worktrees: $(git ls-remote origin 'refs/heads/wt-*'); $(tail -4 "$work_dir/finalize-wt-one.log")"
# Both sessions ask for the same tag name in the same instant; each ends up with a tag of its own.
[ -z "$(git for-each-ref refs/code-evolve)" ] && [ "$(git ls-remote --tags origin 'day0-*' | grep -vc '\^{}')" -eq 2 ] \
    && ok "no sync ref is left, and the remote has a tag for each session" || bad "refs: $(git for-each-ref refs/code-evolve); tags: $(git ls-remote --tags origin)"

cd /
echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
