#!/bin/bash
# Test (#94): when the only stack marker sits in a subdirectory (app/package.json, nothing at the
# root), the detected build and test commands run in that subdirectory in both the baseline
# check (prepare) and verification, and the cycle prompt tells the agent to run them there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
work_dir="$(mktemp -d)"
static_dir="$(mktemp -d)"
bootstrap_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir" "$static_dir" "$bootstrap_dir"' EXIT
printf '#!/bin/bash\n[ "${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }\ncat >/dev/null\n' > "$stub_dir/claude"
printf '#!/bin/bash\nexit 1\n' > "$stub_dir/gh"
chmod +x "$stub_dir/claude" "$stub_dir/gh"
export PATH="$stub_dir:$PATH"

# Each script records the directory it ran in, and the test script only passes next to app.js,
# so a run at the project root both leaves the wrong record and fails.
write_app_package() { # <test script>
    printf '{"name":"app","scripts":{"build":"pwd >> %s/build-dirs","test":"%s"}}\n' "$stub_dir" "$1" > app/package.json
}

cd "$work_dir"
git init -q
git config user.email test@example.com
git config user.name test
mkdir app
echo "module.exports = 1" > app/app.js
write_app_package "pwd >> $stub_dir/test-dirs && test -f app.js"
node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed"
git add -A && git commit -qm "baseline"
engine() { ANTHROPIC_API_KEY=k EVOLVE_DIR=.evolve PROJECT_DIR=. AGENT=claude TIMEOUT=60 bash .evolve/scripts/evolve.sh "$@"; }
ran_only_in_app() { [ -s "$1" ] && ! grep -qvxF "$work_dir/app" "$1"; }

engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed: $(tail -3 "$stub_dir/prepare.log")"
ran_only_in_app "$stub_dir/build-dirs" && ok "the baseline build runs in app/" || bad "baseline build ran in: $(cat "$stub_dir/build-dirs" 2>/dev/null)"
ran_only_in_app "$stub_dir/test-dirs" && ok "the baseline test runs in app/" || bad "baseline test ran in: $(cat "$stub_dir/test-dirs" 2>/dev/null)"
grep -q "app build OK" "$stub_dir/prepare.log" && grep -q "app tests OK" "$stub_dir/prepare.log" \
    && ok "the baseline build and test pass" || bad "baseline did not pass: $(grep -i "build\|test" "$stub_dir/prepare.log")"
grep -qF 'cd ./app && npm run build' .evolve/run/PROMPT.md && grep -qF 'cd ./app && npm run test' .evolve/run/PROMPT.md \
    && ok "the prompt gives the commands with their directory" || bad "prompt commands: $(grep -n "npm run" .evolve/run/PROMPT.md)"

rm -f "$stub_dir/build-dirs" "$stub_dir/test-dirs"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && grep -q "Build: PASS" "$stub_dir/verify.log" \
    && ok "verification passes" || bad "verify exited $verify_status: $(tail -3 "$stub_dir/verify.log")"
ran_only_in_app "$stub_dir/build-dirs" && ran_only_in_app "$stub_dir/test-dirs" \
    && ok "verification runs build and test in app/" || bad "verify ran in: $(cat "$stub_dir/build-dirs" "$stub_dir/test-dirs" 2>/dev/null)"

write_app_package "echo broken-app-test >&2; exit 1"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-app-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "a failing test in app/ fails verification" || bad "verify exited $verify_status, ERRORS.md: $(cat .evolve/run/ERRORS.md 2>/dev/null)"

# A nested folder with no commands (static pages) is not reported as verified work.
new_fixture() { # <directory>
    cd "$1"
    git init -q
    git config user.email test@example.com
    git config user.name test
    node "$CLI" init --agent claude </dev/null >/dev/null 2>&1 || bad "init failed in $1"
}
new_fixture "$static_dir"
mkdir site
echo "<html></html>" > site/index.html
git add -A && git commit -qm "baseline"
engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed (static fixture): $(tail -3 "$stub_dir/prepare.log")"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && grep -q "nothing to verify" "$stub_dir/verify.log" && ! grep -q "Build: PASS" "$stub_dir/verify.log" \
    && ok "a nested folder without commands reports nothing to verify" || bad "static verify exited $verify_status: $(tail -3 "$stub_dir/verify.log")"
grep -q "No build system detected yet" .evolve/run/PROMPT.md \
    && ok "the prompt still asks a session to set up build tooling there" || bad "prompt: $(grep -n "Build Verification" .evolve/run/PROMPT.md)"

# Commands the session adds to a nested folder that had none are verified.
printf '{"name":"site","scripts":{"test":"echo broken-site-test >&2; exit 1"}}\n' > site/package.json
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-site-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "checks added to a nested folder during the session are verified" || bad "site verify exited $verify_status: $(tail -3 "$stub_dir/verify.log")"
rm site/package.json

# A project the session adds at the root is verified even though the session started nested.
printf '{"name":"root","scripts":{"test":"echo broken-root-test >&2; exit 1"}}\n' > package.json
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-root-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "a root project added during the session is verified too" || bad "root verify exited $verify_status: $(tail -3 "$stub_dir/verify.log")"

# Bootstrap: nothing detected at the start, the session creates app/.
new_fixture "$bootstrap_dir"
git add -A && git commit -qm "baseline"
engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed (bootstrap fixture): $(tail -3 "$stub_dir/prepare.log")"
mkdir app
printf '{"name":"app","scripts":{"test":"pwd >> %s/bootstrap-dirs"}}\n' "$stub_dir" > app/package.json
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && [ "$(cat "$stub_dir/bootstrap-dirs" 2>/dev/null)" = "$bootstrap_dir/app" ] \
    && ok "a nested project created during the session is verified in its directory" \
    || bad "bootstrap verify exited $verify_status, ran in: $(cat "$stub_dir/bootstrap-dirs" 2>/dev/null)"

# ── Nested projects next to a root project (#152) ──
# Only the folders listed in .evolve/nested-projects.txt are verified; the rest are named.
mixed_dir="$(mktemp -d)"; pipe_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$work_dir" "$static_dir" "$bootstrap_dir" "$mixed_dir" "$pipe_dir"' EXIT
# recording_package <dir> <name> <test script>  → build and test record where they ran
recording_package() {
    printf '{"name":"%s","scripts":{"build":"pwd >> %s/mixed-build-dirs","test":"%s"}}\n' "$2" "$stub_dir" "$3" > "$1/package.json"
}
new_fixture "$mixed_dir"
mkdir api examples
recording_package . root "pwd >> $stub_dir/mixed-test-dirs"
recording_package api api "pwd >> $stub_dir/mixed-test-dirs"
recording_package examples examples "echo broken-examples-test >&2; exit 1"
git add -A && git commit -qm "baseline"
ran_in() { [ "$(sort -u "$1" 2>/dev/null | tr '\n' ' ')" = "$2" ]; }

engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed (root + nested fixture): $(tail -3 "$stub_dir/prepare.log")"
ran_in "$stub_dir/mixed-test-dirs" "$mixed_dir " \
    && ok "without a list, the baseline runs the root project only" || bad "baseline ran in: $(cat "$stub_dir/mixed-test-dirs" 2>/dev/null)"
grep -q "Not verified: api/, examples/" "$stub_dir/prepare.log" && grep -q "nested-projects.txt" "$stub_dir/prepare.log" \
    && ok "prepare names the nested projects it does not verify and how to list them" || bad "prepare notice: $(grep -n "Not verified" "$stub_dir/prepare.log")"
rm -f "$stub_dir/mixed-test-dirs"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && ran_in "$stub_dir/mixed-test-dirs" "$mixed_dir " \
    && ok "without a list, verification runs the root project only and passes" || bad "verify exited $verify_status, ran in: $(cat "$stub_dir/mixed-test-dirs" 2>/dev/null)"
grep -q "Not verified: api/, examples/" "$stub_dir/verify.log" \
    && ok "verify names them too" || bad "verify notice: $(grep -n "Not verified" "$stub_dir/verify.log")"

echo "api" > .evolve/nested-projects.txt
git add -A && git commit -qm "list api"
rm -rf .evolve/run "$stub_dir/mixed-test-dirs" "$stub_dir/mixed-build-dirs"
engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed (listed fixture): $(tail -3 "$stub_dir/prepare.log")"
ran_in "$stub_dir/mixed-test-dirs" "$mixed_dir $mixed_dir/api " && ran_in "$stub_dir/mixed-build-dirs" "$mixed_dir $mixed_dir/api " \
    && ok "listed: the baseline runs the root project and api/" || bad "baseline ran in: $(cat "$stub_dir/mixed-test-dirs" 2>/dev/null)"
grep -q "api build OK" "$stub_dir/prepare.log" && grep -q "Build OK" "$stub_dir/prepare.log" \
    && ok "listed: both baseline builds are reported" || bad "baseline report: $(grep -in "build" "$stub_dir/prepare.log")"
grep -q "Not verified: examples/\." "$stub_dir/prepare.log" \
    && ok "listed: only the unlisted folder is named" || bad "prepare notice: $(grep -n "Not verified" "$stub_dir/prepare.log")"
grep -qF -- '- Test: `npm run test`' .evolve/run/PROMPT.md && grep -qF 'cd ./api && npm run test' .evolve/run/PROMPT.md \
    && ! grep -qF 'cd ./examples' .evolve/run/PROMPT.md \
    && ok "listed: the prompt gives the root commands and api's with its directory" || bad "prompt commands: $(grep -n "npm run" .evolve/run/PROMPT.md)"

rm -f "$stub_dir/mixed-test-dirs"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && ran_in "$stub_dir/mixed-test-dirs" "$mixed_dir $mixed_dir/api " \
    && ok "listed: verification runs the root project and api/" || bad "verify exited $verify_status, ran in: $(cat "$stub_dir/mixed-test-dirs" 2>/dev/null)"
recording_package api api "echo broken-api-test >&2; exit 1"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-api-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "listed: a failing test in api/ fails verification" || bad "verify exited $verify_status, ERRORS.md: $(cat .evolve/run/ERRORS.md 2>/dev/null)"
# The list as it was when the session started still counts: taking a folder off it mid-session
# does not drop its checks.
: > .evolve/nested-projects.txt
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-api-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "listed: emptying the list during the session keeps api/ verified" || bad "verify exited $verify_status after the list was emptied"
grep -q "Not verified: examples/\." "$stub_dir/verify.log" \
    && ok "listed: a folder that is still verified is not named as unverified" || bad "verify notice after the list was emptied: $(grep -n "Not verified" "$stub_dir/verify.log")"
# A folder listed during the session is verified from then on.
echo "examples" > .evolve/nested-projects.txt
recording_package api api "true"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -q "broken-examples-test" .evolve/run/ERRORS.md 2>/dev/null \
    && ok "listed: a folder added to the list during the session is verified" || bad "verify exited $verify_status after examples was listed"

# ── A directory name containing | (#152) ──
new_fixture "$pipe_dir"
mkdir 'a|b'
printf '{"name":"piped","scripts":{"build":"pwd >> %s/pipe-dirs","test":"pwd >> %s/pipe-dirs && test -f marker"}}\n' "$stub_dir" "$stub_dir" > 'a|b/package.json'
touch 'a|b/marker'
git add -A && git commit -qm "baseline"
engine prepare > "$stub_dir/prepare.log" 2>&1 || bad "prepare failed (| fixture): $(tail -3 "$stub_dir/prepare.log")"
grep -qF "cd './a|b' && npm run test" .evolve/run/PROMPT.md \
    && ok "a directory with | in its name: the prompt quotes it for the shell" || bad "| prompt: $(grep -n "npm run" .evolve/run/PROMPT.md)"
ran_in "$stub_dir/pipe-dirs" "$pipe_dir/a|b " && grep -qF 'a|b build OK' "$stub_dir/prepare.log" && grep -qF 'a|b tests OK' "$stub_dir/prepare.log" \
    && ok "a directory with | in its name: the baseline runs in it" || bad "| baseline ran in: $(cat "$stub_dir/pipe-dirs" 2>/dev/null); $(grep -n "OK\|issues" "$stub_dir/prepare.log")"
rm -f "$stub_dir/pipe-dirs"
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -eq 0 ] && grep -q "Build: PASS" "$stub_dir/verify.log" && ran_in "$stub_dir/pipe-dirs" "$pipe_dir/a|b " \
    && ok "a directory with | in its name: verification runs in it and passes" || bad "| verify exited $verify_status, ran in: $(cat "$stub_dir/pipe-dirs" 2>/dev/null)"
rm 'a|b/marker'
verify_status=0; engine verify > "$stub_dir/verify.log" 2>&1 || verify_status=$?
[ "$verify_status" -ne 0 ] && grep -qF '[a|b test]' .evolve/run/ERRORS.md 2>/dev/null \
    && ok "a directory with | in its name: its failing test fails verification" || bad "| verify exited $verify_status, ERRORS.md: $(cat .evolve/run/ERRORS.md 2>/dev/null)"
cd /

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
