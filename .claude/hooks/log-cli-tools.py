#!/usr/bin/env python3
"""
PostToolUse hook: Log external CLI (Codex, Antigravity) input/output to JSONL file.

Triggers after Bash tool calls containing 'codex' or 'agy' commands.
Logs are stored in .claude/logs/cli-tools.jsonl

All agents (Claude Code, subagents, Codex) can read this log.
"""

import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

LOG_DIR = Path(__file__).parent.parent / "logs"
LOG_FILE = LOG_DIR / "cli-tools.jsonl"


def detect_cli_tool(command: str) -> str | None:
    """Detect which external CLI this command invokes."""
    if re.search(r"\bcodex\s+exec\b", command):
        return "codex"
    if re.search(r"\bagy\s+", command):
        return "antigravity"
    return None


def extract_prompt(command: str, tool: str) -> str | None:
    """Extract prompt from a codex exec / agy print command."""
    if tool == "codex":
        patterns = [
            r'codex\s+exec\s+.*?"([^"]+)"\s*2>/dev/null',
            r"codex\s+exec\s+.*?'([^']+)'\s*2>/dev/null",
        ]
    else:
        # agy ... -p "prompt" / --print "prompt" / --prompt "prompt"
        patterns = [
            r'agy\s+.*?(?:-p|--print|--prompt)\s+"([^"]+)"',
            r"agy\s+.*?(?:-p|--print|--prompt)\s+'([^']+)'",
        ]
    for pattern in patterns:
        match = re.search(pattern, command, re.DOTALL)
        if match:
            return match.group(1).strip()
    return None


def extract_model(command: str) -> str | None:
    """Extract model name from command."""
    match = re.search(r"--model\s+(\S+)", command)
    return match.group(1) if match else None


def truncate_text(text: str, max_length: int = 2000) -> str:
    """Truncate text if too long."""
    if len(text) <= max_length:
        return text
    return text[:max_length] + f"... [truncated, {len(text)} total chars]"


def log_entry(entry: dict) -> None:
    """Append entry to JSONL log file."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def main() -> None:
    # Read hook input from stdin
    try:
        hook_input = json.load(sys.stdin)
    except json.JSONDecodeError:
        return

    # Only process Bash tool calls
    tool_name = hook_input.get("tool_name", "")
    if tool_name != "Bash":
        return

    # Get command and output
    tool_input = hook_input.get("tool_input", {})
    tool_response = hook_input.get("tool_response", {})

    command = tool_input.get("command", "")
    output = tool_response.get("stdout", "") or tool_response.get("content", "")

    # Check if this is an external CLI command (codex / agy)
    tool = detect_cli_tool(command)
    if tool is None:
        return

    prompt = extract_prompt(command, tool)
    default_model = "gpt-5.6-sol" if tool == "codex" else "gemini-3.1-pro"
    model = extract_model(command) or default_model

    if not prompt:
        # Could not extract prompt, skip logging
        return

    # Determine success
    exit_code = tool_response.get("exit_code", 0)
    success = exit_code == 0 and bool(output)

    # Create log entry
    entry = {
        "timestamp": datetime.now(UTC).isoformat(),
        "tool": tool,
        "model": model,
        "prompt": truncate_text(prompt),
        "response": truncate_text(output) if output else "",
        "success": success,
        "exit_code": exit_code,
    }

    log_entry(entry)

    # Output notification via hookSpecificOutput
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "additionalContext": f"[LOG] {tool} call logged to .claude/logs/cli-tools.jsonl",
                }
            }
        )
    )


if __name__ == "__main__":
    main()
