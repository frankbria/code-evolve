# code-evolve — Injectability Status Report

**Date:** 2026-06-28
**Question:** How close is `code-evolve` to being an *installable function* that can be dropped into **any** GitHub repo — regardless of language or maturity — to "turn on" autonomous evolution, with a guided install that picks an LLM, interviews the user to produce the artifacts, and wires up local and/or GitHub Action execution on a chosen schedule?

---

## Verdict: ~60% there

The **core evolution engine is real and surprisingly solid** for the happy path (a Claude user, a committed JS/TS/Python/Rust repo, run locally or via the existing GitHub Action). Stack detection is genuinely data-driven, file installation is collision-safe, and a working cron-based local scheduler and CI path both exist.

But the product the user is describing — *"open any repo, install, get interviewed, turn it on"* — has **two hard functional blockers** and a **missing guided-install layer**:

- ~~**The GitHub Action path is currently dead** — workflows install into a subdirectory GitHub never executes (P0.1).~~ **RESOLVED** in #36 — workflows now install directly into `.github/workflows/` with collision-safe names. (Per-agent CI for non-Claude backends remains a follow-up.)
- **True greenfield (zero-commit) repos abort immediately** on session start (P0.2).
- **Guided onboarding is still thin.** `init` now prompts for the agent + auth backend on a TTY (P1.1, #20), but there is still no spec generator, the existing vision interview is hardcoded (not LLM-driven) and not wired into `init`, and there is no "choose local / CI / both + pick a schedule" step (P1.x).

Beyond that, breadth (more languages), non-Claude backend robustness, and package hygiene (no tests, doc drift) are the long tail.

---

## What already works

| Area | State |
|------|-------|
| **Stack detection** | `detect_stack.sh` emits build/test/lint/format as JSON per stack; supports Rust, JS/TS (npm/pnpm/yarn/bun), Python (uv/poetry/pip), Go, Makefile, and 1-level monorepos. Verifies scripts exist before emitting commands. |
| **Non-destructive install** | Workflows use skip-if-exists; `.gitignore` appended with a marker guard; state files preserved on re-init. Won't clobber an existing repo's files. |
| **Local execution** | `code-evolve start` installs a real Unix **crontab** entry (survives reboots), writes a 0600 `.env`, gitignored. `stop` removes it cleanly. |
| **CI execution** | `templates/workflows/evolve.yml` runs the engine on a cron + `workflow_dispatch` (but see P0.1). |
| **Multi-agent architecture** | 4 adapters ship (claude/codex/ollama/opencode); selection via `--agent`, persisted to `config.json`, sourced by `evolve.sh`. Claude is complete end-to-end. |
| **Vision interview** | `code-evolve vision` runs a 10-question interactive interview → `vision.md` (but hardcoded Q&A, undocumented, not linked to `init`). |
| **PROOF9** | Optional requirements-ledger / quality-gate subsystem. Not required for injectability. |

---

## Gaps by dimension

### 1. Functional blockers (advertised feature literally doesn't work)
- ~~**CI workflows install to `.github/workflows/evolve/`** — GitHub Actions only executes workflows directly in `.github/workflows/`, so nested workflows never ran.~~ **RESOLVED in #36** — workflows now install directly into `.github/workflows/` as `evolve.yml`/`evolve-ci.yml`. Remaining open work: the bundled workflow is Claude-only, so `--with-ci` is skipped for non-Claude backends (per-agent CI tracked in #37). → **P0.1 done**
- **Greenfield abort.** `evolve.sh:277` runs `git rev-parse HEAD` under `set -euo pipefail` (`:23`). On a freshly `git init`'d repo with no commits this exits non-zero and kills the session before any work. → **P0.2**

### 2. Guided installation (the "turn on" experience — the heart of the ask)
- ~~No interactive **LLM/agent picker**; `init` silently defaults to `claude`/`api-key`.~~ **DONE** (#20) — `init` prompts for agent + auth on a TTY; flags/non-TTY skip it. → **P1.1**
- No **spec generator** — `spec.md` is always hand-written. → **P1.2**
- `init` never offers to generate artifacts; the `vision` interview is disconnected and undocumented. → **P1.3**
- The interview is **hardcoded string Q&A, not the LLM interviewing the user**. → **P1.4**
- No **execution-mode selector** (local / CI / both); `--with-ci` and `start` are disjoint, no persisted mode. → **P1.5**
- ~~**Schedule is not configurable at install**: local is `--every <hours>` only; CI cron is hardcoded `0 */4 * * *` in the template.~~ **RESOLVED in #44** — `code-evolve init --every <hours>` now applies the chosen cadence to both the templated CI `cron:` and the local cron entry (prompted on a TTY). → **P1.6 done**
- No **unified setup wizard** chaining picker → interview → mode → schedule. → **P1.7**

### 3. Breadth & correctness (works on more repos, correctly)
- ~~CI provisions only Node/Python toolchains — **Rust/Go/JVM builds fail in CI**.~~ **RESOLVED in #46** — both `ci.yml` and `evolve.yml` now detect the stack(s) up front and conditionally install Rust (`dtolnay/rust-toolchain`), Go (`actions/setup-go`), and Java/Kotlin (`actions/setup-java`) toolchains; monorepos install each needed one. Java/Kotlin gating is inert until detection lands (#28). → **P2.1 done**
- Large class of stacks fall through to "unknown" (no verification): **Java/Kotlin, C#/.NET, Ruby, PHP, C/C++, Deno, static sites**. → **P2.2**
- `evolve.sh` blindly appends `--quiet` to build/test commands → **false "build has issues" for Go/Make/pip**. → **P2.3**
- ~~Agent **error detection is Claude-JSON-specific** (`evolve.sh:476`) — codex/ollama/opencode failures pass undetected.~~ **RESOLVED in #49** — the main session now captures `run_agent`'s real exit code (no longer masked by `tee`) and flags a failure on non-zero exit OR a per-adapter `agent_detect_error` marker (Claude keeps its `"type":"error"` grep; other adapters defer to exit code). → **P2.4 done**
- codex/opencode/ollama adapter invocations are **unverified against the real CLIs** (e.g. Codex now uses `codex exec`). → **P2.5**
- Skills are greenfield/spec-driven; **no instruction to discover & honor an existing mature repo's conventions**. → **P2.6**

### 4. Package polish & accuracy
- **`npm test` is broken** — jest declared but not installed, zero test files. → **P3.1**
- **CLAUDE.md & package.json drift** — CLAUDE.md lists 4 commands (code ships 9) and flat skills (actually 5 dirs); package.json missing `keywords`/`homepage`/`bugs`. → **P3.2**
- **`schedule.json` is dead config** (written/displayed but never consumed); `--force` help text is misleading. → **P3.3**

---

## Issue index

| Issue | # | Priority | Title | Depends on |
|-------|---|----------|-------|------------|
| P0.1 | [#18](https://github.com/frankbria/code-evolve/issues/18) ✅ | Blocker | Install GitHub Actions workflows into `.github/workflows/` so they actually run *(done in #36)* | — |
| P0.2 | [#19](https://github.com/frankbria/code-evolve/issues/19) | Blocker | Handle zero-commit / greenfield repos without aborting the session | — |
| P1.1 | [#20](https://github.com/frankbria/code-evolve/issues/20) ✅ | High | Interactive LLM/agent + auth picker on `init` *(done in #39)* | — |
| P1.2 | [#21](https://github.com/frankbria/code-evolve/issues/21) | High | Add `spec` interview command to generate `spec.md` | — |
| P1.3 | [#22](https://github.com/frankbria/code-evolve/issues/22) | High | Wire `init` to offer vision + spec generation after install | P1.1, P1.2 |
| P1.4 | [#23](https://github.com/frankbria/code-evolve/issues/23) | High | Make the vision/spec interview LLM-driven via the chosen agent | P1.1 |
| P1.5 | [#24](https://github.com/frankbria/code-evolve/issues/24) | High | Execution-mode selector (local / CI / both) persisted in config | — |
| P1.6 | [#25](https://github.com/frankbria/code-evolve/issues/25) | High | Make the evolution schedule configurable at install (local + CI) | — |
| P1.7 | [#26](https://github.com/frankbria/code-evolve/issues/26) | High | Unified `setup` wizard chaining picker → interview → mode → schedule | P1.1–P1.6 |
| P2.1 | [#27](https://github.com/frankbria/code-evolve/issues/27) | Medium | Provision CI toolchains for the detected stack (Rust/Go/JVM) | — |
| P2.2 | [#28](https://github.com/frankbria/code-evolve/issues/28) | Medium | Add stack detectors for Java/Kotlin, C#/.NET, Ruby, PHP, C/C++, Deno, static | — |
| P2.3 | [#29](https://github.com/frankbria/code-evolve/issues/29) | Medium | Make build/test/format invocation stack-aware (drop blind `--quiet`) | — |
| P2.4 | [#30](https://github.com/frankbria/code-evolve/issues/30) ✅ | Medium | Per-adapter agent error detection (stop assuming Claude JSON) *(done in #49)* | — |
| P2.5 | [#31](https://github.com/frankbria/code-evolve/issues/31) | Medium | Verify & fix codex/opencode/ollama adapter invocations vs real CLIs | — |
| P2.6 | [#32](https://github.com/frankbria/code-evolve/issues/32) | Medium | Add a "respect existing repo conventions" pass for mature repos | — |
| P3.1 | [#33](https://github.com/frankbria/code-evolve/issues/33) | Low | Add jest + first unit tests; fix the broken `npm test` | — |
| P3.2 | [#34](https://github.com/frankbria/code-evolve/issues/34) | Low | Fix CLAUDE.md / package.json doc & metadata drift | — |
| P3.3 | [#35](https://github.com/frankbria/code-evolve/issues/35) | Low | Make `schedule.json` real or document it; fix misleading `--force` help | — |

Priority = importance × dependency. Ship **P0** first (the feature is broken without it), then **P1** (the guided-install experience the project is actually about), then breadth (**P2**) and polish (**P3**).
