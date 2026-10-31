#!/bin/sh
# SessionStart hook: prints one guild context file; the harness injects stdout as context.
# Usage: sh session-context.sh context/always-on.md
# One hook entry per file, because the harness caps a single hook's stdout near 10KB and
# replaces anything larger with a 2KB preview (the context size check keeps each part under
# 9000 bytes).
# Rendering: a line of two opening braces, hash, if, space, NAME, two closing braces (NAME may
# carry a leading `!`) opens a block, and a line of two opening braces, slash, if, two closing
# braces closes it (no nesting); marker lines are always dropped and the block body is kept only
# while switch NAME is on (`!NAME`: only while it is off).
# PLUGIN_ROOT wrapped in two opening and two closing braces becomes the plugin path with forward
# slashes so the main thread can Read DAG.md and the charter template. The always-on part gains
# a `## Guild switches changed` section listing name=value for every switch that differs from its
# shipped default; the procedure part prints nothing when procedure.default_mode is off.
# Missing file or any internal error prints nothing and exits 0 (never blocks a session).
# The Claude Directory validator cannot read `case` statements, so every match is a `[ ]` test.
set -u

CR=$(printf '\r')
BACKSLASH=$(printf '\134')
LB=$(printf '\173')
RB=$(printf '\175')
OPEN_MARK="$LB$LB#if "
CLOSE_MARK="$LB$LB/if$RB$RB"
END_MARK="$RB$RB"
ROOT_MARK="$LB${LB}PLUGIN_ROOT$RB$RB"

# Loads the switch library from CLAUDE_PLUGIN_ROOT, which the harness always exports for plugin
# hooks; returns 1 when it is unset, not a directory, or the library is missing.
load_libraries() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 1
  [ -d "${CLAUDE_PLUGIN_ROOT}" ] || return 1
  [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh" ] || return 1
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh"
}

# TEXT PART: succeeds when TEXT holds PART (always for an empty PART).
contains() {
  [ -n "$2" ] || return 0
  contains_rest=${1#*"$2"}
  [ "$contains_rest" != "$1" ]
}

# Sets REPLACED to TEXT with every literal FROM replaced by TO.
# No quote may sit inside a double-quoted string in a hook script: the Claude Directory validator cannot read it.
replace_all() {
  REPLACED=''
  replace_rest=$1
  while [ -n "$2" ] && contains "$replace_rest" "$2"; do
    replace_head=${replace_rest%%"$2"*}
    REPLACED=$REPLACED$replace_head$3
    replace_rest=${replace_rest#*"$2"}
  done
  REPLACED="$REPLACED$replace_rest"
}

# Succeeds when LINE starts with the opening marker and ends with the closing braces.
is_open_marker() {
  marker_rest=${1#"$OPEN_MARK"}
  [ "$marker_rest" != "$1" ] || return 1
  marker_inner=${marker_rest%"$END_MARK"}
  [ "$marker_inner" != "$marker_rest" ]
}

# Sets keep for an opening marker line (NAME or !NAME).
open_block() {
  block_switch=${1#"$OPEN_MARK"}
  block_switch=${block_switch%"$END_MARK"}
  block_wanted=on
  block_name=${block_switch#!}
  [ "$block_name" = "$block_switch" ] || block_wanted=off
  if guild_switch "$block_name"; then block_state=on; else block_state=off; fi
  if [ "$block_state" = "$block_wanted" ]; then keep=yes; else keep=no; fi
}

emit_line() {
  if contains "$1" "$ROOT_MARK"; then
    replace_all "$1" "$ROOT_MARK" "$ROOT_FORWARD"
    printf '%s\n' "$REPLACED"
  else
    printf '%s\n' "$1"
  fi
}

render_line() {
  marker=${1%"$CR"}
  if [ "$marker" = "$CLOSE_MARK" ]; then
    keep=yes
  elif is_open_marker "$marker"; then
    open_block "$marker"
  elif [ "$keep" != no ]; then
    emit_line "$1"
  fi
}

render_file() {
  keep=yes
  old_ifs=$IFS
  IFS=''
  while read -r line || [ -n "$line" ]; do
    render_line "$line"
  done <"$1"
  IFS=$old_ifs
}

print_switches_changed() {
  changed=$(guild_changed_switches)
  [ -n "$changed" ] || return 0
  replace_all "$changed" ' ' ', '
  printf '\n## Guild switches changed\n\n%s\n' "$REPLACED"
}

is_suppressed() {
  [ "${1##*/}" = procedure.md ] && ! guild_switch procedure.default_mode
}

main() {
  part=${1:-context/always-on.md}
  load_libraries || return 0
  guild_config_load
  ! is_suppressed "$part" || return 0
  root=${CLAUDE_PLUGIN_ROOT}
  [ -f "$root/$part" ] && [ -r "$root/$part" ] || return 0
  replace_all "$root" "$BACKSLASH" '/'
  ROOT_FORWARD=$REPLACED
  rendered=$(render_file "$root/$part") || return 0
  printf '%s\n' "$rendered"
  [ "${part##*/}" != always-on.md ] || print_switches_changed
}

(main "$@") 2>/dev/null
exit 0
