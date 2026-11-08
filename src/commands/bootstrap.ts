import fs from 'fs';
import path from 'path';
import readline from 'readline/promises';
import { spawnSync } from 'child_process';

/** How each interactive agent CLI is started with the evolve-setup skill as its first prompt. */
export const SETUP_LAUNCH_ARGS: Record<string, string[]> = {
  claude: ['/evolve-setup'],
  codex: ['$evolve-setup'],
  // OpenCode has no skill slash-command; its model loads skills by name on request.
  opencode: ['--prompt', 'Use the evolve-setup skill to set up code-evolve in this project.'],
};

function isOnPath(binary: string): boolean {
  return (process.env.PATH ?? '').split(path.delimiter).some((dir) => {
    try {
      fs.accessSync(path.join(dir, binary), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function shellQuote(arg: string): string {
  return /^[\w./-]+$/.test(arg) ? arg : `'${arg.replace(/'/g, `'\\''`)}'`;
}

function printNextSteps(binName: string): void {
  console.log('To set up code-evolve, run one of these in your project:\n');
  for (const [agent, args] of Object.entries(SETUP_LAUNCH_ARGS)) {
    console.log(`  npx ${binName} init --yes --agent ${agent} && ${[agent, ...args].map(shellQuote).join(' ')}`);
  }
}

async function chooseAgent(found: string[]): Promise<string> {
  if (found.length === 1) return found[0];
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const menu = found.map((agent, index) => `  ${index + 1}. ${agent}`).join('\n');
  const answer = (await rl.question(`Found several agents:\n${menu}\nWhich one should set up code-evolve? [1-${found.length}] (1): `)).trim();
  rl.close();
  return found[Number(answer) - 1] ?? (found.includes(answer) ? answer : found[0]);
}

/**
 * Bare `code-evolve`: install with the agent found on PATH, then hand the terminal to that
 * agent with the evolve-setup skill as its first prompt.
 */
export async function bootstrap(binName: string): Promise<void> {
  const found = Object.keys(SETUP_LAUNCH_ARGS).filter(isOnPath);
  if (found.length === 0 || !process.stdin.isTTY || !process.stdout.isTTY) {
    if (found.length === 0) console.log('No supported agent CLI (claude, codex, opencode) found on PATH.\n');
    printNextSteps(binName);
    return;
  }

  const agent = await chooseAgent(found);
  const init = spawnSync(process.execPath, [process.argv[1], 'init', '--yes', '--agent', agent], { stdio: 'inherit' });
  if (init.status !== 0) process.exit(init.status ?? 1);

  console.log(`\nHanding off to ${agent} to finish setup...\n`);
  const session = spawnSync(agent, SETUP_LAUNCH_ARGS[agent], { stdio: 'inherit' });
  process.exit(session.status ?? 1);
}
