import { Command } from 'commander';
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import readline from 'readline';
import { getEvolveDir, getTemplatesDir, projectFile, evolveFile, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';

const CRON_MARKER = 'code-evolve';

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
    // create, so eject must do the same — verify ownership by comparing against the shipped
    // template before deleting, never removing a user's own evolve.yml/evolve-ci.yml.
    const templatesDir = getTemplatesDir();
    const installedWorkflows: Array<[string, string]> = [
      ['.github/workflows/evolve.yml', path.join(templatesDir, 'workflows', 'evolve.yml')],
      ['.github/workflows/evolve-ci.yml', path.join(templatesDir, 'workflows', 'ci.yml')],
    ];
    for (const [wf, templatePath] of installedWorkflows) {
      const wfPath = projectFile(wf);
      if (!fs.existsSync(wfPath)) continue;
      const isOurs =
        fs.existsSync(templatePath) &&
        fs.readFileSync(wfPath, 'utf8') === fs.readFileSync(templatePath, 'utf8');
      if (isOurs) {
        fs.rmSync(wfPath, { force: true });
        console.log(`Removed ${wf}`);
      } else {
        console.log(`  ${wf} differs from template — leaving in place`);
      }
    }
    // Clean up the legacy .github/workflows/evolve/ subdir from older installs — but only
    // if it holds just the files old versions put there (evolve.yml/ci.yml), so we never
    // delete a user-owned directory that happens to be named evolve/.
    const legacyWorkflowDir = projectFile('.github/workflows/evolve');
    if (fs.existsSync(legacyWorkflowDir)) {
      const entries = fs.readdirSync(legacyWorkflowDir);
      const ours = entries.length > 0 && entries.every((e) => e === 'evolve.yml' || e === 'ci.yml');
      if (ours) {
        fs.rmSync(legacyWorkflowDir, { recursive: true, force: true });
        console.log('Removed .github/workflows/evolve/ (legacy)');
      } else {
        console.log('  .github/workflows/evolve/ has unexpected contents — leaving in place');
      }
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
