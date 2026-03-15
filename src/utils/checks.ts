import { execSync } from 'child_process';

interface DependencyCheck {
  name: string;
  found: boolean;
  version?: string;
}

function checkCommand(name: string, versionFlag = '--version'): DependencyCheck {
  try {
    const output = execSync(`${name} ${versionFlag} 2>&1`, { encoding: 'utf8', timeout: 5000 });
    const version = output.trim().split('\n')[0];
    return { name, found: true, version };
  } catch {
    return { name, found: false };
  }
}

const AGENT_BINARIES: Record<string, string> = {
  claude: 'claude',
  codex: 'codex',
  opencode: 'opencode',
  ollama: 'ollama',
};

export function checkDependencies(agent = 'claude'): { ok: boolean; results: DependencyCheck[] } {
  const agentBinary = AGENT_BINARIES[agent] || agent;
  const results = [
    checkCommand('python3'),
    checkCommand('git'),
    checkCommand(agentBinary),
  ];

  const ok = results.every((r) => r.found);
  return { ok, results };
}

export function formatDependencyResults(results: DependencyCheck[]): string {
  return results
    .map((r) => {
      const status = r.found ? '\u2713' : '\u2717';
      const version = r.version ? ` (${r.version})` : '';
      return `  ${status} ${r.name}${version}`;
    })
    .join('\n');
}
