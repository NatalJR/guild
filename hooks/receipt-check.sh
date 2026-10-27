#!/bin/sh
# SubagentStop hook: enforces the receipt contract on a subagent's final message.
# Payload fields (confirmed by live trace): agent_type, last_assistant_message, stop_hook_active.
# Unknown shape -> no-op (exit 0). Switch: hooks.receipt_check.
# A malformed payload or an internal error never blocks.
set -u

RECEIPT_TOKEN_PATTERN='^(plan:|verify:|verified:|docs-sync\.|No issues\.|No match\.|[0-9]+ findings\.|too-big\.|too-small\.|needs-confirm\.|ambiguous\.|regressed\.|need-map\.|blocked\.|not-security\.|security-scope\.|Defs:|Refs:|Callers:|Tests:|Sites:|Imports:)'
LOCATION_PATTERN='^[^[:space:]]+:[0-9]+'
# Internal status meaning "block"; any other status, including a shell error, allows.
BLOCK_STATUS=3

case "$0" in
  */*) hooks_dir=${0%/*} ;;
  *) hooks_dir=. ;;
esac

# Diagnostic: set GUILD_HOOK_TRACE=<file> to log the payload shape;
# used once to confirm which field carries the subagent's final message.
trace_payload() {
  [ -n "${GUILD_HOOK_TRACE:-}" ] || return 0
  {
    printf '%s SubagentStop\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s' "$PAYLOAD" | dd ibs=1 count=200 2>/dev/null
    printf '\n'
  } 2>/dev/null >>"$GUILD_HOOK_TRACE"
}

is_guild_agent() {
  case "$1" in [Gg][Uu][Ii][Ll][Dd]:*) return 0 ;; esac
  return 1
}

# Scope: only guild agents carry the receipt contract, and a stop this hook already
# re-prompted once (stop_hook_active) goes through to avoid a block loop.
in_scope() {
  agent_type=$(payload_field agent_type) || return 1
  is_guild_agent "$agent_type" && ! payload_bool stop_hook_active
}

is_receipt_line() {
  printf '%s\n' "$1" | LC_ALL=C grep -q -i -E -e "$RECEIPT_TOKEN_PATTERN" && return 0
  printf '%s\n' "$1" | LC_ALL=C grep -q -E -e "$LOCATION_PATTERN"
}

reject() {
  excerpt=$(printf '%s\n' "$1" | cut -c 1-80)
  printf 'Receipt contract: your final message must START with a terminal token or a receipt line (plan:, verify:, verified:, docs-sync., No issues., No match., N findings., too-big., too-small., needs-confirm., ambiguous., need-map., blocked., regressed., not-security., security-scope., or a path:line row). Got: "%s". Rewrite your final message with the token on line 1 and stop again.\n' "$excerpt" >&2
  exit "$BLOCK_STATUS"
}

main() {
  . "$hooks_dir/lib/payload.sh"
  . "$hooks_dir/lib/config.sh"
  guild_config_load
  guild_switch hooks.receipt_check || return 0
  payload_read
  trace_payload
  in_scope || return 0
  final_text=$(payload_field last_assistant_message) || return 0
  first_line=$(payload_first_line "$final_text")
  [ -n "$first_line" ] || return 0
  is_receipt_line "$first_line" || reject "$first_line"
}

(main)
[ "$?" -ne "$BLOCK_STATUS" ] || exit 2
exit 0
