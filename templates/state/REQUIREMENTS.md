# Requirements Ledger

<!-- REQ states: open | satisfied | regressed | waived -->
<!-- Severity:   critical | high | medium | low -->
<!-- Gates:      UNIT | BUILD | LINT | CONTRACT | E2E | SEC | PERF | DEMO | MANUAL -->
<!--
REQ format:
## REQ-NNNN: <title>
- **Source**: <session revert | GitHub issue #N | agent self-assessment | manual>
- **Severity**: critical | high | medium | low
- **Scope**: <glob patterns and/or route patterns, comma-separated>
- **Obligations**: [GATE1, GATE2, ...]
- **Evidence**: <artifact path or "(none yet)" or "(waived)">
- **Status**: open | satisfied | regressed | waived
- **Satisfied by**: <Day N, commit sha>       (only if satisfied)
- **Waiver reason**: <reason>                  (only if waived)
- **Waiver expires**: <Day N or date>          (only if waived)

REQs are created automatically from:
  - Session reverts (evolve.sh auto-capture)
  - GitHub issues addressed by the agent
  - `code-evolve proof capture` (manual)
  - Agent self-assessment during PHASE 4.5

Evidence artifacts are stored in .evolve/evidence/REQ-XXXX/
and are NOT committed to git (ephemeral audit trail).
-->
