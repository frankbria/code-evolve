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

/** Calendar days from one YYYY-MM-DD to another, whatever the length of the days between (a clock change makes one 23 or 25 hours). */
function calendarDaysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

/**
 * The evolution day as the engine counts it: calendar days since the birth date, 0 on the first.
 * Counted from the birth date whenever there is one, so it is today's day between cycles too;
 * DAY_COUNT only stands in for a missing or unreadable birth date.
 */
export function currentDay(): number {
  const recorded = stateFileText('.birth_date');
  if (recorded !== null) {
    // The engine reads a bare date as a day on the local calendar; JavaScript would read it as UTC.
    const birth = new Date(/^\d{4}-\d{2}-\d{2}$/.test(recorded) ? `${recorded}T00:00:00` : recorded);
    if (!Number.isNaN(birth.getTime())) {
      return Math.max(0, calendarDaysBetween(localCalendarDate(birth), localCalendarDate()));
    }
  }
  const dayCount = parseInt(stateFileText('DAY_COUNT') ?? '', 10);
  return dayCount > 0 ? dayCount : 0;
}

/** A state file's trimmed text, or null when it is missing or cannot be read. */
function stateFileText(name: string): string | null {
  try {
    return fs.readFileSync(evolveFile(name), 'utf8').trim();
  } catch {
    return null;
  }
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
