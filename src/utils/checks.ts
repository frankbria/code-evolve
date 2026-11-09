import fs from 'fs';
import path from 'path';
import { spawn } from 'child_process';
import { customCommandBinary } from './config';
import type { AuthMode } from './config';

// Only async child processes here: Codex's sandbox refuses spawnSync/execSync (EPERM) but allows
// spawn, and agents run these commands from inside it (#125).

interface DependencyCheck {
  name: string;
  found: boolean;
  version?: string;
}

function isExecutableFile(file: string): boolean {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

/** True when `binary` is an executable file on PATH (or, when it holds a "/", at that path); spawns nothing. */
export function isOnPath(binary: string): boolean {
  if (!binary) return false;
  if (binary.includes('/')) return isExecutableFile(binary);
  return (process.env.PATH ?? '').split(path.delimiter).some((dir) => isExecutableFile(path.join(dir, binary)));
}

/**
 * Run a command without a shell; resolves with its exit status (null if it could not start or timed out)
 * and stdout. `timeoutMs` 0 means no limit (for git on a large repository).
 */
export function runProcess(command: string, args: string[], timeoutMs = 10000): Promise<{ status: number | null; stdout: string }> {
  return new Promise((resolve) => {
    let stdout = '';
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'ignore'], timeout: timeoutMs });
    child.stdout.on('data', (chunk: Buffer) => { stdout += chunk.toString(); });
    child.on('error', () => resolve({ status: null, stdout }));
    child.on('close', (status) => resolve({ status, stdout }));
  });
}

async function checkCommand(name: string): Promise<DependencyCheck> {
  if (!isOnPath(name)) return { name, found: false };
  // The version is only shown to the user; a binary on PATH that cannot report one still counts.
  const { status, stdout } = await runProcess(name, ['--version'], 5000);
  const version = status === 0 ? stdout.trim().split('\n')[0] : undefined;
  return version ? { name, found: true, version } : { name, found: true };
}

const AGENT_BINARIES: Record<string, string> = {
  claude: 'claude',
  codex: 'codex',
  opencode: 'opencode',
  ollama: 'ollama',
};

/** For agent "custom", `agentCommand` names the binary to check (its first word). */
export async function checkDependencies(agent = 'claude', agentCommand?: string): Promise<{ ok: boolean; results: DependencyCheck[] }> {
  const agentBinary = agent === 'custom' ? customCommandBinary(agentCommand) : AGENT_BINARIES[agent];
  if (!agentBinary) {
    return { ok: false, results: [{ name: agent, found: false }] };
  }
  const results = await Promise.all([checkCommand('python3'), checkCommand('git'), checkCommand(agentBinary)]);
  return { ok: results.every((r) => r.found), results };
}

export function formatDependencyResults(results: DependencyCheck[]): string {
  return results
    .map((r) => {
      const status = r.found ? '✓' : '✗';
      const version = r.version ? ` (${r.version})` : '';
      return `  ${status} ${r.name}${version}`;
    })
    .join('\n');
}

/** In Codex's ChatGPT-login mode, true when `codex login status` reports no usable login. */
export async function codexLoginMissing(agent: string, authMode?: AuthMode): Promise<boolean> {
  if (agent !== 'codex' || authMode !== 'chatgpt') return false;
  return (await runProcess('codex', ['login', 'status'])).status !== 0;
}
