#!/usr/bin/env python3
"""
UserPromptSubmit hook: hint Antigravity for an explicit different-model request.

Antigravity is a verification layer (a different model family reading a
decision), not a tier, so it has its own hook instead of a branch in
agent-router.py. Both hooks may fire on one prompt (agent-router can emit a
Fable hint for "second opinion"); the hints complement each other.

Rule: emit a hint only when the prompt explicitly asks for a *different model
family*. Triggers are matched case-insensitively; English ones on word
boundaries, Japanese ones as substrings.

- "cross-check" is deliberately not a trigger: it usually means a mechanical
  check (compare a CSV against its source), not another model's opinion.
- If the prompt names another executor for the same request (Codex, Fable,
  Opus, Sonnet, Claude, or a `/codex:` command), the user already chose who
  answers, so no hint is emitted -- unless the prompt also names
  antigravity/agy/gemini explicitly, which always wins. For example
  "Codex と別のモデルで確認" is suppressed, "ask Codex and Gemini" is not.
  Paths such as `.claude/rules/x.md` do not count as naming an executor.

Policy: .claude/rules/antigravity-delegation.md
"""

import json
import re
import sys

# Naming the Antigravity family directly is an unambiguous request.
EXPLICIT_TRIGGERS_EN = ["antigravity", "agy", "gemini"]

# Phrases that ask for a different model family without naming it.
GENERIC_TRIGGERS = {
    "en": [
        "second opinion",
        "another model",
        "different model",
        "other model family",
    ],
    "ja": [
        "セカンドオピニオン",
        "別のモデル",
        "他のモデル",
        "別モデル",
    ],
}

# Other executors a prompt may name for the same request. The lookbehind keeps
# path segments like `.claude/` and `.codex/` from counting as a mention.
OTHER_EXECUTOR_RE = re.compile(
    r"(?<![\w./])(?:codex|fable|opus|sonnet|claude)\b|/codex:"
)


def matches_trigger(trigger: str, prompt_lower: str, lang: str) -> bool:
    """Check one trigger against the lowercased prompt.

    English triggers match on word boundaries (optional plural "s"); Japanese
    has no word boundaries, so those stay substring matches.
    """
    if lang != "en":
        return trigger in prompt_lower
    return re.search(rf"\b{re.escape(trigger)}s?\b", prompt_lower) is not None


def detect_trigger(prompt: str) -> str | None:
    """Return the matched trigger when Antigravity should be hinted, else None."""
    prompt_lower = prompt.lower()

    for trigger in EXPLICIT_TRIGGERS_EN:
        if matches_trigger(trigger, prompt_lower, "en"):
            return trigger

    if OTHER_EXECUTOR_RE.search(prompt_lower):
        return None

    for lang, triggers in GENERIC_TRIGGERS.items():
        for trigger in triggers:
            if matches_trigger(trigger, prompt_lower, lang):
                return trigger

    return None


def build_context(trigger: str) -> str:
    """Return the additionalContext hint for a detected trigger."""
    return (
        f"[Antigravity] Detected '{trigger}' — a different-model-family opinion "
        "was requested. Use the antigravity-system skill: write the prompt to a "
        "file, then `python3 .claude/skills/_shared/cli_consult.py --cli "
        'antigravity --model "${ANTIGRAVITY_MODEL:-gemini-3.1-pro-high}" '
        "--prompt-file <path> --label second-opinion`. One opinion per decision; "
        "policy: .claude/rules/antigravity-delegation.md. For in-family "
        "arbitration of a stuck decision, use fable-advisor instead."
    )


def main() -> None:
    try:
        data = json.load(sys.stdin)
        prompt = data.get("prompt", "")
        trigger = detect_trigger(prompt)
        if trigger is None:
            sys.exit(0)

        output = {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": build_context(trigger),
            }
        }
        print(json.dumps(output))
        sys.exit(0)

    except Exception:
        # Never fail the prompt because of a routing hint.
        sys.exit(0)


if __name__ == "__main__":
    main()
