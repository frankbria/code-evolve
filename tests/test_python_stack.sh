#!/bin/bash
# Test (#133): a Python project is verified with tools that can actually run.
#   - pytest and ruff are only returned when installed (a project .venv first, then PATH);
#     unittest-style tests fall back to `python3 -m unittest discover`.
#   - `pip install` is not returned where pip would refuse it or is missing.
#   - ruff (and deno) leave the engine's own directories alone.
# The detected commands are run for real in the fixtures; only ruff and pip are stand-ins
# where the real tool may not be installed (real ruff is also used when it is on PATH).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/templates/scripts/detect_stack.sh"
CLI="$ROOT/dist/cli.js"
ENGINE_EXCLUDES=".evolve,.claude,.agents"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# A PATH holding only what detection and the fixtures' own commands need, so pytest, ruff
# and pip are absent whatever this machine has installed.
toolbox="$scratch/toolbox"
mkdir "$toolbox"
for tool in bash sh cat grep basename dirname python3 sed env; do
    ln -s "$(command -v "$tool")" "$toolbox/$tool"
done
REAL_RUFF="$(command -v ruff || true)"

field() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))"; }
# detect_in <dir> [extra PATH dir]  → the JSON detected with the toolbox PATH
detect_in() { PATH="${2:+$2:}$toolbox" bash "$SCRIPT" "$1"; }
# run_in <dir> <command> [extra PATH dir]  → run a detected command the way the engine does
run_in() { ( cd "$1" && PATH="${3:+$3:}$toolbox" eval "$2" ) > "$scratch/run.log" 2>&1; }
# new_fixture <name>  → an empty project directory
new_fixture() { mkdir -p "$scratch/$1"; echo "$scratch/$1"; }
executable() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n%s\n' "${2:-exit 0}" > "$1"; chmod +x "$1"; }
write_unittest() { # <file>
    mkdir -p "$(dirname "$1")"
    printf 'import unittest\n\n\nclass GreetingTest(unittest.TestCase):\n    def test_greeting(self):\n        self.assertEqual("hi", "hi")\n' > "$1"
}

# ── Acceptance 1: pyproject.toml + unittest tests, no pytest/ruff/pip → commands run and pass ──
plain="$(new_fixture plain)"
printf '[project]\nname = "plain"\nversion = "0.1.0"\n' > "$plain/pyproject.toml"
write_unittest "$plain/tests/test_greeting.py"
J=$(detect_in "$plain")
check "unittest project: stack"  "$(field "$J" stack)"  "python"
check "unittest project: test"   "$(field "$J" test)"   "python3 -m unittest discover -s tests"
check "unittest project: no build without pip" "$(field "$J" build)"  ""
check "unittest project: no lint without ruff"   "$(field "$J" lint)"   ""
check "unittest project: no format without ruff" "$(field "$J" format)" ""
run_in "$plain" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok "unittest project: the detected test command runs the test and passes" \
    || bad "unittest project: test command failed: $(tail -3 "$scratch/run.log")"

sed -i 's/"hi", "hi"/"hi", "bye"/' "$plain/tests/test_greeting.py"
run_in "$plain" "$(field "$J" test)" && bad "unittest project: a failing test passed" || ok "unittest project: a failing test fails the command"

# tests/ as a package, and tests next to the code, are found from the project root.
package="$(new_fixture package)"
printf '[project]\nname = "package"\nversion = "0.1.0"\n' > "$package/pyproject.toml"
write_unittest "$package/tests/test_greeting.py"
: > "$package/tests/__init__.py"
J=$(detect_in "$package")
check "tests package: test" "$(field "$J" test)" "python3 -m unittest discover"
run_in "$package" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok "tests package: the test is found and passes" || bad "tests package: $(tail -3 "$scratch/run.log")"

flat="$(new_fixture flat)"
echo "requests" > "$flat/requirements.txt"
write_unittest "$flat/test_greeting.py"
J=$(detect_in "$flat")
check "requirements.txt: test" "$(field "$J" test)" "python3 -m unittest discover"
check "requirements.txt: no build without pip" "$(field "$J" build)" ""
run_in "$flat" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok "requirements.txt: the test is found and passes" || bad "requirements.txt: $(tail -3 "$scratch/run.log")"

# ── pytest: used when installed; kept when only pytest-style tests exist, so its absence is reported ──
tools="$scratch/tools"
executable "$tools/pytest"
J=$(detect_in "$plain" "$tools")
check "pytest on PATH wins over the unittest fallback" "$(field "$J" test)" "pytest"

pytest_only="$(new_fixture pytest_only)"
printf '[project]\nname = "pytest_only"\nversion = "0.1.0"\n' > "$pytest_only/pyproject.toml"
mkdir "$pytest_only/tests"
printf 'def test_greeting():\n    assert "hi" == "hi"\n' > "$pytest_only/tests/test_greeting.py"
J=$(detect_in "$pytest_only")
check "pytest-style tests without pytest: the command stays" "$(field "$J" test)" "pytest"
run_in "$pytest_only" "$(field "$J" test)" && bad "pytest-style tests without pytest passed unrun" || ok "pytest-style tests without pytest: the run fails instead of skipping them"

bare="$(new_fixture bare)"
printf '[project]\nname = "bare"\nversion = "0.1.0"\n' > "$bare/pyproject.toml"
J=$(detect_in "$bare")
check "no tests and no pytest: no test command" "$(field "$J" test)" ""

# Test files inside the engine's or a virtual environment's directories are not the project's.
mkdir -p "$bare/.evolve/scripts" "$bare/.venv/lib"
write_unittest "$bare/.evolve/scripts/test_engine.py"
write_unittest "$bare/.venv/lib/test_dependency.py"
J=$(detect_in "$bare")
check "engine and .venv test files do not count" "$(field "$J" test)" ""
rm -rf "$bare/.evolve" "$bare/.venv"

# ── A project .venv is preferred, so a scheduled run uses what an in-session run used ──
venv="$(new_fixture venv)"
printf '[project]\nname = "venv"\nversion = "0.1.0"\n' > "$venv/pyproject.toml"
write_unittest "$venv/tests/test_greeting.py"
PATH="$toolbox" python3 -m venv --without-pip "$venv/.venv"
J=$(detect_in "$venv")
check ".venv without pytest: unittest runs on its python" "$(field "$J" test)" ".venv/bin/python -m unittest discover -s tests"
check ".venv without pip: no build" "$(field "$J" build)" ""
run_in "$venv" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok ".venv: the test command runs on the .venv python" || bad ".venv: $(tail -3 "$scratch/run.log")"
executable "$venv/.venv/bin/pytest"
executable "$venv/.venv/bin/ruff"
executable "$venv/.venv/bin/pip"
J=$(detect_in "$venv")
check ".venv: test"   "$(field "$J" test)"   ".venv/bin/pytest"
check ".venv: build"  "$(field "$J" build)"  ".venv/bin/pip install -e ."
check ".venv: lint"   "$(field "$J" lint)"   ".venv/bin/ruff check --extend-exclude $ENGINE_EXCLUDES ."
check ".venv: format" "$(field "$J" format)" ".venv/bin/ruff format --check --extend-exclude $ENGINE_EXCLUDES ."
echo "requests" > "$venv/requirements.txt"; rm "$venv/pyproject.toml"
J=$(detect_in "$venv")
check ".venv + requirements.txt: build" "$(field "$J" build)" ".venv/bin/pip install -r requirements.txt"

# ── pip outside a virtual environment: only where this Python accepts installs (PEP 668) ──
executable "$tools/pip"
if PATH="$toolbox" python3 -c 'import os, sys, sysconfig; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")) else 1)'; then
    system_build=""
else
    system_build="pip install -e ."
fi
J=$(detect_in "$plain" "$tools")
check "system python: build matches whether it is externally managed" "$(field "$J" build)" "$system_build"
PATH="$toolbox" python3 -m venv --without-pip "$scratch/active"
J=$(detect_in "$plain" "$scratch/active/bin:$tools")
check "active virtual environment: pip install is returned" "$(field "$J" build)" "pip install -e ."

# ── Acceptance 2: ruff available + a fresh .evolve/ → lint and format pass with no project config ──
# The stand-in fails the way ruff does on main: when the engine's Python files are in scope.
executable "$tools/ruff" 'case "$*" in *"--extend-exclude '"$ENGINE_EXCLUDES"' ."*) exit 0 ;; esac
[ -d .evolve/scripts ] && { echo "would reformat: .evolve/scripts/format_issues.py" >&2; exit 1; }
exit 0'
linted="$(new_fixture linted)"
(
    cd "$linted"
    git init -q
    git config user.email test@example.com
    git config user.name test
    node "$CLI" init --agent claude </dev/null >/dev/null 2>&1
) || bad "init failed in the ruff fixture"
[ -f "$linted/.evolve/scripts/format_issues.py" ] && ok "ruff fixture: init installed the engine's Python scripts" || bad "ruff fixture: no engine scripts"
printf '[project]\nname = "linted"\nversion = "0.1.0"\n' > "$linted/pyproject.toml"
printf 'def greeting() -> str:\n    return "hi"\n' > "$linted/greeting.py"
J=$(detect_in "$linted" "$tools")
check "ruff: lint"   "$(field "$J" lint)"   "ruff check --extend-exclude $ENGINE_EXCLUDES ."
check "ruff: format" "$(field "$J" format)" "ruff format --check --extend-exclude $ENGINE_EXCLUDES ."
run_in "$linted" "$(field "$J" lint)" "$tools"   && ok "ruff: lint passes next to a fresh .evolve/"   || bad "ruff lint: $(tail -3 "$scratch/run.log")"
run_in "$linted" "$(field "$J" format)" "$tools" && ok "ruff: format passes next to a fresh .evolve/" || bad "ruff format: $(tail -3 "$scratch/run.log")"
if [ -n "$REAL_RUFF" ]; then
    real_ruff_dir="$(dirname "$REAL_RUFF")"
    run_in "$linted" "$(field "$J" lint) --isolated" "$real_ruff_dir"   && ok "real ruff: lint passes next to a fresh .evolve/"   || bad "real ruff lint: $(tail -5 "$scratch/run.log")"
    run_in "$linted" "$(field "$J" format) --isolated" "$real_ruff_dir" && ok "real ruff: format passes next to a fresh .evolve/" || bad "real ruff format: $(tail -5 "$scratch/run.log")"
    printf 'import os\nx=1\n' > "$linted/unformatted.py"
    run_in "$linted" "$(field "$J" lint) --isolated" "$real_ruff_dir"   && bad "real ruff: lint missed the project's own file"   || ok "real ruff: the project's own files are still linted"
    run_in "$linted" "$(field "$J" format) --isolated" "$real_ruff_dir" && bad "real ruff: format missed the project's own file" || ok "real ruff: the project's own files are still format-checked"
    rm "$linted/unformatted.py"
else
    echo "  (ruff is not installed: the real-ruff checks were not run)"
fi

# uv and poetry projects resolve tools themselves; their ruff commands get the same excludes.
executable "$tools/uv"
locked="$(new_fixture locked)"
: > "$locked/pyproject.toml"; : > "$locked/uv.lock"
J=$(detect_in "$locked" "$tools")
check "uv: lint"   "$(field "$J" lint)"   "uv run ruff check --extend-exclude $ENGINE_EXCLUDES ."
check "uv: format" "$(field "$J" format)" "uv run ruff format --check --extend-exclude $ENGINE_EXCLUDES ."
check "uv: test"   "$(field "$J" test)"   "uv run pytest"
rm "$locked/uv.lock"; : > "$locked/poetry.lock"
J=$(detect_in "$locked" "$tools")
check "poetry: lint"   "$(field "$J" lint)"   "poetry run ruff check --extend-exclude $ENGINE_EXCLUDES ."
check "poetry: format" "$(field "$J" format)" "poetry run ruff format --check --extend-exclude $ENGINE_EXCLUDES ."

# ── Deno also scans the tree (deno fmt covers Markdown and JSON, which the engine ships) ──
deno_dir="$(new_fixture deno)"
echo '{}' > "$deno_dir/deno.json"
J=$(detect_in "$deno_dir")
check "deno: lint"   "$(field "$J" lint)"   "deno lint --ignore=$ENGINE_EXCLUDES"
check "deno: format" "$(field "$J" format)" "deno fmt --check --ignore=$ENGINE_EXCLUDES"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
