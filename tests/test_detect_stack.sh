#!/bin/bash
# Test: detect_stack.sh recognizes the stacks added in P2.2 (issue #28) —
# Java/Kotlin (Maven/Gradle), C#/.NET, Ruby, PHP, C/C++ (CMake), Deno, static —
# in addition to the pre-existing Rust/JS-TS/Python/Go/Make detectors, and that
# new stacks also surface through the monorepo substack scan.
#
# Drives the real script against temp dirs holding only a marker file. Hermetic:
# no toolchains required (the script emits commands; it does not run them).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/templates/scripts/detect_stack.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2', want '$3')"; fail=$((fail+1)); fi }

# field <json> <key>  → extract a top-level string field
field() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$2',''))"; }

# detect <setup-fn>  → run setup in a fresh temp dir, echo the JSON
detect() {
  local d; d=$(mktemp -d); ( cd "$d" && "$1" )
  bash "$SCRIPT" "$d"
  rm -rf "$d"
}

# ── Deno ──
mk_deno() { echo '{}' > deno.json; }
J=$(detect mk_deno)
check "deno: stack"  "$(field "$J" stack)"  "deno"
check "deno: test"   "$(field "$J" test)"   "deno test"
check "deno: format" "$(field "$J" format)" "deno fmt --check"

# ── Deno wins over a co-located package.json (npm-compat projects) ──
mk_deno_pkg() { echo '{}' > deno.json; echo '{"scripts":{"build":"x"}}' > package.json; }
J=$(detect mk_deno_pkg)
check "deno+pkg: deno wins" "$(field "$J" stack)" "deno"

# ── Java / Maven ──
mk_maven() { echo '<project/>' > pom.xml; }
J=$(detect mk_maven)
check "maven: stack" "$(field "$J" stack)" "java"
check "maven: build" "$(field "$J" build)" "mvn compile"
check "maven: test"  "$(field "$J" test)"  "mvn test"

# ── Java / Gradle (with wrapper) ──
mk_gradle() { echo 'plugins {}' > build.gradle.kts; : > gradlew; }
J=$(detect mk_gradle)
check "gradle: stack" "$(field "$J" stack)" "java"
check "gradle: build" "$(field "$J" build)" "./gradlew build"
check "gradle: test"  "$(field "$J" test)"  "./gradlew test"

# ── .NET ──
mk_dotnet() { echo '<Project/>' > App.csproj; }
J=$(detect mk_dotnet)
check "dotnet: stack"  "$(field "$J" stack)"  "dotnet"
check "dotnet: build"  "$(field "$J" build)"  "dotnet build"
check "dotnet: format" "$(field "$J" format)" "dotnet format --verify-no-changes"

# ── Ruby (rspec + rubocop) ──
mk_ruby() { printf "gem 'rspec'\ngem 'rubocop'\n" > Gemfile; }
J=$(detect mk_ruby)
check "ruby: stack" "$(field "$J" stack)" "ruby"
check "ruby: test"  "$(field "$J" test)"  "bundle exec rspec"
check "ruby: lint"  "$(field "$J" lint)"  "bundle exec rubocop"

# ── Ruby (default rake, no rubocop) ──
mk_ruby2() { echo "source 'https://rubygems.org'" > Gemfile; }
J=$(detect mk_ruby2)
check "ruby-rake: test" "$(field "$J" test)" "bundle exec rake"
check "ruby-rake: lint" "$(field "$J" lint)" ""

# ── PHP (composer test script) ──
mk_php() { echo '{"scripts":{"test":"phpunit"}}' > composer.json; }
J=$(detect mk_php)
check "php: stack" "$(field "$J" stack)" "php"
check "php: test"  "$(field "$J" test)"  "composer test"

# ── PHP (no test script → phpunit) ──
mk_php2() { echo '{}' > composer.json; }
J=$(detect mk_php2)
check "php-phpunit: test" "$(field "$J" test)" "vendor/bin/phpunit"

# ── C/C++ (CMake) ──
mk_cpp() { echo 'project(x)' > CMakeLists.txt; }
J=$(detect mk_cpp)
check "cpp: stack" "$(field "$J" stack)" "cpp"
check "cpp: test"  "$(field "$J" test)"  "ctest --test-dir build"

# ── CMake wins over a sibling Makefile ──
mk_cpp_make() { echo 'project(x)' > CMakeLists.txt; echo 'all:' > Makefile; }
J=$(detect mk_cpp_make)
check "cpp+make: cmake wins" "$(field "$J" stack)" "cpp"

# ── Static site (weakest signal, after Makefile) ──
mk_static() { echo '<html></html>' > index.html; }
J=$(detect mk_static)
check "static: stack" "$(field "$J" stack)" "static"

# ── Monorepo: new stacks surface as substacks ──
MONO=$(mktemp -d)
mkdir -p "$MONO/api" "$MONO/web"
echo '<project/>' > "$MONO/api/pom.xml"
echo '{}' > "$MONO/web/deno.json"
JM=$(bash "$SCRIPT" "$MONO")
check "monorepo: stack" "$(field "$JM" stack)" "monorepo"
check "monorepo: substack stacks" \
  "$(echo "$JM" | python3 -c "import sys,json; print(','.join(sorted(s['stack'] for s in json.load(sys.stdin)['substacks'])))")" \
  "deno,java"
rm -rf "$MONO"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
