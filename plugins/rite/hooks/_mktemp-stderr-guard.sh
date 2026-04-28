#!/bin/bash
# _mktemp-stderr-guard.sh — Common stderr-tempfile mktemp helper with WARNING emit
#
# F-02 (MEDIUM) consolidation: Earlier the same 4-line `mktemp + WARNING` block was
# duplicated across 6 hook scripts (`_resolve-session-id-from-file.sh`,
# `_resolve-cross-session-guard.sh`, `flow-state-update.sh` ×2, `resume-active-flag-restore.sh`,
# `state-read.sh`). The duplicated block is structurally identical except for the calling
# script's name and the `影響:` line wording. PR #688 cycle 9 F-02 (MEDIUM) extracted this
# block into the present helper following the same API pattern established by
# `_emit-cross-session-incident.sh` (cycle 38 F-08).
#
# Usage:
#   path=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
#            <caller_id> <template_suffix> <impact_msg> [fix_msg])
#
# Arguments:
#   $1 caller_id        : Calling script's name without `.sh` extension
#                         (e.g. "state-read", "flow-state-update").
#                         Used in the WARNING message for caller identification.
#   $2 template_suffix  : mktemp template suffix without leading "rite-" prefix
#                         (e.g. "jq-err", "guard-stderr"). The full template will be
#                         "${TMPDIR:-/tmp}/rite-{template_suffix}-XXXXXX".
#   $3 impact_msg       : Single-line message describing the impact of the mktemp
#                         failure (e.g. "jq 失敗時の parse error 詳細が表示されません").
#   $4 fix_msg          : Optional. Single-line fix-suggestion message. Defaults to
#                         "/tmp の空き容量・パーミッションを確認してください" when omitted.
#
# Output:
#   stdout: tempfile path on success, empty line on failure.
#   stderr: WARNING block (4 lines) on failure.
#
# Exit code:
#   Always 0. Non-blocking by contract — caller checks for empty stdout to detect failure.
#
# Side effect on success:
#   chmod 600 on the created tempfile (multi-user / shared /tmp 環境での path-disclosure 防止)。
#   chmod 失敗は best-effort skip (filesystem が ACL 非対応な環境でも mktemp 自体は成功させる)。

set -u

caller_id="${1:-unknown}"
template_suffix="${2:-stderr-err}"
impact_msg="${3:-cmd の stderr 詳細が表示されません}"
fix_msg="${4:-/tmp の空き容量・パーミッションを確認してください}"

if path=$(mktemp "${TMPDIR:-/tmp}/rite-${template_suffix}-XXXXXX" 2>/dev/null); then
  # success: chmod 600 (best-effort, then echo path to stdout)
  chmod 600 "$path" 2>/dev/null || true
  printf '%s\n' "$path"
else
  # failure: empty stdout + 4-line WARNING block on stderr
  printf '\n'
  echo "WARNING: ${caller_id}: stderr 退避用 tempfile の mktemp に失敗しました (/tmp full / permission denied / SELinux deny?)" >&2
  echo "  影響: ${impact_msg}" >&2
  echo "  対処: ${fix_msg}" >&2
fi

exit 0
