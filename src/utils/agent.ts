import { spawnSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { getEvolveDir } from './paths';
import { readConfig, getAgentEnvKey, getDefaultModel, isValidAgent } from './config';

/**
 * Draft a document by routing `prompt` through the configured agent adapter
 * (`.evolve/scripts/agents/<agent>.sh`) — the same `run_agent` entry point
 * `evolve.sh` uses to invoke the agent.
 *
 * Returns the agent's text output, or `null` when no agent is usable (adapter
 * missing, required API key unset, or the call fails/times out). Callers fall
 * back to their static builder on `null`.
 */
export function draftWithAgent(prompt: string): string | null {
  const config = readConfig();
  const agent = config.agent || 'claude';
  if (!isValidAgent(agent)) return null;

  const adapter = path.join(getEvolveDir(), 'scripts', 'agents', `${agent}.sh`);
  if (!fs.existsSync(adapter)) return null;

  const envKey = getAgentEnvKey(agent, config.authMode);
  if (envKey && !process.env[envKey]) return null;

  const model = config.model || getDefaultModel(agent);
  const promptFile = path.join(os.tmpdir(), `code-evolve-draft-${process.pid}.txt`);

  try {
    fs.writeFileSync(promptFile, prompt);
    // Source the adapter and call its run_agent(prompt_file, model, timeout_cmd, timeout).
    // No timeout_cmd is passed; spawnSync's own timeout guards against a hung agent.
    const result = spawnSync(
      'bash',
      ['-c', 'source "$1"; run_agent "$2" "$3" "" ""', 'bash', adapter, promptFile, model],
      {
        encoding: 'utf8',
        maxBuffer: 16 * 1024 * 1024,
        timeout: 300_000,
        killSignal: 'SIGTERM',
        env: {
          ...process.env,
          ...(config.authMode === 'oauth' ? { CLAUDE_AUTH_MODE: 'oauth' } : {}),
        },
      },
    );
    if (result.status !== 0 || result.error) return null;
    const out = (result.stdout || '').trim();
    return out.length ? out : null;
  } catch {
    return null;
  } finally {
    fs.rmSync(promptFile, { force: true });
  }
}
