"""Retired or non-existent model IDs must not reappear in runtime files.

A stale model ID in a skill, rule, hook, or config fails only at call time --
`agy` exits non-zero on an unknown `--model`, Codex returns HTTP 400 -- and a
caller that hides stderr reads that as an empty answer. Grepping for them here
turns the failure into a test failure instead.

Scope: everything an agent loads at runtime (`.claude/`, `.codex/`, `.agents/`,
root `AGENTS.md`). Review notes under `.claude/docs/reviews/` are historical
records and are excluded, as are git-ignored files (logs, checkpoints, local
settings) and `tests/` (fixtures may use arbitrary model strings).
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNTIME_PATHS = (".claude", ".codex", ".agents", "AGENTS.md")
EXCLUDED_PREFIXES = (".claude/docs/reviews/",)

RETIRED_MODEL_PATTERNS = {
    "GPT-5 family (superseded by GPT-6)": re.compile(r"\bgpt-5\.\d"),
    "gpt-5.3-codex-spark": re.compile(r"codex-spark"),
    "retired `spark` alias": re.compile(r"--model[ =]+[\"']?spark\b"),
    "gemini-3.5-flash (not offered by agy)": re.compile(r"\bgemini-3\.5-flash"),
    "gpt-6.1-luna (does not exist)": re.compile(r"\bgpt-6\.1-luna\b"),
    "terra lane (no GPT-6 successor)": re.compile(r"\bCODEX_MODEL_TERRA\b"),
}


def runtime_files() -> list[Path]:
    """Tracked and untracked-but-not-ignored files under the runtime paths."""
    listing = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        + list(RUNTIME_PATHS),
        cwd=REPO_ROOT,
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8")
    relative_paths = sorted({path for path in listing.split("\0") if path})
    return [
        REPO_ROOT / path
        for path in relative_paths
        if not path.startswith(EXCLUDED_PREFIXES) and (REPO_ROOT / path).is_file()
    ]


def find_retired_references(paths: list[Path], root: Path = REPO_ROOT) -> list[str]:
    """Return `path:line: label` for every retired-model match in *paths*."""
    hits = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            for label, pattern in RETIRED_MODEL_PATTERNS.items():
                if pattern.search(line):
                    location = path.relative_to(root).as_posix()
                    hits.append(f"{location}:{line_number}: {label}")
    return hits


def test_runtime_file_scan_covers_the_runtime_contracts() -> None:
    scanned = {path.relative_to(REPO_ROOT).as_posix() for path in runtime_files()}

    assert "AGENTS.md" in scanned
    assert ".codex/config.toml" in scanned
    assert ".claude/settings.json" in scanned
    assert not any(path.startswith(EXCLUDED_PREFIXES) for path in scanned)


def test_runtime_files_do_not_reference_retired_models() -> None:
    assert find_retired_references(runtime_files()) == []


def test_retired_model_patterns_detect_known_stale_ids(tmp_path: Path) -> None:
    sample = tmp_path / "sample.md"
    sample.write_text(
        "\n".join(
            (
                'model = "gpt-5.6-sol"',
                "/codex:rescue --model spark fix it",
                "--model gemini-3.5-flash",
                "CODEX_MODEL_TERRA=gpt-6.1-luna",
                'model = "gpt-6.1-sol"  # current model, must not match',
                "--model gpt-6-luna and gpt-6-astra are current too",
            )
        ),
        encoding="utf-8",
    )

    hits = find_retired_references([sample], root=tmp_path)

    assert hits == [
        "sample.md:1: GPT-5 family (superseded by GPT-6)",
        "sample.md:2: retired `spark` alias",
        "sample.md:3: gemini-3.5-flash (not offered by agy)",
        "sample.md:4: gpt-6.1-luna (does not exist)",
        "sample.md:4: terra lane (no GPT-6 successor)",
    ]
