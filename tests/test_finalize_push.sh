#!/bin/bash
# Test (#132, #137): what finalize pushes. A branch that was never pushed goes out with its upstream
# set (it used to stay behind while the tag went out alone); the remote is origin, else the only
# one; no remote is quiet. A branch with an upstream is first rebased onto what the remote gained,
# so two schedulers in two clones both land; a push that still fails ends the cycle with status 4.
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
printf '#!/bin/bash\nexit 1\n' > "$tools_dir/gh"; chmod +x "$tools_dir/gh"
agentless_path="$tools_dir:/usr/local/bin:/usr/bin:/bin"
# The user's git configuration is kept out: push.autoSetupRemote or push.default would decide the result.
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
new_bare_remote() { # <remote name>
    git init -q --bare "$PWD-$1.git"
    git remote add "$1" "$PWD-$1.git"
}
engine() { env -i PATH="$agentless_path" HOME="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude bash .evolve/scripts/evolve.sh "$@"; }
# One in-session cycle: prepare, one commit, verify, finalize. Sets finalize_status and finalize_log.
run_session() { # <file to add>
    finalize_log="$work_dir/finalize-$1.log"
    engine prepare > "$work_dir/prepare.log" 2>&1 || bad "prepare failed: $(tail -2 "$work_dir/prepare.log")"
    echo "$1" > "$1"
    # The agent's own journal entry: the engine's fallback entry is skipped when the minute already has one.
    { head -1 .evolve/JOURNAL.md; printf '\n## Day 0: entry for %s\n\nAdded %s.\n' "$1" "$1"; tail -n +2 .evolve/JOURNAL.md; } > "$work_dir/journal"
    cp "$work_dir/journal" .evolve/JOURNAL.md
    git add "$1" .evolve/JOURNAL.md && git commit -qm "Day 0: add $1"
    engine verify > "$work_dir/verify.log" 2>&1 || bad "verify failed: $(tail -2 "$work_dir/verify.log")"
    finalize_status=0; engine finalize --no-agent > "$finalize_log" 2>&1 || finalize_status=$?
}
remote_branch_sha() { git ls-remote "$1" "refs/heads/$branch" | cut -f1; }
remote_tag_count() { git ls-remote --tags "$1" 'day0-*' | grep -vc '\^{}' || true; }

# ── A branch that was never pushed, with a bare origin ──
new_project unpushed
new_bare_remote origin
run_session first.txt
[ "$finalize_status" -eq 0 ] || bad "finalize exited $finalize_status: $(tail -3 "$finalize_log")"
[ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] \
    && ok "a never-pushed branch reaches origin at the session's last commit" \
    || bad "origin has '$(remote_branch_sha origin)', HEAD is $(git rev-parse HEAD): $(tail -4 "$finalize_log")"
[ "$(remote_tag_count origin)" -eq 1 ] && ok "the session tag reaches origin" || bad "tags on origin: $(git ls-remote --tags origin)"
[ "$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" = "origin/$branch" ] \
    && ok "the branch tracks origin/$branch afterwards" || bad "upstream is '$(git rev-parse --abbrev-ref '@{upstream}' 2>&1)'"
! grep -q "failed" "$finalize_log" && ok "no failure is reported for the first push" || bad "log: $(grep failed "$finalize_log")"

# ── The next session on that branch: the upstream exists, so the push is the plain one ──
run_session second.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] \
    && ok "a branch with an upstream is pushed to it" || bad "second session: $(tail -4 "$finalize_log")"
[ "$(git ls-remote --tags origin 'day0-*' | grep -vc '\^{}')" -eq "$(git tag --list 'day0-*' | wc -l)" ] \
    && ok "its tags go out too" || bad "tags on origin: $(git ls-remote --tags origin), local: $(git tag --list)"

# ── Someone else pushed first: their commits are brought in, then the session is pushed (#137) ──
git clone -q "$PWD-origin.git" "$work_dir/other-clone"
git -C "$work_dir/other-clone" -c user.email=other@example.com -c user.name=other commit -q --allow-empty -m "someone else's commit"
git -C "$work_dir/other-clone" push -q origin "HEAD:$branch"
other_sha="$(git -C "$work_dir/other-clone" rev-parse HEAD)"
run_session third.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && git merge-base --is-ancestor "$other_sha" HEAD \
    && ok "a session behind its upstream is rebased onto it and pushed" || bad "sync: exit $finalize_status, $(tail -4 "$finalize_log")"
[ -f third.txt ] && ! grep -q "failed" "$finalize_log" && ok "the session's commit survives the sync and nothing is reported as failed" \
    || bad "log: $(grep -i "failed" "$finalize_log")"
[ -z "$(git for-each-ref refs/code-evolve)" ] && [ ! -d .git/rebase-merge ] && ok "the sync leaves no ref or rebase behind" \
    || bad "left behind: $(git for-each-ref refs/code-evolve)"

# ── A push the remote refuses fails the cycle, with git's reason, and its tag stays local (#137) ──
printf '#!/bin/sh\necho "policy says no" >&2\nexit 1\n' > "$PWD-origin.git/hooks/pre-receive"
chmod +x "$PWD-origin.git/hooks/pre-receive"
tags_on_origin_before="$(remote_tag_count origin)"
sha_on_origin_before="$(remote_branch_sha origin)"
run_session fourth.txt
[ "$finalize_status" -eq 4 ] && ok "a refused push ends finalize with exit status 4" || bad "finalize exited $finalize_status"
grep -q "Push failed: .*rejected" "$finalize_log" \
    && ok "a refused push is reported with git's own line" || bad "log: $(grep -i "push" "$finalize_log")"
! grep -q "maybe no remote" "$finalize_log" && ok "the failure message no longer guesses" || bad "log still guesses"
tail -1 "$finalize_log" | grep -q "NOT pushed" && ! grep -q "=== Day 0 complete ===" "$finalize_log" \
    && ok "the closing line says the cycle was not pushed" || bad "closing line: $(tail -1 "$finalize_log")"
[ "$(remote_tag_count origin)" -eq "$tags_on_origin_before" ] && ! grep -q "Tag push" "$finalize_log" \
    && ok "no tag is pushed for a branch that was refused" || bad "tags on origin: $(remote_tag_count origin), log: $(grep "Tag" "$finalize_log")"
[ "$(remote_branch_sha origin)" = "$sha_on_origin_before" ] && [ -f fourth.txt ] && [ -z "$(git status --porcelain)" ] && [ ! -e .evolve/run ] \
    && ok "the session stays committed locally and is closed" || bad "after a refused push: $(git status --porcelain)"
# A headless cycle ends the same way, and `code-evolve run` passes the status on.
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\ncat >/dev/null\n' > "$tools_dir/claude"; chmod +x "$tools_dir/claude"
run_status=0
env -i PATH="$agentless_path" HOME="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 ANTHROPIC_API_KEY=stub \
    node "$CLI" run > "$work_dir/run.log" 2>&1 || run_status=$?
rm -f "$tools_dir/claude"
[ "$run_status" -eq 4 ] && tail -1 "$work_dir/run.log" | grep -q "NOT pushed" \
    && ok "code-evolve run exits with status 4 when the cycle was not pushed" || bad "run exited $run_status: $(tail -4 "$work_dir/run.log")"
rm "$PWD-origin.git/hooks/pre-receive"
run_session fifth.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && git cat-file -e "$(remote_branch_sha origin):fourth.txt" \
    && ok "the next cycle pushes the one that was held back" || bad "after the refusal was lifted: $(tail -4 "$finalize_log")"

# ── Two schedulers, two clones of one origin: both cycles end up on the origin (#137) ──
new_project first-scheduler
new_bare_remote origin
run_session shared-start.txt
origin_url="$PWD-origin.git"
git clone -q "$origin_url" "$work_dir/second-scheduler"
cd "$work_dir/second-scheduler"
git config user.email second@example.com
git config user.name second
run_session from-second.txt
[ "$finalize_status" -eq 0 ] || bad "second scheduler: finalize exited $finalize_status: $(tail -3 "$finalize_log")"
cd "$work_dir/first-scheduler"
run_session from-first.txt
[ "$finalize_status" -eq 0 ] && ! grep -q "failed" "$finalize_log" \
    && ok "the scheduler that pushes second finishes without a failure" || bad "first scheduler: exit $finalize_status, $(grep -i "failed\|conflict" "$finalize_log")"
origin_head="$(remote_branch_sha origin)"
[ "$origin_head" = "$(git rev-parse HEAD)" ] && git cat-file -e "$origin_head:from-first.txt" && git cat-file -e "$origin_head:from-second.txt" \
    && ok "both cycles' work is on the origin" || bad "origin tree: $(git ls-tree --name-only "$origin_head" 2>&1 | tr '\n' ' ')"
journal="$(git show "$origin_head:.evolve/JOURNAL.md")"
grep -q "entry for from-first.txt" <<<"$journal" && grep -q "entry for from-second.txt" <<<"$journal" && grep -q "entry for shared-start.txt" <<<"$journal" \
    && [ "$(grep -c "^# Journal" <<<"$journal")" -eq 1 ] && ! grep -q '^[<=>]\{7\}' <<<"$journal" \
    && ok "both journal entries are kept, without conflict markers" || bad "journal: $journal"
[ "$(git show "$origin_head:.evolve/LAST_VERIFY.md")" = "$(cat .evolve/LAST_VERIFY.md)" ] && grep -q "^Day 0" .evolve/LAST_VERIFY.md \
    && ok "the verification record is the later cycle's" || bad "LAST_VERIFY: $(git show "$origin_head:.evolve/LAST_VERIFY.md")"
# Three sessions (the shared start and one per scheduler) can all start in the same minute, and so ask for the same tag name.
[ "$(remote_tag_count origin)" -eq 3 ] && [ "$(git ls-remote --tags origin | grep -c "^$origin_head")" -eq 1 ] \
    && ok "each cycle has its own tag on the origin, the last one on the pushed commit" || bad "tags on origin: $(git ls-remote --tags origin)"
[ -z "$(git config --get core.attributesFile || true)" ] && [ ! -s .git/info/attributes ] \
    && ok "the sync leaves the repository's git configuration alone" || bad "configuration changed: $(git config --get core.attributesFile)"

# ── A shallow clone, as actions/checkout makes one, syncs and pushes the same way (#137) ──
git clone -q --depth 1 "file://$origin_url" "$work_dir/shallow-scheduler"
cd "$work_dir/shallow-scheduler"
git config user.email shallow@example.com
git config user.name shallow
cd "$work_dir/first-scheduler"
run_session ahead-of-shallow.txt
cd "$work_dir/shallow-scheduler"
run_session from-shallow.txt
origin_head="$(remote_branch_sha origin)"
[ "$finalize_status" -eq 0 ] && [ "$origin_head" = "$(git rev-parse HEAD)" ] && [ "$(git rev-parse --is-shallow-repository)" = true ] \
    && git cat-file -e "$origin_head:from-shallow.txt" && git cat-file -e "$origin_head:ahead-of-shallow.txt" \
    && ok "a shallow clone that is behind is rebased and pushed" || bad "shallow clone: exit $finalize_status, $(tail -5 "$finalize_log")"
cd "$work_dir/first-scheduler"
git pull -q --rebase origin "$branch"

# ── The other scheduler changed the same lines: the cycle fails visibly and keeps its commits (#137) ──
cd "$work_dir/second-scheduler"
git pull -q --rebase origin "$branch"
echo "second scheduler's version" > shared-start.txt
git commit -qam "second scheduler rewrites shared-start.txt" && git push -q origin "HEAD:$branch"
cd "$work_dir/first-scheduler"
engine prepare > "$work_dir/prepare.log" 2>&1 || bad "prepare failed: $(tail -2 "$work_dir/prepare.log")"
echo "first scheduler's version" > shared-start.txt
git commit -qam "Day 0: rewrite shared-start.txt"
engine verify > "$work_dir/verify.log" 2>&1 || bad "verify failed: $(tail -2 "$work_dir/verify.log")"
origin_before="$(remote_branch_sha origin)"
finalize_log="$work_dir/finalize-conflict.log"
finalize_status=0; engine finalize --no-agent > "$finalize_log" 2>&1 || finalize_status=$?
[ "$finalize_status" -eq 4 ] && ok "a cycle that conflicts with the remote ends with exit status 4" || bad "finalize exited $finalize_status: $(tail -4 "$finalize_log")"
grep -q "Sync failed: .*shared-start.txt" "$finalize_log" && ok "the conflicting file is named" || bad "log: $(grep -i "sync\|conflict" "$finalize_log")"
[ "$(cat shared-start.txt)" = "first scheduler's version" ] && [ -z "$(git status --porcelain)" ] && [ ! -d .git/rebase-merge ] \
    && [ -n "$(git log --format=%s --grep="Day 0: rewrite shared-start.txt")" ] \
    && ok "the session's commits are kept on the local branch, with no rebase left open" || bad "after the conflict: $(git status -sb | head -5)"
[ "$(remote_branch_sha origin)" = "$origin_before" ] && ! grep -q "Push failed\|Tag push" "$finalize_log" \
    && ok "nothing is pushed after a failed sync" || bad "origin moved, or a push was tried: $(grep -i "push" "$finalize_log")"

# ── A branch whose upstream has another name: git refuses the plain push, and the cycle says so (#137) ──
new_project upstream-with-another-name
new_bare_remote origin
git push -q -u origin "$branch"
git checkout -q -b feature "origin/$branch"
run_session only.txt
[ "$finalize_status" -eq 4 ] && grep -q "Push failed: fatal: The upstream branch of your current branch does not match" "$finalize_log" \
    && ok "a push git refuses for the upstream's name fails the cycle with git's reason" || bad "exit $finalize_status: $(tail -4 "$finalize_log")"

# ── The remote cannot be reached: the fetch is reported, the push is still tried, the cycle fails (#137) ──
new_project unreachable-remote
new_bare_remote origin
git push -q -u origin "$branch"
git remote set-url origin "$work_dir/no-such-repository.git"
run_session only.txt
[ "$finalize_status" -eq 4 ] && grep -q "Could not fetch refs/heads/$branch from origin" "$finalize_log" && grep -q "Push failed: " "$finalize_log" \
    && ok "an unreachable remote is reported for the fetch and the push, and fails the cycle" || bad "exit $finalize_status: $(tail -5 "$finalize_log")"

# ── Only the tag is refused: the cycle's commits are on the remote, so it is reported but not a failure ──
new_project tag-refused
new_bare_remote origin
git push -q -u origin "$branch"
printf '#!/bin/sh\ncase "$1" in refs/tags/*) echo "no tags here" >&2; exit 1 ;; esac\n' > "$PWD-origin.git/hooks/update"
chmod +x "$PWD-origin.git/hooks/update"
run_session only.txt
[ "$finalize_status" -eq 0 ] && [ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && grep -q "Tag push failed: " "$finalize_log" \
    && grep -q "=== Day 0 complete ===" "$finalize_log" \
    && ok "a refused tag alone is reported and the cycle still counts as pushed" || bad "exit $finalize_status: $(tail -5 "$finalize_log")"

# ── No remote at all ──
new_project no-remote
run_session only.txt
[ "$finalize_status" -eq 0 ] && ok "a repo with no remote finalizes without an error exit" || bad "finalize exited $finalize_status"
! grep -qi "failed" "$finalize_log" && grep -q "No remote" "$finalize_log" \
    && ok "no remote is reported quietly, not as a failure" || bad "log: $(grep -i "push\|remote" "$finalize_log")"
git tag --list 'day0-*' | grep -q . && ok "the session is still tagged locally" || bad "no local tag"

# ── An upstream given as a path, with no named remote, is still pushed to ──
new_project upstream-by-path
git init -q --bare "$PWD-target.git"
git config "branch.$branch.remote" "$PWD-target.git"
git config "branch.$branch.merge" "refs/heads/$branch"
git config push.default current
run_session only.txt
[ "$(git ls-remote "$PWD-target.git" "refs/heads/$branch" | cut -f1)" = "$(git rev-parse HEAD)" ] && ! grep -q "No remote" "$finalize_log" \
    && ok "an upstream that is a path rather than a named remote is pushed to" || bad "upstream by path: $(tail -4 "$finalize_log")"

# ── A push destination configured as a path, with no named remote and no upstream ──
new_project push-default-by-path
git init -q --bare "$PWD-target.git"
git config remote.pushDefault "$PWD-target.git"
run_session only.txt
[ "$(git ls-remote "$PWD-target.git" "refs/heads/$branch" | cut -f1)" = "$(git rev-parse HEAD)" ] \
    && [ "$(remote_tag_count "$PWD-target.git")" -eq 1 ] && ! grep -q "No remote" "$finalize_log" \
    && ok "a push destination that is a path rather than a named remote is pushed to" || bad "pushDefault by path: $(tail -4 "$finalize_log")"

# ── One remote that is not called origin ──
new_project single-remote
new_bare_remote backup
run_session only.txt
[ "$(remote_branch_sha backup)" = "$(git rev-parse HEAD)" ] && [ "$(remote_tag_count backup)" -eq 1 ] \
    && [ "$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" = "backup/$branch" ] \
    && ok "the only remote is used when none is called origin" || bad "single remote: $(tail -4 "$finalize_log")"

# ── Several remotes, none called origin: nothing to choose by ──
new_project several-remotes
new_bare_remote alpha
new_bare_remote beta
run_session only.txt
[ "$finalize_status" -eq 0 ] && [ -z "$(remote_branch_sha alpha)$(remote_branch_sha beta)" ] \
    && ok "with several remotes and no origin nothing is pushed" || bad "several remotes: $(tail -4 "$finalize_log")"
grep -q "git push -u <remote> $branch" "$finalize_log" && grep -q "alpha" "$finalize_log" && grep -q "beta" "$finalize_log" \
    && ok "the skip names the remotes and the command to run" || bad "log: $(grep -i "push\|remote" "$finalize_log")"

# ── Several remotes including origin ──
new_project origin-among-several
new_bare_remote alpha
new_bare_remote origin
run_session only.txt
[ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && [ -z "$(remote_branch_sha alpha)" ] \
    && ok "origin is preferred among several remotes" || bad "origin among several: $(tail -4 "$finalize_log")"

# ── A fork setup: git is told where to push, and that wins over origin ──
new_project push-default
new_bare_remote origin
new_bare_remote fork
git config remote.pushDefault fork
run_session only.txt
[ "$(remote_branch_sha fork)" = "$(git rev-parse HEAD)" ] && [ -z "$(remote_branch_sha origin)" ] \
    && [ "$(remote_tag_count fork)" -eq 1 ] && [ "$(remote_tag_count origin)" -eq 0 ] \
    && ok "remote.pushDefault decides where a never-pushed branch and its tag go" || bad "pushDefault: $(tail -4 "$finalize_log")"

new_project push-remote
new_bare_remote origin
new_bare_remote fork
new_bare_remote other
git config remote.pushDefault other
git config "branch.$branch.pushRemote" fork
run_session only.txt
[ "$(remote_branch_sha fork)" = "$(git rev-parse HEAD)" ] && [ -z "$(remote_branch_sha origin)$(remote_branch_sha other)" ] \
    && ok "branch.<name>.pushRemote wins over remote.pushDefault" || bad "pushRemote: $(tail -4 "$finalize_log")"

# ── A push mapping configured on the remote is kept: the cycle goes to the branch it names ──
new_project push-refspec
new_bare_remote origin
git config remote.origin.push "refs/heads/$branch:refs/heads/deploy"
run_session only.txt
[ "$(git ls-remote origin refs/heads/deploy | cut -f1)" = "$(git rev-parse HEAD)" ] && [ -z "$(remote_branch_sha origin)" ] \
    && [ "$(remote_tag_count origin)" -eq 1 ] && ! grep -q "Push failed" "$finalize_log" \
    && ok "a configured remote.<name>.push mapping decides the destination branch" || bad "push refspec: $(tail -4 "$finalize_log"); $(git ls-remote origin)"

# ── A remote recorded for the branch without a merge ref is not an upstream ──
new_project remote-without-merge
new_bare_remote origin
new_bare_remote fork
git config "branch.$branch.remote" fork
run_session only.txt
[ "$(remote_branch_sha fork)" = "$(git rev-parse HEAD)" ] && [ -z "$(remote_branch_sha origin)" ] && ! grep -q "Push failed" "$finalize_log" \
    && [ "$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" = "fork/$branch" ] \
    && ok "a branch with a remote but no merge ref is pushed to that remote with its upstream set" || bad "remote without merge: $(tail -4 "$finalize_log")"

# ── A mirror remote takes everything in one push; git refuses a refspec for it ──
new_project mirror
new_bare_remote origin
git config remote.origin.mirror true
run_session only.txt
[ "$(remote_branch_sha origin)" = "$(git rev-parse HEAD)" ] && [ "$(remote_tag_count origin)" -eq 1 ] && ! grep -q "failed" "$finalize_log" \
    && ok "a mirror remote receives the branch and the tag" || bad "mirror: $(tail -4 "$finalize_log")"

# ── A tag named like the branch must not hide the branch's upstream ──
new_project branch-and-tag-share-a-name
new_bare_remote origin
new_bare_remote fork
git push -q -u fork "refs/heads/$branch"
git tag "$branch"
run_session only.txt
[ "$(remote_branch_sha fork)" = "$(git rev-parse HEAD)" ] && [ -z "$(remote_branch_sha origin)" ] \
    && ok "a branch that shares its name with a tag is still pushed to its upstream" || bad "branch and tag share a name: $(tail -4 "$finalize_log")"

# ── Detached HEAD: there is no branch to push ──
new_project detached
new_bare_remote origin
git checkout -q --detach
run_session only.txt
[ "$finalize_status" -eq 0 ] && grep -q "detached" "$finalize_log" && ! grep -q "Push failed" "$finalize_log" \
    && ok "a detached HEAD skips the branch push and says so" || bad "detached: $(tail -4 "$finalize_log")"
[ "$(remote_tag_count origin)" -eq 1 ] && ok "the tag still goes out from a detached HEAD" || bad "tags on origin: $(git ls-remote --tags origin)"

cd /
echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
