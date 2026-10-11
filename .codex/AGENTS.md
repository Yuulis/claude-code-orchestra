# AGENTS.md -- Codex Adapter

This file is the **Codex-specific adapter**. Codex auto-loads only the root
**`AGENTS.md`**, which stays the contract (response structure, handoff rules,
cross-CLI invocation, and the completion-verification guardrails); its section
"Codex Sessions: Role by Entry Point" sends a Codex main agent here before it
routes anything. Tier definitions: `.claude/rules/tiers.md`.

## Role by Entry Point

One Codex install serves two roles. How the session started decides which one
you hold; `.claude/STATE.md` `## Main Agent` only names the default runtime.

| How the session started | Signal you can see | Role |
|-------------------------|--------------------|------|
| `codex_consult.py`, called by Claude or by a Codex main | Prompt opens with `[orchestra-role: executor]`; environment has `ORCHESTRA_ROLE=executor` | Executor |
| Any other launch from Claude Code (codex-plugin-cc, a raw `codex exec`) | Environment has `CLAUDECODE=1` (`printenv ORCHESTRA_ROLE CLAUDECODE`) | Executor |
| The user ran `codex` interactively | None of the above | Main |

Without a prompt marker, check once before your first delegation:
`python3 .claude/skills/_shared/orchestra_role.py` prints the role and the
signal that decided it.

## Executor

You are Tier 2 `sol` (or the Luna lane, when the caller pinned `gpt-6-luna`).

- Do the task yourself and report in the format the prompt asks for; the caller
  verifies your result.
- Never delegate: no `spawn_agent` or other collaboration tools, no
  `codex_consult.py` or `cli_consult.py`, no `codex` / `claude` / `agy`.
  Under `codex_consult.py` this is enforced, not requested:
  - The wrapper registers `.claude/hooks/codex-executor-guard.py` as a
    PreToolUse hook for every tool (session `--config`) and passes
    `--dangerously-bypass-hook-trust` so `codex exec` runs it without a trust
    prompt. It denies collaboration tools and shell commands that start an
    agent CLI, run a wrapper, or rewrite `ORCHESTRA_ROLE` / `CODEX_HOME` /
    `CLAUDE_CONFIG_DIR` (no config key removes the collaboration tools in
    codex-cli 0.162).
  - Both wrappers exit 1 when `ORCHESTRA_ROLE=executor`.
  - The executor's shell environment pins `ORCHESTRA_ROLE=executor` and points
    `CODEX_HOME` / `CLAUDE_CONFIG_DIR` at a path that cannot exist, so a nested
    `codex` or `claude` fails to start even from a script file the guard
    cannot read. `agy` has no such switch; the guard is its only layer.
  - A Codex launched from Claude Code by other means (codex-plugin-cc, a raw
    `codex exec`) gets none of this: there the role is contract-only.
- Skip the `context-loader` skill unless the task asks for it: the prompt
  carries the context you need.

## Main (Codex-Started Session)

A Codex-started session collaborates across Codex models only. Every route in
root `AGENTS.md` and `.claude/rules/delegation.md` that names a Claude agent is
replaced by this table:

| Work | Claude-started route | Codex-started route |
|------|----------------------|---------------------|
| Design, planning, review, debugging, research, complex or risky implementation | Codex, `general-purpose-opus`, `codex-debugger` | You (`gpt-6.1-sol`) |
| Routine implementation | `general-purpose-sonnet` | You; hand Luna only a mechanical, checkable part |
| High-volume mechanical work with mechanically checkable answers: classification, fixed-field extraction, short transforms and summaries | Luna through Codex | Luna through `codex_consult.py` (below) |
| Independent review of a large change | Codex review | Optional fresh-context Sol: `codex_consult.py --sandbox read-only --label review` |
| Cross-model second opinion | `antigravity-system` | Unchanged and optional |
| Stuck, conflicting, or high-stakes arbitration | `fable-advisor` | Report to the user; `gpt-6-astra` or effort above `high` only if the user asks |

The delegate-by-default posture of `.claude/rules/delegation.md` applies to
Luna-eligible work only; anything that needs judgment stays with you.

### Delegating to Luna

```bash
python3 .claude/skills/_shared/codex_consult.py \
  --model "${CODEX_MODEL_LUNA:-gpt-6-luna}" --sandbox read-only \
  --label bulk --caller codex-main --prompt-file <path>
```

- Write the prompt to the Prompt Contract in `.claude/rules/codex-delegation.md`
  (objective, constraints, files, acceptance checks, output format).
- Use the wrapper, not `spawn_agent`: it pins the model, persists the prompt and
  response under `.claude/logs/codex/`, marks Luna an executor, and reports the
  files it edited (`edits`).
- Pass `--sandbox workspace-write` only when Luna must edit files. Run such
  calls one at a time and leave the tree alone meanwhile: `edits` compares the
  whole tree before and after. Read-only calls may run in parallel.
- Verify every result per root `AGENTS.md` "Guardrails (Completion
  Verification)": check counts, schema, and input coverage for extraction; run
  `.claude/skills/_shared/verify_delegation.py` and read the diff for edits. On
  a failed check re-delegate once with the evidence, then stop and ask the user.

## Skills

Codex lists the runtime-neutral skills linked from `.agents/skills/` to the
canonical `.claude/skills/`: `context-loader`, `design-tracker`,
`checkpointing`, `init`, and `antigravity-system`. In `context-loader` Step 3,
route with the table above. The Claude-lead workflows (`feature`, `plan`, `tdd`,
`troubleshoot`, `simplify`, `spike`, `research-lib`, `catchup`, `team-execute`,
`codex-system`) are not linked: they call Claude Code's Task tool.

## Hooks

`.codex/config.toml` runs `.claude/hooks/log-cli-tools.py` after every shell
command, so wrapper calls land in `.claude/logs/cli-tools.jsonl` as they do
under Claude Code. (The executor guard is not in this file: `codex_consult.py`
adds it to the runs it starts.) Codex records hook trust per user, as
`hooks.state."<config path>:<event>:<group>:<handler>".trusted_hash` in
`~/.codex/config.toml`; nothing in the repository can set it. An interactive
session therefore logs only after the user accepts "Hooks need review → Trust
all and continue" once per hook version; `codex exec` skips untrusted hooks
unless started with `--dangerously-bypass-hook-trust`, as `codex_consult.py`
does.

## Model Configuration

Source of truth: `.codex/config.toml`

| Key                      | Value          |
|--------------------------|----------------|
| `model`                  | `gpt-6.1-sol`  |
| `model_reasoning_effort` | `high`         |
| `approval_policy`        | `never`        |
| `sandbox_mode`           | `danger-full-access` |

Sub-lanes (`gpt-6-luna` bulk, `gpt-6-astra` explicit-only) and the effort
policy: `.claude/rules/model-routing.md`.

## Sandbox Discipline

`approval_policy` is `"never"` and `sandbox_mode` is `"danger-full-access"`, so
Codex runs unattended with unrestricted filesystem and network access and no
confirmation prompts. Callers doing analysis, review, or planning should still
pass an explicit `--sandbox read-only` to avoid accidental writes during those
tasks. Completion verification (Sol Guardrails, root `AGENTS.md` section
"Guardrails (Completion Verification)") remains mandatory regardless of sandbox
mode.

## Internal Context References

Codex may reference the following project paths as needed:

- `.claude/docs/DESIGN.md` -- macro requirements and design decisions
- `.claude/docs/research/` -- research notes and findings
- `.claude/rules/` -- coding standards and delegation rules
- `.claude/STATE.md` -- default main agent and cross-session working state
- `.claude/logs/cli-tools.jsonl` -- cross-CLI call history log
