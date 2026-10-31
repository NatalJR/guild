# Guild switch table (sourced by the guild hooks; POSIX sh).
# Sources, later wins: <plugin root>/config/defaults.conf, ~/.claude/guild.conf,
# <project>/.claude/guild.conf. Missing files are skipped silently.
# Grammar per line: blank or `#` comment ignored; otherwise `name = value`, optional spaces
# around `=`, names matching ^[a-z][a-z0-9_.]*$, values on|off|true|false|yes|no in any case.
# Any other line (inline comments included) is ignored silently. The defaults file declares the
# known switches; a switch the defaults file does not declare is ignored in the user and project
# files and reads as on. Lines are only matched against that grammar, never expanded or executed.
# git.handling is not a conf switch: a line for it is ignored in every file, the defaults file
# included. The plugin option CLAUDE_PLUGIN_OPTION_GIT_HANDLING (install prompt or /config) is
# its only source: true|1|on|yes in any case is on, any other value is off, unset reads as off.
# The defaults file is read from ${CLAUDE_PLUGIN_ROOT} only; when it is unset no defaults file is
# read (the hooks exit before sourcing this file in that case). The release build compiles the
# defaults in: it replaces that read with one declare line per defaults file entry.
# The Claude Directory validator cannot read `case` statements, so every match below is a `[ ]`
# test on a parameter expansion.
set -u

GUILD_SWITCHES=''
GUILD_DEFAULTS=''
_GUILD_NL='
'
_GUILD_CR=$(printf '\r')

# Builds GUILD_SWITCHES: newline-separated name=on / name=off entries, one per switch.
# GUILD_DEFAULTS keeps the same table as declared by the defaults file alone.
guild_config_load() {
  GUILD_SWITCHES=''
  # Release build anchor: the only code line naming the defaults file, replaced by generated
  # declare lines. Rewriting it or adding a second such line breaks the release build.
  [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || _guild_config_read "${CLAUDE_PLUGIN_ROOT}/config/defaults.conf" declare
  GUILD_DEFAULTS=$GUILD_SWITCHES
  [ -z "${HOME:-}" ] || _guild_config_read "$HOME/.claude/guild.conf" override
  [ -z "${CLAUDE_PROJECT_DIR:-}" ] || _guild_config_read "$CLAUDE_PROJECT_DIR/.claude/guild.conf" override
  _guild_option_apply
  return 0
}

# Returns 0 when switch NAME is on, 1 when off. A switch with no entry takes its built-in default.
guild_switch() {
  _guild_table_value "$GUILD_SWITCHES" "$1" || _guild_builtin_default "$1"
  [ "$_guild_value" = on ]
}

# Prints the name=on / name=off entries whose value differs from the shipped default, sorted by
# name, space separated; nothing when every switch holds its default.
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

# Sets _guild_value to NAME's shipped default: the defaults file entry, else the built-in one.
_guild_default_value() {
  _guild_table_value "$GUILD_DEFAULTS" "$1" || _guild_builtin_default "$1"
}

# TABLE NAME: sets _guild_value to NAME's state in TABLE; returns 1 when TABLE has no entry.
_guild_table_value() {
  if _guild_table_has "$1" "$2=on"; then
    _guild_value=on
  elif _guild_table_has "$1" "$2=off"; then
    _guild_value=off
  else
    return 1
  fi
}

# TABLE ENTRY: succeeds when ENTRY is one whole line of TABLE.
_guild_table_has() {
  _guild_lines="$_GUILD_NL$1$_GUILD_NL"
  _guild_rest=${_guild_lines#*"$_GUILD_NL$2$_GUILD_NL"}
  [ "$_guild_rest" != "$_guild_lines" ]
}

# Built-in defaults for a switch no defaults file declares: git.handling is opt-in, the rest on.
_guild_builtin_default() {
  _guild_value=on
  [ "$1" != git.handling ] || _guild_value=off
}

# FILE MODE: applies every valid line; MODE declare accepts new switches, override only known ones.
_guild_config_read() {
  [ -f "$1" ] && [ -r "$1" ] || return 0
  _guild_config_mode=$2
  while IFS= read -r _guild_config_line || [ -n "$_guild_config_line" ]; do
    _guild_config_apply "$_guild_config_line"
  done <"$1"
}

_guild_config_apply() {
  _guild_config_parse "$1" || return 0
  # git.handling comes from the plugin option only.
  [ "$_guild_name" != git.handling ] || return 0
  _guild_switch_known "$_guild_name" || [ "$_guild_config_mode" = declare ] || return 0
  _guild_switch_store "$_guild_name" "$_guild_state"
}

# Sets _guild_name and _guild_state from a `name = value` line; returns 1 for any other line.
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

# Succeeds when NAME starts with a lowercase letter and holds only [a-z0-9_.].
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

# Succeeds when WORD is on, true or yes in any case.
_guild_is_on_word() {
  [ -n "$1" ] || return 1
  [ -z "${1#[Oo][Nn]}" ] || [ -z "${1#[Tt][Rr][Uu][Ee]}" ] || [ -z "${1#[Yy][Ee][Ss]}" ]
}

# Succeeds when WORD is off, false or no in any case.
_guild_is_off_word() {
  [ -n "$1" ] || return 1
  [ -z "${1#[Oo][Ff][Ff]}" ] || [ -z "${1#[Ff][Aa][Ll][Ss][Ee]}" ] || [ -z "${1#[Nn][Oo]}" ]
}

# Maps the git handling plugin option, when set, onto git.handling: 1 or an on word is on.
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

# Rewrites the existing entry for NAME in place, keeping the table order.
_guild_switch_replace() {
  _guild_table="$_GUILD_NL$GUILD_SWITCHES$_GUILD_NL"
  _guild_before=${_guild_table%%"$_GUILD_NL$1="*}
  _guild_after=${_guild_table#*"$_GUILD_NL$1="}
  _guild_after=${_guild_after#*"$_GUILD_NL"}
  _guild_table="$_guild_before$_GUILD_NL$1=$2$_GUILD_NL$_guild_after"
  _guild_table=${_guild_table#"$_GUILD_NL"}
  GUILD_SWITCHES=${_guild_table%"$_GUILD_NL"}
}
