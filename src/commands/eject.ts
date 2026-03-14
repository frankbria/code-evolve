import { Command } from 'commander';
import { execSync } from 'child_process';
import fs from 'fs';
import readline from 'readline';
import { getEvolveDir, projectFile, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';

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
        'This will stop the engine, remove .evolve/ and workflows. vision.md and spec.md will be kept. Continue?'
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

    // Remove .evolve/
    const evolveDir = getEvolveDir();
    fs.rmSync(evolveDir, { recursive: true, force: true });
    console.log('Removed .evolve/');

    // Remove evolve workflow directory
    const evolveWorkflowDir = projectFile('.github/workflows/evolve');
    if (fs.existsSync(evolveWorkflowDir)) {
      fs.rmSync(evolveWorkflowDir, { recursive: true, force: true });
      console.log('Removed .github/workflows/evolve/');
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
    console.log('Ejected. vision.md and spec.md are preserved.');
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
