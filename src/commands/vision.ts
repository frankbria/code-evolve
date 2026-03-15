import { Command } from 'commander';
import fs from 'fs';
import readline from 'readline';
import { evolveFile, getEvolveDir, isInitialized } from '../utils/paths';

interface InterviewAnswers {
  whatBuilding: string;
  whoFor: string;
  currentPain: string;
  triggerMoment: string;
  firstExperience: string;
  mustDoWell: string;
  notThis: string;
  mvpCuts: string;
  successSignal: string;
  delightMoment: string;
}

export const visionCommand = new Command('vision')
  .description('Launch a guided interview to generate .evolve/vision.md')
  .option('--refine', 'Revisit and improve an existing vision.md')
  .action(async (options: { refine?: boolean }) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const ask = (question: string): Promise<string> =>
      new Promise((resolve) => rl.question(question, resolve));

    try {
      console.log('');
      console.log('=== code-evolve: Vision Interview ===');
      console.log('');
      console.log("I'll ask you a series of questions to help shape your project vision.");
      console.log('Answer naturally — short or long is fine. Say "skip" to move on.');
      console.log('');

      // Refine mode: load existing vision
      let existingVision = '';
      if (options.refine) {
        const visionPath = evolveFile('vision.md');
        if (fs.existsSync(visionPath)) {
          existingVision = fs.readFileSync(visionPath, 'utf8');
          console.log('Found existing .evolve/vision.md. Using it as context for follow-up questions.');
          console.log('');
        } else {
          console.log('No existing .evolve/vision.md found. Starting fresh.');
          console.log('');
        }
      }

      const answers = await runInterview(ask, existingVision);

      // Summary
      console.log('');
      console.log('=== Summary ===');
      console.log('');
      printSummary(answers);

      const confirm = await ask('\nDoes this capture your vision? (yes / edit / cancel) ');
      const choice = confirm.toLowerCase().trim();

      if (choice === 'cancel' || choice === 'c') {
        console.log('Cancelled. Nothing was written.');
        return;
      }

      let finalAnswers = answers;
      if (choice === 'edit' || choice === 'e') {
        console.log('\nLet\'s go through the questions again. Press Enter to keep your previous answer.\n');
        finalAnswers = await runInterview(ask, '', answers);
        console.log('');
        console.log('=== Updated Summary ===');
        console.log('');
        printSummary(finalAnswers);
      }

      // Build and preview
      const doc = buildVisionDoc(finalAnswers);

      console.log('\n=== Preview ===\n');
      console.log(doc);

      const writeConfirm = await ask('Write this to .evolve/vision.md? (yes / no) ');
      if (writeConfirm.toLowerCase().trim() !== 'yes' && writeConfirm.toLowerCase().trim() !== 'y') {
        console.log('Aborted. Nothing was written.');
        return;
      }

      // Ensure .evolve/ exists
      if (!isInitialized()) {
        fs.mkdirSync(getEvolveDir(), { recursive: true });
      }

      fs.writeFileSync(evolveFile('vision.md'), doc);
      console.log('');
      console.log('Written to .evolve/vision.md');
      console.log('');
      console.log('Next: edit .evolve/spec.md to define features, then run `code-evolve run` to start building.');
    } finally {
      rl.close();
    }
  });

async function runInterview(
  ask: (q: string) => Promise<string>,
  existingContext: string,
  previous?: InterviewAnswers,
): Promise<InterviewAnswers> {
  const answers: InterviewAnswers = previous
    ? { ...previous }
    : {
        whatBuilding: '',
        whoFor: '',
        currentPain: '',
        triggerMoment: '',
        firstExperience: '',
        mustDoWell: '',
        notThis: '',
        mvpCuts: '',
        successSignal: '',
        delightMoment: '',
      };

  async function askQuestion(
    key: keyof InterviewAnswers,
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

  // Round 1 — The Core
  console.log('--- Round 1: The Core ---\n');
  await askQuestion(
    'whatBuilding',
    'What are you building? Describe it in one sentence like you\'re telling a friend.',
    'Can you say a bit more about what it does?',
  );
  await askQuestion(
    'whoFor',
    'Who is this for? Describe a specific person who would use this.',
    'What\'s their role or daily workflow?',
  );

  // Round 2 — The Problem
  console.log('\n--- Round 2: The Problem ---\n');
  await askQuestion(
    'currentPain',
    'What does this person do today without your tool? What\'s painful about that?',
    'Can you give a specific example?',
  );
  await askQuestion(
    'triggerMoment',
    'What\'s the moment they\'d reach for your tool instead?',
    'What frustration triggers that moment?',
  );

  // Round 3 — The Shape
  console.log('\n--- Round 3: The Shape ---\n');

  // Adaptive: detect CLI/terminal projects
  const isCli = /\b(?:cli|terminal|command[- ]line|shell|console)\b/i.test(answers.whatBuilding);
  if (isCli) {
    await askQuestion(
      'firstExperience',
      'When someone first runs your tool, what do they type and what do they see?',
      'Walk me through the first 30 seconds.',
    );
  } else {
    await askQuestion(
      'firstExperience',
      'When it\'s working, what does the user see or do first?',
      'Walk me through the first 30 seconds.',
    );
  }
  await askQuestion(
    'mustDoWell',
    'What\'s the one thing it absolutely must do well?',
    'Why that one thing above all else?',
  );

  // Round 4 — The Boundaries
  console.log('\n--- Round 4: The Boundaries ---\n');
  await askQuestion(
    'notThis',
    'What is this NOT? What should it never become?',
    'What\'s the trap you want to avoid?',
  );
  await askQuestion(
    'mvpCuts',
    'If you had to ship in one week, what would you cut?',
    'What\'s the nice-to-have vs. the must-have?',
  );

  // Round 5 — Success
  console.log('\n--- Round 5: Success ---\n');
  await askQuestion(
    'successSignal',
    'How would you know it\'s working? What would you measure or observe?',
    'What metric or moment tells you it\'s a success?',
  );
  await askQuestion(
    'delightMoment',
    'Describe the moment a user says "this is exactly what I needed."',
    'What are they doing right before that moment?',
  );

  return answers;
}

function printSummary(answers: InterviewAnswers): void {
  const entries: [string, string][] = [
    ['Building', answers.whatBuilding],
    ['For', answers.whoFor],
    ['Problem', answers.currentPain],
    ['Trigger', answers.triggerMoment],
    ['First experience', answers.firstExperience],
    ['Must do well', answers.mustDoWell],
    ['Not this', answers.notThis],
    ['MVP cuts', answers.mvpCuts],
    ['Success signal', answers.successSignal],
    ['Delight moment', answers.delightMoment],
  ];

  for (const [label, value] of entries) {
    console.log(`  ${label}: ${value}`);
  }
}

function buildVisionDoc(answers: InterviewAnswers): string {
  return `# Vision

## What We're Building
${answers.whatBuilding}

## Who It's For
${answers.whoFor}

## The Problem
${answers.currentPain}

### The Trigger
${answers.triggerMoment}

## The Experience
${answers.firstExperience}

### Core Capability
${answers.mustDoWell}

## Boundaries
${answers.notThis}

### MVP Scope
${answers.mvpCuts}

## Success
${answers.successSignal}

### The Delight Moment
${answers.delightMoment}
`;
}
