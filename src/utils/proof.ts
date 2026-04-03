import fs from 'fs';
import path from 'path';
import { minimatch } from 'minimatch';
import { requirementsFile, evidenceDir, currentDay, shortCommit } from './paths';

// ── Types ──────────────────────────────────────────────────────────────────────

export type Gate = 'UNIT' | 'BUILD' | 'LINT' | 'CONTRACT' | 'E2E' | 'SEC' | 'PERF' | 'DEMO' | 'MANUAL';
export type ReqStatus = 'open' | 'satisfied' | 'regressed' | 'waived';
export type Severity = 'critical' | 'high' | 'medium' | 'low';

export interface Req {
  id: string;
  title: string;
  source: string;
  severity: Severity;
  scope: string[];
  obligations: Gate[];
  evidence: string;
  status: ReqStatus;
  satisfiedBy?: string;
  waiverReason?: string;
  waiverExpires?: string;
}

// ── Ledger parse/serialize ─────────────────────────────────────────────────────

export function parseRequirements(content: string): Req[] {
  const reqs: Req[] = [];
  // Split on REQ headings
  const blocks = content.split(/^## (REQ-\d{4}: .+)$/m);

  for (let i = 1; i < blocks.length; i += 2) {
    const heading = blocks[i].trim();
    const body = blocks[i + 1] ?? '';

    const idMatch = heading.match(/^(REQ-\d{4}):\s*(.+)$/);
    if (!idMatch) continue;

    const id = idMatch[1];
    const title = idMatch[2].trim();

    const get = (field: string): string => {
      const m = body.match(new RegExp(`\\*\\*${field}\\*\\*:\\s*(.+)`));
      return m ? m[1].trim() : '';
    };

    const scopeRaw = get('Scope');
    const scope = scopeRaw
      ? scopeRaw.split(',').map((s) => s.trim()).filter(Boolean)
      : [];

    const validGates: Gate[] = ['UNIT', 'BUILD', 'LINT', 'CONTRACT', 'E2E', 'SEC', 'PERF', 'DEMO', 'MANUAL'];
    const validStatuses: ReqStatus[] = ['open', 'satisfied', 'regressed', 'waived'];
    const validSeverities: Severity[] = ['critical', 'high', 'medium', 'low'];

    const obligationsRaw = get('Obligations');
    const obligations = obligationsRaw
      .replace(/[\[\]]/g, '')
      .split(',')
      .map((g) => g.trim())
      .filter((g): g is Gate => validGates.includes(g as Gate));

    const rawStatus = get('Status');
    const status: ReqStatus = validStatuses.includes(rawStatus as ReqStatus) ? (rawStatus as ReqStatus) : 'open';

    const rawSeverity = get('Severity');
    const severity: Severity = validSeverities.includes(rawSeverity as Severity) ? (rawSeverity as Severity) : 'high';

    reqs.push({
      id,
      title,
      source: get('Source'),
      severity,
      scope,
      obligations,
      evidence: get('Evidence'),
      status,
      satisfiedBy: get('Satisfied by') || undefined,
      waiverReason: get('Waiver reason') || undefined,
      waiverExpires: get('Waiver expires') || undefined,
    });
  }

  return reqs;
}

export function serializeRequirements(reqs: Req[]): string {
  const header = `# Requirements Ledger

<!-- REQ states: open | satisfied | regressed | waived -->
<!-- Severity:   critical | high | medium | low -->
<!-- Gates:      UNIT | BUILD | LINT | CONTRACT | E2E | SEC | PERF | DEMO | MANUAL -->

`;

  if (reqs.length === 0) return header.trimEnd() + '\n';

  const blocks = reqs.map((req) => {
    const lines = [
      `## ${req.id}: ${req.title}`,
      `- **Source**: ${req.source}`,
      `- **Severity**: ${req.severity}`,
      `- **Scope**: ${req.scope.join(', ') || '*'}`,
      `- **Obligations**: [${req.obligations.join(', ')}]`,
      `- **Evidence**: ${req.evidence || '(none yet)'}`,
      `- **Status**: ${req.status}`,
    ];
    if (req.satisfiedBy) lines.push(`- **Satisfied by**: ${req.satisfiedBy}`);
    if (req.waiverReason) lines.push(`- **Waiver reason**: ${req.waiverReason}`);
    if (req.waiverExpires) lines.push(`- **Waiver expires**: ${req.waiverExpires}`);
    return lines.join('\n');
  });

  return header + blocks.join('\n\n') + '\n';
}

export function nextReqId(reqs: Req[]): string {
  let max = 0;
  for (const req of reqs) {
    const n = parseInt(req.id.replace('REQ-', ''), 10);
    if (n > max) max = n;
  }
  return `REQ-${String(max + 1).padStart(4, '0')}`;
}

export function createReq(fields: Partial<Req> & { id: string; title: string }): Req {
  return {
    source: 'manual',
    severity: 'high',
    scope: ['*'],
    obligations: ['BUILD'],
    evidence: '(none yet)',
    status: 'open',
    ...fields,
  };
}

// ── Ledger I/O ────────────────────────────────────────────────────────────────

export function readLedger(): Req[] {
  const file = requirementsFile();
  if (!fs.existsSync(file)) return [];
  return parseRequirements(fs.readFileSync(file, 'utf8'));
}

export function writeLedger(reqs: Req[]): void {
  fs.writeFileSync(requirementsFile(), serializeRequirements(reqs));
}

// ── Gate assignment heuristics ─────────────────────────────────────────────────

export function assignGates(failureType: string, affectedFiles: string[]): Gate[] {
  const gates = new Set<Gate>();
  const lower = failureType.toLowerCase();

  if (lower.includes('build') || lower.includes('compile') || lower.includes('bundle')) {
    gates.add('BUILD');
  }
  if (lower.includes('test') || lower.includes('unit') || lower.includes('spec') || lower.includes('assert')) {
    gates.add('UNIT');
  }
  if (lower.includes('lint') || lower.includes('style') || lower.includes('format')) {
    gates.add('LINT');
  }
  if (lower.includes('api') || lower.includes('endpoint') || lower.includes('contract') || lower.includes('route')) {
    gates.add('CONTRACT');
  }
  if (lower.includes('e2e') || lower.includes('end-to-end') || lower.includes('flow') || lower.includes('browser')) {
    gates.add('E2E');
  }
  if (lower.includes('security') || lower.includes('vulner') || lower.includes('audit') || lower.includes('inject')) {
    gates.add('SEC');
  }
  if (lower.includes('perf') || lower.includes('slow') || lower.includes('latency') || lower.includes('benchmark')) {
    gates.add('PERF');
  }
  if (lower.includes('demo') || lower.includes('feature') || lower.includes('spec') || lower.includes('visible')) {
    gates.add('DEMO');
  }

  // File-based heuristics
  const hasApiFile = affectedFiles.some((f) => /route|endpoint|api|controller/i.test(f));
  if (hasApiFile) gates.add('CONTRACT');

  const hasSqlFile = affectedFiles.some((f) => f.endsWith('.sql'));
  if (hasSqlFile) gates.add('UNIT');

  // Default: if nothing matched, assume BUILD + UNIT
  if (gates.size === 0) {
    gates.add('BUILD');
    gates.add('UNIT');
  }

  return Array.from(gates);
}

// ── Scope selector engine ─────────────────────────────────────────────────────

type ScopePattern = { type: 'glob' | 'route'; pattern: string };

export function parseScopePattern(pattern: string): ScopePattern {
  // Route patterns start with HTTP methods
  if (/^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+\//i.test(pattern)) {
    return { type: 'route', pattern };
  }
  return { type: 'glob', pattern };
}

export function matchesScope(changedFiles: string[], scopePatterns: string[]): boolean {
  if (scopePatterns.includes('*') || scopePatterns.length === 0) return true;

  for (const raw of scopePatterns) {
    const parsed = parseScopePattern(raw);
    if (parsed.type === 'glob') {
      for (const file of changedFiles) {
        if (minimatch(file, parsed.pattern, { matchBase: true })) return true;
        // Also try without leading ./
        const normalized = file.startsWith('./') ? file.slice(2) : file;
        if (minimatch(normalized, parsed.pattern, { matchBase: true })) return true;
      }
    } else {
      // Route pattern: match files in route/api directories whose path component matches
      const [, routePath] = parsed.pattern.split(/\s+/, 2);
      const segments = routePath.split('/').filter(Boolean); // e.g. ['auth', 'login']
      for (const file of changedFiles) {
        const fileParts = file.split(/[/\\]/).map((p) => p.toLowerCase());
        // Match if any route segment exactly matches a path component of the file
        if (segments.some((seg) => fileParts.includes(seg.toLowerCase()))) return true;
      }
    }
  }

  return false;
}

export function filterReqsByScope(reqs: Req[], changedFiles: string[]): Req[] {
  return reqs.filter((req) => matchesScope(changedFiles, req.scope));
}

// ── Waiver logic ──────────────────────────────────────────────────────────────

export function isWaiverExpired(req: Req, currentDay: number): boolean {
  if (req.status !== 'waived' || !req.waiverExpires) return false;
  const dayMatch = req.waiverExpires.match(/Day\s+(\d+)/i);
  if (dayMatch) return currentDay > parseInt(dayMatch[1], 10);
  // Try date comparison
  const expiryDate = new Date(req.waiverExpires);
  if (!isNaN(expiryDate.getTime())) return new Date() > expiryDate;
  return false;
}

export function reinstateLapsedWaivers(reqs: Req[], currentDay: number): Req[] {
  return reqs.map((req) => {
    if (req.status === 'waived' && isWaiverExpired(req, currentDay)) {
      const { waiverReason: _r, waiverExpires: _e, satisfiedBy: _s, ...rest } = req;
      return { ...rest, status: 'open' as ReqStatus, evidence: '(none yet)' };
    }
    return req;
  });
}

// ── Evidence artifact storage ─────────────────────────────────────────────────

export function writeEvidence(
  reqId: string,
  gate: Gate,
  command: string,
  output: string,
  exitCode: number
): string {
  const dir = evidenceDir(reqId);
  fs.mkdirSync(dir, { recursive: true });

  const day = currentDay();
  const commit = shortCommit();
  const timestamp = new Date().toISOString();
  // Include seconds-level timestamp suffix to prevent overwrite on repeated runs
  const timeSuffix = timestamp.replace(/[:.]/g, '').slice(0, 15); // e.g. 20260403T035306
  const filename = `day${day}-${commit}-${gate.toLowerCase()}-${timeSuffix}.txt`;
  const artifactPath = path.join(dir, filename);

  // Truncate output to last 500 lines
  const lines = output.split('\n');
  const truncated = lines.length > 500 ? lines.slice(-500).join('\n') : output;

  const content = [
    `Gate: ${gate}`,
    `Command: ${command}`,
    `Exit code: ${exitCode}`,
    `Timestamp: ${timestamp}`,
    `Day: ${day}`,
    `Commit: ${commit}`,
    '',
    'Output (last 500 lines):',
    truncated,
  ].join('\n');

  fs.writeFileSync(artifactPath, content);
  return artifactPath;
}

export function updateReqEvidence(req: Req, artifactPath: string): Req {
  return { ...req, evidence: artifactPath };
}

// ── Test stub generation ──────────────────────────────────────────────────────

export function generateTestStub(reqId: string, obligations: Gate[], affectedFiles: string[]): string {
  const stubs: string[] = [];

  const firstFile = affectedFiles[0] ?? 'unknown';
  const title = reqId;

  for (const gate of obligations) {
    if (gate === 'UNIT') {
      stubs.push(`describe('${title}', () => {\n  it('should satisfy ${reqId} obligation (add assertions for ${firstFile})', () => {\n    expect(true).toBe(true);\n  });\n});`);
    } else if (gate === 'CONTRACT') {
      stubs.push(`describe('${title} API contract', () => {\n  it('${reqId} — API should return expected response shape', async () => {\n    // assert response status and shape for ${firstFile}\n  });\n});`);
    } else if (gate === 'E2E') {
      stubs.push(`describe('${title} user flow', () => {\n  it('${reqId} — user flow completes end-to-end', async () => {\n    // drive browser/CLI through the affected flow\n  });\n});`);
    }
  }

  return stubs.join('\n\n');
}
