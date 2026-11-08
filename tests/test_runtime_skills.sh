#!/bin/bash
# Test (#76): the runtime skills follow the Agent Skills spec (agentskills.io/specification)
# and the cycle prompt carries an index of them, so any agent that can read files uses them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── Frontmatter conforms to the spec ──
for skill_file in "$ROOT"/templates/skills/*/SKILL.md; do
    skill_dir=$(basename "$(dirname "$skill_file")")
    frontmatter=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$skill_file")
    name=$(sed -n 's/^name: *//p' <<<"$frontmatter")
    description=$(sed -n 's/^description: *//p' <<<"$frontmatter")
    unknown_keys=$(grep -oE '^[a-zA-Z_-]+:' <<<"$frontmatter" | tr -d ':' \
        | grep -vxE 'name|description|license|compatibility|metadata|allowed-tools' || true)
    if [ "$name" = "$skill_dir" ] && [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#name}" -le 64 ] \
        && [ -n "$description" ] && [ "${#description}" -le 1024 ] && [ -z "$unknown_keys" ]; then
        ok "$skill_dir: frontmatter follows the Agent Skills spec"
    else
        bad "$skill_dir: name='$name' description=${#description} chars unknown keys='$unknown_keys'"
    fi
done

# ── The cycle prompt indexes every skill ──
stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir"' EXIT
cat > "$stub_dir/claude" <<STUB
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
if [ -e "$stub_dir/prompt.txt" ]; then cat >/dev/null; else cat > "$stub_dir/prompt.txt"; fi
STUB
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/gh"
export PATH="$stub_dir:$PATH"
cd "$work_dir"
git init -q
git config user.email test@example.com
git config user.name test
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed"
ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 \
    bash .evolve/scripts/evolve.sh > "$stub_dir/engine.log" 2>&1 || true

grep -q "=== SKILLS ===" "$stub_dir/prompt.txt" 2>/dev/null \
    && ok "prompt has a skills section" || bad "no skills section in the prompt"
grep -qF ".evolve/skills/<name>/SKILL.md" "$stub_dir/prompt.txt" 2>/dev/null \
    && ok "prompt says where each skill file lives" || bad "prompt does not give the skill path"
for skill_file in "$ROOT"/templates/skills/*/SKILL.md; do
    skill_dir=$(basename "$(dirname "$skill_file")")
    [ -f "$work_dir/.evolve/skills/$skill_dir/SKILL.md" ] && grep -qF -- "- $skill_dir: " "$stub_dir/prompt.txt" \
        && ok "prompt indexes $skill_dir (installed at .evolve/skills/$skill_dir/SKILL.md)" || bad "prompt does not index $skill_dir"
done

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
