#!/bin/sh
# PreToolUse hook (Bash|PowerShell): blocks a git commit or a PR create/edit whose command
# text carries AI attribution (owner rule).
# Text-level guardrail only: it inspects the command string, so attribution supplied through
# files (commit -F, --body-file), templates, or environment variables is not detected.
# Switch: hooks.deny_attribution. A malformed payload or an internal error never blocks.
set -u

GIT_ARTIFACT_PATTERN='git[[:space:]]+commit|gh[[:space:]]+pr[[:space:]]+(create|edit)'
ATTRIBUTION_PATTERN='Co-Authored-By|Generated with|Claude Code|Anthropic|noreply@anthropic\.com'
BLOCK_MESSAGE='BLOCKED: AI attribution in a git artifact is forbidden (owner rule). Remove the trailer/footer and retry.'
# Internal status meaning "block"; any other status, including a shell error, allows.
BLOCK_STATUS=3

case "$0" in
  */*) hooks_dir=${0%/*} ;;
  *) hooks_dir=. ;;
esac

# Newlines are folded to spaces first, so a command split across lines still counts.
creates_git_artifact() {
  printf '%s\n' "$1" | tr '\n' ' ' | LC_ALL=C grep -q -i -E -e "$GIT_ARTIFACT_PATTERN"
}

carries_attribution() {
  printf '%s\n' "$1" | LC_ALL=C grep -q -i -E -e "$ATTRIBUTION_PATTERN"
}

main() {
  . "$hooks_dir/lib/payload.sh"
  . "$hooks_dir/lib/config.sh"
  guild_config_load
  guild_switch hooks.deny_attribution || return 0
  payload_read
  command_text=$(payload_field command) || return 0
  creates_git_artifact "$command_text" && carries_attribution "$command_text" || return 0
  printf '%s\n' "$BLOCK_MESSAGE" >&2
  exit "$BLOCK_STATUS"
}

(main)
[ "$?" -ne "$BLOCK_STATUS" ] || exit 2
exit 0
