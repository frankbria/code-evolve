#!/bin/bash
# Test (#79): `init --yes` is the one materializer every install surface calls. It never
# prompts, is idempotent, installs the operator skills where agents look for them, adds a
# marked code-evolve section to AGENTS.md (and CLAUDE.md when needed), and eject undoes it all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
printf '#!/bin/bash\necho "claude 0.0.0-stub"\n' > "$stub_dir/claude"
cat > "$stub_dir/crontab" <<STUB
#!/bin/bash
if [ "\${1:-}" = "-l" ]; then [ -f "$stub_dir/table" ] && cat "$stub_dir/table" && exit 0; echo "no crontab for test" >&2; exit 1; fi
cat > "$stub_dir/table"
STUB
chmod +x "$stub_dir/claude" "$stub_dir/crontab"
export PATH="$stub_dir:$PATH"
cli() { node "$CLI" "$@" </dev/null >/dev/null 2>&1; }
# Every file outside .git with its content hash, so two trees can be compared exactly.
tree_digest() { (cd "$1" && { find . -path ./.git -prune -o -type f -print | sort | xargs -I{} sha256sum {} 2>/dev/null
    find . -path ./.git -prune -o -type d -print | sort | sed 's/^/dir  /'; }); }

# ── Existing repo with its own AGENTS.md and a CLAUDE.md that does not import it ──
project="$(mktemp -d)"
cd "$project"
git init -q
printf '# House rules\n\nUse tabs.\n' > AGENTS.md
printf '# Claude notes\n' > CLAUDE.md
printf 'node_modules/\n\n\n.evolve/.env*\n' > .gitignore   # a rule init also manages, plus blank lines
mkdir -p .claude/skills/evolve-run && printf -- '---\nname: evolve-run\ndescription: my own\n---\nmine (body mentions managed-by: code-evolve)\n' > .claude/skills/evolve-run/SKILL.md
mkdir -p .agents/skills   # a pre-existing empty skills dir must survive the round trip
before=$(tree_digest "$project")

cli init --yes --agent claude || bad "init --yes failed"
for skill_dir in .claude/skills .agents/skills; do
    for skill in evolve-setup evolve-run evolve-status; do
        [ -f "$skill_dir/$skill/SKILL.md" ] || bad "missing $skill_dir/$skill/SKILL.md"
    done
done
[ -f .claude/skills/evolve-setup/SKILL.md ] && [ -f .agents/skills/evolve-run/SKILL.md ] \
    && ok "operator skills are installed in .claude/skills and .agents/skills"
grep -q "^mine " .claude/skills/evolve-run/SKILL.md \
    && ok "a same-named skill the user wrote is left alone" || bad "user's evolve-run skill was replaced"
[ "$(grep -c 'code-evolve:begin' AGENTS.md)" = "1" ] && grep -q "Use tabs." AGENTS.md \
    && ok "AGENTS.md keeps its content and gains one code-evolve section" || bad "AGENTS.md: $(cat AGENTS.md)"
[ "$(grep -c 'code-evolve:begin' CLAUDE.md)" = "1" ] \
    && ok "CLAUDE.md without @AGENTS.md gets the section too" || bad "CLAUDE.md: $(cat CLAUDE.md)"

after_first=$(tree_digest "$project")
cli init --yes --agent claude || bad "second init --yes failed"
[ "$(tree_digest "$project")" = "$after_first" ] \
    && ok "running init --yes twice leaves an identical tree" \
    || bad "second init changed: $(diff <(echo "$after_first") <(tree_digest "$project") | head -5)"

cli eject --yes || bad "eject failed"
# eject hands vision.md and spec.md back at the root on purpose; nothing else may differ.
[ "$(diff <(echo "$before") <(tree_digest "$project") | grep '^>' | sed 's/.*  \.\///' | sort | tr '\n' ' ')" = "spec.md vision.md " ] \
    && [ -z "$(diff <(echo "$before") <(tree_digest "$project") | grep '^<')" ] \
    && ok "init then eject restores the original tree (plus the vision/spec eject hands back)" \
    || bad "tree differs after eject: $(diff <(echo "$before") <(tree_digest "$project") | head -6)"
grep -q "^mine " .claude/skills/evolve-run/SKILL.md && ok "eject keeps the user's own skill" || bad "eject removed the user's skill"
cd / && rm -rf "$project"

# ── Fresh repo: init creates AGENTS.md; CLAUDE.md that imports AGENTS.md is left alone ──
project="$(mktemp -d)"
cd "$project"
git init -q
printf '# Claude\n@AGENTS.md\n' > CLAUDE.md
cli init --yes --agent claude || bad "fresh init failed"
[ -f AGENTS.md ] && grep -q "code-evolve:begin" AGENTS.md && ok "init creates AGENTS.md with the section" || bad "no AGENTS.md"
[ "$(cat CLAUDE.md)" = "$(printf '# Claude\n@AGENTS.md')" ] \
    && ok "a CLAUDE.md that imports AGENTS.md is not modified" || bad "CLAUDE.md changed: $(cat CLAUDE.md)"
sed -i 's/$/\r/' .claude/skills/evolve-run/SKILL.md   # as checked out with core.autocrlf=true
cli eject --yes || bad "fresh eject failed"
[ ! -e AGENTS.md ] && [ ! -e .claude ] && [ ! -e .agents ] && [ ! -e .gitignore ] \
    && ok "eject removes the files and dirs init created" || bad "left behind: $(ls -A)"
cd / && rm -rf "$project"

# ── Symlinked AGENTS.md is left alone; every managed .gitignore rule pre-existing survives ──
project="$(mktemp -d)"
cd "$project"
git init -q
shared="$(mktemp)"; echo "# shared instructions" > "$shared"
ln -s "$shared" AGENTS.md
printf '%s\n' "# code-evolve ephemeral files" .evolve/ISSUES_TODAY.md .evolve/ISSUE_RESPONSE.md .evolve/.env \
    '.evolve/.env*' .evolve/evolve.log .evolve/schedule.json .evolve/evidence/ > .gitignore
gitignore_before=$(cat .gitignore)
cli init --yes --agent claude || bad "symlink init failed"
[ "$(cat "$shared")" = "# shared instructions" ] && [ -L AGENTS.md ] \
    && ok "a symlinked AGENTS.md (shared instructions) is not written through" || bad "shared file changed: $(cat "$shared")"
cli eject --yes || bad "symlink eject failed"
[ "$(cat .gitignore)" = "$gitignore_before" ] \
    && ok "user-authored copies of every managed .gitignore rule survive init and eject" || bad ".gitignore changed: $(cat .gitignore)"
cd / && rm -rf "$project" "$shared"

# ── Refresh keeps the schedule; a fresh --yes keeps root documents; symlinked skill dirs are skipped ──
project="$(mktemp -d)"
cd "$project"
git init -q
echo "# my vision" > vision.md
outside="$(mktemp -d)"
mkdir -p .agents && ln -s "$outside" .agents/skills
ANTHROPIC_API_KEY=sk-test cli init --yes --agent claude --mode local --every 6 || bad "local init failed"
[ "$(cat vision.md 2>/dev/null)" = "# my vision" ] \
    && ok "a fresh init --yes leaves the project's own root vision.md in place" || bad "root vision.md was moved"
[ -z "$(ls -A "$outside")" ] && ok "a symlinked .agents/skills is skipped, nothing written through it" || bad "wrote into the symlink target"
schedule_before=$(cat .evolve/schedule.json); table_before=$(cat "$stub_dir/table")
sleep 1
ANTHROPIC_API_KEY=sk-test cli init --yes --agent claude || bad "refresh failed"
[ "$(cat .evolve/schedule.json)" = "$schedule_before" ] && [ "$(cat "$stub_dir/table")" = "$table_before" ] \
    && ok "a refresh keeps the existing local schedule (every 6h) untouched" || bad "refresh rewrote the schedule: $(cat .evolve/schedule.json)"
printf '#!/bin/bash\necho "codex 0.0.0-stub"\n' > "$stub_dir/codex"; chmod +x "$stub_dir/codex"
OPENAI_API_KEY=sk-test cli init --yes --agent codex || bad "agent-change refresh failed"
grep -q 'AGENT="codex"' "$stub_dir/table" && grep -q '"agent": "codex"' .evolve/schedule.json && grep -q '"every": 6' .evolve/schedule.json \
    && ok "an explicit agent change on refresh reinstalls the schedule for the new agent" || bad "schedule still uses the old agent: $(grep -o 'AGENT=[^ ]*' "$stub_dir/table")"
ANTHROPIC_API_KEY=sk-test cli eject --yes || bad "local eject failed"
[ ! -e .gitignore ] && ok "eject removes the .gitignore a local-mode init created" || bad "left .gitignore: $(cat .gitignore)"
cd / && rm -rf "$project" "$outside"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
