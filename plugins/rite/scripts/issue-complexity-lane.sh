#!/bin/bash
# rite workflow - Issue Complexity Lane Determination (XS/S 軽量レーン)
#
# Responsibility: 対象 Issue の**宣言 Complexity** だけを入力に、後続工程を軽量レーン (light)
# で回すかフル装備 (full) で回すかを決める。判定器は作らない — 宣言値をそのまま読む
# (判定器は speculative であり、宣言 + Cross-File Impact Check の安全網で足りるため)。
#
# 設計根拠の SoT: skills/pr-review/references/complexity-lane.md
#   - なぜレーン境界を {XS, S} / {M, L, XL} の二値にするか
#   - なぜ reviewer 上限を reviewers/SKILL.md Phase 5 に置くか (cap の SoT は 1 つ)
#   - 何を軽量化し、何を軽量化しないか (採否基準・Cross-File Impact Check は不変)
#   - なぜ情報欠落時に必ず full へ倒すか
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 1.3.2 (Complexity Lane Determination)
#   - skills/issue-implement/SKILL.md 5.1.0.1 (Complexity 判定 / XS 生産量制約)
#
# Usage:
#   bash issue-complexity-lane.sh --issue <n> [--repo <owner/repo>]
#
#   --issue  Issue 番号 (数値必須)。
#   --repo   owner/repo (slash 形式)。省略時は hooks/scripts/lib/git-remote.sh resolve-owner-repo
#            → `gh repo view` の順で解決する。`gh` には常に -R を明示する
#            (省略すると SSH host alias 環境で別リポジトリを引く — references/gh-cli-patterns.md)。
#
# Complexity の抽出元は Issue body のみ (flow-state は complexity フィールドを持たない)。
# リポジトリ内に 2 つの記法が併存するため**両方**を受理する — 片方だけ読むと、もう片方で
# 書かれた Issue が全て complexity_absent で full へ倒れ、レーンが一度も発動しない:
#   1. `**Complexity**: X`  — templates/issue/template-structure.md Section 0 Meta (現行 rite 形式)
#   2. `## 複雑度` セクション — skills/rite-workflow/references/common-principles.md の記載形式
# 先に見つかった方を採る (1 を優先)。値は大小文字を問わず XS/S/M/L/XL に正規化する。
#
# Output — stderr (observability contract。stdout は使わない):
#   [CONTEXT] COMPLEXITY_LANE=light; complexity=<XS|S>; source=<body_meta|body_section>
#   [CONTEXT] COMPLEXITY_LANE=full; complexity=<M|L|XL>; source=<body_meta|body_section>
#   [CONTEXT] COMPLEXITY_LANE=full; reason=<reason>                 ← fail-safe 経路
#   [CONTEXT] COMPLEXITY_LANE_FALLBACK=1; reason=<reason>           ← fail-safe 経路で追加 emit
#   ⚠️ Complexity レーン判定のフォールバック: ...                    ← 同上 (人間向け)
#
# Fallback reason 語彙 (SoT。skills/pr-review/SKILL.md ステップ 1.3.2 /
# skills/pr-review/references/complexity-lane.md の reason 表と同期):
#   gh_missing            — gh が PATH 上に無い
#   repo_unresolved       — owner/repo を解決できず -R を付けて gh を呼べない
#   issue_fetch_failed    — gh issue view が失敗した (認証切れ / rate limit / Issue 不在)
#   complexity_absent     — body に上記 2 記法のいずれも無い (rite 外で作られた Issue 等)
#   complexity_invalid    — 値が XS/S/M/L/XL のいずれでもない (誤記 / 未展開の placeholder)
#
# 上記に加え、**本 script では表現できない** consumer 側の reason が 2 つある。いずれも本 script を
# 呼べない / 呼んだが marker が得られない状況そのものを指すため、caller 側 (SKILL.md) に置く:
#   issue_number_missing  — 関連 Issue を特定できず --issue を渡せない (本 script は未起動)
#   helper_failed         — 本 script が marker を出さずに非ゼロ終了した (usage error 等)
#
# 全 fallback reason は **full へ倒れる** (reason は分岐を変えない)。欠落時の安全側は常に
# 「儀式を減らさない方」= full である。詳細: complexity-lane.md「fail-safe は必ず full へ倒す」。
#
# Exit codes:
#   0 = レーン決定完了 (light / full のいずれも正常終了)
#   2 = usage error (--issue 欠落 / 非数値 / 未知フラグ)
#
# Why fail-safe instead of fail-loud:
#   本 script は状態を書き換えず「どちらのレーンで回すか」を選ぶだけで、情報が何も得られない
#   ときの安全な選択 (full = 現行フル装備) が常に存在する。ここで exit 1 を返すと caller の
#   bash が失敗し、儀式コスト最適化の失敗がレビュー / 実装そのものの失敗に昇格してしまう。
#   sibling の scripts/review-cycle-scope.sh と同じ判断で、同じく silent fallback ではない
#   (全経路で reason 付き marker を emit する)。
set -uo pipefail

_icl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ISSUE_NUMBER=""
OWNER_REPO=""

# `shift 2` は使わない。値なしフラグが argv 末尾に来ると n > $# で shift が $# を変えずに rc=1 を
# 返し、set -e 非設定 + ${2:-} で nounset も発火しない本 script では while を抜けられず hang する
# (無人ループの /rite:iterate / /rite:batch-run では診断ゼロの無期限停止になる)。1 回目の shift で
# $# を確実に 0 にし 2 回目を no-op にする house convention に従う
# (sibling: scripts/review-cycle-scope.sh、機械検査: hooks/tests/shift2-loop-hardening.test.sh)。
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) ISSUE_NUMBER="${2:-}"; shift; shift ;;
    --repo)  OWNER_REPO="${2:-}"; shift; shift ;;
    *) echo "ERROR: issue-complexity-lane: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$ISSUE_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: issue-complexity-lane: --issue は数値必須です (received: '${ISSUE_NUMBER}')" >&2
    exit 2 ;;
esac

# full へ倒して終了する共通経路。reason は分岐を変えず、全経路が WARNING を伴う
# (sibling の review-cycle-scope.sh は cycle 1 正常経路の no_prev_json だけを無警告にするが、
#  本 script には「情報が無いのが正常」な reason が存在しない — Complexity は rite が作る
#  全 Issue の Section 0 Meta に必ずあるため、欠落は常に調査に値する)。
emit_full_fallback() {
  local reason="$1"
  echo "[CONTEXT] COMPLEXITY_LANE=full; reason=$reason" >&2
  echo "⚠️ Complexity レーン判定のフォールバック: reason=${reason}。フル装備 (M+ 相当) で実行します。" >&2
  echo "[CONTEXT] COMPLEXITY_LANE_FALLBACK=1; reason=$reason" >&2
  exit 0
}

command -v gh >/dev/null 2>&1 || emit_full_fallback gh_missing

if [ -z "$OWNER_REPO" ]; then
  _or_line=$(bash "$_icl_dir/../hooks/scripts/lib/git-remote.sh" resolve-owner-repo 2>/dev/null) || _or_line=""
  if [ -n "$_or_line" ]; then
    IFS=$'\t' read -r _or_owner _or_repo <<< "$_or_line"
    [ -n "$_or_owner" ] && [ -n "$_or_repo" ] && OWNER_REPO="$_or_owner/$_or_repo"
  fi
fi
if [ -z "$OWNER_REPO" ]; then
  OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || OWNER_REPO=""
fi
[ -n "$OWNER_REPO" ] || emit_full_fallback repo_unresolved

# 取得失敗と「body が空の Issue」を区別する。gh の rc を捨てて本文の空判定だけで倒すと、
# 認証切れ (fetch 失敗) が complexity_absent として報告され、原因の切り分けができなくなる。
_icl_err=$(mktemp "${TMPDIR:-/tmp}/rite-complexity-lane-err-XXXXXX") || _icl_err=""
if ! _body=$(gh issue view "$ISSUE_NUMBER" -R "$OWNER_REPO" --json body --jq '.body' 2>"${_icl_err:-/dev/null}"); then
  if [ -n "$_icl_err" ] && [ -s "$_icl_err" ]; then
    echo "WARNING: issue-complexity-lane: gh issue view が失敗しました (issue=#${ISSUE_NUMBER}, repo=${OWNER_REPO}):" >&2
    head -3 "$_icl_err" | sed 's/^/  /' >&2
  fi
  rm -f "${_icl_err:-}"
  emit_full_fallback issue_fetch_failed
fi
rm -f "${_icl_err:-}"

# 記法 1: `**Complexity**: X` (Section 0 Meta)。装飾の揺れ (太字なし / 全角コロン) は受理しない —
# テンプレート由来の 1 形式だけを pin し、崩れた記法は complexity_absent として可視化する。
_raw=$(printf '%s\n' "$_body" | sed -n 's/^[[:space:]]*\*\*Complexity\*\*:[[:space:]]*\([A-Za-z]\{1,2\}\).*$/\1/p' | head -1)
_source="body_meta"

# 記法 2: `## 複雑度` セクション。見出しの次に現れる最初の非空行から値を取る
# (`M` 単独行 / `- M` / `**M**` のいずれも許容する。common-principles.md は書式を固定していない)。
if [ -z "$_raw" ]; then
  _raw=$(printf '%s\n' "$_body" \
    | awk '/^##[[:space:]]+複雑度[[:space:]]*$/{f=1; next} f && NF {print; exit}' \
    | sed -n 's/.*\b\([Xx][Ss]\|[SsMmLl]\|[Xx][Ll]\)\b.*/\1/p' | head -1)
  _source="body_section"
fi

[ -n "$_raw" ] || emit_full_fallback complexity_absent

_complexity=$(printf '%s' "$_raw" | tr '[:lower:]' '[:upper:]')
case "$_complexity" in
  XS|S) _lane="light" ;;
  M|L|XL) _lane="full" ;;
  *) emit_full_fallback complexity_invalid ;;
esac

echo "[CONTEXT] COMPLEXITY_LANE=$_lane; complexity=$_complexity; source=$_source" >&2
exit 0
