---
name: antigravity-system
description: |
  Cross-model second opinion from Antigravity CLI (agy, Gemini): independent
  cross-examination of high-stakes designs/plans, tiebreaks between competing
  approaches, and pre-ship verification by a different model family. A
  verification layer, not a tier: NOT for planning, review, implementation,
  debugging, or research (see .claude/rules/delegation.md).
  Explicit triggers: "second opinion", "cross-check", "another model",
  "セカンドオピニオン", "別のモデル".
metadata:
  short-description: Antigravity CLI — cross-model second opinions (Gemini)
---

# Antigravity System — Cross-Model Second Opinion

**When** to consult is policy: `.claude/rules/antigravity-delegation.md`. This
skill covers **how**.

## Preflight

```bash
command -v agy && agy models
```

If either fails, skip the second opinion and say so explicitly ("Antigravity
skipped: <reason>"). Run `agy update` when calls fail or the model list drifts.
Auth is browser-based Google Sign-In; in CI set `ANTIGRAVITY_API_KEY` (never
hardcode it).

## Model

`ANTIGRAVITY_MODEL` in `.claude/settings.json` `env` (currently
`gemini-3.1-pro-high`). The slug carries the thinking level: `agy` rejects a
bare `gemini-3.1-pro` without `--effort`, and an unknown `--model` exits
non-zero with no fallback. Check `agy models` before changing it.

## Call

Write the prompt to a file, then call the shared wrapper:

```bash
python3 .claude/skills/_shared/cli_consult.py --cli antigravity \
  --model "${ANTIGRAVITY_MODEL:-gemini-3.1-pro-high}" \
  --prompt-file <path> --label second-opinion --caller <your agent name>
```

- The wrapper closes stdin, applies a timeout, captures stdout **and stderr**
  under `.claude/logs/antigravity/`, and prints one JSON object (`ok`,
  `exit_code`, `response_file`, `error`, `edits`, …). Exit codes: `0` ok,
  `1` bad args, `2` `agy` not on PATH, `3` failed or timed out.
- An empty or failed response is a **failure**, never agreement. Read `error`
  and the stderr log, then retry once or report the opinion as skipped.
- `--read-only` is refused for Antigravity (headless auto-approves every tool
  call). Check the `edits` object: a second opinion should have edited nothing.
- For a large proposal, run the call inside a `general-purpose-opus` subagent
  and have it return only verdict + top risks + recommendation.

## Prompt Templates

### Cross-Examine a Design or Plan

```markdown
Decision under review: {single sentence}
Proposal (produced by another model): {condensed design/plan}
Constraints:
- {constraint}

Identify flaws, risks, and superior alternatives — do not restate the proposal.
1. Which failure modes does it miss?
2. Where is it over- or under-engineered?

Output format:
## Verdict (agree / disagree / agree-with-changes)
## Flaws & Risks
## Alternatives
## Recommendation
```

### Tiebreak Two Approaches

```markdown
Decision under review: {problem}
Option A: {summary}
Option B: {summary}
Constraints: {constraints}

Pick one, justify it with concrete trade-offs, and state what evidence would
change your answer. Do not restate the options.

Output format:
## Choice
## Trade-offs
## What Would Change the Answer
```

## Integrating the Result

- Treat it as one reviewer's opinion; the main agent synthesizes (see
  "Conflict Resolution" in `.claude/rules/antigravity-delegation.md`).
- One second opinion per decision — do not ping-pong models.
- Every call is logged to `.claude/logs/cli-tools.jsonl` with `caller`,
  `label`, and `edits`.
