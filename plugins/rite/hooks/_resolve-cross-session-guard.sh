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
#   "invalid_uuid:1"        legacy.session_id JSON-parseable but UUID validation failed
#                           → refuse take-over (tampered / legacy schema with non-UUID session_id)
#                           Distinct from "corrupt:*" so incident response can differentiate
#                           UUID validation failure from jq parse failure (cycle 36 F-16)
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
#   - "invalid_uuid:<rc>" → emit legacy_state_corrupt with reason=invalid_uuid_format via
#                       workflow-incident-emit.sh, distinct root_cause_hint for diagnosis
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
# Trap is canonical signal-specific (variable-first-declared / trap-set-second /
# mktemp-third) per references/bash-trap-patterns.md; SIGINT/SIGTERM/SIGHUP
# propagate POSIX exit codes 130/143/129.
# Variable name `_jq_err` is intentionally aligned with state-read.sh for the
# writer/reader symmetry that this helper enforces. cleanup is Form A (single
# `rm -f`); see bash-trap-patterns.md "cleanup 関数の契約" for why `return 0`
# is unnecessary. Historical drift fixes are catalogued in
# references/state-read-evolution.md.
_jq_err=""
_rite_cross_session_cleanup() {
  rm -f "${_jq_err:-}"
}
trap 'rc=$?; _rite_cross_session_cleanup; exit $rc' EXIT
trap '_rite_cross_session_cleanup; exit 130' INT
trap '_rite_cross_session_cleanup; exit 143' TERM
trap '_rite_cross_session_cleanup; exit 129' HUP
# Mktemp + chmod 600 + WARNING emit on failure are centralised in
# `_mktemp-stderr-guard.sh` (returns empty path on failure, emits WARNING to
# stderr). Caller (state-read.sh / flow-state-update.sh) treats an empty path
# as `/dev/null` redirection — the corrupt:N rc is still observable, only the
# line/column detail is lost when mktemp itself fails.
_jq_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  "_resolve-cross-session-guard" "cross-session-jq-err" \
  "jq 失敗時の parse error 詳細が表示されません (caller は corrupt:N rc を観測できますが原因 line/column が失われます)")

# jq_rc must be captured inside the `else` branch (not after `fi`): bash's `if`
# statement leaves `$?` at 0 once the condition is evaluated, so a post-`fi`
# capture would always read 0 and collapse `corrupt:N` to `corrupt:0`. Capturing
# in the `else` branch yields the actual jq exit code (4=parse error, 5=I/O,
# etc.) that downstream consumers embed in the WORKFLOW_INCIDENT details.
#
# Stderr is intentionally kept clean here. Callers (state-read.sh /
# flow-state-update.sh) historically combined stdout/stderr with `2>&1` to
# capture diagnostics, but that merged any `jq:` parse-error text into the
# `classification` string and broke the `case ... corrupt:*) ...` match,
# silently routing to the defensive `*)` arm and suppressing the
# `legacy_state_corrupt` sentinel. The current contract: callers use
# `2>/dev/null` and observe the rc via `corrupt:N`; full jq stderr is captured
# by each caller into its own tempfile (see `_jq_err` capture blocks in the
# caller hooks). Drift history is in references/state-read-evolution.md.
if legacy_sid=$(jq -r '.session_id // empty' "$LEGACY_PATH" 2>"${_jq_err:-/dev/null}"); then
  if [ -z "$legacy_sid" ]; then
    printf 'empty'
  elif [ "$legacy_sid" = "$CURRENT_SID" ]; then
    printf 'same'
  else
    # Validate legacy_sid as UUID via `_resolve-session-id.sh`: the value is
    # read from an untrusted file (newline / shell metachar / huge payload all
    # possible). Downstream workflow-incident-emit.sh sanitizes its own input,
    # but this helper's API contract promises `foreign:<UUID>` and we enforce
    # it here as defense-in-depth.
    #
    # Helper-existence check distinguishes deploy mishaps (rc=127 missing /
    # rc=126 non-executable) from real UUID validation failure (rc=1) so they
    # do not collapse into `invalid_uuid:1`. Upstream callers already perform
    # an `[ -x ]` check before invoking this helper; this inline check is
    # double defence for transitive direct execution.
    _resolve_sid_helper="$(dirname "${BASH_SOURCE[0]}")/_resolve-session-id.sh"
    if [ ! -x "$_resolve_sid_helper" ]; then
      # deploy 不整合: helper 自体が存在しない / 非実行可能。invalid_uuid:1 に collapse させずに
      # corrupt:126 で emit して root cause 診断時の区別を可能にする (caller 側の
      # case "$classification" in corrupt:*) は既存経路と同じ動線で legacy_state_corrupt sentinel
      # を emit する)。
      printf 'corrupt:126'
      exit 0
    fi
    if validated_legacy=$(bash "$_resolve_sid_helper" "$legacy_sid" 2>/dev/null); then
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
  # Surface the first 3 lines of jq stderr so the caller's `_classify_err`
  # tempfile receives the parse-error line/column. Callers redirect stderr
  # into their own tempfile (`2>"$_classify_err"`), so emitting here does not
  # contaminate stdout (`classification` token). This restores the
  # observability that was traded away when stdout pollution forced removal
  # of an earlier `cat "$_jq_err" >&2` block; details in
  # references/state-read-evolution.md.
  [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" >&2
  printf 'corrupt:%d' "$jq_rc"
  exit 0
fi
