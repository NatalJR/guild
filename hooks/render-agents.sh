#!/bin/sh
set -u

MODELS='haiku sonnet opus fable inherit'
EFFORTS='low medium high xhigh max'
TR_BACKSLASH=$(printf '\134\134')

option_value() {
  if [ "$2" = model ]; then model_option "$1"; else effort_option "$1"; fi
}

model_option() {
  [ "$1" != investigator ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_INVESTIGATOR_MODEL:-}"
  [ "$1" != builder ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_BUILDER_MODEL:-}"
  [ "$1" != architect ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_ARCHITECT_MODEL:-}"
  [ "$1" != reviewer ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_REVIEWER_MODEL:-}"
  [ "$1" != security ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SECURITY_MODEL:-}"
  [ "$1" != scribe ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SCRIBE_MODEL:-}"
}

effort_option() {
  [ "$1" != investigator ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_INVESTIGATOR_EFFORT:-}"
  [ "$1" != builder ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_BUILDER_EFFORT:-}"
  [ "$1" != architect ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_ARCHITECT_EFFORT:-}"
  [ "$1" != reviewer ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_REVIEWER_EFFORT:-}"
  [ "$1" != security ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SECURITY_EFFORT:-}"
  [ "$1" != scribe ] || printf '%s' "${CLAUDE_PLUGIN_OPTION_SCRIBE_EFFORT:-}"
}

is_allowed() {
  [ -n "$1" ] || return 1
  [ "${1%%[!a-z]*}" = "$1" ] || return 1
  allowed_list=" $2 "
  allowed_rest=${allowed_list#*" $1 "}
  [ "$allowed_rest" != "$allowed_list" ]
}

frontmatter_value() {
  sed -n "1,/^---\$/s/^$2: *//p" "$1" | head -n 1 | tr -d '\r'
}

wanted_value() {
  wanted_option=$(option_value "$1" "$2")
  if [ -n "$3" ] && is_allowed "$wanted_option" "$4"; then
    printf '%s' "$wanted_option"
  else
    printf '%s' "$3"
  fi
}

has_frontmatter() {
  first_line=$(head -n 1 "$1" | tr -d '\r')
  [ "$first_line" = '---' ]
}

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

render_setting() {
  current_value=$(frontmatter_value "$agent_file" "$2")
  rendered_value=$(wanted_value "$1" "$2" "$current_value" "$3")
  [ "$rendered_value" != "$current_value" ] || return 0
  rewrite_frontmatter "$agent_file" "$2" "$rendered_value" || return 1
  agent_changed=yes
}

rewrite_frontmatter() {
  rewrite_temp="$1.render"
  sed "1,/^---\$/s/^$2:.*\$/$2: $3/" "$1" >"$rewrite_temp" && mv -f "$rewrite_temp" "$1" && return 0
  rm -f "$rewrite_temp"
  return 1
}

main() {
  plugin_root=$(printf '%s' "$CLAUDE_PLUGIN_ROOT/" | tr "$TR_BACKSLASH" '/')
  plugin_root=${plugin_root%/}
  [ -n "$plugin_root" ] || return 0
  [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || return 0
  agents_dir="$plugin_root/agents"
  RENDERED=''
  for agent in investigator builder architect reviewer security scribe; do
    render_agent "$agent" || continue
  done
  [ -n "$RENDERED" ] || return 0
  printf 'GUILD AGENTS RENDERED: %s. Run the reload-plugins command to apply.\n' "$RENDERED"
}

(main) 2>/dev/null
exit 0
