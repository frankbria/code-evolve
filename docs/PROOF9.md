# PROOF9: A Quality Memory System for Agentic Coding

Last updated: 2026-11-22

---

## The Problem

Traditional quality processes are amnesiac. They test what someone remembered to write tests for. If a bug slips through and gets fixed, the fix might include a test -- or it might not. There is no systematic mechanism to ensure that every failure becomes a permanent proof obligation.

This is especially dangerous in agentic coding, where AI agents generate code at high velocity. An agent can re-introduce a bug that was already fixed in a prior session because there is no institutional memory encoding _why_ the fix mattered or _what evidence_ should prove it stays fixed.

PROOF9 is that mechanism.

---

## Core Concept: Quality Memory

PROOF9 treats quality not as a point-in-time check ("do the tests pass?") but as an accumulating body of evidence ("do the requirements have proof?"). Every failure, once discovered, becomes a permanent obligation that must be satisfied on every subsequent build that touches the affected scope.

The result is **quality compounding interest**. Over time, the system becomes harder to break in the ways you have already been burned.

---

## The Nine Gates

PROOF9 defines nine categories of evidence that code must produce. Not every change triggers all nine -- the system uses scope selectors to determine which gates are relevant.

| Gate | What It Proves | How `proof run` checks it |
|------|----------------|---------------------------|
| **UNIT** | Logic correctness | The first that exists of `npm test`, `pytest`, `cargo test`, `go test ./...` |
| **BUILD** | The project builds | `npm run build`, `tsc --noEmit`, `python -m build`, `cargo build` or `go build ./...` |
| **LINT** | Lint and format rules hold | `npm run lint`, `ruff check .`, `eslint .` or `golangci-lint run` |
| **CONTRACT** | API and integration contracts hold | No automated check yet: recorded, not run |
| **E2E** | User journeys work end-to-end | No automated check yet |
| **SEC** | No known vulnerable dependencies | `npm audit --audit-level=high`, `pip-audit` or `cargo audit` |
| **PERF** | Performance within budget | No automated check yet |
| **DEMO** | Feature demonstrably works | No automated check yet |
| **MANUAL** | Human-verified (tracked waiver with expiry) | Waived with `code-evolve proof waive` |

A gate with no tool on the machine is reported as not evaluated (exit 2), not as passed.

### Scope Selectors

Not every task triggers all nine gates. The system uses **scope selectors** -- routes, components, APIs, files -- to determine which requirements intersect with the current change and runs only the relevant obligations. A change to an API route adds CONTRACT; a change that touches no API file does not.

---

## The Closed Loop

PROOF9's defining feature is not the gates themselves -- it is the feedback loop that connects failures to permanent enforcement.

```
Ship ──> Discover glitch ──> Capture ──> Enforce forever ──> Ship with higher confidence
  ^                                                                    |
  +────────────────────────────────────────────────────────────────────+
```

### How it works

1. **Glitch discovery.** A failure is found -- in production, QA, dogfooding, or monitoring. It does not matter where.

2. **Capture.** The glitch is captured as a **Requirement (REQ)** with attached proof obligations. Each REQ specifies:
   - A description of the failure
   - The scope it affects (files, routes, components)
   - Which PROOF9 gates must produce evidence to prove compliance
   - Severity and optional expiry (for time-bounded obligations)

3. **Permanent enforcement.** From that point forward, every build that touches the REQ's scope must produce evidence satisfying those obligations. The REQ can never be silently dropped.

4. **Waivers.** A REQ can be waived -- but only with a stated reason and an expiry date. The waiver itself is tracked in the requirements ledger. When it expires, the obligation returns.

### What this means in practice

- A bug that was fixed once will always have a proof obligation ensuring it stays fixed.
- An agent cannot silently re-introduce a regression -- the gate will catch it.
- Over time, the requirements ledger grows into a complete record of every quality issue the project has encountered and how it was resolved.

---

## Evidence Over Claims

A core design principle: **the agent says it fixed the bug; the PROOF9 gate says it did not. Believe the gate.**

Quality is not "tests pass." Quality is "requirements have evidence." The distinction matters because:

- Tests can be incomplete, outdated, or testing the wrong thing.
- A passing test suite says nothing about requirements that were never encoded as tests.
- PROOF9 ties verification to requirements, not to whatever tests happen to exist.

Each gate run produces **evidence artifacts** -- test output, coverage reports, lighthouse scores, security scan results, screenshots -- that prove compliance. These artifacts are stored and associated with the REQ they satisfy.

---

## How PROOF9 Differs from Traditional Quality Tools

| Dimension | Traditional (SonarQube, Codecov) | PROOF9 |
|-----------|----------------------------------|--------|
| **Driven by** | Metrics (coverage %, lint score) | Requirements (what must be proven) |
| **Memory** | None -- each run is independent | Cumulative -- every failure becomes permanent |
| **Scope** | Whole codebase | Per-change, based on scope selectors |
| **Feedback loop** | Report → human decides → maybe fix | Capture → enforce → never forget |
| **Waivers** | Not tracked | Tracked with reason, expiry, and audit trail |
| **Evidence** | Test results only | Multi-dimensional (9 gate categories) |

---

## Integration Points

PROOF9 is designed to work at multiple stages of a delivery pipeline:

- **During development:** Gates run locally after agent execution, catching issues before code leaves the developer's machine.
- **At PR time:** Pull requests carry a proof report showing which obligations passed, which were waived, and what evidence was produced.
- **At merge time:** Merge can be gated on PROOF9 pass (configurable strictness).
- **Post-deployment:** When a glitch is found after deployment, the capture loop feeds it back as a new REQ, enforced on every subsequent build.

PROOF9 is not a CI/CD system. It produces artifacts that CI/CD systems consume. The requirements ledger and the closed loop are the contribution -- not the test runner itself.

---

## The One Sentence

PROOF9 is a quality memory system that turns every failure into a permanent, evidence-based proof obligation -- so the same mistake can never silently recur.
