#!/usr/bin/env python3
"""Drive `code-evolve init` under a real pty, answering its interactive prompts.

Spawns the compiled CLI with a controlling terminal (so init's `isTTY` checks
are true), then feeds canned answers as each prompt appears. Two modes:

  decline  agent->1, auth->1, interview offer->"no"
  cancel   agent->1, auth->1, interview offer->"yes", then Ctrl-D to cancel each
           launched interview (vision, then spec)

All terminal output is echoed to our stdout so the caller can grep it.
Usage: _drive_init_pty.py <cli.js> <decline|cancel>
"""
import os
import pty
import select
import sys

cli, mode = sys.argv[1], sys.argv[2]

# Ordered (substring, response) steps; each fires at most once, in order.
EOF = b"\x04"  # Ctrl-D -> readline 'close' -> interview cancels
if mode == "cancel":
    steps = [
        ("Select [1-4]", b"1\n"),
        ("Select [1-2]", b"1\n"),
        ("guided interview", b"yes\n"),
        ("Vision Interview", EOF),
        ("Spec Interview", EOF),
    ]
elif mode == "eof":  # press Ctrl-D at the offer prompt instead of answering
    steps = [
        ("Select [1-4]", b"1\n"),
        ("Select [1-2]", b"1\n"),
        ("guided interview", EOF),
    ]
else:  # decline
    steps = [
        ("Select [1-4]", b"1\n"),
        ("Select [1-2]", b"1\n"),
        ("guided interview", b"no\n"),
    ]

idx = 0


def handle(text: str, write) -> None:
    global idx
    while idx < len(steps) and steps[idx][0] in text:
        write(steps[idx][1])
        idx += 1


pid, fd = pty.fork()
if pid == 0:  # child: exec the CLI with the pty as its controlling terminal
    os.execvp("node", ["node", cli, "init"])
else:  # parent: pump output, answer prompts
    while True:
        try:
            r, _, _ = select.select([fd], [], [], 10)
        except (OSError, ValueError):
            break
        if not r:
            break
        try:
            chunk = os.read(fd, 1024)
        except OSError:
            break
        if not chunk:
            break
        os.write(1, chunk)
        handle(chunk.decode("utf-8", "replace"), lambda b: os.write(fd, b))
    os.waitpid(pid, 0)
