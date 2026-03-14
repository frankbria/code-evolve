import { Command } from 'commander';
import fs from 'fs';
import path from 'path';
import { getEvolveDir, getTemplatesDir, projectFile, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';
import { checkDependencies, formatDependencyResults } from '../utils/checks';

// Files that contain user/agent evolution history — never overwrite
const PRESERVE_STATE_FILES = ['JOURNAL.md', 'LEARNINGS.md', 'DAY_COUNT', '.birth_date'];

export const initCommand = new Command('init')
  .description('Initialize .evolve/ in the current project')
  .option('--with-ci', 'Install GitHub Actions workflows')
  .option('--force', 'Overwrite existing .evolve/ directory')
  .action(async (options: { withCi?: boolean; force?: boolean }) => {
    const evolveDir = getEvolveDir();
    const templatesDir = getTemplatesDir();

    // Check dependencies
    console.log('Checking dependencies...');
    const { ok, results } = checkDependencies();
    console.log(formatDependencyResults(results));

    if (!ok) {
      const missing = results.filter((r) => !r.found).map((r) => r.name);
      console.error(`\nMissing required dependencies: ${missing.join(', ')}`);
      console.error('Install them and try again.');
      process.exit(3);
    }
    console.log('');

    // Check if already initialized
    if (isInitialized() && !options.force) {
      console.error(`.evolve/ already exists. Use --force to overwrite.`);
      process.exit(1);
    }

    // Create .evolve/ directory structure
    console.log('Creating .evolve/ directory...');
    fs.mkdirSync(path.join(evolveDir, 'scripts'), { recursive: true });
    fs.mkdirSync(path.join(evolveDir, 'skills'), { recursive: true });

    // Copy scripts (always overwrite — these are framework code, not user data)
    copyDir(path.join(templatesDir, 'scripts'), path.join(evolveDir, 'scripts'));

    // Copy skills (always overwrite — framework definitions)
    copyDir(path.join(templatesDir, 'skills'), path.join(evolveDir, 'skills'));

    // Copy state files (skip if they already exist — these contain evolution history)
    const allStateFiles = ['IDENTITY.md', ...PRESERVE_STATE_FILES];
    for (const file of allStateFiles) {
      const src = path.join(templatesDir, 'state', file);
      const dest = path.join(evolveDir, file);
      if (!fs.existsSync(src)) continue;

      if (fs.existsSync(dest)) {
        console.log(`  ${file} already exists — preserving`);
      } else {
        fs.copyFileSync(src, dest);
      }
    }

    // Create .birth_date only if it doesn't exist
    const birthDatePath = path.join(evolveDir, '.birth_date');
    if (!fs.existsSync(birthDatePath)) {
      const today = new Date().toISOString().split('T')[0];
      fs.writeFileSync(birthDatePath, today + '\n');
    }

    // Set executable permissions on scripts
    const scripts = ['evolve.sh', 'detect_stack.sh'];
    for (const script of scripts) {
      const scriptPath = path.join(evolveDir, 'scripts', script);
      if (fs.existsSync(scriptPath)) {
        fs.chmodSync(scriptPath, 0o755);
      }
    }

    // Copy vision.md and spec.md to project root (only if they don't exist)
    for (const file of ['vision.md', 'spec.md']) {
      const dest = projectFile(file);
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(path.join(templatesDir, file), dest);
        console.log(`  Created ${file}`);
      } else {
        console.log(`  ${file} already exists — skipping`);
      }
    }

    // Install GitHub Actions workflows into namespaced subdirectory
    if (options.withCi) {
      console.log('Installing GitHub Actions workflows...');
      const workflowDir = projectFile('.github/workflows/evolve');
      fs.mkdirSync(workflowDir, { recursive: true });
      // Only copy workflow files that don't already exist
      copyDirSafe(path.join(templatesDir, 'workflows'), workflowDir);
    }

    // Update .gitignore (appends only if marker not already present)
    updateGitignore();

    console.log('');
    console.log('code-evolve initialized.');
    console.log('');
    console.log('Next steps:');
    console.log('  1. Edit vision.md with your project vision');
    console.log('  2. Edit spec.md with your technical specification');
    console.log('  3. Set ANTHROPIC_API_KEY environment variable');
    console.log('  4. Run: code-evolve run');
    if (!options.withCi) {
      console.log('');
      console.log('  To add GitHub Actions (auto-evolve every 4h):');
      console.log('    code-evolve init --with-ci --force');
    }
  });

/** Copy directory recursively, overwriting all files (for framework code). */
function copyDir(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

/** Copy directory recursively, skipping files that already exist. */
function copyDirSafe(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirSafe(srcPath, destPath);
    } else if (fs.existsSync(destPath)) {
      console.log(`  ${path.relative(process.cwd(), destPath)} already exists — skipping`);
    } else {
      fs.copyFileSync(srcPath, destPath);
      console.log(`  Created ${path.relative(process.cwd(), destPath)}`);
    }
  }
}

function updateGitignore(): void {
  const gitignorePath = projectFile('.gitignore');
  const linesToAdd = [
    `# code-evolve ephemeral files`,
    `${EVOLVE_DIR_NAME}/ISSUES_TODAY.md`,
    `${EVOLVE_DIR_NAME}/ISSUE_RESPONSE.md`,
    `${EVOLVE_DIR_NAME}/.env`,
    `${EVOLVE_DIR_NAME}/evolve.log`,
    `${EVOLVE_DIR_NAME}/schedule.json`,
  ];

  let content = '';
  if (fs.existsSync(gitignorePath)) {
    content = fs.readFileSync(gitignorePath, 'utf8');
  }

  // Check if already added
  if (content.includes(`${EVOLVE_DIR_NAME}/ISSUES_TODAY.md`)) {
    return;
  }

  const addition = '\n' + linesToAdd.join('\n') + '\n';
  fs.appendFileSync(gitignorePath, addition);
  console.log('  Updated .gitignore');
}
