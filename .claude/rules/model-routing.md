# Model Routing Addendum (Tier 2 Sub-Lanes)

Fork-local addendum to `.claude/rules/tiers.md`. *Which tier* handles a task is
decided by `AGENTS.md`, `.claude/rules/delegation.md`, and `tiers.md`; this file
only picks the Codex model and reasoning effort *inside* Tier 2 `sol`, and lists
the environment variables that carry those choices.

## Codex Sub-Lanes

| Lane | Model (env var) | Effort | Use for |
|------|-----------------|--------|---------|
| Sol (default) | `CODEX_MODEL` | `high` | Every Tier 2 call unless a row below applies: design, planning, review, complex implementation, debugging. |
| Luna (bulk) | `CODEX_MODEL_LUNA` | `high` | High-volume mechanical work whose answers are mechanically checkable: classification, fixed-field extraction, short transforms and summaries. Anything that needs judgment goes back to Sol. |
| Astra (explicit only) | `CODEX_MODEL_ASTRA` | `high` | Only when the user explicitly names it. Never selected automatically. |

```bash
# Sol (default): model and effort come from .codex/config.toml
python3 .claude/skills/_shared/codex_consult.py --prompt-file <path> --sandbox read-only

# Luna: bulk mechanical work
python3 .claude/skills/_shared/codex_consult.py --prompt-file <path> \
  --model "${CODEX_MODEL_LUNA:-gpt-6-luna}" --label bulk
```

## Effort Policy

- Default reasoning effort is `high` (`.codex/config.toml`
  `model_reasoning_effort`). Callers do not override it.
- `xhigh`, `max`, and `ultra` are used only when the user explicitly asks for
  them: `--config model_reasoning_effort=<level>`. The same applies to
  `--model "${CODEX_MODEL_ASTRA:-gpt-6-astra}"`.
- Lowering effort (`low`, `medium`) for a cheap, narrow question is allowed.
- `/codex:rescue` uses the local Codex config; pass `--model` / `--effort` only
  under the same rules. It has no model aliases worth using.

## Environment Variables (`.claude/settings.json` `env`)

Model IDs live here only; change them here.

| Variable | Value | Notes |
|----------|-------|-------|
| `CODEX_MODEL` | `gpt-6.1-sol` | Tier 2 default. Must equal `.codex/config.toml` `model` and `codex_consult.py` `DEFAULT_MODEL` (`scripts/check.sh` enforces this). |
| `CODEX_MODEL_LUNA` | `gpt-6-luna` | Bulk lane. |
| `CODEX_MODEL_ASTRA` | `gpt-6-astra` | Explicit-only escalation. |
| `ANTIGRAVITY_MODEL` | `gemini-3.1-pro-high` | Cross-model second opinion (`antigravity-system` skill). The slug carries the thinking level; `agy` rejects a bare `gemini-3.1-pro` without `--effort`. |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `sonnet` | Fallback for subagents that name no model. Since Claude Code v2.1.251 the order is per-invocation `model` > agent frontmatter `model` > this variable, so `model: opus` / `model: fable` frontmatter still wins. |
