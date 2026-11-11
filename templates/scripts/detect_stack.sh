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

# python_test_files <dir> [pattern] — true when the project has a test file (matching pattern).
# Searched from inside the project: grep would skip a project directory itself named "venv".
python_test_files() {
    (cd "$1" && grep -rlqE --include='test*.py' --include='*_test.py' \
        --exclude-dir=.git --exclude-dir=.evolve --exclude-dir=.claude --exclude-dir=.agents \
        --exclude-dir=.venv --exclude-dir=venv --exclude-dir=node_modules \
        "${2:-}" .) 2>/dev/null
}

# PEP 668: outside a virtual environment, a distribution-owned Python refuses pip installs.
# shortcut: asks python3, not the interpreter behind `pip`; resolve pip's own interpreter if the two are seen to differ.
python_externally_managed() {
    python3 -c 'import os, sys, sysconfig
marker = os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")
sys.exit(0 if sys.prefix == sys.base_prefix and os.path.exists(marker) else 1)' 2>/dev/null
}

# python_commands <dir> <pip install arguments> — for projects without a uv or poetry lock.
# Sets BUILD_CMD, TEST_CMD, LINT_CMD, FORMAT_CMD to commands whose tools can run here.
python_commands() {
    local dir="$1" install_arguments="$2" python="python3" pytest ruff
    if [ -x "$dir/.venv/bin/python" ]; then
        python=".venv/bin/python"
        [ -x "$dir/.venv/bin/pip" ] && BUILD_CMD=".venv/bin/pip install $install_arguments"
    elif command -v pip >/dev/null 2>&1 && ! python_externally_managed; then
        BUILD_CMD="pip install $install_arguments"
    fi

    pytest=$(python_tool "$dir" pytest)
    if [ -n "$pytest" ]; then
        TEST_CMD="$pytest"
    elif python_test_files "$dir" '^[[:space:]]*(import|from)[[:space:]]+unittest'; then
        TEST_CMD="$python -m unittest discover"
        # Discovery from the root only enters packages; a plain tests/ folder is named instead.
        if [ -d "$dir/tests" ] && [ ! -f "$dir/tests/__init__.py" ]; then
            TEST_CMD="$TEST_CMD -s tests"
        fi
    elif python_test_files "$dir"; then
        # Tests that need pytest: keep the command so its absence is reported, not skipped.
        TEST_CMD="pytest"
    fi

    ruff=$(python_tool "$dir" ruff)
    if [ -n "$ruff" ]; then
        LINT_CMD="$ruff check $RUFF_SCOPE"
        FORMAT_CMD="$ruff format --check $RUFF_SCOPE"
    fi
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
            TEST_CMD="uv run pytest"
            LINT_CMD="uv run ruff check $RUFF_SCOPE"
            FORMAT_CMD="uv run ruff format --check $RUFF_SCOPE"
        elif [ -f "$dir/poetry.lock" ]; then
            BUILD_CMD="poetry install"
            TEST_CMD="poetry run pytest"
            LINT_CMD="poetry run ruff check $RUFF_SCOPE"
            FORMAT_CMD="poetry run ruff format --check $RUFF_SCOPE"
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
