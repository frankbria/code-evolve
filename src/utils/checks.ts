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

export function checkDependencies(): { ok: boolean; results: DependencyCheck[] } {
  const results = [
    checkCommand('python3'),
    checkCommand('git'),
    checkCommand('claude'),
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
