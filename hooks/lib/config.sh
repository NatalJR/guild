# Guild switch table (sourced by the guild hooks; POSIX sh).
# Sources, later wins: <plugin root>/config/defaults.conf, ~/.claude/guild.conf,
# <project>/.claude/guild.conf. Missing files are skipped silently.
# Grammar per line: blank or `#` comment ignored; otherwise `key = value`, optional spaces
# around `=`, keys matching ^[a-z][a-z0-9_.]*$, values on|off|true|false|yes|no in any case.
# Any other line (inline comments included) is ignored silently. The defaults file declares the
# known keys; a key the defaults file does not declare is ignored in the user and project files
# and reads as on, except git.handling, which reads as off (also when the defaults file is missing).
# Lines are only matched against that grammar, never expanded or executed.
# The plugin option CLAUDE_PLUGIN_OPTION_GIT_HANDLING (install prompt or /config) is applied
# after the three files and wins for git.handling: true|1|on|yes in any case is on, any other
# value is off.
# When CLAUDE_PLUGIN_ROOT is unset the root is derived from the sourcing script ($0), which
# sits one level below the plugin root (hooks/*.sh; the test runner in tests/ likewise).
set -u

GUILD_SWITCHES=''
GUILD_DEFAULTS=''
_GUILD_NL='
'
_GUILD_CR=$(printf '\r')
case "$0" in
  */*) _GUILD_SCRIPT_DIR=${0%/*} ;;
  *) _GUILD_SCRIPT_DIR=. ;;
esac

# Builds GUILD_SWITCHES: newline-separated key=on / key=off entries, one per key.
# GUILD_DEFAULTS keeps the same table as declared by the defaults file alone.
guild_config_load() {
  GUILD_SWITCHES=''
  _guild_config_read "${CLAUDE_PLUGIN_ROOT:-$_GUILD_SCRIPT_DIR/..}/config/defaults.conf" declare
  GUILD_DEFAULTS=$GUILD_SWITCHES
  [ -z "${HOME:-}" ] || _guild_config_read "$HOME/.claude/guild.conf" override
  [ -z "${CLAUDE_PROJECT_DIR:-}" ] || _guild_config_read "$CLAUDE_PROJECT_DIR/.claude/guild.conf" override
  _guild_option_apply
  return 0
}

# Returns 0 when KEY is on, 1 when off. A key with no entry takes its built-in default.
guild_switch() {
  _guild_table_value "$GUILD_SWITCHES" "$1" || _guild_builtin_default "$1"
  [ "$_guild_value" = on ]
}

# Prints the key=on / key=off entries whose value differs from the shipped default, sorted by
# key, space separated; nothing when every key holds its default.
guild_changed_keys() {
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

# Sets _guild_value to KEY's shipped default: the defaults file entry, else the built-in one.
_guild_default_value() {
  _guild_table_value "$GUILD_DEFAULTS" "$1" || _guild_builtin_default "$1"
}

# TABLE KEY: sets _guild_value to KEY's state in TABLE; returns 1 when TABLE has no entry.
_guild_table_value() {
  case "$_GUILD_NL$1$_GUILD_NL" in
    *"$_GUILD_NL$2=on$_GUILD_NL"*) _guild_value=on ;;
    *"$_GUILD_NL$2=off$_GUILD_NL"*) _guild_value=off ;;
    *) return 1 ;;
  esac
}

# Built-in defaults for a key no defaults file declares: git.handling is opt-in, the rest on.
_guild_builtin_default() {
  _guild_value=on
  [ "$1" != git.handling ] || _guild_value=off
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
