# Antigravity Delegation Rule

**Antigravity CLI (`agy`, Gemini) is a cross-model second-opinion layer. It is
not a tier.**

Routing between tiers is unchanged (`AGENTS.md`, `.claude/rules/delegation.md`,
`.claude/rules/tiers.md`): Codex designs, plans, and reviews; Claude subagents
implement; `fable-advisor` arbitrates rarely. Every one of those is either Claude
or Codex. Antigravity adds an independent judgment from a **different model
family** on top of them — it verifies, it does not author, and it examines
*judgments* (designs, plans, risk assessments), not raw diffs.

## When to Use

Consult Antigravity when **any** of these apply:

- A Codex design or plan is high-stakes (architecture, data model,
  security-sensitive) and should be cross-examined before user approval.
- Codex and a Claude agent disagree and the evidence does not settle it — ask
  for a tiebreak with explicit trade-off framing, before or alongside an
  escalation to `fable-advisor`.
- The user explicitly asks for a "second opinion", "cross-check", or "another
  model's view" (セカンドオピニオン, 別のモデル).
- A final gate before shipping a large change, complementing
  `/codex:adversarial-review` with another model family's blind spots.

## When NOT to Use

- Planning, design, review, implementation, debugging, research: use the routes
  in `.claude/rules/delegation.md` (Codex, `general-purpose-sonnet`,
  `general-purpose-opus`, `codex-debugger`).
- Read-only consultations that must be confined: the wrapper refuses
  `--read-only` for Antigravity (headless mode auto-approves every tool call);
  use Codex with `--sandbox read-only` instead.
- Routine decisions. **One second opinion per decision** — never loop models
  against each other.

## Conflict Resolution

Antigravity's output is one reviewer's opinion. The main agent synthesizes:
where Codex and Antigravity agree, proceed; where they disagree on a
high-impact decision that evidence cannot settle, surface both positions to the
user with a recommendation (or escalate to `fable-advisor`) — never resolve it
with another model round-trip.

## Prompt Contract (Always Include)

1. The decision under review (single sentence)
2. The proposal being examined (the design/plan, or the two competing options)
3. Constraints the proposal must satisfy
4. Explicit ask: "identify flaws, risks, and superior alternatives — do not
   restate the proposal"
5. Output format (structured markdown sections)

## How to Consult

Always through the shared wrapper with the model pinned:

```bash
python3 .claude/skills/_shared/cli_consult.py --cli antigravity \
  --model "${ANTIGRAVITY_MODEL:-gemini-3.1-pro-high}" \
  --prompt-file <path> --label second-opinion --caller <your agent name>
```

Templates and result handling: the `antigravity-system` skill
(`.claude/skills/antigravity-system/SKILL.md`). Ask Antigravity in English; the
user-facing report follows `AGENTS.md` `## Language Protocol`.
