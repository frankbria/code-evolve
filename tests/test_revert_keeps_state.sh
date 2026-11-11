#!/bin/bash
# Test (#98): a reverted session takes the code back to where the session started, but keeps
# what the session learned (.evolve/LEARNINGS.md) and the day it ran on (.evolve/DAY_COUNT).
# The files that describe the reverted work (spec checkboxes, the agent's journal entry) go back.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"; mkdir -p "$stub_dir"
# claude stub: on its first call it does a session's worth of work (code, a lesson, a ticked
# spec box, a journal entry) and commits it, as the real agent does. Later calls change nothing.
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
cat > /dev/null
[ -e "$work/agent-ran" ] && exit 0
touch "$work/agent-ran"
echo "session work" > feature.js
echo "- LESSON-FROM-THE-FAILED-SESSION" >> .evolve/LEARNINGS.md
echo "- [x] SPEC-BOX-TICKED-BY-THE-SESSION" >> .evolve/spec.md
echo "AGENT-JOURNAL-ENTRY-FOR-REVERTED-WORK" >> .evolve/JOURNAL.md
git add -A && git commit -qm "session work"
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir"/*
export PATH="$stub_dir:$PATH"

new_project() {
    rm -f "$work/agent-ran"
    project="$(mktemp -d "$work/project.XXXXXX")"; cd "$project"
    git init -q; git config user.email t@example.com; git config user.name t
    printf '{"name":"demo","scripts":{"test":"echo FAILING-TEST-MARKER >&2; exit 1"}}\n' > package.json
    node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
    # Born three days ago, with the counter still at the value the last committed session left.
    # The local calendar date: the engine reads a bare date as local midnight.
    node -e "const b=new Date(Date.now()-3*86400000),p=n=>String(n).padStart(2,'0');require('fs').writeFileSync('.evolve/.birth_date',b.getFullYear()+'-'+p(b.getMonth()+1)+'-'+p(b.getDate()))"
    echo 2 > .evolve/DAY_COUNT
    git add -A -f .evolve/.birth_date . && git commit -qm "baseline"
}
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }

assert_reverted_session_kept_its_state() { # <label>
    check "$1: the session was reverted" "$(grep -c 'verification failed' .evolve/LAST_VERIFY.md)" "1"
    check "$1: the session's code is gone" "$([ -e feature.js ] && echo present || echo gone)" "gone"
    check "$1: the lesson it wrote is kept" "$(grep -c 'LESSON-FROM-THE-FAILED-SESSION' .evolve/LEARNINGS.md)" "1"
    check "$1: and is committed" "$(git status --porcelain -- .evolve/LEARNINGS.md)" ""
    check "$1: the lesson is in HEAD" "$(git show HEAD:.evolve/LEARNINGS.md | grep -c 'LESSON-FROM-THE-FAILED-SESSION')" "1"
    # Compared with the day the engine itself reported (3, or 4 if the run crosses local midnight
    # or follows a 25-hour day), never the committed 2 the revert used to bring back.
    check "$1: the day counter stays on the session's day" "$(cat .evolve/DAY_COUNT)" "$(sed -n '1s/^Day \([0-9]*\) .*/\1/p' .evolve/LAST_VERIFY.md)"
    check "$1: which is not the day committed before the session" "$(grep -cx 2 .evolve/DAY_COUNT || true)" "0"
    check "$1: the spec box for the reverted work is unticked again" "$(grep -c 'SPEC-BOX-TICKED-BY-THE-SESSION' .evolve/spec.md || true)" "0"
    check "$1: the journal entry for the reverted work is gone" "$(grep -c 'AGENT-JOURNAL-ENTRY-FOR-REVERTED-WORK' .evolve/JOURNAL.md || true)" "0"
    check "$1: the failure is recorded as a requirement" "$(grep -c '^## REQ-0001: Build failed after revert' .evolve/REQUIREMENTS.md)" "1"
}

# A headless cycle.
new_project
engine > "$work/cycle.log" 2>&1 || true
assert_reverted_session_kept_its_state "cycle"

# The agent-driven flow: prepare, the session's work, verify, finalize --no-agent.
new_project
engine prepare > "$work/prepare.log" 2>&1
claude < /dev/null
engine verify > "$work/verify.log" 2>&1 || true
engine finalize --no-agent > "$work/finalize.log" 2>&1 || true
assert_reverted_session_kept_its_state "split flow"

# A session that wrote no lesson leaves LEARNINGS.md exactly as it was.
new_project
touch "$work/agent-ran"
learnings_before=$(git hash-object .evolve/LEARNINGS.md)
engine > "$work/quiet.log" 2>&1 || true
check "no lesson written: LEARNINGS.md is unchanged" "$(git hash-object .evolve/LEARNINGS.md)" "$learnings_before"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
