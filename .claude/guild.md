# Guild charter: the guild plugin itself

## Identity

guild: a project-agnostic Claude Code plugin (agents, the guild and git skills, POSIX sh hooks, injected context with switches, two workflows, charter convention). GitHub `NatalJR/guild`; this charter applies to any checkout. Runtime for hooks: POSIX sh (dash or bash on Linux and macOS, Git Bash's sh on Windows), with a PowerShell 7 fallback implementation used by the harness only when Git Bash is absent on Windows; both implementations run the same shared test cases. No package manager, no dependencies, no build step.

## Verify

```bash
sh tests/run.sh                                                    # hook contract suite on the host sh (Git Bash here); the lint gate
wsl -e sh tests/run.sh                                             # same suite under dash on WSL Ubuntu (strict POSIX); WSL starts in the checkout; both must pass before a commit
pwsh -NoProfile -File tests/run.ps1                                # PowerShell 7 fallback implementations, same shared cases
env -u CLAUDECODE claude plugin validate .                         # manifest and layout validation
sh hooks/check-context-size.sh                                   # every rendered context part stays under 9000 bytes
for f in workflows/*.js; do { printf 'async function workflow() {
'; sed 's/^export const meta/const meta/' "$f"; printf '
}
'; } | node --input-type=module --check && echo "ok $f"; done   # workflow syntax, body-wrapped because the harness allows top-level return; node is a dev-time check only, never a runtime dependency
```

Hook scripts are exercised by piping a JSON payload on stdin and asserting the exit code (0 allow, 2 block) and the stderr message. Nothing in this repository needs network access.

## Areas

- hooks: `hooks/**` (scripts, `hooks.json`, shared `hooks/lib/**`)
- context: `context/**`, `config/**` (injected text, switch defaults, templating markers)
- agents: `agents/**`
- skills: `skills/**`
- charter: `charter/**`
- workflows: `workflows/**`
- tests: `tests/**`
- docs: `README.md`, `LICENSE`, `.claude-plugin/**`

## Rules

none beyond the universal rules; shell specifics: strict POSIX sh (`#!/bin/sh`, no bash-isms: no `[[`, arrays, `local`, `function`, `pipefail`), `set -u` in every script, no `eval`, `.` only on files inside the plugin, quote every expansion, POSIX ERE only (`grep -E`), no `grep -P`, no `jq`, no `node`, no `python`. The `.ps1` twins are PowerShell 5.1-compatible syntax, behaviour-identical to their `.sh` twin, and never the primary path.

## Security

- Hook stdin is untrusted data from tool calls and subagent output: never `eval` it, never pass it to a shell as code, never interpolate it into a command line unquoted.
- File paths from payloads are only ever read (never written or executed) and only inside `CLAUDE_PROJECT_DIR` when that variable is set.
- Config files (`guild.conf`) are parsed line by line with a fixed `key = value` grammar; no shell expansion of values.
- The plugin writes only inside its own `agents/` (the option render hook, frontmatter lines only, allowlisted values); it never reads secrets and never touches `CLAUDE_PLUGIN_DATA`.

## Docs

- Normative: `README.md` (install, requirements, configuration, hooks table, layout, non-goals), `charter/SCHEMA.md` (charter section contract), `charter/TEMPLATE.md`.
- Injected context: `context/always-on.md`, `context/procedure.md` (default-mode walk), `skills/guild/DAG.md` (binding node rules).
- Docs-sync enumeration: `README.md`, `charter/SCHEMA.md`, `charter/TEMPLATE.md`, `context/always-on.md`, `context/procedure.md`, `skills/guild/SKILL.md`, `skills/guild/DAG.md`, `config/defaults.conf` comments, `.claude-plugin/plugin.json` version, this charter.

## Process surfaces

`.claude/guild.md` (this file), `README.md` release notes, GitHub issues. Main thread only.

## Forbidden for subagents

Commits, pushes, tags, releases, repository visibility or settings changes (`gh repo edit`), plugin install/uninstall on the host, edits under `~/.claude`, deleting test fixtures.

## Tracker

GitHub issues on `NatalJR/guild` (`gh issue list/view/close`). Open issues are closed only by the main thread with a comment naming the commit.

## QA

Live harness behaviour (hook stdout size cap, SessionStart injection, SubagentStop payload shape) cannot be asserted from the test suite; it is probed with `env -u CLAUDECODE claude -p` from a consuming project and the result recorded in the commit message or README.

## Git

Conventional Commits, imperative subject, no AI attribution anywhere. Main is pushed only on the owner's request. Visibility changes are the owner's click.
