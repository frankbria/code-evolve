import { Command } from 'commander';

/**
 * `vision` and `spec` were TTY interviews; the evolve-setup skill drafts both files now (#97).
 * They stay for one release as pointers so old scripts and habits get told where to go.
 */
function retiredInterview(document: 'vision' | 'spec'): Command {
  return new Command(document)
    .description(`Retired: your agent drafts .evolve/${document}.md with the evolve-setup skill`)
    .option('--refine', 'Ignored; kept so old invocations still get the pointer')
    .action(() => {
      console.log(
        `\`code-evolve ${document}\` is retired: the evolve-setup skill drafts .evolve/${document}.md from your repository.\n` +
          'Run `npx code-evolve` to open your agent on it (or invoke evolve-setup in your agent), ' +
          `edit .evolve/${document}.md yourself, or convert an existing document with \`code-evolve migrate ${document} <file>\`.`,
      );
    });
}

export const visionCommand = retiredInterview('vision');
export const specCommand = retiredInterview('spec');
