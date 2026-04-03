import { Command } from 'commander';
import fs from 'fs';
import readline from 'readline';
import { execSync } from 'child_process';
import { isInitialized, evidenceDir, currentDay, shortCommit } from '../utils/paths';
import {
  readLedger,
  writeLedger,
  createReq,
  nextReqId,
  filterReqsByScope,
  assignGates,
  writeEvidence,
  updateReqEvidence,
  reinstateLapsedWaivers,
  isWaiverExpired,
  generateTestStub,
  Gate,
  Req,
  ReqStatus,
  Severity,
} from '../utils/proof';
import { output } from '../utils/output';

// ── Helpers ───────────────────────────────────────────────────────────────────

function requireInit(): void {
  if (!isInitialized()) {
    console.error('Not initialized. Run `code-evolve init` first.');
    process.exit(1);
  }
}

function changedFilesSinceLastCommit(): string[] {
  try {
    const staged = execSync('git diff --name-only HEAD', { stdio: ['pipe', 'pipe', 'pipe'] }).toString().trim();
    const untracked = execSync('git ls-files --others --exclude-standard', { stdio: ['pipe', 'pipe', 'pipe'] }).toString().trim();
    const all = [staged, untracked].filter(Boolean).join('\n');
    return all ? all.split('\n').filter(Boolean) : [];
  } catch {
    return [];
  }
}

// ── proof capture ─────────────────────────────────────────────────────────────

const captureCommand = new Command('capture')
  .description('Capture a quality issue as a new REQ')
  .option('--from-issue <number>', 'Pre-fill from a GitHub issue number')
  .action(async (options: { fromIssue?: string }) => {
    requireInit();

    let prefillTitle = '';
    let prefillSource = 'manual';

    if (options.fromIssue) {
      if (!/^\d+$/.test(options.fromIssue)) {
        console.error('Invalid issue number. Must be a positive integer.');
        process.exit(1);
      }
      try {
        const json = execSync(`gh issue view ${options.fromIssue} --json title,number`, {
          stdio: ['pipe', 'pipe', 'pipe'],
        }).toString();
        const { title, number } = JSON.parse(json) as { title: string; number: number };
        prefillTitle = title;
        prefillSource = `GitHub issue #${number}`;
        console.log(`Pre-filling from GitHub issue #${number}: "${title}"`);
      } catch {
        console.warn(`Warning: could not fetch GitHub issue #${options.fromIssue}. Continuing manually.`);
      }
    }

    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const ask = (q: string, def = ''): Promise<string> =>
      new Promise((resolve) => {
        rl.question(def ? `${q} [${def}]: ` : `${q}: `, (ans) => resolve(ans || def));
      });

    console.log('\nCapture a new quality requirement:\n');

    const title = await ask('Title', prefillTitle);
    if (!title) {
      console.error('Title is required.');
      rl.close();
      process.exit(1);
    }

    const source = await ask('Source (e.g. "Day 3 session revert", "GitHub issue #12")', prefillSource);
    const severityRaw = await ask('Severity [critical/high/medium/low]', 'high');
    const severity = (['critical', 'high', 'medium', 'low'].includes(severityRaw)
      ? severityRaw
      : 'high') as Severity;

    const scopeRaw = await ask('Scope (glob patterns, comma-separated, e.g. "src/auth/*,*.sql")', '*');
    const scope = scopeRaw.split(',').map((s) => s.trim()).filter(Boolean);

    const obligationsRaw = await ask(
      'Obligations [UNIT/BUILD/LINT/CONTRACT/E2E/SEC/PERF/DEMO/MANUAL, comma-separated]',
      'BUILD,UNIT'
    );
    const validGates: Gate[] = ['UNIT', 'BUILD', 'LINT', 'CONTRACT', 'E2E', 'SEC', 'PERF', 'DEMO', 'MANUAL'];
    const obligations = obligationsRaw
      .split(',')
      .map((g) => g.trim().toUpperCase())
      .filter((g): g is Gate => validGates.includes(g as Gate));

    if (obligations.length === 0) {
      console.error('At least one valid obligation is required (UNIT, BUILD, LINT, CONTRACT, E2E, SEC, PERF, DEMO, MANUAL).');
      rl.close();
      process.exit(1);
    }

    rl.close();

    const reqs = readLedger();
    const id = nextReqId(reqs);
    const req = createReq({ id, title, source, severity, scope, obligations });
    reqs.push(req);
    writeLedger(reqs);

    console.log(`\n${id} created`);
    console.log(`  Title:       ${title}`);
    console.log(`  Source:      ${source}`);
    console.log(`  Severity:    ${severity}`);
    console.log(`  Scope:       ${scope.join(', ')}`);
    console.log(`  Obligations: [${obligations.join(', ')}]`);
    console.log(`  Status:      open`);

    // Generate test stubs if obligations include UNIT/CONTRACT/E2E
    const stubGates: Gate[] = obligations.filter((g) => ['UNIT', 'CONTRACT', 'E2E'].includes(g));
    if (stubGates.length > 0) {
      const stub = generateTestStub(id, stubGates, scope);
      if (stub) {
        console.log('\nTest stub (add to your test file):\n');
        console.log(stub);
      }
    }
  });

// ── proof run ─────────────────────────────────────────────────────────────────

const runCommand = new Command('run')
  .description('Run proof obligation checks for current changes')
  .option('--full', 'Run all obligations regardless of scope')
  .action(async (options: { full?: boolean }) => {
    requireInit();

    let reqs = readLedger();
    const day = currentDay();

    // Reinstate lapsed waivers
    reqs = reinstateLapsedWaivers(reqs, day);

    const changedFiles = options.full ? [] : changedFilesSinceLastCommit();
    const applicable = options.full ? reqs : filterReqsByScope(reqs, changedFiles);

    if (applicable.length === 0) {
      const scope = options.full ? 'any' : 'current changes';
      console.log(`No requirements apply to ${scope}.`);
      return;
    }

    console.log(`\nRunning proof obligations for ${applicable.length} REQ(s)...\n`);

    let hasRegressions = false;

    for (const req of applicable) {
      if (req.status === 'waived' && !isWaiverExpired(req, day)) {
        console.log(`  ${req.id}: WAIVED (expires ${req.waiverExpires})`);
        continue;
      }

      console.log(`  ${req.id}: ${req.title}`);
      console.log(`    Obligations: [${req.obligations.join(', ')}]`);

      // Collect all gate results before updating REQ status (a later passing gate must
      // not overwrite the status set by an earlier failing gate)
      type GateResult = { gate: Gate; passed: boolean; artifactPath: string };
      const gateResults: GateResult[] = [];

      for (const gate of req.obligations) {
        const result = runGate(gate);
        if (result.exitCode === 2) {
          // Gate not evaluated (no tool found) — skip without marking pass/fail
          console.log(`    [${gate}] SKIP — ${result.output}`);
          continue;
        }
        const artifactPath = writeEvidence(req.id, gate, result.command, result.output, result.exitCode);
        const passed = result.exitCode === 0;
        gateResults.push({ gate, passed, artifactPath });
        console.log(`    [${gate}] ${passed ? 'PASS' : 'FAIL'} — ${artifactPath}`);
      }

      // Determine aggregate outcome: all gates must pass for satisfied; any fail is a failure
      const anyEvaluated = gateResults.length > 0;
      const allPassed = anyEvaluated && gateResults.every((r) => r.passed);
      const anyFailed = gateResults.some((r) => !r.passed);
      const lastArtifact = gateResults[gateResults.length - 1]?.artifactPath ?? '';

      const idx = reqs.findIndex((r) => r.id === req.id);
      if (idx !== -1) {
        if (anyFailed && req.status === 'satisfied') {
          hasRegressions = true;
          reqs[idx] = { ...reqs[idx], status: 'regressed' };
          console.log(`    → REGRESSED`);
        } else if (anyFailed) {
          // stays open/regressed — no further change needed
        } else if (allPassed) {
          reqs[idx] = updateReqEvidence(
            { ...reqs[idx], status: 'satisfied', satisfiedBy: `Day ${day}, commit ${shortCommit()}` },
            lastArtifact
          );
        }
      }
    }

    writeLedger(reqs);

    if (hasRegressions) {
      console.error('\nREGRESSION DETECTED: Fix regressed requirements before committing.');
      process.exit(1);
    } else {
      console.log('\nAll applicable obligations checked.');
    }
  });

function detectCommand(candidates: string[]): string | null {
  for (const cmd of candidates) {
    const binary = cmd.split(' ')[0];
    try {
      // For `npm run <script>`, verify the script exists in package.json
      if (binary === 'npm' && cmd.startsWith('npm run ')) {
        const scriptName = cmd.split(' ')[2];
        const pkgPath = 'package.json';
        if (fs.existsSync(pkgPath)) {
          const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8')) as { scripts?: Record<string, string> };
          if (!pkg.scripts?.[scriptName]) continue;
        } else {
          continue; // no package.json — not an npm project
        }
      }
      execSync(`command -v ${binary}`, { stdio: 'pipe' });
      return cmd;
    } catch { /* not found */ }
  }
  return null;
}

function runGate(gate: Gate): { command: string; output: string; exitCode: number } {
  // Detect which tool is available for each gate, in priority order
  const gateCandidates: Partial<Record<Gate, string[]>> = {
    BUILD: ['npm run build', 'tsc --noEmit', 'python -m build', 'cargo build', 'go build ./...'],
    UNIT: ['npm test', 'pytest', 'cargo test', 'go test ./...'],
    LINT: ['npm run lint', 'ruff check .', 'eslint .', 'golangci-lint run'],
    SEC: ['npm audit --audit-level=high', 'pip-audit', 'cargo audit'],
  };

  const candidates = gateCandidates[gate];
  const detected = candidates ? detectCommand(candidates) : null;

  // Exit code 2 = gate not evaluated (no tool found) — distinct from pass (0) and fail (1)
  if (!detected) {
    const msg = candidates
      ? `Gate ${gate}: no tool found. Candidates checked: ${candidates.join(', ')}`
      : `Gate ${gate}: no automated check defined`;
    return { command: '', output: msg, exitCode: 2 };
  }

  let out = '';
  let exitCode = 0;

  try {
    out = execSync(detected, { stdio: ['pipe', 'pipe', 'pipe'] }).toString();
  } catch (e: unknown) {
    const err = e as { stdout?: Buffer; stderr?: Buffer; status?: number };
    out = [err.stdout?.toString(), err.stderr?.toString()].filter(Boolean).join('\n');
    exitCode = err.status ?? 1;
  }

  return { command: detected, output: out, exitCode };
}

// ── proof waive ───────────────────────────────────────────────────────────────

const waiveCommand = new Command('waive')
  .description('Waive a requirement temporarily')
  .argument('<req-id>', 'The REQ ID to waive (e.g. REQ-0003)')
  .requiredOption('--reason <reason>', 'Why this cannot be satisfied now')
  .requiredOption('--expires-day <day>', 'Day number when waiver expires')
  .action(async (reqId: string, options: { reason: string; expiresDay: string }) => {
    requireInit();

    const reqs = readLedger();
    const idx = reqs.findIndex((r) => r.id === reqId.toUpperCase());

    if (idx === -1) {
      console.error(`${reqId} not found in requirements ledger.`);
      process.exit(1);
    }

    const expiresDay = parseInt(options.expiresDay, 10);
    if (isNaN(expiresDay) || expiresDay <= 0) {
      console.error(`Invalid --expires-day: must be a positive integer (e.g. --expires-day 12).`);
      process.exit(1);
    }
    const day = currentDay();
    if (expiresDay <= day) {
      console.error(`--expires-day ${expiresDay} is already past (current day: ${day}).`);
      process.exit(1);
    }

    reqs[idx] = {
      ...reqs[idx],
      status: 'waived',
      waiverReason: options.reason,
      waiverExpires: `Day ${expiresDay}`,
    };

    writeLedger(reqs);
    console.log(`${reqId} waived until Day ${expiresDay}`);
    console.log(`  Reason: ${options.reason}`);
  });

// ── proof status ──────────────────────────────────────────────────────────────

const statusCommand = new Command('status')
  .description('Show proof obligation summary')
  .action(async () => {
    requireInit();

    const reqs = readLedger();
    const day = currentDay();
    const reinstated = reinstateLapsedWaivers(reqs, day);

    // Persist any waivers that were reinstated due to expiry
    if (reinstated.some((r, i) => r.status !== reqs[i]?.status)) {
      writeLedger(reinstated);
    }

    const counts: Record<ReqStatus, number> = { open: 0, satisfied: 0, regressed: 0, waived: 0 };
    for (const req of reinstated) counts[req.status]++;

    const total = reinstated.length;

    const data = {
      total,
      open: counts.open,
      satisfied: counts.satisfied,
      regressed: counts.regressed,
      waived: counts.waived,
    };

    const pct = (n: number): string => (total > 0 ? `${Math.round((n / total) * 100)}%` : '—');

    const humanReadable = [
      'proof status',
      `  Total:     ${total}`,
      `  Satisfied: ${counts.satisfied} (${pct(counts.satisfied)})`,
      `  Open:      ${counts.open} (${pct(counts.open)})`,
      `  Regressed: ${counts.regressed} (${pct(counts.regressed)})`,
      `  Waived:    ${counts.waived} (${pct(counts.waived)})`,
      counts.regressed > 0 ? '\n  WARNING: Regressions detected — fix before committing.' : '',
    ]
      .filter(Boolean)
      .join('\n');

    output(data, humanReadable);

    if (counts.regressed > 0) process.exit(1);
  });

// ── proof list ────────────────────────────────────────────────────────────────

const listCommand = new Command('list')
  .description('List all requirements')
  .option('--status <status>', 'Filter by status: open|satisfied|regressed|waived')
  .action(async (options: { status?: string }) => {
    requireInit();

    let reqs = readLedger();
    if (options.status) {
      reqs = reqs.filter((r) => r.status === options.status);
    }

    if (reqs.length === 0) {
      console.log(options.status ? `No ${options.status} requirements.` : 'No requirements in ledger.');
      return;
    }

    console.log(`\n${'ID'.padEnd(10)} ${'Status'.padEnd(12)} ${'Severity'.padEnd(10)} ${'Obligations'.padEnd(30)} Title`);
    console.log('─'.repeat(90));
    for (const req of reqs) {
      const id = req.id.padEnd(10);
      const status = req.status.padEnd(12);
      const sev = req.severity.padEnd(10);
      const obs = `[${req.obligations.join(', ')}]`.padEnd(30);
      console.log(`${id} ${status} ${sev} ${obs} ${req.title}`);
    }
    console.log('');
  });

// ── proof show ────────────────────────────────────────────────────────────────

const showCommand = new Command('show')
  .description('Show full details for a requirement')
  .argument('<req-id>', 'The REQ ID to show')
  .action(async (reqId: string) => {
    requireInit();

    const reqs = readLedger();
    const req = reqs.find((r) => r.id === reqId.toUpperCase());

    if (!req) {
      console.error(`${reqId} not found.`);
      process.exit(1);
    }

    console.log(`\n## ${req.id}: ${req.title}`);
    console.log(`  Source:      ${req.source}`);
    console.log(`  Severity:    ${req.severity}`);
    console.log(`  Scope:       ${req.scope.join(', ')}`);
    console.log(`  Obligations: [${req.obligations.join(', ')}]`);
    console.log(`  Status:      ${req.status}`);
    console.log(`  Evidence:    ${req.evidence}`);
    if (req.satisfiedBy) console.log(`  Satisfied by: ${req.satisfiedBy}`);
    if (req.waiverReason) console.log(`  Waiver reason: ${req.waiverReason}`);
    if (req.waiverExpires) console.log(`  Waiver expires: ${req.waiverExpires}`);

    // List stored evidence artifacts
    const evDir = evidenceDir(req.id);
    if (fs.existsSync(evDir)) {
      const artifacts = fs.readdirSync(evDir).sort();
      if (artifacts.length > 0) {
        console.log('\n  Evidence artifacts:');
        for (const a of artifacts) {
          console.log(`    ${evDir}/${a}`);
        }
      }
    }
    console.log('');
  });

// ── Top-level proof command ───────────────────────────────────────────────────

export const proofCommand = new Command('proof')
  .description('PROOF9 quality gates and requirements management')
  .addCommand(captureCommand)
  .addCommand(runCommand)
  .addCommand(waiveCommand)
  .addCommand(statusCommand)
  .addCommand(listCommand)
  .addCommand(showCommand);
