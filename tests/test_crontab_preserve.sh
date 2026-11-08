#!/bin/bash
# Test (#72): start, stop and eject must leave the user's other crontab lines byte-identical,
# including `$VAR`, backticks and `%`, and must not touch a sibling project's entry.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT

# crontab stub backed by a file; `-l` fails like the real one when there is no table.
cat > "$stub_dir/crontab" <<STUB
#!/bin/bash
table="$stub_dir/crontab.table"
if [ "\${1:-}" = "-l" ]; then [ -f "\$table" ] && cat "\$table" && exit 0; exit 1; fi
cat > "\$table"
STUB
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"
chmod +x "$stub_dir/crontab" "$stub_dir/claude"
export PATH="$stub_dir:$PATH"
export ANTHROPIC_API_KEY=sk-test

user_lines='SHELL=/bin/bash
MAILTO="me@example.com"
0 1 * * * echo "$HOME" `date +%s` > /tmp/out 2>&1 # 100% mine
30 2 * * * cd "$HOME/other" && ./backup.sh $(hostname)'

cd "$work_dir"
mkdir app app2
for dir in app app2; do
    (cd "$dir" && git init -q && node "$CLI" init --agent claude </dev/null >/dev/null 2>&1)
done
printf '%s\n' "$user_lines" > "$stub_dir/crontab.table"

(cd app2 && node "$CLI" start --every 4 >/dev/null 2>&1)
(cd app && node "$CLI" start --every 4 >/dev/null 2>&1)
table_after_start=$(cat "$stub_dir/crontab.table")
[ "$(grep -c 'code-evolve:' <<<"$table_after_start")" = "2" ] \
    && ok "start added one entry per project" || bad "after start: $table_after_start"
head -4 <<<"$table_after_start" | diff - <(printf '%s\n' "$user_lines") >/dev/null \
    && ok "start kept the user's lines byte-identical" \
    || bad "start altered user lines: $(head -4 <<<"$table_after_start")"

(cd app && node "$CLI" stop >/dev/null 2>&1)
table_after_stop=$(cat "$stub_dir/crontab.table")
grep -q "code-evolve:$work_dir/app2\$" <<<"$table_after_stop" \
    && ok "stop kept the sibling project (app2) whose path shares the prefix" \
    || bad "stop removed app2's entry: $table_after_stop"
! grep -q "code-evolve:$work_dir/app\$" <<<"$table_after_stop" \
    && ok "stop removed app's entry" || bad "app entry still present after stop"

(cd app2 && node "$CLI" eject --yes >/dev/null 2>&1)
diff <(cat "$stub_dir/crontab.table") <(printf '%s\n' "$user_lines") >/dev/null \
    && ok "after start, stop and eject the table equals the user's original lines" \
    || bad "final table differs: $(diff <(cat "$stub_dir/crontab.table") <(printf '%s\n' "$user_lines"))"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
