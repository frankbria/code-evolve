#!/bin/bash
# Test (#143): the "Detect and verify project" step of the CI workflow `init --with-ci` installs
# (templates/workflows/ci.yml → .github/workflows/evolve-ci.yml). The step's script is taken
# from the workflow file and run in fixture projects the way a GitHub runner runs it (bash -e).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/templates/workflows/ci.yml"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The step's `run: |` block: every line indented deeper than its key, with that indent removed.
awk '
    /^      - name: / { in_step = ($0 == "      - name: Detect and verify project"); in_run = 0; next }
    in_step && /^        run: \|$/ { in_run = 1; next }
    in_run && /^          / { print substr($0, 11); next }
    in_run && /^[[:space:]]*$/ { print ""; next }
    { in_run = 0 }
' "$WORKFLOW" > "$scratch/step.sh"
grep -q 'detect_stack.sh' "$scratch/step.sh" && bash -n "$scratch/step.sh" \
    && ok "the step's script is found in the workflow and is valid bash" || bad "could not extract the step's script"

# Only the tools the step and the fixtures need, so the result does not depend on what this
# machine has installed; pip is a stand-in that records its arguments and installs nothing.
toolbox="$scratch/toolbox"
mkdir "$toolbox"
for tool in bash sh cat grep find basename dirname sed env chmod; do
    ln -s "$(command -v "$tool")" "$toolbox/$tool"
done
python3 -m venv --without-pip "$scratch/no-pip"
ln -s "$scratch/no-pip/bin/python3" "$toolbox/python3"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$scratch/pip.log" > "$toolbox/pip"
chmod +x "$toolbox/pip"

# new_project <name>  → a project directory with the engine's scripts installed
new_project() {
    mkdir -p "$scratch/$1/.evolve"
    cp -R "$ROOT/templates/scripts" "$scratch/$1/.evolve/scripts"
    echo "$scratch/$1"
}
# python_project <dir> <assertion>  → a Python project with one unittest test
python_project() {
    mkdir -p "$1/tests"
    printf '[project]\nname = "fixture"\nversion = "0.1.0"\n' > "$1/pyproject.toml"
    printf 'import unittest\n\n\nclass GreetingTest(unittest.TestCase):\n    def test_greeting(self):\n        self.%s\n' "$2" > "$1/tests/test_greeting.py"
}
# run_step <dir>  → the step's exit status; its output goes to step.log
run_step() { ( cd "$1" && PATH="$toolbox" bash -e "$scratch/step.sh" ) > "$scratch/step.log" 2>&1; }
logged() { grep -qF -- "$1" "$scratch/step.log"; }

# ── A single project ──
single="$(new_project single)"
python_project "$single" 'assertEqual("hi", "hi")'
run_step "$single" && logged "Running tests: python3 -m unittest discover -s tests" && logged "Ran 1 test" \
    && ok "a Python project: the detected test command runs and the step passes" || bad "passing project: $(tail -5 "$scratch/step.log")"
grep -qx -- "install -e ." "$scratch/pip.log" && ok "a Python project: its dependencies are installed first" || bad "pip was not asked to install the project"

python_project "$single" 'assertEqual("hi", "bye")'
run_step "$single" && bad "a failing test passed the step" || { logged "FAILED (failures=1)" && ok "a failing test fails the step" || bad "failing project: $(tail -5 "$scratch/step.log")"; }

# Lint is reported but does not fail the step.
python_project "$single" 'assertEqual("hi", "hi")'
printf '#!/bin/sh\necho "lint finding"\nexit 1\n' > "$toolbox/ruff"; chmod +x "$toolbox/ruff"
run_step "$single" && logged "Running lint: ruff check" && logged "lint finding" \
    && ok "a lint finding is shown and does not fail the step" || bad "lint: $(tail -5 "$scratch/step.log")"
rm "$toolbox/ruff"

empty="$(new_project empty)"
run_step "$empty" && logged "No project stack detected yet" \
    && ok "no project yet: the step passes without running anything" || bad "empty project: $(tail -5 "$scratch/step.log")"

# ── Projects one level down ──
nested="$(new_project nested)"
python_project "$nested/backend" 'assertEqual("hi", "hi")'
python_project "$nested/tools" 'assertEqual("hi", "hi")'
run_step "$nested" && logged "=== backend (python) ===" && logged "=== tools (python) ===" \
    && [ "$(grep -c "Ran 1 test" "$scratch/step.log")" = "2" ] \
    && ok "nested projects: each one's tests run in its own directory and the step passes" || bad "nested projects: $(tail -8 "$scratch/step.log")"
python_project "$nested/tools" 'assertEqual("hi", "bye")'
run_step "$nested" && bad "a failing nested project passed the step" \
    || { logged "=== backend (python) ===" && logged "FAILED (failures=1)" && ok "one failing nested project fails the step" || bad "failing nested project: $(tail -8 "$scratch/step.log")"; }

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
