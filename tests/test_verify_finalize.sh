#!/bin/bash
# Test (#78): the phase split end to end. An in-session caller runs prepare, does the work
# itself, then verify and `finalize --no-agent`, with no agent binary on PATH at all: passing
# work is committed, tagged and journaled; failing work is reverted with a REQ captured. A
# scheduled cycle leaves a pending prepared session alone and discards an abandoned one.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

tools_dir="$(mktemp -d)"
trap 'rm -rf "$tools_dir"' EXIT
# PATH with node and the system tools but no agent CLI (the nvm bin dir may hold a real `claude`).
ln -s "$(command -v node)" "$tools_dir/node"
printf '#!/bin/bash\nexit 1\n' > "$tools_dir/gh"; chmod +x "$tools_dir/gh"
agentless_path="$tools_dir:/usr/local/bin:/usr/bin:/bin"
command -v claude >/dev/null 2>&1 && PATH="$agentless_path" command -v claude >/dev/null 2>&1 \
    && bad "test setup: claude is still on the agentless PATH"

new_project() { # <test script for package.json>
    local project_dir
    project_dir="$(mktemp -d)"
    cd "$project_dir"
    git init -q
    git config user.email test@example.com
    git config user.name test
    printf '{"name":"demo","scripts":{"build":"true","test":"%s"}}\n' "$1" > package.json
    printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\ncat >/dev/null\n' > "$tools_dir/claude"
    chmod +x "$tools_dir/claude"
    PATH="$agentless_path" node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed"
    rm -f "$tools_dir/claude"
    git add -A && git commit -qm "baseline"
}
engine() { env -i PATH="$agentless_path" HOME="$HOME" EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude \
    PENDING_SESSION_MAX_MINUTES="${PENDING_SESSION_MAX_MINUTES:-240}" bash .evolve/scripts/evolve.sh "$@"; }

# ── Passing work: prepare → edit → verify → finalize --no-agent ──
new_project true
pass_dir="$PWD"
engine prepare > prepare.log 2>&1 || bad "prepare failed: $(tail -2 prepare.log)"
baseline_sha=$(git rev-parse HEAD)
echo "feature" > feature.txt
git add feature.txt && git commit -qm "Day 0: add feature"
verify_status=0; engine verify > verify.log 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && grep -q "Build: PASS" verify.log \
    && ok "verify passes good work and calls no agent" || bad "verify exited $verify_status: $(tail -2 verify.log)"
finalize_status=0; engine finalize --no-agent > finalize.log 2>&1 || finalize_status=$?
[ "$finalize_status" -eq 0 ] && ok "finalize --no-agent succeeds with no agent CLI on PATH" || bad "finalize exited $finalize_status: $(tail -3 finalize.log)"
[ "$(cat feature.txt 2>/dev/null)" = "feature" ] && git cat-file -e HEAD:feature.txt 2>/dev/null \
    && ok "the session's work stays committed" || bad "feature.txt missing after finalize"
git tag --list 'day0-*' | grep -q . && ok "finalize tags the session" || bad "no day0 tag"
grep -q "^## Day 0" .evolve/JOURNAL.md && ok "finalize writes the journal entry via the bash fallback" || bad "no journal entry"
[ ! -e .evolve/run ] && ok "finalize clears .evolve/run/" || bad ".evolve/run still present"
[ "$(git rev-list --count "$baseline_sha"..HEAD)" -ge 1 ] && ok "finalize committed on top of the baseline" || bad "no new commits"
cd / && rm -rf "$pass_dir"

# ── Failing work: verify fails, finalize reverts and captures a REQ ──
new_project true
fail_dir="$PWD"
engine prepare > prepare.log 2>&1 || bad "prepare (fail case) failed"
printf '{"name":"demo","scripts":{"build":"true","test":"echo broken-test >&2; exit 1"}}\n' > package.json
echo "broken" > broken.txt
git add -A && git commit -qm "Day 0: broken change"
echo "generated" > generated.js
verify_status=0; engine verify > verify.log 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "verify fails broken work and writes ERRORS.md" || bad "verify exited $verify_status, ERRORS.md: $(cat .evolve/run/ERRORS.md 2>/dev/null)"
engine finalize --no-agent > finalize.log 2>&1 || bad "finalize (fail case) failed: $(tail -2 finalize.log)"
[ ! -e broken.txt ] && grep -q '"test":"true"' package.json \
    && ok "finalize reverts the failed session to its starting point" || bad "revert did not happen: $(ls)"
[ ! -e generated.js ] && ! git cat-file -e HEAD:generated.js 2>/dev/null \
    && ok "the revert also removes untracked files the session created" || bad "generated.js survived the revert"
grep -q "^## REQ-0001: Build failed after revert" .evolve/REQUIREMENTS.md \
    && ok "finalize captures REQ-0001 for the failure" || bad "no REQ captured"
cd / && rm -rf "$fail_dir"

# ── A project with tests but no build script is still verified (#108) ──
new_project "echo only-tests-fail >&2; exit 1"
printf '{"name":"demo","scripts":{"test":"echo only-tests-fail >&2; exit 1"}}\n' > package.json
git commit -qam "no build script"
engine prepare > prepare.log 2>&1 || bad "prepare (test-only) failed"
verify_status=0; engine verify > verify.log 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "only-tests-fail" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "verify runs the tests of a project with no build command" || bad "test-only project verify exited $verify_status: $(tail -2 verify.log)"
cd / && rm -rf "$OLDPWD"

# ── Same in a headless cycle: the fix loop runs for a test-only project, then reverts (#108) ──
new_project "echo only-tests-fail >&2; exit 1"
cycle_dir="$PWD"
printf '{"name":"demo","scripts":{"test":"echo only-tests-fail >&2; exit 1"}}\n' > package.json
git commit -qam "no build script"
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\necho call >> "%s/fix-calls"\ncat >/dev/null\n' "$tools_dir" > "$tools_dir/claude"
chmod +x "$tools_dir/claude"
rm -f "$tools_dir/fix-calls"
engine > cycle.log 2>&1 || true
rm -f "$tools_dir/claude"
grep -q "Build issues (attempt 1/3)" cycle.log && git log --format=%s | grep -q "revert session changes" \
    && ok "a headless cycle fixes, then reverts, a test-only project whose tests fail" \
    || bad "test-only cycle: $(grep -E 'Build|revert' cycle.log | head -3)"
cd / && rm -rf "$cycle_dir"

# ── A command planted in session.env is never executed ──
new_project true
planted_dir="$PWD"
engine prepare > prepare.log 2>&1 || bad "prepare (planted) failed"
printf 'MODEL=$(touch %s/pwned)\nEVIL_KEY=`touch %s/pwned2`\n' "$planted_dir" "$planted_dir" >> .evolve/run/session.env
engine verify > verify.log 2>&1 || true
engine finalize --no-agent > finalize.log 2>&1 || true
[ ! -e pwned ] && [ ! -e pwned2 ] && ok "values planted in session.env are read as data, never run" || bad "a planted command ran"
cd / && rm -rf "$planted_dir"

# ── prepare refuses to replace a pending session; an abandoned one is discarded cleanly ──
new_project true
again_dir="$PWD"
engine prepare > prepare.log 2>&1 || bad "first prepare failed"
second_status=0; engine prepare > prepare2.log 2>&1 || second_status=$?
[ "$second_status" -eq 1 ] && grep -q "still pending" prepare2.log \
    && ok "a second prepare refuses to replace a pending session" || bad "second prepare exited $second_status"
echo fail > .evolve/run/verify.status
PENDING_SESSION_MAX_MINUTES=0 engine prepare > prepare3.log 2>&1 || bad "prepare over an abandoned session failed"
[ ! -e .evolve/run/verify.status ] && ok "a fresh prepare drops the old session's verify result" || bad "stale verify.status kept"
cd / && rm -rf "$again_dir"

# ── finalize uses the agent the session was prepared with ──
new_project true
agent_dir="$PWD"
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\necho "codex $*" >> "%s/codex-calls"\ncat >/dev/null\n' "$tools_dir" > "$tools_dir/codex"
chmod +x "$tools_dir/codex"
env -i PATH="$agentless_path" HOME="$HOME" EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=codex bash .evolve/scripts/evolve.sh prepare > prepare.log 2>&1 \
    || bad "codex prepare failed: $(tail -2 prepare.log)"
finalize_status=0; engine finalize > finalize.log 2>&1 || finalize_status=$?
[ "$finalize_status" -eq 0 ] && ! grep -q "Agent 'claude'" finalize.log \
    && ok "finalize runs with the session's agent (codex), not the default" || bad "finalize exited $finalize_status: $(tail -2 finalize.log)"
rm -f "$tools_dir/codex"
cd / && rm -rf "$agent_dir"

# ── Scheduling: pending vs abandoned prepared sessions, and phases without a session ──
new_project true
sched_dir="$PWD"
missing_status=0; engine verify > missing.log 2>&1 || missing_status=$?
[ "$missing_status" -eq 2 ] && grep -q "Run: evolve.sh prepare" missing.log \
    && ok "verify without a prepared session exits 2 with guidance" || bad "verify without session exited $missing_status"
engine prepare > prepare.log 2>&1 || bad "prepare (schedule case) failed"
# A scheduled cycle runs the agent, so this part gets a stub agent CLI.
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && exit 0\ncat >/dev/null\n' > "$tools_dir/claude"; chmod +x "$tools_dir/claude"
cycle_status=0; engine > cycle.log 2>&1 || cycle_status=$?
[ "$cycle_status" -eq 0 ] && grep -q "skipping this run" cycle.log && [ -f .evolve/run/session.env ] \
    && ok "a scheduled cycle leaves a pending prepared session alone" || bad "cycle with pending session: $(tail -2 cycle.log)"
PENDING_SESSION_MAX_MINUTES=0 engine > cycle2.log 2>&1 || true
grep -q "Discarding an abandoned prepared session" cycle2.log \
    && ok "a scheduled cycle discards an abandoned prepared session" || bad "abandoned session not discarded: $(head -5 cycle2.log)"
cd / && rm -rf "$sched_dir"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
