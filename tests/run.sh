#!/bin/sh
# Hook contract suite: pipes JSON payloads into the hooks and asserts exit codes, stderr and
# stdout. POSIX sh with no dependencies; runs as `sh tests/run.sh` under Git Bash's sh and
# under dash from the same checkout (every path is derived from this script's location).
# The payload-driven cases live in tests/cases/*.cases (format at the top of each file) and are
# shared with tests/run.ps1, which runs them against the PowerShell twins; the cases that need
# code (scratch roots, crafted bytes, library calls, config queries) stay below, and the ones
# that exercise a twin are written in both runners.
# Fixtures under tests/fixtures/** contain emoji bytes on purpose (emoji-scan cases); the
# repository no-emoji rule exempts that directory. Cases needing a switch override write a
# temporary guild.conf into a scratch HOME or project directory (never into the fixtures) or
# export CLAUDE_PLUGIN_OPTION_GIT_HANDLING; reset_env clears both.
set -u

case "$0" in
  */*) tests_dir=${0%/*} ;;
  *) tests_dir=. ;;
esac
TESTS_DIR=$(CDPATH='' cd -- "$tests_dir" && pwd) || exit 1
REPO_ROOT=$(CDPATH='' cd -- "$TESTS_DIR/.." && pwd) || exit 1
HOOKS="$REPO_ROOT/hooks"
FIXTURES="$TESTS_DIR/fixtures"
FIXTURE_PROJECT="$FIXTURES/project"
FIXTURE_HOME="$FIXTURES/home"

CLAUDE_PLUGIN_ROOT=$REPO_ROOT
CLAUDE_PROJECT_DIR=$FIXTURE_PROJECT
HOME=$FIXTURE_HOME
export CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR HOME
unset GUILD_HOOK_TRACE CLAUDE_PLUGIN_OPTION_GIT_HANDLING

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
  apply_case_lines set "$CASE_ENV" && apply_case_lines unset "$CASE_UNSET"
}

case_scratch_dir() {
  CASE_DIR="$SCRATCH/shared$CASE_SEQUENCE-$1"
  mkdir -p "$CASE_DIR/.claude"
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
  replace_all "$REPLACED" '%ROOT%' "$REPO_ROOT"
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

reset_env() {
  CLAUDE_PLUGIN_ROOT=$REPO_ROOT
  CLAUDE_PROJECT_DIR=$FIXTURE_PROJECT
  HOME=$FIXTURE_HOME
  export CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR
  unset GUILD_HOOK_TRACE CLAUDE_PLUGIN_OPTION_GIT_HANDLING
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
    . "$HOOKS/lib/payload.sh"
    PAYLOAD=$1
    payload_field "$2" || printf '<absent>'
  )
}

bool_of() {
  (
    . "$HOOKS/lib/payload.sh"
    PAYLOAD=$1
    if payload_bool "$2"; then printf 'true'; else printf 'false'; fi
  )
}

first_line_of() {
  (
    . "$HOOKS/lib/payload.sh"
    payload_first_line "$1"
  )
}

config_query() {
  (
    . "$HOOKS/lib/config.sh"
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
expect_exit emoji-scan.sh 2 "$(file_payload "$SCRATCH_DIR/nul.md")" 'nul.md at line 3 (first hit)'
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

describe 'receipt-check: GUILD_HOOK_TRACE records timestamp and payload excerpt'
GUILD_HOOK_TRACE="$SCRATCH/trace.log"
export GUILD_HOOK_TRACE
run_hook receipt-check.sh "$(receipt_payload guild:builder 'verified: ok')"
trace_text=$(cat "$GUILD_HOOK_TRACE" 2>/dev/null)
if contains "$trace_text" 'SubagentStop' && contains "$trace_text" '"agent_type":"guild:builder"'; then pass; else fail "trace: $trace_text"; fi
reset_env

# ---------------------------------------------------------------- config

describe 'config: fixture project carries no guild.conf'
expect_equal 'absent' "$([ -e "$FIXTURE_PROJECT/.claude/guild.conf" ] && printf present || printf absent)"
describe 'config: defaults declare fifteen keys, fourteen on'
expect_equal '14' "$(config_query count_on_switches)"
describe 'config: shipped defaults report no changed keys'
expect_equal '' "$(config_query guild_changed_keys)"
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
expect_equal '' "$(config_query guild_changed_keys)"
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
expect_equal 'review.norms=off' "$(config_query guild_changed_keys)"
reset_env
describe 'config: values are case-insensitive'
use_user_conf "review.security = OFF
docs.sync = False
style.terse = YES"
expect_equal 'docs.sync=off review.security=off' "$(config_query guild_changed_keys)"
reset_env
describe 'config: CRLF line endings'
new_scratch_dir
printf 'review.security = off\r\nhooks.emoji_scan = off\r\n' >"$SCRATCH_DIR/.claude/guild.conf"
HOME=$SCRATCH_DIR
expect_equal 'hooks.emoji_scan=off review.security=off' "$(config_query guild_changed_keys)"
reset_env
describe 'config: guild_changed_keys sorted and space separated'
use_user_conf "style.terse = off
git.handling = on
docs.sync = off
hooks.receipt_check = off"
expect_equal 'docs.sync=off git.handling=on hooks.receipt_check=off style.terse=off' "$(config_query guild_changed_keys)"
reset_env
describe 'config: a key set to its shipped default is not reported as changed'
use_user_conf "git.handling = off
review.security = on"
expect_equal '' "$(config_query guild_changed_keys)"
reset_env
describe 'config: missing defaults file never disables anything'
new_scratch_dir
CLAUDE_PLUGIN_ROOT=$SCRATCH_DIR
use_user_conf 'review.security = off'
expect_equal 'on' "$(switch_state review.security)"
describe 'config: missing defaults file keeps git.handling off'
expect_equal 'off' "$(switch_state git.handling)"
describe 'config: missing defaults file reports no changed keys'
expect_equal '' "$(config_query guild_changed_keys)"
describe 'config: missing defaults file, plugin option true turns git.handling on'
CLAUDE_PLUGIN_OPTION_GIT_HANDLING=true
export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
expect_equal 'on' "$(switch_state git.handling)"
describe 'config: missing defaults file, plugin option true reports git.handling=on'
expect_equal 'git.handling=on' "$(config_query guild_changed_keys)"
reset_env
describe 'config: unset CLAUDE_PLUGIN_ROOT derives the root from the sourcing script'
use_user_conf 'review.security = off'
unset CLAUDE_PLUGIN_ROOT
expect_equal 'review.security=off' "$(config_query guild_changed_keys)"
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
describe 'config: git.handling on in the project conf applies when the plugin option is unset'
use_project_conf 'git.handling = on'
expect_equal 'on' "$(switch_state git.handling)"
describe 'config: plugin option false wins over the project conf'
CLAUDE_PLUGIN_OPTION_GIT_HANDLING=false
export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
expect_equal 'off' "$(switch_state git.handling)"
reset_env
describe 'config: plugin option true wins over the user conf'
use_user_conf 'git.handling = off'
CLAUDE_PLUGIN_OPTION_GIT_HANDLING=true
export CLAUDE_PLUGIN_OPTION_GIT_HANDLING
expect_equal 'on' "$(switch_state git.handling)"
describe 'config: plugin option sets git.handling only'
expect_equal 'git.handling=on' "$(config_query guild_changed_keys)"
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
use_user_conf "$(sed -n 's/= off$/= on/p' "$REPO_ROOT/config/defaults.conf")"
expect_stdout_lacks '{{' session-context.sh context/procedure.md
reset_env

# Points CLAUDE_PLUGIN_ROOT at a scratch root whose context/markers.md holds a plain and a
# negated block on the same switch.
use_marker_root() {
  new_scratch_dir
  mkdir -p "$SCRATCH_DIR/config" "$SCRATCH_DIR/context"
  cp "$REPO_ROOT/config/defaults.conf" "$SCRATCH_DIR/config/defaults.conf"
  printf '%s\n' head '{{#if review.security}}' plain '{{/if}}' '{{#if !review.security}}' negated '{{/if}}' tail >"$SCRATCH_DIR/context/markers.md"
  CLAUDE_PLUGIN_ROOT=$SCRATCH_DIR
}
describe 'session-context: negated block dropped while its switch is on'
use_marker_root
run_context session-context.sh context/markers.md
expect_equal "head${NL}plain${NL}tail" "$RUN_STDOUT"
describe 'session-context: negated block kept while its switch is off'
use_user_conf 'review.security = off'
run_context session-context.sh context/markers.md
expect_equal "head${NL}negated${NL}tail" "$RUN_STDOUT"
reset_env

# ---------------------------------------------------------------- size check

describe 'check-context-size: every part under the limit'
expect_exit check-context-size.sh 0 ''

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
# never reads line 2), line 2 calls the .ps1 twin with the same arguments (PowerShell, where
# exec is not a command, runs it and exits with its status).
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
describe 'hooks.json: six script references found'
expect_equal '6' "$(($(hooks_json_scripts | wc -l)))"
describe 'hooks.json: every command names an existing PowerShell twin'
expect_equal '' "$(hooks_json_twins | missing_hook_files)"
describe 'hooks.json: six commands, all the sh/PowerShell polyglot'
expect_equal '6 6' "$(grep -c '"command":' "$HOOKS/hooks.json") $(count_polyglot_commands)"
describe 'hooks.json: no shell field'
expect_equal '0' "$(grep -c '"shell"' "$HOOKS/hooks.json")"

# ---------------------------------------------------------------- summary

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
