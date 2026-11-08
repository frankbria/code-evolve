import { MANAGED_SECTION_BEGIN, MANAGED_SECTION_END, withManagedSection, withoutManagedSection } from '../projectIntegration';

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
