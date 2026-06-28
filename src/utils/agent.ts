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
  // Per-call private dir (not a guessable shared-tmp name), prompt written 0600 —
  // interview prompts can carry sensitive product details.
  let promptDir: string;
  try {
    promptDir = fs.mkdtempSync(path.join(os.tmpdir(), 'code-evolve-draft-'));
  } catch {
    return null;
  }
  const promptFile = path.join(promptDir, 'prompt.txt');

  try {
    fs.writeFileSync(promptFile, prompt, { mode: 0o600 });
    // Source the adapter and call run_agent(prompt_file, model, timeout_cmd, timeout).
    // A detected `timeout`/`gtimeout` wrapper (the same mechanism evolve.sh uses)
    // kills the agent's whole process tree on timeout; spawnSync's own timeout is
    // an outer backstop in case neither binary exists.
    const result = spawnSync(
      'bash',
      [
        '-c',
        'tcmd="$(command -v timeout || command -v gtimeout || true)"; source "$1"; run_agent "$2" "$3" "$tcmd" 300',
        'bash',
        adapter,
        promptFile,
        model,
      ],
      {
        encoding: 'utf8',
        maxBuffer: 16 * 1024 * 1024,
        timeout: 330_000,
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
    fs.rmSync(promptDir, { recursive: true, force: true });
  }
}
