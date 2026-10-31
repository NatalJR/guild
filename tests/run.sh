#!/bin/sh
# Hook contract suite: pipes JSON payloads into the hooks and asserts exit codes, stderr and
# stdout. POSIX sh with no dependencies; runs as `sh tests/run.sh` under Git Bash's sh and
# under dash from the same checkout (every path is derived from this script's location).
# `sh tests/run.sh --plugin-root DIR` runs the shared cases and the hooks.json and hooks/ layout
# checks against DIR/hooks (a release tree), with CLAUDE_PLUGIN_ROOT=DIR, plus the payload
# library tests; the runner's own library helpers still load from this repository.
# The payload-driven cases live in tests/cases/*.cases (format at the top of each file) and are
# shared with tests/run.ps1, which runs them against the PowerShell twins; the cases that need
# code (scratch roots, crafted bytes, library calls, config queries) stay below, and the ones
# that exercise a twin are written in both runners.
# Fixtures under tests/fixtures/** contain emoji bytes on purpose (emoji-scan cases); the
# repository no-emoji rule exempts that directory. Cases needing a switch override write a
# temporary guild.conf into a scratch HOME or project directory (never into the fixtures) or
# export CLAUDE_PLUGIN_OPTION_GIT_HANDLING; reset_env clears both. render-agents cases run
# against a scratch copy of agents/ (CLAUDE_PLUGIN_ROOT pointed at it), never the repository's
# files; reset_env also clears every CLAUDE_PLUGIN_OPTION_<AGENT>_MODEL / _EFFORT. The hooks
# source their libraries from ${CLAUDE_PLUGIN_ROOT}/hooks/lib only, so every scratch root a hook
# runs against also holds a copy of hooks/lib/ (source layout only).
set -u

case "$0" in
  */*) tests_dir=${0%/*} ;;
  *) tests_dir=. ;;
esac
TESTS_DIR=$(CDPATH='' cd -- "$tests_dir" && pwd) || exit 1
REPO_ROOT=$(CDPATH='' cd -- "$TESTS_DIR/.." && pwd) || exit 1

# --plugin-root DIR: the shared cases and the layout checks, against DIR/hooks with
# CLAUDE_PLUGIN_ROOT=DIR.
PLUGIN_ROOT_GIVEN=no
PLUGIN_ROOT=$REPO_ROOT
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-root)
      [ "$#" -ge 2 ] || { printf 'run.sh: --plugin-root needs a directory\n' >&2; exit 2; }
      PLUGIN_ROOT_GIVEN=yes
      PLUGIN_ROOT=$2
      shift 2
      ;;
    *) printf 'run.sh: unknown argument [%s]\n' "$1" >&2; exit 2 ;;
  esac
done
if [ "$PLUGIN_ROOT_GIVEN" = yes ]; then
  [ -d "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/hooks/hooks.json" ] || {
    printf 'run.sh: plugin root [%s] is missing or has no hooks/hooks.json\n' "$PLUGIN_ROOT" >&2
    exit 2
  }
  PLUGIN_ROOT=$(CDPATH='' cd -- "$PLUGIN_ROOT" && pwd) || exit 2
fi
HOOKS="$PLUGIN_ROOT/hooks"
FIXTURES="$TESTS_DIR/fixtures"
FIXTURE_PROJECT="$FIXTURES/project"
FIXTURE_HOME="$FIXTURES/home"

CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT
CLAUDE_PROJECT_DIR=$FIXTURE_PROJECT
HOME=$FIXTURE_HOME
export CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR HOME
unset CLAUDE_PLUGIN_OPTION_GIT_HANDLING

unset_agent_options() {
  for agent_option in INVESTIGATOR BUILDER ARCHITECT REVIEWER SECURITY SCRIBE; do
    unset "CLAUDE_PLUGIN_OPTION_${agent_option}_MODEL" "CLAUDE_PLUGIN_OPTION_${agent_option}_EFFORT"
  done
}
unset_agent_options

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

PASSED=0
FAILED=0
CASE=''
SCRATCH_SEQUENCE=0
NL='
'
TAB=$(printf '\t')
CR=$(printf '\r')

# ---------------------------------------------------------------- harness

describe() {
  CASE=$1
}

pass() {
  PASSED=$((PASSED + 1))
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL: %s\n      %s\n' "$CASE" "$1"
}

contains() {
  case "$1" in *"$2"*) return 0 ;; esac
  return 1
}

# Prints the summary and exits 0 when no case failed, else 1.
finish() {
  if [ "$PLUGIN_ROOT_GIVEN" = yes ]; then
    printf '%s passed, %s failed (shared cases and layout checks only, plugin root %s)\n' "$PASSED" "$FAILED" "$PLUGIN_ROOT"
  else
    printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
  fi
  [ "$FAILED" -eq 0 ] && exit 0
  exit 1
}

# HOOK PAYLOAD [ARG...]: sets RUN_EXIT, RUN_STDOUT, RUN_STDERR.
run_hook() {
  run_script=$1
  run_payload=$2
  shift 2
  printf '%s' "$run_payload" | sh "$HOOKS/$run_script" "$@" >"$SCRATCH/stdout" 2>"$SCRATCH/stderr"
  RUN_EXIT=$?
  RUN_STDOUT=$(cat "$SCRATCH/stdout")
  RUN_STDERR=$(cat "$SCRATCH/stderr")
}

# HOOK EXIT PAYLOAD [STDERR_SUBSTRING]
expect_exit() {
  run_hook "$1" "$3"
  [ "$RUN_EXIT" = "$2" ] || { fail "exit $RUN_EXIT, want $2; stderr: $RUN_STDERR"; return 0; }
  contains "$RUN_STDERR" "${4:-}" || { fail "exit $RUN_EXIT; stderr lacks [${4:-}]: $RUN_STDERR"; return 0; }
  pass
}

# SUBSTRING HOOK [ARG...]: runs a context hook with an empty payload.
expect_stdout_contains() {
  wanted=$1
  shift
  run_context "$@"
  contains "$RUN_STDOUT" "$wanted" || { fail "exit $RUN_EXIT; stdout lacks [$wanted]; stderr: $RUN_STDERR"; return 0; }
  pass
}

expect_stdout_lacks() {
  unwanted=$1
  shift
  run_context "$@"
  ! contains "$RUN_STDOUT" "$unwanted" || { fail "exit $RUN_EXIT; stdout contains [$unwanted]"; return 0; }
  pass
}

run_context() {
  context_hook=$1
  shift
  run_hook "$context_hook" '' "$@"
}

# WANT GOT
expect_equal() {
  [ "$2" = "$1" ] || { fail "want [$1] got [$2]"; return 0; }
  pass
}

# ---------------------------------------------------------------- shared case runner (tests/cases)

CASE_SEQUENCE=0

case_reset() {
  CASE_STARTED=no
  CASE_NAME=''
  CASE_HOOK=''
  CASE_PART=''
  CASE_HAS_PART=no
  CASE_USER_CONF=''
  CASE_PROJECT_CONF=''
  CASE_AGENTS_COPY=''
  CASE_ENV=''
  CASE_UNSET=''
  CASE_PAYLOAD=''
  CASE_EXPECT=''
  CASE_ERROR=''
}

# FIELD VALUE: records one `field=value` line of the current record.
case_field() {
  CASE_STARTED=yes
  case "$1" in
    'case') CASE_NAME=$2 ;;
    'hook') CASE_HOOK=$2 ;;
    'part') CASE_PART=$2; CASE_HAS_PART=yes ;;
    'user-conf') CASE_USER_CONF="$CASE_USER_CONF$2$NL" ;;
    'project-conf') CASE_PROJECT_CONF="$CASE_PROJECT_CONF$2$NL" ;;
    'agents-copy') CASE_AGENTS_COPY=$2 ;;
    'env') CASE_ENV="$CASE_ENV$2$NL" ;;
    'unset') CASE_UNSET="$CASE_UNSET$2$NL" ;;
    'payload') CASE_PAYLOAD=$2 ;;
    'exit' | 'stderr' | 'stderr-equals' | 'stdout' | 'stdout-lacks' | 'stdout-equals' | 'stdout-under')
      CASE_EXPECT="$CASE_EXPECT$1=$2$NL" ;;
    *) CASE_ERROR="unknown field [$1]" ;;
  esac
}

# FILE: runs every record of a case file, one counted case per record.
run_case_file() {
  case_reset
  while IFS= read -r case_line || [ -n "$case_line" ]; do
    case_line=${case_line%"$CR"}
    case "$case_line" in
      '') run_pending_case ;;
      '#'*) ;;
      *) case_field "${case_line%%=*}" "${case_line#*=}" ;;
    esac
  done <"$1"
  run_pending_case
}

run_pending_case() {
  [ "$CASE_STARTED" = yes ] || return 0
  CASE_SEQUENCE=$((CASE_SEQUENCE + 1))
  describe "${CASE_NAME:-record $CASE_SEQUENCE}"
  if case_failure=$(run_case </dev/null 2>&1); then pass; else fail "$case_failure"; fi
  case_reset
}

# Runs inside a command substitution, so the environment it sets up dies with the case.
# Prints the reason and returns 1 when the record is malformed or an expectation misses.
run_case() {
  [ -z "$CASE_ERROR" ] || { printf '%s' "$CASE_ERROR"; return 1; }
  [ -n "$CASE_NAME" ] && [ -n "$CASE_HOOK" ] && [ -f "$HOOKS/$CASE_HOOK.sh" ] || {
    printf 'record needs case= and hook= naming an existing hook, got [%s]' "$CASE_HOOK"
    return 1
  }
  apply_case_setup || return 1
  expand_placeholders "$CASE_PAYLOAD"
  if [ "$CASE_HAS_PART" = yes ]; then
    run_hook "$CASE_HOOK.sh" "$EXPANDED" "$CASE_PART"
  else
    run_hook "$CASE_HOOK.sh" "$EXPANDED"
  fi
  check_expectations
}

apply_case_setup() {
  if [ -n "$CASE_USER_CONF" ]; then
    case_scratch_dir user
    printf '%s' "$CASE_USER_CONF" >"$CASE_DIR/.claude/guild.conf"
    HOME=$CASE_DIR
  fi
  if [ -n "$CASE_PROJECT_CONF" ]; then
    case_scratch_dir project
    printf '%s' "$CASE_PROJECT_CONF" >"$CASE_DIR/.claude/guild.conf"
    cp "$FIXTURE_PROJECT/emoji.md" "$CASE_DIR/emoji.md"
    CLAUDE_PROJECT_DIR=$CASE_DIR
  fi
  apply_agents_copy && apply_case_lines set "$CASE_ENV" && apply_case_lines unset "$CASE_UNSET"
}

case_scratch_dir() {
  CASE_DIR="$SCRATCH/shared$CASE_SEQUENCE-$1"
  mkdir -p "$CASE_DIR/.claude"
}

# agents-copy=yes: CLAUDE_PLUGIN_ROOT pointed at a scratch dir holding a copy of agents/.
apply_agents_copy() {
  case "$CASE_AGENTS_COPY" in
    '') return 0 ;;
    'yes') ;;
    *) printf 'agents-copy= takes yes, got [%s]' "$CASE_AGENTS_COPY"; return 1 ;;
  esac
  case_scratch_dir agents
  cp -R "$PLUGIN_ROOT/agents" "$CASE_DIR/agents" && copy_hook_libraries "$CASE_DIR" && CLAUDE_PLUGIN_ROOT=$CASE_DIR
}

# MODE LINES: applies each newline-terminated NAME=value (MODE set) or NAME (MODE unset).
apply_case_lines() {
  case_lines_rest=$2
  while [ -n "$case_lines_rest" ]; do
    apply_case_line "$1" "${case_lines_rest%%"$NL"*}" || return 1
    case_lines_rest=${case_lines_rest#*"$NL"}
  done
}

apply_case_line() {
  case_variable=${2%%=*}
  case "$case_variable" in
    '' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) printf 'bad variable name [%s]' "$case_variable"; return 1 ;;
  esac
  if [ "$1" = unset ]; then
    unset "$case_variable"
    return 0
  fi
  case "$2" in *=*) ;; *) printf 'env= needs NAME=value, got [%s]' "$2"; return 1 ;; esac
  export "$case_variable=${2#*=}"
}

check_expectations() {
  case_expect_rest=$CASE_EXPECT
  while [ -n "$case_expect_rest" ]; do
    case_expect_item=${case_expect_rest%%"$NL"*}
    case_expect_rest=${case_expect_rest#*"$NL"}
    expand_placeholders "${case_expect_item#*=}"
    check_expectation "${case_expect_item%%=*}" "$EXPANDED" || return 1
  done
}

# KIND WANT: one expectation against the last run; prints the miss and returns 1.
check_expectation() {
  case "$1" in
    'exit') [ "$RUN_EXIT" = "$2" ] && return 0 ;;
    'stderr') contains "$RUN_STDERR" "$2" && return 0 ;;
    'stderr-equals') [ "$RUN_STDERR" = "$2" ] && return 0 ;;
    'stdout') contains "$RUN_STDOUT" "$2" && return 0 ;;
    'stdout-lacks') contains "$RUN_STDOUT" "$2" || return 0 ;;
    'stdout-equals') [ "$RUN_STDOUT" = "$2" ] && return 0 ;;
    'stdout-under') [ "$(($(printf '%s\n' "$RUN_STDOUT" | wc -c)))" -lt "$2" ] && return 0 ;;
  esac
  printf '%s [%s] not met; exit %s; stdout: %s; stderr: %s' "$1" "$2" "$RUN_EXIT" \
    "$(printf '%s\n' "$RUN_STDOUT" | head -n 3)" "$RUN_STDERR"
  return 1
}

# Sets EXPANDED to VALUE with the case-file placeholders replaced.
expand_placeholders() {
  replace_all "$1" '%NL%' "$NL"
  replace_all "$REPLACED" '%FIXTURES%' "$FIXTURES"
  replace_all "$REPLACED" '%PROJECT%' "${CLAUDE_PROJECT_DIR:-}"
  replace_all "$REPLACED" '%ROOT%' "$PLUGIN_ROOT"
  EXPANDED=$REPLACED
}

# TEXT FROM TO: sets REPLACED to TEXT with every literal FROM replaced by TO.
replace_all() {
  REPLACED=''
  replace_rest=$1
  while [ -n "$2" ] && contains "$replace_rest" "$2"; do
    REPLACED="$REPLACED${replace_rest%%"$2"*}$3"
    replace_rest=${replace_rest#*"$2"}
  done
  REPLACED="$REPLACED$replace_rest"
}

# ---------------------------------------------------------------- environment

new_scratch_dir() {
  SCRATCH_SEQUENCE=$((SCRATCH_SEQUENCE + 1))
  SCRATCH_DIR="$SCRATCH/case$SCRATCH_SEQUENCE"
  mkdir -p "$SCRATCH_DIR/.claude"
}

# CONTENT: points HOME at a scratch directory whose ~/.claude/guild.conf holds CONTENT.
use_user_conf() {
  new_scratch_dir
  printf '%s\n' "$1" >"$SCRATCH_DIR/.claude/guild.conf"
  HOME=$SCRATCH_DIR
}

# CONTENT: points CLAUDE_PROJECT_DIR at a scratch project with CONTENT as its guild.conf.
use_project_conf() {
  new_scratch_dir
  printf '%s\n' "$1" >"$SCRATCH_DIR/.claude/guild.conf"
  cp "$FIXTURE_PROJECT/emoji.md" "$SCRATCH_DIR/emoji.md"
  CLAUDE_PROJECT_DIR=$SCRATCH_DIR
}

# ROOT: copies hooks/lib/ of the plugin root under test into the scratch plugin root ROOT, where
# the hooks source it from; a plugin root without hooks/lib (a release tree) copies nothing.
copy_hook_libraries() {
  mkdir -p "$1/hooks" || return 1
  [ -d "$HOOKS/lib" ] || return 0
  cp -R "$HOOKS/lib" "$1/hooks/lib"
}

reset_env() {
  CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT
  CLAUDE_PROJECT_DIR=$FIXTURE_PROJECT
  HOME=$FIXTURE_HOME
  export CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR
  unset CLAUDE_PLUGIN_OPTION_GIT_HANDLING
  unset_agent_options
}

# Points CLAUDE_PLUGIN_ROOT at a scratch root holding a copy of agents/.
use_agents_root() {
  new_scratch_dir
  cp -R "$REPO_ROOT/agents" "$SCRATCH_DIR/agents"
  copy_hook_libraries "$SCRATCH_DIR"
  CLAUDE_PLUGIN_ROOT=$SCRATCH_DIR
}

# Prints every line the scratch agents/ changed against the repository copy, as
# `<file> - <old line>` and `<file> + <new line>` in diff order.
agents_changes() {
  for agent_path in "$REPO_ROOT"/agents/*.md; do
    agent_name=${agent_path##*/}
    diff "$agent_path" "$SCRATCH_DIR/agents/$agent_name" | sed -n -e "s/^< /$agent_name - /p" -e "s/^> /$agent_name + /p"
  done
}

# FILE: byte size of FILE.
byte_size() {
  printf '%s' "$(($(wc -c <"$1")))"
}

# Windows forms of the repository root when running under Git Bash (cygpath present).
WINDOWS_ROOT_FORWARD=''
WINDOWS_ROOT_BACKSLASH=''
if command -v cygpath >/dev/null 2>&1; then
  WINDOWS_ROOT_FORWARD=$(cygpath -m "$REPO_ROOT")
  WINDOWS_ROOT_BACKSLASH=$(cygpath -w "$REPO_ROOT")
fi

json_escape_backslashes() {
  printf '%s' "$1" | sed 's/\\/\\\\/g'
}

# ---------------------------------------------------------------- payload builders

file_payload() {
  printf '{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"},"tool_response":{"filePath":"%s"}}' "$1" "$1"
}

# AGENT MESSAGE: MESSAGE is already JSON-escaped.
receipt_payload() {
  printf '{"session_id":"s","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_type":"%s","last_assistant_message":"%s"}' "$1" "$2"
}

field_of() {
  (
    . "$REPO_ROOT/hooks/lib/payload.sh"
    PAYLOAD=$1
    payload_field "$2" || printf '<absent>'
  )
}

bool_of() {
  (
    . "$REPO_ROOT/hooks/lib/payload.sh"
    PAYLOAD=$1
    if payload_bool "$2"; then printf 'true'; else printf 'false'; fi
  )
}

first_line_of() {
  (
    . "$REPO_ROOT/hooks/lib/payload.sh"
    payload_first_line "$1"
  )
}

config_query() {
  (
    . "$REPO_ROOT/hooks/lib/config.sh"
    guild_config_load
    "$@"
  )
}

switch_state() {
  if config_query guild_switch "$1"; then printf 'on'; else printf 'off'; fi
}

count_on_switches() {
  printf '%s\n' "$GUILD_SWITCHES" | grep -c '=on$'
}

# ---------------------------------------------------------------- payload library

describe 'payload_field: escaped quote'
expect_equal 'x"y' "$(field_of '{"a":"x\"y"}' a)"
describe 'payload_field: escaped backslash'
expect_equal 'x\y' "$(field_of '{"a":"x\\y"}' a)"
describe 'payload_field: escaped newline'
expect_equal "l1${NL}l2" "$(field_of '{"a":"l1\nl2"}' a)"
describe 'payload_field: escaped backslash before n or t stays a backslash'
expect_equal 'C:\new\tests' "$(field_of '{"a":"C:\\new\\tests"}' a)"
describe 'payload_field: slash, tab, carriage return, unicode escape'
expect_equal "a/b${TAB}c\\u0041" "$(field_of '{"a":"a\/b\tc\r\u0041"}' a)"
describe 'payload_field: key inside a nested object'
expect_equal 'ls -la' "$(field_of '{"tool_input":{"command":"ls -la"}}' command)"
describe 'payload_field: key text inside another string value is not a match'
expect_equal 'real' "$(field_of '{"description":"\"command\":\"fake\"","command":"real"}' command)"
describe 'payload_field: first occurrence wins'
expect_equal 'one' "$(field_of '{"a":"one","b":{"a":"two"}}' a)"
describe 'payload_field: empty value is present'
expect_equal '' "$(field_of '{"a":""}' a)"
describe 'payload_field: absent key'
expect_equal '<absent>' "$(field_of '{"b":"x"}' a)"
describe 'payload_field: non-string value counts as absent'
expect_equal '<absent>' "$(field_of '{"a":null}' a)"
describe 'payload_field: unterminated value counts as absent'
expect_equal '<absent>' "$(field_of '{"a":"open' a)"
describe 'payload_field: empty payload'
expect_equal '<absent>' "$(field_of '' a)"
describe 'payload_bool: true'
expect_equal 'true' "$(bool_of '{"x":1,"stop_hook_active":true}' stop_hook_active)"
describe 'payload_bool: false'
expect_equal 'false' "$(bool_of '{"stop_hook_active":false}' stop_hook_active)"
describe 'payload_first_line: skips blank lines and trims'
expect_equal 'verified: ok' "$(first_line_of "${NL}   ${NL}  verified: ok  ${NL}next")"

# ---------------------------------------------------------------- shared cases

for case_file in "$TESTS_DIR"/cases/*.cases; do
  [ -f "$case_file" ] || continue
  run_case_file "$case_file"
done

describe 'shared cases: every PowerShell twin has a case file'
missing_case_files=$(for twin_script in "$HOOKS"/*.ps1; do
  [ -f "$twin_script" ] || continue
  twin_name=${twin_script##*/}
  [ -f "$TESTS_DIR/cases/${twin_name%.ps1}.cases" ] || printf '%s\n' "$twin_name"
done)
expect_equal '' "$missing_case_files"

# ---------------------------------------------------------------- hooks.json wiring

# Prints every hooks/<name>.sh that a hooks.json command names, one per line.
hooks_json_scripts() {
  sed -n 's|.*/hooks/\([A-Za-z0-9_-]*\.sh\).*|\1|p' "$HOOKS/hooks.json"
}

# Prints every hooks/<name>.ps1 that a hooks.json command names, one per line.
hooks_json_twins() {
  sed -n 's|.*/hooks/\([A-Za-z0-9_-]*\.ps1\).*|\1|p' "$HOOKS/hooks.json"
}

# Counts the commands of the exact two-line polyglot shape: line 1 execs the sh script (so sh
# never reads line 2), line 2 runs the .ps1 twin with the call operator and the same arguments
# (PowerShell, where exec is not a command, runs it and exits with its status).
count_polyglot_commands() {
  grep -c '"command": "exec sh \\"${CLAUDE_PLUGIN_ROOT}/hooks/\([A-Za-z0-9_-]*\)\.sh\\"\([^"\\]*\)\\n& \\"${CLAUDE_PLUGIN_ROOT}/hooks/\1\.ps1\\"\2; exit \$LASTEXITCODE",*$' "$HOOKS/hooks.json"
}

# SCRIPT...: prints every name with no file under hooks/.
missing_hook_files() {
  while IFS= read -r wired_script; do
    [ -f "$HOOKS/$wired_script" ] || printf '%s\n' "$wired_script"
  done
}

describe 'hooks.json: every command runs an existing sh script'
expect_equal '' "$(hooks_json_scripts | missing_hook_files)"
describe 'hooks.json: eight script references found'
expect_equal '8' "$(($(hooks_json_scripts | wc -l)))"
describe 'hooks.json: every command names an existing PowerShell twin'
expect_equal '' "$(hooks_json_twins | missing_hook_files)"
describe 'hooks.json: eight commands, all the sh/PowerShell polyglot'
expect_equal '8 8' "$(grep -c '"command":' "$HOOKS/hooks.json") $(count_polyglot_commands)"
describe 'hooks.json: render-agents wired once on SessionStart and once on UserPromptSubmit'
expect_equal '2' "$(hooks_json_scripts | grep -c '^render-agents\.sh$')"
describe 'hooks.json: no pwsh -File line'
expect_equal '0' "$(grep -c 'pwsh -NoProfile -File' "$HOOKS/hooks.json")"
describe 'hooks.json: no shell field'
expect_equal '0' "$(grep -c '"shell"' "$HOOKS/hooks.json")"

# The coded cases below load hooks/lib or need files only the repository holds; a plugin root
# under test stops after the shared cases and the layout checks above.
[ "$PLUGIN_ROOT_GIVEN" = no ] || finish

# ---------------------------------------------------------------- emoji-scan

describe 'emoji-scan: project prefix needs a path boundary'
new_scratch_dir
mkdir -p "$SCRATCH_DIR/proj" "$SCRATCH_DIR/project"
cp "$FIXTURE_PROJECT/emoji.md" "$SCRATCH_DIR/project/emoji.md"
CLAUDE_PROJECT_DIR="$SCRATCH_DIR/proj"
expect_exit emoji-scan.sh 0 "$(file_payload "$SCRATCH_DIR/project/emoji.md")"
reset_env

# NAME BYTES EXIT: writes BYTES (printf format) on line 2 of a scratch project file.
expect_scan_bytes() {
  new_scratch_dir
  printf "plain first line\nsecond $2 line\n" >"$SCRATCH_DIR/sample.md"
  CLAUDE_PROJECT_DIR=$SCRATCH_DIR
  describe "emoji-scan: $1"
  expect_exit emoji-scan.sh "$3" "$(file_payload "$SCRATCH_DIR/sample.md")"
  reset_env
}
expect_scan_bytes 'U+1FA77 blocked' '\360\237\251\267' 2
expect_scan_bytes 'U+2705 blocked' '\342\234\205' 2
expect_scan_bytes 'U+2B50 blocked' '\342\255\220' 2
expect_scan_bytes 'U+FE0F blocked' '\357\270\217' 2
expect_scan_bytes 'U+200D blocked' '\342\200\215' 2
expect_scan_bytes 'U+1FB00 (outside the ranges) allowed' '\360\237\254\200' 0
expect_scan_bytes 'em dash and box drawing allowed' '\342\200\224 \342\224\200' 0

describe 'emoji-scan: NUL byte keeps the reported line number exact'
new_scratch_dir
printf 'one\ntwo \000\nthree \342\234\205\n' >"$SCRATCH_DIR/nul.md"
CLAUDE_PROJECT_DIR=$SCRATCH_DIR
expect_exit emoji-scan.sh 2 "$(file_payload "$SCRATCH_DIR/nul.md")" 'nul.md at line 3, the first hit'
reset_env

describe 'emoji-scan: uppercase binary extension skipped'
new_scratch_dir
cp "$FIXTURE_PROJECT/image.png" "$SCRATCH_DIR/IMAGE.PNG"
CLAUDE_PROJECT_DIR=$SCRATCH_DIR
expect_exit emoji-scan.sh 0 "$(file_payload "$SCRATCH_DIR/IMAGE.PNG")"
reset_env

if [ -n "$WINDOWS_ROOT_BACKSLASH" ]; then
  describe 'emoji-scan: Windows backslash paths (Git Bash only)'
  CLAUDE_PROJECT_DIR="$WINDOWS_ROOT_BACKSLASH\\tests\\fixtures\\project"
  windows_file=$(json_escape_backslashes "$CLAUDE_PROJECT_DIR\\emoji.md")
  expect_exit emoji-scan.sh 2 "$(file_payload "$windows_file")" 'line 3'
  describe 'emoji-scan: Windows backslash path outside the project (Git Bash only)'
  windows_file=$(json_escape_backslashes "$WINDOWS_ROOT_BACKSLASH\\tests\\fixtures\\outside\\outside.md")
  expect_exit emoji-scan.sh 0 "$(file_payload "$windows_file")"
  reset_env
fi

# ---------------------------------------------------------------- receipt-check

large_message='plan: 2 files\n'
large_round=0
while [ "$large_round" -lt 12 ]; do
  large_message="$large_message$large_message"
  large_round=$((large_round + 1))
done
describe 'receipt-check: large message with a token allowed'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:builder "$large_message")"
describe 'receipt-check: large message without a token blocked'
expect_exit receipt-check.sh 2 "$(receipt_payload guild:builder "prose first\n$large_message")" 'Receipt contract'

# ---------------------------------------------------------------- config

describe 'config: fixture project carries no guild.conf'
expect_equal 'absent' "$([ -e "$FIXTURE_PROJECT/.claude/guild.conf" ] && printf present || printf absent)"
describe 'config: defaults declare fourteen keys, all on'
expect_equal '14' "$(config_query count_on_switches)"
describe 'config: shipped defaults report no changed keys'
expect_equal '' "$(config_query guild_changed_switches)"
describe 'config: git.handling reads as off by default'
expect_equal 'off' "$(switch_state git.handling)"
describe 'config: user conf turns a switch off'
use_user_conf 'hooks.emoji_scan = off'
expect_equal 'off' "$(switch_state hooks.emoji_scan)"
describe 'config: project conf overrides user conf'
use_project_conf 'hooks.emoji_scan = on'
expect_equal 'on' "$(switch_state hooks.emoji_scan)"
reset_env
describe 'config: unknown key ignored'
use_user_conf 'hooks.not_a_switch = off'
expect_equal '' "$(config_query guild_changed_switches)"
describe 'config: unknown key reads as on'
expect_equal 'on' "$(switch_state hooks.not_a_switch)"
reset_env
describe 'config: malformed lines ignored, valid lines still applied'
use_user_conf "hooks.emoji_scan off
hooks.emoji_scan = maybe
Hooks.Emoji_Scan = off
review.security = off # trailing comment
=off
  # docs.sync = off
review.norms=No"
expect_equal 'review.norms=off' "$(config_query guild_changed_switches)"
reset_env
describe 'config: values are case-insensitive'
use_user_conf "review.security = OFF
docs.sync = False
style.terse = YES"
expect_equal 'docs.sync=off review.security=off' "$(config_query guild_changed_switches)"
reset_env
describe 'config: CRLF line endings'
new_scratch_dir
printf 'review.security = off\r\nhooks.emoji_scan = off\r\n' >"$SCRATCH_DIR/.claude/guild.conf"
HOME=$SCRATCH_DIR
expect_equal 'hooks.emoji_scan=off review.security=off' "$(config_query guild_changed_switches)"
reset_env
describe 'config: guild_changed_switches sorted and space separated'
use_user_conf "style.terse = off
docs.sync = off
hooks.receipt_check = off"
expect_equal 'docs.sync=off hooks.receipt_check=off style.terse=off' "$(config_query guild_changed_switches)"
reset_env
describe 'config: a key set to its shipped default is not reported as changed'
use_user_conf "docs.sync = on
review.security = on"
expect_equal '' "$(config_query guild_changed_switches)"
reset_env
describe 'config: missing defaults file never disables anything'
new_scratch_dir
CLAUDE_PLUGIN_ROOT=$SCRATCH_DIR
use_user_conf 'review.security = off'
expect_equal 'on' "$(switch_state review.security)"
describe 'config: missing defaults file keeps git.handling off'
expect_equal 'off' "$(switch_state git.handling)"
describe 'config: missing defaults file reports no changed keys'
expect_equal '' "$(config_query guild_changed_switches)"
describe 'config: missing defaults file, plugin option true turns git.handling on'
CLAUDE_PLUGIN_OPTION_GIT_HANDLING=true
export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
expect_equal 'on' "$(switch_state git.handling)"
describe 'config: missing defaults file, plugin option true reports git.handling=on'
expect_equal 'git.handling=on' "$(config_query guild_changed_switches)"
reset_env
describe 'config: unset CLAUDE_PLUGIN_ROOT reads no defaults file'
use_user_conf 'review.security = off'
unset CLAUDE_PLUGIN_ROOT
expect_equal '' "$(config_query guild_changed_switches)"
reset_env

# VALUE WANT: git.handling state with the plugin option set to VALUE and no conf file.
expect_option_state() {
  describe "config: plugin option [$1] maps git.handling to $2"
  CLAUDE_PLUGIN_OPTION_GIT_HANDLING=$1
  export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
  expect_equal "$2" "$(switch_state git.handling)"
  reset_env
}
expect_option_state true on
expect_option_state TRUE on
expect_option_state 1 on
expect_option_state On on
expect_option_state yes on
expect_option_state false off
expect_option_state 0 off
expect_option_state '' off
expect_option_state maybe off
describe 'config: git.handling on in the project conf is ignored'
use_project_conf 'git.handling = on'
expect_equal 'off' "$(switch_state git.handling)"
describe 'config: git.handling in the project conf reports no changed keys'
expect_equal '' "$(config_query guild_changed_switches)"
describe 'config: plugin option false leaves git.handling off'
CLAUDE_PLUGIN_OPTION_GIT_HANDLING=false
export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
expect_equal 'off' "$(switch_state git.handling)"
reset_env
describe 'config: plugin option true turns git.handling on despite the user conf'
use_user_conf 'git.handling = off'
CLAUDE_PLUGIN_OPTION_GIT_HANDLING=true
export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
expect_equal 'on' "$(switch_state git.handling)"
describe 'config: plugin option sets git.handling only'
expect_equal 'git.handling=on' "$(config_query guild_changed_switches)"
reset_env
describe 'config: git.handling declared in the defaults file is ignored'
new_scratch_dir
mkdir -p "$SCRATCH_DIR/config"
printf '%s\n' 'git.handling = on' 'review.security = on' >"$SCRATCH_DIR/config/defaults.conf"
CLAUDE_PLUGIN_ROOT=$SCRATCH_DIR
expect_equal 'off' "$(switch_state git.handling)"
reset_env

# ---------------------------------------------------------------- session-context

describe 'session-context: every switch off leaves no marker lines'
use_user_conf "$(sed -n 's/= on$/= off/p' "$REPO_ROOT/config/defaults.conf")"
expect_stdout_lacks '{{' session-context.sh context/always-on.md
describe 'session-context: every switch off except default_mode leaves no marker lines in the procedure'
use_user_conf "$(sed -n -e '/procedure.default_mode/d' -e 's/= on$/= off/p' "$REPO_ROOT/config/defaults.conf")"
expect_stdout_lacks '{{' session-context.sh context/procedure.md
reset_env
if [ -n "$WINDOWS_ROOT_BACKSLASH" ]; then
  describe 'session-context: backslash plugin root rendered with forward slashes (Git Bash only)'
  CLAUDE_PLUGIN_ROOT=$WINDOWS_ROOT_BACKSLASH
  expect_stdout_contains "$WINDOWS_ROOT_FORWARD/skills/guild/DAG.md" session-context.sh context/procedure.md
  reset_env
fi

describe 'session-context: every switch on leaves no marker lines in the procedure'
CLAUDE_PLUGIN_OPTION_GIT_HANDLING=true
export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
expect_stdout_lacks '{{' session-context.sh context/procedure.md
reset_env

# Points CLAUDE_PLUGIN_ROOT at a scratch root whose context/procedure.md holds a plain and a
# negated block on the same switch.
use_marker_root() {
  new_scratch_dir
  mkdir -p "$SCRATCH_DIR/config" "$SCRATCH_DIR/context"
  cp "$REPO_ROOT/config/defaults.conf" "$SCRATCH_DIR/config/defaults.conf"
  copy_hook_libraries "$SCRATCH_DIR"
  printf '%s\n' head '{{#if review.security}}' plain '{{/if}}' '{{#if !review.security}}' negated '{{/if}}' tail >"$SCRATCH_DIR/context/procedure.md"
  CLAUDE_PLUGIN_ROOT=$SCRATCH_DIR
}
describe 'session-context: negated block dropped while its switch is on'
use_marker_root
run_context session-context.sh context/procedure.md
expect_equal "head${NL}plain${NL}tail" "$RUN_STDOUT"
describe 'session-context: negated block kept while its switch is off'
use_user_conf 'review.security = off'
run_context session-context.sh context/procedure.md
expect_equal "head${NL}negated${NL}tail" "$RUN_STDOUT"
reset_env

# ---------------------------------------------------------------- size check

describe 'check-context-size: every part under the limit'
expect_exit check-context-size.sh 0 ''

# ---------------------------------------------------------------- render-agents

describe 'render-agents: no option set leaves every agent file untouched'
use_agents_root
run_context render-agents.sh
expect_equal '' "$RUN_STDOUT$(agents_changes)"
reset_env

describe 'render-agents: a differing model rewrites only that line'
use_agents_root
CLAUDE_PLUGIN_OPTION_BUILDER_MODEL=sonnet
export CLAUDE_PLUGIN_OPTION_BUILDER_MODEL
run_context render-agents.sh
expect_equal "builder.md - model: opus${NL}builder.md + model: sonnet" "$(agents_changes)"
describe 'render-agents: the rewritten file keeps every other byte (LF endings included)'
expect_equal "$(($(byte_size "$REPO_ROOT/agents/builder.md") + 2))" "$(byte_size "$SCRATCH_DIR/agents/builder.md")"
describe 'render-agents: no temp file left in agents/'
expect_equal '' "$(ls -A "$SCRATCH_DIR/agents" | grep -v '\.md$')"
describe 'render-agents: running again prints nothing'
run_context render-agents.sh
expect_equal '' "$RUN_STDOUT"
describe 'render-agents: running again keeps the rendered file'
expect_equal "builder.md - model: opus${NL}builder.md + model: sonnet" "$(agents_changes)"
reset_env

describe 'render-agents: model and effort of one agent rewritten in one run'
use_agents_root
CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=sonnet
CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT=low
export CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT
run_context render-agents.sh
expect_equal "reviewer.md - model: opus${NL}reviewer.md - effort: high${NL}reviewer.md + model: sonnet${NL}reviewer.md + effort: low" "$(agents_changes)"
reset_env

describe 'render-agents: a failing agent is skipped and the others still render'
use_agents_root
mkdir "$SCRATCH_DIR/agents/builder.md.render"
CLAUDE_PLUGIN_OPTION_BUILDER_MODEL=sonnet
CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL=sonnet
export CLAUDE_PLUGIN_OPTION_BUILDER_MODEL CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL
run_context render-agents.sh
expect_equal "reviewer.md - model: opus${NL}reviewer.md + model: sonnet" "$(agents_changes)"
describe 'render-agents: the notice lists only the agents rendered'
expect_equal 'GUILD AGENTS RENDERED: reviewer model=sonnet effort=high. Run the reload-plugins command to apply.' "$RUN_STDOUT"
reset_env

describe 'render-agents: invalid values leave every agent file untouched'
use_agents_root
CLAUDE_PLUGIN_OPTION_BUILDER_MODEL='opus sonnet'
CLAUDE_PLUGIN_OPTION_ARCHITECT_EFFORT=extreme
CLAUDE_PLUGIN_OPTION_SCRIBE_MODEL='sonnet/;s/^/x/'
export CLAUDE_PLUGIN_OPTION_BUILDER_MODEL CLAUDE_PLUGIN_OPTION_ARCHITECT_EFFORT CLAUDE_PLUGIN_OPTION_SCRIBE_MODEL
run_context render-agents.sh
expect_equal '' "$RUN_STDOUT$(agents_changes)"
reset_env

# ---------------------------------------------------------------- release-tree checker

# Prints the pre-fix replace_all line of session-context.sh, the shape the validator rejects.
nested_quote_sample() {
  printf '%s\n' '    REPLACED="$REPLACED${replace_rest%%"$2"*}$3"'
}

# The nested-quote rule lives in the release-tree checker; its single-rule mode reads stdin when
# given no file.
describe 'hooks tree: no quote nested inside a double-quoted string'
expect_equal '' "$(sh "$REPO_ROOT/tools/check-release-tree.sh" --nested-quotes "$HOOKS"/*.sh "$HOOKS"/lib/*.sh)"
describe 'hooks tree: the nested-quote check flags the pre-fix replace_all line'
expect_equal '1' "$(($(nested_quote_sample | sh "$REPO_ROOT/tools/check-release-tree.sh" --nested-quotes | wc -l)))"

# Builds a scratch tree whose hooks/hooks.json runs git-guard.sh and git-guard.ps1 on
# PreToolUse; sets CHECKED_TREE.
new_checked_tree() {
  new_scratch_dir
  CHECKED_TREE=$SCRATCH_DIR
  mkdir -p "$CHECKED_TREE/hooks"
  printf '%s\n' '{' '  "hooks": {' '    "PreToolUse": [' \
    '      { "hooks": [{ "type": "command", "command": "sh hooks/git-guard.sh; pwsh hooks/git-guard.ps1" }] }' \
    '    ]' '  }' '}' >"$CHECKED_TREE/hooks/hooks.json"
}

# Runs the release-tree checker over CHECKED_TREE, then removes the tree; sets CHECK_EXIT and
# CHECK_OUTPUT.
run_release_check() {
  CHECK_OUTPUT=$(sh "$REPO_ROOT/tools/check-release-tree.sh" "$CHECKED_TREE" 2>&1)
  CHECK_EXIT=$?
  rm -rf "$CHECKED_TREE"
}

# NAME FILE LINE RULE: a tree whose FILE (relative to the tree) holds LINE as its line 2 makes
# the checker exit non-zero and print `./FILE:2: RULE`.
expect_release_violation() {
  describe "check-release-tree: $1"
  new_checked_tree
  printf '%s\n' '# planted' "$3" >"$CHECKED_TREE/$2"
  run_release_check
  [ "$CHECK_EXIT" -ne 0 ] || { fail "exit 0, want non-zero; output: $CHECK_OUTPUT"; return 0; }
  contains "$CHECK_OUTPUT" "./$2:2: $4" || { fail "output lacks [./$2:2: $4]: $CHECK_OUTPUT"; return 0; }
  pass
}

expect_release_violation 'dot-source of an expression' hooks/loader.ps1 '.($root + "x")' dot-source
expect_release_violation 'dot-source of a variable path' hooks/loader.ps1 '. $path' dot-source
expect_release_violation 'Import-Module' hooks/loader.ps1 'Import-Module Foo' Import-Module
expect_release_violation 'environment read with a non-literal name' hooks/loader.ps1 \
  '$v = [Environment]::GetEnvironmentVariable($name)' 'environment read without a literal name'
expect_release_violation 'whole-environment read' hooks/loader.ps1 \
  '$all = [Environment]::GetEnvironmentVariables()' 'whole-environment read'
expect_release_violation 'hook naming defaults.conf' hooks/reader.sh '# reads config/defaults.conf' 'names defaults.conf'
expect_release_violation 'hook naming hooks/lib' hooks/reader.ps1 '# loads hooks/lib/config.ps1' 'names hooks/lib/'
expect_release_violation 'PreToolUse [System.Console]::Out.Write' hooks/git-guard.ps1 \
  '[System.Console]::Out.Write("x")' 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse $Host.UI.Write' hooks/git-guard.ps1 '$Host.UI.Write("x")' 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse echo' hooks/git-guard.ps1 'echo x' 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse Write-Output' hooks/git-guard.ps1 'Write-Output x' 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse ps1 backslash' hooks/git-guard.ps1 '$p = "a\b"' 'PreToolUse backslash'
expect_release_violation 'PreToolUse ps1 backtick' hooks/git-guard.ps1 '$tab = "`t"' 'PreToolUse backtick'
expect_release_violation 'PreToolUse ps1 percent' hooks/git-guard.ps1 '$r = 5 % 2' 'PreToolUse %'
expect_release_violation 'PreToolUse ps1 -f operator' hooks/git-guard.ps1 '$s = "{0}" -f 1' 'PreToolUse -f operator'
expect_release_violation 'PreToolUse ps1 decision word' hooks/git-guard.ps1 '$decision = "allow"' 'PreToolUse decision word'
expect_release_violation 'call operator on an expression' hooks/loader.ps1 "& (\$root + 'x')" 'call operator'
expect_release_violation 'iex as a command word' hooks/loader.ps1 'iex $s' Invoke-Expression
expect_release_violation 'iex after =' hooks/loader.ps1 '$x = iex $s' Invoke-Expression
expect_release_violation 'iex followed by (' hooks/loader.ps1 "iex('x')" Invoke-Expression
expect_release_violation '[scriptblock]::Create' hooks/loader.ps1 '$b = [scriptblock]::Create($s)' '[scriptblock]::Create'
expect_release_violation 'Invoke-Command' hooks/loader.ps1 'Invoke-Command -ScriptBlock $b' Invoke-Command
expect_release_violation 'Env: provider read' hooks/loader.ps1 'Get-ChildItem Env:' 'Env: provider read'
expect_release_violation 'built Env: path' hooks/loader.ps1 "\$p = 'env:' + \$n" 'built Env: path'
expect_release_violation 'printenv command' hooks/reader.sh 'printenv HOME' 'environment command'
expect_release_violation 'env after then' hooks/reader.sh 'then env' 'environment command'
expect_release_violation 'PreToolUse Write-Warning' hooks/git-guard.ps1 'Write-Warning hi' 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse write command word' hooks/git-guard.ps1 "write 'x'" 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse write followed by (' hooks/git-guard.ps1 "write('x')" 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse Tee-Object' hooks/git-guard.ps1 'Tee-Object x' 'PreToolUse stdout writer'
expect_release_violation 'PreToolUse write after =' hooks/git-guard.ps1 '$x = write 1' 'PreToolUse stdout writer'
expect_release_violation 'dot-source after =' hooks/loader.ps1 '$x = . $p' dot-source
expect_release_violation 'dot-source after {' hooks/loader.ps1 '{ . $p }' dot-source
expect_release_violation 'bare dot value' hooks/reader.sh 'dir=.' 'bare dot value'
expect_release_violation 'double-quoted dot value' hooks/reader.sh 'dir="."' 'bare dot value'
expect_release_violation 'single-quoted dot value' hooks/reader.sh "dir='.'" 'bare dot value'
expect_release_violation 'dot value before )' hooks/reader.sh '(dir=.)' 'bare dot value'
expect_release_violation 'dot value before &&' hooks/reader.sh 'dir=.&&true' 'bare dot value'
expect_release_violation 'dot default expansion' hooks/reader.sh 'x=${d:-.}' 'bare dot value'
expect_release_violation 'quoted nested parameter expansion' hooks/reader.sh 't=${1#"${1%%x*}"}' \
  'nested parameter expansion'
expect_release_violation 'unquoted nested parameter expansion' hooks/reader.sh 't=${x%${x##*y}}' \
  'nested parameter expansion'
expect_release_violation 'bare plugin root' hooks/reader.sh '[ -d "$CLAUDE_PLUGIN_ROOT" ]' 'bare plugin root'
expect_release_violation 'braced bare plugin root' hooks/reader.sh '[ -d "${CLAUDE_PLUGIN_ROOT}" ]' 'bare plugin root'
expect_release_violation 'plugin root as a printf argument' hooks/reader.sh \
  "x=\$(printf '%s' \"\$CLAUDE_PLUGIN_ROOT\")" 'bare plugin root'
expect_release_violation 'copy of the plugin root' hooks/reader.sh 'root="$CLAUDE_PLUGIN_ROOT/"' 'copy of the plugin root'
expect_release_violation 'braced copy of the plugin root' hooks/reader.sh 'root="${CLAUDE_PLUGIN_ROOT}/"' \
  'copy of the plugin root'
expect_release_violation 'unquoted copy of the plugin root' hooks/reader.sh 'root=$CLAUDE_PLUGIN_ROOT/' \
  'copy of the plugin root'
expect_release_violation 'copy of the plugin root, slash after the quote' hooks/reader.sh \
  'root="$CLAUDE_PLUGIN_ROOT"/' 'copy of the plugin root'
expect_release_violation 'operator expansion copy of the plugin root' hooks/reader.sh \
  'root=${CLAUDE_PLUGIN_ROOT%/}' 'copy of the plugin root'
expect_release_violation 'bracket in single-quoted text' hooks/reader.sh "msg='see (above)'" \
  'bracket in single-quoted text'
expect_release_violation 'brace pair in single-quoted text' hooks/reader.sh "msg='a {b}'" \
  'bracket in single-quoted text'
expect_release_violation 'closing parenthesis in single-quoted text' hooks/reader.sh "msg='a b)'" \
  'bracket in single-quoted text'
expect_release_violation 'closing brace in single-quoted text' hooks/reader.sh "msg='a }'" \
  'bracket in single-quoted text'
expect_release_violation 'doubled backslash in single-quoted text' hooks/reader.sh "p=\$(sed 's|\\\\|/|g')" \
  'doubled backslash in single-quoted text'

describe 'check-release-tree: a line reports each rule once'
new_checked_tree
printf '%s\n' '# planted' 'iex $s; Invoke-Expression $t' >"$CHECKED_TREE/hooks/loader.ps1"
run_release_check
expect_equal '1' "$(printf '%s\n' "$CHECK_OUTPUT" | grep -c -F './hooks/loader.ps1:2: Invoke-Expression')"

describe 'check-release-tree: clean tree passes (member access and calls, decimal, $echo, &&, literal reads, dot near-misses, quoted brackets, plugin root substitution)'
new_checked_tree
printf '%s\n' '$a.b' '.5 + 1' '$echo = 1' '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding' \
  "\$name = [Environment]::GetEnvironmentVariable('LITERAL')" "\$read = [Environment]::GetEnvironmentVariable( 'HOME')" \
  "[Console]::Error.Write('x')" "\$o.Write('x')" '$a && $b' '$h = $env:HOME' 'Invoke-EmojiScan' >"$CHECKED_TREE/hooks/git-guard.ps1"
printf '%s\n' 'environment' 'dir=./x' 'dir=..' 'n=.5' 'name=${file%.*}' \
  'x = y "." z' 'x=${d:-./y}' 'x=${d%.*}' 'l=${1%%x*}; t=${1#"$l"}' 'p="${a}${b}"' 'q=${a%x}/${b#y}' \
  '[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]' '[ -d "$CLAUDE_PLUGIN_ROOT/hooks" ]' 'x="${CLAUDE_PLUGIN_ROOT}/agents"' \
  '[ -n "${CLAUDE_PLUGIN_ROOT+set}" ]' 'has_root=${CLAUDE_PLUGIN_ROOT:+set}' 'x=${CLAUDE_PLUGIN_ROOT+1}' \
  '(main "$@") 2>/dev/null' 'x="$(cmd)"' "printf '%s\\n' \"\$x\"" \
  "plugin_root=\$(printf '%s' \"\$CLAUDE_PLUGIN_ROOT/\" | tr -s /)" "x=\"don't (x)\"" "x=\"\\\"'(x)\"" \
  "# see 'a (b)'" "x=1  # it's (fine)" "echo don\\'t \"(ok)\"" >"$CHECKED_TREE/hooks/clean.sh"
run_release_check
expect_equal '0 []' "$CHECK_EXIT [$CHECK_OUTPUT]"

# ---------------------------------------------------------------- summary

finish
