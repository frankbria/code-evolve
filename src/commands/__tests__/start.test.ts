import fs from 'fs';
import os from 'os';
import path from 'path';
import { credentialsKeptFromEnvFile, pathWithoutNpmScriptEntries } from '../start';

describe('credentialsKeptFromEnvFile', () => {
  let directory: string;
  let envFile: string;

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'code-evolve-start-'));
    envFile = path.join(directory, '.env');
    delete process.env.CODE_EVOLVE_TEST_TOKEN;
    delete process.env.CODE_EVOLVE_OTHER_TOKEN;
  });

  afterEach(() => {
    fs.rmSync(directory, { recursive: true, force: true });
    delete process.env.CODE_EVOLVE_TEST_TOKEN;
  });

  it('keeps the saved value of a credential the shell does not set, and unquotes it', () => {
    fs.writeFileSync(envFile, "export MODEL='m'\nexport CODE_EVOLVE_TEST_TOKEN='it'\\''s $HOME\nline two'\nexport PATH='/bin'\n");
    expect(credentialsKeptFromEnvFile(['CODE_EVOLVE_TEST_TOKEN'], envFile)).toEqual({
      kept: { CODE_EVOLVE_TEST_TOKEN: "it's $HOME\nline two" },
      warnings: ['CODE_EVOLVE_TEST_TOKEN is not set in this shell; keeping the value saved in .evolve/.env'],
    });
  });

  it('leaves a credential the shell sets to the shell, even when it is empty', () => {
    fs.writeFileSync(envFile, "export CODE_EVOLVE_TEST_TOKEN='old'\nexport CODE_EVOLVE_OTHER_TOKEN='old'\n");
    process.env.CODE_EVOLVE_TEST_TOKEN = '';
    expect(credentialsKeptFromEnvFile(['CODE_EVOLVE_TEST_TOKEN'], envFile)).toEqual({ kept: {}, warnings: [] });
  });

  it('warns when no value is saved: no file, no line for the name, a line in another format, or an empty value', () => {
    const missing = "CODE_EVOLVE_TEST_TOKEN is not set in this shell and no value is saved in .evolve/.env; scheduled cycles won't get it until you set it and run code-evolve start";
    expect(credentialsKeptFromEnvFile(['CODE_EVOLVE_TEST_TOKEN'], envFile)).toEqual({ kept: {}, warnings: [missing] });
    fs.writeFileSync(envFile, "export MODEL='m'\nCODE_EVOLVE_TEST_TOKEN=bare\nexport CODE_EVOLVE_TEST_TOKEN=\"double\"\n");
    expect(credentialsKeptFromEnvFile(['CODE_EVOLVE_TEST_TOKEN'], envFile)).toEqual({ kept: {}, warnings: [missing] });
    fs.writeFileSync(envFile, "export CODE_EVOLVE_TEST_TOKEN=''\n");
    expect(credentialsKeptFromEnvFile(['CODE_EVOLVE_TEST_TOKEN'], envFile)).toEqual({ kept: {}, warnings: [missing] });
  });

  it('reads the last value when a name is saved twice, as the shell would', () => {
    fs.writeFileSync(envFile, "export CODE_EVOLVE_TEST_TOKEN='first'\nexport CODE_EVOLVE_TEST_TOKEN='second'\n");
    expect(credentialsKeptFromEnvFile(['CODE_EVOLVE_TEST_TOKEN'], envFile).kept).toEqual({ CODE_EVOLVE_TEST_TOKEN: 'second' });
  });

  it('does not read an export line that sits inside another saved value', () => {
    fs.writeFileSync(envFile, "export CODE_EVOLVE_OTHER_TOKEN='a\nexport CODE_EVOLVE_TEST_TOKEN='\\''inner'\\''\nb'\n");
    expect(credentialsKeptFromEnvFile(['CODE_EVOLVE_TEST_TOKEN'], envFile).kept).toEqual({});
  });

  it('never carries a name the engine sets itself', () => {
    fs.writeFileSync(envFile, "export AGENT_COMMAND='planted'\nexport BASH_ENV='/tmp/x'\n");
    const saved = { AGENT_COMMAND: process.env.AGENT_COMMAND, BASH_ENV: process.env.BASH_ENV };
    delete process.env.AGENT_COMMAND;
    delete process.env.BASH_ENV;
    try {
      expect(credentialsKeptFromEnvFile(['AGENT_COMMAND', 'BASH_ENV', 'BAD-NAME'], envFile)).toEqual({ kept: {}, warnings: [] });
    } finally {
      if (saved.AGENT_COMMAND !== undefined) process.env.AGENT_COMMAND = saved.AGENT_COMMAND;
      if (saved.BASH_ENV !== undefined) process.env.BASH_ENV = saved.BASH_ENV;
    }
  });
});

describe('pathWithoutNpmScriptEntries', () => {
  let project: string;
  const npmEntries = (workingDirectory: string): string[] => [
    '/home/dev/.npm/_npx/4b4c857f6efdfb61/node_modules/.bin',
    path.join(workingDirectory, 'node_modules', '.bin'),
    path.join(path.dirname(workingDirectory), 'node_modules', '.bin'),
    '/node_modules/.bin',
    '/usr/lib/node_modules/npm/node_modules/@npmcli/run-script/lib/node-gyp-bin',
  ];

  beforeEach(() => {
    project = fs.mkdtempSync(path.join(os.tmpdir(), 'code-evolve-path-'));
  });

  afterEach(() => {
    fs.rmSync(project, { recursive: true, force: true });
  });

  it('drops the npx cache, the node_modules/.bin of the project and its parents, and node-gyp-bin', () => {
    const value = [...npmEntries(project), '/opt/tools/bin', '/usr/bin', '/bin'].join(':');
    expect(pathWithoutNpmScriptEntries(value, project, 'claude')).toBe('/opt/tools/bin:/usr/bin:/bin');
  });

  it('keeps every other entry in order: a node_modules/.bin outside the project and its parents, a relative one, another node-gyp-bin', () => {
    // The working directory sits under a directory whose name starts with dots: its parents still count.
    const value = ['/usr/bin', '/srv/other/node_modules/.bin', path.join(project, 'node_modules', '.bin'), '', 'node_modules/.bin', path.join(project, '..sibling', 'node_modules', '.bin'), '/opt/node-gyp-bin', '/bin'].join(':');
    expect(pathWithoutNpmScriptEntries(value, path.join(project, '..sibling', 'app'), 'claude'))
      .toBe('/usr/bin:/srv/other/node_modules/.bin::node_modules/.bin:/opt/node-gyp-bin:/bin');
  });

  it('keeps an npm entry that holds the agent binary, so a project-local agent still runs from cron', () => {
    const localBin = path.join(project, 'node_modules', '.bin');
    fs.mkdirSync(localBin, { recursive: true });
    fs.writeFileSync(path.join(localBin, 'claude'), '#!/bin/sh\n', { mode: 0o755 });
    const value = [...npmEntries(project), '/usr/bin'].join(':');
    expect(pathWithoutNpmScriptEntries(value, project, 'claude')).toBe(`${localBin}:/usr/bin`);
    expect(pathWithoutNpmScriptEntries(value, project, 'codex')).toBe('/usr/bin');
  });
});
