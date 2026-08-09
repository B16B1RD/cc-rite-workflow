#!/bin/bash
# Resolve a Ready target PR and run the bang-backtick scanner against its head.
set -u
pr_number=""; owner_repo=""; plugin_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) pr_number="${2:-}"; shift 2 ;;
    --repo) owner_repo="${2:-}"; shift 2 ;;
    --plugin-root) plugin_root="${2:-}"; shift 2 ;;
    *) echo "ERROR: Ready gate: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$pr_number" in ''|*[!0-9]*) echo "ERROR: Ready gate: PR number is required" >&2; exit 2 ;; esac
[ -n "$owner_repo" ] || { echo "ERROR: Ready gate: owner/repo is required" >&2; exit 2; }
[ -x "$plugin_root/hooks/scripts/bang-backtick-check.sh" ] || {
  echo "[CONTEXT] BANG_BACKTICK_CHECK_INVOCATION_FAILED=1; reason=script_missing; resolved_root=${plugin_root:-<empty>}" >&2
  echo "ERROR: bang-backtick-check.sh not found. Cannot proceed with Ready gate." >&2
  exit 2
}
ready_gate_tmp=""
cleanup_ready_gate_worktree() {
  [ -n "${ready_gate_tmp:-}" ] || return 0
  cleanup_path="$ready_gate_tmp"; ready_gate_tmp=""
  if ! git worktree remove --force "$cleanup_path" >/dev/null 2>&1; then
    echo "WARNING: Ready gate の一時 worktree を削除できませんでした: $cleanup_path" >&2
  fi
  return 0
}
trap 'rc=$?; cleanup_ready_gate_worktree; exit $rc' EXIT
trap 'cleanup_ready_gate_worktree; exit 130' INT
trap 'cleanup_ready_gate_worktree; exit 143' TERM
trap 'cleanup_ready_gate_worktree; exit 129' HUP
pr_head_oid=$(gh pr view "$pr_number" -R "$owner_repo" --json headRefOid --jq '.headRefOid') || {
  echo "ERROR: Ready gate: PR #$pr_number の headRefOid を解決できません" >&2; exit 2
}
[ -n "$pr_head_oid" ] || { echo "ERROR: Ready gate: PR #$pr_number の headRefOid が空です" >&2; exit 2; }
current_oid=$(git rev-parse HEAD) || { echo "ERROR: Ready gate: 現在の HEAD を解決できません" >&2; exit 2; }
scan_root="."
if [ "$current_oid" != "$pr_head_oid" ]; then
  git fetch origin "$pr_head_oid" >/dev/null 2>&1 || { echo "ERROR: Ready gate: PR head $pr_head_oid の fetch に失敗しました" >&2; exit 2; }
  ready_gate_tmp=$(mktemp -d "${TMPDIR:-/tmp}/rite-ready-pr-head.XXXXXX") || { echo "ERROR: Ready gate: 一時ディレクトリの作成に失敗しました" >&2; exit 2; }
  rmdir "$ready_gate_tmp" || { echo "ERROR: Ready gate: 一時 worktree path の準備に失敗しました" >&2; exit 2; }
  git worktree add --detach "$ready_gate_tmp" "$pr_head_oid" >/dev/null 2>&1 || { echo "ERROR: Ready gate: PR head $pr_head_oid の一時 worktree 作成に失敗しました" >&2; exit 2; }
  scan_root="$ready_gate_tmp"
  echo "[CONTEXT] READY_GATE_PR_HEAD_RESOLVED=1; head_oid=$pr_head_oid" >&2
fi
bang_output=$(bash "$plugin_root/hooks/scripts/bang-backtick-check.sh" --all --skip-if-no-target --repo-root "$scan_root" 2>&1); bang_rc=$?
case "$bang_rc" in
  0) if printf '%s' "$bang_output" | grep -q '\[bang-backtick\] not applicable'; then echo "ℹ️ Bang-backtick gate: N/A（clean skip）。" >&2; fi ;;
  1) echo "❌ Bang-backtick adjacency detected — Ready transition blocked:" >&2; printf '%s\n' "$bang_output" >&2; echo "ACTION: Apply Style A (full-width 「!」) or Style B (expand 'if ! cmd; then')." >&2; exit 1 ;;
  *) echo "[CONTEXT] BANG_BACKTICK_CHECK_INVOCATION_FAILED=1; reason=invocation_error; rc=$bang_rc" >&2; printf '%s\n' "$bang_output" >&2; exit 2 ;;
esac
