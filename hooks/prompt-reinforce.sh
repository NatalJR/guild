#!/bin/sh
set -u

load_libraries() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 1
  [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || return 1
set -u

GUILD_SWITCHES=''
GUILD_DEFAULTS=''
_GUILD_NL='
'
_GUILD_CR=$(printf '\r')

guild_config_load() {
  GUILD_SWITCHES=''
  _guild_config_mode=declare
  _guild_config_apply 'style.terse = on'
  _guild_config_apply 'rules.universal = on'
  _guild_config_apply 'procedure.default_mode = on'
  _guild_config_apply 'procedure.investigate_first = on'
  _guild_config_apply 'procedure.design_gate = on'
  _guild_config_apply 'procedure.sharding = on'
  _guild_config_apply 'procedure.cleanup_pass = on'
  _guild_config_apply 'review.norms = on'
  _guild_config_apply 'review.correctness = on'
  _guild_config_apply 'review.security = on'
  _guild_config_apply 'docs.sync = on'
  _guild_config_apply 'hooks.prompt_reinforce = on'
  _guild_config_apply 'hooks.emoji_scan = on'
  _guild_config_apply 'hooks.receipt_check = on'
  GUILD_DEFAULTS=$GUILD_SWITCHES
  [ -z "${HOME:-}" ] || _guild_config_read "$HOME/.claude/guild.conf" override
  [ -z "${CLAUDE_PROJECT_DIR:-}" ] || _guild_config_read "$CLAUDE_PROJECT_DIR/.claude/guild.conf" override
  _guild_option_apply
  return 0
}

guild_switch() {
  _guild_table_value "$GUILD_SWITCHES" "$1" || _guild_builtin_default "$1"
  [ "$_guild_value" = on ]
}

guild_changed_switches() {
  _guild_changed=$(_guild_changed_entries | LC_ALL=C sort -t '=' -k 1,1 | tr '\n' ' ')
  [ -z "$_guild_changed" ] || printf '%s\n' "${_guild_changed% }"
  return 0
}

_guild_changed_entries() {
  printf '%s\n' "$GUILD_SWITCHES" | while IFS= read -r _guild_entry; do
    [ -n "$_guild_entry" ] || continue
    _guild_default_value "${_guild_entry%%=*}"
    [ "${_guild_entry#*=}" = "$_guild_value" ] || printf '%s\n' "$_guild_entry"
  done
}

_guild_default_value() {
  _guild_table_value "$GUILD_DEFAULTS" "$1" || _guild_builtin_default "$1"
}

_guild_table_value() {
  if _guild_table_has "$1" "$2=on"; then
    _guild_value=on
  elif _guild_table_has "$1" "$2=off"; then
    _guild_value=off
  else
    return 1
  fi
}

_guild_table_has() {
  _guild_lines="$_GUILD_NL$1$_GUILD_NL"
  _guild_rest=${_guild_lines#*"$_GUILD_NL$2$_GUILD_NL"}
  [ "$_guild_rest" != "$_guild_lines" ]
}

_guild_builtin_default() {
  _guild_value=on
  [ "$1" != git.handling ] || _guild_value=off
}

_guild_config_read() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  _guild_config_mode=$2
  while IFS= read -r _guild_config_line || [ -n "$_guild_config_line" ]; do
    _guild_config_apply "$_guild_config_line"
  done <"$1"
}

_guild_config_apply() {
  _guild_config_parse "$1" || return 0
  [ "$_guild_name" != git.handling ] || return 0
  _guild_switch_known "$_guild_name" || [ "$_guild_config_mode" = declare ] || return 0
  _guild_switch_store "$_guild_name" "$_guild_state"
}

_guild_config_parse() {
  _guild_text=${1%"$_GUILD_CR"}
  [ "${_guild_text#*=}" != "$_guild_text" ] || return 1
  _guild_trim "${_guild_text%%=*}"
  _guild_name=$_guild_trimmed
  _guild_trim "${_guild_text#*=}"
  _guild_is_name "$_guild_name" && _guild_parse_state "$_guild_trimmed"
}

_guild_trim() {
  _guild_lead=${1%%[![:space:]]*}
  _guild_trimmed=${1#"$_guild_lead"}
  _guild_tail=${_guild_trimmed##*[![:space:]]}
  _guild_trimmed=${_guild_trimmed%"$_guild_tail"}
}

_guild_is_name() {
  [ "${1#[a-z]}" != "$1" ] || return 1
  [ "${1%%[!a-z0-9_.]*}" = "$1" ]
}

_guild_parse_state() {
  if _guild_is_on_word "$1"; then
    _guild_state=on
  elif _guild_is_off_word "$1"; then
    _guild_state=off
  else
    return 1
  fi
}

_guild_is_on_word() {
  [ -n "$1" ] || return 1
  [ -z "${1#[Oo][Nn]}" ] || [ -z "${1#[Tt][Rr][Uu][Ee]}" ] || [ -z "${1#[Yy][Ee][Ss]}" ]
}

_guild_is_off_word() {
  [ -n "$1" ] || return 1
  [ -z "${1#[Oo][Ff][Ff]}" ] || [ -z "${1#[Ff][Aa][Ll][Ss][Ee]}" ] || [ -z "${1#[Nn][Oo]}" ]
}

_guild_option_apply() {
  [ -n "${CLAUDE_PLUGIN_OPTION_GIT_HANDLING+set}" ] || return 0
  _guild_option=$CLAUDE_PLUGIN_OPTION_GIT_HANDLING
  if [ "$_guild_option" = 1 ] || _guild_is_on_word "$_guild_option"; then
    _guild_switch_store git.handling on
  else
    _guild_switch_store git.handling off
  fi
}

_guild_switch_known() {
  _guild_lines="$_GUILD_NL$GUILD_SWITCHES$_GUILD_NL"
  _guild_rest=${_guild_lines#*"$_GUILD_NL$1="}
  [ "$_guild_rest" != "$_guild_lines" ]
}

_guild_switch_store() {
  if _guild_switch_known "$1"; then
    _guild_switch_replace "$1" "$2"
  elif [ -z "$GUILD_SWITCHES" ]; then
    GUILD_SWITCHES="$1=$2"
  else
    GUILD_SWITCHES="$GUILD_SWITCHES$_GUILD_NL$1=$2"
  fi
}

_guild_switch_replace() {
  _guild_table="$_GUILD_NL$GUILD_SWITCHES$_GUILD_NL"
  _guild_before=${_guild_table%%"$_GUILD_NL$1="*}
  _guild_after=${_guild_table#*"$_GUILD_NL$1="}
  _guild_after=${_guild_after#*"$_GUILD_NL"}
  _guild_table="$_guild_before$_GUILD_NL$1=$2$_GUILD_NL$_guild_after"
  _guild_table=${_guild_table#"$_GUILD_NL"}
  GUILD_SWITCHES=${_guild_table%"$_GUILD_NL"}
}
}

main() {
  load_libraries || return 0
  guild_config_load
  guild_switch hooks.prompt_reinforce || return 0
  printf '%s\n' 'GUILD DEFAULT MODE: replies at most six lines, universal code rules, coding requests walk the operating procedure in session context (no slash command).'
}

(main) 2>/dev/null
exit 0
