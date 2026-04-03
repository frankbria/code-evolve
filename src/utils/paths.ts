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

export function currentDay(): number {
  try {
    const dayCountPath = evolveFile('DAY_COUNT');
    if (fs.existsSync(dayCountPath)) {
      const n = parseInt(fs.readFileSync(dayCountPath, 'utf8').trim(), 10);
      if (!isNaN(n) && n > 0) return n;
    }
    // Fallback: derive from birth date if DAY_COUNT is absent or corrupt
    const birthPath = evolveFile('.birth_date');
    if (fs.existsSync(birthPath)) {
      const birth = new Date(fs.readFileSync(birthPath, 'utf8').trim());
      const elapsed = Math.floor((Date.now() - birth.getTime()) / 86_400_000);
      return Math.max(1, elapsed);
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
