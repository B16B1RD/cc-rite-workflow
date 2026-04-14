#!/bin/bash
# rite workflow - Phase Transition Whitelist (#490)
#
# Provides the canonical phase-transition graph used by stop-guard.sh and
# other orchestration helpers to detect silent phase-skipping bugs in
# /rite:issue:start end-to-end flow.
#
# This file is designed to be SOURCED, not executed directly. After sourcing:
#   - `rite_phase_transition_allowed <prev> <next>` — returns 0 if allowed, 1 otherwise
#   - `rite_phase_expected_next <phase>` — prints space-separated list of valid next phases
#   - `rite_phase_is_known <phase>` — returns 0 if the phase name exists in the graph
#
# Overrides may be loaded from rite-config.yml under:
#   hooks:
#     stop_guard:
#       phase_transitions:
#         <phase>: [<next1>, <next2>]
#
# Override semantics: MERGE — listed targets are APPENDED to the baked-in
# whitelist for that phase (allowing projects to add custom transitions
# without losing the defaults).

# Guard against double-loading when multiple scripts source this file.
[ -n "${_RITE_PHASE_TRANSITION_LOADED:-}" ] && return 0
_RITE_PHASE_TRANSITION_LOADED=1

# Baked-in whitelist. Each entry maps a phase to the phases it may transition to.
# Empty string ("") is accepted as a synthetic "workflow start" predecessor for
# any phase, since /rite:issue:start begins with no prior state.
declare -gA _RITE_PHASE_TRANSITIONS=(
  # Phase 1 → Phase 1.5/1.6/2
  ["phase1_5_parent"]="phase1_5_post_parent"
  ["phase1_5_post_parent"]="phase1_6_child phase2_branch"
  ["phase1_6_child"]="phase1_6_post_child"
  ["phase1_6_post_child"]="phase2_branch"

  # Phase 2: branch → projects → iteration → work memory → plan
  ["phase2_branch"]="phase2_post_branch"
  ["phase2_post_branch"]="phase2_projects phase2_work_memory"
  ["phase2_projects"]="phase2_post_projects"
  ["phase2_post_projects"]="phase2_iteration phase2_work_memory"
  ["phase2_iteration"]="phase2_post_iteration"
  ["phase2_post_iteration"]="phase2_work_memory"
  ["phase2_work_memory"]="phase2_post_work_memory"
  ["phase2_post_work_memory"]="phase3_plan"

  # Phase 3: implementation plan
  ["phase3_plan"]="phase3_post_plan"
  ["phase3_post_plan"]="phase5_stop_hook phase5_lint"

  # Phase 5.0: stop-hook verification
  ["phase5_stop_hook"]="phase5_post_stop_hook"
  ["phase5_post_stop_hook"]="phase5_lint"

  # Phase 5.1/5.2: implement + lint
  ["phase5_lint"]="phase5_post_lint"
  ["phase5_post_lint"]="phase5_pr phase5_lint"

  # Phase 5.3: PR create
  ["phase5_pr"]="phase5_post_pr"
  ["phase5_post_pr"]="phase5_review"

  # Phase 5.4: review-fix loop
  ["phase5_review"]="phase5_post_review"
  ["phase5_post_review"]="phase5_fix phase5_ready"
  ["phase5_fix"]="phase5_post_fix"
  ["phase5_post_fix"]="phase5_review phase5_ready"

  # Phase 5.5: ready → status → metrics → completion
  ["phase5_ready"]="phase5_post_ready"
  ["phase5_post_ready"]="phase5_status_in_review"
  ["phase5_status_in_review"]="phase5_post_status_in_review"
  ["phase5_post_status_in_review"]="phase5_metrics"
  ["phase5_metrics"]="phase5_post_metrics"
  ["phase5_post_metrics"]="phase5_completion"

  # Phase 5.6 / 5.7: completion + parent completion
  ["phase5_completion"]="phase5_parent_completion completed"
  ["phase5_parent_completion"]="phase5_post_parent_completion"
  ["phase5_post_parent_completion"]="completed"
)

# Load override map from rite-config.yml if present.
# Only called once per process via the guard flag above.
_rite_load_whitelist_overrides() {
  local config_file="${1:-}"
  [ -z "$config_file" ] && return 0
  [ ! -f "$config_file" ] && return 0

  # Extract the hooks.stop_guard.phase_transitions block with awk.
  # Supported format (subset of YAML):
  #   hooks:
  #     stop_guard:
  #       phase_transitions:
  #         phase_x: [phase_y, phase_z]
  #         phase_a:
  #           - phase_b
  #           - phase_c
  local block
  block=$(awk '
    BEGIN { in_hooks=0; in_sg=0; in_pt=0; pt_indent=-1 }
    /^hooks:[[:space:]]*$/ { in_hooks=1; next }
    in_hooks && /^[a-zA-Z]/ { in_hooks=0; in_sg=0; in_pt=0 }
    in_hooks && /^[[:space:]]+stop_guard:[[:space:]]*$/ { in_sg=1; next }
    in_sg && /^[[:space:]]+phase_transitions:[[:space:]]*$/ {
      in_pt=1
      match($0, /^[[:space:]]+/)
      pt_indent=RLENGTH
      next
    }
    in_pt {
      # Leaving the phase_transitions block when indentation shrinks back.
      line_indent=0
      match($0, /^[[:space:]]*/); line_indent=RLENGTH
      if ($0 ~ /^[[:space:]]*$/) { next }
      if (line_indent <= pt_indent) { in_pt=0; next }
      print
    }
  ' "$config_file" 2>/dev/null)

  [ -z "$block" ] && return 0

  # Parse the extracted block. Two sub-formats:
  #   (1) inline list:  phase_x: [a, b, c]
  #   (2) block list:   phase_x:\n  - a\n  - b
  local current_key=""
  local current_targets=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Strip leading whitespace
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue

    if [[ "$trimmed" =~ ^-\  ]]; then
      # Block list entry: "- value"
      local val="${trimmed#- }"
      val="${val%%#*}"
      val="${val//[[:space:]]/}"
      [ -n "$val" ] && current_targets="${current_targets:+$current_targets }$val"
    elif [[ "$trimmed" =~ ^([a-zA-Z0-9_]+):(.*)$ ]]; then
      # Flush previous key
      if [ -n "$current_key" ] && [ -n "$current_targets" ]; then
        _rite_merge_override_entry "$current_key" "$current_targets"
      fi
      current_key="${BASH_REMATCH[1]}"
      local rhs="${BASH_REMATCH[2]}"
      rhs="${rhs#"${rhs%%[![:space:]]*}"}"
      current_targets=""
      # Handle inline list form:  [a, b, c]
      if [[ "$rhs" =~ ^\[(.*)\]$ ]]; then
        local list_body="${BASH_REMATCH[1]}"
        list_body="${list_body//,/ }"
        for val in $list_body; do
          val="${val//\"/}"
          val="${val//\'/}"
          val="${val//[[:space:]]/}"
          [ -n "$val" ] && current_targets="${current_targets:+$current_targets }$val"
        done
        _rite_merge_override_entry "$current_key" "$current_targets"
        current_key=""
        current_targets=""
      fi
    fi
  done <<< "$block"

  # Flush any trailing block list
  if [ -n "$current_key" ] && [ -n "$current_targets" ]; then
    _rite_merge_override_entry "$current_key" "$current_targets"
  fi
}

_rite_merge_override_entry() {
  local key="$1"
  local new_targets="$2"
  local existing="${_RITE_PHASE_TRANSITIONS[$key]:-}"
  if [ -z "$existing" ]; then
    _RITE_PHASE_TRANSITIONS[$key]="$new_targets"
  else
    # Append non-duplicate targets
    local merged="$existing"
    local val
    for val in $new_targets; do
      if ! [[ " $merged " == *" $val "* ]]; then
        merged="$merged $val"
      fi
    done
    _RITE_PHASE_TRANSITIONS[$key]="$merged"
  fi
}

# Return 0 if `prev_phase -> next_phase` is allowed, 1 otherwise.
# Synthetic rules:
#   - Empty prev_phase is accepted for any known phase (workflow cold start).
#   - Unknown prev_phase is accepted (forward-compatibility; phases added by
#     sub-skills outside this whitelist should not cause spurious blocks).
#   - The special phase "completed" is always a valid terminal.
rite_phase_transition_allowed() {
  local prev="$1"
  local next="$2"

  # Terminal / cold-start cases
  [ -z "$prev" ] && return 0
  [ "$prev" = "$next" ] && return 0
  [ "$next" = "completed" ] && return 0
  [ "$next" = "phase_done" ] && return 0
  [ "$next" = "create_completed" ] && return 0

  local allowed="${_RITE_PHASE_TRANSITIONS[$prev]:-}"
  # Unknown prev phase → accept (forward compat)
  [ -z "$allowed" ] && ! rite_phase_is_known "$prev" && return 0

  local val
  for val in $allowed; do
    [ "$val" = "$next" ] && return 0
  done
  return 1
}

# Print the expected next phases for a given phase.
rite_phase_expected_next() {
  local phase="$1"
  printf '%s\n' "${_RITE_PHASE_TRANSITIONS[$phase]:-}"
}

# Return 0 if the given phase name is defined in the whitelist as either a
# source or a target.
rite_phase_is_known() {
  local phase="$1"
  [ -n "${_RITE_PHASE_TRANSITIONS[$phase]:-}" ] && return 0
  local key val
  for key in "${!_RITE_PHASE_TRANSITIONS[@]}"; do
    for val in ${_RITE_PHASE_TRANSITIONS[$key]}; do
      [ "$val" = "$phase" ] && return 0
    done
  done
  return 1
}

# Optional: auto-load overrides when RITE_CONFIG env var points to a config file.
if [ -n "${RITE_CONFIG:-}" ]; then
  _rite_load_whitelist_overrides "$RITE_CONFIG"
fi
