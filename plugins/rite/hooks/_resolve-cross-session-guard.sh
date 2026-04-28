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
# verified-review cycle 35 fix (F-05 MEDIUM): canonical signal-specific trap with
# variable-first-declared / trap-set-second / mktemp-third ordering. Race window between
# mktemp success and trap installation is closed; SIGINT/SIGTERM/SIGHUP propagate
# POSIX-conventional exit codes (130/143/129).
# verified-review cycle 38 F-14 LOW: jq stderr 退避用変数を state-read.sh と同じ `_jq_err` 表記に統一
# (旧 `jq_err` は無 prefix で他 helper の命名 `_<name>` 規約から外れていた)。trap cleanup の参照も併せて更新。
_jq_err=""
# verified-review F-07 (MEDIUM): cleanup 関数本体は Form A (`rm -f "${_jq_err:-}"` 単一行) のため、
# bash-trap-patterns.md「cleanup 関数の契約」節 Form A 規範では `return 0` 不要 (rm -f の rc=0 で十分)。
# 旧実装は Form B doctrine を誤って Form A に適用した非対称コード (cycle 36 F-03 で導入) だった。
# `_resolve-session-id-from-file.sh` の Form A cleanup と統一し、Form A 最小性 doctrine を維持する。
_rite_cross_session_cleanup() {
  rm -f "${_jq_err:-}"
}
trap 'rc=$?; _rite_cross_session_cleanup; exit $rc' EXIT
trap '_rite_cross_session_cleanup; exit 130' INT
trap '_rite_cross_session_cleanup; exit 143' TERM
trap '_rite_cross_session_cleanup; exit 129' HUP
# verified-review (PR #688 cycle 39 H-02) MEDIUM (silent-failure-hunter): mktemp 失敗時に WARNING emit。
# state-read.sh の cycle 38 F-06 fix で導入された mktemp 失敗 WARNING 3 行 emit ブロック
# (jq stderr 退避用 _jq_err 直前の `if ! _jq_err=$(mktemp ...)` ブロック) と writer/reader 対称化。
# 旧実装は `2>/dev/null || _jq_err=""` で mktemp 失敗 (/tmp full / permission denied / SELinux deny) を
# silent fallback し、後続の `2>"${_jq_err:-/dev/null}"` で jq stderr が `/dev/null` に redirect される
# 二重 silent failure になっていた (corrupt:* arm の line/column 詳細が失われる)。
# state-read.sh と非対称な silent fallback を解消する (writer/reader 対称化は本 helper の存在意義の核心)。
# verified-review cycle 40: cycle 39 で「state-read.sh L247-252」と書いた行番号参照を
# semantic anchor (mktemp 失敗 WARNING 3 行 emit ブロック) に置換 (cycle 38 F-04 DRIFT-CHECK ANCHOR
# 原則と整合)。
# F-02 (MEDIUM) consolidation: 共通 helper `_mktemp-stderr-guard.sh` 経由で
# Stderr emit + chmod 600 + path return を集約 (PR #688 cycle 9 F-02)。
# helper は失敗時に空文字を返し WARNING を stderr に emit する (non-blocking contract)。
# chmod 600 (cycle 41 F-14 で導入された defense-in-depth) は helper 内に内蔵済。
_jq_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  "_resolve-cross-session-guard" "cross-session-jq-err" \
  "jq 失敗時の parse error 詳細が表示されません (caller は corrupt:N rc を観測できますが原因 line/column が失われます)")

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
# verified-review cycle 35 fix (F-01/F-02 CRITICAL related): stop emitting `cat "$_jq_err" >&2` here.
# The caller (`state-read.sh` / `flow-state-update.sh`) was using `2>&1` to combine stdout/stderr,
# so any jq parse error message printed here would be merged into the `classification` string and
# break the `case "$classification" in corrupt:*) ...` match — silently routing to the defensive
# `*)` arm and suppressing the `legacy_state_corrupt` workflow incident sentinel emit. We now keep
# stderr clean so callers can use `2>/dev/null` (also fixed in cycle 35) without losing the rc.
# If a future debug session needs the jq parse error text, the caller can capture it via a
# separate stderr tempfile (state-read.sh の `_jq_err` capture block / flow-state-update.sh の同型
# pattern を参照。cycle 38 propagation scan: 旧 `state-read.sh:203` 行番号参照を semantic anchor に置換)。
if legacy_sid=$(jq -r '.session_id // empty' "$LEGACY_PATH" 2>"${_jq_err:-/dev/null}"); then
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
    #
    # verified-review F-09 LOW (defense-in-depth): _resolve-session-id.sh が deploy 不整合で
    # 不在 (rc=127) / 非実行可能 (rc=126) になった場合、UUID validation 失敗 (rc=1) と区別
    # 不能で `invalid_uuid:1` に collapse する経路を解消する。upstream caller (state-read.sh
    # / flow-state-update.sh) は本 helper を呼ぶ前に既に `_resolve-session-id.sh` の
    # `[ -x ]` を upfront check しているため、本 inline check は二重防御 (transitive 経路で
    # 個別実行された場合の保険)。_resolve-session-id-from-file.sh が cycle 39 H-01 で同型 fix
    # を採用しているため writer/reader 対称化。
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
  printf 'corrupt:%d' "$jq_rc"
  exit 0
fi
