#!/bin/bash
# Test (#113): the checks a session is verified with only grow. `verify` writes what it finds
# (root commands and nested projects) back to .evolve/run/session.env, so a later `verify` or
# `finalize` still runs a check that the work tree no longer declares.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
fixtures_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$fixtures_dir"' EXIT
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }\ncat >/dev/null\n' > "$stub_dir/claude"
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/gh"
export PATH="$stub_dir:$PATH"

new_fixture() { # <name>: an initialized repo; the caller adds files and commits the baseline
    mkdir "$fixtures_dir/$1"
    cd "$fixtures_dir/$1"
    git init -q
    git config user.email test@example.com
    git config user.name test
    node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed in $1"
}
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }
prepare() { # <name>
    git add -A && git commit -qm "baseline"
    engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed ($1): $(tail -3 "$stub_dir/prepare.log")"
}
package_json() { # <name> <scripts object>
    printf '{"name":"%s","scripts":%s}\n' "$1" "$2"
}
session_value() { sed -n "s/^$1=//p" .evolve/run/session.env 2>/dev/null; }
finalize_reverted() { grep -q "Verification failed" "$stub_dir/finalize.log" && grep -q "^## REQ-0001" .evolve/REQUIREMENTS.md; }

# ── Checks first found at verify are written to session.env ──
new_fixture found
prepare found
[ -z "$(session_value TEST_CMD)" ] || bad "test setup: a test command was detected before the session made one"
state_before=$(grep -vE '^(STACK|BUILD_CMD|TEST_CMD|LINT_CMD|FORMAT_CMD|SUBSTACKS_JSON)=' .evolve/run/session.env)
package_json demo '{"test":"true"}' > package.json
git add -A && git commit -qm "Day 0: add the project"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && [ "$(session_value TEST_CMD)" = "npm run test" ] && [ "$(session_value STACK)" = "javascript" ] \
    && ok "verify records the commands it found in session.env" \
    || bad "verify exited $verify_status, recorded: stack '$(session_value STACK)' test '$(session_value TEST_CMD)'"
[ "$state_before" = "$(grep -vE '^(STACK|BUILD_CMD|TEST_CMD|LINT_CMD|FORMAT_CMD|SUBSTACKS_JSON)=' .evolve/run/session.env)" ] \
    && ok "verify leaves the rest of the session state as prepare wrote it" || bad "verify changed other session state"
[ -z "$(ls .evolve/run | grep -v -x -e session.env -e PROMPT.md -e protected -e verify.status -e verify.fingerprint)" ] \
    && ok "verify leaves no temporary state file behind" || bad "unexpected files in .evolve/run: $(ls .evolve/run)"

# The test script is dropped after the passing verify: finalize still runs it.
package_json demo '{}' > package.json
echo "unchecked" > unchecked.txt
git add -A && git commit -qm "Day 0: drop the test script"
engine finalize --no-agent > "$stub_dir/finalize.log" 2>&1 || true
finalize_reverted && [ ! -e unchecked.txt ] && [ ! -e package.json ] \
    && ok "finalize runs a check found at verify after the session removed it, and reverts" \
    || bad "finalize kept unchecked work: $(grep -iE 'verif|revert' "$stub_dir/finalize.log" | head -3)"

# ── A failing check cannot be removed to make the next verify pass ──
new_fixture again
prepare again
package_json demo '{"test":"echo broken-first-test >&2; exit 1"}' > package.json
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-first-test" .evolve/run/ERRORS.md 2>/dev/null \
    || bad "test setup: the first verify should fail (exit $verify_status)"
package_json demo '{}' > package.json
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && ! grep -q "nothing to verify" "$stub_dir/verify.log" \
    && ok "a second verify still runs the check the first one found" || bad "second verify exited $verify_status: $(tail -2 "$stub_dir/verify.log")"

# ── A nested project found at verify is kept for finalize ──
new_fixture nested
prepare nested
mkdir app
package_json app '{"test":"true"}' > app/package.json
git add -A && git commit -qm "Day 0: add app/"
engine verify > "$stub_dir/verify.log" 2>&1 || bad "verify (nested) failed: $(tail -2 "$stub_dir/verify.log")"
[ "$(session_value STACK)" = "monorepo" ] && session_value SUBSTACKS_JSON | grep -q '"dir": "app"' \
    && ok "verify records the nested project it found" || bad "recorded: stack '$(session_value STACK)' substacks '$(session_value SUBSTACKS_JSON)'"
package_json app '{}' > app/package.json
git add -A && git commit -qm "Day 0: drop app's test script"
engine finalize --no-agent > "$stub_dir/finalize.log" 2>&1 || true
finalize_reverted && [ ! -e app/package.json ] \
    && ok "finalize runs the nested project's check after the session removed it" \
    || bad "finalize kept unchecked nested work: $(grep -iE 'verif|revert' "$stub_dir/finalize.log" | head -3)"

# ── A root project added after verify is checked next to the subprojects known from the start ──
new_fixture root
mkdir app
package_json app "{\"test\":\"pwd >> $stub_dir/root-fixture-app-runs\"}" > app/package.json
prepare root
engine verify > "$stub_dir/verify.log" 2>&1 || bad "verify (root added later) failed: $(tail -2 "$stub_dir/verify.log")"
rm -f "$stub_dir/root-fixture-app-runs"
package_json root '{"test":"echo broken-root-test >&2; exit 1"}' > package.json
git add -A && git commit -qm "Day 0: add a root project"
engine finalize --no-agent > "$stub_dir/finalize.log" 2>&1 || true
finalize_reverted && grep -q "broken-root-test" .evolve/REQUIREMENTS.md .evolve/LAST_VERIFY.md && [ ! -e package.json ] \
    && ok "finalize verifies a root project added after verify" \
    || bad "root project not verified at finalize: $(grep -iE 'verif|revert' "$stub_dir/finalize.log" | head -3)"
[ "$(cat "$stub_dir/root-fixture-app-runs" 2>/dev/null)" = "$fixtures_dir/root/app" ] \
    && ok "the subproject known from the start is verified in the same run" || bad "app/ ran in: $(cat "$stub_dir/root-fixture-app-runs" 2>/dev/null)"

# ── A root with no commands (static page) that becomes a nested project is verified ──
new_fixture static
echo "<html></html>" > index.html
prepare static
git rm -q index.html
mkdir app
package_json app '{"test":"echo broken-moved-test >&2; exit 1"}' > app/package.json
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-moved-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "a nested project that replaces a static root is verified" || bad "static-to-nested verify exited $verify_status: $(tail -2 "$stub_dir/verify.log")"
cd /

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
