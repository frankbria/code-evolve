import { Command } from 'commander';
import fs from 'fs';
import readline from 'readline';
import { evolveFile, getEvolveDir, isInitialized } from '../utils/paths';
import { makeAsk } from '../utils/interview';
import { draftWithAgent } from '../utils/agent';

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
    const ask = makeAsk(rl);

    try {
      console.log('');
      console.log('=== code-evolve: Vision Interview ===');
      console.log('');
      console.log("I'll ask you a series of questions to help shape your project vision.");
      console.log('Answer naturally — short or long is fine. Say "skip" to move on.');
      console.log('');

      // Refine mode: load existing vision
      let previousAnswers: InterviewAnswers | undefined;
      if (options.refine) {
        const visionPath = evolveFile('vision.md');
        if (fs.existsSync(visionPath)) {
          const existingVision = fs.readFileSync(visionPath, 'utf8');
          previousAnswers = parseVisionDoc(existingVision);
          console.log('Found existing .evolve/vision.md. Previous answers will be shown — press Enter to keep them.');
          console.log('');
        } else {
          console.log('No existing .evolve/vision.md found. Starting fresh.');
          console.log('');
        }
      }

      const answers = await runInterview(ask, previousAnswers);

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
        finalAnswers = await runInterview(ask, answers);
        console.log('');
        console.log('=== Updated Summary ===');
        console.log('');
        printSummary(finalAnswers);
      }

      // Draft with the configured agent; fall back to the static template when
      // no agent/key is available.
      console.log('\nDrafting your vision...');
      let drafted = draftWithAgent(buildVisionPrompt(finalAnswers));
      console.log(drafted ? '(Drafted with your configured agent.)' : '(No agent configured — using the built-in template.)');
      let doc = drafted ?? buildVisionDoc(finalAnswers);

      // Preview + accept/refine loop.
      for (;;) {
        console.log('\n=== Preview ===\n');
        console.log(doc);

        const prompt = drafted
          ? 'Write this to .evolve/vision.md? (yes / refine / no) '
          : 'Write this to .evolve/vision.md? (yes / no) ';
        const choice = (await ask(prompt)).toLowerCase().trim();

        if (choice === 'yes' || choice === 'y') break;

        if (drafted && (choice === 'refine' || choice === 'r')) {
          const feedback = (await ask('What should change? ')).trim();
          const redo = draftWithAgent(buildVisionPrompt(finalAnswers, feedback));
          if (redo) {
            drafted = redo;
            doc = redo;
          } else {
            console.log('Could not redraft — keeping the current version.');
          }
          continue;
        }

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

function parseVisionDoc(content: string): InterviewAnswers {
  function extractSection(heading: string): string {
    const pattern = new RegExp(`^#+ ${heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`, 'm');
    const match = pattern.exec(content);
    if (!match || match.index === undefined) return '';
    const start = match.index + match[0].length;
    const nextHeading = content.slice(start).search(/^#+\s/m);
    const end = nextHeading === -1 ? undefined : start + nextHeading;
    return content.slice(start, end).trim();
  }

  return {
    whatBuilding: extractSection("What We're Building"),
    whoFor: extractSection("Who It's For"),
    currentPain: extractSection('The Problem'),
    triggerMoment: extractSection('The Trigger'),
    firstExperience: extractSection('The Experience'),
    mustDoWell: extractSection('Core Capability'),
    notThis: extractSection('Boundaries'),
    mvpCuts: extractSection('MVP Scope'),
    successSignal: extractSection('Success'),
    delightMoment: extractSection('The Delight Moment'),
  };
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

function buildVisionPrompt(answers: InterviewAnswers, feedback?: string): string {
  const qa: [string, string][] = [
    ['What are you building', answers.whatBuilding],
    ['Who it is for', answers.whoFor],
    ['The current pain without this tool', answers.currentPain],
    ['The moment they reach for it', answers.triggerMoment],
    ['The first experience', answers.firstExperience],
    ['The one thing it must do well', answers.mustDoWell],
    ['What it is NOT', answers.notThis],
    ['What to cut for a one-week MVP', answers.mvpCuts],
    ['How success is measured', answers.successSignal],
    ['The delight moment', answers.delightMoment],
  ];
  const interview = qa.map(([q, a]) => `- ${q}: ${a || '(not answered)'}`).join('\n');

  return `You are drafting a project vision document from a founder interview.
Write a clear, compelling vision in GitHub-flavored Markdown.

Use EXACTLY these headings, in this order, and nothing else:
# Vision
## What We're Building
## Who It's For
## The Problem
### The Trigger
## The Experience
### Core Capability
## Boundaries
### MVP Scope
## Success
### The Delight Moment

Base each section on the interview answers below. Sharpen the language and flow,
but do not invent facts that the answers do not imply. For any answer that is
empty or "(to be determined)", write a short honest placeholder.

Output ONLY the Markdown document — no preamble, no commentary, and do not use
any tools or write any files.
${feedback ? `\nRevision request from the user — apply this: ${feedback}\n` : ''}
Interview answers:
${interview}
`;
}
