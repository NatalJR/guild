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
# - a parameter expansion nested inside another (a `${` opened before the enclosing expansion
#   closes with its `}`), quoted or not; `$(...)` inside an expansion is not tracked
# - a lone quote literal, `'"'` or `"'"`
# - `$PWD` or `${!`
# - an assignment whose whole value is `.`, bare or quoted (`NAME=.`, `NAME="."`, `NAME='.'`),
#   or a default expansion whose default is `.` (`${NAME:-.}`, `${NAME-.}`)
# - `$CLAUDE_PLUGIN_ROOT` or `${CLAUDE_PLUGIN_ROOT}`, quoted or not, not immediately followed by
#   `/`; the forms `${CLAUDE_PLUGIN_ROOT:-...}`, `${CLAUDE_PLUGIN_ROOT-...}`,
#   `${CLAUDE_PLUGIN_ROOT+...}` and `${CLAUDE_PLUGIN_ROOT:+...}` stay allowed
# - .ps1 (any case): a dot-source (a lone `.` at the line start or after `{`, `;`, `(`, `|` or
#   `=`, then optional blanks and `(`, `$`, a quote, a slash, a backslash or `~`, or blanks and a
#   path character), Import-Module, the call operator `&` followed by `(`, `$` or a quote,
#   Invoke-Expression, or `iex` as a command word (see below), [scriptblock]::Create under any
#   namespace prefix, Invoke-Command
# - .sh, .ps1: `GetEnvironmentVariable(` not followed (after optional blanks) by a single quote,
#   or `GetEnvironmentVariables(` (any case)
# - .ps1 (any case): an Env: provider read through Get-ChildItem, Get-Item, Get-Content, gci, gi,
#   dir, ls or gc (an `env:` not preceded by `$`), and an `env:` path built by concatenation
#   (`'env:' +`, `"env:$`); `$env:NAME` stays allowed
# - .sh: `env`, `printenv` or `eval` as a command word (line start, after `;`, `|`, `&`, `(`,
#   a backtick, `{` or `!`, or after the word then, do, else, if, elif, while, until or exec)
# - hooks/*.sh, hooks/*.ps1: the text `defaults.conf` or `hooks/lib/`
# - .sh, .ps1, .js: an identifier containing key, token, secret, password, cred or auth
#   (any case); whole-line comments are skipped in .ps1 and .js
# - every shipped text file but the .claude-plugin manifests: a URL (`://`), except one
#   repository link in README.md
# - the scripts the PreToolUse entry of hooks/hooks.json runs: the words allow, approve or
#   permissionDecision (any case); in .sh any printf whose line holds a `%` and any backslash
#   outside an awk regex literal; in .ps1 any backslash, backtick or `%`, the `-f` operator as a
#   standalone token, and the stdout writers Write-Output, Write-Host, Write-Information,
#   Write-Warning, Tee-Object, echo, `write` and `tee` as command words, Out-Host, Out-Default,
#   [Console]::Out and [Console]::Write* under any namespace prefix of Console, $Host.UI.Write*
#   and OpenStandardOutput (any case). A .ps1 command word starts a statement or pipeline element
#   (line start, or after `;`, `|`, `{`, `(` or `=`, then optional blanks) and is followed by a
#   blank, `(` or the line end, so a `.Write(` member call does not match. Known limit: uncaptured
#   expression output (a bare value, or a call whose result is neither assigned nor discarded)
#   also reaches stdout and cannot be detected by pattern; the hook's tests measuring 0 stdout
#   bytes cover it.
# - README.md: a `$` followed by a letter or `{`
# A line reports each rule at most once.
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
      bare_dot = "(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=([.]|" dq "[.]" dq "|" q "[.]" q ")([ \t;)&|]|$)"
      dot_default = "[$][{][A-Za-z_][A-Za-z0-9_]*:?-[.][}]"
      bare_plugin_root = "[$](CLAUDE_PLUGIN_ROOT([^A-Za-z0-9_/]|$)|[{]CLAUDE_PLUGIN_ROOT[}]([^/]|$))"
    }
    function report(rule) { print FILENAME ":" FNR ": " rule }
    # LINE: a `${` opened while an earlier expansion on the line is still open; a `}` closes the
    # innermost open expansion, and braces without a `$` before them never open one.
    function nests_expansion(line,   i, c, depth) {
      depth = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "$" && substr(line, i + 1, 1) == "{") { if (depth > 0) return 1; depth++; i++ }
        else if (c == "}" && depth > 0) depth--
      }
      return 0
    }
    { sub(/\r$/, "") }
    FNR == 1 && /^#!/ { next }
    index($0, "<<") { report("typed <<") }
    $0 ~ loads_dot || $0 ~ runs_sh || /(^|[^A-Za-z0-9_])source[ \t]/ { report("loads or runs another file") }
    /(^|[;&|({ \t])case[ \t]+[^ \t].*[ \t]in([ \t;]|$)/ { report("case statement") }
    index($0, q dq q) || index($0, dq q dq) { report("lone quote literal") }
    index($0, "$PWD") || index($0, "${PWD") { report("reads PWD") }
    index($0, "${!") { report("indirect expansion ${!") }
    $0 ~ bare_dot || $0 ~ dot_default { report("bare dot value") }
    $0 ~ bare_plugin_root { report("bare plugin root") }
    nests_expansion($0) { report("nested parameter expansion") }
  ' {} +
}

nested_quotes_in_tree() {
  find . -type f -name '*.sh' -exec sh "$SELF" --nested-quotes {} +
}

# .ps1: a line that loads another file or runs code built at run time. A dot-source is a lone `.`
# at a statement or pipeline element start; member access (`$a.b`) never puts one there, and a
# decimal (`.5`) has a digit right after the dot, so neither matches. `&&` is not a call operator.
powershell_loads() {
  find . -type f -name '*.ps1' -exec awk '
    function report(rule) { print FILENAME ":" FNR ": " rule }
    { sub(/\r$/, ""); line = tolower($0) }
    line ~ /(^|[{;(|=])[ \t]*[.]([ \t]*[($"\047\\\/~]|[ \t]+[a-z0-9_.])/ { report("dot-source") }
    index(line, "import-module") { report("Import-Module") }
    line ~ /(^|[^&])&[ \t]*[($"\047]/ { report("call operator") }
    line ~ /(^|[^a-z0-9_-])invoke-expression([^a-z0-9_-]|$)/ { report("Invoke-Expression") }
    line ~ /(^|[{;(|=])[ \t]*iex([ \t(]|$)/ { report("Invoke-Expression") }
    line ~ /\[[ \t]*([a-z0-9_]+[.])*scriptblock[ \t]*\][ \t]*::[ \t]*create/ { report("[scriptblock]::Create") }
    line ~ /(^|[^a-z0-9_-])invoke-command([^a-z0-9_-]|$)/ { report("Invoke-Command") }
  ' {} +
}

# .sh, .ps1: an environment read whose name is not a single-quoted literal, or a read of the
# whole environment. `$env:NAME` in .ps1 is a literal read; an `env:` the provider cmdlets or a
# concatenation reach is not.
environment_reads() {
  find . -type f \( -name '*.sh' -o -name '*.ps1' \) -exec awk '
    BEGIN {
      q = "\047"; single_read = "getenvironmentvariable("
      command_start = "(^|[;|&(`{!]|(^|[^A-Za-z0-9_])(then|do|else|if|elif|while|until|exec)[ \t])"
      sh_environment_command = command_start "[ \t]*(env|printenv|eval)([ \t;|&)`]|$)"
    }
    function report(rule) { print FILENAME ":" FNR ": " rule }
    { sub(/\r$/, ""); line = tolower($0) }
    { dotnet_reads(line) }
    FILENAME ~ /[.]ps1$/ { provider_reads(line) }
    FILENAME ~ /[.]sh$/ && $0 ~ sh_environment_command { report("environment command") }
    # LINE (lowercased): .NET reads, the single-name one checked for a single-quoted literal.
    function dotnet_reads(line,   rest, at, name) {
      rest = line
      if (index(rest, "getenvironmentvariables(")) report("whole-environment read")
      while ((at = index(rest, single_read)) > 0) {
        rest = substr(rest, at + length(single_read))
        name = rest
        sub(/^[ \t]*/, "", name)
        if (substr(name, 1, 1) != q) { report("environment read without a literal name"); break }
      }
    }
    # LINE (lowercased): Env: provider reads through a cmdlet, and env: paths built at run time.
    function provider_reads(line) {
      if (line ~ /(^|[^a-z0-9_$-])(get-childitem|get-item|get-content|gci|gi|dir|ls|gc)[ \t(](.*[^a-z0-9_$])?env:/)
        report("Env: provider read")
      if (line ~ /[\047"]env:[\047"][ \t]*[+]/ || index(line, "\"env:$")) report("built Env: path")
    }
  ' {} +
}

# hooks/*.sh, hooks/*.ps1: a name of the defaults file or of the library directory, both of which
# the build compiles away.
hook_references() {
  [ -d hooks ] || return 0
  find ./hooks -type f \( -name '*.sh' -o -name '*.ps1' \) -exec awk '
    FILENAME !~ /^[.]\/hooks\/[^\/]+$/ { next }
    index($0, "defaults.conf") { print FILENAME ":" FNR ": names defaults.conf" }
    index($0, "hooks/lib/") { print FILENAME ":" FNR ": names hooks/lib/" }
  ' {} +
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
      FILENAME ~ /[.]sh$/ && index(outside_regex_literals($0), "\\") { report("PreToolUse backslash") }
      FILENAME ~ /[.]ps1$/ { powershell_rules(tolower($0)) }
      # LINE (lowercased): the characters and calls a .ps1 PreToolUse script must not hold.
      function powershell_rules(line) {
        if (index(line, "\\")) report("PreToolUse backslash")
        if (index(line, "`")) report("PreToolUse backtick")
        if (index(line, "%")) report("PreToolUse %")
        if (line ~ /(^|[ \t])-f([ \t]|$)/) report("PreToolUse -f operator")
        if (writes_stdout(line)) report("PreToolUse stdout writer")
      }
      # LINE (lowercased): a named stdout writer. Uncaptured expression output also reaches
      # stdout but has no name to match; the hook tests measuring 0 stdout bytes cover it.
      function writes_stdout(line) {
        if (line ~ /write-(output|host|information|warning)|tee-object|out-(host|default)/) return 1
        if (index(line, "openstandardoutput")) return 1
        if (line ~ /(^|[;|{(=])[ \t]*(write|tee)([ \t(]|$)/) return 1
        if (line ~ /(^|[^a-z0-9_$-])echo([^a-z0-9_-]|$)/) return 1
        if (line ~ /\[[ \t]*([a-z0-9_]+[.])*console[ \t]*\][ \t]*::[ \t]*(out([^a-z]|$)|write)/) return 1
        return line ~ /[$]host[ \t]*[.][ \t]*ui[ \t]*[.][ \t]*write/
      }
      # TEXT without its awk regex literals: a / after the line start, a blank, a single quote or
      # one of ( , ~ ! { & |, up to the next unescaped /.
      function outside_regex_literals(text) {
        gsub(/(^|[ \t\047(,~!{&|])\/([^\/\\]|\\.)*\//, " ", text)
        return text
      }
    ' "$script_path"
  done
}

readme_variables() {
  [ -f README.md ] || return 0
  awk '/[$][A-Za-z{]/ { print FILENAME ":" FNR ": README variable" }' ./README.md
}

all_rules() {
  shell_rules
  nested_quotes_in_tree
  powershell_loads
  environment_reads
  hook_references
  credential_identifiers
  urls
  pre_tool_use_rules
  readme_variables
}

# DIR: every rule over DIR, each `file:line: rule` printed once.
check_tree() {
  [ -d "$1" ] || { printf 'check-release-tree: not a directory: %s\n' "$1" >&2; return 2; }
  cd "$1" || return 2
  violations=$(all_rules | awk '!reported[$0]++')
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
