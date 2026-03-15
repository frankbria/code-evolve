import { Command } from 'commander';
import fs from 'fs';
import readline from 'readline';
import { evolveFile, getEvolveDir, isInitialized } from '../utils/paths';
import {
  extractFeaturesRegex,
  buildSpecMarkdown,
  buildVisionMarkdown,
  generateWithClaude,
  buildAiSpecPrompt,
  buildAiVisionPrompt,
  gatherCodebaseFiles,
} from '../utils/migrate';

export const migrateCommand = new Command('migrate')
  .description('Convert an existing spec or vision document into code-evolve format')
  .argument('<type>', 'Document type: "spec" or "vision"')
  .argument('<source>', 'Path to the source document')
  .option('--yes', 'Write without confirmation prompt')
  .option('--ai', 'Use Claude CLI for AI-powered conversion (default: regex extraction)')
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
    console.log(`Mode: ${options.ai ? 'AI-powered (claude CLI)' : 'regex extraction'}`);
    console.log('');

    let result: string;

    if (options.ai) {
      console.log('Running Claude CLI...');
      try {
        if (type === 'spec') {
          const files = gatherCodebaseFiles(process.cwd());
          const prompt = buildAiSpecPrompt(sourceContent, files);
          result = generateWithClaude(prompt);
        } else {
          const prompt = buildAiVisionPrompt(sourceContent);
          result = generateWithClaude(prompt);
        }
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(`AI conversion failed: ${message}`);
        process.exit(3);
      }
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
