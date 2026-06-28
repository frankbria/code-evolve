import { Command } from 'commander';
import { execSync } from 'child_process';
import fs from 'fs';
import readline from 'readline';
import { getEvolveDir, projectFile, evolveFile, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';

const CRON_MARKER = 'code-evolve';
// Stable marker embedded in the workflow templates so eject recognizes files it
// installed regardless of which package version wrote them (kept in sync with
// templates/workflows/*.yml). A user's own same-named workflow won't contain it.
const WORKFLOW_MARKER = 'code-evolve:managed';

export const ejectCommand = new Command('eject')
  .description('Remove code-evolve framework, keep project files')
  .option('--yes', 'Skip confirmation prompt')
  .action(async (options: { yes?: boolean }) => {
    if (!isInitialized()) {
      console.error('Not initialized — nothing to eject.');
      process.exit(1);
    }

    if (!options.yes) {
      const confirmed = await confirm(
        'This will stop the engine, remove .evolve/ and workflows. vision.md and spec.md will be copied to the project root. Continue?'
      );
      if (!confirmed) {
        console.log('Aborted.');
        process.exit(0);
      }
    }

    // Stop cron job if running
    if (process.platform !== 'win32') {
      const removed = removeCron(process.cwd());
      if (removed) {
        console.log('Stopped evolution engine (cron job removed).');
      }
    }

    // Copy vision.md and spec.md to project root before removal
    for (const file of ['vision.md', 'spec.md']) {
      const src = evolveFile(file);
      if (fs.existsSync(src)) {
        const dest = projectFile(file);
        if (fs.existsSync(dest)) {
          console.log(`  ${file} already exists at project root — skipping (kept .evolve/${file} content in .evolve/)`);
        } else {
          fs.copyFileSync(src, dest);
          console.log(`  Copied .evolve/${file} → ${file}`);
        }
      }
    }

    // Remove .evolve/
    const evolveDir = getEvolveDir();
    fs.rmSync(evolveDir, { recursive: true, force: true });
    console.log('Removed .evolve/');

    // Remove only the workflow files we installed. init skips same-named files it didn't
    // create, so eject must do the same — recognize ours by the embedded marker (stable
    // across package versions), never removing a user's own evolve.yml/evolve-ci.yml.
    for (const wf of ['.github/workflows/evolve.yml', '.github/workflows/evolve-ci.yml']) {
      const wfPath = projectFile(wf);
      if (!fs.existsSync(wfPath)) continue;
      const isOurs = fs.readFileSync(wfPath, 'utf8').includes(WORKFLOW_MARKER);
      if (isOurs) {
        fs.rmSync(wfPath, { force: true });
        console.log(`Removed ${wf}`);
      } else {
        console.log(`  ${wf} is not code-evolve-managed — leaving in place`);
      }
    }
    // We deliberately do NOT auto-remove a legacy .github/workflows/evolve/ subdir from
    // pre-relocation installs: those nested files never executed (GitHub ignores subdirs),
    // so they're inert, and we can't prove ownership of a user dir named evolve/ without
    // risking data loss. If present, tell the user so they can delete it themselves.
    const legacyWorkflowDir = projectFile('.github/workflows/evolve');
    if (fs.existsSync(legacyWorkflowDir)) {
      console.log('  Note: a legacy .github/workflows/evolve/ directory exists (inert) — remove it manually if it was code-evolve\'s.');
    }

    // Clean .gitignore entries
    const gitignorePath = projectFile('.gitignore');
    if (fs.existsSync(gitignorePath)) {
      let content = fs.readFileSync(gitignorePath, 'utf8');
      const linesToRemove = [
        `# code-evolve ephemeral files`,
        `${EVOLVE_DIR_NAME}/ISSUES_TODAY.md`,
        `${EVOLVE_DIR_NAME}/ISSUE_RESPONSE.md`,
        `${EVOLVE_DIR_NAME}/.env`,
        `${EVOLVE_DIR_NAME}/evolve.log`,
        `${EVOLVE_DIR_NAME}/schedule.json`,
      ];
      for (const line of linesToRemove) {
        content = content.replace(line + '\n', '');
      }
      fs.writeFileSync(gitignorePath, content);
    }

    console.log('');
    console.log('Ejected. vision.md and spec.md have been copied to the project root.');
  });

function removeCron(projectDir: string): boolean {
  try {
    const existing = execSync('crontab -l 2>/dev/null', { encoding: 'utf8' });
    if (!existing) return false;

    const marker = `${CRON_MARKER}:${projectDir}`;
    const lines = existing.split('\n');
    const filtered = lines.filter((line) => !line.includes(marker));
    if (filtered.length === lines.length) return false;

    const cleaned = filtered.join('\n').replace(/\n{3,}/g, '\n\n');
    execSync(`echo ${JSON.stringify(cleaned)} | crontab -`, { encoding: 'utf8' });
    return true;
  } catch {
    return false;
  }
}

function confirm(question: string): Promise<boolean> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} [y/N] `, (answer) => {
      rl.close();
      resolve(answer.toLowerCase() === 'y' || answer.toLowerCase() === 'yes');
    });
  });
}
