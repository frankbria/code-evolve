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
cd /

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
