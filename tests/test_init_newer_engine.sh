#!/bin/bash
# Test (#140): init (and setup, which runs it) refuses to put this version's engine over a newer
# installed one and changes nothing; the same, an older or an unrecorded version is refreshed as before.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
VERSION="$(node -p "require('$ROOT/package.json').version")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

project="$(mktemp -d)"; stub_dir="$(mktemp -d)"
trap 'rm -rf "$project" "$stub_dir"' EXIT
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"
printf '#!/bin/bash\necho "codex 0.0.0-stub"\n' > "$stub_dir/codex"
# Never touch the real crontab: this stub holds an empty table.
printf '#!/bin/bash\n[ "${1:-}" = "-l" ] && { echo "no crontab for $USER" >&2; exit 1; }\ncat > /dev/null\n' > "$stub_dir/crontab"
chmod +x "$stub_dir/claude" "$stub_dir/codex" "$stub_dir/crontab"
export PATH="$stub_dir:$PATH"
cd "$project"
git init -q; git config user.email t@example.com; git config user.name t
node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1

record_engine() { # <version, or empty to remove the record>: also plants a marker a refresh would remove
    ENGINE="$1" node -e "const f='.evolve/config.json';const c=require('./'+f);if(process.env.ENGINE)c.engineVersion=process.env.ENGINE;else delete c.engineVersion;require('fs').writeFileSync(f,JSON.stringify(c,null,2)+'\n')"
    echo "# installed engine" >> .evolve/scripts/evolve.sh
    git add -A && git commit -qm "engine ${1:-unrecorded}"
}
marker() { grep -c '# installed engine' .evolve/scripts/evolve.sh || true; }
refused() { # <label> <command...>: exits 1, says why and what to do, and leaves the tree as committed
    local label="$1" status=0; shift
    node "$CLI" "$@" </dev/null > "$stub_dir/refusal.log" 2>&1 || status=$?
    check "$label: exits 1" "$status" "1"
    check "$label: names both versions" "$(grep -c "installed engine (99.0.0) is newer than this code-evolve ($VERSION)" "$stub_dir/refusal.log")" "1"
    check "$label: says what to do" "$(grep -c 'npx code-evolve@latest' "$stub_dir/refusal.log")" "1"
    check "$label: changes nothing" "$(git status --porcelain)" ""
}

record_engine 99.0.0
refused "init --yes over a newer engine" init --yes --agent claude
# Plain init is refused for the same reason, not sent to --force (which would only be refused next).
refused "plain init over a newer engine" init
check "plain init does not suggest --force" "$(grep -c -- '--force' "$stub_dir/refusal.log" || true)" "0"
refused "init --yes switching agent over a newer engine" init --yes --agent codex
refused "init --force over a newer engine" init --force
refused "setup over a newer engine" setup
refused "upgrade over a newer engine" upgrade
check "upgrade names its own command" "$(grep -c 'npx code-evolve@latest upgrade' "$stub_dir/refusal.log")" "1"
check "the newer engine's files are still installed" "$(marker)" "1"
check "the newer engine's version is still recorded" "$(node -p "require('./.evolve/config.json').engineVersion")" "99.0.0"

refreshed() { # <label> <recorded version, or empty>
    record_engine "$2"
    local status=0
    node "$CLI" init --yes </dev/null > "$stub_dir/refresh.log" 2>&1 || status=$?
    check "$1: init --yes succeeds" "$status" "0"
    check "$1: the engine is replaced" "$(marker)" "0"
    check "$1: this version is recorded" "$(node -p "require('./.evolve/config.json').engineVersion")" "$VERSION"
    git add -A && git commit -qm "refreshed"
}
refreshed "the same version" "$VERSION"
refreshed "an older version" "0.0.1"
refreshed "an unrecorded version" ""

# A leftover config.json without an engine beside it is not an install: init sets the directory up.
leftover="$(mktemp -d)"
(
    cd "$leftover"
    git init -q
    mkdir .evolve && printf '{"agent":"claude","engineVersion":"99.0.0"}\n' > .evolve/config.json
    status=0; node "$CLI" init --yes </dev/null >/dev/null 2>&1 || status=$?
    echo "$status $(node -p "require('./.evolve/config.json').engineVersion") $([ -f .evolve/scripts/evolve.sh ] && echo installed)" > "$stub_dir/leftover"
)
rm -rf "$leftover"
check "a leftover config.json with no engine does not block a new install" "$(cat "$stub_dir/leftover")" "0 $VERSION installed"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
