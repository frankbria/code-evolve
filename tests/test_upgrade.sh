#!/bin/bash
# Test (#88): `code-evolve upgrade` replaces the managed engine files with this version's, keeps every
# user-owned file byte-identical, records engineVersion, and refuses to run on a dirty tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
VERSION="$(node -p "require('$ROOT/package.json').version")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
same() { cmp -s "$1" "$2" && echo same || echo different; }

project="$(mktemp -d)"; stub_dir="$(mktemp -d)"
trap 'rm -rf "$project" "$stub_dir"' EXIT
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"; chmod +x "$stub_dir/claude"
export PATH="$stub_dir:$PATH"
cd "$project"
git init -q; git config user.email t@example.com; git config user.name t
node "$CLI" init --yes --agent claude </dev/null >/dev/null 2>&1
check "init records the engine version" "$(node -p "require('./.evolve/config.json').engineVersion")" "$VERSION"

# Turn it into an "older install": stale engine files, an unrecorded version, and real user content.
echo "# old engine" >> .evolve/scripts/evolve.sh
echo "# old skill" >> .evolve/skills/prove/SKILL.md
echo "# old constitution" >> .evolve/IDENTITY.md
node -e "const f='.evolve/config.json';const c=require('./'+f);delete c.engineVersion;require('fs').writeFileSync(f,JSON.stringify(c,null,2))"
printf '# Vision\nOur own vision.\n' > .evolve/vision.md
printf '# Spec\n- [ ] our feature\n' > .evolve/spec.md
printf '# Journal\n\n## Day 3 - our entry\n' > .evolve/JOURNAL.md
printf '# Learnings\nour learning\n' > .evolve/LEARNINGS.md
printf '\n## REQ-0001: ours\n- **Status**: open\n' >> .evolve/REQUIREMENTS.md
echo 3 > .evolve/DAY_COUNT
git add -A && git commit -qm "older install"
user_files=(vision.md spec.md JOURNAL.md LEARNINGS.md REQUIREMENTS.md DAY_COUNT .birth_date)
saved="$stub_dir/saved"; mkdir "$saved"
for file in "${user_files[@]}"; do cp ".evolve/$file" "$saved/$file"; done
check "status reports the unrecorded engine version" "$(node "$CLI" status </dev/null | node -p "JSON.parse(require('fs').readFileSync(0)).engineVersion")" "null"

# A dirty tree is refused before anything changes.
echo "work in progress" > notes.txt
status=0; node "$CLI" upgrade </dev/null > "$stub_dir/dirty.log" 2>&1 || status=$?
check "upgrade refuses a dirty tree" "$status" "1"
check "the refusal says why" "$(grep -c 'Commit or stash' "$stub_dir/dirty.log")" "1"
check "a refused upgrade changes nothing" "$(grep -c '# old engine' .evolve/scripts/evolve.sh)" "1"
rm notes.txt

status=0; node "$CLI" upgrade </dev/null > "$stub_dir/upgrade.log" 2>&1 || status=$?
check "upgrade succeeds on a clean tree" "$status" "0"
check "the engine script is replaced" "$(same .evolve/scripts/evolve.sh "$ROOT/templates/scripts/evolve.sh")" "same"
check "runtime skills are replaced" "$(same .evolve/skills/prove/SKILL.md "$ROOT/templates/skills/prove/SKILL.md")" "same"
check "IDENTITY.md is replaced" "$(same .evolve/IDENTITY.md "$ROOT/templates/state/IDENTITY.md")" "same"
for file in "${user_files[@]}"; do
    check "$file is kept byte-identical" "$(same ".evolve/$file" "$saved/$file")" "same"
done
check "the agent choice is kept" "$(node -p "require('./.evolve/config.json').agent")" "claude"
check "engineVersion is recorded" "$(node -p "require('./.evolve/config.json').engineVersion")" "$VERSION"
check "status shows no drift afterwards" "$(node "$CLI" status </dev/null | node -p "JSON.stringify(JSON.parse(require('fs').readFileSync(0)).engineDrift)")" "[]"

plain="$(mktemp -d)"
status=0; (cd "$plain" && node "$CLI" upgrade </dev/null >/dev/null 2>&1) || status=$?
rm -rf "$plain"
check "upgrade outside an install exits 1" "$status" "1"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
