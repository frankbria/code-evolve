#!/bin/bash
# Test (#132): what finalize pushes. A branch that was never pushed goes out with its upstream
# set (it used to stay behind while the tag went out alone); the remote is origin, else the only
# one; no remote is quiet; and a failed push is reported with git's own reason.
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
    git add "$1" && git commit -qm "Day 0: add $1"
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

# ── A push the remote rejects is reported with git's reason ──
git clone -q "$PWD-origin.git" "$work_dir/other-clone"
git -C "$work_dir/other-clone" -c user.email=other@example.com -c user.name=other commit -q --allow-empty -m "someone else's commit"
git -C "$work_dir/other-clone" push -q origin "HEAD:$branch"
run_session third.txt
[ "$finalize_status" -eq 0 ] && ok "a rejected push does not fail finalize" || bad "finalize exited $finalize_status"
grep -q "Push failed: .*rejected" "$finalize_log" \
    && ok "a rejected push is reported with git's own line" || bad "log: $(grep -i "push" "$finalize_log")"
! grep -q "maybe no remote" "$finalize_log" && ok "the failure message no longer guesses" || bad "log still guesses"

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
