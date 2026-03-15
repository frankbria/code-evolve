#!/usr/bin/env node
import path from 'path';
import { Command } from 'commander';
import { initCommand } from './commands/init';
import { startCommand } from './commands/start';
import { stopCommand } from './commands/stop';
import { runCommand } from './commands/run';
import { statusCommand } from './commands/status';
import { ejectCommand } from './commands/eject';
import { migrateCommand } from './commands/migrate';
import { visionCommand } from './commands/vision';

const rawName = path.basename(process.argv[1]);
const binName = rawName === 'ce' ? 'ce' : 'code-evolve';
const program = new Command();

program
  .name(binName)
  .description('Self-evolving project builder powered by Claude Code')
  .version('0.1.0');

program.addCommand(initCommand);
program.addCommand(startCommand);
program.addCommand(stopCommand);
program.addCommand(runCommand);
program.addCommand(statusCommand);
program.addCommand(ejectCommand);
program.addCommand(migrateCommand);
program.addCommand(visionCommand);

program.parse();
