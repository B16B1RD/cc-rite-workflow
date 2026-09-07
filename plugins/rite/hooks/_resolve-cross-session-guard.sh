#!/bin/bash
# rite workflow - Cross-Session Legacy Guard Helper (private internal helper)
#
# Inspects a legacy `.rite-flow-state` file relative to a current session_id
# and classifies the cross-session takeover/fallback decision. The writer and
# reader state resolvers that shared this classification were consolidated into
# flow-state.sh, so this helper currently has no live caller — it is retained as
# the canonical classification contract for any future re-wiring.
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
#                           Distinct from "corrupt:*" so a consumer can differentiate
#                           UUID validation failure from jq parse failure.
#
# Caller responsibility (no live caller today — see above):
#   A consumer of these classifications would route each one and surface the
#   non-adoptable cases as a plain WARNING on stderr:
#   - "same" / "empty" → adopt legacy as the resolved STATE_FILE
#   - "foreign:<sid>" → cross-session takeover refused; route to per-session path
#                       (writer) or DEFAULT (reader)
#   - "corrupt:<rc>" → legacy state corrupt; route to per-session path (writer) or
#                       DEFAULT (reader)
#   - "invalid_uuid:<rc>" → legacy state corrupt (reason=invalid_uuid_format),
#                       distinct classification for diagnosis
#
# Exit codes:
#   0 — always (classification printed to stdout)
set -euo pipefail
# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

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
# Variable name `_jq_err` follows the `_*_err` stderr-capture naming convention
# shared across the state hooks. cleanup is Form A (single
# `rm -f`); see bash-trap-patterns.md "cleanup 関数の契約" for why `return 0`
# is unnecessary.
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
# stderr). A consumer would treat an empty path as `/dev/null` redirection — the
# corrupt:N rc is still observable, only the line/column detail is lost when
# mktemp itself fails.
_jq_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  "_resolve-cross-session-guard" "cross-session-jq-err" \
  "jq 失敗時の parse error 詳細が表示されません (caller は corrupt:N rc を観測できますが原因 line/column が失われます)")

# jq_rc must be captured inside the `else` branch (not after `fi`): bash's `if`
# statement leaves `$?` at 0 once the condition is evaluated, so a post-`fi`
# capture would always read 0 and collapse `corrupt:N` to `corrupt:0`. Capturing
# in the `else` branch yields the actual jq exit code (4=parse error, 5=I/O,
# etc.) that downstream consumers embed in the WARNING details.
#
# Keep stdout limited to the classification token: merging stderr with `2>&1`
# would contaminate the value and break `case ... corrupt:*)` matching.
# Callers can capture stderr separately to retain jq diagnostics.
if legacy_sid=$(jq -r '.session_id // empty' "$LEGACY_PATH" 2>"${_jq_err:-/dev/null}"); then
  if [ -z "$legacy_sid" ]; then
    printf 'empty'
  elif [ "$legacy_sid" = "$CURRENT_SID" ]; then
    printf 'same'
  else
    # Validate legacy_sid as UUID via `_resolve-session-id.sh`: the value is
    # read from an untrusted file (newline / shell metachar / huge payload all
    # possible). This helper's API contract promises `foreign:<UUID>`, so we
    # enforce UUID validity here as defense-in-depth before the consumer surfaces it.
    #
    # Helper-existence check distinguishes deploy mishaps (rc=127 missing /
    # rc=126 non-executable) from real UUID validation failure (rc=1) so they
    # do not collapse into `invalid_uuid:1`. Upstream callers already perform
    # an `[ -x ]` check before invoking this helper; this inline check is
    # double defence for transitive direct execution.
    _resolve_sid_helper="$(dirname "${BASH_SOURCE[0]}")/_resolve-session-id.sh"
    if [ ! -x "$_resolve_sid_helper" ]; then
      # deploy 不整合: helper 自体が存在しない / 非実行可能。invalid_uuid:1 に collapse させずに
      # corrupt:126 を返して root cause 診断時の区別を可能にする (caller 側の
      # case "$classification" in corrupt:*) は既存経路と同じ動線で legacy-state-corrupt
      # WARNING を surface する)。
      printf 'corrupt:126'
      exit 0
    fi
    if validated_legacy=$(bash "$_resolve_sid_helper" "$legacy_sid" 2>/dev/null); then
      printf 'foreign:%s' "$validated_legacy"
    else
      # legacy session_id is not a valid UUID (corrupt / tampered / legacy schema).
      # The `invalid_uuid:` prefix avoids collision with jq exit code 1
      # ("any other error"). Operators reading the WARNING details can
      # distinguish "UUID validation failure" (this branch) from "jq general error"
      # (jq_rc=1 in the else branch below). A consumer would handle the
      # `invalid_uuid:*` token distinctly in its classification cases.
      printf 'invalid_uuid:1'
    fi
  fi
  exit 0
else
  jq_rc=$?
  # Surface the first 3 lines of jq stderr so the caller's `_classify_err`
  # tempfile receives the parse-error line/column. Callers redirect stderr
  # into their own tempfile (`2>"$_classify_err"`), so emitting here does not
  # contaminate stdout (`classification` token).
  [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | neutralize_ctrl --keep-newline >&2
  printf 'corrupt:%d' "$jq_rc"
  exit 0
fi
