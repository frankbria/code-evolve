import { Command } from 'commander';
import fs from 'fs';
import path from 'path';
import { spawnSync } from 'child_process';
import { compareVersions, evolveFile, isInitialized, packageVersion } from '../utils/paths';
import { readConfig } from '../utils/config';
import { runInit } from './init';

/**
 * True while another process holds the engine's run lock (the kernel flock hold_lock.py takes).
 * shortcut: checked, not held, so a cycle starting during the upgrade is not stopped; hold the lock
 * for the whole upgrade if that race ever matters.
 */
function cycleIsRunning(): boolean {
  const gitDir = spawnSync('git', ['rev-parse', '--absolute-git-dir'], { encoding: 'utf8' }).stdout.trim();
  const probe = spawnSync(
    'python3',
    ['-c', 'import fcntl,sys;f=open(sys.argv[1],"a");fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)', path.join(gitDir, 'code-evolve.lock')],
  );
  return probe.status !== 0;
}

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

    // A prepared or running cycle restores protected files from its start-of-session snapshot,
    // which would put the old engine back over the upgrade.
    if (fs.existsSync(evolveFile('run'))) {
      console.error('An in-session cycle is prepared (.evolve/run/). Finish it with `bash .evolve/scripts/evolve.sh finalize`, or remove .evolve/run to abandon it, then upgrade.');
      process.exit(1);
    }
    if (cycleIsRunning()) {
      console.error('A cycle is running (it holds the code-evolve run lock). Upgrade after it finishes.');
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
