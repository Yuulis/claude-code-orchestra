"""Where the template comes from, and that it arrives with LF line endings.

Two failures from installing this fork into real projects are pinned here:
the updater defaulted to the upstream repository, so updating a fork install
silently downgraded it and deleted the fork's files; and a clone made with
``core.autocrlf=true`` checked the shell scripts out with CRLF, which broke
``install.sh`` and bricked ``update.sh`` (``/usr/bin/env: 'bash\\r'``).
"""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
from pathlib import Path
from types import ModuleType

REPO_ROOT = Path(__file__).resolve().parents[1]
FORK_URL = "https://github.com/Yuulis/claude-code-orchestra.git"
UPSTREAM_OWNER = "DeL-TaiseiOzaki"


def _load_module(path: Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helpers = _load_module(
    REPO_ROOT / "tests" / "test_install_script.py", "install_helpers_for_source"
)


def runtime_files() -> list[Path]:
    """Files an install copies or runs. Review notes are evidence records and
    run logs are generated, so neither counts as runtime content."""
    tracked = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    selected: list[Path] = []
    for relative in tracked:
        if relative.startswith((".claude/docs/reviews/", ".claude/logs/")):
            continue
        if relative.startswith(("scripts/", ".claude/", ".agents/", ".codex/")) or (
            relative in {"AGENTS.md", "pyproject.toml"}
        ):
            path = REPO_ROOT / relative
            if path.is_file() and not path.is_symlink():
                selected.append(path)
    return selected


def test_runtime_and_install_files_never_name_the_upstream_repository() -> None:
    offenders = [
        str(path.relative_to(REPO_ROOT))
        for path in runtime_files()
        if UPSTREAM_OWNER in path.read_text(encoding="utf-8", errors="replace")
    ]

    assert offenders == []


def test_install_and_update_default_to_the_fork() -> None:
    for script in ("scripts/install.sh", "scripts/update.sh"):
        content = (REPO_ROOT / script).read_text(encoding="utf-8")
        match = re.search(r'^DEFAULT_TEMPLATE_REPO="([^"]+)"$', content, re.M)
        assert match, script
        assert match.group(1) == FORK_URL, script


def test_readme_clone_commands_use_the_fork_and_disable_autocrlf() -> None:
    for readme in ("README.md", "README.ja.md"):
        clone_lines = [
            line
            for line in (REPO_ROOT / readme).read_text(encoding="utf-8").splitlines()
            if line.startswith("git clone")
        ]
        assert clone_lines, readme
        for line in clone_lines:
            assert FORK_URL in line, (readme, line)
            assert "core.autocrlf=false" in line, (readme, line)


def test_gitattributes_forces_lf_checkouts() -> None:
    attributes = (REPO_ROOT / ".gitattributes").read_text(encoding="utf-8")

    assert "* text=auto eol=lf" in attributes.splitlines()
    assert "*.png binary" in attributes.splitlines()


def crlf_git_env(tmp_path: Path) -> dict[str, str]:
    """An environment whose global git config turns on autocrlf, the setting
    that produced the CRLF checkouts."""
    config = tmp_path / "crlf.gitconfig"
    config.write_text("[core]\n\tautocrlf = true\n", encoding="utf-8")
    env = {k: v for k, v in os.environ.items() if k != "ORCHESTRA_TEMPLATE_REPO"}
    env["GIT_CONFIG_GLOBAL"] = str(config)
    return env


def test_a_clone_under_autocrlf_checks_scripts_out_with_lf(tmp_path: Path) -> None:
    template = helpers.build_template_repo(tmp_path)
    clone = tmp_path / "clone"

    subprocess.run(
        ["git", "clone", "-q", str(template), str(clone)],
        check=True,
        env=crlf_git_env(tmp_path),
    )

    for script in ("scripts/install.sh", "scripts/update.sh", "scripts/check.sh"):
        assert b"\r\n" not in (clone / script).read_bytes(), script


def test_update_clone_disables_autocrlf_even_without_gitattributes(
    tmp_path: Path,
) -> None:
    """A template version without .gitattributes must not install CRLF
    scripts either: the updater would replace itself with one that no
    longer runs."""
    template = helpers.build_template_repo(tmp_path)
    subprocess.run(
        ["git", "-C", str(template), "rm", "-q", ".gitattributes"], check=True
    )
    subprocess.run(
        ["git", "-C", str(template), "commit", "-qm", "no attributes"], check=True
    )
    target = tmp_path / "project"
    helpers.init_git_repo(target)
    assert (
        helpers.run_install(target, script=template / "scripts/install.sh").returncode
        == 0
    )
    env = crlf_git_env(tmp_path)
    env["ORCHESTRA_TEMPLATE_REPO"] = str(template)

    result = subprocess.run(
        ["bash", str(target / "scripts/update.sh"), "--yes"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    for script in ("scripts/install.sh", "scripts/update.sh", "scripts/check.sh"):
        assert b"\r\n" not in (target / script).read_bytes(), script
