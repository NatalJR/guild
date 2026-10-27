#!/bin/sh
# SessionStart hook: prints one guild context file; the harness injects stdout as context.
# Usage: sh session-context.sh context/always-on.md
# One hook entry per file, because the harness caps a single hook's stdout near 10KB and
# replaces anything larger with a 2KB preview (hooks/check-context-size.sh keeps each part
# under 9000 bytes).
# Rendering: a line `{{#if KEY}}` or `{{#if !KEY}}` opens a block and a line `{{/if}}` closes
# it (no nesting); marker lines are always dropped and the block body is kept only while switch
# KEY is on (`!KEY`: only while it is off).
# `{{PLUGIN_ROOT}}` becomes the plugin path with forward slashes so the main thread can Read
# DAG.md and the charter template. The always-on part gains a `## Guild switches changed`
# section listing key=value for every switch that differs from its shipped default; the procedure
# part prints nothing when procedure.default_mode is off.
# Missing file or any internal error prints nothing and exits 0 (never blocks a session).
set -u

case "$0" in
  */*) hooks_dir=${0%/*} ;;
  *) hooks_dir=. ;;
esac
CR=$(printf '\r')

contains() {
  case "$1" in *"$2"*) return 0 ;; esac
  return 1
}

# Sets REPLACED to TEXT with every literal FROM replaced by TO.
replace_all() {
  REPLACED=''
  replace_rest=$1
  while [ -n "$2" ] && contains "$replace_rest" "$2"; do
    REPLACED="$REPLACED${replace_rest%%"$2"*}$3"
    replace_rest=${replace_rest#*"$2"}
  done
  REPLACED="$REPLACED$replace_rest"
}

plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
  else
    (CDPATH='' cd -- "$hooks_dir/.." && pwd)
  fi
}

# Sets keep for a `{{#if KEY}}` or `{{#if !KEY}}` marker line.
open_block() {
  block_key=${1#'{{#if '}
  block_key=${block_key%'}}'}
  block_wanted=on
  case "$block_key" in '!'*) block_key=${block_key#'!'}; block_wanted=off ;; esac
  if guild_switch "$block_key"; then block_state=on; else block_state=off; fi
  if [ "$block_state" = "$block_wanted" ]; then keep=yes; else keep=no; fi
}

emit_line() {
  if contains "$1" '{{PLUGIN_ROOT}}'; then
    replace_all "$1" '{{PLUGIN_ROOT}}' "$ROOT_FORWARD"
    printf '%s\n' "$REPLACED"
  else
    printf '%s\n' "$1"
  fi
}

render_line() {
  marker=${1%"$CR"}
  case "$marker" in
    '{{/if}}') keep=yes ;;
    '{{#if '*'}}') open_block "$marker" ;;
    *) [ "$keep" = no ] || emit_line "$1" ;;
  esac
}

render_file() {
  keep=yes
  while IFS= read -r line || [ -n "$line" ]; do
    render_line "$line"
  done <"$1"
}

print_switches_changed() {
  changed=$(guild_changed_keys)
  [ -n "$changed" ] || return 0
  replace_all "$changed" ' ' ', '
  printf '\n## Guild switches changed\n\n%s\n' "$REPLACED"
}

is_suppressed() {
  [ "${1##*/}" = procedure.md ] && ! guild_switch procedure.default_mode
}

main() {
  part=${1:-context/always-on.md}
  . "$hooks_dir/lib/config.sh"
  guild_config_load
  ! is_suppressed "$part" || return 0
  root=$(plugin_root) || return 0
  [ -f "$root/$part" ] && [ -r "$root/$part" ] || return 0
  replace_all "$root" '\' '/'
  ROOT_FORWARD=$REPLACED
  rendered=$(render_file "$root/$part") || return 0
  printf '%s\n' "$rendered"
  [ "${part##*/}" != always-on.md ] || print_switches_changed
}

(main "$@") 2>/dev/null
exit 0
