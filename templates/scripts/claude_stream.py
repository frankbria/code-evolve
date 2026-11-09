#!/usr/bin/env python3
"""Turn `claude -p --output-format stream-json --verbose` events into a readable log.

Reads the event stream on stdin and prints the assistant's text and one line per tool call.
A failed session (an error event, or a result whose `is_error` is set or whose subtype is not
"success") prints an ERROR_MARKER line for the reader and makes this script exit 1. Under
evolve.sh's pipefail that exit code is the adapter's, so the failure signal is the exit status,
which nothing the model writes can forge. Lines that are not JSON (stderr) pass through unchanged.
"""
from __future__ import annotations  # `dict | None` hints on Python < 3.10

import json
import sys

ERROR_MARKER = "code-evolve: agent error"


def summarize_tool(block: dict) -> str:
    tool_input = block.get("input") or {}
    detail = tool_input.get("command") or tool_input.get("file_path") or tool_input.get("pattern") or ""
    return f"-> {block.get('name', 'tool')} {str(detail).splitlines()[0][:120] if detail else ''}".rstrip()


def is_failure(event: dict) -> bool:
    if event.get("type") == "error":
        return True
    return event.get("type") == "result" and (bool(event.get("is_error")) or event.get("subtype") != "success")


def describe(event: dict) -> list[str]:
    kind = event.get("type")
    if kind == "assistant":
        lines = []
        for block in (event.get("message") or {}).get("content") or []:
            if block.get("type") == "text" and block.get("text", "").strip():
                lines.append(block["text"].rstrip())
            elif block.get("type") == "tool_use":
                lines.append(summarize_tool(block))
        return lines
    if kind == "result":
        subtype = event.get("subtype", "unknown")
        if is_failure(event):
            reason = event.get("result") or event.get("api_error_status") or subtype
            return [f"{ERROR_MARKER} ({subtype}): {str(reason).strip()[:500]}"]
        return [f"Session finished ({event.get('num_turns', '?')} turns)."]
    if kind == "error":
        error = event.get("error")
        message = error.get("message") if isinstance(error, dict) else error
        return [f"{ERROR_MARKER}: {message or json.dumps(event)[:500]}"]
    return []


def main() -> int:
    failed = False
    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n")
        try:
            event = json.loads(line)
        except ValueError:
            print(line, flush=True)
            continue
        if not isinstance(event, dict):
            print(line, flush=True)
            continue
        failed = failed or is_failure(event)
        for output in describe(event):
            print(output, flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
