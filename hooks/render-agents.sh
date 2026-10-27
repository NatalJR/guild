#!/bin/sh
# SessionStart and UserPromptSubmit hook: renders the per-agent plugin options (install prompt or
# /config) into the agent frontmatter. For each agent, CLAUDE_PLUGIN_OPTION_<AGENT>_MODEL and
# CLAUDE_PLUGIN_OPTION_<AGENT>_EFFORT, when set to an allowlisted value that differs from the
# `model:` / `effort:` line of ${CLAUDE_PLUGIN_ROOT}/agents/<agent>.md, replace that line in
# place; nothing else in the file changes. Unset or invalid values are ignored. Prints one notice
# line only when a file changed (the harness injects stdout as context), listing the agents
# rendered. Writes only inside agents/. An agent whose rewrite fails is skipped and the others
# still render; any other internal error prints nothing. Always exits 0 (never blocks a session
# or a prompt).
set -u

MODELS='haiku sonnet opus fable inherit'
EFFORTS='low medium high xhigh max'

# OPTION: prints the plugin option for OPTION (<agent>_model or <agent>_effort), empty when unset.
option_value() {
  case "$1" in
    investigator_model) printf '%s' "${CLAUDE_PLUGIN_OPTION_INVESTIGATOR_MODEL:-}" ;;
    investigator_effort) printf '%s' "${CLAUDE_PLUGIN_OPTION_INVESTIGATOR_EFFORT:-}" ;;
    builder_model) printf '%s' "${CLAUDE_PLUGIN_OPTION_BUILDER_MODEL:-}" ;;
    builder_effort) printf '%s' "${CLAUDE_PLUGIN_OPTION_BUILDER_EFFORT:-}" ;;
    architect_model) printf '%s' "${CLAUDE_PLUGIN_OPTION_ARCHITECT_MODEL:-}" ;;
    architect_effort) printf '%s' "${CLAUDE_PLUGIN_OPTION_ARCHITECT_EFFORT:-}" ;;
    reviewer_model) printf '%s' "${CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL:-}" ;;
    reviewer_effort) printf '%s' "${CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT:-}" ;;
    security_model) printf '%s' "${CLAUDE_PLUGIN_OPTION_SECURITY_MODEL:-}" ;;
    security_effort) printf '%s' "${CLAUDE_PLUGIN_OPTION_SECURITY_EFFORT:-}" ;;
    scribe_model) printf '%s' "${CLAUDE_PLUGIN_OPTION_SCRIBE_MODEL:-}" ;;
    scribe_effort) printf '%s' "${CLAUDE_PLUGIN_OPTION_SCRIBE_EFFORT:-}" ;;
  esac
}

# VALUE ALLOWED: succeeds when VALUE is one word of the space-separated ALLOWED list.
is_allowed() {
  case "$1" in '' | *[!a-z]*) return 1 ;; esac
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# FILE KEY: prints the value of the first `KEY:` line of the frontmatter, empty when absent.
frontmatter_value() {
  sed -n "1,/^---\$/s/^$2: *//p" "$1" | head -n 1 | tr -d '\r'
}

# OPTION CURRENT ALLOWED: prints the option value when allowed and CURRENT exists, else CURRENT.
wanted_value() {
  wanted_option=$(option_value "$1")
  if [ -n "$2" ] && is_allowed "$wanted_option" "$3"; then
    printf '%s' "$wanted_option"
  else
    printf '%s' "$2"
  fi
}

# AGENT: rewrites agents/AGENT.md when an option differs; appends the change to RENDERED.
# Returns 1 when a rewrite fails, leaving RENDERED as it was.
render_agent() {
  agent_file="$agents_dir/$1.md"
  [ -f "$agent_file" ] || return 0
  [ "$(head -n 1 "$agent_file" | tr -d '\r')" = '---' ] || return 0
  agent_changed=''
  render_key "$1" model "$MODELS" || return 1
  rendered_model=$rendered_value
  render_key "$1" effort "$EFFORTS" || return 1
  [ -n "$agent_changed" ] || return 0
  RENDERED="$RENDERED${RENDERED:+; }$1 model=$rendered_model effort=$rendered_value"
}

# AGENT KEY ALLOWED: sets rendered_value to the wanted KEY value and, when it differs from the
# file, rewrites the KEY line and sets agent_changed; returns 1 when the rewrite fails.
render_key() {
  current_value=$(frontmatter_value "$agent_file" "$2")
  rendered_value=$(wanted_value "$1_$2" "$current_value" "$3")
  [ "$rendered_value" != "$current_value" ] || return 0
  rewrite_frontmatter "$agent_file" "$2" "$rendered_value" || return 1
  agent_changed=yes
}

# FILE KEY VALUE: replaces the frontmatter `KEY:` line through a sibling temp file. KEY is
# model or effort and VALUE an allowlisted lowercase word, so both are safe in the sed script.
rewrite_frontmatter() {
  rewrite_temp="$1.render"
  sed "1,/^---\$/s/^$2:.*\$/$2: $3/" "$1" >"$rewrite_temp" && mv -f "$rewrite_temp" "$1" && return 0
  rm -f "$rewrite_temp"
  return 1
}

main() {
  plugin_root=$(printf '%s' "$CLAUDE_PLUGIN_ROOT" | sed 's|\\|/|g')
  [ -n "$plugin_root" ] || return 0
  agents_dir="$plugin_root/agents"
  RENDERED=''
  for agent in investigator builder architect reviewer security scribe; do
    # A failing agent is skipped; the others still render.
    render_agent "$agent" || continue
  done
  [ -n "$RENDERED" ] || return 0
  printf 'GUILD AGENTS RENDERED: %s. Run /reload-plugins to apply.\n' "$RENDERED"
}

(main) 2>/dev/null
exit 0
