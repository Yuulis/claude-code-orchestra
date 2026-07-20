# Manual Docs Convention (docs/manual/)

Where and how to write specification and implementation-status summaries.

## Trigger

When the user asks to summarize specifications ("仕様書をまとめて") or the
current implementation status ("実装状況をまとめて"), write the summary as
markdown under `docs/manual/`, not in the conversation and not in
`.claude/docs/`.

## Layout

```
docs/manual/<theme>/
  <topic>.md
```

- Create a **new theme directory per topic** (kebab-case, English name:
  `auth-flow/`, `data-pipeline/`, `release-2026-07/`).
- Split large themes into multiple focused `.md` files inside the theme
  directory rather than one long file.
- `docs/manual/` is created on demand; a `.gitkeep` keeps the convention
  visible in the template.

## Language

Content under `docs/manual/**` is written in **Japanese** — this is the only
documentation location exempt from the English rule. Code identifiers,
commands, and file paths stay in English. See `.claude/rules/language.md`
(Documentation exception).

## Scope Boundaries

- `docs/manual/` = user-facing Japanese summaries of specs/status (this rule).
- `.claude/docs/DESIGN.md` = macro requirements/design (要件定義書), managed by
  `/init` and `/design-tracker` — do not duplicate it here; link to it.
- `.claude/docs/research/` = research outputs; `PROGRESS.md` = work progress.
  None of these move under `docs/manual/`.
