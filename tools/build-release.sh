#!/bin/sh
# Builds the slim tree the Claude Directory tracks (the `release` branch) from the working tree.
# Usage: sh tools/build-release.sh OUTDIR   (OUTDIR must be absent or an empty directory)
#
# Copies only the shipped files, swaps README.release.md in as README.md, and compiles every hook
# into one self-contained file; hooks/lib/ is not shipped.
# - each .sh hook hooks/hooks.json names: line 1 (the shebang) kept, whole-line comments dropped,
#   each `. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/<lib>.sh"` line replaced by that library minus its
#   shebang and whole-line comments, every other line mentioning hooks/lib/ deleted.
# - each .ps1 hook hooks/hooks.json names (the second line of each command): each
#   `. ($<root> + '/hooks/lib/<lib>.ps1')` line replaced by that library minus its whole-line
#   comments and blank lines, every other line kept.
# - comments and blank lines are dropped only outside quoted strings: the inliner tracks the quote
#   state across lines and copies a line that starts inside a string, or continues a line ending
#   in an escape, verbatim. sh: '...' literal, "..." with backslash escapes, a backslash outside
#   quotes escapes the next character, # starts a comment at the start of a word. ps1: '...' with
#   '' as a quote, "..." with backtick escapes, # outside quotes starts a comment. A ps1 library
#   line opening a here-string (`@'` or `@"` at the end of the line) or a `<#` block comment fails
#   the build with its file:line: the inliner cannot carry either.
# - inside an inlined library, the line naming /config/defaults.conf (exactly one in each config
#   library) becomes one generated line per entry of config/defaults.conf, applied as declared
#   defaults; an entry with a character outside [A-Za-z0-9_. =] and tab fails the build.
# A compiled hook that still mentions hooks/lib/ or defaults.conf, names a missing library or does
# not parse (sh -n; for .ps1 the PowerShell parser of every PowerShell found) fails the build
# (exit 1; the tree is left for inspection).
# The .ps1 parse check runs powershell.exe (Windows PowerShell 5.1, the syntax floor the hooks
# target) when it is on PATH and pwsh (PowerShell 7) when it is on PATH; at least one is required.
# With pwsh alone, 7-only syntax passes the build: a warning on stderr says so.
# Dependencies: sh, sed, awk, cp, mkdir, find, and powershell.exe or pwsh for the .ps1 parse check.
set -u

LIBRARY_DIR=hooks/lib
DEFAULTS_FILE=config/defaults.conf
EXCLUDED_SCRIPT=check-context-size.sh
BUILD_FAILED=no

# Prints every parse error of the .ps1 files in the current directory as `file:line: message` on
# stderr; exits 1 when there is any.
POWERSHELL_PARSE_CHECK='$failed = $false
foreach ($file in Get-ChildItem -LiteralPath . -Filter *.ps1) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
  foreach ($parseError in $errors) {
    [Console]::Error.WriteLine($file.Name + [string][char]58 + $parseError.Extent.StartLineNumber + [string][char]58 + [string][char]32 + $parseError.Message)
    $failed = $true
  }
}
if ($failed) { exit 1 }
exit 0'

fail() {
  printf 'build-release: %s\n' "$1" >&2
  exit 1
}

report_failure() {
  printf 'build-release: %s\n' "$1" >&2
  BUILD_FAILED=yes
}

script_directory() {
  script_dir=${0%/*}
  [ "$script_dir" != "$0" ] || script_dir=.
  printf '%s' "$script_dir"
}

# DIR: succeeds when DIR has no entry, hidden ones included.
directory_is_empty() {
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      return 1
    fi
  done
  return 0
}

prepare_output() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    [ -d "$1" ] && directory_is_empty "$1" || fail "$1 exists and is not an empty directory"
  fi
  mkdir -p "$1" || fail "cannot create $1"
  OUT=$(CDPATH='' cd -- "$1" && pwd) || fail "cannot enter $1"
}

# PATH: copies one repository file to the same relative path under OUT.
copy_file() {
  [ -f "$1" ] || fail "missing shipped file $1"
  target_dir=${1%/*}
  [ "$target_dir" = "$1" ] || mkdir -p "$OUT/$target_dir" || fail "cannot create $OUT/$target_dir"
  cp "$1" "$OUT/$1" || fail "cannot copy $1"
}

copy_directory() {
  [ -d "$1" ] || fail "missing shipped directory $1"
  cp -R "$1" "$OUT/$1" || fail "cannot copy $1"
}

copy_shipped_files() {
  copy_file .claude-plugin/plugin.json
  copy_file .claude-plugin/marketplace.json
  copy_file .claude-plugin/icon.png
  copy_file LICENSE
  # Without it a Windows clone checks the hooks out with CRLF line endings and sh fails on them.
  copy_file .gitattributes
  for shipped_dir in agents skills context config workflows; do
    copy_directory "$shipped_dir"
  done
  copy_file charter/TEMPLATE.md
  copy_file charter/SCHEMA.md
  copy_file hooks/hooks.json
  [ -f README.release.md ] || fail 'missing README.release.md'
  cp README.release.md "$OUT/README.md" || fail 'cannot copy README.release.md'
}

# LANGUAGE: prints each distinct hooks/<name>.LANGUAGE that hooks/hooks.json names, one name per
# line.
hook_scripts() {
  awk -v excluded="$EXCLUDED_SCRIPT" -v language="$1" '
    BEGIN { script_path = "hooks/[A-Za-z0-9_-]+[.]" language }
    {
      rest = $0
      while (match(rest, script_path)) {
        name = substr(rest, RSTART + 6, RLENGTH - 6)
        rest = substr(rest, RSTART + RLENGTH)
        if (name != excluded && !(name in seen)) { seen[name] = 1; print name }
      }
    }
  ' hooks/hooks.json
}

# SOURCE LANGUAGE: prints SOURCE, a hook written in LANGUAGE (sh or ps1), compiled; exits 1 with
# a message on stderr when a library is missing or the defaults cannot be compiled in.
compile_source() {
  awk -v library_dir="$LIBRARY_DIR" -v defaults_path="$DEFAULTS_FILE" -v language="$2" '
    function is_comment(text) { return text ~ /^[ \t]*#/ }
    function is_blank(text) { return text ~ /^[ \t]*$/ }
    function complain(message) { print message | "cat 1>&2"; failed = 1 }
    # Fills defaults[1..defaults_count] with the entries of the defaults file.
    function load_defaults(   text, status, line_number) {
      defaults_loaded = 1
      while ((status = (getline text < defaults_path)) > 0) {
        line_number++
        sub(/\r$/, "", text)
        if (is_blank(text) || is_comment(text)) continue
        if (text ~ /[^A-Za-z0-9_. \t=]/) complain(defaults_path ":" line_number ": character outside [A-Za-z0-9_. =] and tab")
        else defaults[++defaults_count] = text
      }
      close(defaults_path)
      if (status < 0) complain("missing defaults file " defaults_path)
    }
    # The lines that apply every defaults entry as a declared default, at INDENT.
    function print_defaults(indent,   i) {
      if (!defaults_loaded) load_defaults()
      if (language == "sh") print indent "_guild_config_mode=declare"
      for (i = 1; i <= defaults_count; i++) {
        if (language == "sh") print indent "_guild_config_apply " q defaults[i] q
        else print indent "Add-GuildConfigLine " q defaults[i] q " " q "declare" q
      }
    }
    # Prints one library line, the defaults line expanded; returns 1 for the defaults line.
    function library_line(text) {
      if (!index(text, "/config/defaults.conf")) { print text; return 0 }
      match(text, /^[ \t]*/)
      print_defaults(substr(text, 1, RLENGTH))
      return 1
    }
    # The quote state after LINE, scanned from STATE: code, single or double, or continued when
    # LINE ends in an escape outside quotes. WHERE (file:line) locates a refused ps1 construct.
    # A doubled quote inside a string closes and reopens it, which leaves the state unchanged.
    function scan_line(line, state, where,   position, character) {
      if (state == "continued") state = "code"
      for (position = 1; position <= length(line); position++) {
        character = substr(line, position, 1)
        if (state == "single") { if (character == q) state = "code" }
        else if (state == "double") { if (character == escape) position++; else if (character == "\"") state = "code" }
        else if (character == escape) { if (position == length(line)) return "continued"; position++ }
        else if (character == q) state = open_quote(line, position, where, "single")
        else if (character == "\"") state = open_quote(line, position, where, "double")
        else if (character == "#" && starts_comment(line, position, where)) break
      }
      return state
    }
    # The character before POSITION in LINE; empty at the start of the line (awk substr would
    # clamp position 0 to the first character).
    function previous_character(line, position) {
      return position > 1 ? substr(line, position - 1, 1) : ""
    }
    # KIND, the state the quote at POSITION in LINE opens; a ps1 here-string opening is refused.
    function open_quote(line, position, where, kind) {
      if (language == "ps1" && previous_character(line, position) == "@" && substr(line, position + 1) ~ /^[ \t]*$/)
        complain(where ": opens a here-string, which the library inliner cannot carry")
      return kind
    }
    # Succeeds when the # at POSITION in LINE starts a comment; a ps1 block comment is refused.
    function starts_comment(line, position, where,   previous) {
      previous = previous_character(line, position)
      if (language == "sh") return previous == "" || previous ~ /[ \t;&|()<>]/
      if (previous == "<") complain(where ": opens a block comment, which the library inliner cannot carry")
      return 1
    }
    # Emits one library line that starts in LINE_STATE; returns 1 for the defaults line.
    function emit_library_line(text, line_state) {
      if (line_state != "code") { print text; return 0 }
      if (is_comment(text) || (language == "ps1" && is_blank(text))) return 0
      return library_line(text)
    }
    function inline_library(name,   path, text, status, count, replaced, state, line_state) {
      path = library_dir "/" name "." language
      count = 0
      replaced = 0
      state = "code"
      while ((status = (getline text < path)) > 0) {
        count++
        sub(/\r$/, "", text)
        if (count == 1 && text ~ /^#!/) continue
        line_state = state
        state = scan_line(text, state, path ":" count)
        replaced += emit_library_line(text, line_state)
      }
      close(path)
      if (status < 0) complain("missing library " path)
      else if (name == "config" && replaced != 1)
        complain(path ": " replaced " lines name /config/defaults.conf, expected exactly 1")
    }
    function library_name(line) {
      sub(/^.*\/hooks\/lib\//, "", line)
      sub(/[.](sh|ps1).*$/, "", line)
      return line
    }
    BEGIN {
      q = "\047"
      escape = language == "sh" ? "\\" : "`"
      hook_state = "code"
      dot_source["sh"] = "^[ \t]*[.][ \t]+\"[$][{]CLAUDE_PLUGIN_ROOT[}]/hooks/lib/[A-Za-z0-9_-]+[.]sh\"[ \t]*$"
      dot_source["ps1"] = "^[ \t]*[.][ \t]+[(][$][A-Za-z]+[ \t]*[+][ \t]*" q "/hooks/lib/[A-Za-z0-9_-]+[.]ps1" q "[)][ \t]*$"
    }
    { sub(/\r$/, "") }
    language == "sh" && FNR == 1 { print; next }
    language == "sh" { line_state = hook_state; hook_state = scan_line($0, hook_state, FILENAME ":" FNR) }
    language == "sh" && line_state != "code" { print; next }
    language == "sh" && is_comment($0) { next }
    $0 ~ dot_source[language] { inline_library(library_name($0)); next }
    language == "sh" && /hooks\/lib\// { next }
    { print }
    END { exit failed }
  ' "$1"
}

# FILE TEXT: succeeds when a line of FILE contains TEXT.
mentions_text() {
  awk -v text="$2" 'index($0, text) { found = 1 } END { exit !found }' "$1"
}

# NAME LANGUAGE: compiles hooks/NAME into OUT/hooks/NAME (cp first so the file mode carries over).
compile_hook() {
  source_path="hooks/$1"
  target_path="$OUT/hooks/$1"
  [ -f "$source_path" ] || { report_failure "missing hook script $source_path"; return; }
  cp "$source_path" "$target_path" || fail "cannot copy $source_path"
  compile_source "$source_path" "$2" >"$target_path" || report_failure "cannot compile $source_path"
  ! mentions_text "$target_path" hooks/lib/ || report_failure "compiled $1 still mentions hooks/lib/"
  ! mentions_text "$target_path" defaults.conf || report_failure "compiled $1 still mentions defaults.conf"
  [ "$2" != sh ] || sh -n "$target_path" || report_failure "compiled $1 does not parse"
}

# LANGUAGE: compiles every hooks/<name>.LANGUAGE that hooks/hooks.json names.
compile_named_hooks() {
  hook_names=$(hook_scripts "$1") || fail 'cannot read hooks/hooks.json'
  [ -n "$hook_names" ] || fail "hooks/hooks.json names no .$1 hook script"
  printf '%s\n' "$hook_names" | {
    while IFS= read -r hook_name; do
      compile_hook "$hook_name" "$1"
    done
    [ "$BUILD_FAILED" = no ]
  } || BUILD_FAILED=yes
}

# Sets WINDOWS_POWERSHELL_FOUND and PWSH_FOUND (yes or no); fails when neither is on PATH.
find_powershell_parsers() {
  WINDOWS_POWERSHELL_FOUND=no
  PWSH_FOUND=no
  if command -v powershell.exe >/dev/null 2>&1; then WINDOWS_POWERSHELL_FOUND=yes; fi
  if command -v pwsh >/dev/null 2>&1; then PWSH_FOUND=yes; fi
  [ "$WINDOWS_POWERSHELL_FOUND" = yes ] || [ "$PWSH_FOUND" = yes ] ||
    fail 'no PowerShell on PATH: the build parse-checks the compiled .ps1 hooks with powershell.exe (Windows PowerShell 5.1) or pwsh (PowerShell 7)'
}

# EXECUTABLE NAME: parses (never runs) every compiled .ps1 hook with EXECUTABLE.
parse_powershell_hooks() {
  (cd "$OUT/hooks" && "$1" -NoProfile -NonInteractive -Command "$POWERSHELL_PARSE_CHECK") ||
    report_failure "a compiled .ps1 hook does not parse under $1 ($2)"
}

warn_pwsh_only() {
  printf 'build-release: WARNING: powershell.exe (Windows PowerShell 5.1) is not on PATH.\n' >&2
  printf 'build-release: WARNING: the .ps1 hooks were parsed with pwsh only; PowerShell 7-only syntax the 5.1 floor rejects was NOT checked.\n' >&2
}

# Each .ps1 twin hooks/hooks.json names ships compiled; each PowerShell found then parses them all
# in one run.
compile_powershell_hooks() {
  compile_named_hooks ps1
  [ "$WINDOWS_POWERSHELL_FOUND" = no ] || parse_powershell_hooks powershell.exe 'Windows PowerShell 5.1'
  [ "$PWSH_FOUND" = no ] || parse_powershell_hooks pwsh 'PowerShell 7'
  [ "$WINDOWS_POWERSHELL_FOUND" = yes ] || warn_pwsh_only
}

compile_hooks() {
  mkdir -p "$OUT/hooks" || fail "cannot create $OUT/hooks"
  compile_named_hooks sh
  compile_powershell_hooks
}

[ "$#" -eq 1 ] && [ -n "$1" ] || fail 'usage: sh tools/build-release.sh OUTDIR'
find_powershell_parsers
prepare_output "$1"
REPO_ROOT=$(CDPATH='' cd -- "$(script_directory)/.." && pwd) || fail 'cannot locate the repository'
cd "$REPO_ROOT" || fail "cannot enter $REPO_ROOT"
copy_shipped_files
compile_hooks
printf 'files: %s\n' "$(find "$OUT" -type f | awk 'END { print NR }')"
[ "$BUILD_FAILED" = no ] || fail 'build failed; see the messages above'
