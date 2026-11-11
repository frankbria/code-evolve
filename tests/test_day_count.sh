#!/bin/bash
# Test (#147): `status` and `proof` report the same day in every state, `init` records the birth
# date on the local calendar (the one the engine counts from), and the engine never writes a
# negative day.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stub_dir="$work/bin"; mkdir -p "$stub_dir"
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && echo "claude 0.0.0-stub"\ncat >/dev/null\n' > "$stub_dir/claude"
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir"/*
export PATH="$stub_dir:$PATH"

new_project() {
    project="$(mktemp -d "$work/project.XXXXXX")"; cd "$project"
    git init -q; git config user.email t@example.com; git config user.name t
    printf '{"name":"demo","scripts":{"test":"true"}}\n' > package.json
    node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
    printf '\n## REQ-0001: a\n- **Status**: open\n' >> .evolve/REQUIREMENTS.md
}
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }
status_day() { node "$CLI" status </dev/null | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s).day))"; }
# The local calendar date <days> from now (negative: in the past).
local_date() { node -e "const b=new Date(Date.now()+$1*86400000),p=n=>String(n).padStart(2,'0');console.log(b.getFullYear()+'-'+p(b.getMonth()+1)+'-'+p(b.getDate()))"; }
# `proof waive` refuses an expiry that is not after its current day and names that day, so its
# day is the largest expiry it refuses (and it accepts the next one).
proof_day() {
    local day
    day=$(node "$CLI" proof waive REQ-0001 --reason probe --expires-day 100000 2>&1 | sed -n 's/.*(current day: \([0-9]*\)).*/\1/p')
    [ -n "$day" ] && { echo "$day"; return; }
    for day in $(seq 0 40); do
        node "$CLI" proof waive REQ-0001 --reason probe --expires-day "$((day + 1))" >/dev/null 2>&1 && { echo "$day"; return; }
    done
    echo "unknown"
}

# The zones are fixed offsets (UTC+14 and UTC-12) written the POSIX way, which needs no zone
# database. At every moment at least one of them is on a different calendar date from UTC.
zones_off_utc=0
for zone in XXX-14 XXX12; do
    export TZ="$zone"
    [ "$(date +%Y-%m-%d)" = "$(date -u +%Y-%m-%d)" ] || zones_off_utc=$((zones_off_utc + 1))
    date_before=$(date +%Y-%m-%d)
    new_project
    birth=$(cat .evolve/.birth_date)
    # Either side of the call, in case it ran across local midnight.
    check "$zone: init records the local date" "$([ "$birth" = "$date_before" ] || [ "$birth" = "$(date +%Y-%m-%d)" ] && echo local)" "local"
    check "$zone: status is on Day 0 before the first cycle" "$(status_day)" "0"
    check "$zone: and proof agrees" "$(proof_day)" "0"
    git add -A && git commit -qm baseline
    engine prepare > "$work/prepare.log" 2>&1 || true
    day_written=$(cat .evolve/DAY_COUNT)
    if [ "$(date +%Y-%m-%d)" = "$date_before" ]; then
        check "$zone: the first same-day cycle is Day 0" "$day_written" "0"
    else
        check "$zone: the first cycle is Day 0 or 1 (the test ran across local midnight)" "$([ "$day_written" -le 1 ] && echo yes)" "yes"
    fi
    check "$zone: status after that cycle" "$(status_day)" "$day_written"
    unset TZ
done
check "one of the zones is on another date than UTC right now" "$([ "$zones_off_utc" -ge 1 ] && echo yes)" "yes"

# Before the first cycle of an older install: DAY_COUNT is still the 0 init wrote.
new_project
local_date -10 > .evolve/.birth_date
day_from_birth=$(status_day)
# 10, or 9 in the first hour of a day that follows a 23-hour day.
check "an older install before its first cycle: status counts from the birth date" "$([ "$day_from_birth" -ge 9 ] && echo counted)" "counted"
check "and proof reports the same day" "$(proof_day)" "$day_from_birth"

# After a cycle wrote DAY_COUNT.
echo 4 > .evolve/DAY_COUNT
check "after a cycle: status reports the engine's day" "$(status_day)" "4"
check "and proof reports the same day" "$(proof_day)" "4"
check "the terminal view prints that day" "$(script -qec "node '$CLI' status" /dev/null 2>/dev/null | grep -c 'Day:      4' || true)" "1"

# A birth date in the future (a clock that was set back, or a file written by an older init
# west of UTC in the evening) must not produce a negative day.
new_project
local_date 2 > .evolve/.birth_date
git add -A -f .evolve/.birth_date . && git commit -qm baseline
engine prepare > "$work/future.log" 2>&1 || true
check "a future birth date: the engine writes Day 0" "$(cat .evolve/DAY_COUNT)" "0"
check "and announces Day 0" "$(grep -c '^=== Day 0 ' "$work/future.log")" "1"
check "and the session is Day 0" "$(sed -n 's/^DAY=//p' .evolve/run/session.env)" "0"
check "status agrees" "$(status_day)" "0"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
