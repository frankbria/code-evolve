#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { Command } from 'commander';
import { initCommand } from './commands/init';
import { setupCommand } from './commands/setup';
import { startCommand } from './commands/start';
import { stopCommand } from './commands/stop';
import { runCommand } from './commands/run';
import { statusCommand } from './commands/status';
import { ejectCommand } from './commands/eject';
import { migrateCommand } from './commands/migrate';
import { visionCommand } from './commands/vision';
import { specCommand } from './commands/spec';
import { proofCommand } from './commands/proof';
import { bootstrap } from './commands/bootstrap';

const rawName = path.basename(process.argv[1]);
const binName = rawName === 'ce' ? 'ce' : 'code-evolve';

// Single source of truth for the version: read it from package.json (shipped in
// the tarball) so the CLI and package.json can never drift apart.
const { version } = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'),
);

const program = new Command();

program
  .name(binName)
  .description('Self-evolving project builder powered by Claude Code')
  .version(version)
  // A typo'd subcommand must error, not fall through to the bootstrap.
  .action(() => (program.args.length ? program.error(`error: unknown command '${program.args[0]}'`) : bootstrap(binName)));

program.addCommand(initCommand);
program.addCommand(setupCommand);
program.addCommand(startCommand);
program.addCommand(stopCommand);
program.addCommand(runCommand);
program.addCommand(statusCommand);
program.addCommand(ejectCommand);
program.addCommand(migrateCommand);
program.addCommand(visionCommand);
program.addCommand(specCommand);
program.addCommand(proofCommand);

program.parse();
