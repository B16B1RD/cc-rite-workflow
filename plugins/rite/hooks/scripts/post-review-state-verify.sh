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
#   bash post-review-state-verify.sh --snapshot
#   bash post-review-state-verify.sh \
#       --original-branch <name> \
#       [--original-stash-count <N>] \
#       [--original-branch-list-hash <hash>] \
#       [--original-worktree-hash <hash>] \
#       [--auto-recover true|false]
#
# Arguments:
#   --snapshot                         Review 開始時の 4 値を 1 行で出力する:
#                                      `review_pre_state: branch=<b> stash_count=<n> branch_list_hash=<h> worktree_hash=<h>`
#                                      verify と同じ関数で算出するため、両側の算出方法は構造上一致する。
#   --original-branch <name>           Review 開始時の current branch 名 (required。detached は DETACHED:<short-hash>)
#   --original-stash-count <N>         Review 開始時の、件名の branch が他セッションの worktree で checkout 中でない stash の件数 (optional)
#   --original-branch-list-hash <hash> Review 開始時の、他セッションの worktree で checkout 中でない branch 一覧の hash (optional)
#   --original-worktree-hash <hash>    Review 開始時の `lib/git-status-filtered.sh --tracked-only` の hash (optional)
#   --auto-recover                     drift 検出時に automatic recovery を行う (default: true)
#
# State vector axes: branch / stash / branch_list / worktree の 4 軸を recovery より前に
# すべて独立に評価し、変化した軸をすべて報告する。優先順 branch → stash → branch_list →
# worktree は JSON の `type`（最初に見つかった軸）の選定にだけ使う。
# branch drift のみ auto-recover 対象 (exit 1 で block しうる)。stash / branch_list /
# worktree drift は内容を失うリスク回避のため advisory (WARNING + 手動 triage、exit 0)。
#
# refs/heads と refs/stash は全 worktree で共有されるため、並列セッションの操作をレビュー中の
# drift と誤認しないよう、2 軸は他セッションの worktree で checkout 中の branch を除いて数える。
# 他セッションの worktree = 自 worktree 以外で、reviewer 実験用の名前空間
# (rite-review-mutation-* / rite-revert-test-*) にないもの (パスは物理パスで比較)。
# ただし reviewer 漏出名 (pr-<N>-cycle<X> / pr-<N>-test / pr-<N>-experiment / pr-<N>-mutation /
# pr-<N>-verify / pr-<N>-check / pr-<N>-sandbox。pr-cycle-cleanup.sh の PATTERN と同じ集合) の
# branch は含めない:
#   - stash: 件名 `WIP on <b>:` / `On <b>:` の <b> がその集合にないエントリ。git は同じ branch を
#     2 つの worktree で checkout させないため、named branch の件名はそれを checkout した worktree を
#     指す。自 worktree で別 branch へ切り替えて作った stash も数える
#   - branch_list: その集合を除いた一覧
# 残余 (判別子の外にあるもの):
#   - 報告側に倒れる: 他セッションが checkout していない branch の作成・削除、他 worktree
#     での branch の切り替え (元の branch が除外から外れて一覧に現れる)、detached の worktree
#     が作った stash (件名 `(no branch)` は branch ではないので常に数える)、他セッションが
#     stash した後に worktree を片付けたもの
#   - 数えない: reviewer が名前空間の外に `git worktree add -b` で作った worktree の branch のうち、
#     漏出名に当たらないもの (他セッションの branch と区別できない)
#
# Exit codes:
#   0 — no drift, or drift detected and (branch) successfully recovered
#       (HEAD is back on the original branch after the switch),
#       or advisory drift only (stash / branch_list / worktree), or --snapshot
#   1 — branch drift detected and recovery failed (manual intervention required)
#   2 — invalid arguments
#
# Output:
#   stderr: WARNING/ERROR messages
#   stdout: --snapshot は review_pre_state 行、verify は machine-readable JSON summary
#     {"drift":false}
#     {"drift":true,"type":"branch","types":["branch"],"detail":"...","recovered":true}
#     {"drift":true,"type":"stash","types":["stash","worktree"],"detail":"...","recovered":false}

set -uo pipefail  # 意図的に -e なし: drift detection 自体を fail とせず、結果を JSON で返す

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="verify"
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
    --snapshot)
      MODE="snapshot"
      shift
      ;;
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

# --- 4 軸の算出 (snapshot / verify 共通) ---
# md5sum portability: Linux では md5sum、macOS では shasum を fallback として使う。
# どちらも stdout 先頭 token が hash であるため awk で抽出可能。
_hash_cmd=""
if command -v md5sum >/dev/null 2>&1; then
  _hash_cmd="md5sum"
elif command -v shasum >/dev/null 2>&1; then
  _hash_cmd="shasum"
fi

# 物理パス。存在しないディレクトリは入力のまま返す (登録だけ残る worktree 用)。
_physical_path() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

axis_branch() {
  local b
  b=$(git branch --show-current 2>/dev/null || echo "")
  if [ -z "$b" ]; then
    b="DETACHED:$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  fi
  printf '%s\n' "$b"
}

# 他セッションの worktree で checkout 中の branch を _foreign に集め、全 branch を _all_branches に
# 入れる。reviewer 実験用の名前空間 (rite-review-mutation-* / rite-revert-test-*) の worktree と、
# reviewer 漏出名の branch は他セッションのものではないので _foreign に入れない。取得に失敗したら非ゼロ。
# 漏出名の正規表現は pr-cycle-cleanup.sh の PATTERN とリテラルで一致させる (テストが一致を固定する)。
_reviewer_leak_re='^pr-[0-9]+-(cycle[0-9]+|test|experiment|mutation|verify|check|sandbox)$'
declare -A _foreign=()
_all_branches=""
_load_branches() {
  local top refs name wt
  _foreign=()
  _all_branches=""
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  refs=$(git for-each-ref --format='%(refname:short)%09%(worktreepath)' refs/heads 2>/dev/null) || return 1
  top=$(_physical_path "$top")
  while IFS=$'\t' read -r name wt; do
    [ -n "$name" ] || continue
    _all_branches+="$name"$'\n'
    [ -n "$wt" ] || continue
    case "${wt##*/}" in *rite-review-mutation-*|*rite-revert-test-*) continue ;; esac
    [[ $name =~ $_reviewer_leak_re ]] && continue
    [ "$(_physical_path "$wt")" = "$top" ] || _foreign[$name]=1
  done <<< "$refs"
}

# 件名の branch が他セッションの worktree で checkout 中でない stash の件数。
# 取得に失敗したら空文字列 (その軸は比較不可として skip)。
axis_stash_count() {
  local subjects s b n=0
  if ! _load_branches || ! subjects=$(git stash list --format=%gs 2>/dev/null); then
    echo "WARNING: git stash list / for-each-ref failed — stash drift axis skipped for this check" >&2
    return 0
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case "$s" in
      "WIP on "*) b=${s#WIP on } ;;
      "On "*) b=${s#On } ;;
      *) b="" ;;
    esac
    b=${b%%:*}
    [ -n "$b" ] && [ -n "${_foreign[$b]:-}" ] && continue
    n=$((n + 1))
  done <<< "$subjects"
  printf '%s\n' "$n"
}

axis_branch_list_hash() {
  [ -n "$_hash_cmd" ] || return 0
  local name kept=""
  if ! _load_branches; then
    echo "WARNING: git rev-parse / for-each-ref failed — branch_list drift axis skipped for this check" >&2
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -n "${_foreign[$name]:-}" ] && continue
    kept+="$name"$'\n'
  done <<< "$_all_branches"
  printf '%s' "$kept" | LC_ALL=C sort | "$_hash_cmd" 2>/dev/null | awk '{print $1}'
}

# Snapshot and verification both hash tracked status only. Untracked paths can
# vary across sandbox contexts; the helper reports them separately as WARNINGs.
# Capture before hashing so helper failures cannot become a clean-tree hash.
axis_worktree_hash() {
  [ -n "$_hash_cmd" ] || return 0
  local raw
  if ! raw=$(bash "$SCRIPT_DIR/lib/git-status-filtered.sh" --tracked-only); then
    echo "WARNING: git-status-filtered.sh failed — worktree drift axis skipped for this check" >&2
    return 0
  fi
  printf '%s' "$raw" | "$_hash_cmd" 2>/dev/null | awk '{print $1}'
}

if [ "$MODE" = "snapshot" ]; then
  printf 'review_pre_state: branch=%s stash_count=%s branch_list_hash=%s worktree_hash=%s\n' \
    "$(axis_branch)" "$(axis_stash_count)" "$(axis_branch_list_hash)" "$(axis_worktree_hash)"
  exit 0
fi

if [ -z "$ORIGINAL_BRANCH" ]; then
  echo "ERROR: --original-branch is required" >&2
  exit 2
fi

# --- ORIGINAL_BRANCH の charset validation ---
# recovery の `git switch` に `--orphan=evil` / `-c` 等の option-like 値が渡って recovery 経路自身が
# branch leak を起こす経路を防ぐ。git は `-` で始まる branch 名を認めないため、`-*` の拒否で
# 正当な branch 名は失われない。git branch 名として valid な ASCII allowlist のみ受理:
#   - 英数字 / `_` / `-` / `.` / `/` (refs/heads/foo/bar 階層)
#   - `DETACHED:` prefix (snapshot の detached HEAD sentinel、+ short hash 7-40 chars)
case "$ORIGINAL_BRANCH" in
  DETACHED:*)
    # detached HEAD sentinel — branch drift check は skip し、他の軸のみ評価
    ;;
  -*|*=*|*$'\n'*|*$'\r'*|*$'\t'*)
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

# --- 現在の state を取得 (recovery より前に全軸を確定させる) ---
current_branch=$(git branch --show-current 2>/dev/null || echo "")
current_stash_count=$(axis_stash_count)
current_branch_list_hash=$(axis_branch_list_hash)
current_worktree_hash=$(axis_worktree_hash)

# --- Drift detection (全軸を独立に評価) ---
drift_types=()
declare -A drift_detail=()

# Branch drift: detached HEAD sentinel (DETACHED:<hash>) は branch を持たないため
# branch 一致 check 自体が意味を持たず skip する。
case "$ORIGINAL_BRANCH" in
  DETACHED:*)
    : ;;
  *)
    if [ "$current_branch" != "$ORIGINAL_BRANCH" ]; then
      drift_types+=("branch")
      drift_detail[branch]="from=$ORIGINAL_BRANCH; to=$current_branch"
    fi
    ;;
esac

# 以下の 3 軸は両側に値がある場合のみ比較する。空文字列 (hash コマンド非利用 / 算出失敗) は
# 比較不可として skip し、silent false-negative を防ぐ。
if [ -n "$ORIGINAL_STASH_COUNT" ] && [ -n "$current_stash_count" ] \
   && [ "$current_stash_count" != "$ORIGINAL_STASH_COUNT" ]; then
  drift_types+=("stash")
  drift_detail[stash]="from_count=$ORIGINAL_STASH_COUNT; to_count=$current_stash_count"
fi

if [ -n "$ORIGINAL_BRANCH_LIST_HASH" ] && [ -n "$current_branch_list_hash" ] \
   && [ "$current_branch_list_hash" != "$ORIGINAL_BRANCH_LIST_HASH" ]; then
  drift_types+=("branch_list")
  drift_detail[branch_list]="reviewer leaked named branch(es); compare 'git branch --list' before/after"
fi

if [ -n "$ORIGINAL_WORKTREE_HASH" ] && [ -n "$current_worktree_hash" ] \
   && [ "$current_worktree_hash" != "$ORIGINAL_WORKTREE_HASH" ]; then
  drift_types+=("worktree")
  drift_detail[worktree]="reviewer mutated the working tree/index (Edit/Write or state-changing git); compare 'git status --porcelain' before/after"
fi

if [ "${#drift_types[@]}" -eq 0 ]; then
  printf '{"drift":false}\n'
  exit 0
fi

# --- Drift 検出 — 軸ごとの WARNING + recovery attempt ---
echo "WARNING: Reviewer subagent caused parent session state drift" >&2
recovered="false"
for drift_type in "${drift_types[@]}"; do
  echo "  type: $drift_type" >&2
  echo "  detail: ${drift_detail[$drift_type]}" >&2
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

  case "$drift_type" in
    branch)
      if [ "$AUTO_RECOVER" = "true" ]; then
        # `--` で option 解釈を閉じる。`--no-guess` は local branch が消えていたときに
        # remote-tracking branch から作り直して未 push の commit の消失を隠すのを防ぐ。
        # 完全な ref 名 (refs/heads/<b>) は detached HEAD になるため使わない。
        echo "  recovery: attempting 'git switch --no-guess -- $ORIGINAL_BRANCH'..." >&2
        if switch_output=$(git switch --no-guess -- "$ORIGINAL_BRANCH" 2>&1); then
          # switch の exit 0 だけでは元の branch に戻った証拠にならないため、HEAD を照合する。
          after_branch=$(git branch --show-current 2>/dev/null || echo "")
          if [ "$after_branch" = "$ORIGINAL_BRANCH" ]; then
            recovered="true"
            echo "  recovery: succeeded" >&2
          else
            echo "  recovery: FAILED — HEAD is on '${after_branch:-<detached>}', not '$ORIGINAL_BRANCH', after git switch" >&2
            echo "  manual action: run 'git switch --no-guess -- $ORIGINAL_BRANCH' to restore the working tree" >&2
          fi
        else
          echo "  recovery: FAILED — git switch error: $switch_output" >&2
          echo "  manual action: run 'git switch --no-guess -- $ORIGINAL_BRANCH' to restore the working tree" >&2
        fi
      fi
      ;;
    stash)
      # stash drift / branch_list drift は自動 recovery しない (stash の中身を失うリスク)
      echo "  recovery: SKIPPED (stash recovery not auto-applied — stash entries may contain reviewer work)" >&2
      echo "  manual action: inspect 'git stash list' and decide whether to drop or apply each entry" >&2
      ;;
    branch_list)
      echo "  recovery: SKIPPED (named branch leak — orchestrator side pr-cycle-cleanup.sh will sweep)" >&2
      echo "  manual action: review 'git branch --list' for unexpected names matching reviewer experiment patterns" >&2
      ;;
    worktree)
      # worktree drift は自動 recovery しない (reviewer が加えた変更を破棄すると PR ブランチの
      # 正当な作業まで巻き添えにするリスク。auto-recover は内容消失を避けるため明示的な non-goal)。
      echo "  recovery: SKIPPED (working-tree drift is not auto-recovered — a blind revert could discard legitimate PR work)" >&2
      echo "  manual action: run 'git status --porcelain' and 'git diff' to triage the drift; a reviewer subagent likely edited a file in place (Edit/Write) or ran a state-changing git command — restore intended state manually before /rite:fix consumes the diff" >&2
      ;;
  esac
done

# --- JSON summary ---
# `detail` は長文メッセージを内包する可能性があるため、printf で JSON value に直接埋め込むのでは
# なく jq で escape する。`type` / `detail` は優先順で最初の軸、`types` は変化した全軸。
# `recovered` は branch recovery の成否 ("true"/"false" 文字列を JSON boolean に変換)。
primary="${drift_types[0]}"
printf '%s\n' "${drift_types[@]}" | jq -Rsc --arg t "$primary" --arg d "${drift_detail[$primary]}" --arg r "$recovered" \
  '{drift: true, type: $t, types: (split("\n") | map(select(length > 0))), detail: $d, recovered: ($r == "true")}'

# Exit code: branch drift を復旧できなかったときだけ 1 (manual intervention required)。
# stash / branch_list / worktree は自動 recover しないが advisory として exit 0 (review flow を block しない)。
if [ "$primary" = "branch" ] && [ "$recovered" != "true" ]; then
  exit 1
fi
exit 0
