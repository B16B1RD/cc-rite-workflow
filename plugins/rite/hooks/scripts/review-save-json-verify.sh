#!/bin/bash
# rite workflow - ステップ 8.0.4 positive 検査 (本 cycle のレビュー結果 JSON の実在確認)
#
# Responsibility: 「現 run の results dir に、本 cycle の commit SHA を持つレビュー結果 JSON が
# 実在するか」を決定論的に判定する。ステップ 8.0.4 の save-pending marker 検査 (negative) が
# 構造的に検出できない failure mode — ステップ 5.3.0.M〜6.1.a を**区間ごと** skip した cycle —
# を塞ぐための独立した観測点。
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 8.0.4 Pre-Check の `esac` の**後**。marker 層の 3 arm
#     すべてを通る (marker 残存を検出した枝だけは `*)` arm 内の `exit 1` で本 helper に到達しない)。
#     本 helper は marker の在否を前提にせず、ステップ 1.2.5 の commit SHA とディスク上の
#     永続 JSON だけで判定する。出力の意味論は下記「出力」節が SoT。
#
# Usage:
#   bash review-save-json-verify.sh --pr N --commit-sha SHA [--results-dir PATH] [--since BASENAME]
#
# 出力 (stderr。stdout は使わない — caller は marker と exit code だけを読む):
#   [CONTEXT] REVIEW_SAVE_JSON_OK=1; pr=<n>; result_json=<basename>            (exit 0)
#   [CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_result_json_undecidable   (exit 0)
#   [CONTEXT] REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent; expected_sha=<sha> (exit 1)
#
#   成功時に `REVIEW_SAVE_GATE=pass` を名乗らないのは、本 helper が marker 層の 3 arm すべてから
#   呼ばれるため — degraded に降りた marker 層の直後に pass を重ねると、caller の「degraded を
#   pass と読み替えてはならない」規則と観測値が食い違う。本 helper が主張するのは「本 cycle の
#   結果 JSON が実在する」ことだけで、gate 全体の可否は `REVIEW_SAVE_GATE_FAILED` の不在で決まる。
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
#   比較は **一方が他方の prefix なら一致** とする。references/review-result-schema.md の正典例が
#   7 桁短縮 (`"commit_sha": "abc1234"`) で、書き手側 (hooks/review-result-save.sh) に形状検査が
#   無いためである。厳密一致にすると同一 commit の短縮 SHA が「不在」と判定され、差し戻し先の
#   6.1.a を何度実行しても同じ値が再生成されるため非収束ループになる。誤一致は `_sha_matches` が
#   **両オペランド**に 7 桁下限を課すことで防ぐ — 比較が双方向である以上、`--commit-sha` 側の
#   入力検査だけでは JSON 側の短すぎる値を止められない (書き手は commit_sha を検査しない)。
#
# fail と degraded の境界 (Issue #2127 §4.5 / AC-6):
#   degraded に倒すのは「判定に必要な入力・環境が揃わない」場合だけ — 入力の置換漏れ / 形状不正、
#   jq 不在、state root 未解決、run 開始点 pin を読めない、results dir を **読めない** (permission
#   等で find が失敗する) の 5 群。results dir が **存在しない** のは degraded ではなく fail に
#   合流させる (AC-2 の Given「区間ごと skip して JSON も無い」の最も強い証拠であり、degraded に
#   倒すと機械強制がその Given でだけ降りる)。
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
# shellcheck source=./lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"

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
                    省略時は state root 配下 .rite/state/review-run-since-{pr}.txt を読む。
                    空文字を明示すると pin を読まず全件を現 run とみなす (sibling と同じ意味論)
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

# 診断・marker 行へ埋める外部由来の値から制御文字を落とす。**入力検査より前に定義する** —
# `_degraded` は拒否した値そのものを WARNING にエコーするため、走査ブロックの直前に置くと
# 拒否経路を覆えず、「入力を拒否した」degraded 出力の中で桁 0 に `[CONTEXT]` 行を偽造できる。
# 実装は builtin だけで閉じる (`tr` を通さない) — jq 不在の degraded は PATH が壊れた環境でも
# 起きうる経路で、そこで外部コマンドに依存すると WARNING 本文が空になり、fail-loud のはずの
# 出力が原因を名指しできなくなる (機械検査: tests/review-save-json-verify.test.sh T-06n)。
_scrub() { local _s="$1"; printf '%s' "${_s//[[:cntrl:]]/}"; }

_degraded() {
  # $1 = 人間向け WARNING 本文 (原因を名指しする。silent fallback にしないための必須要素)。
  # 本文には拒否した入力値が埋まるため必ず scrub する (marker 行の偽造遮断)。
  echo "WARNING: ステップ 8.0.4 positive 検査: $(_scrub "$1")" >&2
  echo "  本 cycle のレビュー結果 JSON が実在するかを確認できないため、機械強制を降ろします (黙って pass にはしません)。" >&2
  echo "[CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_result_json_undecidable" >&2
  exit 0
}

# ---- 入力検査 (置換漏れ / 形状不正は degraded。理由は冒頭 docstring) --------------
case "$pr_number" in
  ''|*[!0-9]*) _degraded "--pr が数値ではありません (received: '$pr_number')。caller の {pr_number} 置換漏れの可能性があります" ;;
esac
case "$commit_sha" in
  ''|*'{'*|*'}'*) _degraded "--commit-sha が空または placeholder 形状です (received: '$commit_sha')。ステップ 1.2.5 の {current_commit_sha} 置換漏れの可能性があります" ;;
  *[!0-9a-fA-F]*) _degraded "--commit-sha が 16 進数以外の文字を含みます (received: '$commit_sha')。git rev-parse HEAD の出力をそのまま渡してください" ;;
esac
# 7 桁未満は git の短縮 SHA としても短すぎ、prefix 比較が別 commit を誤って一致させる。
[ "${#commit_sha}" -ge 7 ] || _degraded "--commit-sha が 7 桁未満です (received: '$commit_sha')。prefix 比較が別 commit を誤一致させるため判定を降ろします"
# 比較は小文字で行う (git rev-parse は小文字、JSON 側は大文字でも受理する)。
commit_sha=$(printf '%s' "$commit_sha" | tr '[:upper:]' '[:lower:]')

command -v jq >/dev/null 2>&1 || _degraded "jq が PATH 上にありません。JSON の commit_sha を読めません"

# ---- results dir と run 開始点 pin の解決 -----------------------------------------
# 解決**先**は書込側 hooks/review-result-save.sh・sibling hooks/scripts/review-trend-divergence.sh と
# 同一 (state-path-resolve.sh、セッション worktree 内から呼ばれても main checkout と同一パスへ解決)。
# ただし解決に**失敗した**ときの縮退は sibling と異なり cwd 相対へ倒さず _degraded にする —
# 誤った基準で「JSON 不在 = fail」を宣告する gate になるより、未判定として降りる方が安全側 (AC-6)。
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

# results dir の **不在** は degraded にしない — Issue #2127 §4.5 が degraded に置くのは
# 「解決できない / 読めない」であって「存在しない」ではなく、dir 不在は AC-2 の Given
# (区間ごと skip して JSON も無い) の最も強い証拠だからである。下の走査を skip して fail 側へ
# 合流させる (診断は seen_count=0 のとき「(なし)」を出すので追加実装は要らない)。

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
found=""
seen=""
seen_count=0

# git の短縮 SHA を許容する。schema の正典例は 7 桁短縮のため厳密一致にすると同一 commit が
# 「不在」と判定され、差し戻し先の 6.1.a を何度実行しても直らない非収束ループになる。
# **下限は関数の内側で両オペランドに掛ける** — 比較が双方向である以上、期待値側にだけ入力検査を
# 置いても保証にならず、JSON 側の 1 文字の値が 40 桁 SHA の prefix として誤一致する。書き手
# (hooks/review-result-save.sh) は commit_sha を検査しないため、その値は実際に生成されうる。
_sha_matches() {
  [ "${#1}" -ge 7 ] && [ "${#2}" -ge 7 ] || return 1
  case "$2" in "$1"*) return 0 ;; esac
  case "$1" in "$2"*) return 0 ;; esac
  return 1
}

# The expected SHA is supplied by the same review workflow that this helper
# gates, so independently bind it to the checkout being reviewed.  Resolve
# HEAD from this helper's cwd (not state_root, which points at the main
# checkout for linked worktrees).
actual_head=$(git rev-parse HEAD 2>/dev/null) \
  || _degraded "helper の cwd で git rev-parse HEAD を実行できません。レビュー対象 HEAD を独立検証できません"
actual_head=$(_scrub "$actual_head" | tr '[:upper:]' '[:lower:]')
case "$actual_head" in
  ''|*[!0-9a-f]*) _degraded "helper の cwd から取得した HEAD が有効な SHA ではありません (received: '$actual_head')" ;;
esac
[ "${#actual_head}" -ge 7 ] \
  || _degraded "helper の cwd から取得した HEAD が 7 桁未満です (received: '$actual_head')"
if ! _sha_matches "$actual_head" "$commit_sha"; then
  echo "WARNING: ステップ 8.0.4 positive 検査: --commit-sha が helper の cwd の実 HEAD と一致しません (expected: '$actual_head', received: '$commit_sha')" >&2
  echo "  caller の stale anchor は破棄し、helper が独立取得した実 HEAD で結果 JSON を検査します。" >&2
  commit_sha="$actual_head"
fi

if [ -d "$results_dir" ]; then
  # find の rc を検査する。dir が存在しても読めない (permission 等) と find は 0 件を返すため、
  # rc を見ないと「読めない」が「実在しない」に化けて fail へ落ち、差し戻し先の 6.1.a を何度
  # 実行しても解消しない非収束ループになる (§4.5 / AC-6 は読取不能を degraded 側に置く)。
  # `2>/dev/null` は付けない — find の "Permission denied" が原因の唯一の手がかり。
  find_raw=$(find "$results_dir" -maxdepth 1 -type f -name "${pr_number}-*.json") \
    || _degraded "レビュー結果ディレクトリを読めません ($results_dir)。直前の find の診断を参照してください"
  # ファイル名 `{pr}-{timestamp}[~{hex}].json` の LC_ALL=C 昇順 = 時系列昇順
  # (SoT: references/review-result-schema.md §保存場所)。`*.json.corrupt-*` は glob に入らない。
  # tempfile は house convention (coding-principles.md §Shell Helper Conventions) に従い lib 経由。
  # 生 mktemp + 手書き rm は EXIT のみの cleanup と「登録前に signal を受ける窓」を再導入する。
  rite_tempfile_init
  rite_tempfile_new jq_err "p804-jq-err" || {
    echo "WARNING: jq の stderr を捕捉できないため、読取失敗の診断が rc のみに縮退します" >&2
    jq_err=""
  }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bn=$(_scrub "$(basename "$f")")
    if [ -n "$since" ]; then
      # pin より **厳密に新しい** basename だけが現 run のもの (pin 自身は前 run の最終ファイル)。
      [ "$bn" = "$since" ] && continue
      [ "$(printf '%s\n%s\n' "$bn" "$since" | LC_ALL=C sort | head -1)" = "$since" ] || continue
    fi
    # 「JSON が壊れて読めない」「commit_sha キーが無い / 空」の 2 状態を融合しない。融合すると
    # 破損が旧形式互換の顔をして運用者に無視され、SHOULD (保存失敗と区間 skip の切り分け) が
    # 成立しない (sibling scripts/review-cycle-scope.sh が同じ融合を明示的に禁じている)。
    if sha=$(jq -r '.commit_sha // ""' "$f" 2>"${jq_err:-/dev/null}"); then
      sha=$(_scrub "$sha" | tr '[:upper:]' '[:lower:]')
      if [ -z "$sha" ]; then
        sha_display="commit_sha=<キー欠落または空>"
      elif [ "${#sha}" -lt 7 ]; then
        # 判定に使えない値は「一致しなかった」ではなく「短すぎる」と名指しする (3 状態を融合しない)。
        sha_display="commit_sha=$sha <7 桁未満のため判定に使えません>"
      else
        sha_display="commit_sha=$sha"
      fi
    else
      jq_rc=$?
      sha=""
      jq_msg=""
      [ -n "$jq_err" ] && [ -s "$jq_err" ] && jq_msg=$(_scrub "$(head -1 "$jq_err")")
      sha_display="commit_sha=<jq 読取失敗 rc=$jq_rc${jq_msg:+: $jq_msg}>"
    fi
    seen="${seen}    - ${bn} (${sha_display})
"
    seen_count=$((seen_count + 1))
    if [ -n "$sha" ] && _sha_matches "$sha" "$commit_sha"; then
      found="$bn"
    fi
  done <<< "$(printf '%s\n' "$find_raw" | LC_ALL=C sort)"
fi

if [ -n "$found" ]; then
  echo "[CONTEXT] REVIEW_SAVE_JSON_OK=1; pr=$pr_number; result_json=$found" >&2
  exit 0
fi

echo "ERROR: ステップ 8.0.4 gate failed (機械強制)。本 cycle の commit を持つレビュー結果 JSON が現 run に実在しません" >&2
echo "  期待した commit_sha (ステップ 1.2.5 で記録した値): $commit_sha" >&2
echo "  探索先: $results_dir/${pr_number}-*.json" >&2
echo "  run 開始点 pin: ${since:-<不在 = 全件を現 run とみなした>}" >&2
echo "  現 run に実在する JSON ($seen_count 件):" >&2
if [ "$seen_count" -gt 0 ]; then printf '%s' "$seen" >&2; else echo "    (なし)" >&2; fi
echo "  切り分け: 一覧が空なら ステップ 5.3.0.M〜6.1.a を**区間ごと**実行していないか、6.1.a の保存自体が失敗しています (会話の LOCAL_SAVE_FAILED を確認)。非空で commit_sha がすべて古いなら、区間は走ったが本 cycle 分の保存だけが落ちています。" >&2
echo "    ただし会話の LOCAL_SAVE_FAILED の reason が mktemp_failure で始まるなら原因は \${TMPDIR} です。6.1.a は結果 JSON を \${TMPDIR} 上の一時ファイル経由で書くため、上記「探索先」(保存先ディレクトリ) が健全でも保存は落ち続け、再実行では収束しません — 復旧するのは探索先ではなく \${TMPDIR} です。それ以外の reason は 6.1.a 自身が出した「対処:」行が正しい復旧先を名指ししているのでそちらに従ってください (例: mkdir_failure は探索先の親、write_failure は渡した JSON body)。" >&2
echo "  ACTION: ステップ 6.1.a を **step 0 から** 実行してください。step 2 (保存 helper) だけを実行しては**なりません** — step 0 が emit する REVIEW_CYCLE_ID / NONBLOCKING_PENDING_MARKER を欠くと 8.0.3 が前 cycle の値を見て誤 pass します。" >&2
echo "    会話に本 cycle の REVIEW_SAVE_PENDING_MARKER / REVIEW_SAVE_PENDING_ID が 1 つも無い場合は、marker と id の生成元である ステップ 5.3.0.M step 2 から実行してください。" >&2
echo "    続けて {post_comment_mode} に応じて 6.1.b または 6.1.c も再実行してから ステップ 8.0 を再評価してください。" >&2
echo "  ⚠️ 本 gate を pass せずに ステップ 8.1 の result pattern を emit してはなりません。" >&2
echo "[CONTEXT] REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent; expected_sha=$commit_sha" >&2
exit 1
