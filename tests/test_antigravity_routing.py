"""Fork addendum: Antigravity is reached only through the shared wrapper.

The second-opinion layer used to shell out to `agy` directly with stderr sent
to /dev/null, so a rejected model slug looked like an empty, agreeing answer.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType

REPO_ROOT = Path(__file__).resolve().parents[1]
ANTIGRAVITY_DOCS = (
    REPO_ROOT / ".claude/rules/antigravity-delegation.md",
    REPO_ROOT / ".claude/skills/antigravity-system/SKILL.md",
)


def load_agent_router() -> ModuleType:
    path = REPO_ROOT / ".claude/hooks/agent-router.py"
    spec = importlib.util.spec_from_file_location("agent_router_ag", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_explicit_second_opinion_requests_route_to_antigravity() -> None:
    router = load_agent_router()

    for prompt in (
        "Can I get a second opinion on this design?",
        "please cross-check the migration plan",
        "ask another model about it",
        "この設計にセカンドオピニオンがほしい",
        "別のモデルにも聞いて",
    ):
        assert router.detect_agent(prompt)[0] == "antigravity", prompt


def test_ordinary_design_question_still_routes_to_codex() -> None:
    router = load_agent_router()

    assert router.detect_agent("どう設計すべき?")[0] == "codex"


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
