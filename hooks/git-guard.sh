#!/bin/sh
# PreToolUse hook (Bash|PowerShell): the guild git guard. Denies, in the command text, AI
# attribution in a git commit or a PR create/edit, a hook bypass (--no-verify; -n on git
# commit) and a forced push (--force or -f; --force-with-lease and --force-if-includes are not
# blocked). The whole command string is evaluated, compound commands included.
# Text-level guardrail only: it inspects the command string, so attribution supplied through
# files (commit -F, --body-file), templates, or environment variables is not detected. The flag
# checks see standalone tokens of a git commit / git push segment (ended by ;, &, | or a newline)
# with quoted spans removed, so a flag written inside quotes, a bundled short flag (-nm), a
# refspec force push (+branch) or git options before the subcommand (git -C dir push) are not
# detected either.
# Writes nothing to stdout: a block message goes to stderr with exit 2.
# Switch: git.handling, set by the plugin option only (off by default). A
# malformed payload or an internal error never blocks.
set -u

# Matching follows `LC_ALL=C grep -i -E`: the command is ASCII-lowercased and the patterns are
# written in lowercase. The attribution e-mail address needs no alternative of its own:
# `anthropic` already matches it.
GIT_ARTIFACT_PATTERN='git[[:space:]]+commit|gh[[:space:]]+pr[[:space:]]+(create|edit)'
ATTRIBUTION_PATTERN='co-authored-by|generated with|claude code|anthropic'
# The rest of a git subcommand up to the next shell operator, then the end of a standalone token.
SEGMENT='([[:space:]][^;&|]*)?[[:space:]]'
FLAG_BOUNDARY='([[:space:];&|)]|$)'
# git push -n is --dry-run, not a hook bypass, so -n counts on git commit only.
NO_VERIFY_PATTERN="git[[:space:]]+commit$SEGMENT(--no-verify|-n)$FLAG_BOUNDARY|git[[:space:]]+push$SEGMENT--no-verify$FLAG_BOUNDARY"
FORCE_PUSH_PATTERN="git[[:space:]]+push$SEGMENT(--force|-f)$FLAG_BOUNDARY"
# The Claude Directory validator cannot read quote or backslash literals in an awk program, so
# the quoted-span patterns are built here from character codes and reach awk as arguments.
DOUBLE_QUOTE=$(printf '\042')
SINGLE_QUOTE=$(printf '\047')
BACKSLASH=$(printf '\134')
NEWLINE='
'
# A double-quoted span (a backslash escapes the next character, an escaped quote included) and a
# single-quoted span, so a flag named inside a commit message is not taken for a flag.
NOT_QUOTE_OR_BACKSLASH="[^$DOUBLE_QUOTE$BACKSLASH$BACKSLASH]*"
DOUBLE_QUOTED_SPAN="$DOUBLE_QUOTE$NOT_QUOTE_OR_BACKSLASH($BACKSLASH$BACKSLASH.$NOT_QUOTE_OR_BACKSLASH)*$DOUBLE_QUOTE"
SINGLE_QUOTED_SPAN="$SINGLE_QUOTE[^$SINGLE_QUOTE]*$SINGLE_QUOTE"
# Violation statuses of VIOLATION_CHECK; any other status, an awk error included, is no violation.
ATTRIBUTION_FOUND=10
NO_VERIFY_FOUND=11
FORCE_PUSH_FOUND=12
# Internal status meaning "block"; any other status, including a shell error, lets the call run.
BLOCK_STATUS=3

# ARGV: the command, a newline, the double- and single-quoted span patterns, then the artifact,
# attribution, no-verify and force-push patterns. Newlines fold to spaces for the attribution
# check, which reads the whole command, so an artifact command split across lines still counts.
# They become `;` for the flag checks, so a newline ends a command segment like any other
# separator. Exits with the status of the first rule broken (10, 11, 12), else 0.
VIOLATION_CHECK='
BEGIN {
  folded = ARGV[1] " "
  gsub(ARGV[2], " ", folded)
  words = ARGV[1] ";"
  gsub(ARGV[2], ";", words)
  gsub(ARGV[3], "", words)
  gsub(ARGV[4], "", words)
  folded = tolower(folded)
  words = tolower(words)
  if (folded ~ ARGV[5] && folded ~ ARGV[6]) exit 10
  if (words ~ ARGV[7]) exit 11
  if (words ~ ARGV[8]) exit 12
  exit 0
}'

# Loads the shared libraries from CLAUDE_PLUGIN_ROOT, which the harness always exports for
# plugin hooks; returns 1 when it is unset or a library is missing.
load_libraries() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 1
  [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/payload.sh" ] || return 1
  [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh" ] || return 1
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/payload.sh"
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh"
}

# COMMAND: returns the violation status of the first rule COMMAND breaks, 0 when none.
violation_status() {
  LC_ALL=C awk "$VIOLATION_CHECK" "$1" "$NEWLINE" "$DOUBLE_QUOTED_SPAN" "$SINGLE_QUOTED_SPAN" \
    "$GIT_ARTIFACT_PATTERN" "$ATTRIBUTION_PATTERN" "$NO_VERIFY_PATTERN" "$FORCE_PUSH_PATTERN"
}

# STATUS: prints the block message of a violation status to stderr; returns 1 for any other.
report_violation() {
  if [ "$1" -eq "$ATTRIBUTION_FOUND" ]; then
    printf 'BLOCKED: AI attribution in a git artifact is forbidden. Remove the trailer/footer and retry.\n' >&2
  elif [ "$1" -eq "$NO_VERIFY_FOUND" ]; then
    printf 'BLOCKED: hook bypass (--no-verify) is forbidden. Fix the failing hook instead.\n' >&2
  elif [ "$1" -eq "$FORCE_PUSH_FOUND" ]; then
    printf 'BLOCKED: forced push is forbidden. Use --force-with-lease only inside the PR update sequence.\n' >&2
  else
    return 1
  fi
}

main() {
  load_libraries || return 0
  guild_config_load
  guild_switch git.handling || return 0
  payload_read
  command_text=$(payload_field command) || return 0
  violation_status "$command_text"
  report_violation "$?" || return 0
  exit "$BLOCK_STATUS"
}

(main)
[ "$?" -ne "$BLOCK_STATUS" ] || exit 2
exit 0
