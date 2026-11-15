#!/bin/bash
# Test (#147, #164): `status` and `proof` report the same day in every state, today's day even
# between cycles, `init` records the birth date on the local calendar (the one the engine counts
# from), the engine never writes a negative day, and days are counted on the calendar, so a
# 23-hour day (a clock change) still counts as one.
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
local_date() { node -e "const b=new Date();b.setDate(b.getDate()+$1);const p=n=>String(n).padStart(2,'0');console.log(b.getFullYear()+'-'+p(b.getMonth()+1)+'-'+p(b.getDate()))"; }
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
check "an older install before its first cycle: status counts from the birth date" "$(status_day)" "10"
check "and proof reports the same day" "$(proof_day)" "10"

# After a cycle wrote DAY_COUNT, and between cycles when it is a day or more behind.
echo 10 > .evolve/DAY_COUNT
check "after a cycle: status reports the engine's day" "$(status_day)" "10"
echo 4 > .evolve/DAY_COUNT
check "between cycles: status reports today's day, not the last cycle's" "$(status_day)" "10"
check "and proof reports the same day" "$(proof_day)" "10"
# GNU script takes -c, BSD script takes the command after the file.
terminal_status() { if script -qec true /dev/null >/dev/null 2>&1; then script -qec "node '$CLI' status" /dev/null; else script -q /dev/null node "$CLI" status; fi; }
check "the terminal view prints that day" "$(terminal_status 2>/dev/null | grep -c 'Day:      10' || true)" "1"

# A birth date a day or more in the future (a clock that was set back) must not produce a
# negative day.
new_project
local_date 2 > .evolve/.birth_date
git add -A -f .evolve/.birth_date . && git commit -qm baseline
engine prepare > "$work/future.log" 2>&1 || true
check "a future birth date: the engine writes Day 0" "$(cat .evolve/DAY_COUNT)" "0"
check "and announces Day 0" "$(grep -c '^=== Day 0 ' "$work/future.log")" "1"
check "and the session is Day 0" "$(sed -n 's/^DAY=//p' .evolve/run/session.env)" "0"
check "status agrees" "$(status_day)" "0"

# The engine's own day arithmetic, on dates (it needs no clock, so any date pair can be tried).
eval "$(sed -n '/^evolution_day()/,/^}/p;/^calendar_day_number()/,/^}/p' "$ROOT/templates/scripts/evolve.sh")"
check "a month boundary" "$(evolution_day 2026-01-31 2026-02-01)" "1"
check "a leap day" "$(evolution_day 2024-02-28 2024-03-01)" "2"
check "a year boundary" "$(evolution_day 2025-12-31 2026-01-01)" "1"
check "the same day" "$(evolution_day 2026-03-09 2026-03-09)" "0"
check "a long stretch" "$(evolution_day 2025-03-09 2026-03-09)" "365"
check "a birth date ahead of today" "$(evolution_day 2026-03-12 2026-03-09)" "0"
check "an unreadable birth date is Day 0" "$(evolution_day nonsense 2026-03-09)" "0"
# A UTC timestamp from an older install counts from its local date, as `code-evolve status` does
# (GNU date here, BSD date on the macOS CI job).
check "a UTC timestamp counts from its local date" "$(TZ=America/New_York evolution_day 2026-03-01T01:00:00.000Z 2026-03-02)" "2"

# A 23-hour day: with clocks moved forward on 2026-03-08, the first hour of 2026-03-09 is 8 days
# minus an hour after the start of 2026-03-01 in seconds, but 8 calendar days. Needs a date that
# can be told what time it is (GNU -d); the zone is a POSIX rule, so it needs no zone database.
if date -d "2000-01-01 00:00:00" +%s >/dev/null 2>&1; then
    real_date="$(command -v date)"
    mkdir -p "$work/fakedate"
    printf '#!/bin/bash\ncase "$*" in *-d*) exec "%s" "$@" ;; esac\nfor arg in "$@"; do case "$arg" in +*) exec "%s" -d "$FAKE_NOW" "$@" ;; esac; done\nexec "%s" "$@"\n' "$real_date" "$real_date" "$real_date" > "$work/fakedate/date"
    chmod +x "$work/fakedate/date"
    new_project
    echo 2026-03-01 > .evolve/.birth_date
    git add -A -f . && git commit -qm baseline
    TZ='EST5EDT,M3.2.0,M11.1.0' FAKE_NOW="2026-03-09 00:30:00" PATH="$work/fakedate:$PATH" engine prepare > "$work/dst.log" 2>&1 || true
    check "the first hour after a 23-hour day: the engine counts calendar days" "$(cat .evolve/DAY_COUNT)" "8"
    check "and announces that day" "$(grep -c '^=== Day 8 (2026-03-09 00:30)' "$work/dst.log")" "1"
else
    echo "  skip: the 23-hour day check needs GNU date"
fi

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
