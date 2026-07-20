# Codex Delegation Rule

**Codex CLI is Claude's implementation executor and design consultant. Claude
leads and finalizes planning; Codex implements and advises.**

> Preflight: ensure codex CLI is current (see codex-system skill).
> Model/effort lane selection: `.claude/rules/model-routing.md` (SSOT).

## Two Roles of Codex

### 1. Design Consultation

Claude owns and finalizes plans; Codex is consulted for an expert design
opinion (`${CODEX_MODEL}` at `${CODEX_PLAN_EFFORT}`) when the stakes warrant it:

- Architecture design, module structure
- Implementation-plan sanity checks (step decomposition, dependency ordering)
- Trade-off evaluation, technology selection

### 2. Complex Code Implementation

- Complex algorithms, optimization
- Debugging with unknown root causes
- Advanced refactoring
- Multi-step implementation tasks

## Delegation Decision

Claude leads planning and delegates implementation to Codex by default.

Delegate **implementation** to Codex when the change is non-trivial (multi-file,
complex algorithm, unclear root cause, multi-step). Ask Codex for a **design
opinion** (consultation, not ownership) when **any** of these apply:

- High-stakes design/architecture decisions are involved (architecture, data
  model, security-sensitive).
- User requests comparison/trade-off analysis.
- You are unsure between two implementation directions.

Do NOT delegate to Codex when:

- Obvious one-file tiny edits, typo fixes
- Tasks that simply follow explicit user instructions
- git commit, test execution, lint
- **Routine planning** → Claude leads it directly
- **Default code review** → Sonnet subagent (Opus for high-risk); `/codex:review`
  is an optional cross-tool lane, recommended in addition for high-risk changes
- **Codebase analysis** → general-purpose subagent (Opus 1M context)
- **External information retrieval / web research** → general-purpose subagent (Opus, WebSearch/WebFetch); Antigravity may assist as needed
- **Second opinion on an already-completed design/plan** → Antigravity CLI (`.claude/rules/antigravity-delegation.md`)

## Prompt Contract (Always Include)

1. Objective (single sentence)
2. Constraints (style, limits, forbidden approaches)
3. Relevant files (explicit paths)
4. Acceptance checks (commands)
5. Output format (structured markdown sections)

Detailed templates: `@.claude/docs/CODEX_HANDOFF_PLAYBOOK.md`

## How to Consult

Exec syntax, subagent/direct patterns, implementation calls, and the sandbox-modes table: see the **codex-system skill** (`.claude/skills/codex-system/SKILL.md`) — this rule covers only *when* to delegate.

## Codex Plugin for Claude Code (codex-plugin-cc)

Plugin slash commands (`/codex:review`, `/codex:rescue`, job management) and plugin-vs-CLI guidance: see the codex-system skill.

## Language Protocol

See `.claude/rules/language.md` (SSOT): ask Codex in English; report to the user per that rule.
