"""Fork addendum: Antigravity is reached only through the shared wrapper.

The second-opinion layer used to shell out to `agy` directly with stderr sent
to /dev/null, so a rejected model slug looked like an empty, agreeing answer.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
ANTIGRAVITY_DOCS = (
    REPO_ROOT / ".claude/rules/antigravity-delegation.md",
    REPO_ROOT / ".claude/skills/antigravity-system/SKILL.md",
)


def load_antigravity_router() -> ModuleType:
    path = REPO_ROOT / ".claude/hooks/antigravity-router.py"
    spec = importlib.util.spec_from_file_location("antigravity_router", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_hook(prompt: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(REPO_ROOT / ".claude/hooks/antigravity-router.py")],
        input=json.dumps({"prompt": prompt}),
        capture_output=True,
        text=True,
        timeout=20,
    )


@pytest.mark.parametrize(
    "prompt",
    [
        "Can I get a second opinion on this design?",
        "get a second opinion from Gemini",
        "ask another model about it",
        "use a different model to review the plan",
        "check it with another model family: other model family please",
        "ask antigravity about the schema",
        "run agy on this plan",
        "この設計にセカンドオピニオンがほしい",
        "別のモデルにも聞いて",
        "他のモデルの意見も見たい",
        "別モデルで確認して",
        "Codex と別のモデルで確認、Gemini も使って",
        "Ask Codex and Gemini for a second opinion",
    ],
)
def test_explicit_different_model_requests_get_a_hint(prompt: str) -> None:
    router = load_antigravity_router()

    assert router.detect_trigger(prompt) is not None, prompt


@pytest.mark.parametrize(
    "prompt",
    [
        "Please cross-check the generated CSV against the input rows",
        "Ask Fable for a second opinion on this stuck design",
        "Get a second opinion using Codex with --sandbox read-only",
        "/codex:review get another model view",
        "Opus と Sonnet のセカンドオピニオンがほしい",
        "Codex と別のモデルで確認",
        "design the retry logic",
        "agyness is not a trigger",
        "",
    ],
)
def test_other_prompts_get_no_hint(prompt: str) -> None:
    router = load_antigravity_router()

    assert router.detect_trigger(prompt) is None, prompt


def test_executor_names_inside_paths_do_not_suppress_the_hint() -> None:
    router = load_antigravity_router()

    prompt = "second opinion on .claude/rules/delegation.md and .codex/config.toml"

    assert router.detect_trigger(prompt) == "second opinion"


def test_hook_emits_additional_context_json_for_a_trigger() -> None:
    result = run_hook("get a second opinion from gemini")

    assert result.returncode == 0
    output = json.loads(result.stdout)["hookSpecificOutput"]
    assert output["hookEventName"] == "UserPromptSubmit"
    assert "antigravity-system" in output["additionalContext"]
    assert "cli_consult.py --cli antigravity" in output["additionalContext"]
    assert "fable-advisor" in output["additionalContext"]


def test_hook_is_silent_without_a_trigger_and_on_bad_input() -> None:
    quiet = run_hook("cross-check the CSV")
    broken = subprocess.run(
        [sys.executable, str(REPO_ROOT / ".claude/hooks/antigravity-router.py")],
        input="not json",
        capture_output=True,
        text=True,
        timeout=20,
    )

    assert (quiet.returncode, quiet.stdout) == (0, "")
    assert (broken.returncode, broken.stdout) == (0, "")


def test_hook_is_registered_after_agent_router() -> None:
    settings = json.loads(
        (REPO_ROOT / ".claude/settings.json").read_text(encoding="utf-8")
    )

    commands = [
        hook["command"]
        for entry in settings["hooks"]["UserPromptSubmit"]
        for hook in entry["hooks"]
    ]

    router = next(i for i, c in enumerate(commands) if "agent-router.py" in c)
    assert "antigravity-router.py" in commands[router + 1]


def test_antigravity_model_carries_an_explicit_thinking_level() -> None:
    settings = json.loads(
        (REPO_ROOT / ".claude/settings.json").read_text(encoding="utf-8")
    )

    # `agy` rejects a bare `gemini-3.1-pro` unless `--effort` is also passed.
    assert settings["env"]["ANTIGRAVITY_MODEL"] == "gemini-3.1-pro-high"


def test_antigravity_docs_use_the_wrapper_and_never_hide_stderr() -> None:
    for path in ANTIGRAVITY_DOCS:
        content = path.read_text(encoding="utf-8")

        assert "cli_consult.py --cli antigravity" in content, path
        assert "2>/dev/null" not in content, path
        assert "agy -p" not in content, path
        assert "agy --model" not in content, path
