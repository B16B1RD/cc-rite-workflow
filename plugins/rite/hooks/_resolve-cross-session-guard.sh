#!/bin/bash
# rite workflow - Cross-Session Legacy Guard Helper (private internal helper)
#
# Inspects a legacy `.rite-flow-state` file relative to a current session_id
# and classifies the cross-session takeover/fallback decision. Both writer
# (flow-state-update.sh) and reader (state-read.sh) layers share this
# classification so the decision logic can never drift.
#
# Usage:
#   bash plugins/rite/hooks/_resolve-cross-session-guard.sh \
#     <legacy_path> <current_sid>
#
# Outputs (single token to stdout):
#   "same"                  legacy.session_id == current_sid → safe to take over
#   "empty"                 legacy.session_id is null/missing → safe (sessionless legacy)
#   "foreign:<other_sid>"   legacy.session_id != current_sid → refuse take-over
#   "corrupt:<jq_rc>"       legacy file jq parse failed → refuse take-over (cannot verify)
#
# Why this exists (verified-review cycle 34 fix F-02 HIGH):
#   The same `legacy.session_id` extraction + comparison logic was duplicated
#   between writer-side `_resolve_session_state_path` and reader-side state-read.sh
#   per-session resolver. DRY-ifying eliminates the drift risk where a future
#   tightening of the comparison (e.g., variant-bit equivalence, normalization)
#   is applied to one side only — Issue #687 root cause was a writer-side guard
#   that the reader-side did not yet mirror (cycle 32 added writer, cycle 33
#   added reader).
#
# Caller responsibility:
#   The caller decides what to do with each classification:
#   - "same" / "empty" → adopt legacy as the resolved STATE_FILE
#   - "foreign:<sid>" → emit cross_session_takeover_refused via workflow-incident-emit.sh
#                       and route to per-session path (writer) or DEFAULT (reader)
#   - "corrupt:<rc>" → emit legacy_state_corrupt via workflow-incident-emit.sh
#                       and route to per-session path (writer) or DEFAULT (reader)
#
# Exit codes:
#   0 — always (classification printed to stdout)
set -euo pipefail

LEGACY_PATH="${1:-}"
CURRENT_SID="${2:-}"

if [ -z "$LEGACY_PATH" ] || [ -z "$CURRENT_SID" ]; then
  echo "ERROR: usage: $0 <legacy_path> <current_sid>" >&2
  exit 1
fi

if [ ! -f "$LEGACY_PATH" ] || [ ! -s "$LEGACY_PATH" ]; then
  # Caller should not invoke this helper unless the legacy file is non-empty —
  # but defensive: treat empty/missing as "empty" so the caller path doesn't
  # need additional guard logic.
  printf 'empty'
  exit 0
fi

# Capture jq stderr separately so the caller can surface real IO errors.
# verified-review cycle 35 fix (F-05 MEDIUM): canonical signal-specific trap with
# variable-first-declared / trap-set-second / mktemp-third ordering. Race window between
# mktemp success and trap installation is closed; SIGINT/SIGTERM/SIGHUP propagate
# POSIX-conventional exit codes (130/143/129).
jq_err=""
_rite_cross_session_cleanup() {
  rm -f "${jq_err:-}"
  # verified-review cycle 36 fix (F-03 MEDIUM): explicit `return 0` per Form B doctrine
  # (bash-trap-patterns.md). `set -euo pipefail` is active (L38) — without `return 0`,
  # any future addition that returns non-zero (e.g., short-circuit `[ -n "" ] && rm`)
  # would cause `set -e` to abort the trap action, preventing `exit $rc` from running.
  # Adding `return 0` unconditionally as preemptive defense.
  return 0
}
trap 'rc=$?; _rite_cross_session_cleanup; exit $rc' EXIT
trap '_rite_cross_session_cleanup; exit 130' INT
trap '_rite_cross_session_cleanup; exit 143' TERM
trap '_rite_cross_session_cleanup; exit 129' HUP
jq_err=$(mktemp /tmp/rite-cross-session-jq-err-XXXXXX 2>/dev/null) || jq_err=""

# verified-review cycle 35 fix (F-03 HIGH): jq_rc capture must be inside the `else`
# branch. The previous structure `if cmd; then ...; exit 0; fi; jq_rc=$?` always
# captured 0 because bash's `if` statement's failed branch leaves `$?` at 0 (the
# failing command's exit code is discarded once `if` evaluates the condition).
# Moving rc capture into the `else` branch yields the actual jq exit code (4=parse
# error, 5=I/O error, etc.) which downstream consumers (state-read.sh /
# flow-state-update.sh) embed in the WORKFLOW_INCIDENT details for diagnosis.
#
# Empirical evidence (cycle 35 review): `printf '{corrupt' > /tmp/x && bash _resolve-cross-session-guard.sh /tmp/x <sid>`
# previously produced `corrupt:0` (wrong); after this fix it produces `corrupt:5` (correct, jq parse error rc).
#
# verified-review cycle 35 fix (F-01/F-02 CRITICAL related): stop emitting `cat "$jq_err" >&2` here.
# The caller (`state-read.sh` / `flow-state-update.sh`) was using `2>&1` to combine stdout/stderr,
# so any jq parse error message printed here would be merged into the `classification` string and
# break the `case "$classification" in corrupt:*) ...` match — silently routing to the defensive
# `*)` arm and suppressing the `legacy_state_corrupt` workflow incident sentinel emit. We now keep
# stderr clean so callers can use `2>/dev/null` (also fixed in cycle 35) without losing the rc.
# If a future debug session needs the jq parse error text, the caller can capture it via a
# separate stderr tempfile (state-read.sh:203 / flow-state-update.sh adopt this pattern).
if legacy_sid=$(jq -r '.session_id // empty' "$LEGACY_PATH" 2>"${jq_err:-/dev/null}"); then
  if [ -z "$legacy_sid" ]; then
    printf 'empty'
  elif [ "$legacy_sid" = "$CURRENT_SID" ]; then
    printf 'same'
  else
    # verified-review cycle 35 fix (F-10 LOW security): validate legacy_sid as
    # UUID via _resolve-session-id.sh. legacy_sid is read from an untrusted file
    # (could contain newline / shell metachar / huge payload). The downstream
    # workflow-incident-emit.sh already sanitizes, but this helper's API contract
    # promises `foreign:<UUID>` so we enforce it here as defense-in-depth.
    if validated_legacy=$(bash "$(dirname "${BASH_SOURCE[0]}")/_resolve-session-id.sh" "$legacy_sid" 2>/dev/null); then
      printf 'foreign:%s' "$validated_legacy"
    else
      # legacy session_id is not a valid UUID (corrupt / tampered / legacy schema).
      # verified-review cycle 36 fix (F-16 LOW security): use `invalid_uuid:` prefix
      # instead of `corrupt:1` to avoid numeric collision with jq exit code 1
      # ("any other error"). Operators reading WORKFLOW_INCIDENT details can now
      # distinguish "UUID validation failure" (this branch) from "jq general error"
      # (jq_rc=1 in the else branch below). Caller-side classification cases
      # (state-read.sh / flow-state-update.sh) are updated to handle `invalid_uuid:*`.
      printf 'invalid_uuid:1'
    fi
  fi
  exit 0
else
  jq_rc=$?
  printf 'corrupt:%d' "$jq_rc"
  exit 0
fi
