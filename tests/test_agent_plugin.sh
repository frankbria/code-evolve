#!/bin/bash
# Test (#84): plugins/code-evolve/plugin.json is a valid Agent Plugins 1.0 manifest for Codex and other
# clients, within OpenAI's listing limits, and scripts/pack-codex-plugin zips exactly the plugin directory.
# Test (#100): `pack-codex-plugin --directory` builds the copy for OpenAI's public directory, without hooks.
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
check "longDescription is at most 4000 characters" "$(manifest 'ui.longDescription.length <= 4000')" "true"
check "developerName is at most 80 characters" "$(manifest 'ui.developerName.length >= 1 && ui.developerName.length <= 80')" "true"
check "every listing URL is HTTPS, at most 1024 characters, without credentials" \
    "$(manifest '["websiteURL","supportURL","privacyPolicyURL","termsOfServiceURL"].filter(k => k in ui && !(ui[k].length <= 1024 && new URL(ui[k]).protocol === "https:" && !new URL(ui[k]).username))')" "[]"
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


# The public directory takes no plugin with lifecycle hooks or app references, so its upload copy is the
# committed plugin without them and is otherwise byte-identical.
objects_before="$(git -C "$ROOT" count-objects -v)"
"$ROOT/scripts/pack-codex-plugin" --directory "$work/directory.zip" >/dev/null 2>"$work/notes"
directory_listed="$(unzip -Z1 "$work/directory.zip" | grep -v '/$' | sort)"
check "the directory ZIP holds the committed plugin files except hooks/" "$directory_listed" "$(printf '%s\n' "$committed" | grep -v '^code-evolve/hooks/')"
check "the directory ZIP has no hook or app file" "$(printf '%s\n' "$directory_listed" | grep -cE '(^|/)(hooks/|\.app\.json$)' || true)" "0"
mkdir "$work/full" "$work/directory"
unzip -q "$work/plugin.zip" -d "$work/full"
unzip -q "$work/directory.zip" -d "$work/directory"
check "only plugin.json and hooks/ differ from the full ZIP" \
    "$(diff -rq "$work/full" "$work/directory" | sed "s#$work/##g" | sort)" \
    "$(printf '%s\n' 'Files full/code-evolve/plugin.json and directory/code-evolve/plugin.json differ' 'Only in full/code-evolve: hooks')"
check "the directory manifest drops only the hooks declaration" \
    "$(node -e "const [full, copy] = ['full','directory'].map(d => require('$work/' + d + '/code-evolve/plugin.json')); const had = 'hooks' in full.extensions['com.openai']; delete full.extensions['com.openai'].hooks; console.log(had && JSON.stringify(full) === JSON.stringify(copy))")" "true"
check "the directory manifest declares no hooks or apps" \
    "$(node -e "const m = require('$work/directory/code-evolve/plugin.json'); console.log(JSON.stringify(['hooks','apps'].filter(k => k in m || k in m.extensions['com.openai'])))")" "[]"
missing_pages="$(manifest '["websiteURL","supportURL","privacyPolicyURL","termsOfServiceURL"].filter(k => !ui[k]).join(", ")' | tr -d '"')"
check "it names exactly the listing pages that are not in the manifest yet" \
    "$(sed -n 's/^Note: the listing has no \(.*\) yet;.*/\1/p' "$work/notes")" "$missing_pages"
check "building it adds no objects to the repository" "$(git -C "$ROOT" count-objects -v)" "$objects_before"
default_output="dist/code-evolve-plugin-$(manifest 'm.version' | tr -d '"')-directory.zip"
check "the default output name marks the directory copy" "$("$ROOT/scripts/pack-codex-plugin" --directory 2>/dev/null)" "$default_output"
# The npm package ships dist/, so the copy must not stay there.
rm -f "$ROOT/$default_output"
check "an unknown option is refused" "$("$ROOT/scripts/pack-codex-plugin" --public "$work/x.zip" >/dev/null 2>&1; echo $?)" "2"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
