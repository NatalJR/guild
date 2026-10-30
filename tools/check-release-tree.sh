#!/bin/sh
# Guards for the release tree the Claude Directory validates (the shapes its scanner holds or
# blocks on). Prints one `file:line: rule` per violation and exits 1 when there is any.
#
# Usage:
#   sh tools/check-release-tree.sh DIR                    every rule over a built release tree
#   sh tools/check-release-tree.sh --nested-quotes FILE...  only the nested-quote rule (stdin
#                                                          when no FILE), for any sh source
#
# Rules over DIR (shipped .sh unless stated):
# - a typed `<<`
# - a line that loads or runs another file (`. "...`, `source `, `sh "...`)
# - any `case` statement
# - a quote nested inside a double-quoted string (a `"` inside a `${ }` inside `"..."`)
# - a lone quote literal, `'"'` or `"'"`
# - `$PWD` or `${!`
# - .sh, .ps1, .js: an identifier containing key, token, secret, password, cred or auth
#   (any case); whole-line comments are skipped in .ps1 and .js
# - every shipped text file but the .claude-plugin manifests: a URL (`://`), except one
#   repository link in README.md
# - the scripts the PreToolUse entry of hooks/hooks.json runs: the words allow, approve or
#   permissionDecision (any case), and in .sh any printf whose line holds a `%`
# - README.md: a `$` followed by a letter or `{`
# Dependencies: sh, awk, find.
set -u

REPOSITORY_LINK='github.com/NatalJR/guild'

# FILE... (stdin when none): a `"` inside a `${ }` that is itself inside a double-quoted string.
# Quote state resets per line; comment lines and trailing comments are skipped.
nested_quotes() {
  awk '
    BEGIN { squote = "\047"; dquote = "\""; backslash = "\\" }
    /^[ \t]*#/ { next }
    {
      in_single = 0; in_double = 0; depth = 0; previous = " "
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (in_single) { if (c == squote) in_single = 0; previous = c; continue }
        if (c == backslash) { i++; previous = "x"; continue }
        if (in_double) {
          if (c == dquote && depth > 0) { print location() ": nested quote"; break }
          if (c == dquote) in_double = 0
          else if (c == "$" && substr($0, i + 1, 1) == "{") { depth++; i++ }
          else if (c == "}" && depth > 0) depth--
        } else if (c == squote) in_single = 1
        else if (c == dquote) in_double = 1
        else if (c == "#" && (i == 1 || previous == " " || previous == "\t" || previous == ";")) break
        previous = c
      }
    }
    function location() { return (FILENAME == "" ? "-" : FILENAME) ":" FNR }
  ' "$@"
}

# The per-line shell rules over every shipped .sh.
shell_rules() {
  find . -type f -name '*.sh' -exec awk '
    BEGIN {
      q = "\047"; dq = "\""
      loads_dot = "(^|[;&|({ \t])[.][ \t]+[" dq q "$/]"
      runs_sh = "(^|[^A-Za-z0-9_])(sh|bash|dash)[ \t]+[" dq q "$/]"
    }
    function report(rule) { print FILENAME ":" FNR ": " rule }
    { sub(/\r$/, "") }
    FNR == 1 && /^#!/ { next }
    index($0, "<<") { report("typed <<") }
    $0 ~ loads_dot || $0 ~ runs_sh || /(^|[^A-Za-z0-9_])source[ \t]/ { report("loads or runs another file") }
    /(^|[;&|({ \t])case[ \t]+[^ \t].*[ \t]in([ \t;]|$)/ { report("case statement") }
    index($0, q dq q) || index($0, dq q dq) { report("lone quote literal") }
    index($0, "$PWD") || index($0, "${PWD") { report("reads PWD") }
    index($0, "${!") { report("indirect expansion ${!") }
  ' {} +
}

nested_quotes_in_tree() {
  find . -type f -name '*.sh' -exec sh "$SELF" --nested-quotes {} +
}

# .sh, .ps1, .js: identifiers that read as credentials. A word counts as an identifier when it
# holds `_` or a lower-upper case change, follows `$`, `${`, a declaring keyword, or is followed
# by `=` (not `==`) or `(`.
credential_identifiers() {
  find . -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.js' \) -exec awk '
    function is_identifier(word, before, after) {
      if (word ~ /_/ || word ~ /[a-z][A-Z]/) return 1
      if (before ~ /[$]$/ || before ~ /[$][{]$/) return 1
      if (before ~ /(^|[^A-Za-z0-9_])(function|const|let|var|for|read|local|export|param)[ \t]+$/) return 1
      return after ~ /^[ \t]*[(]/ || after ~ /^[ \t]*=([^=~]|$)/
    }
    { sub(/\r$/, "") }
    FILENAME !~ /[.]sh$/ && /^[ \t]*(#|<#|\/\/|\/[*]|[*])/ { next }
    {
      before = ""; rest = $0
      while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
        word = substr(rest, RSTART, RLENGTH)
        before = before substr(rest, 1, RSTART - 1)
        rest = substr(rest, RSTART + RLENGTH)
        if (tolower(word) ~ /key|token|secret|password|cred|auth/ && is_identifier(word, before, rest))
          print FILENAME ":" FNR ": credential-like identifier " word
        before = before word
      }
    }
  ' {} +
}

# Every shipped file but images: `://`, except the first README.md line holding exactly one
# repository link.
# The manifests are exempt: the Claude Directory requires homepage, repository, schema and owner URLs.
urls() {
  find . -type f ! -name '*.png' -exec awk -v link="$REPOSITORY_LINK" '
    function occurrences(text,   count) {
      count = 0
      while ((at = index(text, "://")) > 0) { count++; text = substr(text, at + 3) }
      return count
    }
    function is_plugin_manifest() {
      return FILENAME == "./.claude-plugin/plugin.json" || FILENAME == "./.claude-plugin/marketplace.json"
    }
    is_plugin_manifest() { next }
    !index($0, "://") { next }
    FILENAME == "./README.md" && !link_used && index($0, link) && occurrences($0) == 1 {
      link_used = 1
      next
    }
    { print FILENAME ":" FNR ": URL" }
  ' {} +
}

# Prints the ./hooks/<name>.(sh|ps1) paths the PreToolUse entry of hooks/hooks.json runs.
pre_tool_use_scripts() {
  [ -f hooks/hooks.json ] || return 0
  awk '
    /"[A-Z][A-Za-z]*"[ \t]*:/ { in_entry = ($0 ~ /"PreToolUse"[ \t]*:/) }
    in_entry {
      rest = $0
      while (match(rest, /hooks\/[A-Za-z0-9_-]+[.](sh|ps1)/)) {
        print "./" substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' hooks/hooks.json
}

pre_tool_use_rules() {
  pre_tool_use_scripts | while IFS= read -r script_path; do
    [ -f "$script_path" ] || continue
    awk '
      function report(rule) { print FILENAME ":" FNR ": " rule }
      tolower($0) ~ /allow|approve|permissiondecision/ { report("PreToolUse decision word") }
      FILENAME ~ /[.]sh$/ && /(^|[^A-Za-z0-9_])printf([^A-Za-z0-9_]|$)/ && index($0, "%") {
        report("PreToolUse printf with %")
      }
    ' "$script_path"
  done
}

readme_variables() {
  [ -f README.md ] || return 0
  awk '/[$][A-Za-z{]/ { print FILENAME ":" FNR ": README variable" }' ./README.md
}

check_tree() {
  [ -d "$1" ] || { printf 'check-release-tree: not a directory: %s\n' "$1" >&2; return 2; }
  cd "$1" || return 2
  violations=$(
    shell_rules
    nested_quotes_in_tree
    credential_identifiers
    urls
    pre_tool_use_rules
    readme_variables
  )
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  return 1
}

usage() {
  printf 'usage: sh tools/check-release-tree.sh DIR | --nested-quotes [FILE...]\n' >&2
  exit 2
}

SELF_DIR=${0%/*}
[ "$SELF_DIR" != "$0" ] || SELF_DIR=.
SELF="$(CDPATH='' cd -- "$SELF_DIR" && pwd)/${0##*/}" || exit 2

[ "$#" -ge 1 ] || usage
if [ "$1" = --nested-quotes ]; then
  shift
  found=$(nested_quotes "$@")
  [ -z "$found" ] && exit 0
  printf '%s\n' "$found"
  exit 1
fi
[ "$#" -eq 1 ] || usage
check_tree "$1"
