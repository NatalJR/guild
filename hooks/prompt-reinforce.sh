#!/bin/sh
# UserPromptSubmit hook: per-turn reinforcement of the guild context, since style drifts
# in long sessions. The harness injects stdout as context. Switch: hooks.prompt_reinforce.
# Any internal error prints nothing and exits 0 (never blocks a prompt).
set -u

# Loads the switch library from CLAUDE_PLUGIN_ROOT, which the harness always exports for plugin
# hooks; returns 1 when it is unset or the library is missing.
load_libraries() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 1
  [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh" ] || return 1
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh"
}

main() {
  load_libraries || return 0
  guild_config_load
  guild_switch hooks.prompt_reinforce || return 0
  printf '%s\n' 'GUILD DEFAULT MODE: replies at most six lines, universal code rules, coding requests walk the operating procedure in session context (no slash command).'
}

(main) 2>/dev/null
exit 0
