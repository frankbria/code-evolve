import { Command } from 'commander';
import fs from 'fs';
import path from 'path';
import { getEvolveDir, getTemplatesDir, projectFile, evolveFile, isInitialized, EVOLVE_DIR_NAME } from '../utils/paths';
import { checkDependencies, formatDependencyResults } from '../utils/checks';
import { readConfig, writeConfig, isValidAgent, getAgentEnvHint, AuthMode } from '../utils/config';

// Files that contain user/agent evolution history — never overwrite
const PRESERVE_STATE_FILES = ['JOURNAL.md', 'LEARNINGS.md', 'DAY_COUNT', '.birth_date'];

export const initCommand = new Command('init')
  .description('Initialize .evolve/ in the current project')
  .option('--with-ci', 'Install GitHub Actions workflows')
  .option('--force', 'Overwrite existing .evolve/ directory')
  .option('--agent <name>', 'Agent backend to use (claude, codex, opencode, ollama)', 'claude')
  .option('--auth-mode <mode>', 'Auth mode for Claude: api-key or oauth', 'api-key')
  .action(async (options: { withCi?: boolean; force?: boolean; agent: string; authMode: string }) => {
    const evolveDir = getEvolveDir();
    const templatesDir = getTemplatesDir();

    // Resolve agent: use existing config on --force if --agent not explicitly passed
    const existingConfig = options.force ? readConfig() : { agent: 'claude' };
    const agent = options.agent !== 'claude' ? options.agent : existingConfig.agent || 'claude';

    if (!isValidAgent(agent)) {
      console.error(`Unknown agent "${agent}". Supported: claude, codex, opencode, ollama`);
      process.exit(1);
    }

    // Resolve auth mode
    let authMode: AuthMode = 'api-key';
    if (options.authMode === 'oauth') {
      if (agent !== 'claude') {
        console.warn(`Warning: --auth-mode oauth is only applicable to the Claude agent. Falling back to api-key.`);
      } else {
        authMode = 'oauth';
      }
    } else if (options.authMode !== 'api-key') {
      console.error(`Unknown auth mode "${options.authMode}". Supported: api-key, oauth`);
      process.exit(1);
    }

    // On --force, preserve existing authMode if --auth-mode wasn't explicitly passed
    if (options.force && options.authMode === 'api-key' && existingConfig.authMode) {
      authMode = existingConfig.authMode;
    }

    // Check dependencies
    console.log('Checking dependencies...');
    const { ok, results } = checkDependencies(agent);
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

    // Migrate root-level vision.md/spec.md into .evolve/ (0.1.x upgrade path)
    if (options.force) {
      for (const file of ['vision.md', 'spec.md']) {
        const rootPath = projectFile(file);
        const evolvePath = evolveFile(file);
        if (fs.existsSync(rootPath) && !fs.existsSync(evolvePath)) {
          fs.renameSync(rootPath, evolvePath);
          console.log(`  Moved ${file} → .evolve/${file} (migration from 0.1.x)`);
        } else if (fs.existsSync(rootPath) && fs.existsSync(evolvePath)) {
          console.log(`  Warning: ${file} exists at both root and .evolve/ — using .evolve/ version (root copy is now unused)`);
        }
      }
    }

    // Copy state files (skip if they already exist — these contain evolution history)
    const allStateFiles = ['IDENTITY.md', 'vision.md', 'spec.md', ...PRESERVE_STATE_FILES];
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
    // Set executable permissions on agent adapters
    const agentsDir = path.join(evolveDir, 'scripts', 'agents');
    if (fs.existsSync(agentsDir)) {
      for (const file of fs.readdirSync(agentsDir)) {
        if (file.endsWith('.sh')) {
          fs.chmodSync(path.join(agentsDir, file), 0o755);
        }
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

    // Write agent config
    const currentConfig = readConfig();
    writeConfig({ ...currentConfig, agent, authMode });
    if (agent !== 'claude') {
      console.log(`  Agent: ${agent}`);
    }
    if (authMode === 'oauth') {
      console.log(`  Auth: OAuth (claude login)`);
    }

    console.log('');
    console.log('code-evolve initialized.');
    console.log('');
    console.log('Next steps:');
    console.log('  1. Edit .evolve/vision.md with your project vision');
    console.log('  2. Edit .evolve/spec.md with your technical specification');
    console.log(`  3. ${getAgentEnvHint(agent, authMode)}`);
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
