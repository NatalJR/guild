#!/bin/sh
# Maintenance check, not a hook: every context part the SessionStart hooks inject must stay
# under the harness cap (a hook's stdout near 10KB is replaced by a 2KB preview). Each
# context/*.md is rendered through session-context.sh with every switch on (user and project
# overrides cleared) and the output measured. Run after editing anything under context/ or
# config/. Exit 1 on a violation.
set -u

LIMIT=9000

case "$0" in
  */*) hooks_dir=${0%/*} ;;
  *) hooks_dir=. ;;
esac
plugin_root=$(CDPATH='' cd -- "$hooks_dir/.." && pwd) || exit 1

rendered_size() {
  (
    unset HOME CLAUDE_PROJECT_DIR
    CLAUDE_PLUGIN_ROOT=$plugin_root
    export CLAUDE_PLUGIN_ROOT
    sh "$plugin_root/hooks/session-context.sh" "context/$1"
  ) | wc -c
}

# Prints one `name size state` row; returns 1 when the part is too large.
report() {
  size=$(($(rendered_size "$1")))
  state=ok
  [ "$size" -le "$LIMIT" ] || state='TOO LARGE'
  printf '%-22s %6s bytes  %s\n' "$1" "$size" "$state"
  [ "$state" = ok ]
}

failed=0
for part_file in "$plugin_root"/context/*.md; do
  [ -f "$part_file" ] || continue
  report "${part_file##*/}" || failed=1
done
exit "$failed"
