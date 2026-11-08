#!/bin/bash
# Test (#86): the plugin's PreToolUse hook blocks (exit 2, reason on stderr) edits to protected files
# from Claude Code (Edit/Write/Bash) and Codex (apply_patch/Bash), and lets everything else through.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/code-evolve/hooks/guard_protected_paths.py"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

project="$(mktemp -d)"; stub_dir="$(mktemp -d)"
trap 'rm -rf "$project" "$stub_dir"' EXIT
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"; chmod +x "$stub_dir/claude"
git -C "$project" init -q
(cd "$project" && PATH="$stub_dir:$PATH" node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1)

# hook_exit <tool> <tool_input JSON> [cwd]: the hook's exit code for that tool call.
hook_exit() {
    local payload status=0
    payload="$(node -e 'console.log(JSON.stringify({hook_event_name:"PreToolUse",cwd:process.argv[3],tool_name:process.argv[1],tool_input:JSON.parse(process.argv[2])}))' "$1" "$2" "${3:-$project}")"
    printf '%s' "$payload" | python3 "$HOOK" 2>"$stub_dir/stderr" || status=$?
    echo "$status"
}
edit() { node -e 'console.log(JSON.stringify({file_path:process.argv[1]}))' "$1"; }
bash_command() { node -e 'console.log(JSON.stringify({command:process.argv[1]}))' "$1"; }

# Claude Code file tools (absolute paths)
check "Edit of .evolve/IDENTITY.md is blocked" "$(hook_exit Edit "$(edit "$project/.evolve/IDENTITY.md")")" "2"
grep -q "\.evolve/IDENTITY.md is protected" "$stub_dir/stderr" && check "the reason names the file" yes yes || check "the reason names the file" no yes
check "Write of an engine script is blocked" "$(hook_exit Write "$(edit "$project/.evolve/scripts/evolve.sh")")" "2"
check "Write of a new file under a protected glob is blocked" "$(hook_exit Write "$(edit "$project/.evolve/skills/new/SKILL.md")")" "2"
check "Edit of the evolve workflow is blocked" "$(hook_exit Edit "$(edit "$project/.github/workflows/evolve.yml")")" "2"
check "Edit of the spec is allowed" "$(hook_exit Edit "$(edit "$project/.evolve/spec.md")")" "0"
check "Edit of project source is allowed" "$(hook_exit Write "$(edit "$project/src/app.ts")")" "0"
check "Edit of the project's own CI workflow is allowed" "$(hook_exit Edit "$(edit "$project/.github/workflows/ci.yml")")" "0"
check "Edit outside the project is allowed" "$(hook_exit Edit "$(edit /tmp/elsewhere.txt)")" "0"
check "a protected file reached from a subdirectory is still blocked" \
    "$(mkdir -p "$project/src" && hook_exit Edit "$(edit "../.evolve/IDENTITY.md")" "$project/src")" "2"

# Bash (both clients)
check "a redirect into a protected file is blocked" "$(hook_exit Bash "$(bash_command 'echo x > .evolve/IDENTITY.md')")" "2"
check "sed -i on a protected file is blocked" "$(hook_exit Bash "$(bash_command "sed -i 's/a/b/' .evolve/scripts/evolve.sh")")" "2"
check "rm -rf of the engine directory is blocked" "$(hook_exit Bash "$(bash_command 'rm -rf .evolve/scripts')")" "2"
check "git checkout -- of a protected file is blocked" "$(hook_exit Bash "$(bash_command 'git checkout -- .evolve/IDENTITY.md')")" "2"
check "reading a protected file is allowed" "$(hook_exit Bash "$(bash_command 'cat .evolve/IDENTITY.md 2>/dev/null | head')")" "0"
check "the engine's own phases are allowed" "$(hook_exit Bash "$(bash_command 'bash .evolve/scripts/evolve.sh verify')")" "0"
check "ordinary writes are allowed" "$(hook_exit Bash "$(bash_command 'echo x > notes.txt && rm -f build.log')")" "0"

# Codex apply_patch: the patch text is in tool_input.command
patch_for() { printf '*** Begin Patch\n*** %s File: %s\n@@\n-old\n+new\n*** End Patch\n' "$1" "$2"; }
check "apply_patch updating a protected file is blocked" "$(hook_exit apply_patch "$(bash_command "$(patch_for Update .evolve/IDENTITY.md)")")" "2"
check "apply_patch deleting an engine script is blocked" "$(hook_exit apply_patch "$(bash_command "$(patch_for Delete .evolve/scripts/hold_lock.py)")")" "2"
check "apply_patch on project source is allowed" "$(hook_exit apply_patch "$(bash_command "$(patch_for Update src/app.ts)")")" "0"

# Outside a code-evolve project, and on input it cannot read, the hook stays out of the way.
plain="$(mktemp -d)"
check "a project without .evolve is never blocked" "$(hook_exit Edit "$(edit "$plain/.evolve/IDENTITY.md")" "$plain")" "0"
rm -rf "$plain"
status=0; printf 'not json' | python3 "$HOOK" 2>/dev/null || status=$?
check "unreadable input is allowed" "$status" "0"

# The plugin registers the hook for Claude Code (hooks/hooks.json) and Codex (plugin.json).
check "hooks.json runs the guard on PreToolUse" \
    "$(node -e "const h=require('$ROOT/plugins/code-evolve/hooks/hooks.json').hooks.PreToolUse[0];console.log(h.hooks[0].command.includes('guard_protected_paths.py') && /apply_patch/.test(h.matcher) && /Edit/.test(h.matcher) && /Bash/.test(h.matcher))")" "true"
check "the Agent Plugins manifest declares the hooks for Codex" \
    "$(node -e "console.log(require('$ROOT/plugins/code-evolve/plugin.json').extensions['com.openai'].hooks)")" "./hooks/hooks.json"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
