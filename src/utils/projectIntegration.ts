import fs from 'fs';
import path from 'path';
import { EVOLVE_DIR_NAME } from './paths';

/** Agent skill directories that operator skills are installed into, relative to the project. */
export const AGENT_SKILL_DIRS = ['.claude/skills', '.agents/skills'];

export const MANAGED_SECTION_BEGIN = '<!-- code-evolve:begin -->';
export const MANAGED_SECTION_END = '<!-- code-evolve:end -->';

/** Lines init, start and eject manage in the project's .gitignore. */
export const MANAGED_GITIGNORE_LINES = [
  '# code-evolve ephemeral files',
  `${EVOLVE_DIR_NAME}/ISSUES_TODAY.md`,
  `${EVOLVE_DIR_NAME}/ISSUE_RESPONSE.md`,
  `${EVOLVE_DIR_NAME}/.env`,
  `${EVOLVE_DIR_NAME}/.env*`,
  `${EVOLVE_DIR_NAME}/evolve.log`,
  `${EVOLVE_DIR_NAME}/schedule.json`,
  `${EVOLVE_DIR_NAME}/evidence/`,
];

const AGENTS_SECTION = `## code-evolve

This project evolves autonomously with code-evolve. Its engine and state live in \`${EVOLVE_DIR_NAME}/\`.

- Run a cycle from inside your session with the \`evolve-run\` skill, or \`npx code-evolve run\` headless.
- Don't edit the paths listed in \`${EVOLVE_DIR_NAME}/scripts/protected-paths.txt\` (IDENTITY.md, scripts/,
  skills/, the evolve workflows): the engine restores them after every agent call.
- \`${EVOLVE_DIR_NAME}/vision.md\` and \`${EVOLVE_DIR_NAME}/spec.md\` describe what is being built.`;

const sectionPattern = new RegExp(
  `\\n?${escapeRegExp(MANAGED_SECTION_BEGIN)}[\\s\\S]*?${escapeRegExp(MANAGED_SECTION_END)}\\n?`
);

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Returns `content` with the code-evolve section set to `section` (replaced if present, else appended). */
export function withManagedSection(content: string, section: string): string {
  const block = `${MANAGED_SECTION_BEGIN}\n${section}\n${MANAGED_SECTION_END}\n`;
  if (content.includes(MANAGED_SECTION_BEGIN)) {
    return content.replace(sectionPattern, (match) => (match.startsWith('\n') ? `\n${block}` : block));
  }
  if (content === '') return block;
  return `${content.endsWith('\n') ? content : `${content}\n`}\n${block}`;
}

/** Returns `content` without the code-evolve section and the blank line that separated it. */
export function withoutManagedSection(content: string): string {
  if (!content.includes(MANAGED_SECTION_BEGIN)) return content;
  return content.replace(sectionPattern, '').replace(/\n\n$/, '\n');
}

function operatorSkillNames(operatorSkillsDir: string): string[] {
  return fs
    .readdirSync(operatorSkillsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && fs.existsSync(path.join(operatorSkillsDir, entry.name, 'SKILL.md')))
    .map((entry) => entry.name);
}

/** Copies each operator skill into every agent skill directory, replacing earlier copies. */
export function installOperatorSkills(projectDir: string, operatorSkillsDir: string): string[] {
  const names = operatorSkillNames(operatorSkillsDir);
  for (const skillDir of AGENT_SKILL_DIRS) {
    for (const name of names) {
      const destination = path.join(projectDir, skillDir, name);
      fs.rmSync(destination, { recursive: true, force: true });
      fs.cpSync(path.join(operatorSkillsDir, name), destination, { recursive: true });
    }
  }
  return names;
}

/** Removes the operator skills init installed, and skill directories that end up empty. */
export function removeOperatorSkills(projectDir: string, operatorSkillsDir: string): void {
  const names = operatorSkillNames(operatorSkillsDir);
  for (const skillDir of AGENT_SKILL_DIRS) {
    for (const name of names) {
      fs.rmSync(path.join(projectDir, skillDir, name), { recursive: true, force: true });
    }
    removeIfEmpty(path.join(projectDir, skillDir));
    removeIfEmpty(path.dirname(path.join(projectDir, skillDir)));
  }
}

function removeIfEmpty(directory: string): void {
  if (fs.existsSync(directory) && fs.readdirSync(directory).length === 0) fs.rmdirSync(directory);
}

/**
 * Agent instruction files that should carry the code-evolve section: AGENTS.md always, and
 * CLAUDE.md when it exists without importing AGENTS.md (Claude Code then ignores AGENTS.md).
 */
function instructionFiles(projectDir: string): string[] {
  const files = [path.join(projectDir, 'AGENTS.md')];
  const claudeFile = path.join(projectDir, 'CLAUDE.md');
  if (fs.existsSync(claudeFile) && !fs.readFileSync(claudeFile, 'utf8').includes('@AGENTS.md')) files.push(claudeFile);
  return files;
}

export function upsertAgentInstructions(projectDir: string): void {
  for (const file of instructionFiles(projectDir)) {
    const content = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
    fs.writeFileSync(file, withManagedSection(content, AGENTS_SECTION));
  }
}

/** Removes the code-evolve section; deletes a file the section was the only content of. */
export function removeAgentInstructions(projectDir: string): void {
  for (const name of ['AGENTS.md', 'CLAUDE.md']) {
    const file = path.join(projectDir, name);
    if (!fs.existsSync(file)) continue;
    const remaining = withoutManagedSection(fs.readFileSync(file, 'utf8'));
    if (remaining.trim() === '') fs.rmSync(file);
    else fs.writeFileSync(file, remaining);
  }
}
