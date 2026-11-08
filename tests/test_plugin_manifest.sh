#!/bin/bash
# Test (#83): the repo is its own Claude Code marketplace, serving the self-contained plugin in
# plugins/code-evolve, whose version follows package.json (`npm version` syncs it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_MANIFEST="plugins/code-evolve/.claude-plugin/plugin.json"
AGENT_MANIFEST="plugins/code-evolve/plugin.json"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
json() { node -e "console.log(JSON.stringify(require('$1')$2))"; }

check "Claude plugin version matches package.json" "$(json "$ROOT/$PLUGIN_MANIFEST" .version)" "$(json "$ROOT/package.json" .version)"
check "Agent Plugins version matches package.json" "$(json "$ROOT/$AGENT_MANIFEST" .version)" "$(json "$ROOT/package.json" .version)"
check "marketplace serves the plugin directory" \
    "$(json "$ROOT/.claude-plugin/marketplace.json" '.plugins.map(p => [p.name, p.source])')" '[["code-evolve","./plugins/code-evolve"]]'
check "the plugin ships the three operator skills" \
    "$(cd "$ROOT/plugins/code-evolve/skills" && ls -d */SKILL.md | tr '\n' ' ')" "evolve-run/SKILL.md evolve-setup/SKILL.md evolve-status/SKILL.md "

# `npm version` runs the package's version script; it must carry the new version into plugin.json.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$(dirname "$PLUGIN_MANIFEST")" "$work/scripts"
cp "$ROOT/package.json" "$work/"; cp "$ROOT/scripts/sync-plugin-version.js" "$work/scripts/"
cp "$ROOT/$PLUGIN_MANIFEST" "$work/$PLUGIN_MANIFEST"; cp "$ROOT/$AGENT_MANIFEST" "$work/$AGENT_MANIFEST"
git -C "$work" init -q
node -e "const f='$work/package.json';const p=require(f);p.version='9.9.9';require('fs').writeFileSync(f,JSON.stringify(p))"
(cd "$work" && npm run version --silent >/dev/null 2>&1)
check "the version script syncs the Claude manifest" "$(json "$work/$PLUGIN_MANIFEST" .version)" '"9.9.9"'
check "the version script syncs the Agent Plugins manifest" "$(json "$work/$AGENT_MANIFEST" .version)" '"9.9.9"'
check "the version script stages both manifests for the version commit" \
    "$(git -C "$work" diff --cached --name-only | sort | tr '\n' ' ')" "$PLUGIN_MANIFEST $AGENT_MANIFEST "

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
