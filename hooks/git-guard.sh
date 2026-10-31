#!/bin/sh
set -u

ATTRIBUTION_FOUND=10
NO_VERIFY_FOUND=11
FORCE_PUSH_FOUND=12
BLOCK_STATUS=3

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

plugin_root_present() {
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ]
}

git_handling_on() {
  option=${CLAUDE_PLUGIN_OPTION_GIT_HANDLING:-}
  [ -n "$option" ] || return 1
  [ "$option" = 1 ] || [ -z "${option#[Oo][Nn]}" ] || [ -z "${option#[Tt][Rr][Uu][Ee]}" ] || [ -z "${option#[Yy][Ee][Ss]}" ]
}

report_violation() {
  if [ "$1" -eq "$ATTRIBUTION_FOUND" ]; then
    echo 'BLOCKED: AI attribution in a git artifact is forbidden. Remove the trailer/footer and retry.' >&2
  elif [ "$1" -eq "$NO_VERIFY_FOUND" ]; then
    echo 'BLOCKED: hook bypass (--no-verify) is forbidden. Fix the failing hook instead.' >&2
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
