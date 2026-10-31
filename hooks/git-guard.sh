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
# Switch: git.handling, set by the plugin option CLAUDE_PLUGIN_OPTION_GIT_HANDLING only (true,
# 1, on or yes in any case is on; any other value or unset is off). A malformed payload or an
# internal error never blocks.
# Self-contained on purpose: it loads no library, so the release build inlines nothing into it.
set -u

# Violation statuses of GUARD_PROGRAM; any other status, an awk error included, is no violation.
ATTRIBUTION_FOUND=10
NO_VERIFY_FOUND=11
FORCE_PUSH_FOUND=12
# Internal status meaning "block"; any other status, including a shell error, lets the call run.
BLOCK_STATUS=3

# Reads the hook payload on stdin and exits with the status of the first rule its command breaks
# (10, 11, 12), else 0. The value of the first "command":"..." on a line is decoded: escaped
# backslash, quote, slash, newline and tab are restored, an escaped carriage return is dropped and
# a unicode escape stays as text; with no closing quote on that line the command is absent.
# Matching follows `LC_ALL=C grep -i -E`: the command is ASCII-lowercased and the patterns are
# written in lowercase. Newlines fold to spaces for the attribution check, which reads the whole
# command, so an artifact command split across lines still counts. They become `;` for the flag
# checks, so a newline ends a command segment like any other separator.
# tab: the string holds one literal tab character.
# segment, boundary: the rest of a git subcommand up to the next shell operator, then the end of
# a standalone token.
# attribution: the attribution address needs no alternative of its own: anthropic already
# matches it.
# no_verify: git push -n is --dry-run, not a hook bypass, so -n counts on git commit only.
# backslash_in: the backslash in TEXT, else empty: the validator cannot inspect a hook whose text
# holds backslash escapes.
# single_quote_in: the single quote in TEXT, else empty: the validator cannot inspect a hook whose
# text holds backslash escapes.
# decoded_value: the decoded value that TEXT opens, empty when it has no closing quote. Escaped
# backslashes and then escaped quotes are parked on characters a JSON line cannot hold, so the
# first quote left closes the value.
# double_quoted_span: a double-quoted span (a backslash escapes the next character, an escaped
# quote included).
# unquoted_words: COMMAND without its quoted spans, so a flag named inside a commit message is not
# taken for a flag.
GUARD_PROGRAM='
BEGIN {
  newline = RS
  tab = "	"
  blanks = "[[:space:]]+"
  segment = "([[:space:]][^;&|]*)?[[:space:]]"
  boundary = "([[:space:];&|)]|$)"
  git_artifact = "git" blanks "commit|gh" blanks "pr" blanks "(create|edit)"
  attribution = "co-authored-by|generated with|claude code|anthropic"
  no_verify = "git" blanks "commit" segment "(--no-verify|-n)" boundary "|git" blanks "push" segment "--no-verify" boundary
  force_push = "git" blanks "push" segment "(--force|-f)" boundary
}

function backslash_in(text) {
  gsub(/[][Z^]/, "", text)
  return match(text, /[Z-^]/) ? substr(text, RSTART, 1) : ""
}

function single_quote_in(text) {
  gsub(/[&(]/, "", text)
  return match(text, /[&-(]/) ? substr(text, RSTART, 1) : ""
}

function decoded_value(text,   end) {
  if (backslash != "") text = parked(text)
  end = index(text, quote)
  if (end == 0) return ""
  text = substr(text, 1, end - 1)
  return backslash == "" ? text : unescaped(text)
}

function parked(text,   escape) {
  escape = backslash backslash
  gsub(escape escape, SUBSEP, text)
  gsub(escape quote, newline, text)
  return text
}

function unescaped(text,   escape) {
  escape = backslash backslash
  gsub(newline, quote, text)
  gsub(escape "/", "/", text)
  gsub(escape "n", newline, text)
  gsub(escape "t", tab, text)
  gsub(escape "r", "", text)
  gsub(SUBSEP, backslash, text)
  return text
}

function double_quoted_span(   escape, plain) {
  if (backslash == "") return quote "[^" quote "]*" quote
  escape = backslash backslash
  plain = "[^" quote escape "]*"
  return quote plain "(" escape "." plain ")*" quote
}

function unquoted_words(command,   words, single_quote) {
  words = command ";"
  gsub(newline, ";", words)
  gsub(double_quoted_span(), "", words)
  single_quote = single_quote_in(command)
  if (single_quote != "") gsub(single_quote "[^" single_quote "]*" single_quote, "", words)
  return tolower(words)
}

function violation_status(command,   folded, words) {
  folded = command " "
  gsub(newline, " ", folded)
  folded = tolower(folded)
  words = unquoted_words(command)
  if (folded ~ git_artifact && folded ~ attribution) return 10
  if (words ~ no_verify) return 11
  if (words ~ force_push) return 12
  return 0
}

match($0, /"command"[[:space:]]*:[[:space:]]*"/) {
  quote = substr($0, RSTART + RLENGTH - 1, 1)
  opened = substr($0, RSTART + RLENGTH)
  backslash = backslash_in($0)
  command = decoded_value(opened)
  if (command == "") exit 0
  exit violation_status(command)
}'

# Like its PowerShell twin, the hook does nothing unless the harness names a plugin root whose hooks
# directory exists.
plugin_root_present() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ]
}

# Succeeds when the git handling plugin option is set to 1, true, on or yes in any case.
git_handling_on() {
  option=${CLAUDE_PLUGIN_OPTION_GIT_HANDLING:-}
  [ -n "$option" ] || return 1
  [ "$option" = 1 ] || [ -z "${option#[Oo][Nn]}" ] || [ -z "${option#[Tt][Rr][Uu][Ee]}" ] || [ -z "${option#[Yy][Ee][Ss]}" ]
}

# STATUS: prints the block message of a violation status to stderr; returns 1 for any other.
report_violation() {
  if [ "$1" -eq "$ATTRIBUTION_FOUND" ]; then
    echo 'BLOCKED: AI attribution in a git artifact is forbidden. Remove the trailer/footer and retry.' >&2
  elif [ "$1" -eq "$NO_VERIFY_FOUND" ]; then
    echo 'BLOCKED: hook bypass with --no-verify is forbidden. Fix the failing hook instead.' >&2
  elif [ "$1" -eq "$FORCE_PUSH_FOUND" ]; then
    echo 'BLOCKED: forced push is forbidden. Use --force-with-lease only inside the PR update sequence.' >&2
  else
    return 1
  fi
}

main() {
  plugin_root_present || return 0
  git_handling_on || return 0
  LC_ALL=C awk "$GUARD_PROGRAM"
  report_violation "$?" || return 0
  exit "$BLOCK_STATUS"
}

(main)
[ "$?" -ne "$BLOCK_STATUS" ] || exit 2
exit 0
