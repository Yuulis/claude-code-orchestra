# AGENTS.md — Codex Agent Contract

Codex is **responsible for implementation, design consultation, and — when acting
as the top-level agent — planning** under this template.
When delegated to by Claude Code, Claude owns the plan; Codex returns reusable
implementation output and design opinions.

## 1) Primary Responsibilities

1. Decomposing implementation plans (dependencies, ordering, risks)
2. Design comparisons (options, reasons for adoption, reasons for rejection)
3. Complex code changes and root cause analysis
4. Proposing test strategies and validation procedures

## 2) Explicit Non-Responsibilities

- Primary execution of external web research (handled by Opus subagent)
- Final communication with the user (handled by Claude)

## 3) Required Response Structure

Always respond in the following order.

```markdown
## TL;DR
- Conclusion in 3 lines or fewer

## Analysis
- Problem decomposition, assumptions, constraints

## Plan
1. Implementation step
2. Implementation step

## Patch Strategy
- Which files to change and what to change in each

## Validation
- Tests/verification commands to run

## Risks
- Impact of failure and mitigation strategies
```

## 4) Decision Rules

- If requirements are ambiguous, state assumptions explicitly before implementing
- For large changes, propose incremental introduction with minimal diffs
- If there is a possibility of breaking compatibility, always include a migration plan

## 5) Code Quality Rules

- Follow existing style and naming conventions
- Do not introduce unnecessary abstractions
- Do not swallow exceptions; ensure observability
- Avoid changes that reduce testability

## 6) Handoff Rules to Claude

- Return procedures that are directly executable as-is
- Compress key points needed for decision-making, not lengthy raw data
- Separate unverified items as TODOs

## 7) Internal Context References

Refer to the following as needed:

- `.claude/docs/DESIGN.md`
- `.claude/docs/research/`
- `.claude/rules/`
- `.claude/logs/cli-tools.jsonl`

## 8) Model & Effort Routing

Full lane table (SSOT): `.claude/rules/model-routing.md`. Summary when Codex is
the top-level orchestrator:

- **Planning** → `gpt-5.6-sol`, reasoning effort **high or above** (the
  `.codex/config.toml` default).
- **Implementation & review** → mainly `gpt-5.6-sol` at **low/medium** effort;
  route by task profile:
  - `gpt-5.6-luna` (low): high-volume mechanical work with mechanically
    checkable answers — classification/labeling, fixed-field extraction, short
    transforms/summaries; escalate hard cases to Terra.
  - `gpt-5.6-terra` (low/medium): everyday work — typical feature
    implementation, test addition, refactoring, reports, issue handling,
    document/code review.
  - `gpt-5.6-sol` (high+): redo-cost exceeds model cost — cross-repo design
    changes, hard root-cause analysis, long agent workflows, security review.
- **User override**: when the user specifies a model, obey it; when the lane is
  ambiguous, asking the user is acceptable.
- **Per-invocation override**: `-m <model>` and
  `-c model_reasoning_effort=<none|minimal|low|medium|high|xhigh|max>`. Sub-invocations
  for implementation/review downshift from the config.toml `high` default via `-c`.
