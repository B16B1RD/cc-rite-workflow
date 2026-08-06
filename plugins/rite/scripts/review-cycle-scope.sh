#!/bin/bash
# rite workflow - Review Cycle Scope Determination (cycle 1 / cycle 2+ 差分スコープ)
#
# Responsibility: 当該 PR の永続レビュー JSON (skills/pr-review/SKILL.md ステップ 6.1.a の
# 保存先 `{state_root}/.rite/review-results/{pr}-*.json`) だけを入力に、今回のレビューを
# full scope (cycle 1) で回すか incremental scope (cycle 2+ 差分スコープ) で回すかを決める。
# あわせて差分の起点 commit と、前サイクルで blocking を出した reviewer_type を抽出する。
#
# 設計根拠の SoT: skills/pr-review/references/cycle-scope.md
#   - なぜ判定入力を PR コメントでなく永続 JSON にするか (既定 post_comment: false)
#   - なぜ二値であって cycle 数の段階判定ではないか (finding-cycling.md の degradation 禁止)
#   - なぜ情報欠落時に必ず full へ倒すか
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 1.2.4 (Review Scope Determination)
#
# Usage:
#   bash review-cycle-scope.sh --pr <n> [--results-dir <dir>]
#
#   --pr           PR 番号 (数値必須)。JSON ファイル名 `{pr}-{timestamp}.json` の照合に使う。
#   --results-dir  review-results ディレクトリ。省略時は hooks/state-path-resolve.sh で解決した
#                  state root 配下 `.rite/review-results` (書込側 hooks/review-result-save.sh と
#                  同一解決。セッション worktree / main checkout のどちらから実行しても同じ物理
#                  パスを読む)。解決失敗時は cwd 相対へフォールバックする。
#
# git 操作は cwd のリポジトリに対して行う (caller はセッション worktree 内で実行する)。
#
# Output — stderr (observability contract。stdout は使わない):
#   [CONTEXT] REVIEW_CYCLE_SCOPE=incremental; base_sha=<sha>; prev_json=<path>; prev_finders=<csv>
#   [CONTEXT] REVIEW_CYCLE_SCOPE=full; reason=<reason>
#   [CONTEXT] REVIEW_CYCLE_SCOPE_FALLBACK=1; reason=<reason>   ← no_prev_json 以外で追加 emit
#   ⚠️ 差分スコープのフォールバック: ...                        ← 同上 (人間向け)
#
#   prev_finders は前サイクルの findings[] (= 5.3.0.M 通過後の blocking 集合) の reviewer を
#   agent 名から reviewer_type へ正規化 (`-reviewer` サフィックス除去) し unique + カンマ区切りに
#   したもの。空になりうる (前サイクルの blocking が 0 件だった場合)。統合済み旧 type
#   (api/frontend/performance/database/type-design) の読み替えは caller 側の責務
#   (skills/reviewers/SKILL.md の Legacy Reviewer Type Aliases 表が SoT)。
#
# Fallback reason 語彙 (SoT。skills/pr-review/SKILL.md ステップ 1.2.4 の reason 表と同期):
#   no_prev_json          — 当該 PR の review-results JSON が無い (cycle 1 の正常経路。WARNING なし)
#   prev_json_unreadable  — JSON が壊れている / jq で読めない / 探索中に IO エラー
#   commit_sha_missing    — .commit_sha が空 / null / キー欠落 (旧形式)
#   commit_sha_unreachable— 起点 commit が履歴から消失 (force-push / rebase)
#   diff_failed           — git diff {sha}..HEAD が失敗
#   jq_missing            — jq が PATH 上に無い
#
# Exit codes:
#   0 = スコープ決定完了 (incremental / full のいずれも正常終了)
#   2 = usage error (--pr 欠落 / 非数値)
#
# Why fail-safe instead of fail-loud on jq_missing:
#   sibling helper (review-measured-gate.sh 等) は jq 不在を exit 1 の fatal として扱う。それらは
#   レビュー結果 JSON を **書き換える** ため、環境が壊れた状態で先へ進ませてはならないからである。
#   本 script は状態を書き換えず「どちらのスコープで回すか」を選ぶだけで、情報が何も得られない
#   ときの安全な選択 (full = 従来どおりの徹底レビュー) が常に存在する。ここで exit 1 を返すと
#   caller の bash が失敗し、スコープ最適化の失敗がレビュー自体の失敗に昇格してしまう。
#   これは Issue #2118 AC-3 が要求する「取得不能なら WARNING を出してフルレビューへ倒れる」の
#   契約そのものでもある。silent fallback ではない — 全経路で reason 付き marker を emit する。
set -uo pipefail

_rcs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/scripts/lib/tempfile.sh
source "$_rcs_dir/../hooks/scripts/lib/tempfile.sh"

PR_NUMBER=""
RESULTS_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)          PR_NUMBER="${2:-}"; shift 2 ;;
    --results-dir) RESULTS_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: review-cycle-scope: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-cycle-scope: --pr は数値必須です (received: '${PR_NUMBER}')" >&2
    exit 2 ;;
esac

# full へ倒して終了する共通経路。no_prev_json だけは cycle 1 の正常経路なので WARNING を出さない。
emit_full() {
  local reason="$1"
  echo "[CONTEXT] REVIEW_CYCLE_SCOPE=full; reason=$reason" >&2
  if [ "$reason" != "no_prev_json" ]; then
    echo "⚠️ 差分スコープのフォールバック: reason=${reason}。フルレビュー (全 reviewer・フル diff) で実行します。" >&2
    echo "[CONTEXT] REVIEW_CYCLE_SCOPE_FALLBACK=1; reason=$reason" >&2
  fi
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_full jq_missing

if [ -z "$RESULTS_DIR" ]; then
  if _rcs_root=$(bash "$_rcs_dir/../hooks/state-path-resolve.sh" "$PWD" 2>/dev/null) && [ -n "$_rcs_root" ]; then
    RESULTS_DIR="$_rcs_root/.rite/review-results"
  else
    echo "WARNING: review-cycle-scope: state-path-resolve.sh の解決に失敗。cwd 相対の .rite/review-results へフォールバックします" >&2
    RESULTS_DIR=".rite/review-results"
  fi
fi

# dir 不在は初回レビュー (cycle 1) の正常経路
[ -d "$RESULTS_DIR" ] || emit_full no_prev_json

rite_tempfile_init
rite_tempfile_new find_err "rcs-find-err" || emit_full prev_json_unreadable

# mapfile + process substitution で SIGPIPE 経路を断つ (scripts/review-source-resolve.sh Priority 2 と同形)。
# sort の stderr も同じファイルへ追記し、探索段の IO エラーを取りこぼさない。
cs_files=()
mapfile -t cs_files < <(find "$RESULTS_DIR" -maxdepth 1 -type f -name "${PR_NUMBER}-*.json" 2>"$find_err" | sort -r 2>>"$find_err")

# IO エラーを「JSON が無い (= cycle 1)」と誤認すると、探索に失敗しただけの状態が silent に
# cycle 1 扱いになる。loud な prev_json_unreadable として区別する。
if [ -s "$find_err" ]; then
  echo "WARNING: review-cycle-scope: $RESULTS_DIR/ の探索でエラーが発生しました:" >&2
  head -3 "$find_err" | sed 's/^/  /' >&2
  emit_full prev_json_unreadable
fi

prev_json="${cs_files[0]:-}"
[ -n "$prev_json" ] || emit_full no_prev_json

jq empty "$prev_json" 2>/dev/null || emit_full prev_json_unreadable

base_sha=$(jq -r '.commit_sha // empty' "$prev_json" 2>/dev/null)
[ -n "$base_sha" ] || emit_full commit_sha_missing

# `^{commit}` を付けて「commit として解決できる」ことまで確認する (blob/tree の SHA を誤って
# 起点に据えない)。force-push / rebase で起点が履歴から消えた場合はここで落ちる。
git cat-file -e "${base_sha}^{commit}" 2>/dev/null || emit_full commit_sha_unreachable

git diff --name-only "${base_sha}..HEAD" >/dev/null 2>&1 || emit_full diff_failed

# findings[] は 5.3.0.M 通過後の blocking 集合。reviewer は agent 名 (`code-quality-reviewer`) で
# 入るため reviewer_type (`code-quality`) へ正規化する。jq 失敗時も空文字で incremental を維持する
# — 起点 sha と diff は取れており差分スコープ自体は成立する。finder が空なら caller の選抜は
# fix diff の領域担当のみになり、既存の sole-reviewer guard / min_reviewers フロアが下限を守る。
prev_finders=$(jq -r '[.findings[]?.reviewer | select(type == "string") | sub("-reviewer$";"")] | unique | join(",")' "$prev_json" 2>/dev/null) || prev_finders=""

echo "[CONTEXT] REVIEW_CYCLE_SCOPE=incremental; base_sha=$base_sha; prev_json=$prev_json; prev_finders=$prev_finders" >&2
exit 0
