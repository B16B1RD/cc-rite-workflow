#!/bin/bash
# rite workflow - ステップ 8.0.4 positive 検査 (本 cycle のレビュー結果 JSON の実在確認)
#
# Responsibility: 「現 run の results dir に、本 cycle の commit SHA を持つレビュー結果 JSON が
# 実在するか」を決定論的に判定する。ステップ 8.0.4 の save-pending marker 検査 (negative) が
# 構造的に検出できない failure mode — ステップ 5.3.0.M〜6.1.a を**区間ごと** skip した cycle —
# を塞ぐための独立した観測点。
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 8.0.4 Pre-Check の `*)` arm。
#     **caller 契約**: marker の不在を確認済みの経路からのみ呼ばれる。したがって本 helper の
#     pass は「marker 不在 ∧ 本 cycle の JSON 実在」を意味し、reason は marker 層の語彙
#     (`save_pending_marker_absent`) をそのまま使う (下流 consumer の語彙を drift させない)。
#
# Usage:
#   bash review-save-json-verify.sh --pr N --commit-sha SHA [--results-dir PATH] [--since BASENAME]
#
# 出力 (stderr。stdout は使わない — caller は marker と exit code だけを読む):
#   [CONTEXT] REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent; result_json=<basename>
#   [CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_result_json_undecidable
#   [CONTEXT] REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent; expected_sha=<sha>
#
# Why negative 検査だけでは足りないか:
#   save-pending marker は 5.3.0.M step 2 で設置され 6.1.a の EXIT trap で削除される。arming と
#   解除が**どちらも「飛ばされる区間」の内側**にあるため、区間ごと skip した cycle の観測値は
#   「6.1.a が完走して marker を消した」場合とバイト単位で同一になる。不在と成功が区別できない
#   以上、marker の不在を pass の十分条件にはできない。本 helper が見るのは区間の外側で確定する
#   独立した事実 (ステップ 1.2.5 の commit SHA と、ディスク上の永続 JSON) だけである。
#   設計根拠の SoT: skills/pr-review/references/measured-gate-record.md#save-pending-marker
#
# Why ファイルの有無ではなく commit SHA で判定するか:
#   results dir は /rite:cleanup まで同一 PR の複数 cycle・複数 run の JSON を同居させる。
#   「1 件でもあれば pass」にすると前 cycle の JSON で素通りし、本 helper が塞ぐはずの
#   「本 cycle 分だけ保存されていない」状態をそのまま通す。
#
# 既知の検出限界:
#   本 cycle と前 cycle の HEAD が同一のとき (/rite:fix の accept-only cycle 等、新規 commit を
#   伴わない cycle) は、前 cycle の JSON が SHA 一致で pass しうる。判定軸を commit SHA と定める
#   Issue #2127 §4.4 の契約に従った上での既知の残余で、silent ではない (pass 行の result_json=
#   にどのファイルで通ったかが出る)。
#
# Why 入力不正を fail ではなく degraded に倒すか:
#   `--pr` / `--commit-sha` は caller が `{pr_number}` / `{current_commit_sha}` を literal
#   substitute して渡す。置換漏れを gate 失敗にすると、差し戻し先 (6.1.a) を何度実行しても
#   置換漏れは直らず**非収束ループ**になる。8.0.4 が placeholder residue を degraded に倒すのと
#   同じ理由で、判定に必要な入力が揃わない場合は「判定不能」を loud に告知して機械強制を降ろす。
#   黙って pass にはしない (WARNING + reason 付き marker を必ず emit する)。
#
# Exit codes:
#   0  pass または degraded (どちらも caller は先へ進む)
#   1  gate 失敗 (本 cycle の JSON が現 run に実在しない)
#   2  caller 契約違反 (未知オプション。skill 定義のバグ)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pr_number=""
commit_sha=""
results_dir=""
since=""
since_set=0

usage() {
  cat <<'EOF'
Usage: review-save-json-verify.sh --pr N --commit-sha SHA [--results-dir PATH] [--since BASENAME]

Options:
  --pr N            対象 PR 番号 (必須)
  --commit-sha SHA  ステップ 1.2.5 で記録した本 cycle の commit SHA (必須)
  --results-dir P   レビュー結果 JSON のディレクトリ (既定: state-path-resolve.sh 経由で解決)
  --since BASENAME  run 開始点の pin。この basename より新しい結果ファイルだけを現 run とみなす。
                    省略時は state root 配下 .rite/state/review-run-since-{pr}.txt を読む
  -h, --help        Show this help

Exit codes:
  0  pass / degraded
  1  gate 失敗 (本 cycle の JSON が現 run に実在しない)
  2  未知オプション
EOF
}

# `shift 2` は使わない (値なしフラグが argv 末尾に来ると無限ループになる house convention。
# sibling: scripts/review-cycle-scope.sh、機械検査: hooks/tests/shift2-loop-hardening.test.sh)。
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)           pr_number="${2:-}"; shift; shift ;;
    --commit-sha)   commit_sha="${2:-}"; shift; shift ;;
    --results-dir)  results_dir="${2:-}"; shift; shift ;;
    --since)        since="${2:-}"; since_set=1; shift; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "ERROR: review-save-json-verify: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

_degraded() {
  # $1 = 人間向け WARNING 本文 (原因を名指しする。silent fallback にしないための必須要素)
  echo "WARNING: ステップ 8.0.4 positive 検査: $1" >&2
  echo "  本 cycle のレビュー結果 JSON が実在するかを確認できないため、機械強制を降ろします (黙って pass にはしません)。" >&2
  echo "[CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_result_json_undecidable" >&2
  exit 0
}

# ---- 入力検査 (置換漏れ / 空は degraded。理由は冒頭 docstring) --------------------
case "$pr_number" in
  ''|*[!0-9]*) _degraded "--pr が数値ではありません (received: '$pr_number')。caller の {pr_number} 置換漏れの可能性があります" ;;
esac
case "$commit_sha" in
  ''|*'{'*|*'}'*) _degraded "--commit-sha が空または placeholder 形状です (received: '$commit_sha')。ステップ 1.2.5 の {current_commit_sha} 置換漏れの可能性があります" ;;
esac

command -v jq >/dev/null 2>&1 || _degraded "jq が PATH 上にありません。JSON の commit_sha を読めません"

# ---- results dir と run 開始点 pin の解決 -----------------------------------------
# 解決順は書込側 hooks/review-result-save.sh・sibling hooks/scripts/review-trend-divergence.sh と
# 同一 (state-path-resolve.sh → cwd 相対)。セッション worktree 内から呼ばれても main checkout と
# 同一パスへ解決される。
state_root=""
if [ -z "$results_dir" ] || [ "$since_set" -eq 0 ]; then
  # `2>/dev/null` は付けない — resolver は git 内外どちらでも rc=0 / 非空を返す設計なので、
  # ここに落ちるのは helper 自体を実行できない場合 (プラグイン破損 / 版 skew) だけであり、
  # その唯一の原因を示す診断を抑止してはならない (sibling helper と同じ論拠)。
  state_root=$(bash "$SCRIPT_DIR/../state-path-resolve.sh") || state_root=""
fi

if [ -z "$results_dir" ]; then
  [ -n "$state_root" ] || _degraded "state-path-resolve.sh がレビュー結果ディレクトリの root を解決できませんでした"
  results_dir="$state_root/.rite/review-results"
fi

[ -d "$results_dir" ] || _degraded "レビュー結果ディレクトリが存在しません ($results_dir)"

# run 境界は既存の run 開始点 pin を再利用する (新しい state ファイルは作らない)。書き手は
# skills/iterate/SKILL.md ステップ 0.6 で、sibling の review-trend-divergence.sh / review-cycle-scope.sh
# と同一ファイル・同一の LC_ALL=C 昇順比較を共有する。pin 不在は新規 PR の正常系で全件を現 run
# とみなす。pin が**存在するのに読めない**のは別物 — 現 run を絞れないまま「実在した」と誤判定
# するより判定を降ろす方が安全側 (fail-loud の意味論を保つ)。
if [ "$since_set" -eq 0 ]; then
  if [ -n "$state_root" ]; then
    pin_file="$state_root/.rite/state/review-run-since-${pr_number}.txt"
    if [ -f "$pin_file" ]; then
      since=$(head -1 "$pin_file") || _degraded "run 開始点 pin を読めません ($pin_file)"
    fi
  else
    _degraded "state root を解決できないため run 開始点 pin の在否を確認できません"
  fi
fi

# ---- 現 run の JSON を走査し、本 cycle の commit SHA を持つものを探す ---------------
# ファイル名 `{pr}-{timestamp}[~{hex}].json` の LC_ALL=C 昇順 = 時系列昇順
# (SoT: references/review-result-schema.md §保存場所)。`*.json.corrupt-*` は glob に入らない。
found=""
seen=""
seen_count=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  bn=$(basename "$f")
  if [ -n "$since" ]; then
    # pin より **厳密に新しい** basename だけが現 run のもの (pin 自身は前 run の最終ファイル)。
    [ "$bn" = "$since" ] && continue
    [ "$(printf '%s\n%s\n' "$bn" "$since" | LC_ALL=C sort | head -1)" = "$since" ] || continue
  fi
  sha=$(jq -r '.commit_sha // ""' "$f" 2>/dev/null) || sha=""
  seen="${seen}    - ${bn} (commit_sha=${sha:-<読取不可>})
"
  seen_count=$((seen_count + 1))
  if [ -n "$sha" ] && [ "$sha" = "$commit_sha" ]; then
    found="$bn"
  fi
# `2>/dev/null` は付けない。dir を読めない (permission 等) とき find は 0 件を返し、後続の診断が
# 原因を「区間 skip / 本 cycle 分だけ未保存」の 2 つに限定して名指しする — 実際の原因はそのどちら
# でもないため運用者が空振りする。正常系の find は stderr 0 バイト。
done < <(find "$results_dir" -maxdepth 1 -type f -name "${pr_number}-*.json" | LC_ALL=C sort)

if [ -n "$found" ]; then
  echo "[CONTEXT] REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent; result_json=$found" >&2
  exit 0
fi

echo "ERROR: ステップ 8.0.4 gate failed (機械強制)。本 cycle の commit を持つレビュー結果 JSON が現 run に実在しません" >&2
echo "  期待した commit_sha (ステップ 1.2.5 で記録した値): $commit_sha" >&2
echo "  探索先: $results_dir/${pr_number}-*.json" >&2
echo "  run 開始点 pin: ${since:-<不在 = 全件を現 run とみなした>}" >&2
echo "  現 run に実在する JSON ($seen_count 件):" >&2
if [ "$seen_count" -gt 0 ]; then printf '%s' "$seen" >&2; else echo "    (なし)" >&2; fi
echo "  切り分け: 一覧が空なら ステップ 5.3.0.M〜6.1.a を**区間ごと**実行していません。非空で commit_sha がすべて古いなら、区間は走ったが本 cycle 分の保存だけが落ちています。" >&2
echo "  ACTION: ステップ 6.1.a を **step 0 から** 実行してください。step 2 (保存 helper) だけを実行しては**なりません** — step 0 が emit する REVIEW_CYCLE_ID / NONBLOCKING_PENDING_MARKER を欠くと 8.0.3 が前 cycle の値を見て誤 pass します。" >&2
echo "    会話に本 cycle の REVIEW_SAVE_PENDING_MARKER / REVIEW_SAVE_PENDING_ID が 1 つも無い場合は、marker と id の生成元である ステップ 5.3.0.M step 2 から実行してください。" >&2
echo "    続けて {post_comment_mode} に応じて 6.1.b または 6.1.c も再実行してから ステップ 8.0 を再評価してください。" >&2
echo "  ⚠️ 本 gate を pass せずに ステップ 8.1 の result pattern を emit してはなりません。" >&2
echo "[CONTEXT] REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent; expected_sha=$commit_sha" >&2
exit 1
