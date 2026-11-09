import fs from 'fs';
import os from 'os';
import path from 'path';
import { MANAGED_SECTION_BEGIN, MANAGED_SECTION_END, installOperatorSkills, withManagedSection, withoutManagedSection } from '../projectIntegration';
import { getOperatorSkillsDir } from '../paths';

const section = 'code-evolve is installed in .evolve/.';

describe('withManagedSection', () => {
  it('creates the marked section in an empty file', () => {
    expect(withManagedSection('', section)).toBe(`${MANAGED_SECTION_BEGIN}\n${section}\n${MANAGED_SECTION_END}\n`);
  });

  it('appends after existing content, separated by a blank line', () => {
    expect(withManagedSection('# Project\n\nRules.\n', section)).toBe(
      `# Project\n\nRules.\n\n${MANAGED_SECTION_BEGIN}\n${section}\n${MANAGED_SECTION_END}\n`
    );
  });

  it('replaces an existing section in place, so re-running is idempotent', () => {
    const once = withManagedSection('# Project\n', section);
    const replaced = withManagedSection(`${once}\nAfter.\n`, 'new text');
    expect(replaced).toBe(`# Project\n\n${MANAGED_SECTION_BEGIN}\nnew text\n${MANAGED_SECTION_END}\n\nAfter.\n`);
    expect(withManagedSection(once, section)).toBe(once);
  });
});

describe('withoutManagedSection', () => {
  it('restores the original content exactly', () => {
    const original = '# Project\n\nRules.\n';
    expect(withoutManagedSection(withManagedSection(original, section))).toBe(original);
  });

  it('returns an empty string when the section was the whole file', () => {
    expect(withoutManagedSection(withManagedSection('', section))).toBe('');
  });

  it('leaves files without a section untouched', () => {
    expect(withoutManagedSection('# Project\n')).toBe('# Project\n');
  });
});

describe('installOperatorSkills', () => {
  it('skips a skill directory it cannot write (an agent sandbox) and reports only the ones it wrote', () => {
    const project = fs.mkdtempSync(path.join(os.tmpdir(), 'code-evolve-skills-'));
    fs.mkdirSync(path.join(project, '.agents'));
    fs.chmodSync(path.join(project, '.agents'), 0o555);
    try {
      const result = installOperatorSkills(project, getOperatorSkillsDir());
      expect(result.installedDirs).toEqual(['.claude/skills']);
      expect(result.skipped).toEqual([expect.stringMatching(/^\.agents\/skills \(not writable here: EACCES\)$/)]);
      expect(result.createdDirs).not.toContain('.agents/skills');
      expect(fs.existsSync(path.join(project, '.claude/skills/evolve-setup/SKILL.md'))).toBe(true);
    } finally {
      fs.chmodSync(path.join(project, '.agents'), 0o755);
      fs.rmSync(project, { recursive: true, force: true });
    }
  });
});
