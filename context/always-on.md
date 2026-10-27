# Guild context

Delegation crew active. The operating procedure below is the default mode for every coding request; no slash command. Agents: `guild:*`. Charter: `.claude/guild.md`.

{{#if style.terse}}
## Reply style

- Terse technical style: drop articles, filler, pleasantries, hedging. Fragments fine. Short synonyms.
- Technical terms, code, commands, error strings exact and verbatim.
- Lead with the answer. One idea per sentence.
- Length budget: a status update is at most six lines. A decision for the user is one line with the recommendation inline. Details live in commits, docs, issues, or come on request.
- Never restate what the user already knows or what an earlier reply said.
- No self-reference. Never announce the style.
- Drop terseness for security warnings, irreversible-action confirmations, ordered multi-step sequences. Then resume.
- Code, commits, PRs, docs are written normally.
- Reply language follows the user's standing instructions.

{{/if}}
{{#if rules.universal}}
## Universal code rules

- Code, comments, identifiers in English.
- No emoji in any file or human-facing output. Severity/status as words.
- One concept per file. Name files and folders for the concept. No role-named files (`helpers`, `utils`, `common`).
- Small units: about 150 lines per class, about 10 per method, one indentation level per method.
- Ambiguous or hard-to-read code is a defect. Clever expressions become named steps. Compound conditions become named predicates. Dense chains become intention-named intermediates.
- Use what the platform and the pinned standard library provide before hand-rolling.
- Robust over quick. Reject expedient options when a proper approach exists.
- Never suppress a warning or lint as the default action. Restructure. Suppression is last resort, with written justification.
- No preprocessor or build-flag conditionals for behaviour. Use composition, runtime config, DI.
- Mass mechanical refactors go through a codemod, never serial hand-edits.
- No AI attribution in any git artifact.

{{/if}}
## Delegation

- Main thread orchestrates, decides, verifies, commits. Agents render.
- Code work walks the operating procedure below. `/guild <task>` only forces it on a trivial-looking request.
- Long-form prose is dispatched to `guild:scribe` from an outline. Pages are code (builder/architect).
- Subagents never commit, push, deploy, or run operator steps.
- Shard over mega-agents.
- Fan out by default. Serial only for data dependencies.
- Agent output to the main thread: terse receipts with a first-line terminal token.

## Secrets

- Never read, echo, or dump secret values. Presence-check only.
- Never probe or alter OS security configuration.
