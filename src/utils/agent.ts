import { spawnSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { getEvolveDir } from './paths';
import { readConfig, getAgentEnvKey, getDefaultModel, isValidAgent, customAgentEnv } from './config';

/** Adapters whose stdout is a session log; their reply comes only from `$EVOLVE_AGENT_REPLY_FILE`. */
const REPLY_FILE_AGENTS = new Set(['claude', 'codex']);

/**
 * Draft a document by routing `prompt` through the configured agent adapter
 * (`.evolve/scripts/agents/<agent>.sh`) — the same `run_agent` entry point
 * `evolve.sh` uses to invoke the agent.
 *
 * Returns the agent's reply, or `null` when no agent is usable (adapter missing,
 * required API key unset) or the call fails: a non-zero exit anywhere in the adapter's
 * pipeline, the adapter's own `agent_detect_error` matching the output (a custom
 * agent's error pattern), a timeout, or no reply. claude and codex write the bare
 * reply to `$EVOLVE_AGENT_REPLY_FILE`; an adapter installed before that (or a run
 * that wrote nothing there) gives no reply rather than its session log. For the
 * other adapters the whole stdout is the reply.
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
  // Per-call private dir (not a guessable shared-tmp name), prompt written 0600:
  // the source document can carry sensitive product details.
  let promptDir: string;
  try {
    promptDir = fs.mkdtempSync(path.join(os.tmpdir(), 'code-evolve-draft-'));
  } catch {
    return null;
  }
  const promptFile = path.join(promptDir, 'prompt.txt');
  const replyFile = path.join(promptDir, 'reply.txt');
  const outputFile = path.join(promptDir, 'output.txt');
  const errorFile = path.join(promptDir, 'errors.txt');

  try {
    fs.writeFileSync(promptFile, prompt, { mode: 0o600 });
    // Source the adapter and call run_agent(prompt_file, model, timeout_cmd, timeout) the way
    // evolve.sh does: pipefail (claude's renderer exits 0 when claude itself dies) and the
    // adapter's agent_detect_error on what it printed. A detected `timeout`/`gtimeout` wrapper
    // kills the agent's whole process tree on timeout; spawnSync's own timeout is an outer
    // backstop in case neither binary exists.
    const result = spawnSync(
      'bash',
      [
        '-c',
        'set -o pipefail; tcmd="$(command -v timeout || command -v gtimeout || true)"; source "$1"; ' +
          'run_agent "$2" "$3" "$tcmd" 300 >"$4" 2>"$5" || exit $?; ' +
          'if declare -f agent_detect_error >/dev/null && { agent_detect_error "$4" || agent_detect_error "$5"; }; then exit 1; fi',
        'bash',
        adapter,
        promptFile,
        model,
        outputFile,
        errorFile,
      ],
      {
        encoding: 'utf8',
        maxBuffer: 16 * 1024 * 1024,
        timeout: 330_000,
        killSignal: 'SIGTERM',
        env: {
          ...process.env,
          EVOLVE_AGENT_REPLY_FILE: replyFile,
          ...customAgentEnv(agent, config),
          ...(config.authMode === 'oauth' ? { CLAUDE_AUTH_MODE: 'oauth' } : {}),
        },
      },
    );
    if (result.status !== 0 || result.error) return null;
    const replySource = REPLY_FILE_AGENTS.has(agent) ? replyFile : outputFile;
    const reply = fs.existsSync(replySource) ? fs.readFileSync(replySource, 'utf8').trim() : '';
    return reply.length ? reply : null;
  } catch {
    return null;
  } finally {
    fs.rmSync(promptDir, { recursive: true, force: true });
  }
}
