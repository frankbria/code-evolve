#!/bin/bash
# Test (#133): a Python project is verified with tools that can actually run.
#   - pytest and ruff are only returned when installed (a project .venv first, then PATH);
#     unittest-style tests fall back to `python3 -m unittest discover`.
#   - `pip install` is not returned where pip would refuse it or is missing.
#   - ruff (and deno) leave the engine's own directories alone.
# The detected commands are run for real in the fixtures. Ruff is the real one when it is on
# PATH (CI installs it) next to a stand-in that fails the way ruff does on the engine's files.
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

# A PATH holding only what detection and the fixtures' own commands need, so pytest and ruff
# are absent whatever this machine has installed. Its python3 is a virtual environment
# without pip, so "pip cannot install" does not depend on this machine's Python either.
toolbox="$scratch/toolbox"
mkdir "$toolbox"
for tool in bash sh cat grep find wc basename dirname sed env; do
    ln -s "$(command -v "$tool")" "$toolbox/$tool"
done
SYSTEM_PYTHON="$(command -v python3)"
REAL_RUFF="$(command -v ruff || true)"
"$SYSTEM_PYTHON" -m venv --without-pip "$scratch/no-pip"
ln -s "$scratch/no-pip/bin/python3" "$toolbox/python3"

field() { echo "$1" | "$SYSTEM_PYTHON" -c "import sys,json; print(json.load(sys.stdin).get('$2',''))"; }
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

# A project that names pytest keeps it, whatever its test files look like: pytest may be
# configured to collect files this script would not recognise.
configured="$(new_fixture configured)"
printf '[project]\nname = "configured"\nversion = "0.1.0"\n\n[tool.pytest.ini_options]\npython_files = ["check_*.py"]\n' > "$configured/pyproject.toml"
printf 'def check_failure():\n    assert False\n' > "$configured/check_failure.py"
J=$(detect_in "$configured")
check "pytest configured in pyproject.toml keeps pytest" "$(field "$J" test)" "pytest"
write_unittest "$configured/tests/test_greeting.py"
J=$(detect_in "$configured")
check "pytest configured, TestCase tests present: still pytest" "$(field "$J" test)" "pytest"
declared="$(new_fixture declared)"
echo "pytest>=8" > "$declared/requirements-dev.txt"; echo "requests" > "$declared/requirements.txt"
J=$(detect_in "$declared")
check "pytest in a requirements file keeps pytest" "$(field "$J" test)" "pytest"
rm "$declared/requirements-dev.txt"; : > "$declared/conftest.py"
J=$(detect_in "$declared")
check "a conftest.py keeps pytest" "$(field "$J" test)" "pytest"

# Test files inside the engine's or a virtual environment's directories are not the project's.
mkdir -p "$bare/.evolve/scripts" "$bare/.venv/lib"
write_unittest "$bare/.evolve/scripts/test_engine.py"
write_unittest "$bare/.venv/lib/test_dependency.py"
J=$(detect_in "$bare")
check "engine and .venv test files do not count" "$(field "$J" test)" ""
rm -rf "$bare/.evolve" "$bare/.venv"

# unittest discovery would skip these, so they keep pytest and the missing tool is reported.
mocked="$(new_fixture mocked)"
printf '[project]\nname = "mocked"\nversion = "0.1.0"\n' > "$mocked/pyproject.toml"
mkdir "$mocked/tests"
printf 'from unittest.mock import Mock\n\n\ndef test_failure():\n    assert Mock() is None\n' > "$mocked/tests/test_mocked.py"
J=$(detect_in "$mocked")
check "pytest functions that import unittest.mock keep pytest" "$(field "$J" test)" "pytest"
write_unittest "$mocked/tests/test_greeting.py"
J=$(detect_in "$mocked")
check "TestCase classes next to pytest functions keep pytest" "$(field "$J" test)" "pytest"

suffixed="$(new_fixture suffixed)"
printf '[project]\nname = "suffixed"\nversion = "0.1.0"\n' > "$suffixed/pyproject.toml"
write_unittest "$suffixed/tests/greeting_test.py"
J=$(detect_in "$suffixed")
check "TestCase classes in *_test.py files keep pytest" "$(field "$J" test)" "pytest"
write_unittest "$suffixed/tests/test_greeting.py"
J=$(detect_in "$suffixed")
check "a *_test.py file next to a test_*.py TestCase keeps pytest" "$(field "$J" test)" "pytest"

# A tests/ folder that holds no tests does not become the start directory.
beside="$(new_fixture beside)"
printf '[project]\nname = "beside"\nversion = "0.1.0"\n' > "$beside/pyproject.toml"
write_unittest "$beside/test_greeting.py"
mkdir "$beside/tests"; echo "fixture data" > "$beside/tests/data.txt"
J=$(detect_in "$beside")
check "tests next to the code with a data-only tests/ folder" "$(field "$J" test)" "python3 -m unittest discover"
run_in "$beside" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok "tests next to the code: the test is found and passes" || bad "tests next to the code: $(tail -3 "$scratch/run.log")"

# Test files in folders discovery does not enter would be skipped, so those suites keep pytest.
nested="$(new_fixture nested)"
printf '[project]\nname = "nested"\nversion = "0.1.0"\n' > "$nested/pyproject.toml"
write_unittest "$nested/tests/test_greeting.py"
write_unittest "$nested/tests/unit/test_deeper.py"
J=$(detect_in "$nested")
check "a test folder discovery would not enter keeps pytest" "$(field "$J" test)" "pytest"
rm -rf "$nested/tests/unit"
write_unittest "$nested/test_beside.py"
J=$(detect_in "$nested")
check "tests both in a plain tests/ folder and beside the code keep pytest" "$(field "$J" test)" "pytest"
rm "$nested/test_beside.py"
J=$(detect_in "$nested")
check "the same project with every test in tests/ runs unittest" "$(field "$J" test)" "python3 -m unittest discover -s tests"

# pytest classes, and file names unittest cannot import, would be skipped the same way.
printf 'class TestRegression:\n    def test_failure(self):\n        assert False\n' >> "$nested/tests/test_greeting.py"
J=$(detect_in "$nested")
check "a pytest class next to a TestCase keeps pytest" "$(field "$J" test)" "pytest"
write_unittest "$nested/tests/test_greeting.py"
printf 'class TestCaseRegression:\n    def test_failure(self):\n        assert False\n' >> "$nested/tests/test_greeting.py"
J=$(detect_in "$nested")
check "a pytest class named like a TestCase keeps pytest" "$(field "$J" test)" "pytest"
dashed="$(new_fixture dashed)"
printf '[project]\nname = "dashed"\nversion = "0.1.0"\n' > "$dashed/pyproject.toml"
write_unittest "$dashed/tests/test-regression.py"
J=$(detect_in "$dashed")
check "a test file name unittest cannot import keeps pytest" "$(field "$J" test)" "pytest"

# ── A project .venv is preferred, so a scheduled run uses what an in-session run used ──
venv="$(new_fixture venv)"
printf '[project]\nname = "venv"\nversion = "0.1.0"\n' > "$venv/pyproject.toml"
write_unittest "$venv/tests/test_greeting.py"
"$SYSTEM_PYTHON" -m venv --without-pip "$venv/.venv"
J=$(detect_in "$venv")
check ".venv without pytest: unittest runs on its python" "$(field "$J" test)" ".venv/bin/python -m unittest discover -s tests"
check ".venv without pip: no build" "$(field "$J" build)" ""
run_in "$venv" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok ".venv: the test command runs on the .venv python" || bad ".venv: $(tail -3 "$scratch/run.log")"
executable "$tools/uv"
J=$(detect_in "$venv" "$tools")
check ".venv without pip, uv installed: uv installs into it" "$(field "$J" build)" "uv pip install --python .venv/bin/python -e ."
rm "$tools/uv"
executable "$venv/.venv/bin/pytest"
executable "$venv/.venv/bin/ruff"
J=$(detect_in "$venv")
check ".venv: test"   "$(field "$J" test)"   ".venv/bin/pytest"
check ".venv: lint"   "$(field "$J" lint)"   ".venv/bin/ruff check --extend-exclude $ENGINE_EXCLUDES ."
check ".venv: format" "$(field "$J" format)" ".venv/bin/ruff format --check --extend-exclude $ENGINE_EXCLUDES ."

# ── pip: only through an interpreter that has it and accepts installs (PEP 668) ──
# The checks that need pip borrow this machine's through --system-site-packages, so they
# only run where the system Python has pip.
system_python_dir="$scratch/system-python"
mkdir "$system_python_dir"
ln -s "$SYSTEM_PYTHON" "$system_python_dir/python3"
if "$SYSTEM_PYTHON" -m pip --version >/dev/null 2>&1; then
    if "$SYSTEM_PYTHON" -c 'import os, sys, sysconfig; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")) else 1)'; then
        J=$(detect_in "$plain" "$system_python_dir")
        check "externally managed system python: no build" "$(field "$J" build)" ""
    else
        echo "  (this Python is not externally managed: that check was not run)"
    fi

    "$SYSTEM_PYTHON" -m venv --without-pip --system-site-packages "$scratch/active"
    J=$(detect_in "$plain" "$scratch/active/bin")
    check "active virtual environment with pip: build" "$(field "$J" build)" "python3 -m pip install -e ."
    # A pip on PATH that belongs to another Python is not what the build would use.
    executable "$tools/pip"
    J=$(detect_in "$plain" "$tools")
    check "a pip on PATH next to a python3 without pip: no build" "$(field "$J" build)" ""
    rm "$tools/pip"

    rm -rf "$venv/.venv"
    "$SYSTEM_PYTHON" -m venv --without-pip --system-site-packages "$venv/.venv"
    J=$(detect_in "$venv")
    check ".venv with pip: build" "$(field "$J" build)" ".venv/bin/python -m pip install -e ."
    echo "requests" > "$venv/requirements.txt"; rm "$venv/pyproject.toml"
    J=$(detect_in "$venv")
    check ".venv with pip + requirements.txt: build" "$(field "$J" build)" ".venv/bin/python -m pip install -r requirements.txt"
else
    echo "  (this Python has no pip: the checks that need one were not run)"
fi

# ── Acceptance 2: ruff available + a fresh .evolve/ → lint and format pass with no project config ──
# The stand-in fails the way ruff does on main: when the engine's Python files are in scope.
executable "$tools/ruff" 'case "$*" in *"--extend-exclude '"$ENGINE_EXCLUDES"' ."*) exit 0 ;; esac
[ -d .evolve/scripts ] && { echo "would reformat: .evolve/scripts/format_issues.py" >&2; exit 1; }
exit 0'
linted="$(new_fixture linted)"
# init looks for the agent CLI; a stand-in keeps the test independent of an installed one.
executable "$scratch/agent/claude" '[ "${1:-}" = "--version" ] && echo "claude 0.0.0-stub"; exit 0'
(
    cd "$linted"
    PATH="$scratch/agent:$PATH"
    git init -q
    git config user.email test@example.com
    git config user.name test
    node "$CLI" init --agent claude </dev/null > "$scratch/init.log" 2>&1
) || bad "init failed in the ruff fixture: $(tail -3 "$scratch/init.log")"
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
elif [ -n "${CI:-}" ]; then
    bad "ruff is not installed in CI: the real-ruff checks did not run"
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
