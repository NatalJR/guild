## Operating procedure (default mode)

Every coding request walks this procedure. No slash command is needed and the user never types one; `/guild <task>` exists only to force the walk on a request that looks trivial. Charter at `<project>/.claude/guild.md`; absent charter: tell the user, offer `{{PLUGIN_ROOT}}/charter/TEMPLATE.md`, continue with generic defaults.

The main thread is the orchestrator; subagents do the work. Keep own tool use minimal: main-thread context is the resource being protected. The graph, node rules, dispatch modes, cleanup pass and docs sync live in `{{PLUGIN_ROOT}}/skills/guild/DAG.md`. Read it once per session before the first dispatch; its node rules and anti-edges are binding, this procedure is the walk order only.

### Step 0: Triage and mode

- Question, problem description, thinking out loud: assess and answer. No edits until an imperative arrives.
- Imperative on code: pick the dispatch mode (DAG.md `## Dispatch modes`) and paste its guardrails into every edit dispatch. Investigation dispatches name their mode too (`investigate-first` or `verify-and-stop`).

### Step 1: Classify

Pick exactly one start node:

| Signal | Route |
|---|---|
| Answer already in context / one-liner | Answer inline. STOP, no subagent. |
| "where is / what calls / list uses / map" | Investigator (Step 2) |
| Edit, exact `path:line` known | Scope gate (Step 3) |
| Edit, site unknown | Investigator first (Step 2), then Step 3 |
| "review this diff/branch/file" (non-security) | `guild:reviewer` (Step 5) only |
| "find bugs in this diff" (correctness) | `code-review` skill (Step 5) only |
| "security review" / diff touches SQL, file IO paths, native or model-file loading, dependencies, config/secret files, items in the charter's `## Security` | `guild:security` (Step 5) only |
| Mass mechanical refactor (serial renames, moves, symbol maps) | Codemod (the project's codemod location, default `tools/codemods/`, created on first use; architect WRITES it, main thread runs it and checks idempotence) |
| Normative/plan doc amendment OR new-doc render (surfaces under `## Docs`) | `guild:scribe`: main thread sends decisions/outline, scribe renders prose; the ledger and `## Process surfaces` stay main-thread |
| HTML/interactive page (explainers, tools, mockups) | Pages are CODE: builder/architect from a main-thread outline + data contract, never scribe, never authored inline |
| Wants prose, rationale, architecture opinion | Vanilla `Explore` / `Plan`. The guild is the wrong tool; say so, use vanilla. |
{{#if procedure.cleanup_pass}}
| "cleanup pass" / end of phase | Cleanup pass mode (below) |
{{/if}}

### Step 2: Investigate

Dispatch `guild:investigator`. Broad question (defs + callers + tests): 2-3 investigators in ONE message, different angles each. Aggregate the `path:line` tables. `No match.`: report to user, stop. Read-only question: relay findings, done. Edit task: continue.

### Step 3: Scope gate

- Surgical, <=2 files, no new abstractions: `guild:builder`. Prompt MUST contain exact `path:line` sites, the change spec and the mode guardrails. Builder never searches.
- 3+ files / new feature / new files / cross-cutting: `guild:architect`.
{{#if procedure.investigate_first}}
  NEVER dispatch without an investigator site map. New feature with no existing sites still gets a map: investigator scouts insertion points + conventions first.
{{/if}}
  Prompt gets: task spec, site map verbatim, the work-plan contract (DAG.md), the mode guardrails, the charter's `## Rules` files that touch the change, and the `## Verify` commands.
{{#if procedure.sharding}}
- Work spanning >12 files OR >1 area of the `## Areas` map: shard into parallel slices with exclusive ownership, all in one message.
{{/if}}

{{#if procedure.design_gate}}
### Step 3a: Design gate (architect route only)

Solution shape obvious, one sane way: skip this step. Wide solution space:

1. Dispatch vanilla `Plan` with the investigator map VERBATIM, stating: "Site map below is pre-computed and trusted. Start by Reading those files; do NOT re-run broad search. Explore only gaps the map doesn't cover." Ask for 2-3 options with trade-offs, one recommendation, and a final `new sites: path:line — note` section.
2. Choice visible to user (UX, data model, scope, cost): AskUserQuestion. Internal-only (naming, module layout): pick the recommendation yourself.
3. Merge `new sites` into the site map.
4. Compress the winner into the architect spec: approach in <=5 lines, decided trade-offs as constraints, merged map attached. Decisions, not options.

{{/if}}
### Step 4: Handle terminal tokens

First line of the subagent reply decides the edge. Never re-dispatch verbatim.

| Token | Edge |
|---|---|
| receipt + `verified:`/`verify:` OK | Step 5 |
| `too-big. split: ...` | Re-dispatch to architect (or run independent 1-2 file splits as builder calls) |
| `too-small.` | Re-dispatch to builder |
| `ambiguous. ask: <q>` | Answer from context if you can; else ask user, then re-dispatch tightened. Design-shaped question from architect means Step 3a was skipped; run it now |
| `needs-confirm. op: <cmd>` | Show user, wait for confirm, re-dispatch with approval stated |
| `regressed. ...` | Recover without hand-editing: `git checkout`/`git revert` the slice's files to last green, re-dispatch with the failure receipt in the spec; one-obvious-line regression: fresh builder scoped to that line |
| `blocked. need: <thing>` | Get thing from user, re-dispatch |
| `need-map. ask: <q>` | Run investigator on `<q>`, re-dispatch architect with prior map + new findings. First map request does not count toward the 2-cap |
| No recognizable token on line 1 | Treat as `ambiguous.`: one re-dispatch restating the token contract; counts toward the 2-cap |

Max 2 re-dispatches per agent. Third failure: take over in main thread, tell user why.

### Step 5: Review

Three dimensions, same parallel wave when they apply:

{{#if review.norms}}
- **Norms/structure**: `guild:reviewer` on every passed edit (`git diff` scope in prompt). Waves of 3+ slices or crossing areas also get ONE aggregate-diff verification review before commit.
{{/if}}
{{#if review.correctness}}
- **Correctness**: the `code-review` skill (`/code-review` at the chosen effort) on substantive diffs (3+ files, new abstraction, behaviour change) and at phase close. `/code-review ultra` (cloud, billed) is owner-triggered only; never launch it.
{{/if}}
{{#if review.security}}
- **Security**: diff touches SQL construction, file IO / path resolution, native or model-file loading, dependencies, config/secret surfaces, process execution, or anything under the charter's `## Security`: `guild:security` in diff-gate mode. `security-scope.` from the reviewer: hand to `guild:security`, don't fix-loop. `not-security.`: scope was wrong; send it to `guild:reviewer`.
{{/if}}

Verdicts: `No issues.` from every dispatched reviewer means done. Red/yellow: fix loop (<=2 files builder; more architect), then the same reviewer again; max 2 loops, then residual findings to the user. Security red/yellow block the commit until fixed or explicitly accepted by the user; cap exhausted with security findings open means the commit STAYS blocked, residual to the user. Blue / question: report, don't loop.

### Step 6: Report

Short summary for the user (they don't see subagent output): what changed (paths), verify result, review verdicts, anything residual. Paraphrase receipts.
{{#if git.handling}}
Commits only on request, by the main thread, through the guild `git` skill.
{{/if}}
{{#if !git.handling}}
Commits only on request, by the main thread, through the project's git skill named under `## Git`.
{{/if}}
QA surfaces from `## QA` go to the owner as a numbered checklist; the slice stays open until they report.

{{#if procedure.cleanup_pass}}
### Cleanup pass (dedicated mode)

Task = "cleanup pass" / end of phase: do NOT classify as a regular edit; run DAG.md `## Cleanup pass`: one `guild:reviewer` per area group from `## Areas` (3 to 5 auditors, config surfaces in the last group) + one `guild:security` repo-state auditor + `/code-review`, same wave, find-only; then THEME consolidation on the main thread (vehicle per theme: codemod / architect / builder; discarded nits on the record); then slices through the normal procedure, extraction before consumption; then green tree via `## Verify` + aggregate verification reviewer + `guild:security` diff gate + one commit per theme + receipt flags to cards via `## Tracker` + state summary in the ledger file named under `## Process surfaces`.
{{/if}}
{{#if docs.sync}}
Phase close: after the cleanup pass, run DAG.md `## Docs sync`.
{{/if}}
