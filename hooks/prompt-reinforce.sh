#!/bin/sh
# UserPromptSubmit hook: per-turn reinforcement of the guild context, since style drifts
# in long sessions. The harness injects stdout as context. Switch: hooks.prompt_reinforce.
# Any internal error prints nothing and exits 0 (never blocks a prompt).
set -u

case "$0" in
  */*) hooks_dir=${0%/*} ;;
  *) hooks_dir=. ;;
esac

main() {
  . "$hooks_dir/lib/config.sh"
  guild_config_load
  guild_switch hooks.prompt_reinforce || return 0
  printf '%s\n' 'GUILD DEFAULT MODE: replies at most six lines, universal code rules, coding requests walk the operating procedure in session context (no slash command).'
}

(main) 2>/dev/null
exit 0
