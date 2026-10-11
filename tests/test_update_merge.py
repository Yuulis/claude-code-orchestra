"""Install/update behaviour for projects that already have their own content.

``scripts/update.sh`` used to replace every template-owned directory
wholesale, so a project's own skills, agents, and hooks disappeared on the
next update with no warning and no backup. These tests pin the per-entry
merge: template entries are replaced, entries the template dropped are removed
only when the manifest says the template installed them, everything else is
kept and reported, and nothing replaced or removed is lost.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
from pathlib import Path
from types import ModuleType

REPO_ROOT = Path(__file__).resolve().parents[1]


def _load_module(path: Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Reuse the installer test helpers rather than copying them.
helpers = _load_module(
    REPO_ROOT / "tests" / "test_install_script.py", "install_helpers_for_merge"
)


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def commit_all(repo: Path, message: str) -> None:
    git(repo, "add", "-A")
    git(
        repo,
        "-c",
        "user.email=test@example.com",
        "-c",
        "user.name=Test",
        "commit",
        "-qm",
        message,
    )


def installed_project(tmp_path: Path) -> tuple[Path, Path]:
    template = helpers.build_template_repo(tmp_path)
    target = tmp_path / "project"
    helpers.init_git_repo(target)
    result = helpers.run_install(target, script=template / "scripts/install.sh")
    assert result.returncode == 0, result.stdout + result.stderr
    return template, target


def add_user_entries(target: Path) -> None:
    skill = target / ".claude/skills/my-own-skill/SKILL.md"
    skill.parent.mkdir(parents=True)
    skill.write_text("---\nname: my-own-skill\n---\nMine.\n", encoding="utf-8")
    (target / ".claude/agents/my-agent.md").write_text("mine\n", encoding="utf-8")
    (target / ".claude/hooks/my-hook.py").write_text("print()\n", encoding="utf-8")
    (target / ".claude/rules/my-rule.md").write_text("mine\n", encoding="utf-8")
    (target / ".agents/skills/my-own-skill").symlink_to(
        "../../.claude/skills/my-own-skill"
    )
    codex_only = target / ".agents/skills/my-codex/SKILL.md"
    codex_only.parent.mkdir(parents=True)
    codex_only.write_text("---\nname: my-codex\n---\nCodex.\n", encoding="utf-8")


def run_check(target: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(target / "scripts/check.sh")],
        check=False,
        capture_output=True,
        text=True,
    )


def test_install_writes_a_manifest_of_template_entries(tmp_path: Path) -> None:
    _, target = installed_project(tmp_path)

    manifest = (target / ".claude/orchestra-manifest").read_text(encoding="utf-8")
    entries = {line for line in manifest.splitlines() if not line.startswith("#")}

    assert ".claude/skills/context-loader" in entries
    assert ".claude/agents/general-purpose-opus.md" in entries
    assert ".claude/hooks/agent-router.py" in entries
    assert ".agents/skills/context-loader" in entries
    assert not any("__pycache__" in entry for entry in entries)


def test_update_keeps_project_owned_entries_and_reports_them(
    tmp_path: Path,
) -> None:
    template, target = installed_project(tmp_path)
    add_user_entries(target)

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    for kept in (
        ".claude/skills/my-own-skill/SKILL.md",
        ".claude/agents/my-agent.md",
        ".claude/hooks/my-hook.py",
        ".claude/rules/my-rule.md",
        ".agents/skills/my-codex/SKILL.md",
    ):
        assert (target / kept).is_file(), kept
        assert kept.rsplit("/SKILL.md", 1)[0] in result.stdout
    assert (target / ".agents/skills/my-own-skill").is_symlink()
    # Project-owned entries are not template content, so check.sh accepts them.
    checked = run_check(target)
    assert checked.returncode == 0, checked.stdout


def test_update_backs_up_local_edits_to_template_files(tmp_path: Path) -> None:
    template, target = installed_project(tmp_path)
    tiers = target / ".claude/rules/tiers.md"
    tiers.write_text("local edit\n", encoding="utf-8")
    statusline = target / ".claude/statusline.py"
    statusline.write_text("print('mine')\n", encoding="utf-8")

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert tiers.read_text(encoding="utf-8") == (
        template / ".claude/rules/tiers.md"
    ).read_text(encoding="utf-8")
    backups = list(target.glob(".orchestra-backup-update-*"))
    assert len(backups) == 1
    assert (backups[0] / ".claude/rules/tiers.md").read_text(
        encoding="utf-8"
    ) == "local edit\n"
    assert (backups[0] / ".claude/statusline.py").read_text(
        encoding="utf-8"
    ) == "print('mine')\n"
    assert "backed up" in result.stdout


def test_update_with_no_changes_creates_no_backup(tmp_path: Path) -> None:
    template, target = installed_project(tmp_path)

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert list(target.glob(".orchestra-backup-update-*")) == []


def test_update_removes_entries_the_template_dropped_after_backing_up(
    tmp_path: Path,
) -> None:
    template, target = installed_project(tmp_path)
    add_user_entries(target)
    git(template, "rm", "-rq", ".claude/skills/spike")
    commit_all(template, "drop spike")

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert not (target / ".claude/skills/spike").exists()
    backups = list(target.glob(".orchestra-backup-update-*"))
    assert len(backups) == 1
    assert (backups[0] / ".claude/skills/spike/SKILL.md").is_file()
    assert ".claude/skills/spike (dropped by the template)" in result.stdout
    assert (target / ".claude/skills/my-own-skill/SKILL.md").is_file()
    manifest = (target / ".claude/orchestra-manifest").read_text(encoding="utf-8")
    assert ".claude/skills/spike" not in manifest.splitlines()


def test_update_without_a_manifest_keeps_unknown_entries_with_a_warning(
    tmp_path: Path,
) -> None:
    """Installs that predate the manifest cannot tell a dropped template entry
    from a project's own, so nothing unknown is removed."""
    template, target = installed_project(tmp_path)
    (target / ".claude/orchestra-manifest").unlink()
    git(template, "rm", "-rq", ".claude/skills/spike")
    commit_all(template, "drop spike")

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / ".claude/skills/spike/SKILL.md").is_file()
    assert "No .claude/orchestra-manifest found" in result.stdout
    assert (target / ".claude/orchestra-manifest").is_file()


def test_update_prints_the_version_change(tmp_path: Path) -> None:
    template, target = installed_project(tmp_path)
    (template / "VERSION").write_text("9.9.9\n", encoding="utf-8")
    commit_all(template, "release")
    old_version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip()

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert f"{old_version} -> 9.9.9" in result.stdout


def test_update_warns_when_settings_reference_a_missing_script(
    tmp_path: Path,
) -> None:
    template, target = installed_project(tmp_path)
    settings = target / ".claude/settings.json"
    settings.write_text(
        settings.read_text(encoding="utf-8").replace(
            ".claude/hooks/agent-router.py", ".claude/hooks/removed-hook.py"
        ),
        encoding="utf-8",
    )

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "references a missing file: .claude/hooks/removed-hook.py" in (result.stdout)


def test_force_reinstall_does_not_copy_the_contract_into_state(
    tmp_path: Path,
) -> None:
    target = tmp_path / "project"
    helpers.init_git_repo(target)
    (target / "AGENTS.md").write_text("# Project rules\n\nKeep me.\n", "utf-8")
    assert helpers.run_install(target).returncode == 0
    state = (target / ".claude/STATE.md").read_text(encoding="utf-8")
    assert state.count("Keep me.") == 1

    result = helpers.run_install(target, "--force")

    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / ".claude/STATE.md").read_text(encoding="utf-8") == state
    assert "is an Orchestra contract" in result.stdout


def test_install_records_a_remote_origin_as_the_update_source(
    tmp_path: Path,
) -> None:
    template = helpers.build_template_repo(tmp_path)
    fork_url = "https://example.com/someone/claude-code-orchestra.git"
    git(template, "remote", "add", "origin", fork_url)
    target = tmp_path / "project"
    helpers.init_git_repo(target)
    env = {k: v for k, v in os.environ.items() if k != "ORCHESTRA_TEMPLATE_REPO"}

    result = subprocess.run(
        ["bash", str(template / "scripts/install.sh"), "--yes", str(target)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / ".claude/orchestra-source").read_text(encoding="utf-8") == (
        fork_url + "\n"
    )


def test_install_falls_back_to_the_fork_for_a_local_origin(tmp_path: Path) -> None:
    """The README installs from a temporary clone, which is gone by the time
    update.sh runs, so a local path is never recorded."""
    template = helpers.build_template_repo(tmp_path)
    git(template, "remote", "add", "origin", str(tmp_path / "somewhere"))
    target = tmp_path / "project"
    helpers.init_git_repo(target)
    env = {k: v for k, v in os.environ.items() if k != "ORCHESTRA_TEMPLATE_REPO"}

    result = subprocess.run(
        ["bash", str(template / "scripts/install.sh"), "--yes", str(target)],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / ".claude/orchestra-source").read_text(encoding="utf-8") == (
        "https://github.com/Yuulis/claude-code-orchestra.git\n"
    )


def test_update_fetches_from_the_recorded_source(tmp_path: Path) -> None:
    template, target = installed_project(tmp_path)
    (target / ".claude/orchestra-source").write_text(f"{template}\n", "utf-8")
    (template / "VERSION").write_text("7.0.0\n", encoding="utf-8")
    commit_all(template, "release")
    env = {k: v for k, v in os.environ.items() if k != "ORCHESTRA_TEMPLATE_REPO"}

    result = subprocess.run(
        ["bash", str(target / "scripts/update.sh"), "--yes"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert f"Template source: {template} (.claude/orchestra-source)" in result.stdout
    assert (target / ".claude/orchestra-version").read_text(
        encoding="utf-8"
    ) == "7.0.0\n"


def test_update_refuses_a_source_that_looks_like_an_option(tmp_path: Path) -> None:
    template, target = installed_project(tmp_path)
    (target / ".claude/orchestra-source").write_text("--upload-pack=true\n", "utf-8")
    env = {k: v for k, v in os.environ.items() if k != "ORCHESTRA_TEMPLATE_REPO"}

    result = subprocess.run(
        ["bash", str(target / "scripts/update.sh"), "--yes"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 1
    assert "Refusing template source" in result.stderr


def test_update_adds_lf_gitattributes_for_older_installs(tmp_path: Path) -> None:
    template, target = installed_project(tmp_path)
    (target / ".gitattributes").unlink()

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    attributes = (target / ".gitattributes").read_text(encoding="utf-8")
    assert "scripts/update.sh text eol=lf" in attributes.splitlines()


def test_force_reinstall_backs_up_an_edited_contract(tmp_path: Path) -> None:
    target = tmp_path / "project"
    helpers.init_git_repo(target)
    assert helpers.run_install(target).returncode == 0
    contract = target / "AGENTS.md"
    edited = contract.read_text(encoding="utf-8") + "\nProject note.\n"
    contract.write_text(edited, encoding="utf-8")

    result = helpers.run_install(target, "--force")

    assert result.returncode == 0, result.stdout + result.stderr
    backups = list(target.glob(".orchestra-backup-*"))
    assert len(backups) == 1
    assert (backups[0] / "AGENTS.md").read_text(encoding="utf-8") == edited
    assert "Project note." not in (target / ".claude/STATE.md").read_text("utf-8")


def test_update_stops_on_an_entry_name_with_a_newline(tmp_path: Path) -> None:
    """Line-based lists cannot represent such a name; merging anyway would
    drop the entry without a backup."""
    template, target = installed_project(tmp_path)
    odd = target / ".claude/skills" / "context-loader\ninit"
    odd.mkdir()
    (odd / "SKILL.md").write_text("odd\n", encoding="utf-8")

    result = helpers.run_update(target, template)

    assert result.returncode != 0
    assert "contains a newline" in result.stderr
    assert (odd / "SKILL.md").read_text(encoding="utf-8") == "odd\n"
    assert helpers.find_debris(target) == []


def test_update_stops_when_a_directory_cannot_be_listed(tmp_path: Path) -> None:
    """A listing failure must not read as an empty directory, which would
    swap in the template and drop the project's entries."""
    template, target = installed_project(tmp_path)
    add_user_entries(target)
    shim_dir = tmp_path / "fake-bin"
    shim_dir.mkdir()
    ls_shim = shim_dir / "ls"
    ls_shim.write_text(
        "#!/usr/bin/env bash\n"
        f'if [[ "${{*}}" == *"{target}/.claude/skills"* ]]; then exit 2; fi\n'
        'exec /bin/ls "$@"\n',
        encoding="utf-8",
    )
    ls_shim.chmod(0o755)

    result = helpers.run_update(target, template, extra_path=shim_dir)

    assert result.returncode != 0
    assert (target / ".claude/skills/my-own-skill/SKILL.md").is_file()
    assert helpers.find_debris(target) == []


def test_update_keeps_a_regular_file_named_after_a_template_skill(
    tmp_path: Path,
) -> None:
    """Only a real directory is a stale pre-2.0 skill copy."""
    template, target = installed_project(tmp_path)
    note = target / ".agents/skills/spike"
    note.write_text("not a skill copy\n", encoding="utf-8")

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert note.read_text(encoding="utf-8") == "not a skill copy\n"


def test_update_replaces_a_regular_file_at_a_template_directory(
    tmp_path: Path,
) -> None:
    template, target = installed_project(tmp_path)
    skills_path = target / ".agents/skills"
    for link in skills_path.iterdir():
        link.unlink()
    skills_path.rmdir()
    skills_path.write_text("oops\n", encoding="utf-8")

    result = helpers.run_update(target, template)

    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / ".agents/skills/context-loader").is_symlink()
    backups = list(target.glob(".orchestra-backup-update-*"))
    assert (backups[0] / ".agents/skills").read_text(encoding="utf-8") == "oops\n"
