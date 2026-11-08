#!/bin/bash
# Test (#81): `code-evolve status` (JSON when not a terminal, as agents call it) reports PROOF9
# requirement counts and whether an in-session cycle is pending, which the evolve-status skill uses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

stub_dir="$(mktemp -d)"
project="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$project"' EXIT
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"; chmod +x "$stub_dir/claude"
cd "$project"
git init -q
PATH="$stub_dir:$PATH" node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1

status_field() { node "$CLI" status </dev/null | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const v=JSON.parse(s);console.log(JSON.stringify($1))})"; }

check "fresh install: no requirements" "$(status_field 'v.requirements')" '{"open":0,"regressed":0,"satisfied":0,"waived":0}'
check "fresh install: no pending session" "$(status_field 'v.pendingSession')" "false"

printf '\n## REQ-0001: a\n- **Status**: open\n\n## REQ-0002: b\n- **Status**: regressed\n\n## REQ-0003: c\n- **Status**: satisfied\n' >> .evolve/REQUIREMENTS.md
mkdir -p .evolve/run && echo "DAY=0" > .evolve/run/session.env
check "requirements are counted by status" "$(status_field 'v.requirements')" '{"open":1,"regressed":1,"satisfied":1,"waived":0}'
check "a prepared session is reported as pending" "$(status_field 'v.pendingSession')" "true"
check "an old prepared session is reported as abandoned, not pending" \
    "$(PENDING_SESSION_MAX_MINUTES=0 status_field '[v.pendingSession, v.abandonedSession]')" "[false,true]"
rm .evolve/run/session.env
check "a run dir left without session.env (a failed prepare) is abandoned" \
    "$(status_field '[v.pendingSession, v.abandonedSession]')" "[false,true]"
rm -rf .evolve/run
check "no run dir: neither pending nor abandoned" \
    "$(status_field '[v.pendingSession, v.abandonedSession]')" "[false,false]"

printf '\n## REQ-0004: d\n- **Status**: waived\n- **Waiver expires**: Day 0\n\n## REQ-0005: e\n- **Status**: waived\n- **Waiver expires**: Day 99\n' >> .evolve/REQUIREMENTS.md
echo 3 > .evolve/DAY_COUNT
check "an expired waiver counts as open; a live one as waived" "$(status_field 'v.requirements')" '{"open":2,"regressed":1,"satisfied":1,"waived":1}'
# Same day as `proof`: without DAY_COUNT the day comes from the birth date (10 days ago -> Day 10).
rm .evolve/DAY_COUNT
node -e "require('fs').writeFileSync('.evolve/.birth_date', new Date(Date.now() - 10 * 86400000).toISOString())"
sed -i 's/Waiver expires\*\*: Day 99/Waiver expires**: Day 5/' .evolve/REQUIREMENTS.md
check "waiver expiry uses the birth-date day when DAY_COUNT is missing" "$(status_field 'v.requirements')" '{"open":3,"regressed":1,"satisfied":1,"waived":0}'

check "fresh install: engine matches this version" "$(status_field 'v.engineDrift')" "[]"
echo "# stale" >> .evolve/scripts/agents/claude.sh
rm .evolve/scripts/hold_lock.py
check "edited or missing engine files are reported as drift" "$(status_field 'v.engineDrift')" '["agents/claude.sh","hold_lock.py"]'
chmod a-r .evolve/scripts/evolve.sh
check "an unreadable engine file reports drift as unknown instead of failing" "$(status_field 'v.engineDrift')" "null"
chmod u+r .evolve/scripts/evolve.sh
PATH="$stub_dir:$PATH" node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
check "init --yes clears the drift" "$(status_field 'v.engineDrift')" "[]"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
