#!/bin/sh
# PostToolUse hook (Edit|Write): rejects emoji in the file just written (owner rule).
# Skips empty paths, missing files, files outside CLAUDE_PROJECT_DIR, and binary types.
# Project containment is lexical: the path is resolved for `.` and `..` without following
# symlinks, so a symlink inside the project that points outside it is still scanned (read-only;
# only the line number of the first hit is reported).
# Detection is byte-level (LC_ALL=C grep -E over UTF-8 byte sequences), so no Unicode-aware tool
# is needed: U+1F000-U+1FAFF, U+2600-U+27BF, U+2B00-U+2BFF, U+FE0F, U+200D. The ranges only
# check the leading bytes of each sequence, so a malformed UTF-8 sequence that starts with
# the same bytes also counts as a hit; that slight over-match is accepted.
# Switch: hooks.emoji_scan. A malformed payload or an internal error never blocks.
set -u

# Generic binary types, tied to no project: images, fonts, archives, executables, model and
# database files, and PDF documents.
BINARY_EXTENSIONS=' .png .jpg .jpeg .gif .ico .onnx .sqlite .dll .exe .pdf .zip .woff .woff2 .ttf '
EMOJI_PATTERN=$(printf '\360\237[\200-\253]|\342[\230-\236]|\342[\254-\257]|\357\270\217|\342\200\215')
# Internal status meaning "block"; any other status, including a shell error, allows.
BLOCK_STATUS=3

case "$0" in
  */*) hooks_dir=${0%/*} ;;
  *) hooks_dir=. ;;
esac

to_forward_slashes() {
  printf '%s' "$1" | tr '\\' '/'
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

absolute_directory() {
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd)
}

# Forward-slash path in, absolute path out with `.` and `..` resolved through its directory.
canonical_file_path() {
  case "$1" in
    */*) file_directory=${1%/*} ;;
    *) file_directory=. ;;
  esac
  case "$file_directory" in '' | *:) file_directory="$file_directory/" ;; esac
  file_directory=$(absolute_directory "$file_directory") || return 1
  printf '%s/%s' "${file_directory%/}" "${1##*/}"
}

# Case-insensitive prefix match against the project root, with a trailing slash.
is_inside_project() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 0
  project_root=$(to_forward_slashes "$CLAUDE_PROJECT_DIR")
  project_root=$(absolute_directory "$project_root") || project_root=$(to_forward_slashes "$CLAUDE_PROJECT_DIR")
  project_root=$(to_lower "${project_root%/}/")
  candidate=$(canonical_file_path "$1") || return 1
  candidate=$(to_lower "$candidate")
  case "$candidate" in "$project_root"*) return 0 ;; esac
  return 1
}

has_binary_extension() {
  file_name=${1##*/}
  case "$file_name" in *.*) ;; *) return 1 ;; esac
  extension=$(to_lower ".${file_name##*.}")
  case "$BINARY_EXTENSIONS" in *" $extension "*) return 0 ;; esac
  return 1
}

# PATH FORWARD_PATH: the raw payload path and its forward-slash form.
is_scannable() {
  [ -n "$1" ] && [ -f "$1" ] || return 1
  is_inside_project "$2" || return 1
  ! has_binary_extension "$2"
}

# NUL bytes are dropped first so grep never classifies the file as binary (which hides the line
# number); newlines survive, so the reported line number stays exact.
first_emoji_line() {
  LC_ALL=C tr -d '\000' <"$1" 2>/dev/null | LC_ALL=C grep -n -E -e "$EMOJI_PATTERN" | head -n 1 | cut -d : -f 1
}

# Sets file_path from the payload; returns 1 when the payload names no scannable file.
scannable_payload_file() {
  payload_read
  file_path=$(payload_field file_path) || return 1
  is_scannable "$file_path" "$(to_forward_slashes "$file_path")"
}

main() {
  . "$hooks_dir/lib/payload.sh"
  . "$hooks_dir/lib/config.sh"
  guild_config_load
  guild_switch hooks.emoji_scan || return 0
  scannable_payload_file || return 0
  hit_line=$(first_emoji_line "$file_path")
  [ -n "$hit_line" ] || return 0
  printf 'Emoji found in %s at line %s (first hit). Owner rule: no emoji in any committed file; write severity/status markers as words. Remove it.\n' "$file_path" "$hit_line" >&2
  exit "$BLOCK_STATUS"
}

(main)
[ "$?" -ne "$BLOCK_STATUS" ] || exit 2
exit 0
