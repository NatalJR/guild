#!/bin/sh
# Builds the slim tree the Claude Directory tracks (the `release` branch) from the working tree.
# Usage: sh tools/build-release.sh OUTDIR   (OUTDIR must be absent or an empty directory)
#
# Copies only the shipped files, swaps README.release.md in as README.md, and compiles every hook
# script hooks/hooks.json names into one self-contained file: line 1 (the shebang) kept, whole-line
# comments dropped, each `. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/<lib>.sh"` line replaced by that
# library minus its shebang and whole-line comments, every other line mentioning hooks/lib/
# deleted. hooks/lib/*.sh is not shipped. A compiled script that still mentions hooks/lib/, names
# a missing library or does not parse fails the build (exit 1; the tree is left for inspection).
# Dependencies: sh, sed, awk, cp, mkdir, find.
set -u

LIBRARY_DIR=hooks/lib
EXCLUDED_SCRIPT=check-context-size.sh
BUILD_FAILED=no

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

# PATTERN: copies every file the glob matches; a glob matching nothing copies nothing.
copy_matching() {
  for matched in $1; do
    [ -f "$matched" ] && copy_file "$matched"
  done
  return 0
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
  copy_matching 'hooks/*.ps1'
  copy_matching "$LIBRARY_DIR/*.ps1"
  [ -f README.release.md ] || fail 'missing README.release.md'
  cp README.release.md "$OUT/README.md" || fail 'cannot copy README.release.md'
}

# Prints each distinct hooks/<name>.sh that hooks/hooks.json names, one name per line.
hook_scripts() {
  awk -v excluded="$EXCLUDED_SCRIPT" '
    {
      rest = $0
      while (match(rest, /hooks\/[A-Za-z0-9_-]+[.]sh/)) {
        name = substr(rest, RSTART + 6, RLENGTH - 6)
        rest = substr(rest, RSTART + RLENGTH)
        if (name != excluded && !(name in seen)) { seen[name] = 1; print name }
      }
    }
  ' hooks/hooks.json
}

# SOURCE: prints SOURCE compiled; exits 1 with a message on stderr when a library is missing.
compile_source() {
  awk -v library_dir="$LIBRARY_DIR" '
    function is_comment(text) { return text ~ /^[ \t]*#/ }
    function inline_library(name,   path, text, status, count) {
      path = library_dir "/" name ".sh"
      count = 0
      while ((status = (getline text < path)) > 0) {
        count++
        sub(/\r$/, "", text)
        if ((count == 1 && text ~ /^#!/) || is_comment(text)) continue
        print text
      }
      close(path)
      if (status < 0) { print "missing library " path | "cat 1>&2"; missing = 1 }
    }
    { sub(/\r$/, "") }
    FNR == 1 { print; next }
    is_comment($0) { next }
    /^[ \t]*[.][ \t]+"[$][{]CLAUDE_PLUGIN_ROOT[}]\/hooks\/lib\/[A-Za-z0-9_-]+[.]sh"[ \t]*$/ {
      name = $0
      sub(/^.*\/hooks\/lib\//, "", name)
      sub(/[.]sh"[ \t]*$/, "", name)
      inline_library(name)
      next
    }
    /hooks\/lib\// { next }
    { print }
    END { exit missing }
  ' "$1"
}

mentions_library_dir() {
  awk '/hooks\/lib\// { found = 1 } END { exit !found }' "$1"
}

# NAME: compiles hooks/NAME into OUT/hooks/NAME (cp first so the file mode carries over).
compile_hook() {
  source_path="hooks/$1"
  target_path="$OUT/hooks/$1"
  [ -f "$source_path" ] || { report_failure "hooks.json names missing script $source_path"; return; }
  cp "$source_path" "$target_path" || fail "cannot copy $source_path"
  compile_source "$source_path" >"$target_path" || report_failure "cannot compile $source_path"
  ! mentions_library_dir "$target_path" || report_failure "compiled $1 still mentions hooks/lib/"
  sh -n "$target_path" || report_failure "compiled $1 does not parse"
}

compile_hooks() {
  mkdir -p "$OUT/hooks" || fail "cannot create $OUT/hooks"
  hook_names=$(hook_scripts) || fail 'cannot read hooks/hooks.json'
  [ -n "$hook_names" ] || fail 'hooks/hooks.json names no hook script'
  printf '%s\n' "$hook_names" | {
    while IFS= read -r hook_name; do
      compile_hook "$hook_name"
    done
    [ "$BUILD_FAILED" = no ]
  } || BUILD_FAILED=yes
}

[ "$#" -eq 1 ] && [ -n "$1" ] || fail 'usage: sh tools/build-release.sh OUTDIR'
prepare_output "$1"
REPO_ROOT=$(CDPATH='' cd -- "$(script_directory)/.." && pwd) || fail 'cannot locate the repository'
cd "$REPO_ROOT" || fail "cannot enter $REPO_ROOT"
copy_shipped_files
compile_hooks
printf 'files: %s\n' "$(find "$OUT" -type f | awk 'END { print NR }')"
[ "$BUILD_FAILED" = no ] || fail 'build failed; see the messages above'
