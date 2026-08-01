#!/bin/bash
# rite workflow - Measured CONFIRMED Gate (実測必須ゲート) の決定論的後処理
#
# Responsibility: レビュー結果 JSON の findings[] に対し、`internal 内容` (= description) 列の
# `Verification:` アンカーを機械的に検出して findings[].verification を設定し、非実測 finding を
# non_blocking_findings[] へ移送し、残った blocking 件数から overall_assessment を確定する。
# ゲート契約の SoT は references/severity-levels.md §実測必須ゲート、適用手順の SoT は
# skills/fix/references/assessment-rules.md §5.3.0.M。本 script はその 2 文書の実行側であり、
# 判定に LLM の裁量を介在させないための唯一の強制層である (Issue #2072)。
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 5.3 実行順 step 2 (旧 LLM 分類手順を置換)。
#     mergeable 判定 (5.3.1) より前に実行することが契約 — 判定は本 script の
#     [CONTEXT] MEASURED_GATE= marker と書き換え後 JSON のみを入力とする。
#
# Usage:
#   bash review-measured-gate.sh --input <review-result JSON path> [--reject-preset-verification]
#
# 入力 JSON は書き換え対象そのもの (in-place)。書き込みは tempfile + mv の atomic write。
#
# Why --reject-preset-verification (caller 契約の機械的強制):
#   pr-review ステップ 5.3.0.M step 1 の生成規約は「Claude は verification を書かない」を課すが、
#   それは散文の指示にすぎず、本 Issue が置き換えようとしている強制手段そのものである。実際
#   PR #2070 の cycle 2-9 では、そう指示されていないにもかかわらず LLM が
#   `verification.measured: true` を実 repro 付きで JSON へ直接書いていた (fixtures/pr-2070/ で確認可能)。
#   その形が来ると §4.5「既存値を正とする」によりアンカー検出を経ない値がそのまま blocking 判定に
#   入り、ゲートが無音で迂回される。本フラグは「既存 boolean が description のアンカー有無と
#   矛盾する」= 迂回の形だけを hard fail させ、caller (pr-review step 2) から常に指定する。
#
#   **本フラグは部分的な強制である** — hard fail するのは「既存 boolean が description のアンカー
#   有無と矛盾する」場合だけで、アンカーと一致する preset は rc=0 で素通りし、その repro /
#   failing_test は computed_verification を経ずに caller が書いた文字列のまま残る。
#   「preset の存在自体を hard fail させる」形には**できない** — ゲート適用後の findings[] は
#   未判定を除き verification を持つため、同じ JSON への再実行が必ず hard fail し AC-5 (冪等性) が
#   壊れる (未判定はキー自体を持たないので再実行でも preset とみなされない)。
#   preset の中身まで強制したい場合は、ゲートが書いた値と caller が書いた値を区別する marker が
#   別途必要になる (本 script のスコープ外)。
#
#   フラグなしの素の呼び出し (再実行 / 旧形式 JSON) は従来どおり WARNING + 保持。
#   **冪等性 (AC-5) が成立するのは同一引数での再実行に限る** — フラグ指定下で成功した run の出力は
#   「アンカーあり ∧ measured=true」「gate 対象外 scope ∧ アンカーなし ∧ measured=false」
#   「形式崩れアンカー ∧ verification 欠落 (未判定)」しか残さないため再実行しても矛盾に該当しない
#   (未判定は verification を持たないので verification_conflict の母集団に入らず、description が
#   不変なら再実行でも同じく未判定に落ちる)。一方フラグなしモードは既存 boolean を保持するため
#   「アンカーなし ∧ measured=true」という第 3 の形を残しうる (PR #2070 fixture がこの形)。
#   この出力にフラグ付きで再実行すると verification_preset_by_caller で停止する = モード混在では
#   冪等でない。配線済み call site (pr-review ステップ 5.3.0.M step 2) は常にフラグを指定するため
#   本番経路でモード混在は発生しない。
#
# Gate semantics:
#   1. findings[] の各要素について verification を確定する
#      - .verification.measured が boolean で既に入っている → 既存値を正として上書きしない
#        (description のアンカー有無と矛盾する場合は WARNING のみ。§4.5 の契約)
#        `verification: {}` / `measured: null` は read 側型ガードが「未判定」として受理する形であり
#        「設定済み」とはみなさない — 本 script が算出する
#      - `--reject-preset-verification` 指定時は、上記「既存値かつ description と矛盾」を
#        **caller 契約違反として hard fail** させる (下記 Why 参照)
#      - 形式崩れアンカー (stage 1 真 ∧ `=>` あり ∧ stage 2 偽) → **verification を設定しない**。
#        「実測の有無を判定する構造が読めない」状態を measured=false (実測が無いと確定) へ潰さず
#        **未判定** として表現する。read 側の 3 値モデルが「verification 欠落 = 未判定 = blocking」と
#        規定済みのため、キーを生やさないことがそのまま blocking 継続になる
#      - それ以外 → description を 2 段判定し measured を決める
#   2. measured=false かつ gate 対象 scope (current-pr / follow-up) の finding を
#      non_blocking_findings[] へ **append** で移送する (既存要素は保持)。
#      scope=nit-noted は本ゲートの対象外のため非実測でも findings[] に残る
#   3. 移送後の findings[] のうち gate 対象 scope の件数 (= blocking 件数) から
#      overall_assessment を両方向で確定する (0 件 → mergeable / 1 件以上 → fix-needed)
#
# 2 段判定 (assessment-rules.md §5.3.0.M の verbatim 実装):
#   stage 1 = アンカー marker の**存在**判定。種別キーワードも colon 直後の空白も条件に含めず、
#             装飾文字と全角コロンを吸収する「正規化」形で書く (列挙形にすると列挙漏れの形が
#             stage 1/2 の両方から外れ WARNING ゼロで降格する = 本 script が閉じた silent failure)
#   stage 2 = 正規形アンカーの full match 判定。stage 1 が真かつ stage 2 が偽の finding は
#             「アンカーはあるが形式崩れ」として WARNING を出す。帰結は marker から同一セグメント
#             (終端は改行 / <br> / 句点) 内に `=>` が続くかで分かれる:
#               続く   → 未判定 (blocking のまま)  + MEASURED_UNDETERMINED_ON_ANCHOR
#               続かない → measured=false で降格   + MEASURED_DEMOTED_ON_ANCHOR
#             同一セグメントで絞るのは、アンカーが `<LHS> => <RHS>` を必須とする (_reviewer-base.md
#             §Verification) ため、marker から文の切れ目を越えた先の `=>` は別の話題だから。絞らないと
#             stage 1 の意図的に緩い存在判定が拾う散文がそのまま恒久 blocking へ昇格し、
#             /rite:fix には直す対象が無いまま max_review_cycles まで空転する
#
# stdout contract: なし (全 emit は stderr。caller は [CONTEXT] marker を bash 出力として観測する)
#
# stderr contract:
#   [CONTEXT] MEASURED_GATE=applied; blocking={n}; demoted={n}; non_blocking_total={n}; assessment={v}
#   [CONTEXT] MEASURED_UNDETERMINED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable
#   [CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable
#   [CONTEXT] MEASURED_RUNTIME_OBS_WITHOUT_ANCHOR=1; count={n}
#   [CONTEXT] MEASURED_GATE_FAILED=1; reason=...
#
# 上記 2 つの ON_ANCHOR marker の count は排他で、和は常に「stage 1 真 ∧ stage 2 偽」の総数に
# 一致する (assessment-rules.md §5.3.0.M の WARNING emit 母集団と同一 = 検出層に穴を作らない)。
#
# 失敗経路では外部コマンド (jq / mktemp / mv) の stderr 先頭 5 行を ERROR 行の直後に転記する。
# 唯一の hard-stop 経路で診断が空になると caller (pr-review step 3 routing) は [review:error] で
# 止まるだけになり原因を追えないため (references/common-error-handling.md の silent suppression 禁止)。
#
# Reason SoT (pr-review/SKILL.md の reason 表からは bullet 形式で参照される — 委譲済 reason は
# caller 側で `reason=` 構文を使わない規約):
#   jq_missing                  — jq が PATH 上に無い (exit 1)。json_invalid と誤ラベルしないため独立
#   input_missing               — --input のパスが存在しない / 通常ファイルでない (exit 1)
#   input_unreadable            — 読み取り権限がない (exit 1)
#   json_invalid                — jq parse 不能 (exit 1)
#   findings_not_array          — .findings が配列でない (exit 1)
#   non_blocking_not_array      — .non_blocking_findings がキー存在かつ非配列 (exit 1)
#   jq_transform_failed         — ゲート変換 jq が非ゼロ終了 (exit 1)
#   stats_read_failed           — .stats.* の読み出し jq が失敗、値が数値でない、または統計間の
#                                 不変条件が破れている (exit 1)。いずれも「統計を信頼できない」状態。
#                                 握り潰すと後続の `[ "$x" -gt 0 ]` が空文字で偽になり、
#                                 hard fail ゲート自体が無音で skip される (fail-open)。
#                                 不変条件は anchor_undetermined + anchor_demoted_marker ==
#                                 anchor_unparseable — 破れると形式崩れアンカーの一部が
#                                 どちらの marker にも載らず無音で降格する
#   scope_enum_violation        — findings[].scope が enum (current-pr / follow-up / nit-noted) 外、
#                                 またはキー自体が欠落 (フラグ有無に依らず発火)
#                                 (exit 1、書き換えはしない)。**fail-closed が必須** — 未知 scope は
#                                 gated 判定 (== 完全一致) から外れて blocking 件数にも
#                                 non_blocking_findings[] への移送対象にも入らず、実測済み CRITICAL が
#                                 findings[] に残ったまま assessment=mergeable が確定する
#                                 (review-result-schema.md cross-field invariant #2 違反)。
#                                 ascii_downcase 正規化や current-pr への default 補完は採らない —
#                                 不正入力を黙って受理する fallback は本 script の設計前提と衝突する
#   verification_preset_by_caller — --reject-preset-verification 指定下で、description のアンカー有無と
#                                  矛盾する既存 verification.measured を検出 (exit 1、書き換えはしない)
#   mktemp_failure              — 出力 tempfile の mktemp 失敗 (exit 1)
#   write_failure               — tempfile への書き出し失敗 (exit 1)
#   mv_failure                  — atomic mv 失敗 (exit 1)
#
# Eval-order enumeration (reason 表と併せて参照する emit reasons の documented set):
# emit reasons sequence = (`jq_missing` / `input_missing` / `input_unreadable` / `json_invalid` /
#   `findings_not_array` / `non_blocking_not_array` / `jq_transform_failed` / `stats_read_failed` /
#   `scope_enum_violation` / `verification_preset_by_caller` / `mktemp_failure` / `write_failure` / `mv_failure`)
# `signal_aborted` は signal trap 由来で線形の emit 順に載らないため本 enumeration から除外する
# (hooks/review-nonblocking-record.sh と同じ慣行)。reason 表には下記のとおり載せる。
#   signal_aborted              — INT / TERM / HUP で中断 (rc= / signal= を併記)。marker ゼロで
#                                 終わると caller が「失敗していない」と読む余地が残るため emit する
#
# Exit codes:
#   0  ゲート適用成功 (WARNING のみを含む)
#   1  ゲート適用失敗 (MEASURED_GATE_FAILED emit 済み)。**caller は LLM 分類へ fallback せず
#      [review:error] で停止する** — fallback は本 Issue が閉じた不発の再生産になる
#   2  invocation error (引数欠落 / 未知フラグ)
#
# NOTE on shell flags: jq / mktemp / mv の rc を個別にハンドリングするため global `set -e` は使わない
# (sibling の scripts/review-findings-maps.sh と同方針)。
set -u

input=""
reject_preset=0

usage() {
  cat <<'EOF'
Usage: review-measured-gate.sh --input PATH [--reject-preset-verification]

Options:
  --input PATH                    実測必須ゲートを適用する review-result JSON (in-place 書き換え)
  --reject-preset-verification    description のアンカーと矛盾する既存 verification.measured を
                                  caller 契約違反として hard fail させる (pr-review step 2 から常時指定)
  -h, --help                      Show this help

Exit codes:
  0  Gate applied
  1  Gate failed (caller must stop with [review:error]; do NOT fall back to LLM classification)
  2  Invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --input) input="${2:-}"; shift; shift ;;
    --reject-preset-verification) reject_preset=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$input" ]; then
  echo "ERROR: --input は必須です" >&2
  usage >&2
  exit 2
fi

# repo root への cd はしない — 本 script は絶対/相対いずれの --input もそのまま開き、
# rite-config.yml 等の repo-relative なファイルを読まないため (sibling の review-findings-maps.sh は
# config 読込のために cd するが、本 script にその依存はない)。

_fail() {
  # $1 = reason, $2 = 人間向け説明
  # 直前の外部コマンドが stderr を $diag_file へ退避していれば先頭 5 行を転記する
  # (sibling の scripts/review-findings-maps.sh と同型。stderr を捨てると本 script 唯一の
  #  hard-stop 経路で原因が消える)。
  echo "ERROR: $2" >&2
  if [ -n "${diag_file:-}" ] && [ -s "${diag_file:-}" ]; then
    head -5 "$diag_file" | sed 's/^/  /' >&2
  fi
  echo "[CONTEXT] MEASURED_GATE_FAILED=1; reason=$1" >&2
  exit 1
}

# jq 不在を json_invalid と誤ラベルしない (jq empty が rc=127 で落ちるため、guard が無いと
# 完全に valid な JSON に対して「parse できません」と報告して運用者を誤誘導する)。
# 同梱テスト scripts/tests/review-measured-gate.test.sh は同じ guard を持つ。
if ! command -v jq >/dev/null 2>&1; then
  _fail jq_missing "jq が見つかりません (PATH を確認してください)"
fi

# 診断用 tempfile と trap は **最初の jq 呼び出しより前**に用意する。後ろに置くと
# `json_invalid` / `findings_not_array` / `non_blocking_not_array` の 3 経路で退避先が存在せず、
# docstring と caller routing が約束している「ERROR 行の直後に stderr 先頭 5 行を転記する」が
# 破れる。step 1 は Claude が JSON を Write する工程なので、不正 JSON は本ゲートの最有力
# failure mode であり、そこで jq の line/column が消えるのは最も痛い。
out_tmp=""
diag_file=""
_cleanup() {
  [ -n "${out_tmp:-}" ] && rm -f "$out_tmp"
  [ -n "${diag_file:-}" ] && rm -f "$diag_file"
  return 0
}
# signal 中断でも marker を残す。caller (pr-review step 3) の routing 表は観測 marker のみを
# 入力にするため、marker ゼロで終わると「失敗していない」と読む余地が残る
# (sibling の hooks/review-nonblocking-record.sh と同じ理由・同じ形)。
_signal_abort() {
  echo "ERROR: 実測必須ゲートが signal で中断されました (signal=$2)" >&2
  echo "[CONTEXT] MEASURED_GATE_FAILED=1; reason=signal_aborted; rc=$1; signal=$2" >&2
  _cleanup
  exit "$1"
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_signal_abort 130 INT' INT
trap '_signal_abort 143 TERM' TERM
trap '_signal_abort 129 HUP' HUP

if ! diag_file=$(mktemp "${TMPDIR:-/tmp}/rite-measured-gate-err-XXXXXX" 2>/dev/null); then
  diag_file=""
  echo "WARNING: 診断用 tempfile を作成できませんでした。失敗時の外部コマンド stderr は表示されません" >&2
fi

if [ ! -f "$input" ]; then
  _fail input_missing "実測必須ゲートの入力 JSON が見つかりません: $input"
fi
if [ ! -r "$input" ]; then
  _fail input_unreadable "実測必須ゲートの入力 JSON を読み取れません (権限): $input"
fi
if ! jq empty "$input" 2>"${diag_file:-/dev/null}"; then
  _fail json_invalid "実測必須ゲートの入力 JSON が parse できません: $input"
fi
if [ "$(jq -r '.findings | type' "$input" 2>"${diag_file:-/dev/null}")" != "array" ]; then
  _fail findings_not_array ".findings が配列ではありません: $input"
fi
non_blocking_type=$(jq -r 'if has("non_blocking_findings") then (.non_blocking_findings | type) else "absent" end' "$input" 2>"${diag_file:-/dev/null}")
if [ "$non_blocking_type" != "array" ] && [ "$non_blocking_type" != "absent" ]; then
  _fail non_blocking_not_array ".non_blocking_findings がキー存在かつ配列ではありません (type=$non_blocking_type): $input"
fi

# ---- ゲート変換 ----
# 3 つの regex はいずれも assessment-rules.md §5.3.0.M / _reviewer-base.md §Verification の SoT 由来。
# $re_extract は SoT の Anchor detection regex に **capture group と RHS 末尾消費を足しただけ**で、
# match するかどうかの意味論は変えていない (capture 化と、必須 atom の後ろの greedy `*` 追加は
# 受理集合を変えない)。この等価性は scripts/tests/review-measured-gate.test.sh の
# 「SoT regex との等価性」ケースが入力マトリクスで機械的に固定する。
read -r -d '' JQ_PROG <<'JQEOF'
def scope_effective: (.scope // "");

def gated: (scope_effective | (. == "current-pr" or . == "follow-up"));

# gated は完全一致で判定するため、enum 外の scope は blocking 集合からも降格対象からも同時に
# 外れて「指摘ゼロの正常終了」と区別できない mergeable を作る。本述語で検出し hard fail する。
def scope_known:
  (scope_effective | (. == "current-pr" or . == "follow-up" or . == "nit-noted"));

def desc: (.description // "");

# verification が「設定済み」= measured が boolean。{} / null は read 側型ガードが受理する
# 「未判定」形であり、本 script が算出する対象。
def has_measured_bool:
  ((.verification | type) == "object") and ((.verification.measured | type) == "boolean");

def anchored: (desc | test($re_detect));
def marker_present: (desc | test($re_stage1));

# アンカーは `<LHS> => <RHS>` を必須とする (_reviewer-base.md §Verification)。したがって marker から
# 同一セグメント内に `=>` が続かない `Verification:` は「書き損じたアンカー」ではなく散文中の言及で
# ある。stage 1 は意図的に緩い存在判定で散文を拾うため、未判定 (= blocking のまま) へ倒す母集団は
# 本述語で絞る。絞らないと `Verification:` に言及するだけの doc 指摘が恒久 blocking になり、
# /rite:fix には直す対象が無いまま max_review_cycles まで空転する。
#
# セグメントの終端は改行 / `<br>` / 句点 (`。`) — アンカーは 1 セグメントに収まる形で書かれるため、
# marker と `=>` の間に文の切れ目があれば別の話題であり、アンカーの書き損じではない。
#
# **残存する限界 (意図的に受容)**: 同一セグメント内に `=>` が現れる散文は分離できず未判定へ倒れる。
# rationale: skills/fix/references/assessment-rules.md §5.3.0.M「(i) は完全な分離ではない」
# marker prefix は `$re_stage1` を連結して共有する — literal 複製すると stage 1 側だけを編集した
# ときに marker_present が真・has_arrow が偽となり、形式崩れアンカーが未判定ではなく降格へ落ちる。
# この誤分類では内訳の和が母集団と一致したままなので下の fail-closed ガードでは検出できない。
# 走査長は有界にする — 無界の `*` は marker 出現数 × セグメント長で二次的に増大し、marker を
# 多数含む description で秒オーダーの遅延になる (実測: 8000 marker で 12.3s → 有界化で 0.055s)。
# アンカー 1 セグメントが 600 字を超える例は無いため受理集合は実質不変。
def has_arrow: (desc | test($re_stage1 + "(?:(?!<br)[^\n。]){0,600}=>"));

# 形式崩れアンカー = 「実測の有無を判定する構造が読めない」状態。measured=false (実測が無いと
# 確定) ではなく **未判定** として扱い、verification キー自体を生やさない。read 側の 3 値モデル
# (review-result-schema.md §3値モデルへの上書き / fix/SKILL.md ステップ 1.3 measured lookup) が
# 「verification 欠落 = 未判定 = blocking」と規定済みのため、read 側の変更は要らない。
def undetermined_on_anchor: (marker_present and has_arrow and (anchored | not));

def computed_verification:
  ([desc | capture($re_extract)] | first) as $a
  | if $a == null then {measured: false, repro: null, failing_test: null}
    else
      (($a.lhs | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
        + " => "
        + ($a.rhs | sub("[[:space:]]+$"; ""))) as $t
      | if $a.label == "repro"
        then {measured: true, repro: $t, failing_test: null}
        else {measured: true, repro: null, failing_test: $t} end
    end;

# 既存 boolean は上書きしない。未設定のものだけ description から算出する。
# 形式崩れアンカーは verification を **設定しない** ことで未判定を表現する (キーを生やさない)。
# 未判定化は `gated` に限る — SoT の疑似コードが母集団を scope ∈ {current-pr, follow-up} と
# 定義しており、nit-noted は降格され得ないので未判定にする意味がない。ここで gated を外すと
# nit-noted も verification を失う一方、下の anchor_undetermined 統計 (gated 限定) には載らず、
# 「marker ゼロで表現だけが変わる」観測不能な差分になる。
# 未判定分岐は `del` で明示的にキーを落とす。裸の `.` で返すと、`measured` が boolean でない
# 既存 verification (型崩れ preset) が正規化を経ずゲート出力へ残り、read 側の型ガードが当該
# review-result を reject して永続 artifact を corrupt 扱いで rename する。「未判定 = キー欠落」を
# 出力形として literal に満たすことで、この経路を塞ぐ (キー不在時は no-op のため冪等)。
def with_verification:
  if has_measured_bool then .
  elif (gated and undetermined_on_anchor) then del(.verification)
  else .verification = computed_verification end;

# $orig は verification 代入**前**の findings[]。「元から boolean が入っていたか」を問う統計は
# 必ず $orig 側で評価する — $judged では全件が boolean を持つため has_measured_bool が常に真になり、
# アンカー形式違反の WARNING が恒久的に発火しなくなる (= 本 script が閉じた silent failure の再生産)。
.findings as $orig
| ($orig | map(with_verification)) as $judged
| ($judged | map(select((.verification.measured == false) and gated))) as $demoted
| ($judged | map(select(((.verification.measured == false) and gated) | not))) as $kept
| ($kept | map(select(gated)) | length) as $blocking
| {
    doc: (
      .findings = $kept
      | .non_blocking_findings = ((.non_blocking_findings // []) + $demoted)
      | .overall_assessment = (if $blocking == 0 then "mergeable" else "fix-needed" end)
    ),
    stats: {
      blocking: $blocking,
      demoted: ($demoted | length),
      non_blocking_total: (((.non_blocking_findings // []) | length) + ($demoted | length)),
      assessment: (if $blocking == 0 then "mergeable" else "fix-needed" end),
      # enum 外 scope の件数 (0 でなければ caller 契約違反として hard fail する)。
      scope_unknown: ([$orig[] | select(scope_known | not)] | length),
      # stage 1 真 かつ stage 2 偽 = 「アンカーはあるが形式崩れ」。
      # **既存 boolean の有無で除外してはならない** — `measured: false` の preset を持つ finding は
      # verification_conflict にも該当しない (false == anchored(false)) ため、除外すると
      # 「アンカーはあるが形式崩れ」が hard fail にも WARNING にも載らず無音で通り抜ける
      # (docstring が「silent 降格の唯一の検出層」と称する層の穴)。
      #
      # **母集団は gate 対象 scope に限る**。nit-noted は `gated` が偽で降格され得ないため、
      # 含めると「降格していないものを降格と申告する」ことになり、WARNING の件数が
      # 実際の降格件数と食い違う。
      anchor_unparseable: (
        [$orig[] | select(gated and marker_present and (anchored | not))] | length
      ),
      # anchor_unparseable の内訳。両者は排他かつ和が anchor_unparseable に一致する
      # (検出層に穴を空けないための不変条件)。
      #   undetermined = 未判定として blocking に留めたもの (verification を生やさなかった)
      #   demoted_marker = marker はあるが未判定にしなかったもの (同一セグメントに `=>` が
      #                    続かない / 既存 boolean 保持)
      anchor_undetermined: (
        [$orig[] | select(gated and (has_measured_bool | not) and undetermined_on_anchor)] | length
      ),
      anchor_demoted_marker: (
        [$orig[] | select(gated and marker_present and (anchored | not)
                          and (has_measured_bool or (has_arrow | not)))] | length
      ),
      # 実測済みを主張する Likelihood-Evidence があるのに Verification アンカーが無い不整合
      # (§4.4 SHOULD: 両方添付が契約)。母集団を gated に限る理由は anchor_unparseable と同じ。
      runtime_obs_without_anchor: (
        [$orig[] | select(gated and (desc | test($re_runtime_obs)) and (anchored | not))] | length
      ),
      # 既存 boolean と description のアンカー有無が食い違う件数 (既存値を正とするため WARNING のみ)。
      # 既存 boolean が「本ゲートが算出したはずの値」と食い違う件数。3 値化後は 2 値比較
      # (`!= anchored`) だけでは足りない — ゲートが**未判定**を算出する形に `measured: false` を
      # 先書きされると `false == anchored(false)` で矛盾なしと読み、`has_measured_bool` の短絡が
      # 未判定分岐を飛ばして実測済み CRITICAL を non_blocking へ移送し mergeable を確定させる。
      # フラグ指定下でのみ hard fail するため §4.5 の「既存値を正とする」は無傷。
      verification_conflict: (
        [$orig[] | select(has_measured_bool)
         | select((.verification.measured != anchored) or (gated and undetermined_on_anchor))] | length
      ),
      # enum 外 scope の診断行。値は tojson で 1 行の JSON literal に畳む (raw 改行による
      # [CONTEXT] marker 偽造と ANSI/OSC の素通しを同時に塞ぐ)。
      scope_unknown_list: (
        [$orig[] | select(scope_known | not)
         | "  - \(.id // "?" | tojson) \(.file // "?" | tojson): scope=\(.scope | tojson)"]
      )
    }
  }
JQEOF

if ! result=$(jq \
  --arg re_stage1 '(?i)verification[*_`[:space:]]*[:：]' \
  --arg re_detect '(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(repro|failing_test)[[:space:]]+(?:(?!=>|<br)[^|])+=>[ \t]*(?!<br)[^|[:space:]]' \
  --arg re_extract '(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(?<label>repro|failing_test)[[:space:]]+(?<lhs>(?:(?!=>|<br)[^|])+)=>[ \t]*(?<rhs>(?!<br)[^|[:space:]](?:(?!<br)[^|])*)' \
  --arg re_runtime_obs '(?i)likelihood-evidence[[:space:]]*[:：][[:space:]]*runtime_observation' \
  "$JQ_PROG" "$input" 2>"${diag_file:-/dev/null}"); then
  _fail jq_transform_failed "実測必須ゲートの変換 jq が失敗しました: $input"
fi

# stats は **1 回の jq で全件まとめて読み、検証も main shell で行う**。
# 個別に `x=$(stat_of ...)` の形にすると、`stat_of` 内の `_fail` (= exit 1) が**コマンド置換の
# サブシェルだけ**を終わらせ script は続行する。その結果 x="" となり後続の `[ "$x" -gt 0 ]` が
# rc=2 (偽) に倒れて、hard fail ゲート自体が無音で skip され JSON が書き込まれる — 塞いだはずの
# fail-open をゲートの内部で再生産する形になる (実測で確認済み)。
# `map(tostring)` は必須。キーが欠けると `@tsv` がそこを空文字にし、tab は IFS whitespace のため
# 連続 tab が圧縮されてフィールドが左シフトする。fail-closed 自体は保たれる (どこかの数値枠に
# enum 文字列が落ちる) が、**診断が実際に欠けたものと別の統計名を名指しする**。
# `tostring` を通すと欠落キーが "null" という非空文字列になり、シフトが消えて名前が正しくなる。
if ! stats_tsv=$(printf '%s\n' "$result" | jq -r '
  [ .stats.blocking, .stats.demoted, .stats.non_blocking_total,
    .stats.anchor_unparseable, .stats.anchor_undetermined, .stats.anchor_demoted_marker,
    .stats.runtime_obs_without_anchor,
    .stats.scope_unknown, .stats.verification_conflict,
    .stats.assessment ] | map(tostring) | @tsv' 2>"${diag_file:-/dev/null}"); then
  _fail stats_read_failed "ゲート統計の読み出し jq が失敗しました"
fi
IFS=$'\t' read -r blocking demoted non_blocking_total anchor_unparseable \
  anchor_undetermined anchor_demoted_marker \
  runtime_obs_without_anchor scope_unknown verification_conflict assessment \
  <<< "$stats_tsv"
for _stat_name in blocking demoted non_blocking_total anchor_unparseable \
  anchor_undetermined anchor_demoted_marker \
  runtime_obs_without_anchor scope_unknown verification_conflict; do
  _stat_val="${!_stat_name-}"
  case "$_stat_val" in
    ''|*[!0-9]*) _fail stats_read_failed "ゲート統計 $_stat_name が数値ではありません: '$_stat_val'" ;;
  esac
done
case "$assessment" in
  mergeable|fix-needed) ;;
  *) _fail stats_read_failed "ゲート統計 assessment が enum 外です: '$assessment'" ;;
esac

# 「stage 1 真 ∧ stage 2 偽」の母集団は未判定 / 降格の 2 subset に排他分割される。分割が母集団を
# 覆えていないと、どちらの marker にも載らない finding が無音で降格する = 本 script が閉じたはずの
# silent failure が検出層の内部で再生産される。2 つの述語は独立に書かれており将来の編集で覆いが
# 破れうるため、構成上の自明さに頼らず機械的に固定する (書き換え前に評価し fail-closed)。
if [ "$((anchor_undetermined + anchor_demoted_marker))" -ne "$anchor_unparseable" ]; then
  _fail stats_read_failed "ゲート統計の内訳が母集団と一致しません (undetermined=${anchor_undetermined} + demoted_marker=${anchor_demoted_marker} != anchor_unparseable=${anchor_unparseable}): 形式崩れアンカーの一部がどちらの marker にも載らず無音で扱われます"
fi

# caller 契約の強制は **書き換えより前** に評価する — 迂回された分類を含む JSON を
# 一度でも書いてしまうと、caller が停止しても後段 (6.1.a 保存 / 6.1.b Raw JSON) が
# その内容を拾える状態が残る。
if [ "$scope_unknown" -gt 0 ]; then
  echo "ERROR: findings[].scope が enum (current-pr / follow-up / nit-noted) 外の finding が ${scope_unknown} 件あります。未知 scope は gated 判定から外れて blocking 件数にも non_blocking_findings[] への移送対象にも入らず、実測済み指摘を findings[] に残したまま assessment=mergeable を確定させます (fail-open)" >&2
  # 列挙は変換 jq が算出済みの集合を読む (述語を 2 箇所に持たない)。値は `tojson` で必ず
  # 1 行の JSON literal に畳む — id / file / scope は LLM 生成の自由記述で、raw 改行を
  # 埋めれば本 script 自身の `[CONTEXT]` marker とバイト同一の行を偽造でき、その marker は
  # caller (pr-review step 3) の routing 入力そのものになる。ANSI/OSC も同時に潰れる。
  printf '%s\n' "$result" | jq -r '.stats.scope_unknown_list[]' 2>"${diag_file:-/dev/null}" | head -10 >&2
  if [ "$scope_unknown" -gt 10 ]; then
    echo "  ... (残り $((scope_unknown - 10)) 件は省略)" >&2
  fi
  _fail scope_enum_violation "scope enum 違反のため、ゲートを適用せず停止しました: $input"
fi

if [ "$reject_preset" -eq 1 ] && [ "$verification_conflict" -gt 0 ]; then
  echo "ERROR: findings[] に、description の Verification: アンカー有無と矛盾する verification.measured が ${verification_conflict} 件あらかじめ設定されています。ゲート適用前の JSON に verification を書いてはいけません (アンカー検出を経ない値が blocking 判定に入り、実測必須ゲートが無音で迂回されます)" >&2
  _fail verification_preset_by_caller "レビュー結果 JSON の生成規約違反のため、ゲートを適用せず停止しました: $input"
fi

if ! out_tmp=$(mktemp "${input}.gate.XXXXXX" 2>"${diag_file:-/dev/null}"); then
  _fail mktemp_failure "ゲート出力用 tempfile を作成できません (dir: $(dirname "$input"))"
fi

if ! printf '%s\n' "$result" | jq '.doc' > "$out_tmp" 2>"${diag_file:-/dev/null}"; then
  _fail write_failure "ゲート適用後 JSON の書き出しに失敗しました: $out_tmp"
fi

if ! mv "$out_tmp" "$input" 2>"${diag_file:-/dev/null}"; then
  _fail mv_failure "ゲート適用後 JSON の atomic mv に失敗しました: $out_tmp -> $input"
fi
out_tmp=""

# 以降で使う統計値はすべて書き換え前の一括読み出し + 検証済み (上記 stats_tsv)。

# アンカー文字列があるのに正規形で書けていない finding は silent に扱わない
# (アンカー文字列そのものが無い正常系 = 非実測指摘 では WARNING を出さない — 形式違反と
#  正常系が区別できなくなるため)。母集団 anchor_unparseable は 2 つの排他な帰結に分かれ、
# それぞれを対の WARNING + marker で報告する (和は常に anchor_unparseable = 検出層に穴なし)。
if [ "$anchor_undetermined" -gt 0 ]; then
  echo "WARNING: Verification: アンカーはあるが検出 regex に match しない finding ${anchor_undetermined} 件を **未判定** として blocking のまま残しました (raw pipe / => 右辺空 / 種別ラベル誤記 (repro|failing_test 以外) / アンカー直前の境界欠落)。実測の有無を判定できないため non-blocking へ降格させません。アンカーの直前は行頭・改行タグ・空白のいずれかにし、パイプを含むコマンドは ¦ で代替表記してください" >&2
  echo "[CONTEXT] MEASURED_UNDETERMINED_ON_ANCHOR=1; count=${anchor_undetermined}; cause=anchor_unparseable" >&2
fi

if [ "$anchor_demoted_marker" -gt 0 ]; then
  echo "WARNING: Verification: marker はあるが同一セグメント内に => が続かないため本ゲートが未判定にしなかった finding ${anchor_demoted_marker} 件を検出しました (marker と => の間に改行タグが挟まった折り返しアンカー / 文境界を挟んだ散文中の言及 / 既存 verification.measured の保持)。実測を主張する指摘なら <LHS> => <RHS> 形のアンカーを marker と同一セグメント内に置き、パイプを含むコマンドは ¦ で代替表記してください" >&2
  echo "[CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count=${anchor_demoted_marker}; cause=anchor_unparseable" >&2
fi

if [ "$runtime_obs_without_anchor" -gt 0 ]; then
  echo "WARNING: Likelihood-Evidence: runtime_observation を持つのに Verification: の正規形アンカーを欠く finding ${runtime_obs_without_anchor} 件を検出しました (実測済み指摘は両方の添付が契約)。帰結は併記される MEASURED_UNDETERMINED_ON_ANCHOR / MEASURED_DEMOTED_ON_ANCHOR marker を参照してください (形式崩れは未判定として blocking に据え置き、アンカー欠如は measured=false へ降格)" >&2
  echo "[CONTEXT] MEASURED_RUNTIME_OBS_WITHOUT_ANCHOR=1; count=${runtime_obs_without_anchor}" >&2
fi

if [ "$verification_conflict" -gt 0 ]; then
  echo "WARNING: 既存 verification.measured と description のアンカー有無が矛盾する finding ${verification_conflict} 件を検出しました (既存値を正として保持)" >&2
fi

echo "[CONTEXT] MEASURED_GATE=applied; blocking=${blocking}; demoted=${demoted}; non_blocking_total=${non_blocking_total}; assessment=${assessment}" >&2
exit 0
