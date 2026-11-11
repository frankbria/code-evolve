import path from 'path';
import fs from 'fs';
import { execSync } from 'child_process';

export const EVOLVE_DIR_NAME = '.evolve';

export function getEvolveDir(): string {
  return path.resolve(process.cwd(), EVOLVE_DIR_NAME);
}

export function getTemplatesDir(): string {
  // __dirname is dist/utils/ when compiled, so go up two levels to package root
  return path.join(__dirname, '..', '..', 'templates');
}

/** This package's version, the one an install records as its engine version. */
export function packageVersion(): string {
  return JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'package.json'), 'utf8')).version;
}

/** -1, 0 or 1 as semver `a` is older than, equal to or newer than `b` (numeric parts only). */
export function compareVersions(a: string, b: string): number {
  const parts = (version: string) => {
    const pieces = version.split(/[.+-]/);
    return [0, 1, 2].map((index) => Number(pieces[index]) || 0);
  };
  const [left, right] = [parts(a), parts(b)];
  for (let index = 0; index < 3; index++) {
    if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1;
  }
  return 0;
}

/** Operator skills (evolve-setup, evolve-run, ...), shared with the plugin manifests. */
export function getOperatorSkillsDir(): string {
  return path.join(__dirname, '..', '..', 'plugins', 'code-evolve', 'skills');
}

export function evolveFile(name: string): string {
  return path.join(getEvolveDir(), name);
}

export function projectFile(name: string): string {
  return path.resolve(process.cwd(), name);
}

export function requirementsFile(): string {
  return evolveFile('REQUIREMENTS.md');
}

export function evidenceDir(reqId?: string): string {
  const base = path.join(getEvolveDir(), 'evidence');
  return reqId ? path.join(base, reqId) : base;
}

/** YYYY-MM-DD on the local calendar, which is how the engine reads a birth date (toISOString gives the UTC date). */
export function localCalendarDate(date = new Date()): string {
  const pad = (value: number) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

/** The evolution day as the engine counts it: whole days since the birth date, 0 on the first. */
export function currentDay(): number {
  try {
    const dayCountPath = evolveFile('DAY_COUNT');
    if (fs.existsSync(dayCountPath)) {
      const n = parseInt(fs.readFileSync(dayCountPath, 'utf8').trim(), 10);
      // 0 is also what init installs before any cycle has run, so it is checked against the birth date.
      if (n > 0) return n;
    }
    const birthPath = evolveFile('.birth_date');
    if (fs.existsSync(birthPath)) {
      const recorded = fs.readFileSync(birthPath, 'utf8').trim();
      // The engine reads a bare date as local midnight; JavaScript would read it as UTC.
      const birth = new Date(/^\d{4}-\d{2}-\d{2}$/.test(recorded) ? `${recorded}T00:00:00` : recorded);
      const elapsed = Math.floor((Date.now() - birth.getTime()) / 86_400_000);
      return Math.max(0, elapsed);
    }
  } catch { /* ignore */ }
  return 0;
}

export function shortCommit(): string {
  try {
    return execSync('git rev-parse --short HEAD', { stdio: ['pipe', 'pipe', 'pipe'] }).toString().trim();
  } catch {
    return 'unknown';
  }
}

export function isInitialized(): boolean {
  const evolveDir = getEvolveDir();
  return (
    fs.existsSync(evolveDir) &&
    fs.existsSync(path.join(evolveDir, 'scripts', 'evolve.sh')) &&
    fs.existsSync(path.join(evolveDir, 'IDENTITY.md'))
  );
}
