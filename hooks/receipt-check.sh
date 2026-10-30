#!/bin/sh
set -u

RECEIPT_MARKER_PATTERN='^(plan:|verify:|verified:|docs-sync\.|No issues\.|No match\.|[0-9]+ findings\.|too-big\.|too-small\.|needs-confirm\.|ambiguous\.|regressed\.|need-map\.|blocked\.|not-security\.|security-scope\.|Defs:|Refs:|Callers:|Tests:|Sites:|Imports:)'
LOCATION_PATTERN='^[^[:space:]]+:[0-9]+'
BLOCK_STATUS=3

load_libraries() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 1
set -u

PAYLOAD=''
_PAYLOAD_MARK=$(printf '\037')
_PAYLOAD_QUOTE=$(printf '\036')
_PAYLOAD_TAB=$(printf '\t')
_PAYLOAD_DOUBLE_QUOTE=$(printf '\042')
_PAYLOAD_BACKSLASH=$(printf '\134')
_PAYLOAD_SED_BACKSLASH="$_PAYLOAD_BACKSLASH$_PAYLOAD_BACKSLASH"
_PAYLOAD_SED_NEWLINE="$_PAYLOAD_BACKSLASH
"

payload_read() {
  PAYLOAD=$(cat 2>/dev/null) || PAYLOAD=''
}

payload_field() {
  _payload_is_name "$1" || return 1
  _payload_value=$(printf '%s\n' "$PAYLOAD" | _payload_extract "$1") || return 1
  [ -n "$_payload_value" ] || return 1
  printf '%s' "${_payload_value#=}"
}

payload_bool() {
  _payload_flag=$_PAYLOAD_DOUBLE_QUOTE$1$_PAYLOAD_DOUBLE_QUOTE
  printf '%s\n' "$PAYLOAD" | LC_ALL=C grep -q -F -e "$_payload_flag:true" -e "$_payload_flag: true"
}

payload_first_line() {
  printf '%s\n' "$1" | LC_ALL=C sed -n -e '/[^[:space:]]/{' -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//' -e 'p' -e 'q' -e '}'
}

_payload_is_name() {
  [ -n "$1" ] || return 1
  [ "${1%%[!A-Za-z0-9_]*}" = "$1" ]
}

_payload_extract() {
  _payload_open="s/$_PAYLOAD_DOUBLE_QUOTE$1$_PAYLOAD_DOUBLE_QUOTE[[:space:]]*:[[:space:]]*$_PAYLOAD_DOUBLE_QUOTE/$_PAYLOAD_MARK/"
  LC_ALL=C sed -n -e "$_payload_open" -e 't found' -e 'd' \
    -e ':found' -e "s/^[^$_PAYLOAD_MARK]*$_PAYLOAD_MARK//" \
    -e "s/$_PAYLOAD_SED_BACKSLASH$_PAYLOAD_SED_BACKSLASH/$_PAYLOAD_MARK/g" \
    -e "s/$_PAYLOAD_SED_BACKSLASH$_PAYLOAD_DOUBLE_QUOTE/$_PAYLOAD_QUOTE/g" \
    -e "/$_PAYLOAD_DOUBLE_QUOTE/!q" -e "s/$_PAYLOAD_DOUBLE_QUOTE.*//" \
    -e "s/$_PAYLOAD_QUOTE/$_PAYLOAD_DOUBLE_QUOTE/g" -e "s|$_PAYLOAD_SED_BACKSLASH/|/|g" \
    -e "s/${_PAYLOAD_SED_BACKSLASH}n/$_PAYLOAD_SED_NEWLINE/g" -e "s/${_PAYLOAD_SED_BACKSLASH}t/$_PAYLOAD_TAB/g" \
    -e "s/${_PAYLOAD_SED_BACKSLASH}r//g" -e "s/$_PAYLOAD_MARK/$_PAYLOAD_SED_BACKSLASH/g" -e 's/^/=/' -e 'p' -e 'q'
}
set -u

GUILD_SWITCHES=''
GUILD_DEFAULTS=''
_GUILD_NL='
'
_GUILD_CR=$(printf '\r')

guild_config_load() {
  GUILD_SWITCHES=''
  [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || _guild_config_read "${CLAUDE_PLUGIN_ROOT}/config/defaults.conf" declare
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
  _guild_trimmed=${1#"${1%%[![:space:]]*}"}
  _guild_trimmed=${_guild_trimmed%"${_guild_trimmed##*[![:space:]]}"}
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

is_guild_agent() {
  [ "${1#[Gg][Uu][Ii][Ll][Dd]:}" != "$1" ]
}

in_scope() {
  agent_type=$(payload_field agent_type) || return 1
  is_guild_agent "$agent_type" && ! payload_bool stop_hook_active
}

is_receipt_line() {
  printf '%s\n' "$1" | LC_ALL=C grep -q -i -E -e "$RECEIPT_MARKER_PATTERN" && return 0
  printf '%s\n' "$1" | LC_ALL=C grep -q -E -e "$LOCATION_PATTERN"
}

reject() {
  excerpt=$(printf '%s\n' "$1" | cut -c 1-80)
  printf 'Receipt contract: your final message must START with a terminal token or a receipt line (plan:, verify:, verified:, docs-sync., No issues., No match., N findings., too-big., too-small., needs-confirm., ambiguous., need-map., blocked., regressed., not-security., security-scope., or a path:line row). Got: "%s". Rewrite your final message with the token on line 1 and stop again.\n' "$excerpt" >&2
  exit "$BLOCK_STATUS"
}

main() {
  load_libraries || return 0
  guild_config_load
  guild_switch hooks.receipt_check || return 0
  payload_read
  in_scope || return 0
  final_text=$(payload_field last_assistant_message) || return 0
  first_line=$(payload_first_line "$final_text")
  [ -n "$first_line" ] || return 0
  is_receipt_line "$first_line" || reject "$first_line"
}

(main)
[ "$?" -ne "$BLOCK_STATUS" ] || exit 2
exit 0
