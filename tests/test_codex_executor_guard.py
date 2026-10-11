"""Tests for .claude/hooks/codex-executor-guard.py (Codex PreToolUse hook)."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
HOOK = REPO_ROOT / ".claude" / "hooks" / "codex-executor-guard.py"
_spec = importlib.util.spec_from_file_location("codex_executor_guard", HOOK)
assert _spec is not None and _spec.loader is not None
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)

EXECUTOR = {"ORCHESTRA_ROLE": "executor"}


def bash(command: str) -> dict:
    """A PreToolUse payload as Codex 0.162 sends it for a shell command."""
    return {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
    }


def run_hook(payload: dict, role: str | None) -> subprocess.CompletedProcess[str]:
    env = {k: v for k, v in os.environ.items() if k != "ORCHESTRA_ROLE"}
    if role is not None:
        env["ORCHESTRA_ROLE"] = role
    return subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


@pytest.mark.parametrize(
    "command",
    [
        'codex exec "hi"',
        "/usr/bin/codex exec hi",
        "env FOO=1 codex exec hi",
        "timeout 30 codex exec hi",
        "npx -y @openai/codex exec hi",
        'bash -c "codex exec hi; echo done"',
        "sh -c 'claude -p hi'",
        "echo $(codex exec hi)",
        "echo `agy -p hi`",
        "ls && claude -p hi",
        'eval "codex exec hi"',
        "node /x/node_modules/@openai/codex/bin/codex.js exec hi",
        "python3 .claude/skills/_shared/codex_consult.py --prompt-file p.md",
        "uv run python .claude/skills/_shared/cli_consult.py --cli antigravity",
        "ORCHESTRA_ROLE=main python3 .claude/skills/_shared/codex_consult.py",
        "env -u ORCHESTRA_ROLE python3 x.py",
        "unset CODEX_HOME; ls",
        "CLAUDE_CONFIG_DIR=$HOME/.claude claude -p hi",
    ],
)
def test_executor_shell_commands_that_delegate_are_denied(command: str) -> None:
    assert guard.decide(bash(command), EXECUTOR) is not None


@pytest.mark.parametrize(
    "command",
    [
        "cat .claude/skills/_shared/codex_consult.py",
        "grep -rn codex .",
        'rg "claude -p" README.md',
        "echo codex",
        "printenv ORCHESTRA_ROLE",
        "uv run pytest -q tests/test_codex_consult.py",
        "python3 -m pytest tests/test_cli_consult.py",
        "python3 script.py codex",
        "git log --oneline",
        "bash -c 'echo hi'",
        'bash -c "echo \\"unbalanced',
    ],
)
def test_executor_ordinary_shell_commands_are_allowed(command: str) -> None:
    assert guard.decide(bash(command), EXECUTOR) is None


@pytest.mark.parametrize(
    "tool_name",
    ["collaborationspawn_agent", "collaborationwait_agent", "spawn_agent"],
)
def test_executor_collaboration_tools_are_denied(tool_name: str) -> None:
    payload = {"tool_name": tool_name, "tool_input": {"task_name": "x"}}
    assert guard.decide(payload, EXECUTOR) is not None


def test_executor_other_tools_are_allowed() -> None:
    assert guard.decide({"tool_name": "apply_patch"}, EXECUTOR) is None


@pytest.mark.parametrize("role", [None, "main"])
def test_outside_an_executor_everything_is_allowed(role: str | None) -> None:
    result = run_hook(bash('codex exec "hi"'), role)

    assert result.returncode == 0
    assert result.stdout == ""


def test_deny_is_reported_in_the_pretooluse_format_codex_honours() -> None:
    result = run_hook({"tool_name": "collaborationspawn_agent"}, "executor")

    assert result.returncode == 0
    output = json.loads(result.stdout)["hookSpecificOutput"]
    assert output["hookEventName"] == "PreToolUse"
    assert output["permissionDecision"] == "deny"
    assert "executor" in output["permissionDecisionReason"]


def test_malformed_input_is_ignored() -> None:
    result = subprocess.run(
        [sys.executable, str(HOOK)],
        input="not json",
        capture_output=True,
        text=True,
        env={**os.environ, **EXECUTOR},
        check=False,
    )

    assert result.returncode == 0
    assert result.stdout == ""
