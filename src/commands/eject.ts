import { Command } from 'commander';
import { MANAGED_GITIGNORE_LINES, removeAgentInstructions, removeOperatorSkills } from '../utils/projectIntegration';
import { removeProjectCron } from '../utils/crontab';
import fs from 'fs';
import readline from 'readline';
import { getEvolveDir, getOperatorSkillsDir, projectFile, evolveFile, isInitialized } from '../utils/paths';

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
      let removed = false;
      try {
        removed = removeProjectCron(process.cwd());
      } catch (err) {
        // Abort before deleting anything: removing .evolve/ would leave a cron entry firing at missing scripts.
        console.error(`Could not update the crontab, so nothing was ejected: ${err instanceof Error ? err.message : String(err)}`);
        process.exit(1);
      }
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

    // Clean .gitignore entries (the same list init and start add)
    const gitignorePath = projectFile('.gitignore');
    if (fs.existsSync(gitignorePath)) {
      const managed = new Set(MANAGED_GITIGNORE_LINES);
      const kept = fs.readFileSync(gitignorePath, 'utf8').split('\n').filter((line) => !managed.has(line));
      const cleaned = kept.join('\n').replace(/\n{3,}/g, '\n\n');
      if (cleaned.trim() === '') {
        fs.rmSync(gitignorePath);
        console.log('Removed .gitignore (it only held code-evolve entries)');
      } else {
        fs.writeFileSync(gitignorePath, cleaned);
        console.log('Cleaned .gitignore');
      }
    }

    // Operator skills and the code-evolve section in AGENTS.md / CLAUDE.md
    removeOperatorSkills(process.cwd(), getOperatorSkillsDir());
    removeAgentInstructions(process.cwd());
    console.log('Removed code-evolve skills and agent instructions');

    console.log('');
    console.log('Ejected. vision.md and spec.md have been copied to the project root.');
  });

function confirm(question: string): Promise<boolean> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} [y/N] `, (answer) => {
      rl.close();
      resolve(answer.toLowerCase() === 'y' || answer.toLowerCase() === 'yes');
    });
  });
}
