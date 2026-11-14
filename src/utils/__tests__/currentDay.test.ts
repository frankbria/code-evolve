import fs from 'fs';
import os from 'os';
import path from 'path';
import { currentDay, localCalendarDate } from '../paths';
import { createReq, isWaiverExpired } from '../proof';

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

  // Calendar days, as currentDay counts them: N × 24 hours can cross a clock change.
  const daysAgo = (days: number) => {
    const date = new Date();
    date.setDate(date.getDate() - days);
    return localCalendarDate(date);
  };

  it('is 0 on the day the project was born, as the engine counts it', () => {
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '0\n');
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(0));
    expect(currentDay()).toBe(0);
  });

  it('is 0 from the birth date alone on the first day', () => {
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(0));
    expect(currentDay()).toBe(0);
  });

  it('counts from the birth date, ignoring a DAY_COUNT left by an earlier cycle', () => {
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(10));
    expect(currentDay()).toBe(10);
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '7\n');
    expect(currentDay()).toBe(10);
  });

  it('uses DAY_COUNT when there is no birth date to count from', () => {
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '7\n');
    expect(currentDay()).toBe(7);
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), 'not a date\n');
    expect(currentDay()).toBe(7);
  });

  it('lapses a waiver on its day without a cycle having to run', () => {
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(6));
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '5\n');
    const waived = createReq({ id: 'REQ-0001', title: 'waived', status: 'waived', waiverExpires: 'Day 5' });
    expect(isWaiverExpired(waived, currentDay())).toBe(true);
  });

  it('counts from the birth date while DAY_COUNT is still the 0 that init installs', () => {
    fs.writeFileSync(path.join(evolveDirectory, 'DAY_COUNT'), '0\n');
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), daysAgo(5));
    expect(currentDay()).toBe(5);
  });

  it('reads a bare birth date as local midnight, as the engine does', () => {
    const now = new Date();
    const pad = (value: number) => String(value).padStart(2, '0');
    const today = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    fs.writeFileSync(path.join(evolveDirectory, '.birth_date'), today + '\n');
    expect(currentDay()).toBe(0);
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

describe('currentDay across a clock change', () => {
  const originalDirectory = process.cwd();
  let project: string;

  beforeEach(() => {
    project = fs.mkdtempSync(path.join(os.tmpdir(), 'current-day-dst-'));
    fs.mkdirSync(path.join(project, '.evolve'));
    process.chdir(project);
    // jest.global-setup.js puts the suite in a zone with clock changes; without it these tests prove nothing.
    expect(new Date(2026, 2, 9, 12).getTimezoneOffset()).toBe(240);
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
    process.chdir(originalDirectory);
    fs.rmSync(project, { recursive: true, force: true });
  });

  it('counts calendar days, so the first hour after a 23-hour day is not a day behind', () => {
    fs.writeFileSync(path.join(project, '.evolve', '.birth_date'), '2026-03-01\n');
    // Clocks went forward on 2026-03-08, so 2026-03-09 is 8 calendar days on but 8 days minus an hour of seconds.
    jest.setSystemTime(new Date(2026, 2, 9, 0, 30));
    expect(currentDay()).toBe(8);
    jest.setSystemTime(new Date(2026, 2, 9, 23, 30));
    expect(currentDay()).toBe(8);
  });

  it('counts calendar days across the clock change back, a 25-hour day', () => {
    fs.writeFileSync(path.join(project, '.evolve', '.birth_date'), '2026-10-25\n');
    jest.setSystemTime(new Date(2026, 10, 2, 23, 30));
    expect(currentDay()).toBe(8);
  });
});

describe('localCalendarDate', () => {
  it('is the date on the local calendar, zero-padded, at either end of the day', () => {
    expect(localCalendarDate(new Date(2026, 0, 5, 0, 10))).toBe('2026-01-05');
    expect(localCalendarDate(new Date(2026, 0, 5, 23, 50))).toBe('2026-01-05');
    expect(localCalendarDate(new Date(2026, 10, 30, 12, 0))).toBe('2026-11-30');
  });

  it('is a birth date that currentDay counts as Day 0 right now', () => {
    const project = fs.mkdtempSync(path.join(os.tmpdir(), 'local-date-'));
    const originalDirectory = process.cwd();
    fs.mkdirSync(path.join(project, '.evolve'));
    fs.writeFileSync(path.join(project, '.evolve', '.birth_date'), localCalendarDate() + '\n');
    process.chdir(project);
    try {
      expect(currentDay()).toBe(0);
    } finally {
      process.chdir(originalDirectory);
      fs.rmSync(project, { recursive: true, force: true });
    }
  });
});
