#!/bin/bash
# Test (#82): bare `code-evolve` installs with the agent found on PATH and hands the terminal to it
# with the evolve-setup skill as the first prompt; without a terminal or agent it prints next steps.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
contains() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (missing '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Only node, python3 and git besides the stubs, so the host's real agent CLIs are never found.
base_bin="$work/base"; mkdir "$base_bin"
for tool in node python3 git; do ln -s "$(command -v "$tool")" "$base_bin/$tool"; done

# make_stubs <dir> <agent>...: each stub records its argv, one argument per line, and answers --version.
make_stubs() {
    local dir="$1"; shift; mkdir -p "$dir"
    for agent in "$@"; do
        printf '#!/bin/bash\n[ "${1:-}" = --version ] && { echo "%s 0.0.0-stub"; exit 0; }\nprintf "%%s\\n" "$@" > "%s/%s.argv"\n' \
            "$agent" "$work" "$agent" > "$dir/$agent"
        chmod +x "$dir/$agent"
    done
}

new_project() { local project; project="$(mktemp -d "$work/project.XXXX")"; git -C "$project" init -q; echo "$project"; }

# run_in_tty <project> <path> <input>: run bare code-evolve on a real terminal, typing <input>.
run_in_tty() {
    (cd "$1" && printf '%s' "$3" | timeout 30 script -qec "PATH='$2' node '$CLI'" /dev/null 2>&1) || true
}

# Each agent alone: no prompt, init with that agent, then the agent launched with the setup skill.
for agent in claude codex opencode; do
    make_stubs "$work/only-$agent" "$agent"
    project="$(new_project)"
    out="$(run_in_tty "$project" "$work/only-$agent:$base_bin" "")"
    check "$agent alone: installed for $agent" "$(node -e "console.log(require('$project/.evolve/config.json').agent)")" "$agent"
    check "$agent alone: no agent prompt" "$(printf '%s' "$out" | grep -c 'Which one' || true)" "0"
done
check "claude is launched with /evolve-setup" "$(cat "$work/claude.argv")" "/evolve-setup"
check "codex is launched with \$evolve-setup" "$(cat "$work/codex.argv")" '$evolve-setup'
check "opencode is launched with a prompt naming the skill" "$(head -1 "$work/opencode.argv")" "--prompt"
contains "opencode's prompt names evolve-setup" "$(cat "$work/opencode.argv")" "evolve-setup skill"

# Several agents: exactly one prompt, and the answer picks the agent.
rm -f "$work"/*.argv
make_stubs "$work/several" claude codex opencode
project="$(new_project)"
out="$(run_in_tty "$project" "$work/several:$base_bin" $'2\n')"
check "several agents: asked exactly once" "$(printf '%s' "$out" | grep -c 'Which one')" "1"
check "several agents: the chosen agent is installed" "$(node -e "console.log(require('$project/.evolve/config.json').agent)")" "codex"
check "several agents: only the chosen agent is launched" "$(ls "$work"/*.argv | xargs -n1 basename | tr '\n' ' ')" "codex.argv "

# No terminal: print every agent's next step, install nothing, exit 0.
project="$(new_project)"
status=0; out="$(cd "$project" && PATH="$work/several:$base_bin" node "$CLI" </dev/null 2>&1)" || status=$?
check "no terminal: exits 0" "$status" "0"
check "no terminal: nothing installed" "$([ -d "$project/.evolve" ] && echo yes || echo no)" "no"
contains "no terminal: claude next step" "$out" "init --yes --agent claude && claude /evolve-setup"
contains "no terminal: codex next step" "$out" "init --yes --agent codex && codex '\$evolve-setup'"
contains "no terminal: opencode next step" "$out" "init --yes --agent opencode && opencode --prompt"

# No agent on PATH, even on a terminal: say so and print the next steps.
project="$(new_project)"
out="$(run_in_tty "$project" "$base_bin" "")"
contains "no agent: says none was found" "$out" "No supported agent CLI"
contains "no agent: prints next steps" "$out" "init --yes --agent claude"
check "no agent: nothing installed" "$([ -d "$project/.evolve" ] && echo yes || echo no)" "no"

# A mistyped subcommand still errors instead of bootstrapping.
status=0; out="$(cd "$project" && PATH="$base_bin" node "$CLI" stauts 2>&1)" || status=$?
check "typo: exits non-zero" "$([ "$status" -ne 0 ] && echo yes || echo no)" "yes"
contains "typo: names the unknown command" "$out" "unknown command 'stauts'"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
