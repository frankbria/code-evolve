import { Command } from 'commander';
import { isInitialized } from '../utils/paths';
import { runInit, InitOptions } from './init';

/**
 * `code-evolve setup` — `init` that is **re-runnable**: on an already-initialized repo it
 * auto-enables --force so a second run reconfigures instead of erroring. init preserves
 * history/state files on --force, so re-running is safe (#26). Guided onboarding (vision,
 * spec, schedule) is the evolve-setup skill's job since its TTY wizard was retired (#97).
 */
export const setupCommand = new Command('setup')
  .description('Install or reconfigure code-evolve from flags (re-runnable init); the evolve-setup skill onboards')
  .option('--with-ci', 'Install GitHub Actions workflows')
  .option('--force', 'Reconfigure even if .evolve/ already exists')
  .option('--agent <name>', 'Agent backend to use (claude, codex, opencode, ollama, custom)', 'claude')
  .option('--agent-command <command>', 'For --agent custom: the headless command (prompt on stdin, or {prompt_file}; {model})')
  .option('--agent-error-pattern <regex>', 'For --agent custom: a log line matching this regex fails the session')
  .option('--agent-env <names>', 'For --agent custom: comma-separated environment variables its CLI needs (saved into the cron .env)')
  .option('--auth-mode <mode>', 'Auth mode: api-key, oauth (Claude login) or chatgpt (Codex login)', 'api-key')
  .option('--mode <mode>', 'Execution mode: local, ci, both, or native (the agent\'s own scheduler)')
  .option('--every <hours>', 'Evolution cadence in hours (1–24)')
  .action(async (options: InitOptions) => {
    console.log('🌱 code-evolve setup — installs or reconfigures code-evolve from your flags.');
    console.log('   To have your agent draft the vision and spec and pick a schedule, run `npx code-evolve`.\n');
    // Re-runnable: a second setup on an existing repo reconfigures rather than
    // aborting. init preserves JOURNAL/LEARNINGS/etc. under --force.
    if (isInitialized()) options.force = true;
    await runInit(options);
    console.log("\n✅ You're live — code-evolve is configured and ready.");
  });
