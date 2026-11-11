#!/bin/bash
# Test (#133): a Python project is verified with tools that can actually run.
#   - pytest and ruff are only returned when installed (a project .venv first, then PATH);
#     unittest-style tests fall back to `python3 -m unittest discover`.
#   - `pip install` is not returned where pip would refuse it or is missing.
#   - ruff (and deno) leave the engine's own directories alone.
# (#143): test files are classified by parsing them, nested test packages run through unittest,
# a project .venv never borrows a pytest from PATH, and uv/poetry only run a tool their lock names.
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
for tool in bash sh cat grep find basename dirname sed env; do
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
# With __init__.py all the way down, discovery enters it (#143).
: > "$nested/tests/unit/__init__.py"
J=$(detect_in "$nested")
check "a nested package under a plain tests/ folder runs unittest" "$(field "$J" test)" "python3 -m unittest discover -s tests"
run_in "$nested" "$(field "$J" test)" && grep -q "Ran 2 tests" "$scratch/run.log" \
    && ok "nested package under tests/: both tests are found and pass" || bad "nested package under tests/: $(tail -3 "$scratch/run.log")"
: > "$nested/tests/__init__.py"
J=$(detect_in "$nested")
check "nested test packages run unittest from the project root" "$(field "$J" test)" "python3 -m unittest discover"
run_in "$nested" "$(field "$J" test)" && grep -q "Ran 2 tests" "$scratch/run.log" \
    && ok "nested test packages: both tests are found and pass" || bad "nested test packages: $(tail -3 "$scratch/run.log")"
printf 'def load_tests(loader, tests, pattern):\n    return tests\n' > "$nested/tests/unit/__init__.py"
J=$(detect_in "$nested")
check "a package whose load_tests hook replaces discovery keeps pytest" "$(field "$J" test)" "pytest"
rm "$nested/tests/unit/__init__.py"
J=$(detect_in "$nested")
check "a package chain with a gap keeps pytest" "$(field "$J" test)" "pytest"
rm -rf "$nested/tests/unit" "$nested/tests/__init__.py"
mkdir "$nested/moved"; mv "$nested/tests/test_greeting.py" "$nested/moved/"
mkdir "$nested/tests/unit"; : > "$nested/tests/unit/__init__.py"; mv "$nested/moved/test_greeting.py" "$nested/tests/unit/"; rmdir "$nested/moved"
J=$(detect_in "$nested")
check "a plain tests/ folder holding only test packages is the start" "$(field "$J" test)" "python3 -m unittest discover -s tests"
run_in "$nested" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok "tests/ holding only packages: the test is found and passes" || bad "tests/ holding only packages: $(tail -3 "$scratch/run.log")"
mv "$nested/tests/unit/test_greeting.py" "$nested/tests/"; rm -rf "$nested/tests/unit"
in_app="$(new_fixture in_app)"
printf '[project]\nname = "in_app"\nversion = "0.1.0"\n' > "$in_app/pyproject.toml"
write_unittest "$in_app/app/tests/test_greeting.py"
: > "$in_app/app/__init__.py"; : > "$in_app/app/tests/__init__.py"
J=$(detect_in "$in_app")
check "tests in a package inside the code's package run unittest" "$(field "$J" test)" "python3 -m unittest discover"
run_in "$in_app" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok "app/tests/: the test is found and passes" || bad "app/tests/: $(tail -3 "$scratch/run.log")"
mv "$in_app/app" "$in_app/my-app"
J=$(detect_in "$in_app")
check "a package directory unittest cannot import keeps pytest" "$(field "$J" test)" "pytest"
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
write_unittest "$nested/tests/test_greeting.py"
printf '\nif True:\n    def test_conditional():\n        assert False\n' >> "$nested/tests/test_greeting.py"
J=$(detect_in "$nested")
check "a pytest function defined under a condition keeps pytest" "$(field "$J" test)" "pytest"
# Enough classes after the pytest one to fill a pipe: the scan must not lose the hit.
printf 'class TestRegression:\n    def test_failure(self):\n        assert False\n' > "$nested/tests/test_greeting.py"
for number in $(seq 1 3000); do
    printf 'class Generated%sTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertTrue(True)\n' "$number"
done >> "$nested/tests/test_greeting.py"
J=$(detect_in "$nested")
check "a pytest class ahead of thousands of TestCase classes keeps pytest" "$(field "$J" test)" "pytest"
printf 'from helpers import TestCaseMixin\n\n\nclass TestRegression(TestCaseMixin):\n    def test_failure(self):\n        assert False\n' > "$nested/tests/test_greeting.py"
J=$(detect_in "$nested")
check "a base class that only contains the word TestCase keeps pytest" "$(field "$J" test)" "pytest"
printf 'import unittest\n\n\nclass AsyncGreetingTest(unittest.IsolatedAsyncioTestCase):\n    async def test_greeting(self):\n        self.assertEqual("hi", "hi")\n' > "$nested/tests/test_greeting.py"
J=$(detect_in "$nested")
check "an IsolatedAsyncioTestCase suite runs unittest" "$(field "$J" test)" "python3 -m unittest discover -s tests"
run_in "$nested" "$(field "$J" test)" && grep -q "Ran 1 test" "$scratch/run.log" \
    && ok "an IsolatedAsyncioTestCase suite: the test is found and passes" || bad "async suite: $(tail -3 "$scratch/run.log")"

# Cases a line pattern gets wrong; the files are parsed instead (#143).
parsed="$(new_fixture parsed)"
printf '[project]\nname = "parsed"\nversion = "0.1.0"\n' > "$parsed/pyproject.toml"
# parsed_as <label> <want> <second test file's content>  → detection with that file next to a TestCase
parsed_as() {
    write_unittest "$parsed/tests/test_greeting.py"
    printf '%b' "$3" > "$parsed/tests/test_other.py"
    check "$1" "$(field "$(detect_in "$parsed")" test)" "$2"
}
UNITTEST="python3 -m unittest discover -s tests"
parsed_as "a pytest function with a space before its parenthesis keeps pytest" "pytest" \
    'def test_failure ():\n    assert False\n'
parsed_as "a pytest function whose signature spans lines keeps pytest" "pytest" \
    'def test_failure(\n):\n    assert False\n'
parsed_as "an async pytest function inside try keeps pytest" "pytest" \
    'try:\n    import fast\nexcept ImportError:\n    async def test_failure():\n        assert False\n'
parsed_as "a pytest function whose first parameter is named self keeps pytest" "pytest" \
    'def test_failure(self=None):\n    assert False\n'
parsed_as "a Test class on a project class named TestCase keeps pytest" "pytest" \
    'from unittest import TestCase\n\n\nclass TestCase:\n    pass\n\n\nclass TestRegression(TestCase):\n    def test_failure(self):\n        assert False\n'
parsed_as "a Test class on a TestCase name that was assigned something else keeps pytest" "pytest" \
    'from unittest import TestCase as Base\n\nBase = object\n\n\nclass TestRegression(Base):\n    def test_failure(self):\n        assert False\n'
parsed_as "a TestCase name bound to something else in another branch keeps pytest" "pytest" \
    'import sys\n\nif sys.argv:\n    Base = object\nelse:\n    from unittest import TestCase as Base\n\n\nclass TestRegression(Base):\n    def test_failure(self):\n        assert False\n'
parsed_as "a function assigned to a test name in a Test class keeps pytest" "pytest" \
    'def failure(self):\n    assert False\n\n\nclass TestRegression:\n    test_failure = failure\n'
parsed_as "a load_tests hook in a test file keeps pytest" "pytest" \
    'import unittest\n\n\nclass SkippedTest(unittest.TestCase):\n    def test_failure(self):\n        self.fail()\n\n\ndef load_tests(loader, tests, pattern):\n    return unittest.TestSuite()\n'
parsed_as "a pytest class nested in a Test class keeps pytest" "pytest" \
    'class TestOuter:\n    class TestInner:\n        def test_failure(self):\n            assert False\n'
parsed_as "a Test class that inherits its test from a plain class keeps pytest" "pytest" \
    'class Checks:\n    def test_failure(self):\n        assert False\n\n\nclass Shared(Checks):\n    pass\n\n\nclass TestRegression(Shared):\n    pass\n'
parsed_as "a Test class on a base from another module keeps pytest" "pytest" \
    'from checks import Checks\n\n\nclass TestRegression(Checks):\n    pass\n'
parsed_as "a test function imported into a TestCase file keeps pytest" "pytest" \
    'import unittest\n\nfrom helpers import test_shared\n\n\nclass OtherTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "a Test class imported into a TestCase file keeps pytest" "pytest" \
    'import unittest\n\nfrom checks import TestShared\n\n\nclass OtherTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertTrue(TestShared)\n'
printf 'def test_shared():\n    assert False\n' > "$parsed/tests/checks.py"
printf 'def greeting():\n    return "hi"\n' > "$parsed/tests/helpers.py"
parsed_as "a star import of a project file that holds a test function keeps pytest" "pytest" \
    'import unittest\n\nfrom checks import *\n\n\nclass OtherTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "a class made by a call and assigned to a Test name keeps pytest" "pytest" \
    'import unittest\n\nTestGenerated = type("TestGenerated", (), {"test_failure": lambda self: 1 / 0})\n\n\nclass OtherTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "a TestCase file that imports pytest keeps pytest" "pytest" \
    'import unittest\n\nimport pytest\n\n\nclass MarkedTest(unittest.TestCase):\n    @pytest.mark.slow\n    def test_marked(self):\n        pass\n'
parsed_as "a test file this Python cannot parse keeps pytest" "pytest" \
    'def test_failure(:\n'
parsed_as "TestCase imported under another name runs unittest" "$UNITTEST" \
    'from unittest import TestCase as Base\n\n\nclass TestAliased(Base):\n    def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "a Test class on a TestCase of the same file runs unittest" "$UNITTEST" \
    'import unittest as ut\n\n\nclass Shared(ut.TestCase):\n    pass\n\n\nclass TestDerived(Shared):\n    def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "a TestCase named through unittest.case runs unittest" "$UNITTEST" \
    'import unittest\n\n\nclass TestLong(unittest.case.TestCase):\n    def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "unittest imported twice, with unittest.mock and in try/except, runs unittest" "$UNITTEST" \
    'import unittest\nimport unittest.mock\n\ntry:\n    from unittest import IsolatedAsyncioTestCase\nexcept ImportError:\n    from unittest import IsolatedAsyncioTestCase\n\n\nclass TestMocked(unittest.TestCase):\n    def test_passes(self):\n        self.assertTrue(unittest.mock.Mock())\n\n\nclass TestAsync(IsolatedAsyncioTestCase):\n    async def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "setting an attribute of unittest.TestCase does not rebind unittest" "$UNITTEST" \
    'import unittest\n\nunittest.TestCase.maxDiff = None\nsettings = {}\nsettings[unittest] = 1\n\n\nclass TestLong(unittest.TestCase):\n    def test_passes(self):\n        self.assertTrue(True)\n'
parsed_as "star imports of project code and of installed modules run unittest" "$UNITTEST" \
    'import unittest\n\nfrom helpers import *\nfrom os.path import *\n\n\nclass StarTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertEqual(greeting(), "hi")\n'
parsed_as "a mixin holding the tests of a TestCase runs unittest" "$UNITTEST" \
    'import unittest\n\n\nclass GreetingChecks:\n    def test_passes(self):\n        self.assertTrue(True)\n\n\nclass MixedTest(GreetingChecks, unittest.TestCase):\n    pass\n'
parsed_as "a Test-named helper class with no test in it or its bases runs unittest" "$UNITTEST" \
    'import unittest\n\n\nclass Settings(object):\n    name = "hi"\n\n\nclass TestSettings(Settings):\n    def build(self):\n        return self.name\n\n\nclass SettingsTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertEqual(TestSettings().build(), "hi")\n'
parsed_as "test data and helpers named test* inside functions run unittest" "$UNITTEST" \
    'import unittest\n\ntest_cases = ["hi"]\n\n\ndef build():\n    def test_inner():\n        return 1\n    return test_inner\n\n\nclass DataTest(unittest.TestCase):\n    def test_passes(self):\n        self.assertEqual(build()(), len(test_cases))\n'
run_in "$parsed" "$UNITTEST" && grep -q "Ran 2 tests" "$scratch/run.log" \
    && ok "parsed suite: the detected command runs both files and passes" || bad "parsed suite: $(tail -3 "$scratch/run.log")"
rm "$parsed/tests/test_other.py"
mkdir -p "$parsed/tests/unit"; : > "$parsed/tests/unit/__init__.py"; : > "$parsed/tests/unit/conftest.py"
check "a conftest.py in a nested test package keeps pytest" "$(field "$(detect_in "$parsed")" test)" "pytest"
rm -rf "$parsed/tests/unit"
write_unittest "$parsed/tests/test_greeting_test.py"
check "a file discovery loads, though named *_test.py too, runs unittest" "$(field "$(detect_in "$parsed")" test)" "$UNITTEST"

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
# A pytest on PATH runs on another interpreter, so a .venv without pytest does not use it (#143).
J=$(detect_in "$venv" "$tools")
check ".venv without pytest, pytest on PATH: unittest still runs on the .venv python" "$(field "$J" test)" ".venv/bin/python -m unittest discover -s tests"
printf 'def test_greeting():\n    assert "hi" == "hi"\n' > "$venv/tests/test_function.py"
J=$(detect_in "$venv" "$tools")
check ".venv without pytest, pytest-style tests: pytest is asked of the .venv python" "$(field "$J" test)" ".venv/bin/python -m pytest"
run_in "$venv" "$(field "$J" test)" "$tools" && bad ".venv without pytest: the PATH pytest ran instead" \
    || { grep -q "No module named pytest" "$scratch/run.log" && ok ".venv without pytest: the run reports the missing module" || bad ".venv without pytest: $(tail -3 "$scratch/run.log")"; }
rm "$venv/tests/test_function.py"
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
# init looks for the agent CLI; a stand-in keeps the test independent of an installed one.
executable "$scratch/agent/claude" '[ "${1:-}" = "--version" ] && echo "claude 0.0.0-stub"; exit 0'
# install_engine <dir>  → a fresh `code-evolve init` in that project directory
install_engine() {
    (
        cd "$1"
        PATH="$scratch/agent:$PATH"
        git init -q
        git config user.email test@example.com
        git config user.name test
        node "$CLI" init --agent claude </dev/null > "$scratch/init.log" 2>&1
    ) || bad "init failed in $(basename "$1"): $(tail -3 "$scratch/init.log")"
}
linted="$(new_fixture linted)"
install_engine "$linted"
[ -f "$linted/.evolve/scripts/format_issues.py" ] && ok "ruff fixture: init installed the engine's Python scripts" || bad "ruff fixture: no engine scripts"
# deno fmt wraps Markdown at 80 columns and reads the project's AGENTS.md (checked here too,
# because the real-deno checks below only run where deno is installed).
[ -s "$linted/AGENTS.md" ] && [ -z "$(awk 'length > 80' "$linted/AGENTS.md")" ] \
    && ok "the section init writes into AGENTS.md stays within 80 columns" || bad "AGENTS.md has a line over 80 columns"
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

# uv and poetry projects run the tools their lock file names; ruff gets the same excludes.
executable "$tools/uv"
locked="$(new_fixture locked)"
: > "$locked/pyproject.toml"; printf '[[package]]\nname = "%s"\nversion = "1.0.0"\n\n' pytest ruff > "$locked/uv.lock"
J=$(detect_in "$locked" "$tools")
check "uv: lint"   "$(field "$J" lint)"   "uv run ruff check --extend-exclude $ENGINE_EXCLUDES ."
check "uv: format" "$(field "$J" format)" "uv run ruff format --check --extend-exclude $ENGINE_EXCLUDES ."
check "uv: test"   "$(field "$J" test)"   "uv run pytest"
mv "$locked/uv.lock" "$locked/poetry.lock"
J=$(detect_in "$locked" "$tools")
check "poetry: lint"   "$(field "$J" lint)"   "poetry run ruff check --extend-exclude $ENGINE_EXCLUDES ."
check "poetry: format" "$(field "$J" format)" "poetry run ruff format --check --extend-exclude $ENGINE_EXCLUDES ."
check "poetry: test"   "$(field "$J" test)"   "poetry run pytest"

# A tool the lock does not name is not in the project's environment (#143): the runner would
# borrow one from PATH or fail. Tests fall back as for any Python project; ruff comes from PATH.
printf '[[package]]\nname = "%s"\nversion = "1.0.0"\n\n' pytest-cov ruff-lsp > "$locked/poetry.lock"
uv_only="$scratch/uv-only"
executable "$uv_only/uv"
J=$(detect_in "$locked" "$uv_only")
check "poetry, lock without pytest, no tests: no test command" "$(field "$J" test)" ""
check "poetry, lock without ruff, none installed: no lint"     "$(field "$J" lint)" ""
check "poetry, lock without ruff, none installed: no format"   "$(field "$J" format)" ""
J=$(detect_in "$locked" "$tools")
check "poetry, lock without ruff, ruff on PATH: lint" "$(field "$J" lint)" "ruff check --extend-exclude $ENGINE_EXCLUDES ."
write_unittest "$locked/tests/test_greeting.py"
J=$(detect_in "$locked" "$tools")
check "poetry, lock without pytest, unittest suite" "$(field "$J" test)" "poetry run python -m unittest discover -s tests"
mv "$locked/poetry.lock" "$locked/uv.lock"
J=$(detect_in "$locked" "$tools")
check "uv, lock without pytest, unittest suite: not the pytest on PATH" "$(field "$J" test)" "uv run python -m unittest discover -s tests"
check "uv, lock without pytest: build is unchanged" "$(field "$J" build)" "uv sync"
printf 'def test_greeting():\n    assert "hi" == "hi"\n' > "$locked/tests/test_function.py"
J=$(detect_in "$locked" "$tools")
check "uv, lock without pytest, pytest-style tests: the command stays" "$(field "$J" test)" "uv run pytest"
printf '[tool.pytest.ini_options]\n' > "$locked/pyproject.toml"; rm "$locked/tests/test_function.py"
J=$(detect_in "$locked" "$tools")
check "uv, lock without pytest, pytest configured: the command stays" "$(field "$J" test)" "uv run pytest"

# ── Deno also scans the tree (deno fmt covers Markdown and JSON, which the engine ships) ──
deno_dir="$(new_fixture deno)"
echo '{}' > "$deno_dir/deno.json"
J=$(detect_in "$deno_dir")
check "deno: lint"   "$(field "$J" lint)"   "deno lint --ignore=$ENGINE_EXCLUDES"
check "deno: format" "$(field "$J" format)" "deno fmt --check --ignore=$ENGINE_EXCLUDES"
# The same commands with the real deno next to a fresh .evolve/ (#143; CI installs deno).
REAL_DENO="$(command -v deno || true)"
if [ -n "$REAL_DENO" ]; then
    real_deno_dir="$(dirname "$REAL_DENO")"
    denoed="$(new_fixture denoed)"
    install_engine "$denoed"
    echo '{}' > "$denoed/deno.json"
    printf 'export function greeting(): string {\n  return "hi";\n}\n' > "$denoed/greeting.ts"
    J=$(detect_in "$denoed")
    run_in "$denoed" "$(field "$J" lint)" "$real_deno_dir"   && ok "real deno: lint passes next to a fresh .evolve/"   || bad "real deno lint: $(tail -8 "$scratch/run.log")"
    run_in "$denoed" "$(field "$J" format)" "$real_deno_dir" && ok "real deno: format passes next to a fresh .evolve/" || bad "real deno format: $(tail -8 "$scratch/run.log")"
    printf 'var unused=1\n' > "$denoed/unformatted.ts"
    run_in "$denoed" "$(field "$J" lint)" "$real_deno_dir"   && bad "real deno: lint missed the project's own file"   || ok "real deno: the project's own files are still linted"
    run_in "$denoed" "$(field "$J" format)" "$real_deno_dir" && bad "real deno: format missed the project's own file" || ok "real deno: the project's own files are still format-checked"
elif [ -n "${CI:-}" ]; then
    bad "deno is not installed in CI: the real-deno checks did not run"
else
    echo "  (deno is not installed: the real-deno checks were not run)"
fi

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
