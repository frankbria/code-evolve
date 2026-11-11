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
check "deno: format" "$(field "$J" format)" "deno fmt --check --ignore=.evolve,.claude,.agents"

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

# ── One nested project (#94): its commands carry the directory they run in ──
NESTED=$(mktemp -d)
mkdir -p "$NESTED/app" "$NESTED/docs"
echo '{"scripts":{"build":"x","test":"y"}}' > "$NESTED/app/package.json"
JN=$(bash "$SCRIPT" "$NESTED")
substack_field() { echo "$JN" | python3 -c "import sys,json; s=json.load(sys.stdin).get('substacks',[]); print(s[0].get('$1','') if len(s)==1 else 'substacks: %d' % len(s))"; }
check "nested: stack"          "$(field "$JN" stack)"     "monorepo"
check "nested: no root build"  "$(field "$JN" build)"     ""
check "nested: substack dir"   "$(substack_field dir)"    "app"
check "nested: substack stack" "$(substack_field stack)"  "javascript"
check "nested: substack build" "$(substack_field build)"  "npm run build"
check "nested: substack test"  "$(substack_field test)"   "npm run test"
mkdir "$NESTED/we\"ird"
echo '<project/>' > "$NESTED/we\"ird/pom.xml"
mkdir "$NESTED/back\\slash"
echo '<project/>' > "$NESTED/back\\slash/pom.xml"
mkdir "$NESTED/tab"$'\t'"name"
echo '<project/>' > "$NESTED/tab"$'\t'"name/pom.xml"
JN=$(bash "$SCRIPT" "$NESTED")
check "nested: a name that would break the JSON is skipped" "$(substack_field dir)" "app"
rm -rf "$NESTED"

# ── Nested projects next to a root project (#152) ──
# The list lives in the engine's directory, so these fixtures get the scripts installed.
install_engine() { mkdir -p "$1/.evolve"; cp -R "$ROOT/templates/scripts" "$1/.evolve/scripts"; }
installed_detect() { bash "$1/.evolve/scripts/detect_stack.sh" "$1"; }
# listing <json> <key> <field>  → that field of every entry (or the entry itself), comma-joined
listing() { echo "$1" | python3 -c "import sys,json; print(','.join(e if isinstance(e, str) else e['$3'] for e in json.load(sys.stdin).get('$2', [])))"; }

MIXED=$(mktemp -d)
install_engine "$MIXED"
echo '{"scripts":{"build":"x","test":"y"}}' > "$MIXED/package.json"
mkdir -p "$MIXED/api" "$MIXED/examples/.venv/bin" "$MIXED/site" "$MIXED/services/worker" "$MIXED/plain"
# A folder nobody listed must not have its own interpreter run just to be named.
printf '[project]\nname = "examples"\n' > "$MIXED/examples/pyproject.toml"
printf '#!/bin/sh\ntouch "%s/interpreter-ran"\n' "$MIXED" > "$MIXED/examples/.venv/bin/python"
chmod +x "$MIXED/examples/.venv/bin/python"
echo '<project/>' > "$MIXED/api/pom.xml"
printf 'all:\n' > "$MIXED/examples/Makefile"
echo '<html></html>' > "$MIXED/site/index.html"
echo '{}' > "$MIXED/services/worker/deno.json"
JR=$(installed_detect "$MIXED")
check "root + nested, no list: the root project is reported as before" "$(field "$JR" stack)|$(field "$JR" build)" "javascript|npm run build"
check "root + nested, no list: no nested project is verified" "$(listing "$JR" substacks dir)" ""
check "root + nested, no list: folders with a stack marker are named as unverified" "$(listing "$JR" unverified dir)" "api,examples"
check "root + nested, no list: naming a folder does not run its interpreter" "$([ -e "$MIXED/interpreter-ran" ] && echo ran || echo "not run")" "not run"

printf '# verified next to the root project\n\napi/\n  services/worker  \r\n./examples\nplain\nmissing\n' > "$MIXED/.evolve/nested-projects.txt"
JR=$(installed_detect "$MIXED")
check "listed: the root project keeps its own commands" "$(field "$JR" stack)|$(field "$JR" test)" "javascript|npm run test"
check "listed: listed folders are substacks, deeper paths too" "$(listing "$JR" substacks dir)" "api,services/worker,examples"
check "listed: a substack carries its own commands" \
  "$(echo "$JR" | python3 -c "import sys,json; s=json.load(sys.stdin)['substacks'][0]; print(s['stack'], s['build'], s['test'], sep='|')")" "java|mvn compile|mvn test"
check "listed: nothing listed is left unverified" "$(listing "$JR" unverified dir)" ""

# Real projects at each place an entry could escape to, so only the filter keeps them out.
OUTSIDE="$(dirname "$MIXED")/outside-$(basename "$MIXED")"
mkdir "$OUTSIDE"
echo '<project/>' > "$OUTSIDE/pom.xml"
printf 'api\napi/\n%s\n../%s\napi/../../%s\n.\n' "$OUTSIDE" "$(basename "$OUTSIDE")" "$(basename "$OUTSIDE")" > "$MIXED/.evolve/nested-projects.txt"
JR=$(installed_detect "$MIXED")
check "listed: duplicates count once; paths outside the project are ignored" "$(listing "$JR" substacks dir)" "api"
check "listed: the rest is still named as unverified" "$(listing "$JR" unverified dir)" "examples"

# Read as a nested project itself (the CI workflow does, after installing dependencies), a
# folder is not searched with the root's list: api/api was never listed.
mkdir -p "$MIXED/api/api/.venv/bin" "$MIXED/a|b"
printf '[project]\nname = "inner"\n' > "$MIXED/api/api/pyproject.toml"
cp "$MIXED/examples/.venv/bin/python" "$MIXED/api/api/.venv/bin/python"
printf 'all:\n' > "$MIXED/a|b/Makefile"
rm -f "$MIXED/interpreter-ran"
JA=$(DETECT_STACK_NESTED=0 bash "$MIXED/.evolve/scripts/detect_stack.sh" "$MIXED/api")
check "a nested project read on its own: its commands, no list, nothing named" \
  "$(field "$JA" stack)|$(listing "$JA" substacks dir)|$(listing "$JA" unverified dir)|$([ -e "$MIXED/interpreter-ran" ] && echo ran || echo "not run")" "java|||not run"
JR=$(installed_detect "$MIXED")
check "unverified: a name with | is named too" "$(listing "$JR" unverified dir)" "a|b,examples"
rm -rf "$MIXED/a|b"

git -C "$MIXED" init -q
echo 'examples/' > "$MIXED/.gitignore"
JR=$(installed_detect "$MIXED")
check "unverified: a folder git ignores is not named" "$(listing "$JR" unverified dir)" ""
rm -rf "$MIXED" "$OUTSIDE"

# Without a root project every folder one level down counts, and the list adds deeper ones.
DEEP=$(mktemp -d)
install_engine "$DEEP"
mkdir -p "$DEEP/web" "$DEEP/services/worker"
echo '{}' > "$DEEP/web/deno.json"
echo '<project/>' > "$DEEP/services/worker/pom.xml"
printf 'services/worker\nweb\n' > "$DEEP/.evolve/nested-projects.txt"
JD=$(installed_detect "$DEEP")
check "no root project: still a monorepo" "$(field "$JD" stack)" "monorepo"
check "no root project: scanned folders once, listed deeper ones added" "$(listing "$JD" substacks dir)" "web,services/worker"
rm -rf "$DEEP"

# A name with | is a project like any other (the engine does not split on it).
PIPE=$(mktemp -d)
mkdir "$PIPE/a|b"
echo '<project/>' > "$PIPE/a|b/pom.xml"
JP=$(bash "$SCRIPT" "$PIPE")
check "a directory name with | is detected" "$(listing "$JP" substacks dir)" "a|b"
rm -rf "$PIPE"

echo "----"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
