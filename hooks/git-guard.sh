#!/bin/sh
# PreToolUse hook (Bash|PowerShell): the guild git guard. Denies, in the command text, AI
# attribution in a git commit or a PR create/edit, a hook bypass (--no-verify; -n on git
# commit) and a forced push (--force or -f; --force-with-lease and --force-if-includes stay
# allowed). The whole command string is evaluated, compound commands included.
# Text-level guardrail only: it inspects the command string, so attribution supplied through
# files (commit -F, --body-file), templates, or environment variables is not detected. The flag
# checks see standalone tokens of a git commit / git push segment (ended by ;, &, | or a newline)
# with quoted spans removed, so a flag written inside quotes, a bundled short flag (-nm), a
# refspec force push (+branch) or git options before the subcommand (git -C dir push) are not
# detected either.
# Switch: git.handling, set by the plugin option only (off by default). A
# malformed payload or an internal error never blocks.
set -u

GIT_ARTIFACT_PATTERN='git[[:space:]]+commit|gh[[:space:]]+pr[[:space:]]+(create|edit)'
ATTRIBUTION_PATTERN='Co-Authored-By|Generated with|Claude Code|Anthropic|noreply@anthropic\.com'
# The rest of a git subcommand up to the next shell operator, then the end of a standalone token.
SEGMENT='([[:space:]][^;&|]*)?[[:space:]]'
FLAG_BOUNDARY='([[:space:];&|)]|$)'
# git push -n is --dry-run, not a hook bypass, so -n counts on git commit only.
NO_VERIFY_PATTERN="git[[:space:]]+commit$SEGMENT(--no-verify|-n)$FLAG_BOUNDARY|git[[:space:]]+push$SEGMENT--no-verify$FLAG_BOUNDARY"
FORCE_PUSH_PATTERN="git[[:space:]]+push$SEGMENT(--force|-f)$FLAG_BOUNDARY"
ATTRIBUTION_MESSAGE='BLOCKED: AI attribution in a git artifact is forbidden. Remove the trailer/footer and retry.'
NO_VERIFY_MESSAGE='BLOCKED: hook bypass (--no-verify) is forbidden. Fix the failing hook instead.'
FORCE_PUSH_MESSAGE='BLOCKED: forced push is forbidden. Use --force-with-lease only inside the PR update sequence.'
# Internal status meaning "block"; any other status, including a shell error, allows.
BLOCK_STATUS=3

# Succeeds when CLAUDE_PLUGIN_ROOT is set and holds the libraries this hook sources; the
# harness always exports it for plugin hooks.
libraries_present() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/payload.sh" ] &&
    [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh" ]
}

# TEXT PATTERN: case-insensitive ERE match anywhere in TEXT.
matches() {
  printf '%s\n' "$1" | LC_ALL=C grep -q -i -E -e "$2"
}

# Newlines are folded to spaces for the attribution check, which reads the whole command, so an
# artifact command split across lines still counts.
folded() {
  printf '%s\n' "$1" | tr '\n' ' '
}

# Newlines become `;` for the flag checks, so a newline ends a command segment like any other
# separator and the next line's flags are never read as the previous command's.
segmented() {
  printf '%s\n' "$1" | tr '\n' ';'
}

# Drops double-quoted spans (a backslash escapes the next character, \" included) and
# single-quoted spans, so a flag named inside a commit message is not taken for a flag.
unquoted() {
  printf '%s\n' "$1" | sed -e 's/"[^"\]*\(\\.[^"\]*\)*"//g' -e "s/'[^']*'//g"
}

# Prints the block message for the first rule COMMAND breaks; prints nothing otherwise.
violation_of() {
  command_folded=$(folded "$1")
  command_words=$(unquoted "$(segmented "$1")")
  if matches "$command_folded" "$GIT_ARTIFACT_PATTERN" && matches "$command_folded" "$ATTRIBUTION_PATTERN"; then
    printf '%s\n' "$ATTRIBUTION_MESSAGE"
  elif matches "$command_words" "$NO_VERIFY_PATTERN"; then
    printf '%s\n' "$NO_VERIFY_MESSAGE"
  elif matches "$command_words" "$FORCE_PUSH_PATTERN"; then
    printf '%s\n' "$FORCE_PUSH_MESSAGE"
  fi
}

main() {
  libraries_present || return 0
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/payload.sh"
  . "${CLAUDE_PLUGIN_ROOT}/hooks/lib/config.sh"
  guild_config_load
  guild_switch git.handling || return 0
  payload_read
  command_text=$(payload_field command) || return 0
  block_message=$(violation_of "$command_text")
  [ -n "$block_message" ] || return 0
  printf '%s\n' "$block_message" >&2
  exit "$BLOCK_STATUS"
}

(main)
[ "$?" -ne "$BLOCK_STATUS" ] || exit 2
exit 0
