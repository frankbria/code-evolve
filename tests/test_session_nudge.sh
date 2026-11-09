#!/bin/bash
# Test (#87): the plugin's SessionStart hook says one line when code-evolve needs attention (not set up,
# engine older or newer than the plugin) and nothing otherwise; it is fast and never fails the session.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/code-evolve/hooks/session_nudge.py"
PLUGIN_VERSION="$(node -p "require('$ROOT/plugins/code-evolve/plugin.json').version")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
contains() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', missing '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# run_hook <cwd> [env...]: the hook's stdout for a SessionStart in <cwd>; the exit code goes to $work/status.
run_hook() {
    local cwd="$1"; shift
    local status=0 output
    output="$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$cwd" | env "$@" python3 "$HOOK" 2>/dev/null)" || status=$?
    echo "$status" > "$work/status"
    # The user-facing line (systemMessage); empty when the hook stays silent.
    [ -n "$output" ] && printf '%s' "$output" | node -e "const o=JSON.parse(require('fs').readFileSync(0));if(o.hookSpecificOutput.additionalContext!==o.systemMessage)process.exit(1);process.stdout.write(o.systemMessage)"
    return 0
}
set_engine() { mkdir -p "$1/.evolve"; printf '{"agent":"claude"%s}\n' "${2:+,\"engineVersion\":\"$2\"}" > "$1/.evolve/config.json"; }

project="$work/project"; mkdir -p "$project/src"; git -C "$project" init -q

out="$(run_hook "$project")"
contains "a repository without .evolve is told to run setup" "$out" "/code-evolve:evolve-setup"
check "the nudge is one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
check "it exits 0" "$(cat "$work/status")" "0"
contains "Codex is told its own skill syntax" "$(run_hook "$project" PLUGIN_ROOT=/plugin)" "\$evolve-setup"
contains "a session started in a subdirectory still finds the repository" "$(run_hook "$project/src")" "evolve-setup"

set_engine "$project" "$PLUGIN_VERSION"
check "a current engine is silent" "$(run_hook "$project")" ""

set_engine "$project" "0.0.1"
out="$(run_hook "$project")"
contains "an older engine is told to upgrade" "$out" "upgrade"
contains "the upgrade names both versions" "$out" "0.0.1"

set_engine "$project" ""
contains "an engine without a recorded version is told to upgrade" "$(run_hook "$project")" "upgrade"

set_engine "$project" "999.0.0"
contains "an engine newer than the plugin is told to update the plugin" "$(run_hook "$project")" "update the code-evolve plugin"

plain="$work/not-a-repo"; mkdir -p "$plain"
check "outside a git repository it is silent" "$(run_hook "$plain")" ""

rm "$project/.evolve/config.json"
contains "an install without config.json (older than version tracking) is told to upgrade" "$(run_hook "$project")" "upgrade"
printf 'not json' > "$project/.evolve/config.json"
check "a corrupt config is silent" "$(run_hook "$project")" ""
status=0; out="$(printf 'not json' | python3 "$HOOK" 2>/dev/null)" || status=$?
check "unreadable input is silent and exits 0" "$status:$out" "0:"

# Fast enough to run on every session start (budget: 200 ms).
set_engine "$project" "0.0.1"
elapsed_ms="$(python3 -c "
import subprocess, time
start = time.monotonic()
subprocess.run(['python3', '$HOOK'], input=b'{\"cwd\": \"$project\"}', capture_output=True)
print(int((time.monotonic() - start) * 1000))")"
check "it runs within 200 ms (${elapsed_ms} ms)" "$([ "$elapsed_ms" -lt 200 ] && echo yes || echo no)" "yes"

check "hooks.json registers the nudge for new sessions" \
    "$(node -e "const h=require('$ROOT/plugins/code-evolve/hooks/hooks.json').hooks.SessionStart||[];console.log(h.some(e=>e.matcher==='startup'&&e.hooks.some(c=>c.command.includes('session_nudge.py'))))")" "true"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
