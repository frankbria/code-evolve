import fs from 'fs';
import os from 'os';
import path from 'path';
import { createReq, readLedger, writeLedger } from '../proof';
import { getTemplatesDir } from '../paths';

describe('writeLedger', () => {
  const originalDirectory = process.cwd();
  let ledgerPath: string;

  beforeEach(() => {
    const project = fs.mkdtempSync(path.join(os.tmpdir(), 'proof-ledger-'));
    fs.mkdirSync(path.join(project, '.evolve'));
    ledgerPath = path.join(project, '.evolve', 'REQUIREMENTS.md');
    process.chdir(project);
  });

  afterEach(() => {
    process.chdir(originalDirectory);
    fs.rmSync(path.dirname(path.dirname(ledgerPath)), { recursive: true, force: true });
  });

  const template = () => fs.readFileSync(path.join(getTemplatesDir(), 'state', 'REQUIREMENTS.md'), 'utf8');
  const firstRequirement = createReq({ id: 'REQ-0001', title: 'first' });
  const secondRequirement = createReq({ id: 'REQ-0002', title: 'second' });

  it("keeps the template's comment block when the first requirement is written", () => {
    fs.writeFileSync(ledgerPath, template());
    writeLedger([firstRequirement]);
    const written = fs.readFileSync(ledgerPath, 'utf8');
    expect(written.startsWith(template().trimEnd() + '\n\n## REQ-0001: first\n')).toBe(true);
    expect(readLedger()).toEqual([firstRequirement]);
  });

  it('keeps it across later rewrites without growing the file', () => {
    fs.writeFileSync(ledgerPath, template());
    writeLedger([firstRequirement]);
    const afterFirstWrite = fs.readFileSync(ledgerPath, 'utf8');
    writeLedger([firstRequirement]);
    expect(fs.readFileSync(ledgerPath, 'utf8')).toBe(afterFirstWrite);
    writeLedger([firstRequirement, secondRequirement]);
    const afterSecondWrite = fs.readFileSync(ledgerPath, 'utf8');
    expect(afterSecondWrite.startsWith(afterFirstWrite + '\n## REQ-0002: second\n')).toBe(true);
    expect(afterSecondWrite.split('REQs are created automatically from:')).toHaveLength(2);
  });

  it("keeps a user's own notes above the requirements", () => {
    fs.writeFileSync(ledgerPath, '# Requirements Ledger\n\nOur team reviews waivers on Mondays.\n\n## REQ-0001: first\n- **Status**: open\n');
    writeLedger(readLedger());
    expect(fs.readFileSync(ledgerPath, 'utf8')).toContain('# Requirements Ledger\n\nOur team reviews waivers on Mondays.\n\n## REQ-0001: first\n');
  });

  it('writes the standard header when the ledger is missing or has nothing above the requirements', () => {
    writeLedger([firstRequirement]);
    expect(fs.readFileSync(ledgerPath, 'utf8')).toMatch(/^# Requirements Ledger\n\n<!-- REQ states: [^\n]+\n<!-- Severity: [^\n]+\n<!-- Gates: [^\n]+\n\n## REQ-0001: first\n/);
    fs.writeFileSync(ledgerPath, '## REQ-0001: first\n- **Status**: open\n');
    writeLedger(readLedger());
    expect(fs.readFileSync(ledgerPath, 'utf8')).toMatch(/^# Requirements Ledger\n/);
  });

  it("keeps the text a user wrote under a requirement, with its own fields and headings", () => {
    const ledger = [
      '# Requirements Ledger',
      '',
      '## REQ-0001: first',
      '- **Source**: manual',
      '- **Status**: open',
      '- **Owner**: the payments team',
      '',
      'Reproduce with `npm run slow-test`; see the 2026-10 incident notes.',
      '',
      '## REQ-0002: second',
      '- **Status**: open',
      '',
      '### Follow-up',
      'Ask before waiving this one.',
      '',
    ].join('\n');
    fs.writeFileSync(ledgerPath, ledger);
    const requirements = readLedger();
    expect(requirements[0].notes).toBe('- **Owner**: the payments team\n\nReproduce with `npm run slow-test`; see the 2026-10 incident notes.');
    writeLedger(requirements.map((requirement) => ({ ...requirement, status: 'satisfied' as const })));
    const written = fs.readFileSync(ledgerPath, 'utf8');
    expect(written).toContain(
      '- **Status**: satisfied\n\n- **Owner**: the payments team\n\nReproduce with `npm run slow-test`; see the 2026-10 incident notes.\n\n## REQ-0002: second\n',
    );
    expect(written.endsWith('- **Status**: satisfied\n\n### Follow-up\nAsk before waiving this one.\n')).toBe(true);
    writeLedger(readLedger());
    expect(fs.readFileSync(ledgerPath, 'utf8')).toBe(written);
  });

  it('moves a note written between two fields below them, and keeps a requirement without notes as it was', () => {
    fs.writeFileSync(ledgerPath, '## REQ-0001: first\n- **Source**: manual\nflaky on Windows only\n- **Status**: regressed\n\n## REQ-0002: second\n- **Status**: open\n');
    const requirements = readLedger();
    expect(requirements[1].notes).toBeUndefined();
    writeLedger(requirements);
    const written = fs.readFileSync(ledgerPath, 'utf8');
    expect(written).toContain('- **Status**: regressed\n\nflaky on Windows only\n\n## REQ-0002: second\n');
    expect(written.endsWith('## REQ-0002: second\n- **Source**: \n- **Severity**: high\n- **Scope**: *\n- **Obligations**: []\n- **Evidence**: (none yet)\n- **Status**: open\n')).toBe(true);
    // An empty field used to be read back as the line below it.
    expect(readLedger()[1].source).toBe('');
    writeLedger(readLedger());
    expect(fs.readFileSync(ledgerPath, 'utf8')).toBe(written);
  });

  it('reads the fields and notes of a ledger saved with Windows line endings', () => {
    fs.writeFileSync(ledgerPath, '## REQ-0001: first\r\n- **Severity**: low\r\n- **Status**: regressed\r\n\r\nseen on the build server\r\n');
    expect(readLedger()).toEqual([
      { ...firstRequirement, source: '', severity: 'low', scope: [], obligations: [], evidence: '', status: 'regressed', notes: 'seen on the build server' },
    ]);
  });

  it('takes the first value of a field that is written twice and keeps the other line', () => {
    fs.writeFileSync(ledgerPath, '## REQ-0001: first\n- **Status**: satisfied\n- **Status**: open\n');
    expect(readLedger()[0].status).toBe('satisfied');
    expect(readLedger()[0].notes).toBe('- **Status**: open');
    writeLedger(readLedger());
    const written = fs.readFileSync(ledgerPath, 'utf8');
    expect(written.endsWith('- **Status**: satisfied\n\n- **Status**: open\n')).toBe(true);
    writeLedger(readLedger());
    expect(fs.readFileSync(ledgerPath, 'utf8')).toBe(written);
  });

  it('leaves a fenced example alone, even one that looks like a field the requirement lacks', () => {
    const example = '```\n- **Waiver reason**: an example, not a waiver\n- **Status**: satisfied\n```';
    fs.writeFileSync(ledgerPath, `## REQ-0001: first\n- **Status**: open\n\n${example}\n`);
    const [requirement] = readLedger();
    expect(requirement).toMatchObject({ status: 'open', notes: example });
    expect(requirement.waiverReason).toBeUndefined();
    writeLedger([requirement]);
    expect(fs.readFileSync(ledgerPath, 'utf8').endsWith(`- **Status**: open\n\n${example}\n`)).toBe(true);
  });

  it('reads fields written as a numbered, plus-bulleted or quoted list, as it did before', () => {
    fs.writeFileSync(ledgerPath, '## REQ-0001: first\n1. **Severity**: low\n+ **Status**: satisfied\n> **Source**: manual\n**Evidence**: e1\n');
    expect(readLedger()[0]).toMatchObject({ severity: 'low', status: 'satisfied', source: 'manual', evidence: 'e1' });
    expect(readLedger()[0].notes).toBeUndefined();
  });

  it('leaves the header in place when the last requirement is removed', () => {
    fs.writeFileSync(ledgerPath, template());
    writeLedger([]);
    expect(fs.readFileSync(ledgerPath, 'utf8')).toBe(template().trimEnd() + '\n');
  });
});
