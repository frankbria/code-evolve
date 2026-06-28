import readline from 'readline';

/**
 * Build an `ask(question)` helper over a readline interface that works for both
 * interactive (TTY) and piped (non-TTY) input.
 *
 * A line-queue decouples our await pace from readline's emit pace, so piped
 * input isn't dropped between questions, and EOF resolves any pending prompt to
 * '' instead of leaving the process hung.
 */
export function makeAsk(rl: readline.Interface): (question: string) => Promise<string> {
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

  return (question: string): Promise<string> => {
    process.stdout.write(question);
    if (queue.length) return Promise.resolve(queue.shift()!);
    if (closed) return Promise.resolve('');
    return new Promise((resolve) => waiters.push(resolve));
  };
}
