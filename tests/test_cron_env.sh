#!/bin/bash
# Test (#71): the cron command installed by `code-evolve start` must hand the
# .evolve/.env values (API key, MODEL) to the engine, even when they contain
# shell-special characters, and two overlapping cycles must not both run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT

# claude stub: log argv and the key it received, then wait SLEEP_SECONDS so a
# second cycle can overlap. crontab stub: `-l` prints the captured table, `-`
# captures stdin, so the real crontab is never touched. gh fails (no network).
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
echo "argv=\$* key=\${ANTHROPIC_API_KEY:-<unset>} model_env=\${MODEL:-<unset>} run=\${RUN_ID:-cron}" >> "$stub_dir/agent-calls"
cat >/dev/null
sleep "\${SLEEP_SECONDS:-0}"
STUB
cat > "$stub_dir/crontab" <<STUB
#!/bin/bash
if [ "\${1:-}" = "-l" ]; then cat "$stub_dir/crontab.table" 2>/dev/null; exit 0; fi
cat > "$stub_dir/crontab.table"
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/crontab" "$stub_dir/gh"

# GNU timeout is not on stock macOS; fall back to perl's alarm, which is.
run_with_timeout() { # <seconds> <command...>
    if command -v timeout >/dev/null 2>&1; then timeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi
}

base_path="$stub_dir:$(dirname "$(command -v node)"):/usr/local/bin:/usr/bin:/bin"
tricky_key='sk-"quoted"-$HOME-`echo pwned`-'"'single'"

cd "$work_dir"
git init -q
git config user.email test@example.com
git config user.name test
echo "# demo" > README.md
git add README.md && git commit -qm init
env -i PATH="$base_path" HOME="$HOME" node "$CLI" init --agent claude >/dev/null 2>&1 \
    || bad "init failed"
env -i PATH="$base_path" HOME="$HOME" ANTHROPIC_API_KEY="$tricky_key" \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
    node "$CLI" start --every 4 --model my-model >/dev/null 2>&1 || bad "start failed"

cron_line=$(grep "code-evolve:" "$stub_dir/crontab.table" 2>/dev/null || true)
[ -n "$cron_line" ] && ok "start installed a cron entry" || bad "no cron entry captured"

# Run the cron command the way cron would: /bin/sh with cron's minimal environment.
cron_command=$(sed -E 's/^([^ ]+ +){5}//' <<<"$cron_line")
rm -f "$stub_dir/agent-calls"
run_with_timeout 120 env -i HOME="$HOME" PATH=/usr/bin:/bin SHELL=/bin/sh GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
    /bin/sh -c "$cron_command" || true

first_call=$(head -1 "$stub_dir/agent-calls" 2>/dev/null || true)
if [ "$first_call" = "argv=-p --model my-model --allowedTools Bash,Read,Write,Edit,Glob,Grep key=$tricky_key model_env=my-model run=cron" ]; then
    ok "cron run: agent env has MODEL and the exact API key from .env"
else
    bad "cron run: agent call was '$first_call'; log tail: $(tail -5 .evolve/evolve.log 2>/dev/null)"
fi
[ ! -e "$HOME/pwned" ] && ok "cron run: no command substitution from .env values" || bad "backticks in .env were executed"

# Two overlapping cycles: exactly one reaches the agent, the other exits 0 with a log line.
# Different TZ values must not make the live owner look like a different process.
rm -f "$stub_dir/agent-calls"
run_engine() { # <log-file> <run-id>   (honors RUN_TZ)
    env -i PATH="$base_path" HOME="$HOME" TZ="${RUN_TZ:-UTC}" ANTHROPIC_API_KEY=k SLEEP_SECONDS="${SLEEP_SECONDS:-6}" RUN_ID="$2" \
        GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
        GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
        EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
        bash .evolve/scripts/evolve.sh > "$1" 2>&1
}
RUN_TZ=America/New_York run_engine "$stub_dir/first.log" first & first_pid=$!
sleep 2
second_status=0; run_engine "$stub_dir/second.log" second || second_status=$?
wait "$first_pid" || true

grep -q "already running" "$stub_dir/second.log" && [ "$second_status" -eq 0 ] \
    && ok "overlap: second cycle exits 0 with an 'already running' line" \
    || bad "overlap: second cycle (exit $second_status): $(tail -3 "$stub_dir/second.log")"
grep -q "Day .* complete" "$stub_dir/first.log" \
    && ok "overlap: first cycle completed" || bad "overlap: first cycle did not complete: $(tail -3 "$stub_dir/first.log")"
grep -q " run=first$" "$stub_dir/agent-calls" 2>/dev/null && ! grep -q " run=second$" "$stub_dir/agent-calls" \
    && ok "overlap: only the first cycle called the agent" \
    || bad "overlap: agent calls: $(cat "$stub_dir/agent-calls" 2>/dev/null)"
# The kernel lock dies with its holder: no lock state survives a finished cycle...
lock_file="$(git rev-parse --absolute-git-dir)/code-evolve.lock"
lock_holders=$( (pgrep -f "hold_lock.py $lock_file" || true) | wc -l | tr -d " ")
[ "$lock_holders" = "0" ] && ok "lock released after the cycle (no holder left)" || bad "lock holder still running"

# ...or a crashed one: kill -9 a cycle mid-run, and the next cycle must still run.
SLEEP_SECONDS=30 run_engine "$stub_dir/crashed.log" crashed & crashed_pid=$!
for _ in $(seq 1 100); do grep -q " run=crashed$" "$stub_dir/agent-calls" 2>/dev/null && break; sleep 0.1; done
engine_pid=$( (pgrep -P "$crashed_pid" -f "evolve.sh" || true) | head -1)
kill -9 "$engine_pid" 2>/dev/null || true
wait "$crashed_pid" 2>/dev/null || true
pkill -f "$stub_dir/claude" 2>/dev/null || true
sleep 2
[ -n "$engine_pid" ] && ! grep -q "Day .* complete" "$stub_dir/crashed.log" \
    && ok "the crashed cycle really died mid-run" || bad "crash setup failed (engine pid '$engine_pid')"
after_crash_status=0; SLEEP_SECONDS=0 run_engine "$stub_dir/after-crash.log" after-crash || after_crash_status=$?
grep -q "Day .* complete" "$stub_dir/after-crash.log" \
    && ok "a cycle killed with -9 leaves no stale lock" \
    || bad "lock outlived a crashed cycle (exit $after_crash_status): $(tail -3 "$stub_dir/after-crash.log")"

# If the lock cannot be taken at all, the cycle must fail closed: no agent call.
cp .evolve/scripts/hold_lock.py "$stub_dir/hold_lock.py.real"
echo 'raise SystemExit(1)' > .evolve/scripts/hold_lock.py
rm -f "$stub_dir/agent-calls"
no_lock_status=0; SLEEP_SECONDS=0 run_engine "$stub_dir/no-lock.log" no-lock || no_lock_status=$?
cp "$stub_dir/hold_lock.py.real" .evolve/scripts/hold_lock.py
grep -q "could not take the run lock" "$stub_dir/no-lock.log" && [ "$no_lock_status" -ne 0 ] \
    && ! grep -q " run=no-lock$" "$stub_dir/agent-calls" 2>/dev/null \
    && ok "no lock means no cycle (fails closed, agent not called)" \
    || bad "lock failure did not fail closed (exit $no_lock_status): $(tail -2 "$stub_dir/no-lock.log")"

# Re-running start over a world-readable .env must leave it 0600 (it holds the API key).
chmod 644 .evolve/.env
env -i PATH="$base_path" HOME="$HOME" ANTHROPIC_API_KEY=k node "$CLI" start --every 4 >/dev/null 2>&1 \
    || bad "second start failed"
env_mode=$(stat -c '%a' .evolve/.env 2>/dev/null || stat -f '%Lp' .evolve/.env)
[ "$env_mode" = "600" ] && ok ".env is 0600 after start rewrites it" || bad ".env mode after rewrite: $env_mode"

grep -qxF ".evolve/.env*" .gitignore \
    && ok ".gitignore covers .env and its temporary rewrite file" || bad ".gitignore lacks .evolve/.env*"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
