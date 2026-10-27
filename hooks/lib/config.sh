# Guild switch table (sourced by the guild hooks; POSIX sh).
# Sources, later wins: <plugin root>/config/defaults.conf, ~/.claude/guild.conf,
# <project>/.claude/guild.conf. Missing files are skipped silently.
# Grammar per line: blank or `#` comment ignored; otherwise `key = value`, optional spaces
# around `=`, keys matching ^[a-z][a-z0-9_.]*$, values on|off|true|false|yes|no in any case.
# Any other line (inline comments included) is ignored silently. The defaults file declares the
# known keys; a key the defaults file does not declare is ignored in the user and project files.
# Lines are only matched against that grammar, never expanded or executed.
# The plugin option CLAUDE_PLUGIN_OPTION_GIT_HANDLING (install prompt or /config) is applied
# after the three files and wins for git.handling: true|1|on|yes in any case is on, any other
# value is off.
# When CLAUDE_PLUGIN_ROOT is unset the root is derived from the sourcing script ($0), which
# sits one level below the plugin root (hooks/*.sh; the test runner in tests/ likewise).
set -u

GUILD_SWITCHES=''
_GUILD_NL='
'
_GUILD_CR=$(printf '\r')
case "$0" in
  */*) _GUILD_SCRIPT_DIR=${0%/*} ;;
  *) _GUILD_SCRIPT_DIR=. ;;
esac

# Builds GUILD_SWITCHES: newline-separated key=on / key=off entries, one per key.
guild_config_load() {
  GUILD_SWITCHES=''
  _guild_config_read "${CLAUDE_PLUGIN_ROOT:-$_GUILD_SCRIPT_DIR/..}/config/defaults.conf" declare
  [ -z "${HOME:-}" ] || _guild_config_read "$HOME/.claude/guild.conf" override
  [ -z "${CLAUDE_PROJECT_DIR:-}" ] || _guild_config_read "$CLAUDE_PROJECT_DIR/.claude/guild.conf" override
  _guild_option_apply
  return 0
}

# Returns 0 when KEY is on or unknown (unknown keys default to on), 1 when off.
guild_switch() {
  case "$_GUILD_NL$GUILD_SWITCHES$_GUILD_NL" in
    *"$_GUILD_NL$1=off$_GUILD_NL"*) return 1 ;;
  esac
  return 0
}

# Prints the keys that are off, sorted, space separated; nothing when every key is on.
guild_disabled_keys() {
  _guild_off=$(printf '%s\n' "$GUILD_SWITCHES" | sed -n 's/=off$//p' | LC_ALL=C sort | tr '\n' ' ')
  [ -z "$_guild_off" ] || printf '%s\n' "${_guild_off% }"
  return 0
}

# FILE MODE: applies every valid line; MODE declare accepts new keys, override only known ones.
_guild_config_read() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  _guild_config_mode=$2
  while IFS= read -r _guild_config_line || [ -n "$_guild_config_line" ]; do
    _guild_config_apply "$_guild_config_line"
  done <"$1"
}

_guild_config_apply() {
  _guild_config_parse "$1" || return 0
  _guild_switch_known "$_guild_key" || [ "$_guild_config_mode" = declare ] || return 0
  _guild_switch_store "$_guild_key" "$_guild_state"
}

# Sets _guild_key and _guild_state from a `key = value` line; returns 1 for any other line.
_guild_config_parse() {
  _guild_text=${1%"$_GUILD_CR"}
  case "$_guild_text" in *=*) ;; *) return 1 ;; esac
  _guild_trim "${_guild_text%%=*}"
  _guild_key=$_guild_trimmed
  _guild_trim "${_guild_text#*=}"
  _guild_is_key "$_guild_key" && _guild_parse_state "$_guild_trimmed"
}

_guild_trim() {
  _guild_trimmed=${1#"${1%%[![:space:]]*}"}
  _guild_trimmed=${_guild_trimmed%"${_guild_trimmed##*[![:space:]]}"}
}

_guild_is_key() {
  case "$1" in [a-z]*) ;; *) return 1 ;; esac
  case "$1" in *[!a-z0-9_.]*) return 1 ;; esac
  return 0
}

_guild_parse_state() {
  case "$1" in
    [Oo][Nn] | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss]) _guild_state=on ;;
    [Oo][Ff][Ff] | [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo]) _guild_state=off ;;
    *) return 1 ;;
  esac
}

# Maps the git handling plugin option, when set, onto git.handling.
_guild_option_apply() {
  [ -n "${CLAUDE_PLUGIN_OPTION_GIT_HANDLING+set}" ] || return 0
  case "$CLAUDE_PLUGIN_OPTION_GIT_HANDLING" in
    [Tt][Rr][Uu][Ee] | 1 | [Oo][Nn] | [Yy][Ee][Ss]) _guild_switch_store git.handling on ;;
    *) _guild_switch_store git.handling off ;;
  esac
}

_guild_switch_known() {
  case "$_GUILD_NL$GUILD_SWITCHES$_GUILD_NL" in
    *"$_GUILD_NL$1="*) return 0 ;;
  esac
  return 1
}

_guild_switch_store() {
  if _guild_switch_known "$1"; then
    _guild_switch_replace "$1" "$2"
  else
    GUILD_SWITCHES="${GUILD_SWITCHES:+$GUILD_SWITCHES$_GUILD_NL}$1=$2"
  fi
}

# Rewrites the existing entry for KEY in place, keeping the table order.
_guild_switch_replace() {
  _guild_table="$_GUILD_NL$GUILD_SWITCHES$_GUILD_NL"
  _guild_before=${_guild_table%%"$_GUILD_NL$1="*}
  _guild_after=${_guild_table#*"$_GUILD_NL$1="}
  _guild_after=${_guild_after#*"$_GUILD_NL"}
  _guild_table="$_guild_before$_GUILD_NL$1=$2$_GUILD_NL$_guild_after"
  _guild_table=${_guild_table#"$_GUILD_NL"}
  GUILD_SWITCHES=${_guild_table%"$_GUILD_NL"}
}
