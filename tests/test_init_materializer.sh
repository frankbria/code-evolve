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
printf '#!/bin/bash\n[ "${1:-}" = "-l" ] && { echo "no crontab for test" >&2; exit 1; }\ncat >/dev/null\n' > "$stub_dir/crontab"
chmod +x "$stub_dir/claude" "$stub_dir/crontab"
export PATH="$stub_dir:$PATH"
cli() { node "$CLI" "$@" </dev/null >/dev/null 2>&1; }
# Every file outside .git with its content hash, so two trees can be compared exactly.
tree_digest() { (cd "$1" && find . -path ./.git -prune -o -type f -print | sort | xargs -I{} sha256sum {} 2>/dev/null); }

# ── Existing repo with its own AGENTS.md and a CLAUDE.md that does not import it ──
project="$(mktemp -d)"
cd "$project"
git init -q
printf '# House rules\n\nUse tabs.\n' > AGENTS.md
printf '# Claude notes\n' > CLAUDE.md
echo "node_modules/" > .gitignore
before=$(tree_digest "$project")

cli init --yes --agent claude || bad "init --yes failed"
for skill_dir in .claude/skills .agents/skills; do
    for skill in evolve-setup evolve-run evolve-status; do
        [ -f "$skill_dir/$skill/SKILL.md" ] || bad "missing $skill_dir/$skill/SKILL.md"
    done
done
[ -f .claude/skills/evolve-run/SKILL.md ] && [ -f .agents/skills/evolve-run/SKILL.md ] \
    && ok "operator skills are installed in .claude/skills and .agents/skills"
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
rm -f vision.md spec.md   # eject hands these back on purpose
[ "$(tree_digest "$project")" = "$before" ] \
    && ok "init then eject restores the original tree exactly" \
    || bad "tree differs after eject: $(diff <(echo "$before") <(tree_digest "$project") | head -6)"
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
cli eject --yes || bad "fresh eject failed"
[ ! -e AGENTS.md ] && [ ! -e .claude ] && [ ! -e .agents ] && [ ! -e .gitignore ] \
    && ok "eject removes the files and dirs init created" || bad "left behind: $(ls -A)"
cd / && rm -rf "$project"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
