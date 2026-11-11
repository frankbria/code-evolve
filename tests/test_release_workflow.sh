#!/bin/bash
# Test (#95): the tag-triggered release. scripts/publish-release runs here against stub `npm` and `gh`
# commands (nothing is published), and release.yml is checked for what the release depends on.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/release.yml"
VERSION="$(node -p "require('$ROOT/package.json').version")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
# The stubs record every call; files in $work/state decide what npm and GitHub "already have".
cat > "$work/bin/npm" <<'STUB'
#!/bin/bash
echo "npm $*" >> "$STUB_LOG"
case "$1" in
    view) [ -f "$STUB_STATE/published" ] && cat "$STUB_STATE/published"; exit 0 ;;
    publish) [ ! -f "$STUB_STATE/publish-fails" ] ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$STUB_LOG"
if [ "$1 $2" = "release view" ]; then [ -f "$STUB_STATE/released" ]; fi
STUB
chmod +x "$work/bin/npm" "$work/bin/gh"

# Runs the script with the stubs first on PATH; prints its exit status. The call log is $work/log.
publish_release() {
    : > "$work/log"
    local status=0
    PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_STATE="$work/state" RUNNER_TEMP="$work" \
        "$ROOT/scripts/publish-release" "$@" > "$work/out" 2>&1 || status=$?
    echo "$status"
}
calls() { grep -c -- "$1" "$work/log" || true; }
archive="$work/code-evolve-plugin-$VERSION.zip"
rm -f "$ROOT"/dist/*.zip

mkdir "$work/state"
check "a first release succeeds" "$(publish_release "v$VERSION")" "0"
check "it publishes to npm with provenance" "$(calls '^npm publish --provenance --access public$')" "1"
check "it creates the GitHub release for the tag with the plugin ZIP" \
    "$(calls "^gh release create v$VERSION $archive --title v$VERSION --generate-notes --verify-tag\$")" "1"
check "the plugin ZIP was built" "$([ -s "$archive" ] && echo yes || echo no)" "yes"
# The release tests run before the publish, and the npm package ships dist/.
check "the plugin ZIP is kept out of dist/, which the npm package ships" "$(ls "$ROOT"/dist/*.zip 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "$VERSION" > "$work/state/published"; touch "$work/state/released"
check "a re-run after a finished release succeeds" "$(publish_release "v$VERSION")" "0"
check "a version already on npm is not published again" "$(calls '^npm publish')" "0"
check "an existing release gets the ZIP re-attached" "$(calls "^gh release upload v$VERSION $archive --clobber\$")" "1"
check "an existing release is not created again" "$(calls '^gh release create')" "0"

echo "0.0.1" > "$work/state/published"; rm "$work/state/released"
check "another version on npm does not count as published" "$(publish_release "v$VERSION"; calls '^npm publish')" "$(printf '0\n1')"

rm -rf "$work/state"; mkdir "$work/state"
check "a tag for another version is refused" "$(publish_release "v99.0.0")" "1"
check "the refusal names the tag" "$(grep -c 'release tag v99.0.0 does not match' "$work/out")" "1"
check "nothing is published or released for a wrong tag" "$(calls '^npm publish\|^gh release')" "0"

touch "$work/state/publish-fails"
check "a failed publish fails the release" "$([ "$(publish_release "v$VERSION")" -ne 0 ] && echo failed || echo passed)" "failed"
check "no GitHub release is created after a failed publish" "$(calls '^gh release')" "0"

# release.yml: only version tags trigger it, it can mint the OIDC token npm needs, and it tests before publishing.
line_of() { grep -n -- "$1" "$WORKFLOW" | head -1 | cut -d: -f1; }
check "the workflow runs on version tags only" "$(grep -A2 '^on:' "$WORKFLOW" | tr -d ' \n')" "on:push:tags:['v[0-9]+.[0-9]+.[0-9]+']"
# Install scripts and tests must not be able to publish: only the publish job holds those rights.
publish_job="$(sed -n '/^  publish:/,$p' "$WORKFLOW")"
check "the workflow itself is read-only" "$(grep -A1 '^permissions:' "$WORKFLOW" | tr -d ' \n')" "permissions:contents:read"
check "only the publish job may request an OIDC token" \
    "$(grep -c 'id-token: write' "$WORKFLOW") $(grep -c '^      id-token: write' <<<"$publish_job")" "1 1"
check "only the publish job may create the GitHub release" \
    "$(grep -c 'contents: write' "$WORKFLOW") $(grep -c '^      contents: write' <<<"$publish_job")" "1 1"
check "the publish job waits for the tests" "$(grep -c '^    needs: test$' <<<"$publish_job")" "1"
check "the publish job runs no dependency install scripts" "$(grep -c 'run: npm ci' <<<"$publish_job") $(grep -c 'run: npm ci --ignore-scripts$' <<<"$publish_job")" "1 1"
check "no job leaves the repository token in the checkout" "$(grep -c 'uses: actions/checkout' "$WORKFLOW") $(grep -c 'persist-credentials: false' "$WORKFLOW")" "2 2"
check "it publishes through scripts/publish-release" "$(grep -c 'scripts/publish-release "\$GITHUB_REF_NAME"' "$WORKFLOW")" "1"
check "it checks the tag before installing anything" \
    "$([ "$(line_of 'sync-plugin-version.js --check --tag "\$GITHUB_REF_NAME"')" -lt "$(line_of 'npm ci')" ] && echo yes || echo no)" "yes"
check "the setup skill falls back when its pinned version is not on npm" \
    "$(grep -c 'code-evolve@latest' "$ROOT/plugins/code-evolve/skills/evolve-setup/SKILL.md" | sed 's/^[1-9][0-9]*$/yes/')" "yes"
check "it runs the tests before publishing" \
    "$([ "$(line_of 'run: npm test')" -lt "$(line_of 'scripts/publish-release')" ] && echo yes || echo no)" "yes"
check "CI fails a pull request whose versions drifted" \
    "$(grep -c 'run: node scripts/sync-plugin-version.js --check$' "$ROOT/.github/workflows/ci.yml")" "1"
# npm's trusted publisher is configured with this file name; renaming it breaks publishing.
check "the maintainer guide names the workflow file" "$(grep -c 'release\.yml' "$ROOT/INSTALL.md" | sed 's/^[1-9][0-9]*$/yes/')" "yes"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
