#!/bin/bash
# Test (#83, #95): the repo is its own Claude Code marketplace, serving the self-contained plugin in
# plugins/code-evolve. Its manifests and the setup skill's pinned install command follow package.json:
# `npm version` syncs them and `sync-plugin-version.js --check` fails on drift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_MANIFEST="plugins/code-evolve/.claude-plugin/plugin.json"
AGENT_MANIFEST="plugins/code-evolve/plugin.json"
SETUP_SKILL="plugins/code-evolve/skills/evolve-setup/SKILL.md"
VERSION="$(node -p "require('$ROOT/package.json').version")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
json() { node -e "console.log(JSON.stringify(require('$1')$2))"; }

check "Claude plugin version matches package.json" "$(json "$ROOT/$PLUGIN_MANIFEST" .version)" "$(json "$ROOT/package.json" .version)"
check "Agent Plugins version matches package.json" "$(json "$ROOT/$AGENT_MANIFEST" .version)" "$(json "$ROOT/package.json" .version)"
check "the setup skill installs the plugin's own version" \
    "$(grep -c "^npx -y code-evolve@$VERSION init " "$ROOT/$SETUP_SKILL")" "1"
status=0; (cd "$ROOT" && node scripts/sync-plugin-version.js --check >/dev/null 2>&1) || status=$?
check "the committed versions are in lockstep (--check)" "$status" "0"
check "marketplace serves the plugin directory" \
    "$(json "$ROOT/.claude-plugin/marketplace.json" '.plugins.map(p => [p.name, p.source])')" '[["code-evolve","./plugins/code-evolve"]]'
check "the plugin ships the three operator skills" \
    "$(cd "$ROOT/plugins/code-evolve/skills" && ls -d */SKILL.md | tr '\n' ' ')" "evolve-run/SKILL.md evolve-setup/SKILL.md evolve-status/SKILL.md "

# `npm version` runs the package's version script; it must carry the new version into every pinned file.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$(dirname "$PLUGIN_MANIFEST")" "$work/$(dirname "$SETUP_SKILL")" "$work/scripts"
cp "$ROOT/package.json" "$work/"; cp "$ROOT/scripts/sync-plugin-version.js" "$work/scripts/"
for pinned in "$PLUGIN_MANIFEST" "$AGENT_MANIFEST" "$SETUP_SKILL"; do cp "$ROOT/$pinned" "$work/$pinned"; done
git -C "$work" init -q
git -C "$work" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$work" add -A
git -C "$work" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -q -m files
sync_check() { (cd "$work" && node scripts/sync-plugin-version.js --check "$@" 2>&1); }

(cd "$work" && npm version 9.9.9 --no-git-tag-version >/dev/null 2>&1)
check "npm version syncs the Claude manifest" "$(json "$work/$PLUGIN_MANIFEST" .version)" '"9.9.9"'
check "npm version syncs the Agent Plugins manifest" "$(json "$work/$AGENT_MANIFEST" .version)" '"9.9.9"'
check "npm version pins the setup skill's install command" \
    "$(grep -c '^npx -y code-evolve@9.9.9 init --yes' "$work/$SETUP_SKILL")" "1"
check "npm version stages every synced file for the version commit" \
    "$(git -C "$work" diff --cached --name-only | sort | tr '\n' ' ')" "$PLUGIN_MANIFEST $AGENT_MANIFEST $SETUP_SKILL "
status=0; sync_check >/dev/null || status=$?
check "--check passes after a sync" "$status" "0"
status=0; sync_check --tag v9.9.9 >/dev/null || status=$?
check "--check accepts the release tag of this version" "$status" "0"
status=0; out="$(sync_check --tag v9.9.8)" || status=$?
check "--check rejects a release tag for another version" "$status" "1"
check "the tag mismatch names both" "$(grep -c 'v9.9.8.*v9.9.9' <<<"$out")" "1"

# A hand-edited version is what CI must catch: each drifted file is named, and nothing is rewritten.
node -e "const f='$work/$AGENT_MANIFEST';const m=require(f);m.version='9.9.8';require('fs').writeFileSync(f,JSON.stringify(m,null,2)+'\n')"
sed -i 's/code-evolve@9\.9\.9 init/code-evolve@latest init/' "$work/$SETUP_SKILL"
status=0; out="$(sync_check)" || status=$?
check "--check fails on a hand-edited mismatch" "$status" "1"
check "--check names the drifted manifest" "$(grep -c "$AGENT_MANIFEST" <<<"$out")" "1"
check "--check names the drifted skill pin" "$(grep -c "$SETUP_SKILL" <<<"$out")" "1"
check "--check leaves the in-sync manifest out" "$(grep -c "$PLUGIN_MANIFEST" <<<"$out")" "0"
check "--check writes nothing" "$(json "$work/$AGENT_MANIFEST" .version)" '"9.9.8"'
(cd "$work" && npm run version --silent >/dev/null 2>&1)
status=0; sync_check >/dev/null || status=$?
check "the version script repairs the drift" "$status" "0"

# A skill that lost its install command must stop the release, not ship unpinned.
cp "$work/$SETUP_SKILL" "$work/skill.backup"
grep -v '^npx -y code-evolve@' "$work/skill.backup" > "$work/$SETUP_SKILL"
status=0; (cd "$work" && npm run version --silent >/dev/null 2>&1) || status=$?
check "a setup skill without the pinned command fails the version script" "$([ "$status" -ne 0 ] && echo failed || echo passed)" "failed"
cp "$work/skill.backup" "$work/$SETUP_SKILL"

chmod a-w "$work/$AGENT_MANIFEST"
status=0; (cd "$work" && npm run version --silent >/dev/null 2>&1) || status=$?
chmod u+w "$work/$AGENT_MANIFEST"
check "a manifest that cannot be written fails the version script (no stale release)" "$([ "$status" -ne 0 ] && echo failed || echo passed)" "failed"

if command -v claude >/dev/null 2>&1; then
    status=0; claude plugin validate "$ROOT" >/dev/null 2>&1 || status=$?
    check "claude plugin validate passes on the marketplace" "$status" "0"
    status=0; claude plugin validate "$ROOT/plugins/code-evolve" >/dev/null 2>&1 || status=$?
    check "claude plugin validate passes on the plugin" "$status" "0"
else
    echo "  skip: claude CLI not installed (CI validates in its own step)"
fi

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
