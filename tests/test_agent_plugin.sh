#!/bin/bash
# Test (#84): plugins/code-evolve/plugin.json is a valid Agent Plugins 1.0 manifest for Codex and other
# clients, within OpenAI's listing limits, and scripts/pack-codex-plugin zips exactly the plugin directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$ROOT/plugins/code-evolve"
MANIFEST="$PLUGIN_DIR/plugin.json"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
manifest() { node -e "const m=require('$MANIFEST');const ui=m.extensions['com.openai'].interface;console.log(JSON.stringify($1))"; }

check "\$schema is the Agent Plugins 1.0 schema" "$(manifest 'm["$schema"]')" '"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"'
check "name matches the plugin directory" "$(manifest 'm.name')" "\"$(basename "$PLUGIN_DIR")\""
check "version is strict semver" "$(manifest '/^\d+\.\d+\.\d+$/.test(m.version)')" "true"
check "no component keys at the top level" "$(manifest '["skills","mcpServers","apps","interface"].filter(k => k in m)')" "[]"
check "author has only name, email or url" "$(manifest 'Object.keys(m.author).filter(k => !["name","email","url"].includes(k))')" "[]"
check "homepage, repository and license are strings" "$(manifest '[m.homepage,m.repository,m.license].every(v => typeof v === "string")')" "true"
check "displayName is at most 30 characters" "$(manifest 'ui.displayName.length <= 30')" "true"
check "shortDescription is at most 30 characters" "$(manifest 'ui.shortDescription.length <= 30')" "true"
check "defaultPrompt has 1 to 3 single-line prompts of at most 128 characters" \
    "$(manifest 'ui.defaultPrompt.length >= 1 && ui.defaultPrompt.length <= 3 && ui.defaultPrompt.every(p => p.length <= 128 && !/\n/.test(p))')" "true"
check "category is a supported listing category" \
    "$(manifest '["Business & Operations","Communication","Creativity","Data & Analytics","Developer Tools","Education & Research","Entertainment","Finance","Healthcare","Other","Productivity","Scientific Research","Security","Travel"].includes(ui.category)')" "true"
check "capabilities is an array of strings" "$(manifest 'Array.isArray(ui.capabilities) && ui.capabilities.every(c => typeof c === "string" && c.trim())')" "true"
check "the onboarding skill is evolve-setup" "$(manifest 'm.extensions["com.openai"].onboardingSkill')" '"./skills/evolve-setup/SKILL.md"'
check "the onboarding skill file exists" "$([ -f "$PLUGIN_DIR/skills/evolve-setup/SKILL.md" ] && echo yes || echo no)" "yes"
check "a local executor is required (cycles run shell scripts and git)" "$(manifest 'm.extensions["com.openai"].requires_local_executor')" "true"

# Icons: square PNGs of at least 48 px, read from the PNG header (width and height at bytes 16-23).
for field in logo composerIcon; do
    icon="$PLUGIN_DIR/$(manifest "ui.$field" | tr -d '"')"
    size="$(node -e "const b=require('fs').readFileSync('$icon');console.log(b.toString('ascii',1,4)==='PNG' ? b.readUInt32BE(16)+'x'+b.readUInt32BE(20) : 'not a PNG')")"
    width="${size%x*}"
    check "$field is a square PNG of at least 48 px ($size)" "$([ "$size" = "${width}x${width}" ] && [ "$width" -ge 48 ] && echo yes || echo no)" "yes"
done

# The archive holds exactly the committed plugin directory under one top folder, and nothing else.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
"$ROOT/scripts/pack-codex-plugin" "$work/plugin.zip" >/dev/null 2>&1
listed="$(unzip -Z1 "$work/plugin.zip" | grep -v '/$' | sort)"
committed="$(git -C "$ROOT" ls-tree -r --name-only HEAD -- plugins/code-evolve | sed 's#^plugins/##' | sort)"
check "the ZIP holds exactly the committed plugin files" "$listed" "$committed"
check "every ZIP entry sits under code-evolve/" "$(unzip -Z1 "$work/plugin.zip" | grep -vc '^code-evolve/' || true)" "0"
for required in code-evolve/plugin.json code-evolve/skills/evolve-setup/SKILL.md code-evolve/assets/logo.png; do
    check "the ZIP contains $required" "$(printf '%s\n' "$listed" | grep -cx "$required")" "1"
done
check "the ZIP has no dependency directories" "$(printf '%s\n' "$listed" | grep -cE '(^|/)node_modules/' || true)" "0"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
