#!/bin/sh
# Maintenance check, not a hook: every context part the SessionStart hooks inject must stay
# under the harness cap (a hook's stdout near 10KB is replaced by a 2KB preview). Each
# context/*.md is rendered through the session context hook with the shipped defaults (user,
# project and plugin option overrides cleared) and the output measured. Run after editing
# anything under context/ or config/. Exit 1 on a violation.
set -u

LIMIT=9000

# The plugin root is the parent of this script's directory unless CLAUDE_PLUGIN_ROOT is set.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  script_directory=$(dirname -- "$0")
  CLAUDE_PLUGIN_ROOT=$(CDPATH='' cd -- "$script_directory/.." && pwd) || exit 1
fi
export CLAUDE_PLUGIN_ROOT

rendered_size() {
  (
    unset HOME CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_OPTION_GIT_HANDLING
    sh "${CLAUDE_PLUGIN_ROOT}/hooks/session-context.sh" "context/$1"
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
for part_file in "${CLAUDE_PLUGIN_ROOT}"/context/*.md; do
  [ -f "$part_file" ] || continue
  report "${part_file##*/}" || failed=1
done
exit "$failed"
