# Antigravity Delegation Rule

**Antigravity CLI (`agy`, Gemini 3.x) provides cross-model second opinions on Codex-produced designs/plans and pre-ship risk assessments.**

It does not add a third code-review lane — raw implementation review stays with
`/codex:review` and `/team-execute --review-only`. Antigravity examines *judgments*
(designs, plans, synthesized risk assessments), not diffs by default.

> Antigravity CLI is the successor to Gemini CLI (rebranded 2026-05, Gemini CLI retired 2026-06).
> Its old roles are NOT restored: multimodal → Claude directly, research → primarily Opus subagents
> (Antigravity may assist in the information-gathering phase as needed — see below).
> The primary role is **independent verification by a different model family**.
>
> Preflight: ensure the CLI is current (see antigravity-system skill).

## Role: Cross-Model Second Opinion

Claude-led planning with Codex implementation (`.claude/rules/codex-delegation.md`,
`.claude/rules/model-routing.md`) remains the default pipeline. Antigravity adds a
**third, independent perspective** (Gemini 3.x) on top of Claude + Codex — it
verifies, it does not author.

### Auxiliary Research Role

During the information-gathering phase, Antigravity may be used **as needed** to
supplement the primary research lane (Opus `general-purpose` subagent) — e.g., to
get a different model family's read on ambiguous external information. This is an
auxiliary option, not a default lane; routine research still goes to Opus subagents.

## When to Use Antigravity

Consult Antigravity when **any** of these apply:

- A Codex-produced design/plan has high stakes (architecture, data model, security-sensitive)
  and you want independent cross-examination before user approval.
- Claude and Codex disagree, or you are uncertain which of two approaches is right —
  use Antigravity as a tiebreaker with explicit trade-off framing.
- User explicitly asks for a "second opinion", "cross-check", or "another model's view".
- Final review gate before shipping a large change (complements `/codex:review` with
  a different model family's blind spots).

## When NOT to Use Antigravity

| Task | Correct Owner |
|------|---------------|
| Planning, design, complex implementation | **Codex CLI** (`codex-delegation.md`) |
| Debugging, root cause analysis | **Codex CLI** / codex-debugger |
| External research, web survey | **general-purpose subagent** (Opus, WebSearch/WebFetch) — Antigravity may assist as needed, not by default |
| Codebase analysis | **general-purpose subagent** (Opus 1M context) |
| Multimodal input (PDF, images, etc.) | **Claude directly** |
| Simple edits, git operations, tests | **Claude directly** |

Do NOT run Antigravity by default on every task — it is a verification layer for
high-stakes or contested decisions, not a parallel pipeline. One second opinion per
decision is enough; do not loop models against each other.

## Conflict Resolution

Antigravity identifies risks; **Claude makes the final synthesis**. Where Codex and
Antigravity agree, proceed. Where they disagree on a high-impact decision and the
disagreement cannot be resolved from evidence, surface both positions to the user
with Claude's own recommendation — never resolve it with another model round-trip.

## Prompt Contract (Always Include)

1. The decision under review (single sentence)
2. The proposal being examined (Codex's design/plan, or the two competing options)
3. Constraints the proposal must satisfy
4. Explicit ask: "identify flaws, risks, and superior alternatives — do not restate the proposal"
5. Output format (structured markdown sections)

## How to Consult

Exec syntax, model selection, sandbox flags, and subagent patterns: see the
**antigravity-system skill** (`.claude/skills/antigravity-system/SKILL.md`) —
this rule covers only *when* to delegate.

## Language Protocol

See `.claude/rules/language.md` (SSOT): ask Antigravity in English; report to the user per that rule.
