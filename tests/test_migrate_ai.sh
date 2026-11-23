#!/bin/bash
# Test (#97): `migrate --ai` drafts through the configured agent's adapter, not a hard-coded
# `claude -p`, and writes only the agent's reply (not its transcript or tool log). The retired
# `vision` and `spec` interviews print a pointer to evolve-setup and change nothing.
#
# Drives the real compiled CLI. Stub `codex` and `claude` binaries stand in for the agents.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/cli.js"
[ -f "$CLI" ] || ( cd "$ROOT" && npm run build >/dev/null 2>&1 )

pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
stubs="$work/bin"; mkdir -p "$stubs"
calls="$work/calls.log"

# codex: prints a transcript, and writes the bare reply only where --output-last-message points.
cat > "$stubs/codex" <<EOF
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "codex-cli 0.0.0-stub"; exit 0; }
echo "codex \$*" >> "$calls"
cat >/dev/null
reply_file=""
while [ \$# -gt 0 ]; do [ "\$1" = "--output-last-message" ] && reply_file="\$2"; shift; done
echo "OpenAI Codex (stub) transcript line"
echo "tokens used 123" >&2
[ -n "\$reply_file" ] && printf '# Vision\n\nCODEX_DRAFT\n' > "\$reply_file"
exit 0
EOF
# claude: speaks stream-json like \`claude -p --output-format stream-json\`.
cat > "$stubs/claude" <<EOF
#!/bin/bash
[ "\${1:-}" = "--version" ] && { echo "claude 0.0.0-stub"; exit 0; }
echo "claude \$*" >> "$calls"
cat >/dev/null
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Let me read the document."}]}}'
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"# Vision\\n\\nCLAUDE_DRAFT"}'
EOF
chmod +x "$stubs/codex" "$stubs/claude"
export PATH="$stubs:$PATH"

new_project() {
    local dir="$work/$1"; mkdir -p "$dir"
    ( cd "$dir" && git init -q && node "$CLI" init --yes --agent "$2" </dev/null >/dev/null 2>&1 )
    printf '# Notes app\n\nA terminal notes tool for developers.\n' > "$dir/doc.md"
    echo "$dir"
}

# ── The configured agent (codex) drafts, and only its reply is written ──
project="$(new_project codex-project codex)"
: > "$calls"
( cd "$project" && OPENAI_API_KEY=stub-key node "$CLI" migrate vision doc.md --ai --yes </dev/null >"$work/out.txt" 2>&1 ) \
    && ok "migrate --ai succeeds with the codex adapter" || bad "migrate --ai failed: $(tail -3 "$work/out.txt")"
grep -q '^codex exec' "$calls" && ok "the codex stub was invoked through the adapter" || bad "the codex stub was not invoked"
grep -q '^claude' "$calls" && bad "claude was called although the project is set up for codex" || ok "claude was not called"
[ "$(cat "$project/.evolve/vision.md")" = "$(printf '# Vision\n\nCODEX_DRAFT')" ] \
    && ok "vision.md holds codex's reply and none of its transcript" \
    || bad "vision.md is not codex's bare reply: $(head -3 "$project/.evolve/vision.md" | tr '\n' '|')"

# ── No usable agent (its API key is unset): fail clearly and write nothing ──
before="$(cat "$project/.evolve/vision.md")"
set +e
( cd "$project" && env -u OPENAI_API_KEY node "$CLI" migrate vision doc.md --ai --yes </dev/null >"$work/out.txt" 2>&1 )
status=$?
set -e
[ "$status" -ne 0 ] && grep -q 'codex' "$work/out.txt" && ok "without a usable agent, migrate --ai fails and names the agent" \
    || bad "migrate --ai without a usable agent: exit $status, output: $(tail -2 "$work/out.txt")"
[ "$(cat "$project/.evolve/vision.md")" = "$before" ] && ok "a failed draft leaves vision.md as it was" || bad "a failed draft changed vision.md"

# ── Claude's adapter: the stream's result is written, not the rendered log ──
project="$(new_project claude-project claude)"
: > "$calls"
( cd "$project" && ANTHROPIC_API_KEY=stub-key node "$CLI" migrate vision doc.md --ai --yes </dev/null >"$work/out.txt" 2>&1 ) \
    && grep -q '^claude -p' "$calls" && ok "migrate --ai drafts with the claude adapter when claude is configured" \
    || bad "migrate --ai with claude: $(tail -3 "$work/out.txt")"
[ "$(cat "$project/.evolve/vision.md")" = "$(printf '# Vision\n\nCLAUDE_DRAFT')" ] \
    && ok "vision.md holds claude's result and none of the rendered log" \
    || bad "vision.md is not claude's bare result: $(head -4 "$project/.evolve/vision.md" | tr '\n' '|')"

# ── The retired interviews point to evolve-setup and change nothing ──
for command in vision "spec --refine"; do
    before="$(cat "$project/.evolve/vision.md" "$project/.evolve/spec.md")"
    output="$( cd "$project" && node "$CLI" $command </dev/null 2>&1 )" && status=0 || status=$?
    [ "$status" -eq 0 ] && grep -qF 'evolve-setup' <<<"$output" && ! grep -qi 'interview ===' <<<"$output" \
        && ok "\`$command\` points to evolve-setup and asks nothing" || bad "\`$command\` (exit $status): $(head -2 <<<"$output")"
    [ "$(cat "$project/.evolve/vision.md" "$project/.evolve/spec.md")" = "$before" ] \
        && ok "\`$command\` leaves vision.md and spec.md alone" || bad "\`$command\` changed vision.md or spec.md"
done

echo "---"
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
