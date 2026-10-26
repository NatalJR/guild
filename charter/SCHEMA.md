# Charter schema

The charter is `<project>/.claude/guild.md`. It has fixed H2 headings in a fixed order. Agents locate sections by heading text, so headings are verbatim and all present. An empty section states `none`.

## Identity

- Purpose: orient every agent on the project in one line.
- Consumers: all agents.
- Required content: project name, what it is, stack.
- Example: `Inventory Service: REST backend tracking warehouse stock. Python 3.12, FastAPI, PostgreSQL.`

## Verify

- Purpose: the exact commands that prove a change is sound.
- Consumers: `guild:architect` (mandatory; absent means it replies `blocked. need: verify commands.`), the skill's close step.
- Required content: build, test, and lint commands with env vars and notes; which command is the lint gate.
- Example lines:
  - `npm run build` - warnings are errors; this is also the lint gate.
  - `API_URL=http://localhost:8080 npm test` - all suites.

## Areas

- Purpose: the sharding map behind the "one area per slice; more than 12 files shards" rule.
- Consumers: the skill (fan-out), `guild:investigator` (scoping), the cleanup pass (one auditor per area group).
- Required content: area name mapped to path globs.
- Example lines:
  - `api` - `src/api/**`
  - `storage` - `src/storage/**`, `migrations/**`
  - `tests` - `tests/**`

## Rules

- Purpose: index of the project's rule files.
- Consumers: `guild:builder`, `guild:architect`, `guild:reviewer`.
- Required content: each `.claude/rules/*.md` file with the globs it covers. Agents Read the ones matching their edit or review targets.
- Example lines:
  - `.claude/rules/api.md` - covers `src/api/**`
  - `.claude/rules/storage.md` - covers `src/storage/**`, `migrations/**`

## Security

- Purpose: project additions to the generic security checklist.
- Consumers: `guild:security`.
- Required content: named factories, path-resolution helpers, model and native file locations, dependency manifests.
- Example lines:
  - Paths resolve only through `PathResolver.Resolve`; raw `Path.Combine` on user input is a defect.
  - Dependency manifests: `package.json`, `package-lock.json`.

## Docs

- Purpose: the doc map and the exhaustive docs-sync surface list.
- Consumers: `guild:scribe` (mandatory; absent means it replies `ambiguous. ask: doc map.`), the skill (docs-sync).
- Required content: normative docs, package-level docs, operator docs, external docs (outside the repo), and an enumeration of every docs-sync surface the close step walks. Each surface receives a hit or no-hit verdict.
- Example lines:
  - Normative: `docs/ARCHITECTURE.md` (layers, invariants), `docs/API.md` (endpoint contracts).
  - Package-level: `src/api/README.md`.
  - Operator: `ops/RUNBOOK.md`.
  - External: `~/notes/concept.md` (owner decisions only).

## Process surfaces

- Purpose: files only the main thread edits.
- Consumers: `guild:scribe` (never touches them), the skill.
- Required content: root `CLAUDE.md`, rule files, the charter itself, ledger and next-steps files.
- Example lines: `CLAUDE.md`, `.claude/rules/*`, `.claude/guild.md`, `NEXT-STEPS.md`.

## Forbidden for subagents

- Purpose: operations agents never run.
- Consumers: `guild:architect`, `guild:security`, the skill.
- Required content: training runs, database rewrites, deploys, pushes, driving an editor, or whatever applies to the project.
- Example lines: `Deploys and pushes.` `Writes to the production database.` `Launching the GUI editor.`

## Tracker

- Purpose: the work-tracking surface and its commands.
- Consumers: the skill (fan-out sourcing, wave close).
- Required content: tool and commands (list, add, move, close, show); card lifecycle: opens as in progress, owner QA moves it to blocked on owner, shipped closes it by commit reference. Chat is not a ledger: deferrals and flags become cards at wave close.
- Example lines: `tools/board.sh list` - live board. `tools/board.sh move <id> blocked-on-owner` - hand to owner QA.

## QA

- Purpose: human-in-the-loop constraints.
- Consumers: the skill, `guild:architect`.
- Required content: what cannot be exercised from the agent environment, and how QA is handed to the owner: a numbered checklist, with the slice staying open until the owner confirms.
- Example lines: `Visual rendering cannot be verified headless.` `Hand-off: numbered checklist in the receipt; slice stays open.`

## Git

- Purpose: pointer to the project's git conventions.
- Consumers: the skill (commits are main-thread only).
- Required content: the project's git skill or the conventions it follows: commit format, push authorization, branch flow.
- Example lines: `Follow .claude/skills/git/SKILL.md before any commit, push, or branch.`
