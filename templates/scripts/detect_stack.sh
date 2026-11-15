#!/bin/bash
# scripts/detect_stack.sh — Detect project stack and output build/test/lint commands as JSON.
# Called by evolve.sh to adapt verification to whatever the project is using.
#
# Usage: ./scripts/detect_stack.sh [project_dir]
# Output: JSON with build, test, lint, format commands (or empty strings if not applicable)
#
# Supports nested layouts: if no stack marker at root, scans immediate subdirectories.
# When any are found, outputs {"stack":"monorepo","substacks":[...]}; each substack's
# commands run in its "dir". Next to a root project, the folders listed in
# ../nested-projects.txt are its "substacks" and other folders with a stack marker are "unverified";
# list entries that cannot be used are named in "skipped".

set -euo pipefail

PROJECT_DIR="${1:-.}"
SCRIPTS_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# has_file_matching <dir> <pattern>... — true when <dir> holds a file matching one of the patterns.
# Matched inside the folder: a * ? or [ in the folder's own name must not widen the match.
has_file_matching() {
    local dir="$1" pattern
    shift
    for pattern in "$@"; do
        (CDPATH="" cd -- "$dir" 2>/dev/null && compgen -G "$pattern" >/dev/null) && return 0
    done
    return 1
}

# Directories that hold no project tests: the engine, agent CLIs, and installed packages.
PYTHON_SKIPPED_DIRS=(.git .evolve .claude .agents .venv venv node_modules)

# listed_nested_paths <dir> — "./<folder>" (NUL-terminated) for each listed nested project when
# <dir> is the project root, else nothing: those folders are verified on their own, so the
# tests in them are not the root project's.
listed_nested_paths() {
    local nested
    [ "$1" = "$PROJECT_DIR" ] || return 0
    for nested in ${NESTED_PROJECT_PATHS[@]+"${NESTED_PROJECT_PATHS[@]}"}; do printf './%s\0' "$nested"; done
}

# python_has_test_files <dir> — true when the project has a file pytest collects by its name.
python_has_test_files() {
    local prunes=() name file nested nested_paths=()
    for name in "${PYTHON_SKIPPED_DIRS[@]}"; do prunes+=(-name "$name" -o); done
    while IFS= read -r -d '' nested; do nested_paths+=("$nested"); done < <(listed_nested_paths "$1")
    while IFS= read -r -d '' file; do
        for nested in ${nested_paths[@]+"${nested_paths[@]}"}; do
            case "$file" in "$nested"/*) continue 2 ;; esac
        done
        return 0
    done < <(cd "$1" && find . \( "${prunes[@]}" -false \) -prune -o -type f \( -name 'test*.py' -o -name '*_test.py' \) -print0 2>/dev/null)
    return 1
}

# python_unittest_command <dir> <python command> — prints the unittest command when it runs the
# whole suite, nothing otherwise. unittest_suite.py decides, by parsing the test files; it runs
# on an interpreter that exists now, which <python command> (`uv run python`) may not yet be.
python_unittest_command() {
    local dir="$1" interpreter="python3" arguments skipped=("${PYTHON_SKIPPED_DIRS[@]}") nested
    [ -x "$dir/.venv/bin/python" ] && interpreter="$dir/.venv/bin/python"
    while IFS= read -r -d '' nested; do skipped+=("$nested"); done < <(listed_nested_paths "$dir")
    arguments=$("$interpreter" -I "$SCRIPTS_DIR/unittest_suite.py" "$dir" "${skipped[@]}" 2>/dev/null) || return 0
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

# lock_installs_tool <dir> <lock file> <tool> — true when `uv sync` / `poetry install` puts the
# tool in the environment: the lock reaches it from the root project's own dependencies or its
# default groups, not only from an optional extra or an optional group. Python 3.11+ reads the
# TOML; where it cannot, a `name = "<tool>"` line in the lock is taken as enough.
lock_installs_tool() {
    local status=0
    python3 -I - "$1" "$2" "$3" <<'PY' 2>/dev/null || status=$?
import os
import re
import sys

try:
    import tomllib
except ImportError:
    sys.exit(2)

project_dir, lock_name, tool = sys.argv[1:4]


def read(name):
    path = os.path.join(project_dir, name)
    if not os.path.isfile(path):
        return {}
    with open(path, "rb") as source:
        return tomllib.load(source)


def normalized(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def uv_installs():
    packages = {}
    for package in read(lock_name).get("package", []):
        packages.setdefault(normalized(package["name"]), []).append(package)
    # uv.toml takes precedence over [tool.uv] in pyproject.toml.
    uv_settings = read("pyproject.toml").get("tool", {}).get("uv", {})
    uv_settings.update(read("uv.toml"))
    default_groups = uv_settings.get("default-groups", ["dev"])
    pending = []
    found_root = False
    for versions in packages.values():
        for package in versions:
            source = package.get("source", {})
            if "." not in (source.get("editable"), source.get("virtual")):
                continue
            found_root = True
            pending += package.get("dependencies", [])
            for group, dependencies in package.get("dev-dependencies", {}).items():
                if default_groups == "all" or group in default_groups:
                    pending += dependencies
    if not found_root:
        sys.exit(2)
    reached = set()
    while pending:
        dependency = pending.pop()
        name = normalized(dependency["name"])
        extras = tuple(dependency.get("extra", []))
        if (name, extras) in reached:
            continue
        reached.add((name, extras))
        for package in packages.get(name, []):
            pending += package.get("dependencies", [])
            for extra in extras:
                pending += package.get("optional-dependencies", {}).get(extra, [])
    return any(name == tool for name, _ in reached)


def poetry_installs():
    groups = read("pyproject.toml").get("tool", {}).get("poetry", {}).get("group", {})
    optional_groups = {name for name, settings in groups.items() if settings.get("optional")}
    for package in read(lock_name).get("package", []):
        if normalized(package["name"]) != tool or package.get("optional"):
            continue
        # poetry.lock 2.x lists a package's groups; older locks only a category, main or dev.
        listed = package.get("groups") or [package.get("category", "main")]
        # A "dev" of an old lock is any group, so it only counts out when all of them are optional.
        all_optional = bool(groups) and set(groups) <= optional_groups
        if any(group not in optional_groups and not (group == "dev" and all_optional) for group in listed):
            return True
    return False


try:
    installs = uv_installs() if lock_name == "uv.lock" else poetry_installs()
# ValueError covers a TOML syntax error and a lock that is not UTF-8.
except (OSError, ValueError, KeyError, TypeError, AttributeError):
    # A lock or pyproject.toml this code cannot follow falls back to the plain name check.
    sys.exit(2)
sys.exit(0 if installs else 1)
PY
    case $status in
        0) return 0 ;;
        1) return 1 ;;
    esac
    grep -qx "name = \"$3\"" "$1/$2"
}

# python_locked_commands <dir> <runner> <lock file> — for uv and poetry projects. The runner
# only finds a tool the lock file installs by default, so the others are chosen as for any
# Python project.
python_locked_commands() {
    local dir="$1" runner="$2" lock="$3" pytest="" ruff
    lock_installs_tool "$dir" "$lock" pytest && pytest="$runner pytest"
    TEST_CMD=$(python_test_command "$dir" "$pytest" "$runner pytest" "$runner python")
    if lock_installs_tool "$dir" "$lock" ruff; then
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

    elif has_file_matching "$dir" "*.sln" "*.csproj"; then
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

# Nested projects the user wants verified next to a root project: one directory per line,
# relative to the project root. Without a root project every folder one level down counts
# already, and the list adds deeper ones.
NESTED_LIST="$SCRIPTS_DIR/../nested-projects.txt"
# DETECT_STACK_NESTED=0: <project_dir> is itself a nested project (the CI workflow reads one
# again after installing its dependencies). The list belongs to the project root, so it must
# not be read against this directory, and nothing below it is named.
SCAN_NESTED="${DETECT_STACK_NESTED:-1}"

# listed_nested_dirs — the list's directories, one per line: no comments, no surrounding
# blanks, no leading ./ or trailing /, and no absolute path or .. component (a symlink the
# user lists is followed wherever it leads).
listed_nested_dirs() {
    local line
    [ "$SCAN_NESTED" != "0" ] && [ -f "$NESTED_LIST" ] || return 0
    # Read byte by byte: in a UTF-8 locale, a line ending in a byte that is not UTF-8 would
    # take the newline and the next line with it.
    while IFS= LC_ALL=C read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s|^\(\./\)*||; s|/*$||')
        case "/$line/" in //|/'#'*|//*|*/../*|*/./*) continue ;; esac
        printf '%s\n' "$line"
    done < "$NESTED_LIST"
}

# json_safe_name <name> — a name goes into the JSON unescaped; one that would break it is not
# worth losing the whole detection over. Bytes that are not UTF-8 break it too: every reader
# of the output would fail and the project would be left with no checks at all.
json_safe_name() {
    case "$1" in *'"'*|*'\'*|*[[:cntrl:]]*) return 1 ;; esac
    printable_ascii_name "$1" || printf '%s' "$1" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null
}
# printable_ascii_name <name> — the common case, decided without starting python.
printable_ascii_name() {
    local LC_ALL=C
    case "$1" in *[!\ -~]*) return 1 ;; esac
}

SUBSTACKS=""
UNVERIFIED=""
SKIPPED_ENTRIES=""

# physical_path <dir> — where the directory really is, symlinks followed; fails if it is none.
physical_path() { (CDPATH="" cd -- "$1" 2>/dev/null && pwd -P); }

# The projects recorded so far, by physical path: one reached by two names (a symlink) is
# verified once, and a name that leads back to the project root adds nothing.
PROJECT_PHYSICAL=$(physical_path "$PROJECT_DIR" || true)
SUBSTACK_PATHS=$'\n'"$PROJECT_PHYSICAL"$'\n'

# add_substack <dir relative to the project> — records the project found there, once.
# Fails when there is no project there.
add_substack() {
    local physical
    json_safe_name "$1" || return 0
    physical=$(physical_path "$PROJECT_DIR/$1") || return 1
    # A link that leads outside the project is not a part of it.
    case "$physical/" in "$PROJECT_PHYSICAL"/*) ;; *) return 1 ;; esac
    case "$SUBSTACK_PATHS" in *$'\n'"$physical"$'\n'*) return 0 ;; esac
    detect_single_stack "$PROJECT_DIR/$1"
    [ "$STACK" != "unknown" ] || return 1
    SUBSTACKS="${SUBSTACKS:+$SUBSTACKS,}{\"name\":\"$1\",\"dir\":\"$1\",\"stack\":\"$STACK\",\"build\":\"$BUILD_CMD\",\"test\":\"$TEST_CMD\",\"lint\":\"$LINT_CMD\",\"format\":\"$FORMAT_CMD\"}"
    SUBSTACK_PATHS="$SUBSTACK_PATHS$physical"$'\n'
}

# add_listed_substack <entry of the list> — add_substack, naming (in "skipped") an entry that
# cannot be used: a session may create the folder later, so it is not an error.
add_listed_substack() {
    local physical reason="is not a folder with a project in it"
    json_safe_name "$1" || return 0
    if physical=$(physical_path "$PROJECT_DIR/$1"); then
        case "$physical/" in
            "$PROJECT_PHYSICAL"/*) add_substack "$1" && return 0 ;;
            *) reason="points outside the project" ;;
        esac
    fi
    SKIPPED_ENTRIES="${SKIPPED_ENTRIES:+$SKIPPED_ENTRIES,}{\"entry\":\"$1\",\"reason\":\"$reason\"}"
}

# has_project_marker <dir> — true when the folder holds a project marker file.
has_project_marker() {
    local marker
    for marker in Cargo.toml deno.json deno.jsonc package.json pyproject.toml requirements.txt go.mod \
        pom.xml build.gradle build.gradle.kts settings.gradle settings.gradle.kts Gemfile composer.json \
        CMakeLists.txt Makefile; do
        [ ! -f "$1/$marker" ] || return 0
    done
    has_file_matching "$1" "*.sln" "*.csproj"
}

NESTED_DIRS=()
while IFS= LC_ALL=C read -r listed_dir; do NESTED_DIRS+=("$listed_dir"); done < <(listed_nested_dirs)
# The listed folders that hold a project, as paths from the project root with links resolved: only
# those are verified on their own, so only their tests are not the root project's.
NESTED_PROJECT_PATHS=()
for listed_dir in ${NESTED_DIRS[@]+"${NESTED_DIRS[@]}"}; do
    # A name the report cannot carry is never verified on its own, so its tests stay the root's.
    json_safe_name "$listed_dir" || continue
    nested_physical=$(physical_path "$PROJECT_DIR/$listed_dir") || continue
    case "$nested_physical" in "$PROJECT_PHYSICAL"/*) ;; *) continue ;; esac
    has_project_marker "$nested_physical" && NESTED_PROJECT_PATHS+=("${nested_physical#"$PROJECT_PHYSICAL"/}")
done

detect_single_stack "$PROJECT_DIR"
ROOT_STACK="$STACK"; ROOT_BUILD_CMD="$BUILD_CMD"; ROOT_TEST_CMD="$TEST_CMD"
ROOT_LINT_CMD="$LINT_CMD"; ROOT_FORMAT_CMD="$FORMAT_CMD"

if [ "$ROOT_STACK" = "unknown" ]; then
    for subdir in "$PROJECT_DIR"/*/; do
        [ -d "$subdir" ] || continue
        add_substack "$(basename "$subdir")" || true
    done
fi
for listed_dir in ${NESTED_DIRS[@]+"${NESTED_DIRS[@]}"}; do
    add_listed_substack "$listed_dir"
done

# The list appears only when it has entries.
SKIPPED_LIST=""
[ -z "$SKIPPED_ENTRIES" ] || SKIPPED_LIST=$'\n'"  \"skipped\": [$SKIPPED_ENTRIES],"

if [ "$ROOT_STACK" = "unknown" ] && [ -n "$SUBSTACKS" ]; then
    # One nested project is reported the same way as several: only a substack entry
    # carries the directory its commands must run in.
    cat <<EOF
{
  "stack": "monorepo",
  "substacks": [$SUBSTACKS],$SKIPPED_LIST
  "build": "",
  "test": "",
  "lint": "",
  "format": ""
}
EOF
    exit 0
fi

# Next to a root project, a folder that looks like a project and is not on the list is not
# verified. It is reported so that the engine can say so; folders git ignores (build output)
# are left out. Only marker files are looked at: full detection runs the folder's own
# interpreter (.venv/bin/python), and nobody offered these folders for that.
if [ "$ROOT_STACK" != "unknown" ] && [ "$SCAN_NESTED" != "0" ]; then
    for subdir in "$PROJECT_DIR"/*/; do
        [ -d "$subdir" ] || continue
        SUBDIR_NAME=$(basename "$subdir")
        json_safe_name "$SUBDIR_NAME" || continue
        physical=$(physical_path "$subdir") || continue
        # A folder already verified under another name, or one that leads out of the project.
        case "$physical/" in "$PROJECT_PHYSICAL"/*) ;; *) continue ;; esac
        case "$SUBSTACK_PATHS" in *$'\n'"$physical"$'\n'*) continue ;; esac
        ! git -C "$PROJECT_DIR" check-ignore -q -- "$SUBDIR_NAME" 2>/dev/null || continue
        has_project_marker "$subdir" || continue
        UNVERIFIED="${UNVERIFIED:+$UNVERIFIED,}\"$SUBDIR_NAME\""
    done
fi

# Single-stack output (or unknown). The lists appear only when they have entries.
NESTED_LISTS=""
[ -z "$SUBSTACKS" ] || NESTED_LISTS="$NESTED_LISTS"$'\n'"  \"substacks\": [$SUBSTACKS],"
[ -z "$UNVERIFIED" ] || NESTED_LISTS="$NESTED_LISTS"$'\n'"  \"unverified\": [$UNVERIFIED],"
NESTED_LISTS="$NESTED_LISTS$SKIPPED_LIST"
cat <<EOF
{
  "stack": "$ROOT_STACK",$NESTED_LISTS
  "build": "$ROOT_BUILD_CMD",
  "test": "$ROOT_TEST_CMD",
  "lint": "$ROOT_LINT_CMD",
  "format": "$ROOT_FORMAT_CMD"
}
EOF
