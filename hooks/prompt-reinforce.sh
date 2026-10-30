#!/bin/sh
# UserPromptSubmit hook: per-turn reinforcement of the guild context, since style drifts
# in long sessions. The harness injects stdout as context. Switch: hooks.prompt_reinforce.
# Any internal error prints nothing and exits 0 (never blocks a prompt).
set -u

# Succeeds when CLAUDE_PLUGIN_ROOT is set and holds the library this hook sources; the
# harness always exports it for plugin hooks.
libraries_present() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh" ]
}

main() {
  libraries_present || return 0
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh"
  guild_config_load
  guild_switch hooks.prompt_reinforce || return 0
  printf '%s\n' 'GUILD DEFAULT MODE: replies at most six lines, universal code rules, coding requests walk the operating procedure in session context (no slash command).'
}

(main) 2>/dev/null
exit 0
