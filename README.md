# guild

## What it is

A private Claude Code plugin owned by NatalJR: a project-agnostic delegation crew. It ships:

- Six agents: `guild:investigator`, `guild:builder`, `guild:architect`, `guild:reviewer`, `guild:security`, `guild:scribe`.
- A default operating procedure (`context/procedure.md`), injected at session start, so every coding request walks the delegation DAG without a slash command: classify, investigate, scope gate, design gate, implement, review, report. `skills/guild/DAG.md` carries the node rules, dispatch modes, cleanup-pass and docs-sync procedures and the parallel-wave contracts. `/guild <task>` only forces the walk on a request that looks trivial.
- Hooks (POSIX sh, each with a PowerShell twin for Windows machines without Git Bash): always-on context injection at session start, per-prompt reinforcement, an emoji scan on every file edit, and a subagent receipt-contract check.
- Opt-in git handling: a generic `git` skill plus a guard hook that denies AI attribution, `--no-verify` and forced pushes (see Git handling).
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
skills/git/                     generic git workflow skill, active only with git handling on
hooks/                          hooks.json + the sh hook scripts and their .ps1 PowerShell twins
hooks/lib/                      shared libraries (sh, each with a .ps1 twin): payload field access, switch table
hooks/check-context-size.sh     maintenance check: each rendered context part under 9000 bytes
config/defaults.conf            switch defaults, one commented line per key
context/always-on.md            style + universal rules, injected at session start
context/procedure.md            default operating procedure (the DAG walk), injected at session start
charter/SCHEMA.md               charter contract (headings, consumers, content)
charter/TEMPLATE.md             blank charter to copy into a project
workflows/cleanup-audit.js      /guild:cleanup-audit: cleanup-pass audit wave; allow rule Workflow(cleanup-audit)
workflows/review-wave.js        /guild:review-wave: pre-commit review wave over one diff; allow rule Workflow(review-wave)
tests/run.sh                    hook contract suite (sh tests/run.sh), fixtures under tests/fixtures/
tests/run.ps1                   the same contract for the PowerShell twins (pwsh -NoProfile -File tests/run.ps1)
tests/cases/                    payload-driven cases shared by both runners, one file per hook (format in each file)
```

## Requirements

POSIX sh is the primary runtime: dash or bash on Linux and macOS, Git Bash's sh on Windows. That is the same requirement as the Claude Code Bash tool, so any machine that runs Claude Code already has it. Nothing else: the sh hooks use only the standard utilities that ship with that shell (`cat`, `sed`, `grep -E`, `tr`, `cut`, `head`, `dd`, `date`, `sort`, `wc`), and no `jq`, `node` or `python`.

On Windows without Git Bash, Claude Code runs hook commands through PowerShell, and each hook entry then runs the PowerShell 7 twin of its script (`hooks/<script>.ps1`, also valid Windows PowerShell 5.1 syntax) automatically; there is nothing to configure. The twins use only PowerShell and .NET, read the same switches, and produce the same stdout, stderr and exit codes as the sh scripts; both implementations run the shared cases in `tests/cases/`.

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
4. Keep the project's own `git` skill or conventions and leave git handling off, or turn git handling on to use the guild `git` skill and guard instead (see Git handling).
5. Delete any project-local agents or skills whose names collide with the plugin's. Project agents shadow plugin agents, and user skills shadow project skills.

## Configuration

Every switch is on by default except `git.handling`, which is opt-in (see Git handling). Three files are read in order, and a later file wins; for `git.handling` the plugin option, when set, is applied after them and wins:

1. `<plugin root>/config/defaults.conf`: the shipped defaults; it also declares the known keys.
2. `~/.claude/guild.conf`: user overrides.
3. `<project>/.claude/guild.conf`: project overrides.

Grammar: one `key = value` per line, spaces around `=` optional. Values are `on`, `off`, `true`, `false`, `yes` or `no`, in any case; keys are lowercase, exactly as listed below. Blank lines and lines starting with `#` are comments. A malformed line (a trailing `# comment` after the value included), a key the defaults file does not declare, and a missing file are all ignored silently. Values are only matched against that grammar, never expanded or executed.

When any switch differs from its shipped default, the always-on context ends with a `## Guild switches changed` section listing each such switch as `key=value`, comma separated (for example `git.handling=on, review.security=off`), so the session knows what departs from the defaults; with the shipped defaults the section is absent. If `config/defaults.conf` is missing, every key reads as on except `git.handling`, which stays off unless the plugin option turns it on. The `procedure.*`, `review.*` and `docs.sync` switches remove the matching text from the injected procedure, and `git.handling` picks the Step 6 commit sentence; `skills/guild/DAG.md` itself is not templated.

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
| `hooks.emoji_scan` | on | Emoji in written files are no longer rejected |
| `hooks.receipt_check` | on | Guild subagents may stop without a terminal token on line 1 |
| `git.handling` | off | No guild `git` skill and no git guard; the project's own git conventions apply (see Git handling) |

Example, `<project>/.claude/guild.conf` for a project whose security review and emoji policy live elsewhere:

```
# Security review runs outside the guild for this project.
review.security = off
# Emoji are allowed in this project's files.
hooks.emoji_scan = off
```

## Git handling (opt-in)

Off by default. While it is off, nothing git-related from the guild applies: the git guard hook exits without checking, the `git` skill stops at its first line, and Step 6 of the procedure routes commits through the project's own git skill or conventions named under the charter's `## Git`.

On, three things change:

- The `git` skill (`skills/git/SKILL.md`) applies: Conventional Commits, one commit per logical change, no AI attribution, no push without an explicit request, a linear rebase-and-PR flow, and a short forbidden list. It is invoked before any commit, push, branch, rebase or PR.
- Step 6 of the injected procedure routes commits through that skill.
- `hooks/git-guard.sh` checks every `Bash` and `PowerShell` command, compound commands included, and denies:
  - AI attribution (`Co-Authored-By`, `Generated with`, `Claude Code`, `Anthropic`, `noreply@anthropic.com`) in `git commit` and `gh pr create` / `gh pr edit`;
  - a hook bypass: `--no-verify` on `git commit` or `git push`, and `-n` on `git commit` (`git push -n` is a dry run and stays allowed);
  - a forced push: `--force` or `-f` on `git push`; `--force-with-lease` and `--force-if-includes` stay allowed.

  The guard reads the command text only: flags inside quoted spans, bundled short flags (`-nm`), `+branch` refspecs, git options before the subcommand, and attribution supplied through files or environment variables are not detected.

To enable it, answer the prompt Claude Code shows when the plugin is enabled, or change "Git handling" later in `/config`. Claude Code passes the option to the hooks as `CLAUDE_PLUGIN_OPTION_GIT_HANDLING` and into the skill as `${user_config.git_handling}`. `git.handling = on` in a `guild.conf` also turns on the guard and the Step 6 wording, but the plugin option, when set, is applied after every conf file and wins; the skill reads the plugin option only.

## Priority facts

- Agents: project > user > plugin.
- Skills: user > project.
- Hooks merge across levels; none replaces another.

## Hooks

Every entry is a two-line sh/PowerShell polyglot, so one `hooks.json` serves both shells with no `shell` field:

```
exec sh "${CLAUDE_PLUGIN_ROOT}/hooks/<script>.sh" [part]
& "${CLAUDE_PLUGIN_ROOT}/hooks/<script>.ps1" [part]; exit $LASTEXITCODE
```

Claude Code runs a hook command through `sh -c` on Linux and macOS and through Git Bash on Windows when it finds it; otherwise it uses PowerShell. Under sh, `exec` replaces the shell with the sh script, so the second line is never read. Under PowerShell, `exec` is not a command: the first line fails with a non-terminating error and the second line runs the PowerShell twin and exits with its status. The table names the sh scripts; each `.ps1` twin behaves the same.

| Event | Script | What it does | Exit behaviour | Switch |
|---|---|---|---|---|
| SessionStart | `session-context.sh context/always-on.md` | Injects the style and universal rules (sections dropped per switch), plus a `## Guild switches changed` list when any switch differs from its shipped default | Exit 0; never blocks | `style.terse`, `rules.universal` |
| SessionStart | `session-context.sh context/procedure.md` | Injects the default operating procedure with the plugin root substituted; prints nothing when the default mode is off | Exit 0; never blocks | `procedure.default_mode` and the procedure switches |
| UserPromptSubmit | `prompt-reinforce.sh` | Per-prompt reinforcement line: six-line reply budget, universal code rules, procedure walk | Exit 0; never blocks | `hooks.prompt_reinforce` |
| PreToolUse (`Bash`, `PowerShell`) | `git-guard.sh` | Denies AI attribution in `git commit` and `gh pr create` / `gh pr edit`, a hook bypass (`--no-verify`; `-n` on `git commit`) and a forced push (`--force`, `-f`; `--force-with-lease` allowed) | Exit 2 with the reason on stderr on a match; exit 0 otherwise and whenever the switch is off | `git.handling` |
| PostToolUse (`Edit`, `Write`) | `emoji-scan.sh` | Scans the written file (inside the project, non-binary) for emoji | Exit 2 naming the first hit line, reported to the agent; exit 0 otherwise | `hooks.emoji_scan` |
| SubagentStop | `receipt-check.sh` | Checks the receipt contract (first-line terminal token) on `guild:*` agents | Exit 2 blocks the stop once on a malformed receipt; allows otherwise | `hooks.receipt_check` |

SessionStart has one entry per context part because the harness caps a single hook's stdout near 10KB and replaces anything larger with a 2KB preview. `sh hooks/check-context-size.sh` (a maintenance check, not a hook) renders each part with the shipped defaults and fails when any part exceeds 9000 bytes. A malformed payload or an internal error never blocks: the hook prints nothing and exits 0. `sh tests/run.sh` is the contract suite for all of the above; `pwsh -NoProfile -File tests/run.ps1` runs the same shared cases from `tests/cases/`, plus its own coded cases, against the PowerShell twins.

## Non-goals

- Not published to any marketplace.
- No telemetry.
- No gateway or proxy.
