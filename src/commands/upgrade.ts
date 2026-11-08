import { Command } from 'commander';
import { spawnSync } from 'child_process';
import { compareVersions, isInitialized, packageVersion } from '../utils/paths';
import { readConfig } from '../utils/config';
import { runInit } from './init';

/**
 * `code-evolve upgrade`: replace the managed engine files (scripts, runtime skills, IDENTITY.md,
 * operator skills, workflows) with this version's, keeping every user-owned file (vision, spec,
 * journal, learnings, requirements, counters, config). It is init's refresh behind a clean-tree check,
 * so the upgrade lands as one reviewable diff that `git checkout .` can undo.
 */
export const upgradeCommand = new Command('upgrade')
  .description("Update the installed engine to this version; your vision, spec, history and config are kept")
  .action(async () => {
    if (!isInitialized()) {
      console.error('Not initialized. Run `code-evolve init` first.');
      process.exit(1);
    }
    const status = spawnSync('git', ['status', '--porcelain'], { encoding: 'utf8' });
    if (status.status !== 0) {
      console.error('upgrade needs a git repository, so the upgrade can be reviewed and undone.');
      process.exit(1);
    }
    if (status.stdout.trim()) {
      console.error('Commit or stash your changes first: upgrade overwrites managed files, and a clean tree keeps it reviewable.');
      process.exit(1);
    }

    const config = readConfig();
    if (config.engineVersion && compareVersions(config.engineVersion, packageVersion()) > 0) {
      console.error(`The installed engine (${config.engineVersion}) is newer than this code-evolve (${packageVersion()}); run: npx code-evolve@latest upgrade`);
      process.exit(1);
    }
    console.log(`Upgrading the engine from ${config.engineVersion ?? 'an unrecorded version'} to ${packageVersion()}...\n`);
    await runInit({ yes: true, agent: config.agent, authMode: config.authMode ?? 'api-key' });
  });
