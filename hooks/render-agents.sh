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
# The Claude Directory validator cannot read `case` statements, so every match is a `[ ]` test.
set -u

MODELS='haiku sonnet opus fable inherit'
EFFORTS='low medium high xhigh max'

# AGENT SETTING: prints the plugin option for the agent's SETTING (model or effort), empty when
# unset.
option_value() {
  if [ "$2" = model ]; then model_option "$1"; else effort_option "$1"; fi
}

# AGENT: prints CLAUDE_PLUGIN_OPTION_<AGENT>_MODEL, empty when unset.
model_option() {
  [ "$1" != investigator ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_INVESTIGATOR_MODEL:-}"
  [ "$1" != builder ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_BUILDER_MODEL:-}"
  [ "$1" != architect ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_ARCHITECT_MODEL:-}"
  [ "$1" != reviewer ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL:-}"
  [ "$1" != security ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SECURITY_MODEL:-}"
  [ "$1" != scribe ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SCRIBE_MODEL:-}"
}

# AGENT: prints CLAUDE_PLUGIN_OPTION_<AGENT>_EFFORT, empty when unset.
effort_option() {
  [ "$1" != investigator ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_INVESTIGATOR_EFFORT:-}"
  [ "$1" != builder ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_BUILDER_EFFORT:-}"
  [ "$1" != architect ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_ARCHITECT_EFFORT:-}"
  [ "$1" != reviewer ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT:-}"
  [ "$1" != security ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SECURITY_EFFORT:-}"
  [ "$1" != scribe ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SCRIBE_EFFORT:-}"
}

# VALUE ALLOWED: succeeds when VALUE is one lowercase word of the space-separated ALLOWED list.
is_allowed() {
  [ -n "$1" ] || return 1
  [ "${1%%[!a-z]*}" = "$1" ] || return 1
  allowed_list=" $2 "
  allowed_rest=${allowed_list#*" $1 "}
  [ "$allowed_rest" != "$allowed_list" ]
}

# FILE SETTING: prints the value of the first `SETTING:` line of the frontmatter, empty when absent.
frontmatter_value() {
  sed -n "1,/^---\$/s/^$2: *//p" "$1" | head -n 1 | tr -d '\r'
}

# AGENT SETTING CURRENT ALLOWED: prints the option value when allowed and CURRENT exists, else
# CURRENT.
wanted_value() {
  wanted_option=$(option_value "$1" "$2")
  if [ -n "$3" ] && is_allowed "$wanted_option" "$4"; then
    printf '%s' "$wanted_option"
  else
    printf '%s' "$3"
  fi
}

# FILE: succeeds when the first line of FILE opens a frontmatter block.
has_frontmatter() {
  first_line=$(head -n 1 "$1" | tr -d '\r')
  [ "$first_line" = '---' ]
}

# AGENT: rewrites agents/AGENT.md when an option differs; appends the change to RENDERED.
# Returns 1 when a rewrite fails, leaving RENDERED as it was.
render_agent() {
  agent_file="$agents_dir/$1.md"
  [ -f "$agent_file" ] || return 0
  has_frontmatter "$agent_file" || return 0
  agent_changed=''
  render_setting "$1" model "$MODELS" || return 1
  rendered_model=$rendered_value
  render_setting "$1" effort "$EFFORTS" || return 1
  [ -n "$agent_changed" ] || return 0
  RENDERED="$RENDERED${RENDERED:+; }$1 model=$rendered_model effort=$rendered_value"
}

# AGENT SETTING ALLOWED: sets rendered_value to the wanted SETTING value and, when it differs
# from the file, rewrites the SETTING line and sets agent_changed; returns 1 when the rewrite
# fails.
render_setting() {
  current_value=$(frontmatter_value "$agent_file" "$2")
  rendered_value=$(wanted_value "$1" "$2" "$current_value" "$3")
  [ "$rendered_value" != "$current_value" ] || return 0
  rewrite_frontmatter "$agent_file" "$2" "$rendered_value" || return 1
  agent_changed=yes
}

# FILE SETTING VALUE: replaces the frontmatter `SETTING:` line through a sibling temp file.
# SETTING is model or effort and VALUE an allowlisted lowercase word, so both are safe in the
# sed script.
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
