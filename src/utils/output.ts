export function isTTY(): boolean {
  return process.stdout.isTTY === true;
}

export function output(data: Record<string, unknown>, humanReadable: string): void {
  if (isTTY()) {
    console.log(humanReadable);
  } else {
    console.log(JSON.stringify(data));
  }
}
