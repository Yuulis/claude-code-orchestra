"""scripts/check.sh in an installed project.

The checker ships with the template, so it has to pass in a real project:
one that keeps its own Claude Code commands, output styles, Codex prompts,
skills, and agents beside the template's. It rejects only paths it knows to be
leftovers of earlier template layouts, and settings that run missing scripts.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def project(tmp_path: Path) -> Path:
    target = tmp_path / "project"
    target.mkdir()
    subprocess.run(["git", "init", "-q", str(target)], check=True)
    result = subprocess.run(
        ["bash", str(REPO_ROOT / "scripts/install.sh"), "--yes", str(target)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return target


def run_check(target: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(target / "scripts/check.sh")],
        check=False,
        capture_output=True,
        text=True,
    )


def write(path: Path, content: str = "x\n") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def test_check_accepts_ordinary_project_entries(project: Path) -> None:
    write(project / ".claude/commands/deploy.md")
    write(project / ".claude/output-styles/terse.md")
    write(project / ".claude/agents/my-agent.md")
    write(project / ".claude/skills/my-skill/SKILL.md", "---\nname: my-skill\n---\n")
    write(project / ".claude/skills/my-skill/helper.py", "print()\n")
    write(project / ".codex/prompts/review.md")
    write(project / ".agents/workflows-notes.txt")
    write(project / ".agents/skills/my-codex/SKILL.md", "---\nname: my-codex\n---\n")

    result = run_check(project)

    assert result.returncode == 0, result.stdout
    assert "FAIL" not in result.stdout


@pytest.mark.parametrize(
    ("written", "flagged"),
    [
        (".agents/workflows/plan.md", ".agents/workflows"),
        (".agents/rules/coding-principles.md", ".agents/rules"),
        (".codex/skills/legacy.md", ".codex/skills"),
        (".codex/prompts/consult.md", ".codex/prompts/consult.md"),
        (".claude/commands/simplify.md", ".claude/commands/simplify.md"),
    ],
)
def test_check_rejects_known_legacy_template_paths(
    project: Path, written: str, flagged: str
) -> None:
    write(project / written)

    result = run_check(project)

    assert result.returncode == 1
    assert f"Legacy template path from an earlier layout: {flagged}" in result.stdout
    assert "FAIL: Native runtime boundaries" in result.stdout


def test_check_rejects_a_codex_skill_copy_of_a_canonical_skill(
    project: Path,
) -> None:
    write(project / ".agents/skills/spike/SKILL.md", "---\nname: spike\n---\n")

    result = run_check(project)

    assert result.returncode == 1
    assert ".agents/skills/spike is a copy" in result.stdout


def test_check_rejects_a_claude_lead_workflow_linked_for_codex(
    project: Path,
) -> None:
    write(
        project / ".agents/skills/my-lead/SKILL.md",
        "---\nname: my-lead\n---\nTask(subagent_type='x')\n",
    )

    result = run_check(project)

    assert result.returncode == 1
    assert "my-lead is a Claude-lead workflow" in result.stdout


def test_check_rejects_settings_that_run_a_missing_script(project: Path) -> None:
    settings = project / ".claude/settings.json"
    settings.write_text(
        settings.read_text(encoding="utf-8").replace(
            ".claude/hooks/agent-router.py", ".claude/hooks/gone.py"
        ),
        encoding="utf-8",
    )

    result = run_check(project)

    assert result.returncode == 1
    assert "references a missing file: .claude/hooks/gone.py" in result.stdout


def test_template_catalog_check_still_covers_template_skills(project: Path) -> None:
    """The manifest exempts project skills, not template ones: a template
    skill missing from the AGENTS.md catalog is still reported."""
    contract = project / "AGENTS.md"
    contract.write_text(
        contract.read_text(encoding="utf-8").replace("`spike`", "spike"),
        encoding="utf-8",
    )

    result = run_check(project)

    assert result.returncode == 1
    assert "Missing skill in AGENTS.md catalog: spike" in result.stdout
