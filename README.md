# guild

guild is a Claude Code plugin that routes coding work through a crew of six specialist agents: an investigator that locates code, a builder for small edits, an architect for work across many files, a reviewer, a security reviewer and a scribe that keeps documentation in sync. A default procedure, loaded at session start, walks every coding request through the same steps: classify, investigate, scope, design, implement, review and report. Project knowledge never lives in the plugin. It lives in a per-project charter file that every agent reads first, so the same crew works in any repository.

The plugin also ships a guild skill that forces the full walk on a request that looks trivial, an optional git skill with a guard against AI attribution, skipped commit checks and forced pushes, two workflows for review and cleanup waves, and hooks for context at session start, a reminder on each prompt, an emoji scan on edited files and a check on each subagent's final report.

## Install

Inside Claude Code:

```
/plugin marketplace add NatalJR/guild
/plugin install guild@guild
```

Then copy `charter/TEMPLATE.md` from the plugin into your project as `.claude/guild.md` and fill in every section; `charter/SCHEMA.md` describes each one. Point the project's `CLAUDE.md` at the charter with one line.

## Requirements

- **POSIX sh:** the same shell the Claude Code Bash tool needs: dash or bash on Linux and macOS, the sh of Git Bash on Windows. The hooks use only the standard utilities that come with it.
- **Windows without Git Bash:** PowerShell 7 (`pwsh`) on the system path. Each hook then runs its PowerShell twin automatically, with the same behaviour; there is nothing to configure.

## Configuration

Every switch is on by default, and a later file wins:

- `config/defaults.conf` inside the plugin: the shipped switches and their names.
- `~/.claude/guild.conf`: your personal overrides.
- `.claude/guild.conf` in a project: overrides for that project.
- Plugin options, asked at install and changed later in `/config`: git handling (off by default), and a model and a reasoning effort for each of the six agents.

A switch line reads `name = off`, for example `hooks.emoji_scan = off`. Values are only matched against on, off, true, false, yes and no; they are never expanded or executed.

## What the plugin runs, reads and writes

- **Runs:** six hook scripts, each a POSIX sh script with a PowerShell twin, and nothing else on its own.
- **Launched by Claude Code:** `session-context` and `render-agents` at session start, `prompt-reinforce` and `render-agents` on each prompt, `git-guard` before Bash and PowerShell tool calls, `emoji-scan` after Edit and Write tool calls, and `receipt-check` when a subagent stops. There is no package launcher, no install step and no interpreter other than sh or PowerShell.
- **Reads:** the tool call details Claude Code passes to each hook; `config/defaults.conf` inside the plugin; your personal and project `guild.conf` files when present; the file just written, for the emoji scan, only when it lies inside the project directory; the plugin's own agent files; the values of the plugin options.
- **Writes:** only the model and effort lines at the top of the plugin's own agent files, through the option render hook, with values restricted to fixed lists. Nothing in your home directory, nothing in your project.
- **Sends:** nothing. No network access of any kind and no telemetry.
- **Personal data:** none read or stored.
- **Workflows:** run only when invoked by name, through the Claude Code Workflow tool, with the agents' own permissions.

The full documentation, with the delegation graph, every switch and every hook, is in the [repository README](https://github.com/NatalJR/guild#readme).
