#!/bin/sh
# Hook contract suite: pipes JSON payloads into the hooks and asserts exit codes, stderr and
# stdout. POSIX sh with no dependencies; runs as `sh tests/run.sh` under Git Bash's sh and
# under dash from the same checkout (every path is derived from this script's location).
# Fixtures under tests/fixtures/** contain emoji bytes on purpose (emoji-scan cases); the
# repository no-emoji rule exempts that directory. Cases needing a switch override write a
# temporary guild.conf into a scratch HOME or project directory, never into the fixtures.
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
unset GUILD_HOOK_TRACE

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

PASSED=0
FAILED=0
CASE=''
SCRATCH_SEQUENCE=0

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

# HOOK [ARG...]
expect_stdout_empty() {
  run_context "$@"
  [ -z "$RUN_STDOUT" ] && [ "$RUN_EXIT" = 0 ] || { fail "exit $RUN_EXIT; stdout not empty: $(printf '%s\n' "$RUN_STDOUT" | head -n 2)"; return 0; }
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

# LIMIT HOOK [ARG...]: stdout byte count stays under LIMIT.
expect_stdout_under() {
  size_limit=$1
  shift
  run_context "$@"
  printf '%s\n' "$RUN_STDOUT" >"$SCRATCH/size"
  stdout_size=$(($(wc -c <"$SCRATCH/size")))
  [ "$stdout_size" -lt "$size_limit" ] || { fail "stdout is $stdout_size bytes, limit $size_limit"; return 0; }
  pass
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
  unset GUILD_HOOK_TRACE
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

bash_payload() {
  printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"d"}}' "$1"
}

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

NL='
'
TAB=$(printf '\t')

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

# ---------------------------------------------------------------- deny-attribution

describe 'deny-attribution: plain commit allowed'
expect_exit deny-attribution.sh 0 "$(bash_payload 'git commit -m \"fix: handle empty input\"')"
describe 'deny-attribution: commit with Co-Authored-By blocked'
expect_exit deny-attribution.sh 2 "$(bash_payload 'git commit -m \"fix: x\n\nCo-Authored-By: Someone <a@b.c>\"')" 'BLOCKED: AI attribution in a git artifact is forbidden'
describe 'deny-attribution: gh pr create with Generated with blocked'
expect_exit deny-attribution.sh 2 "$(bash_payload 'gh pr create --title t --body \"Generated with a tool\"')" 'BLOCKED'
describe 'deny-attribution: echo with Claude Code allowed'
expect_exit deny-attribution.sh 0 "$(bash_payload 'echo \"Claude Code\"')"
describe 'deny-attribution: gh pr edit with Anthropic blocked'
expect_exit deny-attribution.sh 2 "$(bash_payload 'gh pr edit 4 --body \"thanks Anthropic\"')" 'BLOCKED'
describe 'deny-attribution: case-insensitive match'
expect_exit deny-attribution.sh 2 "$(bash_payload 'GIT COMMIT -m \"co-authored-by: x\"')" 'BLOCKED'
describe 'deny-attribution: command split across lines still counts'
expect_exit deny-attribution.sh 2 "$(bash_payload 'git\ncommit -m \"x noreply@anthropic.com\"')" 'BLOCKED'
describe 'deny-attribution: malformed payload allowed'
expect_exit deny-attribution.sh 0 'not json {"command":'
describe 'deny-attribution: empty payload allowed'
expect_exit deny-attribution.sh 0 ''
describe 'deny-attribution: switch off allows'
use_user_conf 'hooks.deny_attribution = off'
expect_exit deny-attribution.sh 0 "$(bash_payload 'git commit -m \"Co-Authored-By: x\"')"
reset_env

# ---------------------------------------------------------------- emoji-scan

describe 'emoji-scan: clean file allowed'
expect_exit emoji-scan.sh 0 "$(file_payload "$FIXTURE_PROJECT/clean.md")"
describe 'emoji-scan: emoji blocked at line 3'
expect_exit emoji-scan.sh 2 "$(file_payload "$FIXTURE_PROJECT/emoji.md")" 'emoji.md at line 3 (first hit)'
describe 'emoji-scan: png skipped'
expect_exit emoji-scan.sh 0 "$(file_payload "$FIXTURE_PROJECT/image.png")"
describe 'emoji-scan: file outside the project skipped'
expect_exit emoji-scan.sh 0 "$(file_payload "$FIXTURES/outside/outside.md")"
describe 'emoji-scan: dot-dot path leaving the project skipped'
expect_exit emoji-scan.sh 0 "$(file_payload "$FIXTURE_PROJECT/../outside/outside.md")"
describe 'emoji-scan: missing file skipped'
expect_exit emoji-scan.sh 0 "$(file_payload "$FIXTURE_PROJECT/missing.md")"
describe 'emoji-scan: empty path skipped'
expect_exit emoji-scan.sh 0 "$(file_payload '')"
describe 'emoji-scan: payload without file_path skipped'
expect_exit emoji-scan.sh 0 '{"tool_input":{"content":"x"}}'
describe 'emoji-scan: no project dir scans anywhere'
unset CLAUDE_PROJECT_DIR
expect_exit emoji-scan.sh 2 "$(file_payload "$FIXTURES/outside/outside.md")" 'line 3'
reset_env
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

describe 'emoji-scan: switch off in user conf allows the emoji file'
use_user_conf 'hooks.emoji_scan = off'
expect_exit emoji-scan.sh 0 "$(file_payload "$FIXTURE_PROJECT/emoji.md")"
describe 'emoji-scan: project conf turns the user-disabled scan back on'
use_project_conf 'hooks.emoji_scan = on'
expect_exit emoji-scan.sh 2 "$(file_payload "$CLAUDE_PROJECT_DIR/emoji.md")" 'line 3'
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

describe 'receipt-check: non-guild agent allowed'
expect_exit receipt-check.sh 0 "$(receipt_payload general-purpose 'I looked around and here is prose.')"
describe 'receipt-check: verified: allowed'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:builder 'verified: build OK\nsrc/a.ts:1-9 change')"
describe 'receipt-check: path:line row allowed'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:investigator 'src/app/main.ts:12 defines run')"
describe 'receipt-check: No issues. allowed'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:reviewer 'No issues.')"
describe 'receipt-check: N findings. allowed'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:reviewer '3 findings.\n1. x')"
describe 'receipt-check: token match is case-insensitive'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:builder 'VERIFIED: ok')"
describe 'receipt-check: prose blocked with excerpt'
expect_exit receipt-check.sh 2 "$(receipt_payload guild:builder 'I finished the work.\nverified: ok')" 'Got: "I finished the work.". Rewrite'
describe 'receipt-check: agent type match is case-insensitive'
expect_exit receipt-check.sh 2 "$(receipt_payload GUILD:Builder 'Done, all good.')" 'Receipt contract'
describe 'receipt-check: stop_hook_active true allowed'
expect_exit receipt-check.sh 0 '{"agent_type":"guild:builder","stop_hook_active":true,"last_assistant_message":"prose"}'
describe 'receipt-check: escaped newlines resolved before the first line'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:builder '\n\n  \r\n  plan: 3 files\nmore')"
describe 'receipt-check: message absent allowed'
expect_exit receipt-check.sh 0 '{"agent_type":"guild:builder","stop_hook_active":false}'
describe 'receipt-check: blank message allowed'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:builder '\n   \n')"
describe 'receipt-check: malformed payload allowed'
expect_exit receipt-check.sh 0 '{"agent_type":"guild:builder","last_assistant_message":"unterminated'
describe 'receipt-check: excerpt capped at 80 characters'
long_line='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
expect_exit receipt-check.sh 2 "$(receipt_payload guild:builder "$long_line")" "Got: \"$(printf '%s' "$long_line" | cut -c 1-80)\"."

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

describe 'receipt-check: switch off allows'
use_user_conf 'hooks.receipt_check = off'
expect_exit receipt-check.sh 0 "$(receipt_payload guild:builder 'prose')"
reset_env

# ---------------------------------------------------------------- config

describe 'config: fixture project carries no guild.conf'
expect_equal 'absent' "$([ -e "$FIXTURE_PROJECT/.claude/guild.conf" ] && printf present || printf absent)"
describe 'config: defaults declare fifteen keys, all on'
expect_equal '15' "$(config_query count_on_switches)"
describe 'config: defaults all on'
expect_equal '' "$(config_query guild_disabled_keys)"
describe 'config: user conf turns a switch off'
use_user_conf 'hooks.emoji_scan = off'
expect_equal 'off' "$(switch_state hooks.emoji_scan)"
describe 'config: project conf overrides user conf'
use_project_conf 'hooks.emoji_scan = on'
expect_equal 'on' "$(switch_state hooks.emoji_scan)"
reset_env
describe 'config: unknown key ignored'
use_user_conf 'hooks.not_a_switch = off'
expect_equal '' "$(config_query guild_disabled_keys)"
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
expect_equal 'review.norms' "$(config_query guild_disabled_keys)"
reset_env
describe 'config: values are case-insensitive'
use_user_conf "review.security = OFF
docs.sync = False
style.terse = YES"
expect_equal 'docs.sync review.security' "$(config_query guild_disabled_keys)"
reset_env
describe 'config: CRLF line endings'
new_scratch_dir
printf 'review.security = off\r\nhooks.emoji_scan = off\r\n' >"$SCRATCH_DIR/.claude/guild.conf"
HOME=$SCRATCH_DIR
expect_equal 'hooks.emoji_scan review.security' "$(config_query guild_disabled_keys)"
reset_env
describe 'config: guild_disabled_keys sorted and space separated'
use_user_conf "style.terse = off
docs.sync = off
hooks.receipt_check = off"
expect_equal 'docs.sync hooks.receipt_check style.terse' "$(config_query guild_disabled_keys)"
reset_env
describe 'config: missing defaults file never disables anything'
new_scratch_dir
CLAUDE_PLUGIN_ROOT=$SCRATCH_DIR
use_user_conf 'review.security = off'
expect_equal 'on' "$(switch_state review.security)"
reset_env
describe 'config: unset CLAUDE_PLUGIN_ROOT derives the root from the sourcing script'
use_user_conf 'review.security = off'
unset CLAUDE_PLUGIN_ROOT
expect_equal 'review.security' "$(config_query guild_disabled_keys)"
reset_env

# ---------------------------------------------------------------- session-context

describe 'session-context: always-on has Reply style by default'
expect_stdout_contains '## Reply style' session-context.sh context/always-on.md
describe 'session-context: always-on carries the length budget'
expect_stdout_contains '- Length budget: a status update is at most six lines.' session-context.sh context/always-on.md
describe 'session-context: no switches-off section by default'
expect_stdout_lacks '## Guild switches off' session-context.sh context/always-on.md
describe 'session-context: always-on default has no marker lines'
expect_stdout_lacks '{{' session-context.sh context/always-on.md
describe 'session-context: style.terse off drops Reply style'
use_user_conf 'style.terse = off'
expect_stdout_lacks '## Reply style' session-context.sh context/always-on.md
describe 'session-context: style.terse off keeps Delegation'
expect_stdout_contains '## Delegation' session-context.sh context/always-on.md
describe 'session-context: switches-off section lists the off key'
expect_stdout_contains "## Guild switches off${NL}${NL}style.terse" session-context.sh context/always-on.md
reset_env
describe 'session-context: rules.universal off drops Universal code rules'
use_user_conf 'rules.universal = off'
expect_stdout_lacks '## Universal code rules' session-context.sh context/always-on.md
reset_env
describe 'session-context: switches-off keys are comma separated'
use_user_conf "style.terse = off
review.security = off"
expect_stdout_contains 'review.security, style.terse' session-context.sh context/always-on.md
reset_env
describe 'session-context: switches-off section only on the always-on part'
use_user_conf 'review.security = off'
expect_stdout_lacks '## Guild switches off' session-context.sh context/procedure.md
reset_env

describe 'session-context: procedure has no marker lines'
expect_stdout_lacks '{{' session-context.sh context/procedure.md
describe 'session-context: PLUGIN_ROOT replaced with a forward-slash path'
expect_stdout_contains "$REPO_ROOT/skills/guild/DAG.md" session-context.sh context/procedure.md
describe 'session-context: no PLUGIN_ROOT placeholder survives'
expect_stdout_lacks '{{PLUGIN_ROOT}}' session-context.sh context/procedure.md
describe 'session-context: procedure has Step 3a by default'
expect_stdout_contains '### Step 3a: Design gate' session-context.sh context/procedure.md
describe 'session-context: rendered procedure under 9000 bytes'
expect_stdout_under 9000 session-context.sh context/procedure.md
describe 'session-context: procedure empty when procedure.default_mode off'
use_user_conf 'procedure.default_mode = off'
expect_stdout_empty session-context.sh context/procedure.md
describe 'session-context: always-on still printed when procedure.default_mode off'
expect_stdout_contains 'procedure.default_mode' session-context.sh context/always-on.md
reset_env
describe 'session-context: Step 3a absent when procedure.design_gate off'
use_user_conf 'procedure.design_gate = off'
expect_stdout_lacks '### Step 3a' session-context.sh context/procedure.md
describe 'session-context: Step 4 still follows when Step 3a is dropped'
expect_stdout_contains "all in one message.${NL}${NL}### Step 4" session-context.sh context/procedure.md
reset_env
describe 'session-context: site-map rule sits between the architect route and its prompt contents'
expect_stdout_contains "\`guild:architect\`.${NL}  NEVER dispatch without an investigator site map." session-context.sh context/procedure.md
describe 'session-context: investigate_first off drops the site-map rule'
use_user_conf 'procedure.investigate_first = off'
expect_stdout_lacks 'NEVER dispatch without an investigator site map' session-context.sh context/procedure.md
describe 'session-context: investigate_first off keeps the architect prompt contents'
expect_stdout_contains "\`guild:architect\`.${NL}  Prompt gets: task spec" session-context.sh context/procedure.md
reset_env
describe 'session-context: sharding off drops the shard rule'
use_user_conf 'procedure.sharding = off'
expect_stdout_lacks 'shard into parallel slices' session-context.sh context/procedure.md
reset_env
describe 'session-context: review switches off keep the verdict paragraph'
use_user_conf "review.norms = off
review.correctness = off
review.security = off"
expect_stdout_contains 'Verdicts:' session-context.sh context/procedure.md
describe 'session-context: review switches off drop the three dimensions'
expect_stdout_lacks '**Norms/structure**' session-context.sh context/procedure.md
reset_env
describe 'session-context: cleanup_pass off drops the cleanup section and route'
use_user_conf 'procedure.cleanup_pass = off'
expect_stdout_lacks 'Cleanup pass' session-context.sh context/procedure.md
describe 'session-context: cleanup_pass off keeps docs sync'
expect_stdout_contains 'Then DAG.md `## Docs sync`.' session-context.sh context/procedure.md
reset_env
describe 'session-context: docs.sync off drops the docs sync line'
use_user_conf 'docs.sync = off'
expect_stdout_lacks '## Docs sync' session-context.sh context/procedure.md
reset_env
describe 'session-context: every switch off leaves no marker lines'
use_user_conf "$(sed -n 's/= on$/= off/p' "$REPO_ROOT/config/defaults.conf")"
expect_stdout_lacks '{{' session-context.sh context/always-on.md
describe 'session-context: every switch off except default_mode leaves no marker lines in the procedure'
use_user_conf "$(sed -n -e '/procedure.default_mode/d' -e 's/= on$/= off/p' "$REPO_ROOT/config/defaults.conf")"
expect_stdout_lacks '{{' session-context.sh context/procedure.md
reset_env
describe 'session-context: missing part prints nothing'
expect_stdout_empty session-context.sh context/missing.md
describe 'session-context: unset CLAUDE_PLUGIN_ROOT derives the root'
unset CLAUDE_PLUGIN_ROOT
expect_stdout_contains '/skills/guild/DAG.md' session-context.sh context/procedure.md
reset_env
if [ -n "$WINDOWS_ROOT_BACKSLASH" ]; then
  describe 'session-context: backslash plugin root rendered with forward slashes (Git Bash only)'
  CLAUDE_PLUGIN_ROOT=$WINDOWS_ROOT_BACKSLASH
  expect_stdout_contains "$WINDOWS_ROOT_FORWARD/skills/guild/DAG.md" session-context.sh context/procedure.md
  reset_env
fi

# ---------------------------------------------------------------- prompt-reinforce, size check

describe 'prompt-reinforce: prints exactly the reinforcement line'
run_context prompt-reinforce.sh
expect_equal 'GUILD DEFAULT MODE: replies at most six lines, universal code rules, coding requests walk the operating procedure in session context (no slash command).' "$RUN_STDOUT"
describe 'prompt-reinforce: switch off prints nothing'
use_user_conf 'hooks.prompt_reinforce = off'
expect_stdout_empty prompt-reinforce.sh
reset_env

describe 'check-context-size: every part under the limit'
expect_exit check-context-size.sh 0 ''

# ---------------------------------------------------------------- hooks.json wiring

# Prints every hooks/<name>.sh that a hooks.json command names, one per line.
hooks_json_scripts() {
  sed -n 's|.*/hooks/\([A-Za-z0-9_-]*\.sh\).*|\1|p' "$HOOKS/hooks.json"
}

describe 'hooks.json: every command runs an existing sh script'
missing_scripts=$(hooks_json_scripts | while IFS= read -r wired_script; do
  [ -f "$HOOKS/$wired_script" ] || printf '%s\n' "$wired_script"
done)
expect_equal '' "$missing_scripts"
describe 'hooks.json: six script references found'
expect_equal '6' "$(($(hooks_json_scripts | wc -l)))"
describe 'hooks.json: six commands, all through sh'
expect_equal '6 6' "$(grep -c '"command":' "$HOOKS/hooks.json") $(grep -c '"command": "sh \\"' "$HOOKS/hooks.json")"
describe 'hooks.json: no PowerShell left'
expect_equal '0' "$(grep -c -i -E 'pwsh|\.ps1' "$HOOKS/hooks.json")"

# ---------------------------------------------------------------- summary

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
