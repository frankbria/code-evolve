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

  it('leaves the header in place when the last requirement is removed', () => {
    fs.writeFileSync(ledgerPath, template());
    writeLedger([]);
    expect(fs.readFileSync(ledgerPath, 'utf8')).toBe(template().trimEnd() + '\n');
  });
});
