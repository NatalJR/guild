# guild

## What it is

A private Claude Code plugin owned by NatalJR: a project-agnostic delegation crew. It ships:

- Six agents: `guild:investigator`, `guild:builder`, `guild:architect`, `guild:reviewer`, `guild:security`, `guild:scribe`.
- A default operating procedure (`context/procedure.md`), injected at session start, so every coding request walks the delegation DAG without a slash command: classify, investigate, scope gate, design gate, implement, review, report. `skills/guild/DAG.md` carries the node rules, dispatch modes, cleanup-pass and docs-sync procedures and the parallel-wave contracts. `/guild <task>` only forces the walk on a request that looks trivial.
- Hooks (POSIX sh): always-on context injection at session start, per-prompt reinforcement, a deny rule for AI attribution in git commits and PRs, an emoji scan on every file edit, and a subagent receipt-contract check.
- Switches: every hook and the optional procedure steps can be turned off per user or per project (see Configuration).
- Two workflows for the review and cleanup-pass waves.
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
hooks/                          hooks.json + the sh hook scripts
hooks/lib/                      shared sh libraries: payload field access, switch table
hooks/check-context-size.sh     maintenance check: each rendered context part under 9000 bytes
config/defaults.conf            switch defaults, one commented line per key
context/always-on.md            style + universal rules, injected at session start
context/procedure.md            default operating procedure (the DAG walk), injected at session start
charter/SCHEMA.md               charter contract (headings, consumers, content)
charter/TEMPLATE.md             blank charter to copy into a project
workflows/cleanup-audit.js      /guild:cleanup-audit: cleanup-pass audit wave; allow rule Workflow(cleanup-audit)
workflows/review-wave.js        /guild:review-wave: pre-commit review wave over one diff; allow rule Workflow(review-wave)
tests/run.sh                    hook contract suite (sh tests/run.sh), fixtures under tests/fixtures/
```

## Requirements

POSIX sh: dash or bash on Linux and macOS, Git Bash's sh on Windows. That is the same requirement as the Claude Code Bash tool, so any machine that runs Claude Code already has it. Nothing else: the hooks use only the standard utilities that ship with that shell (`cat`, `sed`, `grep -E`, `tr`, `cut`, `head`, `dd`, `date`, `sort`, `wc`), and no PowerShell, `jq`, `node` or `python`.

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

## Configuration

Every switch is on by default. Three files are read in order, and a later file wins:

1. `<plugin root>/config/defaults.conf`: the shipped defaults; it also declares the known keys.
2. `~/.claude/guild.conf`: user overrides.
3. `<project>/.claude/guild.conf`: project overrides.

Grammar: one `key = value` per line, spaces around `=` optional. Values are `on`, `off`, `true`, `false`, `yes` or `no`, in any case; keys are lowercase, exactly as listed below. Blank lines and lines starting with `#` are comments. A malformed line (a trailing `# comment` after the value included), a key the defaults file does not declare, and a missing file are all ignored silently. Values are only matched against that grammar, never expanded or executed.

When any switch is off, the always-on context ends with a `## Guild switches off` section listing the off keys, so the session knows what is disabled. The `procedure.*`, `review.*` and `docs.sync` switches remove the matching text from the injected procedure; `skills/guild/DAG.md` itself is not templated.

| Key | Default | Effect of off |
|---|---|---|
| `style.terse` | on | Drops `## Reply style` (terse replies, length budget) from the always-on context |
| `rules.universal` | on | Drops `## Universal code rules` from the always-on context |
| `procedure.default_mode` | on | The procedure is not injected at session start; `/guild <task>` reads `context/procedure.md` on demand |
| `procedure.investigate_first` | on | The architect may be dispatched without an investigator site map |
| `procedure.design_gate` | on | Drops Step 3a (vanilla `Plan` options on the architect route) |
| `procedure.sharding` | on | Work over 12 files or more than one area is no longer forced into parallel slices |
| `procedure.cleanup_pass` | on | Drops the cleanup pass route and section |
| `review.norms` | on | No `guild:reviewer` pass on every passed edit |
| `review.correctness` | on | No `code-review` skill pass on substantive diffs |
| `review.security` | on | No `guild:security` diff gate; security-relevant diffs ship without a security review |
| `docs.sync` | on | Drops the DAG.md `## Docs sync` step at phase close |
| `hooks.prompt_reinforce` | on | No per-prompt reinforcement line |
| `hooks.deny_attribution` | on | AI attribution in `git commit` and `gh pr create` / `gh pr edit` commands is no longer blocked |
| `hooks.emoji_scan` | on | Emoji in written files are no longer rejected |
| `hooks.receipt_check` | on | Guild subagents may stop without a terminal token on line 1 |

Example, `<project>/.claude/guild.conf` for a project whose security review and emoji policy live elsewhere:

```
# Security review runs outside the guild for this project.
review.security = off
# Emoji are allowed in this project's files.
hooks.emoji_scan = off
```

## Priority facts

- Agents: project > user > plugin.
- Skills: user > project.
- Hooks merge across levels; none replaces another.

## Hooks

Every entry runs `sh "${CLAUDE_PLUGIN_ROOT}/hooks/<script>.sh"`.

| Event | Script | What it does | Exit behaviour | Switch |
|---|---|---|---|---|
| SessionStart | `session-context.sh context/always-on.md` | Injects the style and universal rules (sections dropped per switch), plus a `## Guild switches off` list when any switch is off | Exit 0; never blocks | `style.terse`, `rules.universal` |
| SessionStart | `session-context.sh context/procedure.md` | Injects the default operating procedure with the plugin root substituted; prints nothing when the default mode is off | Exit 0; never blocks | `procedure.default_mode` and the procedure switches |
| UserPromptSubmit | `prompt-reinforce.sh` | Per-prompt reinforcement line: six-line reply budget, universal code rules, procedure walk | Exit 0; never blocks | `hooks.prompt_reinforce` |
| PreToolUse (`Bash`, `PowerShell`) | `deny-attribution.sh` | Denies AI attribution in `git commit` and `gh pr create` / `gh pr edit` command text | Exit 2 with the reason on stderr on a match; exit 0 otherwise | `hooks.deny_attribution` |
| PostToolUse (`Edit`, `Write`) | `emoji-scan.sh` | Scans the written file (inside the project, non-binary) for emoji | Exit 2 naming the first hit line, reported to the agent; exit 0 otherwise | `hooks.emoji_scan` |
| SubagentStop | `receipt-check.sh` | Checks the receipt contract (first-line terminal token) on `guild:*` agents | Exit 2 blocks the stop once on a malformed receipt; allows otherwise | `hooks.receipt_check` |

SessionStart has one entry per context part because the harness caps a single hook's stdout near 10KB and replaces anything larger with a 2KB preview. `sh hooks/check-context-size.sh` (a maintenance check, not a hook) renders each part with every switch on and fails when any part exceeds 9000 bytes. A malformed payload or an internal error never blocks: the hook prints nothing and exits 0. `sh tests/run.sh` is the contract suite for all of the above.

## Non-goals

- Not published to any marketplace.
- No telemetry.
- No gateway or proxy.
