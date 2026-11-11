#!/bin/bash
# scripts/detect_stack.sh — Detect project stack and output build/test/lint commands as JSON.
# Called by evolve.sh to adapt verification to whatever the project is using.
#
# Usage: ./scripts/detect_stack.sh [project_dir]
# Output: JSON with build, test, lint, format commands (or empty strings if not applicable)
#
# Supports nested layouts: if no stack marker at root, scans immediate subdirectories.
# When any are found, outputs {"stack":"monorepo","substacks":[...]}; each substack's
# commands run in its "dir".

set -euo pipefail

PROJECT_DIR="${1:-.}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Directories the engine and the agent CLIs own. A linter or formatter that scans the whole
# tree must not judge them: the project cannot fix those files (they are protected).
ENGINE_DIRS=".evolve,.claude,.agents"
RUFF_SCOPE="--extend-exclude $ENGINE_DIRS ."

# python_tool <dir> <tool> — the project's .venv copy when there is one (so a scheduled run
# uses what an in-session run used), else the one on PATH, else nothing.
python_tool() {
    if [ -x "$1/.venv/bin/$2" ]; then
        echo ".venv/bin/$2"
    elif command -v "$2" >/dev/null 2>&1; then
        echo "$2"
    fi
}

# Directories that hold no project tests: the engine, agent CLIs, and installed packages.
PYTHON_SKIPPED_DIRS=(.git .evolve .claude .agents .venv venv node_modules)

# python_has_test_files <dir> — true when the project has a file pytest collects by its name.
python_has_test_files() {
    local prunes=() name
    for name in "${PYTHON_SKIPPED_DIRS[@]}"; do prunes+=(-name "$name" -o); done
    [ -n "$(cd "$1" && find . \( "${prunes[@]}" -false \) -prune -o -type f \( -name 'test*.py' -o -name '*_test.py' \) -print -quit 2>/dev/null)" ]
}

# python_unittest_command <dir> <python command> — prints the unittest command when it runs the
# whole suite, nothing otherwise. unittest_suite.py decides, by parsing the test files; it runs
# on an interpreter that exists now, which <python command> (`uv run python`) may not yet be.
python_unittest_command() {
    local dir="$1" interpreter="python3" arguments
    [ -x "$dir/.venv/bin/python" ] && interpreter="$dir/.venv/bin/python"
    arguments=$("$interpreter" -I "$SCRIPTS_DIR/unittest_suite.py" "$dir" "${PYTHON_SKIPPED_DIRS[@]}" 2>/dev/null) || return 0
    [ -z "$arguments" ] || echo "$2 -m unittest $arguments"
}

# python_declares_pytest <dir> — true when the project's own files name pytest (a dependency,
# its configuration, a conftest). Such a suite may be collected in ways only pytest knows.
python_declares_pytest() {
    [ -f "$1/pytest.ini" ] || [ -f "$1/conftest.py" ] || [ -f "$1/tests/conftest.py" ] \
        || grep -qs pytest "$1/pyproject.toml" "$1"/requirements*.txt "$1/setup.cfg" "$1/tox.ini"
}

# python_can_install <python> — true when that interpreter has pip and accepts installs.
# PEP 668: outside a virtual environment, a distribution-owned Python refuses them.
python_can_install() {
    "$1" -m pip --version >/dev/null 2>&1 || return 1
    "$1" -c 'import os, sys, sysconfig
marker = os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")
sys.exit(1 if sys.prefix == sys.base_prefix and os.path.exists(marker) else 0)' 2>/dev/null
}

# python_test_command <dir> <pytest command, empty when pytest is not installed>
#                     <pytest command that reports it as missing> <python command>
python_test_command() {
    local dir="$1" installed_pytest="$2" missing_pytest="$3" python="$4" unittest
    if [ -n "$installed_pytest" ]; then
        echo "$installed_pytest"
    elif python_declares_pytest "$dir"; then
        # Keep the command so the missing tool is reported instead of the tests being skipped.
        echo "$missing_pytest"
    else
        unittest=$(python_unittest_command "$dir" "$python")
        if [ -n "$unittest" ]; then
            echo "$unittest"
        elif python_has_test_files "$dir"; then
            echo "$missing_pytest"
        fi
    fi
}

# python_ruff_commands <ruff command, empty when ruff is not installed>
python_ruff_commands() {
    [ -n "$1" ] || return 0
    LINT_CMD="$1 check $RUFF_SCOPE"
    FORMAT_CMD="$1 format --check $RUFF_SCOPE"
}

# python_commands <dir> <pip install arguments> — for projects without a uv or poetry lock.
# Sets BUILD_CMD, TEST_CMD, LINT_CMD, FORMAT_CMD to commands whose tools can run here.
python_commands() {
    local dir="$1" install_arguments="$2" pytest=""
    if [ -x "$dir/.venv/bin/python" ]; then
        if python_can_install "$dir/.venv/bin/python"; then
            BUILD_CMD=".venv/bin/python -m pip install $install_arguments"
        elif command -v uv >/dev/null 2>&1; then
            # A .venv made by uv has no pip of its own.
            BUILD_CMD="uv pip install --python .venv/bin/python $install_arguments"
        fi
        # A pytest on PATH runs on another interpreter and may not see the .venv's packages.
        [ -x "$dir/.venv/bin/pytest" ] && pytest=".venv/bin/pytest"
        TEST_CMD=$(python_test_command "$dir" "$pytest" ".venv/bin/python -m pytest" ".venv/bin/python")
    else
        if python_can_install python3; then
            BUILD_CMD="python3 -m pip install $install_arguments"
        fi
        command -v pytest >/dev/null 2>&1 && pytest="pytest"
        TEST_CMD=$(python_test_command "$dir" "$pytest" "pytest" "python3")
    fi
    python_ruff_commands "$(python_tool "$dir" ruff)"
}

# python_locked_commands <dir> <runner> <lock file> — for uv and poetry projects. The runner
# only finds a tool the lock file names, so the others are chosen as for any Python project.
python_locked_commands() {
    local dir="$1" runner="$2" lock="$1/$3" pytest="" ruff
    grep -qx 'name = "pytest"' "$lock" && pytest="$runner pytest"
    TEST_CMD=$(python_test_command "$dir" "$pytest" "$runner pytest" "$runner python")
    if grep -qx 'name = "ruff"' "$lock"; then
        ruff="$runner ruff"
    else
        ruff=$(python_tool "$dir" ruff)
    fi
    python_ruff_commands "$ruff"
}

# ── detect_single_stack(dir) ──
# Sets: STACK, BUILD_CMD, TEST_CMD, LINT_CMD, FORMAT_CMD
detect_single_stack() {
    local dir="$1"
    STACK="unknown"
    BUILD_CMD=""
    TEST_CMD=""
    LINT_CMD=""
    FORMAT_CMD=""

    if [ -f "$dir/Cargo.toml" ]; then
        STACK="rust"
        BUILD_CMD="cargo build"
        TEST_CMD="cargo test"
        LINT_CMD="cargo clippy --all-targets -- -D warnings"
        FORMAT_CMD="cargo fmt -- --check"

    elif [ -f "$dir/deno.json" ] || [ -f "$dir/deno.jsonc" ]; then
        # Checked before package.json: Deno projects may ship one for npm compat.
        STACK="deno"
        BUILD_CMD=""
        TEST_CMD="deno test"
        # deno fmt also covers Markdown and JSON, which the engine ships.
        LINT_CMD="deno lint --ignore=$ENGINE_DIRS"
        FORMAT_CMD="deno fmt --check --ignore=$ENGINE_DIRS"

    elif [ -f "$dir/package.json" ]; then
        # Detect package manager
        local PKG_MGR="npm"
        if [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
            PKG_MGR="bun"
        elif [ -f "$dir/pnpm-lock.yaml" ]; then
            PKG_MGR="pnpm"
        elif [ -f "$dir/yarn.lock" ]; then
            PKG_MGR="yarn"
        fi

        # Check for TypeScript
        if [ -f "$dir/tsconfig.json" ]; then
            STACK="typescript"
            BUILD_CMD="$PKG_MGR run build"
            TEST_CMD="$PKG_MGR run test"
            LINT_CMD="$PKG_MGR run lint"
            FORMAT_CMD=""
        else
            STACK="javascript"
            BUILD_CMD="$PKG_MGR run build"
            TEST_CMD="$PKG_MGR run test"
            LINT_CMD="$PKG_MGR run lint"
            FORMAT_CMD=""
        fi

        # Check for Next.js specifically
        if grep -q '"next"' "$dir/package.json" 2>/dev/null; then
            STACK="nextjs"
            BUILD_CMD="$PKG_MGR run build"
        fi

        # Verify that build/test/lint scripts actually exist in package.json
        if [ -n "$BUILD_CMD" ] && ! grep -q '"build"' "$dir/package.json" 2>/dev/null; then
            BUILD_CMD=""
        fi
        if [ -n "$TEST_CMD" ] && ! grep -q '"test"' "$dir/package.json" 2>/dev/null; then
            TEST_CMD=""
        fi
        if [ -n "$LINT_CMD" ] && ! grep -q '"lint"' "$dir/package.json" 2>/dev/null; then
            LINT_CMD=""
        fi

    elif [ -f "$dir/pyproject.toml" ]; then
        STACK="python"
        if command -v uv &>/dev/null && [ -f "$dir/uv.lock" ]; then
            BUILD_CMD="uv sync"
            python_locked_commands "$dir" "uv run" uv.lock
        elif [ -f "$dir/poetry.lock" ]; then
            BUILD_CMD="poetry install"
            python_locked_commands "$dir" "poetry run" poetry.lock
        else
            python_commands "$dir" "-e ."
        fi

    elif [ -f "$dir/requirements.txt" ]; then
        STACK="python"
        python_commands "$dir" "-r requirements.txt"
        FORMAT_CMD=""

    elif [ -f "$dir/go.mod" ]; then
        STACK="go"
        BUILD_CMD="go build ./..."
        TEST_CMD="go test ./..."
        LINT_CMD="go vet ./..."
        FORMAT_CMD="gofmt -l ."

    elif [ -f "$dir/pom.xml" ]; then
        STACK="java"
        BUILD_CMD="mvn compile"
        TEST_CMD="mvn test"
        LINT_CMD=""
        FORMAT_CMD=""

    elif [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ] || \
         [ -f "$dir/settings.gradle" ] || [ -f "$dir/settings.gradle.kts" ]; then
        STACK="java"
        # Prefer the project's wrapper for a pinned Gradle version.
        local GRADLE="gradle"
        [ -f "$dir/gradlew" ] && GRADLE="./gradlew"
        BUILD_CMD="$GRADLE build"
        TEST_CMD="$GRADLE test"
        LINT_CMD=""
        FORMAT_CMD=""

    elif compgen -G "$dir/*.sln" >/dev/null || compgen -G "$dir/*.csproj" >/dev/null; then
        STACK="dotnet"
        BUILD_CMD="dotnet build"
        TEST_CMD="dotnet test"
        LINT_CMD=""
        FORMAT_CMD="dotnet format --verify-no-changes"

    elif [ -f "$dir/Gemfile" ]; then
        STACK="ruby"
        BUILD_CMD="bundle install"
        if grep -q "rspec" "$dir/Gemfile" 2>/dev/null; then
            TEST_CMD="bundle exec rspec"
        else
            TEST_CMD="bundle exec rake"
        fi
        if grep -q "rubocop" "$dir/Gemfile" 2>/dev/null; then
            LINT_CMD="bundle exec rubocop"
        else
            LINT_CMD=""
        fi
        FORMAT_CMD=""

    elif [ -f "$dir/composer.json" ]; then
        STACK="php"
        BUILD_CMD="composer install"
        if grep -q '"test"' "$dir/composer.json" 2>/dev/null; then
            TEST_CMD="composer test"
        else
            TEST_CMD="vendor/bin/phpunit"
        fi
        LINT_CMD=""
        FORMAT_CMD=""

    elif [ -f "$dir/CMakeLists.txt" ]; then
        # Checked before Makefile: CMake projects often ship a generated Makefile too.
        STACK="cpp"
        BUILD_CMD="cmake -S . -B build && cmake --build build"
        TEST_CMD="ctest --test-dir build"
        LINT_CMD=""
        FORMAT_CMD=""

    elif [ -f "$dir/Makefile" ]; then
        STACK="make"
        BUILD_CMD="make"
        TEST_CMD="make test"
        LINT_CMD=""
        FORMAT_CMD=""

    elif [ -f "$dir/index.html" ]; then
        # Weakest signal — last resort before "unknown". Static site: no build/test.
        STACK="static"
        BUILD_CMD=""
        TEST_CMD=""
        LINT_CMD=""
        FORMAT_CMD=""
    fi
}

# ── Main detection ──

# Try root directory first
detect_single_stack "$PROJECT_DIR"

# If unknown, scan immediate subdirectories for monorepo layout
if [ "$STACK" = "unknown" ]; then
    SUBSTACKS=""
    SUBSTACK_COUNT=0

    for subdir in "$PROJECT_DIR"/*/; do
        [ -d "$subdir" ] || continue
        SUBDIR_NAME=$(basename "$subdir")
        # The name goes into the JSON unescaped; one that would break it is not worth losing
        # the whole detection over.
        case "$SUBDIR_NAME" in *'"'*|*'\'*|*[[:cntrl:]]*) continue ;; esac
        detect_single_stack "$subdir"
        if [ "$STACK" != "unknown" ]; then
            [ "$SUBSTACK_COUNT" -gt 0 ] && SUBSTACKS="$SUBSTACKS,"
            SUBSTACKS="$SUBSTACKS{\"name\":\"$SUBDIR_NAME\",\"dir\":\"$SUBDIR_NAME\",\"stack\":\"$STACK\",\"build\":\"$BUILD_CMD\",\"test\":\"$TEST_CMD\",\"lint\":\"$LINT_CMD\",\"format\":\"$FORMAT_CMD\"}"
            SUBSTACK_COUNT=$((SUBSTACK_COUNT + 1))
        fi
    done

    if [ "$SUBSTACK_COUNT" -ge 1 ]; then
        # One nested project is reported the same way as several: only a substack entry
        # carries the directory its commands must run in.
        cat <<EOF
{
  "stack": "monorepo",
  "substacks": [$SUBSTACKS],
  "build": "",
  "test": "",
  "lint": "",
  "format": ""
}
EOF
        exit 0
    fi
    # If 0 substacks, STACK remains "unknown" — fall through to single output
fi

# Single-stack output (or unknown)
cat <<EOF
{
  "stack": "$STACK",
  "build": "$BUILD_CMD",
  "test": "$TEST_CMD",
  "lint": "$LINT_CMD",
  "format": "$FORMAT_CMD"
}
EOF
