import { Command } from 'commander';
import fs from 'fs';
import readline from 'readline';
import { evolveFile, getEvolveDir, isInitialized } from '../utils/paths';
import { draftWithAgent } from '../utils/agent';
import { readConfig } from '../utils/config';
import {
  extractFeaturesRegex,
  buildSpecMarkdown,
  buildVisionMarkdown,
  buildAiSpecPrompt,
  buildAiVisionPrompt,
  gatherCodebaseFiles,
} from '../utils/migrate';

export const migrateCommand = new Command('migrate')
  .description('Convert an existing spec or vision document into code-evolve format')
  .argument('<type>', 'Document type: "spec" or "vision"')
  .argument('<source>', 'Path to the source document')
  .option('--yes', 'Write without confirmation prompt')
  .option('--ai', "Draft with the project's configured agent (default: regex extraction)")
  .action(async (type: string, source: string, options: { yes?: boolean; ai?: boolean }) => {
    // Validate type
    if (type !== 'spec' && type !== 'vision') {
      console.error(`Invalid type "${type}". Must be "spec" or "vision".`);
      process.exit(1);
    }

    // Validate source file
    if (!fs.existsSync(source)) {
      console.error(`Source file not found: ${source}`);
      process.exit(2);
    }

    // Warn if not initialized
    if (!isInitialized()) {
      console.log('Warning: .evolve/ not initialized. Run `code-evolve init` first for full setup.');
      console.log('Creating .evolve/ directory for output...');
      fs.mkdirSync(getEvolveDir(), { recursive: true });
    }

    let sourceContent: string;
    try {
      sourceContent = fs.readFileSync(source, 'utf8');
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(`Failed to read source file: ${message}`);
      process.exit(2);
    }
    const outputPath = evolveFile(`${type}.md`);

    console.log(`Migrating ${source} → .evolve/${type}.md`);
    const agent = readConfig().agent;
    console.log(`Mode: ${options.ai ? `drafted by the ${agent} agent` : 'regex extraction'}`);
    console.log('');

    let result: string;

    if (options.ai) {
      console.log(`Running the ${agent} agent...`);
      const prompt = type === 'spec'
        ? buildAiSpecPrompt(sourceContent, gatherCodebaseFiles(process.cwd()))
        : buildAiVisionPrompt(sourceContent);
      const drafted = draftWithAgent(prompt);
      if (drafted === null) {
        console.error(
          `AI conversion failed: the ${agent} agent could not draft it (its adapter is missing, ` +
            'its API key is not set, or the call failed). Run `code-evolve init` first, or drop --ai for regex extraction.',
        );
        process.exit(3);
      }
      result = drafted;
    } else {
      if (type === 'spec') {
        const features = extractFeaturesRegex(sourceContent);
        console.log(`Extracted ${features.length} feature(s) from source.`);
        result = buildSpecMarkdown(features);
      } else {
        result = buildVisionMarkdown(sourceContent);
      }
    }

    // Show preview
    if (fs.existsSync(outputPath)) {
      console.log(`\n.evolve/${type}.md already exists. Preview of new content:\n`);
    } else {
      console.log('\nPreview:\n');
    }
    console.log('---');
    console.log(result);
    console.log('---\n');

    // Confirm unless --yes
    if (!options.yes) {
      const confirmed = await confirm(`Write to .evolve/${type}.md?`);
      if (!confirmed) {
        console.log('Aborted.');
        process.exit(0);
      }
    }

    fs.writeFileSync(outputPath, result);
    console.log(`Written to .evolve/${type}.md`);
  });

function confirm(question: string): Promise<boolean> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} [y/N] `, (answer) => {
      rl.close();
      resolve(answer.toLowerCase() === 'y' || answer.toLowerCase() === 'yes');
    });
  });
}
