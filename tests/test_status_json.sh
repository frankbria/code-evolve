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
check "a session finalize already removed is neither pending nor abandoned" \
    "$(status_field '[v.pendingSession, v.abandonedSession]')" "[false,false]"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
