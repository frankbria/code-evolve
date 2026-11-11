#!/bin/bash
# Test (#85): every relative Markdown link in the repository's own documentation points at a
# file that exists, so a moved or renamed document (the demos in docs/demos/ are linked from the
# README and the changelog) cannot leave a dead link behind.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT" <<'EOF'
import glob, os, re, sys

root = sys.argv[1]
documents = [os.path.join(root, name) for name in ("README.md", "CHANGELOG.md", "INSTALL.md", "AGENTS.md")]
documents += glob.glob(os.path.join(root, "docs", "**", "*.md"), recursive=True)
link = re.compile(r"\]\(([^)#\s]+)(?:#[^)\s]*)?\)")

checked, broken = 0, []
for document in documents:
    with open(document, encoding="utf-8") as handle:
        text = handle.read()
    for target in link.findall(text):
        if re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target):
            continue  # http:, mailto: and other absolute links are not checked here
        checked += 1
        if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(document), target))):
            broken.append(f"{os.path.relpath(document, root)} -> {target}")

for entry in broken:
    print(f"  FAIL: dead link: {entry}")
demo = os.path.join(root, "docs", "demos", "first-cycle-acceptance.md")
if not os.path.isfile(demo):
    broken.append("docs/demos/first-cycle-acceptance.md is missing")
    print("  FAIL: docs/demos/first-cycle-acceptance.md is missing")
if checked == 0:
    broken.append("no links checked")
    print("  FAIL: no relative links were found, so the check is not looking at the documents")
print(f"  {checked} relative links checked in {len(documents)} documents, {len(broken)} problems")
sys.exit(1 if broken else 0)
EOF
