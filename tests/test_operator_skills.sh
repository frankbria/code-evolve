#!/bin/bash
# Test (#80, #81): the operator skills in plugins/code-evolve/skills follow the Agent Skills spec,
# carry the ownership marker, ship valid Codex metadata, and only tell the agent to run CLI
# commands and flags that actually exist (so a CLI change cannot silently break onboarding).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
SKILLS="$ROOT/plugins/code-evolve/skills"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

commands=$(node "$CLI" --help 2>&1 | sed -n '/^Commands:/,$p')
for skill_file in "$SKILLS"/*/SKILL.md; do
    skill_dir=$(basename "$(dirname "$skill_file")")
    frontmatter=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$skill_file")
    name=$(sed -n 's/^name: *//p' <<<"$frontmatter")
    description=$(sed -n 's/^description: *//p' <<<"$frontmatter")
    unknown_keys=$(grep -oE '^[a-zA-Z_-]+:' <<<"$frontmatter" | tr -d ':' \
        | grep -vxE 'name|description|license|compatibility|metadata|allowed-tools|disable-model-invocation' || true)
    [ "$name" = "$skill_dir" ] && [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ -n "$description" ] \
        && [ "${#description}" -le 1024 ] && [ -z "$unknown_keys" ] \
        && ok "$skill_dir: frontmatter follows the Agent Skills spec" \
        || bad "$skill_dir: name='$name' description=${#description} chars unknown='$unknown_keys'"
    grep -qx "  managed-by: code-evolve" <<<"$frontmatter" \
        && ok "$skill_dir: carries the code-evolve ownership marker" || bad "$skill_dir: no managed-by marker"

    openai_yaml="$(dirname "$skill_file")/agents/openai.yaml"
    [ -f "$openai_yaml" ] || bad "$skill_dir: no agents/openai.yaml"
    if [ -f "$openai_yaml" ]; then
        python3 - "$openai_yaml" <<'PY' && ok "$skill_dir: agents/openai.yaml is valid Codex metadata" || bad "$skill_dir: bad agents/openai.yaml"
import sys
# Two-level YAML (no PyYAML dependency): top-level sections with indented "key: value" entries.
sections, current = {}, None
for line in open(sys.argv[1]).read().splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not line.startswith(" "):
        current = line.rstrip(":").strip()
        sections[current] = {}
    elif current is not None and ":" in line:
        key, value = line.split(":", 1)
        sections[current][key.strip()] = value.strip().strip('"')
interface, policy = sections.get("interface", {}), sections.get("policy", {})
valid = (all(interface.get(key) for key in ("display_name", "short_description", "default_prompt"))
         and len(interface["short_description"]) <= 30
         and policy.get("allow_implicit_invocation") in ("true", "false"))
sys.exit(0 if valid else 1)
PY
    fi

    # Every `npx code-evolve <command> --flag` the skill tells the agent to run must exist.
    while IFS= read -r invocation; do
        command_name=$(awk '{print $3}' <<<"$invocation")
        # `<unknown> --help` prints the root help and exits 0, so check the command list itself.
        if ! grep -qE "^  $command_name( |\[)" <<<"$commands"; then
            bad "$skill_dir: '$command_name' is not a code-evolve command"; continue
        fi
        help_text=$(node "$CLI" "$command_name" --help 2>&1)
        for flag in $(grep -oE -- '--[a-z][a-z-]*' <<<"$invocation" | grep -vx -- '--yes' || true); do
            grep -qF -- "$flag" <<<"$help_text" || bad "$skill_dir: 'code-evolve $command_name' has no $flag option"
        done
        if grep -qF -- '--yes' <<<"$invocation" && ! grep -qF -- '--yes' <<<"$help_text"; then
            bad "$skill_dir: 'code-evolve $command_name' has no --yes option"
        fi
    done < <(grep -oE 'npx (-y )?code-evolve(@latest)? [a-z]+[^`]*' "$skill_file" | sed -E 's/npx (-y )?code-evolve(@latest)? /npx code-evolve /')
done
ok "every code-evolve command and flag the skills mention exists (failures listed above)"

# evolve-run commits, tags and pushes: both Claude Code and Codex must only run it when asked.
run_skill="$SKILLS/evolve-run"
grep -qx "disable-model-invocation: true" "$run_skill/SKILL.md" && grep -qx "  allow_implicit_invocation: false" "$run_skill/agents/openai.yaml" \
    && ok "evolve-run is explicit-only in Claude Code and Codex" || bad "evolve-run can be invoked implicitly"

# The engine phases and the messages evolve-run reacts to must still exist in evolve.sh.
engine="$ROOT/templates/scripts/evolve.sh"
for phase in prepare verify "finalize --no-agent"; do
    grep -qF "evolve.sh $phase" "$run_skill/SKILL.md" || bad "evolve-run does not run 'evolve.sh $phase'"
done
grep -qF 'cycle|prepare|verify|finalize [--no-agent]' "$engine" \
    && ok "evolve.sh still offers the phases evolve-run uses" || bad "evolve.sh usage no longer lists the phases"
for message in "Prepared Day" "already running" "a prepared session is still pending"; do
    grep -qF "$message" "$run_skill/SKILL.md" && grep -qF "$message" "$engine" \
        || bad "evolve-run reacts to '$message' but evolve.sh no longer prints it"
done
ok "evolve-run's expected engine messages exist (failures listed above)"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
