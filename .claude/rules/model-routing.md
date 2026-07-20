# Model Routing (SSOT)

Canonical lane map for model selection across Claude Code, Codex CLI, and
Antigravity CLI. Contracts and skills reference this file instead of restating
the tables. Bump model versions in `.claude/settings.json` `env` only.

## Claude-Side Orchestration

When Claude Code (Fable 5 or Opus — same policy for both) is the top-level agent:

| Lane | Owner | Notes |
|------|-------|-------|
| Planning | **Claude** (leads & finalizes) | For complex/high-stakes design (architecture, data model, security-sensitive), consult Codex `${CODEX_MODEL}` at `${CODEX_PLAN_EFFORT}` as a *design consultant*. Claude owns the plan. |
| Implementation | **Codex subagent** | `codex exec --sandbox workspace-write`, effort `${CODEX_IMPL_EFFORT}`. Minor one-file edits stay with Claude. |
| Review | **Claude subagents** — Sonnet default, Opus for high-risk | High-risk = security-sensitive, architecture, data model changes. For high-risk changes, additionally recommend `/codex:review` as a cross-tool lane (avoids Claude-family reviewing Claude-family plans exclusively). |
| Research / information gathering | **Opus `general-purpose` subagent** (primary) | Antigravity (`agy`) may assist as needed — auxiliary, not a default lane. |
| Second opinion | **Antigravity** (`agy`) | See `.claude/rules/antigravity-delegation.md`. |
| Multimodal input | **Claude directly** | |

## Codex-Side Orchestration (sol / terra / luna)

When Codex CLI is the top-level agent (governed by `.codex/AGENTS.md` +
`.codex/config.toml`): planning runs on `gpt-5.6-sol` at effort **high or
above**; implementation and review run mainly on `gpt-5.6-sol` at
**low/medium** effort, routed to terra/luna where the task profile fits:

| Lane | Model | Effort | Use for |
|------|-------|--------|---------|
| Luna | `gpt-5.6-luna` | low | High-volume mechanical work with little judgment and mechanically checkable answers: classification/labeling, fixed-field extraction, short transforms/summaries. Escalate hard cases to Terra. |
| Terra | `gpt-5.6-terra` | low/medium | Everyday default candidate: typical feature implementation, test addition, refactoring, reports, issue handling, document/code review. |
| Sol | `gpt-5.6-sol` | high+ | Redo-cost exceeds model cost: cross-repo design changes, hard root-cause analysis, long agent workflows, security review — and all planning. |

Rules:

- When the user specifies a model, obey it. When the right lane is ambiguous,
  asking the user is acceptable.
- Reasoning effort levels: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`.
- Override per invocation with `-m <model>` and `-c model_reasoning_effort=<level>`.

## Environment Variables (`.claude/settings.json` env)

| Variable | Default | Lane |
|----------|---------|------|
| `CODEX_MODEL` | `gpt-5.6-sol` | Codex default (planning consult, complex implementation) |
| `CODEX_MODEL_TERRA` | `gpt-5.6-terra` | Everyday implementation/review alternate |
| `CODEX_MODEL_LUNA` | `gpt-5.6-luna` | Mechanical bulk alternate |
| `CODEX_RESCUE_MODEL` | `gpt-5.6-terra` | Cheap-retry rescue lane (`/codex:rescue`); escalate to sol high manually when truly stuck |
| `CODEX_PLAN_EFFORT` | `high` | Threaded into design-consult calls |
| `CODEX_IMPL_EFFORT` | `medium` | Threaded into implementation/review calls |
| `ANTIGRAVITY_MODEL` | `gemini-3.1-pro` | Second opinion / auxiliary research |
| `CLAUDE_CODE_SUBAGENT_MODEL` | *(unset)* | Intentionally not set — a global value overrides per-spawn `model` params and would break the Sonnet-default review lane. Defined agents pin their model via frontmatter (`.claude/agents/*.md`: `model: opus`); Agent-Teams teammates get an explicit per-spawn model (implementers: opus, reviewers: sonnet/opus). |
