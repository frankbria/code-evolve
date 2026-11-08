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
    if [ -f "$openai_yaml" ]; then
        python3 - "$openai_yaml" <<'PY' && ok "$skill_dir: agents/openai.yaml is valid Codex metadata" || bad "$skill_dir: bad agents/openai.yaml"
import sys
text = open(sys.argv[1]).read().splitlines()
keys = {line.split(":")[0].strip() for line in text if ":" in line}
required = {"interface", "display_name", "short_description", "default_prompt", "policy", "allow_implicit_invocation"}
short = next((l.split(":", 1)[1].strip().strip('"') for l in text if l.strip().startswith("short_description:")), "")
sys.exit(0 if required <= keys and len(short) <= 30 else 1)
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

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
