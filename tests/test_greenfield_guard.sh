#!/bin/bash
# Test: evolve.sh seeds an initial commit on zero-commit (greenfield) repos
# so SESSION_START_SHA and the later revert/log logic have a valid base.
# Regression test for issue #19 (P0.2).
#
# Runs the REAL guard block extracted from evolve.sh against temp repos —
# no API key or agent needed.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/templates/scripts/evolve.sh"

# Extract the guard block: from the "Step 5" marker through the SESSION_START_SHA capture.
GUARD=$(sed -n '/# ── Step 5: Run evolution session ──/,/^SESSION_START_SHA=/p' "$SCRIPT")

run_guard() {
    # Run the extracted guard in the current dir with the same strict flags evolve.sh uses.
    bash -c "set -euo pipefail
$GUARD
echo \"HEAD=\$SESSION_START_SHA\""
}

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

# ── Case 1: zero-commit greenfield repo, no git identity configured ──
T1=$(mktemp -d)
( cd "$T1"
  git init -q
  # deliberately no user.name/user.email — true fresh `git init`
  if run_guard >/dev/null 2>&1; then echo PASS; else echo CRASH; fi
) > "$T1/result" 2>&1 || true
check "greenfield run does not abort" "$(cat "$T1/result")" "PASS"
( cd "$T1"; git rev-parse --verify -q HEAD >/dev/null 2>&1 && echo HASHEAD || echo NOHEAD ) > "$T1/head"
check "greenfield repo has a HEAD afterwards" "$(cat "$T1/head")" "HASHEAD"
rm -rf "$T1"

# ── Case 2: existing repo with history is unaffected (SHA unchanged) ──
T2=$(mktemp -d)
( cd "$T2"
  git init -q
  git config user.name t; git config user.email t@t
  git commit --allow-empty -q -m first
  BEFORE=$(git rev-parse HEAD)
  run_guard >/dev/null 2>&1
  AFTER=$(git rev-parse HEAD)
  [ "$BEFORE" = "$AFTER" ] && echo SAME || echo CHANGED
) > "$T2/result" 2>&1 || echo CRASH > "$T2/result"
check "existing repo HEAD unchanged" "$(cat "$T2/result")" "SAME"
rm -rf "$T2"

# ── Case 3: revert path survives an empty seed commit (greenfield build-fail) ──
# Extract the real revert checkout line and run it where the baseline tree is empty
# but the agent has since added files. It must not abort under set -e.
REVERT=$(sed -n '/if git checkout "\$SESSION_START_SHA" -- "\$PROJECT_DIR\/" 2>\/dev\/null; then/,/^            fi$/p' "$SCRIPT")
[ -n "$REVERT" ] || { echo "  FAIL: could not extract revert block from evolve.sh"; exit 1; }
T3=$(mktemp -d); R3=$(mktemp)   # result file lives OUTSIDE the repo (git clean would remove it)
( cd "$T3"
  git init -q; git config user.name t; git config user.email t@t
  git commit --allow-empty -q -m seed      # empty baseline, like the greenfield seed
  SESSION_START_SHA=$(git rev-parse HEAD)
  PROJECT_DIR=.
  echo "broken code" > app.js; git add -A   # agent's generated file
  bash -c "set -euo pipefail; SESSION_START_SHA=$SESSION_START_SHA; PROJECT_DIR=.; $REVERT" && echo PASS || echo CRASH
  [ -e app.js ] && echo "KEPT" || echo "REMOVED"
) > "$R3" 2>&1 || echo CRASH >> "$R3"
check "revert against empty baseline does not abort" "$(sed -n '1p' "$R3")" "PASS"
check "empty-baseline revert removes generated files" "$(tail -1 "$R3")" "REMOVED"
rm -rf "$T3" "$R3"

# ── Case 4: inclusive seed → revert restores pre-session file content (parity) ──
# A greenfield repo with existing files: the seed commits them, so a failed-build
# revert restores their original content instead of being a no-op.
T4=$(mktemp -d)
( cd "$T4"
  git init -q
  echo "v1" > existing.txt          # pre-session content, not yet committed
  run_guard >/dev/null 2>&1          # seeds initial commit including existing.txt
  SESSION_START_SHA=$(git rev-parse HEAD)
  echo "v2-broken" > existing.txt; git add -A   # "session" modifies it
  bash -c "set -euo pipefail; SESSION_START_SHA=$SESSION_START_SHA; PROJECT_DIR=.; $REVERT"
  cat existing.txt
) > "$T4/result" 2>&1 || echo CRASH >> "$T4/result"
check "revert restores pre-session content" "$(tail -1 "$T4/result")" "v1"
rm -rf "$T4"

# ── Case 5: non-empty baseline revert removes session-added files, keeps untracked ──
T5=$(mktemp -d); R5=$(mktemp)
( cd "$T5"
  git init -q; git config user.name t; git config user.email t@t
  echo base > kept.txt; git add -A; git commit -q -m base   # baseline has kept.txt
  SESSION_START_SHA=$(git rev-parse HEAD)
  echo broken > added.js; git add -A; git commit -q -m "session add"   # session-added, committed
  echo "user notes" > untracked.txt                          # pre-existing untracked user file
  bash -c "set -euo pipefail; SESSION_START_SHA=$SESSION_START_SHA; PROJECT_DIR=.; $REVERT"
  { [ ! -e added.js ] && echo "ADDED_REMOVED" || echo "ADDED_KEPT"; }
  { [ -e untracked.txt ] && [ -e kept.txt ] && echo "USER_SAFE" || echo "USER_LOST"; }
) > "$R5" 2>&1 || echo CRASH >> "$R5"
check "revert removes session-added file" "$(sed -n '1p' "$R5")" "ADDED_REMOVED"
check "revert keeps untracked + baseline files" "$(tail -1 "$R5")" "USER_SAFE"
rm -rf "$T5" "$R5"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
