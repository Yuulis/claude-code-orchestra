---
name: antigravity-system
description: |
  Antigravity CLI (agy, Gemini 3.x) provides cross-model second opinions:
  independent review of designs/plans, tiebreaking between competing
  approaches, and pre-ship verification by a different model family. May also
  assist information gathering as needed (primary research lane stays the
  general-purpose subagent). NOT for planning/implementation (use Codex),
  NOT for multimodal (Claude handles directly).
  Explicit triggers: "second opinion", "cross-check", "another model",
  "セカンドオピニオン", "別のモデル".
metadata:
  short-description: Antigravity CLI — cross-model second opinions (Gemini 3.x)
---

# Antigravity System — Cross-Model Second Opinion

**Antigravity CLI (`agy`) brings Gemini 3.x into the orchestra as an independent verifier.**

> **Preflight:** Before delegating, verify availability — `command -v agy && agy models`.
> If either fails, skip the second opinion, fall back to Codex-only review, and say so
> explicitly ("Antigravity skipped; using Codex-only review"). Run `agy update` when
> calls fail or the model list drifts — not as a mandatory per-session step.
> **Delegation policy (when to delegate)**: `.claude/rules/antigravity-delegation.md`

## Role

A third, independent perspective on top of Claude (orchestration) and Codex
(design/implementation). Antigravity **verifies — it does not author**:

- Cross-examine a design or implementation plan before user approval
- Tiebreak when Claude and Codex disagree on an approach
- Pre-ship review with a different model family's blind spots
- Auxiliary: assist the information-gathering phase as needed (primary research
  lane stays the Opus general-purpose subagent)

## When to Delegate

Delegation policy — when to consult, when NOT to, and the prompt contract — lives in
`.claude/rules/antigravity-delegation.md` (SSOT). This skill covers *how* to consult.

## How to Consult

### Model Selection

Centralized in `.claude/settings.json` (`env.ANTIGRAVITY_MODEL`), same pattern as
`CODEX_MODEL`. Default: `gemini-3.1-pro` (deep review). Use `gemini-3.5-flash` for
quick sanity checks. List current options: `agy models`.

### Direct Call (short questions, responses up to ~50 lines)

```bash
agy --model "${ANTIGRAVITY_MODEL:-gemini-3.1-pro}" --sandbox -p "
Review this decision: {single-sentence decision}
Proposal: {summary of the design/plan under review}
Constraints:
- {constraint 1}
Identify flaws, risks, and superior alternatives — do not restate the proposal.
Output format:
## Verdict (agree / disagree / agree-with-changes)
## Flaws & Risks
## Alternatives
## Recommendation
" 2>/dev/null
```

- `--sandbox` restricts terminal actions — always use it for review-only consultations.
- `-p` / `--print` runs non-interactively; default `--print-timeout` is 5m.
- Never use `--dangerously-skip-permissions`.
- `2>/dev/null` hides auth/binary errors — an **empty response means failure**, not
  agreement. Re-run without `2>/dev/null` to see the error, or treat as "skipped".

### Subagent Pattern (large proposals, preserve main context)

```
Agent tool parameters:
- subagent_type: "general-purpose"
- run_in_background: true (optional)
- prompt: |
    Get a second opinion from Antigravity on: {topic}

    agy --model "${ANTIGRAVITY_MODEL:-gemini-3.1-pro}" --sandbox -p "
    {prompt contract per .claude/rules/antigravity-delegation.md}
    " 2>/dev/null

    Return CONCISE summary: verdict + top flaws/risks + recommendation.
```

### Task Templates

#### Cross-Examine a Codex Design

```bash
agy --model "${ANTIGRAVITY_MODEL:-gemini-3.1-pro}" --sandbox -p "
An implementation plan was produced by another model. Cross-examine it.

Feature: {feature}
Plan: {Codex's plan, condensed}
Constraints: {constraints}

1. What failure modes does this plan miss?
2. Where is it over- or under-engineered?
3. Would you structure it differently? Why?
Be adversarial; do not restate the plan.
" 2>/dev/null
```

#### Tiebreak Two Approaches

```bash
agy --model "${ANTIGRAVITY_MODEL:-gemini-3.1-pro}" --sandbox -p "
Two approaches are under consideration for: {problem}
Option A: {summary}
Option B: {summary}
Constraints: {constraints}
Pick one, justify with concrete trade-offs, and state what would change your answer.
" 2>/dev/null
```

#### Quick Sanity Check (fast model)

```bash
agy --model gemini-3.5-flash --sandbox -p "Sanity-check: {brief claim or decision}" 2>/dev/null
```

## Integrating the Result

- Treat Antigravity's output as **one reviewer's opinion**, not a verdict. Claude
  synthesizes: where Codex and Antigravity agree, proceed; where they conflict,
  surface the disagreement to the user with your own recommendation.
- One second opinion per decision — do not ping-pong models.
- Calls are logged to `.claude/logs/cli-tools.jsonl` (same hook as Codex).

## What This Skill Is NOT For

| Task | Correct Owner |
|------|---------------|
| Research / web survey (primary lane) | general-purpose subagent (Opus) — agy may assist as needed, not by default |
| Codebase analysis | general-purpose subagent (Opus 1M) |
| Planning, design, implementation | Codex CLI (codex-system skill) |
| Debugging | Codex CLI / codex-debugger |
| Multimodal (PDF/image/video/audio) | Claude directly |

## Language Protocol

See `.claude/rules/language.md` (SSOT): ask Antigravity in English, receive in English,
report to the user per that rule.

## Setup & Troubleshooting

```bash
# Install (macOS/Linux)
curl -fsSL https://antigravity.google/cli/install.sh | bash

# Verify
agy --version && agy models

# Update
agy update
```

- Auth: browser-based Google Sign-In (system keyring). Over SSH, the CLI prints an
  authorization URL + one-time code.
- CI/scripting: set `ANTIGRAVITY_API_KEY` env var (never hardcode).
- If `agy models` fails, re-authenticate before delegating; fall back to Codex-only
  review and tell the user the second opinion was skipped.
