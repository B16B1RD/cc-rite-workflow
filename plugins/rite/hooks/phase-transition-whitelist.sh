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

# Bash 4.2+ required for `declare -gA`. Older bash (e.g., macOS default 3.2)
# would abort with a syntax error on the associative-array literal below, and the
# stop-guard source would silently fail-open. Bail out gracefully so that
# stop-guard can detect the missing `rite_phase_transition_allowed` function and
# log a diagnostic instead of silently disabling the whitelist.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
  return 0
fi

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
  # Since cycle-3 MEDIUM #3 fix, every 2.x phase always writes its post-marker
  # (skip is signalled via the `[CONTEXT] PHASE_2_4_STATE=skip` marker and is recorded
  # as a whitelist-valid transition). Direct phase2_post_branch → phase2_work_memory
  # and phase2_post_projects → phase2_work_memory paths were removed because they
  # bypass the iteration-phase chain (prompt-engineer cycle-3 MEDIUM).
  ["phase2_branch"]="phase2_post_branch"
  ["phase2_post_branch"]="phase2_projects"
  ["phase2_projects"]="phase2_post_projects"
  ["phase2_post_projects"]="phase2_iteration"
  ["phase2_iteration"]="phase2_post_iteration"
  ["phase2_post_iteration"]="phase2_work_memory"
  ["phase2_work_memory"]="phase2_post_work_memory"
  ["phase2_post_work_memory"]="phase3_plan"

  # Phase 3: implementation plan
  # Phase 5.0 (Stop Hook Verification) is mandatory — transition MUST go through phase5_stop_hook.
  # Do NOT allow direct phase3_post_plan → phase5_lint (would silently skip Stop Hook verification).
  # phase3_post_plan → phase3_plan is accepted for /rite:resume retry after plan was already
  # completed in a prior session (code-quality cycle-3 MEDIUM).
  ["phase3_plan"]="phase3_post_plan"
  ["phase3_post_plan"]="phase5_stop_hook phase3_plan"

  # Phase 5.0: stop-hook verification
  ["phase5_stop_hook"]="phase5_post_stop_hook"
  ["phase5_post_stop_hook"]="phase5_lint"

  # Phase 5.1/5.2: implement + lint
  ["phase5_lint"]="phase5_post_lint"
  ["phase5_post_lint"]="phase5_pr phase5_lint"

  # Phase 5.3: PR create
  # start.md Phase 5.3 Mandatory After transitions directly from phase5_pr to phase5_review
  # (no intermediate phase5_post_pr write). Allow both the direct path and the legacy
  # post_pr marker for backward compat (devops cycle-2 CRITICAL).
  ["phase5_pr"]="phase5_post_pr phase5_review"
  ["phase5_post_pr"]="phase5_review"

  # Phase 5.4: review-fix loop
  # `rite:pr:ready` defense-in-depth directly writes phase5_post_ready from phase5_post_review /
  # phase5_post_fix, bypassing phase5_ready. Allow that transition to avoid invalid-transition
  # blocks on the mergeable path (devops-reviewer CRITICAL #1).
  ["phase5_review"]="phase5_post_review"
  ["phase5_post_review"]="phase5_fix phase5_ready phase5_post_ready phase5_ready_error"
  ["phase5_fix"]="phase5_post_fix"
  ["phase5_post_fix"]="phase5_review phase5_ready phase5_post_ready phase5_ready_error"

  # Phase 5.5: ready → status → metrics → completion
  # phase5_ready_error is a terminal error state emitted by ready.md Phase 4.5 when skill errors
  # (devops-reviewer HIGH #5). Allow error → post_ready and error → completed transitions so the
  # workflow can recover via user choice (retry / manual / terminate).
  ["phase5_ready"]="phase5_post_ready phase5_ready_error"
  ["phase5_ready_error"]="phase5_post_ready completed"
  ["phase5_post_ready"]="phase5_status_in_review"
  ["phase5_status_in_review"]="phase5_post_status_in_review"
  ["phase5_post_status_in_review"]="phase5_metrics"
  ["phase5_metrics"]="phase5_post_metrics"
  # phase5_post_metrics → phase5_completion is the single valid path. The legacy
  # "completed" direct edge was removed after the Post-completion block moved to
  # Workflow Termination (prompt-engineer cycle-2 MEDIUM #1).
  ["phase5_post_metrics"]="phase5_completion"

  # Phase 5.6 / 5.7: completion + parent completion
  # "completed" is a terminal state reachable from multiple phases (post_metrics, completion,
  # parent_completion, post_parent_completion). The Post-completion block historically patched
  # phase="completed" directly after phase5_post_metrics, so we accept the direct transition
  # (prompt-engineer + devops CRITICAL #2).
  ["phase5_completion"]="phase5_parent_completion completed"
  ["phase5_parent_completion"]="phase5_post_parent_completion"
  ["phase5_post_parent_completion"]="completed"

  # Terminal: "completed" MAY re-enter phase5_completion only in /rite:resume scenarios.
  # Under normal flow, transitions out of "completed" are rejected by rite_phase_transition_allowed
  # (terminal state). The empty-value listing below keeps the name known as a source for
  # rite_phase_is_known().
  ["completed"]=""
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
  #
  # Trailing `# comment` and `#` column-0 comments are both tolerated
  # (regex ends with optional `#.*` to match full-line or inline comments).
  #
  # Error visibility: awk errors (permission denied, disk I/O, malformed invocation)
  # are sent to stderr. Previously suppressed with `2>/dev/null`, which silently
  # hid override misconfiguration from users — the opposite of #490's intent
  # (error-handling-reviewer CRITICAL).
  local block awk_err
  awk_err=$(mktemp /tmp/rite-phase-transition-awk-err-XXXXXX 2>/dev/null) || awk_err=""
  block=$(awk '
    BEGIN { in_hooks=0; in_sg=0; in_pt=0; pt_indent=-1 }
    /^hooks:[[:space:]]*(#.*)?$/ { in_hooks=1; next }
    in_hooks && /^[a-zA-Z]/ { in_hooks=0; in_sg=0; in_pt=0 }
    in_hooks && /^[[:space:]]+stop_guard:[[:space:]]*(#.*)?$/ { in_sg=1; next }
    in_sg && /^[[:space:]]+phase_transitions:[[:space:]]*(#.*)?$/ {
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
  ' "$config_file" 2>"${awk_err:-/dev/null}")
  local awk_rc=$?

  if [ "$awk_rc" -ne 0 ]; then
    echo "WARNING: rite-config.yml override parse (awk) failed (rc=$awk_rc): $config_file" >&2
    if [ -n "$awk_err" ] && [ -s "$awk_err" ]; then
      head -3 "$awk_err" | sed 's/^/  /' >&2
    fi
    echo "  対処: rite-config.yml の権限 / awk バイナリを確認してください" >&2
    [ -n "$awk_err" ] && rm -f "$awk_err"
    # Return non-zero so the caller's `|| log_diag ...` handler records the
    # failure in the diagnostic log (devops cycle-2 LOW #2).
    return 1
  fi
  [ -n "$awk_err" ] && rm -f "$awk_err"

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

    # Ignore pure comment lines
    [[ "$trimmed" =~ ^# ]] && continue

    # Block list entry: "- value" — use [[:space:]]+ to tolerate tab and multiple spaces
    # (prompt-engineer IMPORTANT R #2).
    if [[ "$trimmed" =~ ^-[[:space:]]+ ]]; then
      local val="${trimmed#-}"
      val="${val#"${val%%[![:space:]]*}"}"
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
      # Require balanced brackets — unclosed `[a, b` silently dropped the entry
      # and leaked into the next key (IMPORTANT R #3).
      if [[ "$rhs" =~ ^\[ ]]; then
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
        else
          echo "WARNING: rite-config.yml override parse: unclosed inline list on '$current_key': $rhs" >&2
          current_key=""
          current_targets=""
        fi
      fi
    else
      # Unrecognized line — emit a debug trace so users can diagnose silent drops
      # (error-handling IMPORTANT).
      [ -n "${RITE_DEBUG:-}" ] && echo "[rite debug] override parse skipped line: $trimmed" >&2
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

  # Terminal / cold-start cases.
  # "completed" is the /rite:issue:start terminal state. "create_completed" is written by
  # /rite:issue:create at its end. "phase_done" was a speculative reserved name with no
  # producer — removed per code-quality cycle-3 LOW (premature abstraction).
  [ -z "$prev" ] && return 0
  [ "$prev" = "$next" ] && return 0
  [ "$next" = "completed" ] && return 0
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
