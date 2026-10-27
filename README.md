# guild

## What it is

A private Claude Code plugin owned by NatalJR: a project-agnostic delegation crew. It ships:

- Six agents: `guild:investigator`, `guild:builder`, `guild:architect`, `guild:reviewer`, `guild:security`, `guild:scribe`.
- A default operating procedure (`context/procedure.md`), injected at session start, so every coding request walks the delegation DAG without a slash command: classify, investigate, scope gate, design gate, implement, review, report. `skills/guild/DAG.md` carries the node rules, dispatch modes, cleanup-pass and docs-sync procedures and the parallel-wave contracts. `/guild <task>` only forces the walk on a request that looks trivial.
- Hooks: always-on context injection at session start, per-prompt reinforcement, a deny rule for AI attribution in git commits and PRs, an emoji scan on every file edit, and a subagent receipt-contract check.
- A per-project charter convention.

Project knowledge never lives in the plugin. It lives in `<project>/.claude/guild.md` (the charter), which every agent reads first.

Models are pinned per agent:

| Agent | Model |
|---|---|
| `guild:investigator` | haiku |
| `guild:builder` | opus |
| `guild:architect` | opus |
| `guild:reviewer` | opus |
| `guild:security` | fable (never downgraded) |
| `guild:scribe` | sonnet |

The rationale is cost tiering (cheap scouting, mid-cost implementation, the strongest model only for security and orchestration) and wall-clock parallelism, not context saving.

## Layout

```
.claude-plugin/plugin.json      plugin manifest
.claude-plugin/marketplace.json local marketplace entry
agents/                         the six agent definitions
skills/guild/                   DAG.md (binding rules) + the /guild force-the-walk skill
hooks/                          hook definitions and scripts
context/always-on.md            style + universal rules, injected at session start
context/procedure.md            default operating procedure (the DAG walk), injected at session start
charter/SCHEMA.md               charter contract (headings, consumers, content)
charter/TEMPLATE.md             blank charter to copy into a project
```

## Install

Local path, for development:

```bash
claude plugin marketplace add E:/dev/guild
```

Then, inside Claude Code:

```
/plugin install guild@guild
```

From GitHub, once pushed:

```bash
claude plugin marketplace add NatalJR/guild
```

Enable in `~/.claude/settings.json`:

```json
{
  "enabledPlugins": { "guild@guild": true }
}
```

Update with `/plugin update guild`.

## Adopting in a project

1. Copy `charter/TEMPLATE.md` to `<project>/.claude/guild.md` and fill every section (`charter/SCHEMA.md` defines each one).
2. Point the project's root `CLAUDE.md` at the charter with one line.
3. Keep project-specific rules in `.claude/rules/*.md` with `paths:` frontmatter, and list them in the charter's Rules section.
4. Keep a project `git` skill if the project's git conventions differ from the defaults.
5. Delete any project-local agents or skills whose names collide with the plugin's. Project agents shadow plugin agents, and user skills shadow project skills.

## Priority facts

- Agents: project > user > plugin.
- Skills: user > project.
- Hooks merge across levels; none replaces another.

## Hooks

| Event | What it does | Exit behaviour |
|---|---|---|
| SessionStart | Injects `context/always-on.md` + `context/procedure.md` as hidden context, with the plugin root substituted | Exit 0; never blocks |
| UserPromptSubmit | Per-prompt reinforcement of the core rules | Exit 0; never blocks |
| PreToolUse (git commit, PR creation) | Denies AI attribution in commit messages and PR text | Blocks on a match; allows otherwise |
| PostToolUse (file edits) | Scans the edited file for emoji characters | Reports a violation to the agent on a match; exit 0 otherwise |
| SubagentStop | Checks the receipt contract (first-line terminal token) | Blocks the stop on a malformed receipt; allows otherwise |

## Non-goals

- Not published to any marketplace.
- No telemetry.
- No gateway or proxy.
