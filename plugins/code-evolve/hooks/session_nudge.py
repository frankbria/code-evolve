#!/usr/bin/env python3
"""SessionStart hook (Claude Code and Codex): one line when code-evolve needs attention, else silence.

- In a git repository without .evolve/: suggest the setup skill.
- When .evolve/config.json records an engine older than this plugin (or none): suggest upgrading.
- When the engine is newer than the plugin: suggest updating the plugin.
Outside a git repository, on any error, and when everything is current, it prints nothing.
It never blocks the session: it always exits 0.
"""
from __future__ import annotations  # `str | None` hints on Python < 3.10

import json
import os
import sys

PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_repository_root(start: str) -> str | None:
    directory = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(directory, ".git")):
            return directory
        parent = os.path.dirname(directory)
        if parent == directory:
            return None
        directory = parent


def version_tuple(version: str) -> tuple[int, ...]:
    pieces = version.replace("+", ".").replace("-", ".").split(".")
    return tuple(int(piece) if piece.isdigit() else 0 for piece in (pieces + ["0", "0", "0"])[:3])


def nudge(cwd: str, plugin_version: str, setup_skill: str) -> str | None:
    root = find_repository_root(cwd)
    if root is None:
        return None
    evolve_dir = os.path.join(root, ".evolve")
    if not os.path.isdir(evolve_dir):
        return f"code-evolve is installed but not set up in this repository; run {setup_skill} to start."
    try:
        with open(os.path.join(evolve_dir, "config.json"), encoding="utf-8") as config_file:
            engine_version = json.load(config_file).get("engineVersion")
    except FileNotFoundError:  # installs older than config.json predate version tracking too
        engine_version = None
    except (OSError, ValueError, AttributeError):
        return None
    if not isinstance(engine_version, str):
        return f"code-evolve: this project's engine predates version tracking; update it with `npx code-evolve@{plugin_version} upgrade`."
    if version_tuple(engine_version) < version_tuple(plugin_version):
        return f"code-evolve: engine {engine_version} is older than the plugin ({plugin_version}); update it with `npx code-evolve@{plugin_version} upgrade`."
    if version_tuple(engine_version) > version_tuple(plugin_version):
        return f"code-evolve: engine {engine_version} is newer than the plugin ({plugin_version}); update the code-evolve plugin."
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        cwd = payload.get("cwd") if isinstance(payload, dict) else None
        with open(os.path.join(PLUGIN_ROOT, "plugin.json"), encoding="utf-8") as manifest:
            plugin_version = json.load(manifest)["version"]
        # Codex sets PLUGIN_ROOT (Claude Code sets only CLAUDE_PLUGIN_ROOT) and names skills with "$".
        setup_skill = "$evolve-setup" if os.environ.get("PLUGIN_ROOT") else "/code-evolve:evolve-setup"
        message = nudge(cwd or os.getcwd(), plugin_version, setup_skill)
    except Exception:  # a nudge must never break session start
        return 0
    if message:
        # systemMessage reaches the user; additionalContext lets the agent act on it (both clients).
        print(json.dumps({
            "systemMessage": message,
            "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": message},
        }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
