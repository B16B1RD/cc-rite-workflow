#!/bin/bash
# rite workflow - Post-Review State Verification
#
# Reviewer subagent が READ-ONLY 契約を破って parent repo の working tree / branch /
# stash list を変更した場合に検出し、可能な範囲で recovery する defense-in-depth layer。
#
# 一次防御: reviewer prompt の READ-ONLY 契約 (`plugins/rite/agents/_reviewer-base.md`,
# Layer 1)。working-tree 変更 verb は網羅的な事前遮断が安全でないため機械ゲートから撤去され、
# `pre-tool-bash-guard.sh` Pattern 4 が機械遮断するのは .git 書き込み経路のみになった。
# 本スクリプト (Layer 3) は prompt 契約が破られた事故の検出と recovery を担う
# post-condition gate であり、working-tree / branch / stash / branch-list drift の
# 検出保証はここが正となる。
#
# 想定する事故シナリオ: reviewer subagent が `pr-<N>-test` のようなブランチを作成して
# `git checkout` した結果、parent session の working tree が develop に切り替わって
# `/rite:fix` が PR ブランチを見失う。これを再発させない gate。
#
# Usage:
#   bash post-review-state-verify.sh \
#       --original-branch <name> \
#       [--original-stash-count <N>] \
#       [--original-branch-list-hash <hash>] \
#       [--original-worktree-hash <hash>] \
#       [--auto-recover true|false]
#
# Arguments:
#   --original-branch <name>           Review 開始時の current branch 名 (required)
#   --original-stash-count <N>         Review 開始時の `git stash list` 行数 (optional)
#   --original-branch-list-hash <hash> Review 開始時の `git branch --list | sort | md5sum` (optional)
#   --original-worktree-hash <hash>    Review 開始時の `lib/git-status-filtered.sh | md5sum` (optional).
# で raw `git status --porcelain` から sandbox ghost-mount
#                                      フィルタ経由に変更 — snapshot 側もこのコマンドで計算すること)
#   --auto-recover                     drift 検出時に automatic recovery を行う (default: true)
#
# State vector axes (drift 検出の優先順): branch → stash → branch_list → worktree。
# branch drift のみ auto-recover 対象 (exit 1 で block しうる)。stash / branch_list /
# worktree drift は内容を失うリスク回避のため advisory (WARNING + 手動 triage、exit 0)。
#
# Exit codes:
#   0 — no drift, or drift detected and (branch) successfully recovered,
#       or advisory drift (stash / branch_list / worktree)
#   1 — branch drift detected and recovery failed (manual intervention required)
#   2 — invalid arguments
#
# Output:
#   stderr: WARNING/ERROR messages
#   stdout: machine-readable JSON summary
#     {"drift": false}
#     {"drift": true, "type": "branch", "from": "...", "to": "...", "recovered": true}
#     {"drift": true, "type": "worktree", "detail": "...", "recovered": false}

set -uo pipefail  # 意図的に -e なし: drift detection 自体を fail とせず、結果を JSON で返す

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORIGINAL_BRANCH=""
ORIGINAL_STASH_COUNT=""
ORIGINAL_BRANCH_LIST_HASH=""
ORIGINAL_WORKTREE_HASH=""
AUTO_RECOVER="true"

# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定 + `${2:-}` (nounset 非発火) の下で無限ループに
# 陥る。1 回目の shift で $# を確実に 0 にし、2 回目は no-op で安全に抜ける
# (--original-branch 欠落はループ後の必須チェックが exit 2 で検出)。
while [ $# -gt 0 ]; do
  case "$1" in
    --original-branch)
      ORIGINAL_BRANCH="${2:-}"
      shift; shift
      ;;
    --original-stash-count)
      ORIGINAL_STASH_COUNT="${2:-}"
      shift; shift
      ;;
    --original-branch-list-hash)
      ORIGINAL_BRANCH_LIST_HASH="${2:-}"
      shift; shift
      ;;
    --original-worktree-hash)
      ORIGINAL_WORKTREE_HASH="${2:-}"
      shift; shift
      ;;
    --auto-recover)
      AUTO_RECOVER="${2:-true}"
      shift; shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$ORIGINAL_BRANCH" ]; then
  echo "ERROR: --original-branch is required" >&2
  exit 2
fi

# --- ORIGINAL_BRANCH の charset validation (security-reviewer cycle 1 fix) ---
# `git checkout` に `--orphan=evil` 等の option-like 値が渡って recovery 経路自身が
# branch leak を起こす経路を防ぐ。git branch 名として valid な ASCII allowlist のみ受理:
#   - 英数字 / `_` / `-` / `.` / `/` (refs/heads/foo/bar 階層)
#   - `DETACHED:` prefix (Phase 4.0.A の detached HEAD sentinel、+ short hash 7-40 chars)
case "$ORIGINAL_BRANCH" in
  DETACHED:*)
    # detached HEAD sentinel — branch drift check は skip し、stash/branch_list のみ評価
    ;;
  --*|-=*|*=*|*$'\n'*|*$'\r'*|*$'\t'*)
    echo "ERROR: --original-branch contains disallowed characters (option-like prefix, '=' or control char): '$ORIGINAL_BRANCH'" >&2
    exit 2
    ;;
esac
case "$ORIGINAL_BRANCH" in
  *[!A-Za-z0-9._/+:-]*)
    # allowlist: 英数字 + `.` + `_` + `-` + `/` + `+` + `:` (DETACHED: 用)
    echo "ERROR: --original-branch contains characters outside the allowed charset: '$ORIGINAL_BRANCH'" >&2
    exit 2
    ;;
esac

# --- 現在の state を取得 ---
# md5sum portability: Linux では md5sum、macOS では shasum を fallback として使う。
# どちらも stdout 先頭 token が hash であるため awk で抽出可能。
_hash_cmd=""
if command -v md5sum >/dev/null 2>&1; then
  _hash_cmd="md5sum"
elif command -v shasum >/dev/null 2>&1; then
  _hash_cmd="shasum"
fi

current_branch=$(git branch --show-current 2>/dev/null || echo "")
current_stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$_hash_cmd" ]; then
  current_branch_list_hash=$(git branch --list 2>/dev/null | sort | "$_hash_cmd" 2>/dev/null | awk '{print $1}')
else
  current_branch_list_hash=""
fi
# Worktree axis: `git status --porcelain` hash captures working-tree
# + index drift (modified / staged / untracked) that the branch / stash /
# branch_list axes cannot see — e.g. a reviewer editing a source file in place via
# Edit/Write and hand-restoring it, or leaving a `.bak` untracked. Advisory only.
# Routed through git-status-filtered.sh rather than raw `git status --porcelain`:
# the snapshot side (pr-review SKILL.md ステップ 4.0.A) and this verify side can run in
# different sandbox contexts, and a bwrap sandbox overlays ghost-mount `??` entries
# that vary by context — comparing raw porcelain hashes false-positives on
# those ghost entries alone. The filter drops them on both sides so the hash reflects
# only real working-tree changes.
# Unlike raw `git status --porcelain`, the filter depends on `mktemp` (sandbox TMPDIR
# restrictions can make this fail even though plain `git status` would succeed), so its
# exit code is checked explicitly. The filter's own output is captured first (not piped
# directly into the hash command) so the check does not depend on `pipefail` — this
# mirrors the capture-first pattern used on the snapshot side (pr-review SKILL.md
# ステップ 4.0.A), which cannot rely on pipefail because each Bash tool invocation starts
# a fresh shell with pipefail off and no state carried over from prior blocks.
if [ -n "$_hash_cmd" ]; then
  _wth_raw=$(bash "$SCRIPT_DIR/lib/git-status-filtered.sh")
  if [ $? -ne 0 ]; then
    echo "WARNING: git-status-filtered.sh failed — worktree drift axis skipped for this check" >&2
    current_worktree_hash=""
  else
    current_worktree_hash=$(printf '%s' "$_wth_raw" | "$_hash_cmd" 2>/dev/null | awk '{print $1}')
  fi
else
  current_worktree_hash=""
fi

# --- Drift detection ---
drift_detected="false"
drift_type=""
drift_detail=""

# Branch drift: detached HEAD sentinel (DETACHED:<hash>) は branch drift check を skip し、
# stash / branch_list のみ評価する (detached HEAD で起動した場合は branch を持たないため、
# branch 一致 check 自体が意味を持たない)。
case "$ORIGINAL_BRANCH" in
  DETACHED:*)
    : ;;  # skip branch drift
  *)
    if [ "$current_branch" != "$ORIGINAL_BRANCH" ]; then
      drift_detected="true"
      drift_type="branch"
      drift_detail="from=$ORIGINAL_BRANCH; to=$current_branch"
    fi
    ;;
esac

if [ "$drift_detected" = "false" ] && [ -n "$ORIGINAL_STASH_COUNT" ] && [ "$current_stash_count" != "$ORIGINAL_STASH_COUNT" ]; then
  drift_detected="true"
  drift_type="stash"
  drift_detail="from_count=$ORIGINAL_STASH_COUNT; to_count=$current_stash_count"
fi

# branch_list_hash check: 両側に hash 値がある場合のみ比較する。
# 空文字列 (hash コマンド非利用 or hash 計算失敗) は比較不可として skip し、silent false-negative を防ぐ。
if [ "$drift_detected" = "false" ] \
   && [ -n "$ORIGINAL_BRANCH_LIST_HASH" ] \
   && [ -n "$current_branch_list_hash" ] \
   && [ "$current_branch_list_hash" != "$ORIGINAL_BRANCH_LIST_HASH" ]; then
  drift_detected="true"
  drift_type="branch_list"
  drift_detail="reviewer leaked named branch(es); compare 'git branch --list' before/after"
fi

# worktree_hash check: 両側に hash 値がある場合のみ比較する。
# 空文字列 (hash コマンド非利用 or hash 計算失敗) は比較不可として skip し silent
# false-negative を防ぐ (branch_list check と同一ガード)。
if [ "$drift_detected" = "false" ] \
   && [ -n "$ORIGINAL_WORKTREE_HASH" ] \
   && [ -n "$current_worktree_hash" ] \
   && [ "$current_worktree_hash" != "$ORIGINAL_WORKTREE_HASH" ]; then
  drift_detected="true"
  drift_type="worktree"
  drift_detail="reviewer mutated the working tree/index (Edit/Write or state-changing git); compare 'git status --porcelain' before/after"
fi

if [ "$drift_detected" = "false" ]; then
  printf '{"drift":false}\n'
  exit 0
fi

# --- Drift 検出 — WARNING + recovery attempt ---
echo "WARNING: Reviewer subagent caused parent session state drift" >&2
echo "  type: $drift_type" >&2
echo "  detail: $drift_detail" >&2
# 破られた防御層の案内は drift 軸で出し分ける: worktree drift は Edit/Write 経路なら
# pre-tool-edit-guard が block したはずだが、Bash 経由の state-changing git は機械ゲート
# されない（verb 列挙では安全に網羅できないため、本スクリプトの事後検出を正とする）。それ以外の軸
# (branch / stash / branch_list) も同様に prompt 契約 (Layer 1) violation であり、
# 本スクリプトによる検出が想定どおりの動作となる。
if [ "$drift_type" = "worktree" ]; then
  echo "  context: the reviewer prompt READ-ONLY contract (_reviewer-base.md) was violated via Edit/Write (pre-tool-edit-guard should have blocked — investigate subagent detection / hook registration) or via a state-changing git command (working-tree git verbs are not pre-blocked because exhaustive command matching is unsafe; this post-condition check is the designed guarantee)" >&2
else
  echo "  context: the reviewer prompt READ-ONLY contract (_reviewer-base.md) was violated via a state-changing git command — working-tree git verbs are not pre-blocked because exhaustive command matching is unsafe; this post-condition detection is the designed guarantee (Layer 3)" >&2
fi

recovered="false"
recovery_error=""

if [ "$AUTO_RECOVER" = "true" ] && [ "$drift_type" = "branch" ]; then
  # `refs/heads/<name>` 経由で明示参照することで `git checkout <option-like-value>` の
  # option injection 経路 (security-reviewer empirical 検証で `--orphan=evil` で branch leak
  # 再現) を遮断する。ORIGINAL_BRANCH は冒頭の charset validation 通過済だが、defense-in-depth
  # で refs/heads/ prefix を付与し、`git checkout` の flag 解釈経路を確実に閉じる。
  echo "  recovery: attempting 'git checkout refs/heads/$ORIGINAL_BRANCH'..." >&2
  if checkout_output=$(git checkout "refs/heads/$ORIGINAL_BRANCH" 2>&1); then
    recovered="true"
    echo "  recovery: succeeded" >&2
  else
    echo "  recovery: FAILED — git checkout error: $checkout_output" >&2
    echo "  manual action: run 'git checkout $ORIGINAL_BRANCH' to restore the working tree" >&2
  fi
fi

# stash drift / branch_list drift は自動 recovery しない (stash の中身を失うリスク)
if [ "$drift_type" = "stash" ]; then
  echo "  recovery: SKIPPED (stash recovery not auto-applied — stash entries may contain reviewer work)" >&2
  echo "  manual action: inspect 'git stash list' and decide whether to drop or apply each entry" >&2
fi

if [ "$drift_type" = "branch_list" ]; then
  echo "  recovery: SKIPPED (named branch leak — orchestrator side pr-cycle-cleanup.sh will sweep)" >&2
  echo "  manual action: review 'git branch --list' for unexpected names matching reviewer experiment patterns" >&2
fi

# worktree drift は自動 recovery しない (reviewer が加えた変更を破棄すると PR ブランチの
# 正当な作業まで巻き添えにするリスク。auto-recover は内容消失を避けるため明示的な non-goal)。
if [ "$drift_type" = "worktree" ]; then
  echo "  recovery: SKIPPED (working-tree drift is not auto-recovered — a blind revert could discard legitimate PR work)" >&2
  echo "  manual action: run 'git status --porcelain' and 'git diff' to triage the drift; a reviewer subagent likely edited a file in place (Edit/Write) or ran a state-changing git command — restore intended state manually before /rite:fix consumes the diff" >&2
fi

# --- JSON summary ---
# `drift_detail` / `drift_type` は他 hook script 由来の長文メッセージを内包する可能性があるため、
# printf で JSON value に直接埋め込むのではなく jq で escape する。
# `recovered` は "true"/"false" 文字列を JSON boolean に変換する。
jq -nc --arg t "$drift_type" --arg d "$drift_detail" --arg r "$recovered" \
  '{drift: true, type: $t, detail: $d, recovered: ($r == "true")}'

# Exit code: recovered=true → 0、recovered=false → 1 (manual intervention required)
if [ "$recovered" = "true" ] || [ "$drift_type" = "stash" ] || [ "$drift_type" = "branch_list" ] || [ "$drift_type" = "worktree" ]; then
  # stash/branch_list/worktree は自動 recover しないが advisory として exit 0 (review flow を block しない)
  exit 0
fi
exit 1
