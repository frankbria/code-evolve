#!/usr/bin/env python3
"""PreToolUse hook (Claude Code and Codex): refuse edits to code-evolve's protected files.

Reads the hook payload on stdin. Exit 2 blocks the tool call and shows stderr to the agent; exit 0
lets it run. The engine (evolve.sh) still restores protected files after every agent call, so this
hook only saves the wasted turns; it is not the enforcement.
"""
from __future__ import annotations  # `str | None` hints on Python < 3.10

import fnmatch
import json
import os
import re
import shlex
import sys

PROTECTED_LIST = os.path.join(".evolve", "scripts", "protected-paths.txt")
# Keep in sync with templates/scripts/protected-paths.txt (used when an install predates the list).
DEFAULT_PATTERNS = [
    ".evolve/IDENTITY.md",
    ".evolve/scripts/*",
    ".evolve/skills/*",
    ".github/workflows/evolve.yml",
    ".github/workflows/evolve-ci.yml",
]
FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
REDIRECTS = {">", ">>", ">|", "&>", "&>>"}
# shortcut: a write verb anywhere plus a protected path anywhere also blocks copies *out* of a
# protected file (`cp .evolve/IDENTITY.md /tmp`); parse each command's arguments if that bites.
WRITE_COMMAND = re.compile(
    r"(^|[\s;&|(`])(rm|rmdir|unlink|mv|cp|install|ln|tee|truncate|touch|dd|chmod|chown)\s"
    r"|\b(sed|perl)\s+(-\S*\s+)*-i"
    r"|\bgit\s+(checkout|restore|rm|mv)\b"
)
PATCH_FILE_LINE = re.compile(r"^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$", re.MULTILINE)


def find_project_root(start: str) -> str | None:
    directory = os.path.realpath(start)
    while True:
        if os.path.isdir(os.path.join(directory, ".evolve")):
            return directory
        parent = os.path.dirname(directory)
        if parent == directory:
            return None
        directory = parent


def read_patterns(root: str) -> list[str]:
    try:
        with open(os.path.join(root, PROTECTED_LIST), encoding="utf-8") as listing:
            lines = [line.strip() for line in listing]
    except OSError:
        return DEFAULT_PATTERNS
    return [line for line in lines if line and not line.startswith("#")]


def protected_match(path: str, cwd: str, root: str, patterns: list[str]) -> str | None:
    """The project-relative form of `path` if it is protected, or a directory holding protected files."""
    relative = os.path.relpath(os.path.realpath(os.path.join(cwd, path)), root)
    if relative == "." or relative.startswith(".." + os.sep) or relative == "..":
        return None
    relative = relative.replace(os.sep, "/")
    # fnmatch's * also matches "/", like the engine's bash `case` patterns.
    if any(fnmatch.fnmatchcase(relative, pattern) for pattern in patterns):
        return relative
    if any(pattern.startswith(relative + "/") for pattern in patterns):
        return relative
    return None


def command_tokens(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:  # unbalanced quotes: fall back to plain words
        return command.split()


def blocked_by_shell_command(command: str, cwd: str, root: str, patterns: list[str]) -> str | None:
    tokens = command_tokens(command)
    redirect_targets = [tokens[i + 1] for i, token in enumerate(tokens[:-1]) if token in REDIRECTS]
    for target in redirect_targets:
        match = protected_match(target, cwd, root, patterns)
        if match:
            return match
    if not WRITE_COMMAND.search(command):
        return None
    for token in tokens:
        if token.startswith("-") or token in REDIRECTS:
            continue
        match = protected_match(token, cwd, root, patterns)
        if match:
            return match
    return None


def blocked_path(payload: dict, root: str, patterns: list[str]) -> str | None:
    cwd = payload.get("cwd") or os.getcwd()
    tool = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") or {}
    if tool in FILE_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path")
        return protected_match(path, cwd, root, patterns) if path else None
    command = tool_input.get("command") or ""
    if tool == "apply_patch":  # Codex: the patch text names every file it touches
        for path in PATCH_FILE_LINE.findall(command):
            match = protected_match(path.strip(), cwd, root, patterns)
            if match:
                return match
        return None
    if tool == "Bash":
        return blocked_by_shell_command(command, cwd, root, patterns)
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    root = find_project_root(payload.get("cwd") or os.getcwd())
    if root is None:
        return 0
    path = blocked_path(payload, root, read_patterns(root))
    if path is None:
        return 0
    print(
        f"code-evolve: {path} is protected (see {PROTECTED_LIST}). The evolution engine restores "
        "protected files after every agent call, so this change would be undone. Leave it as it is; "
        "if the user wants it changed, they edit it themselves outside the agent.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
