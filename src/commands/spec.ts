import { Command } from 'commander';
import fs from 'fs';
import readline from 'readline';
import { evolveFile, getEvolveDir, isInitialized } from '../utils/paths';

type FeatureStatus = ' ' | '~' | 'x';

interface Feature {
  status: FeatureStatus;
  text: string;
}

interface SpecAnswers {
  techStack: string;
  architecture: string;
  features: Feature[];
  dataModel: string;
  apiDesign: string;
  testing: string;
  deployment: string;
}

export const specCommand = new Command('spec')
  .description('Launch a guided interview to generate .evolve/spec.md')
  .option('--refine', 'Revisit and improve an existing spec.md')
  .action(async (options: { refine?: boolean }) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

    // Line-queue reader: decouples our await pace from readline's emit pace so
    // piped (non-TTY) input isn't lost between questions, and EOF resolves
    // pending prompts to '' instead of leaving the process hung.
    const queue: string[] = [];
    const waiters: Array<(line: string) => void> = [];
    let closed = false;
    rl.on('line', (line) => {
      const waiter = waiters.shift();
      if (waiter) waiter(line);
      else queue.push(line);
    });
    rl.on('close', () => {
      closed = true;
      while (waiters.length) waiters.shift()!('');
    });
    const ask = (question: string): Promise<string> => {
      process.stdout.write(question);
      if (queue.length) return Promise.resolve(queue.shift()!);
      if (closed) return Promise.resolve('');
      return new Promise((resolve) => waiters.push(resolve));
    };

    try {
      console.log('');
      console.log('=== code-evolve: Spec Interview ===');
      console.log('');
      console.log("I'll ask about your tech stack, architecture, and features.");
      console.log('Answer naturally — short or long is fine. Say "skip" to move on.');
      console.log('');

      // Refine mode: load existing spec
      let previousAnswers: SpecAnswers | undefined;
      if (options.refine) {
        const specPath = evolveFile('spec.md');
        if (fs.existsSync(specPath)) {
          const existingSpec = fs.readFileSync(specPath, 'utf8');
          previousAnswers = parseSpecDoc(existingSpec);
          console.log('Found existing .evolve/spec.md. Previous answers will be shown — press Enter to keep them.');
          console.log('');
        } else {
          console.log('No existing .evolve/spec.md found. Starting fresh.');
          console.log('');
        }
      }

      const answers = await runInterview(ask, previousAnswers);

      // Summary
      console.log('');
      console.log('=== Summary ===');
      console.log('');
      printSummary(answers);

      const confirm = await ask('\nDoes this capture your spec? (yes / edit / cancel) ');
      const choice = confirm.toLowerCase().trim();

      if (choice === 'cancel' || choice === 'c') {
        console.log('Cancelled. Nothing was written.');
        return;
      }

      let finalAnswers = answers;
      if (choice === 'edit' || choice === 'e') {
        console.log('\nLet\'s go through the questions again. Press Enter to keep your previous answer.\n');
        finalAnswers = await runInterview(ask, answers);
        console.log('');
        console.log('=== Updated Summary ===');
        console.log('');
        printSummary(finalAnswers);
      }

      // Build and preview
      const doc = buildSpecDoc(finalAnswers);

      console.log('\n=== Preview ===\n');
      console.log(doc);

      const writeConfirm = await ask('Write this to .evolve/spec.md? (yes / no) ');
      if (writeConfirm.toLowerCase().trim() !== 'yes' && writeConfirm.toLowerCase().trim() !== 'y') {
        console.log('Aborted. Nothing was written.');
        return;
      }

      // Ensure .evolve/ exists
      if (!isInitialized()) {
        fs.mkdirSync(getEvolveDir(), { recursive: true });
      }

      fs.writeFileSync(evolveFile('spec.md'), doc);
      console.log('');
      console.log('Written to .evolve/spec.md');
      console.log('');
      console.log('Next: run `code-evolve run` to start building the first feature.');
    } finally {
      rl.close();
    }
  });

async function runInterview(
  ask: (q: string) => Promise<string>,
  previous?: SpecAnswers,
): Promise<SpecAnswers> {
  const answers: SpecAnswers = previous
    ? { ...previous, features: [...previous.features] }
    : {
        techStack: '',
        architecture: '',
        features: [],
        dataModel: '',
        apiDesign: '',
        testing: '',
        deployment: '',
      };

  async function askQuestion(
    key: Exclude<keyof SpecAnswers, 'features'>,
    question: string,
    followUp?: string,
  ): Promise<void> {
    const prev = previous ? answers[key] : '';
    if (prev) {
      console.log(`${question}`);
      console.log(`  (previous: "${prev.slice(0, 80)}${prev.length > 80 ? '...' : ''}")`);
    } else {
      console.log(`${question}`);
    }

    const answer = await ask('  > ');
    const trimmed = answer.trim();

    if (trimmed === '' && prev) {
      return;
    }

    if (trimmed.toLowerCase() === 'skip' || trimmed === '') {
      answers[key] = prev || '(to be determined)';
      return;
    }

    if (trimmed.toLowerCase() === "i don't know" || trimmed.toLowerCase() === 'not sure') {
      answers[key] = '(to be determined)';
      return;
    }

    if (followUp && trimmed.split(/\s+/).length < 5) {
      console.log(`  ${followUp}`);
      const more = await ask('  > ');
      const moreTrimmed = more.trim();
      if (moreTrimmed && moreTrimmed.toLowerCase() !== 'skip') {
        answers[key] = `${trimmed}. ${moreTrimmed}`;
      } else {
        answers[key] = trimmed;
      }
    } else {
      answers[key] = trimmed;
    }
  }

  // Round 1 — The Stack
  console.log('--- Round 1: The Stack ---\n');
  await askQuestion(
    'techStack',
    'What\'s your tech stack? Language, framework, database, key libraries.',
    'Anything else in the stack — runtime, package manager, hosting?',
  );
  await askQuestion(
    'architecture',
    'How is it structured? (e.g. CLI tool, monolith web app, microservices, library)',
    'How do the pieces fit together?',
  );

  // Round 2 — The Features (priority order)
  console.log('\n--- Round 2: Features (priority order) ---\n');
  answers.features = await askFeatures(ask, previous ? answers.features : []);

  // Round 3 — The Data
  console.log('\n--- Round 3: Data & API ---\n');
  await askQuestion(
    'dataModel',
    'What does the data look like? Main entities and how they\'re stored.',
    'Any key relationships or fields?',
  );
  await askQuestion(
    'apiDesign',
    'Is there an API or interface? Describe its shape (REST routes, CLI commands, function exports).',
    'What are the main entry points?',
  );

  // Round 4 — Quality & Delivery
  console.log('\n--- Round 4: Quality & Delivery ---\n');
  await askQuestion(
    'testing',
    'What\'s the testing strategy? Frameworks and coverage target.',
    'Unit, integration, e2e — what matters most here?',
  );
  await askQuestion(
    'deployment',
    'Where and how does this ship? Deployment target.',
    'How does it get released?',
  );

  return answers;
}

async function askFeatures(
  ask: (q: string) => Promise<string>,
  previous: Feature[],
): Promise<Feature[]> {
  if (previous.length > 0) {
    console.log('Current features (press Enter to keep them as-is, or type "redo" to re-enter the list):');
    for (const f of previous) {
      console.log(`  - [${f.status}] ${f.text}`);
    }
    const choice = (await ask('  > ')).trim().toLowerCase();
    if (choice !== 'redo') {
      return previous;
    }
    console.log('');
  }

  console.log('List your features in priority order — the agent builds them top to bottom.');
  console.log('Enter one per line. Press Enter on an empty line when done.');
  const features: Feature[] = [];
  for (;;) {
    const line = (await ask(`  ${features.length + 1}. `)).trim();
    if (line === '') break;
    features.push({ status: ' ', text: line });
  }
  return features;
}

function printSummary(answers: SpecAnswers): void {
  console.log(`  Tech stack: ${answers.techStack || '(none)'}`);
  console.log(`  Architecture: ${answers.architecture || '(none)'}`);
  console.log(`  Features (${answers.features.length}):`);
  for (const f of answers.features) {
    console.log(`    - [${f.status}] ${f.text}`);
  }
  console.log(`  Data model: ${answers.dataModel || '(none)'}`);
  console.log(`  API design: ${answers.apiDesign || '(none)'}`);
  console.log(`  Testing: ${answers.testing || '(none)'}`);
  console.log(`  Deployment: ${answers.deployment || '(none)'}`);
}

function extractSection(content: string, heading: string): string {
  const pattern = new RegExp(`^#+ ${heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`, 'm');
  const match = pattern.exec(content);
  if (!match || match.index === undefined) return '';
  const start = match.index + match[0].length;
  const nextHeading = content.slice(start).search(/^#+\s/m);
  const end = nextHeading === -1 ? undefined : start + nextHeading;
  return content.slice(start, end).trim();
}

function parseFeatures(section: string): Feature[] {
  const features: Feature[] = [];
  const linePattern = /^\s*-\s*\[([ ~xX])\]\s*(.+?)\s*$/;
  for (const line of section.split('\n')) {
    const m = linePattern.exec(line);
    if (m) {
      const status = (m[1].toLowerCase() === 'x' ? 'x' : m[1]) as FeatureStatus;
      features.push({ status, text: m[2] });
    }
  }
  return features;
}

function parseSpecDoc(content: string): SpecAnswers {
  return {
    techStack: extractSection(content, 'Tech Stack'),
    architecture: extractSection(content, 'Architecture'),
    features: parseFeatures(extractSection(content, 'Features (Priority Order)')),
    dataModel: extractSection(content, 'Data Model'),
    apiDesign: extractSection(content, 'API Design'),
    testing: extractSection(content, 'Testing'),
    deployment: extractSection(content, 'Deployment'),
  };
}

function buildSpecDoc(answers: SpecAnswers): string {
  const featureLines = answers.features.length
    ? answers.features.map((f) => `- [${f.status}] ${f.text}`).join('\n')
    : '- [ ] (add your first feature)';

  return `# Specification

## Tech Stack
${answers.techStack || '(to be determined)'}

## Architecture
${answers.architecture || '(to be determined)'}

## Features (Priority Order)
${featureLines}

## Data Model
${answers.dataModel || '(to be determined)'}

## API Design
${answers.apiDesign || '(to be determined)'}

## Testing
${answers.testing || '(to be determined)'}

## Deployment
${answers.deployment || '(to be determined)'}
`;
}
