import path from 'path';
import fs from 'fs';

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
    const p = evolveFile('DAY_COUNT');
    if (fs.existsSync(p)) {
      return parseInt(fs.readFileSync(p, 'utf8').trim(), 10) || 0;
    }
  } catch { /* ignore */ }
  return 0;
}

export function isInitialized(): boolean {
  const evolveDir = getEvolveDir();
  return (
    fs.existsSync(evolveDir) &&
    fs.existsSync(path.join(evolveDir, 'scripts', 'evolve.sh')) &&
    fs.existsSync(path.join(evolveDir, 'IDENTITY.md'))
  );
}
