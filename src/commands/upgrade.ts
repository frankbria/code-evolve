import { Command } from 'commander';
import fs from 'fs';
import path from 'path';
import os from 'os';
import { spawn, spawnSync } from 'child_process';
import { compareVersions, evolveFile, getTemplatesDir, isInitialized, packageVersion } from '../utils/paths';
import { readConfig } from '../utils/config';
import { runInit } from './init';

/**
 * Take the engine's run lock (the kernel flock hold_lock.py holds) for as long as this process lives,
 * so no cycle can start, snapshot the old engine and later restore it over the upgrade.
 */
async function holdRunLock(): Promise<'locked' | 'busy' | 'failed'> {
  const gitDir = spawnSync('git', ['rev-parse', '--absolute-git-dir'], { encoding: 'utf8' }).stdout.trim();
  // Private (0700) dir: the holder writes status.tmp next to the status file.
  const statusDir = fs.mkdtempSync(path.join(os.tmpdir(), 'code-evolve-upgrade-'));
  const statusFile = path.join(statusDir, 'status');
  const holder = spawn(
    'python3',
    [path.join(getTemplatesDir(), 'scripts', 'hold_lock.py'), path.join(gitDir, 'code-evolve.lock'), String(process.pid), statusFile],
    { stdio: 'ignore' },
  );
  holder.on('error', () => undefined);
  holder.unref();
  // Release the lock as soon as the upgrade ends, rather than at the holder's next once-a-second check.
  process.on('exit', () => holder.kill());
  for (let attempt = 0; attempt < 50 && !fs.existsSync(statusFile); attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const status = fs.existsSync(statusFile) ? fs.readFileSync(statusFile, 'utf8').trim() : '';
  fs.rmSync(statusDir, { recursive: true, force: true });
  return status === 'locked' || status === 'busy' ? status : 'failed';
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
    // which would put the old engine back over the upgrade. Holding the lock keeps new cycles out.
    const lock = await holdRunLock();
    if (lock === 'busy') {
      console.error('A cycle is running (it holds the code-evolve run lock). Upgrade after it finishes.');
      process.exit(1);
    }
    if (lock === 'failed') {
      console.error('Could not take the code-evolve run lock (is python3 installed?), so the upgrade was not started.');
      process.exit(1);
    }
    if (fs.existsSync(evolveFile('run'))) {
      console.error('An in-session cycle is prepared (.evolve/run/). Finish it with `bash .evolve/scripts/evolve.sh finalize`, or remove .evolve/run to abandon it, then upgrade.');
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
