import fs from 'fs';
import os from 'os';
import path from 'path';
import { currentDay } from '../paths';

describe('currentDay', () => {
  const originalDirectory = process.cwd();
  let evolveDirectory: string;

  beforeEach(() => {
    const project = fs.mkdtempSync(path.join(os.tmpdir(), 'current-day-'));
    evolveDirectory = path.join(project, '.evolve');
    fs.mkdirSync(evolveDirectory);
    process.chdir(project);
  });

  afterEach(() => {
    process.chdir(originalDirectory);
    fs.rmSync(path.dirname(evolveDirectory), { recursive: true, force: true });
  });

  const daysAgo = (days: number) => new Date(Date.now() - days * 86_400_000).toISOString();

  it('is 0 on the day the project was born, as the engine counts it', () => {
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '0\n');
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(0));
    expect(currentDay()).toBe(0);
  });

  it('is 0 from the birth date alone on the first day', () => {
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(0));
    expect(currentDay()).toBe(0);
  });

  it('prefers DAY_COUNT, and falls back to whole days since the birth date', () => {
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(10));
    expect(currentDay()).toBe(10);
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '7\n');
    expect(currentDay()).toBe(7);
  });

  it('ignores a corrupt or negative DAY_COUNT', () => {
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(4));
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), 'not a number\n');
    expect(currentDay()).toBe(4);
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '-2\n');
    expect(currentDay()).toBe(4);
  });

  it('is 0 when nothing records a day or the birth date is in the future', () => {
    expect(currentDay()).toBe(0);
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(-3));
    expect(currentDay()).toBe(0);
  });
});
