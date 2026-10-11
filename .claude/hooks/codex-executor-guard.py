#!/usr/bin/env python3
"""Codex PreToolUse hook: stop a delegated executor from delegating again.

`codex_consult.py` registers it for every tool on the Codex it starts (a
session `--config`, so it applies whatever the working directory). It acts
only when the process carries `ORCHESTRA_ROLE=executor`, which the same
wrapper sets; anywhere else it allows everything and prints nothing.

Under the executor role it denies:
- every collaboration tool (`spawn_agent`, `wait_agent`, ...): Codex names
  them `collaboration<tool>` in the hook payload;
- shell commands that start another agent CLI (`codex`, `claude`, `agy`,
  directly, by path, or through `env`, `npx`, `bash -c`, ...) or run the
  cross-CLI wrappers;
- shell commands that rewrite the environment the other layers rely on
  (`ORCHESTRA_ROLE`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`).

It is one layer, not the only one: the wrappers refuse to run under the
executor role by themselves, and the executor's shell environment makes a
nested `codex` or `claude` fail to start (see `codex_consult.py`). A command
the parser below cannot see through -- one assembled at run time from encoded
text -- is what those layers are for.

The deny answer uses the PreToolUse output Codex 0.162 honours:
`hookSpecificOutput.permissionDecision = "deny"`.
"""

import json
import os
import re
import shlex
import sys

ROLE_ENV = "ORCHESTRA_ROLE"
ROLE_EXECUTOR = "executor"

AGENT_CLIS = frozenset({"codex", "claude", "agy"})
WRAPPERS = frozenset({"codex_consult.py", "cli_consult.py"})
# Programs that run the command named in their arguments.
LAUNCHERS = frozenset(
    {
        "env",
        "exec",
        "command",
        "nohup",
        "nice",
        "timeout",
        "time",
        "sudo",
        "xargs",
        "stdbuf",
        "setsid",
        "npx",
        "bunx",
        "pnpx",
    }
)
SHELLS = frozenset({"bash", "sh", "zsh", "dash", "ksh"})
PROTECTED_ENV_RE = re.compile(r"\b(ORCHESTRA_ROLE|CODEX_HOME|CLAUDE_CONFIG_DIR)\b")
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MAX_DEPTH = 3


def _program_name(token: str) -> str:
    """Basename of a command word, without a version suffix or `.js`."""
    name = token.rsplit("/", 1)[-1]
    name = re.sub(r"\.(js|cjs|mjs)$", "", name)
    # npx package specs: `@openai/codex@latest` -> codex
    return name.split("@", 1)[0] if not name.startswith("@") else name


def _is_python(name: str) -> bool:
    return re.fullmatch(r"python(\d+(\.\d+)?)?", name) is not None


def _blocked_segment(tokens: list[str], depth: int) -> str | None:
    """Return why this simple command is blocked, or None."""
    index = 0
    while index < len(tokens) and ASSIGNMENT_RE.match(tokens[index]):
        index += 1
    while index < len(tokens):
        name = _program_name(tokens[index])
        if name in AGENT_CLIS:
            return f"starts the agent CLI `{name}`"
        if name in WRAPPERS:
            return f"runs the delegation wrapper `{name}`"
        if name in ("uv", "uvx"):
            # `uv run [options] <command...>` runs the command that follows.
            index += 1
            while index < len(tokens) and (
                tokens[index] == "run" or tokens[index].startswith("-")
            ):
                index += 1
            continue
        if name == "node" or _is_python(name):
            # The interpreter runs its first non-option argument.
            script = next(
                (
                    argument
                    for argument in tokens[index + 1 :]
                    if not argument.startswith("-")
                ),
                "",
            )
            target = _program_name(script)
            if target in AGENT_CLIS:
                return f"starts the agent CLI `{target}`"
            if target in WRAPPERS:
                return f"runs the delegation wrapper `{target}`"
            return None
        if name in SHELLS:
            if "-c" in tokens[index + 1 :]:
                script_index = tokens.index("-c", index + 1) + 1
                if script_index < len(tokens):
                    return blocked_reason(tokens[script_index], depth + 1)
            return None
        if name == "eval":
            return blocked_reason(" ".join(tokens[index + 1 :]), depth + 1)
        if name in LAUNCHERS:
            index += 1
            # Skip the launcher's own options and assignments (`env -u X`,
            # `timeout 5`, `npx -y`).
            while index < len(tokens) and (
                tokens[index].startswith("-")
                or ASSIGNMENT_RE.match(tokens[index])
                or tokens[index].isdigit()
                or re.fullmatch(r"\d+[smhd]", tokens[index])
            ):
                index += 1
            continue
        return None
    return None


def _segments(command: str) -> list[list[str]]:
    """Split *command* into simple commands, respecting shell quoting.

    Operators (`;`, `&&`, `|`, parentheses, `$(`) end a segment; backticks and
    newlines are treated the same way. Unbalanced quoting falls back to a
    plain split with the quotes stripped, so it cannot hide a command word.
    """
    text = command.replace("`", " ; ").replace("\n", " ; ")
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = [
            part.strip("'\"")
            for part in re.split(r"(\|\||&&|[;|&()])|\s+", text)
            if part and part.strip("'\"")
        ]
    segments: list[list[str]] = [[]]
    for token in tokens:
        if token and all(char in "();<>|&$" for char in token):
            segments.append([])
            continue
        segments[-1].append(token)
    return [segment for segment in segments if segment]


def blocked_reason(command: str, depth: int = 0) -> str | None:
    """Return why an executor may not run *command*, or None if it may."""
    if depth > MAX_DEPTH:
        return "nests shells too deeply to inspect"
    if PROTECTED_ENV_RE.search(command) and re.search(
        r"(\b(ORCHESTRA_ROLE|CODEX_HOME|CLAUDE_CONFIG_DIR)=|\bunset\s|\benv\s+(-\S+\s+)*-u)",
        command,
    ):
        return "rewrites the executor's role environment"
    for tokens in _segments(command):
        reason = _blocked_segment(tokens, depth)
        if reason:
            return reason
    return None


def decide(payload: dict, environ: dict[str, str]) -> str | None:
    """Return a deny reason for *payload*, or None to allow it."""
    if environ.get(ROLE_ENV) != ROLE_EXECUTOR:
        return None
    tool_name = str(payload.get("tool_name", ""))
    if tool_name.startswith("collaboration") or "spawn_agent" in tool_name:
        return (
            f"`{tool_name}` is a sub-agent tool and this Codex is a delegated "
            "executor: do the task yourself"
        )
    if tool_name != "Bash":
        return None
    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
    if not isinstance(command, str):
        return None
    reason = blocked_reason(command)
    if reason is None:
        return None
    return (
        f"this command {reason}; a delegated executor does the task itself "
        "and reports back to its caller"
    )


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    if not isinstance(payload, dict):
        return 0
    reason = decide(payload, dict(os.environ))
    if reason is None:
        return 0
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": f"[orchestra executor guard] {reason}",
                }
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
