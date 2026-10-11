"""Tests for .claude/skills/_shared/orchestra_role.py."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / ".claude" / "skills" / "_shared" / "orchestra_role.py"
sys.path.insert(0, str(SCRIPT.parent))

import orchestra_role  # noqa: E402


@pytest.mark.parametrize(
    ("environ", "expected"),
    [
        ({}, ("main", "no role signal")),
        (
            {"ORCHESTRA_ROLE": "main", "CLAUDECODE": "1"},
            ("main", "ORCHESTRA_ROLE=main"),
        ),
        ({"ORCHESTRA_ROLE": "executor"}, ("executor", "ORCHESTRA_ROLE=executor")),
        ({"CLAUDECODE": "1"}, ("executor", "CLAUDECODE=1")),
    ],
)
def test_detect_role_follows_the_entry_point_signals(
    environ: dict[str, str], expected: tuple[str, str]
) -> None:
    assert orchestra_role.detect_role(environ) == expected


def test_refusal_only_for_executor_and_unknown_values() -> None:
    assert orchestra_role.role_refusal({}) is None
    assert orchestra_role.role_refusal({"ORCHESTRA_ROLE": "main"}) is None
    # Claude Code itself may delegate: CLAUDECODE alone is not a refusal.
    assert orchestra_role.role_refusal({"CLAUDECODE": "1"}) is None
    assert "nested delegation" in str(
        orchestra_role.role_refusal({"ORCHESTRA_ROLE": "executor"})
    )
    assert "not a known role" in str(
        orchestra_role.role_refusal({"ORCHESTRA_ROLE": "exector"})
    )


def run_script(environ: dict[str, str]) -> subprocess.CompletedProcess[str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in ("ORCHESTRA_ROLE", "CLAUDECODE")
    }
    env.update(environ)
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


def test_cli_reports_the_role_as_json() -> None:
    result = run_script({"ORCHESTRA_ROLE": "executor"})

    assert result.returncode == 0
    assert json.loads(result.stdout) == {
        "ok": True,
        "role": "executor",
        "signal": "ORCHESTRA_ROLE=executor",
    }


def test_cli_rejects_an_unknown_role() -> None:
    result = run_script({"ORCHESTRA_ROLE": "boss"})

    assert result.returncode == 1
    assert json.loads(result.stdout)["ok"] is False
