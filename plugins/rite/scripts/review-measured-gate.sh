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
#   フラグなしの素の呼び出し (再実行 / 旧形式 JSON / /rite:recover) は従来どおり WARNING + 保持で、
#   冪等性 (AC-5) は両モードで保たれる — ゲート適用後の findings[] は
#   「アンカーあり ∧ measured=true」か「nit-noted ∧ アンカーなし ∧ measured=false」しか残らず、
#   どちらも矛盾に該当しないため再実行しても発火しない。
#
# Gate semantics:
#   1. findings[] の各要素について verification を確定する
#      - .verification.measured が boolean で既に入っている → 既存値を正として上書きしない
#        (description のアンカー有無と矛盾する場合は WARNING のみ。§4.5 の契約)
#        `verification: {}` / `measured: null` は read 側型ガードが「未判定」として受理する形であり
#        「設定済み」とはみなさない — 本 script が算出する
#      - `--reject-preset-verification` 指定時は、上記「既存値かつ description と矛盾」を
#        **caller 契約違反として hard fail** させる (下記 Why 参照)
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
#             「アンカーはあるが形式崩れ」として WARNING + MEASURED_DEMOTED_ON_ANCHOR を出す
#
# stdout contract: なし (全 emit は stderr。caller は [CONTEXT] marker を bash 出力として観測する)
#
# stderr contract:
#   [CONTEXT] MEASURED_GATE=applied; blocking={n}; demoted={n}; non_blocking_total={n}; assessment={v}
#   [CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable
#   [CONTEXT] MEASURED_GATE_FAILED=1; reason=...
#
# Reason SoT (pr-review/SKILL.md の reason 表からは bullet 形式で参照される — 委譲済 reason は
# caller 側で `reason=` 構文を使わない規約):
#   input_missing               — --input のパスが存在しない / 通常ファイルでない (exit 1)
#   input_unreadable            — 読み取り権限がない (exit 1)
#   json_invalid                — jq parse 不能 (exit 1)
#   findings_not_array          — .findings が配列でない (exit 1)
#   non_blocking_not_array      — .non_blocking_findings がキー存在かつ非配列 (exit 1)
#   jq_transform_failed         — ゲート変換 jq が非ゼロ終了 (exit 1)
#   verification_preset_by_caller — --reject-preset-verification 指定下で、description のアンカー有無と
#                                  矛盾する既存 verification.measured を検出 (exit 1、書き換えはしない)
#   mktemp_failure              — 出力 tempfile の mktemp 失敗 (exit 1)
#   write_failure               — tempfile への書き出し失敗 (exit 1)
#   mv_failure                  — atomic mv 失敗 (exit 1)
#
# Eval-order enumeration (reason 表と併せて参照する emit reasons の documented set):
# emit reasons sequence = (`input_missing` / `input_unreadable` / `json_invalid` /
#   `findings_not_array` / `non_blocking_not_array` / `jq_transform_failed` /
#   `verification_preset_by_caller` / `mktemp_failure` / `write_failure` / `mv_failure`)
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
  echo "ERROR: $2" >&2
  echo "[CONTEXT] MEASURED_GATE_FAILED=1; reason=$1" >&2
  exit 1
}

if [ ! -f "$input" ]; then
  _fail input_missing "実測必須ゲートの入力 JSON が見つかりません: $input"
fi
if [ ! -r "$input" ]; then
  _fail input_unreadable "実測必須ゲートの入力 JSON を読み取れません (権限): $input"
fi
if ! jq empty "$input" 2>/dev/null; then
  _fail json_invalid "実測必須ゲートの入力 JSON が parse できません: $input"
fi
if [ "$(jq -r '.findings | type' "$input" 2>/dev/null)" != "array" ]; then
  _fail findings_not_array ".findings が配列ではありません: $input"
fi
non_blocking_type=$(jq -r 'if has("non_blocking_findings") then (.non_blocking_findings | type) else "absent" end' "$input" 2>/dev/null)
if [ "$non_blocking_type" != "array" ] && [ "$non_blocking_type" != "absent" ]; then
  _fail non_blocking_not_array ".non_blocking_findings がキー存在かつ配列ではありません (type=$non_blocking_type): $input"
fi

out_tmp=""
_cleanup() {
  [ -n "${out_tmp:-}" ] && rm -f "$out_tmp"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

# ---- ゲート変換 ----
# 3 つの regex はいずれも assessment-rules.md §5.3.0.M / _reviewer-base.md §Verification の SoT 由来。
# $re_extract は SoT の Anchor detection regex に **capture group と RHS 末尾消費を足しただけ**で、
# match するかどうかの意味論は変えていない (capture 化と、必須 atom の後ろの greedy `*` 追加は
# 受理集合を変えない)。この等価性は scripts/tests/review-measured-gate.test.sh の
# 「SoT regex との等価性」ケースが入力マトリクスで機械的に固定する。
read -r -d '' JQ_PROG <<'JQEOF'
def scope_effective:
  # scope 欠落時は severity-levels.md §自動 default mapping (schema 1.0 後方互換) を使う。
  # 判定用の内部値のみで、JSON へ scope を書き戻すことはしない。
  (.scope // "") as $sc
  | if $sc != "" then $sc
    elif (((.severity // "") | ascii_upcase) | (. == "LOW" or . == "LOW-MEDIUM")) then "nit-noted"
    else "current-pr" end;

def gated: (scope_effective | (. == "current-pr" or . == "follow-up"));

def desc: (.description // "");

# verification が「設定済み」= measured が boolean。{} / null は read 側型ガードが受理する
# 「未判定」形であり、本 script が算出する対象。
def has_measured_bool:
  ((.verification | type) == "object") and ((.verification.measured | type) == "boolean");

def anchored: (desc | test($re_detect));
def marker_present: (desc | test($re_stage1));

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
def with_verification:
  if has_measured_bool then . else .verification = computed_verification end;

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
      # stage 1 真 かつ stage 2 偽 = 「アンカーはあるが形式崩れ」。既存 boolean を持つ finding は
      # description 由来の判定をしていないため対象外。
      anchor_unparseable: (
        [$orig[] | select(has_measured_bool | not) | select(marker_present and (anchored | not))] | length
      ),
      # 実測済みを主張する Likelihood-Evidence があるのに Verification アンカーが無い不整合
      # (§4.4 SHOULD: 両方添付が契約)。
      runtime_obs_without_anchor: (
        [$orig[] | select(has_measured_bool | not) | select((desc | test($re_runtime_obs)) and (anchored | not))] | length
      ),
      # 既存 boolean と description のアンカー有無が食い違う件数 (既存値を正とするため WARNING のみ)。
      verification_conflict: (
        [$orig[] | select(has_measured_bool) | select(.verification.measured != anchored)] | length
      )
    }
  }
JQEOF

if ! result=$(jq \
  --arg re_stage1 '(?i)verification[*_`[:space:]]*[:：]' \
  --arg re_detect '(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(repro|failing_test)[[:space:]]+(?:(?!=>|<br)[^|])+=>[ \t]*(?!<br)[^|[:space:]]' \
  --arg re_extract '(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(?<label>repro|failing_test)[[:space:]]+(?<lhs>(?:(?!=>|<br)[^|])+)=>[ \t]*(?<rhs>(?!<br)[^|[:space:]](?:(?!<br)[^|])*)' \
  --arg re_runtime_obs '(?i)likelihood-evidence[[:space:]]*[:：][[:space:]]*runtime_observation' \
  "$JQ_PROG" "$input" 2>/dev/null); then
  _fail jq_transform_failed "実測必須ゲートの変換 jq が失敗しました: $input"
fi

stat_of() { printf '%s\n' "$result" | jq -r ".stats.$1"; }
verification_conflict=$(stat_of verification_conflict)

# caller 契約の強制は **書き換えより前** に評価する — 迂回された分類を含む JSON を
# 一度でも書いてしまうと、caller が停止しても後段 (6.1.a 保存 / 6.1.b Raw JSON) が
# その内容を拾える状態が残る。
if [ "$reject_preset" -eq 1 ] && [ "$verification_conflict" -gt 0 ] 2>/dev/null; then
  echo "ERROR: findings[] に、description の Verification: アンカー有無と矛盾する verification.measured が ${verification_conflict} 件あらかじめ設定されています。ゲート適用前の JSON に verification を書いてはいけません (アンカー検出を経ない値が blocking 判定に入り、実測必須ゲートが無音で迂回されます)" >&2
  _fail verification_preset_by_caller "レビュー結果 JSON の生成規約違反のため、ゲートを適用せず停止しました: $input"
fi

if ! out_tmp=$(mktemp "${input}.gate.XXXXXX" 2>/dev/null); then
  _fail mktemp_failure "ゲート出力用 tempfile を作成できません (dir: $(dirname "$input"))"
fi

if ! printf '%s\n' "$result" | jq '.doc' > "$out_tmp" 2>/dev/null; then
  _fail write_failure "ゲート適用後 JSON の書き出しに失敗しました: $out_tmp"
fi

if ! mv "$out_tmp" "$input" 2>/dev/null; then
  _fail mv_failure "ゲート適用後 JSON の atomic mv に失敗しました: $out_tmp -> $input"
fi
out_tmp=""

blocking=$(stat_of blocking)
demoted=$(stat_of demoted)
non_blocking_total=$(stat_of non_blocking_total)
assessment=$(stat_of assessment)
anchor_unparseable=$(stat_of anchor_unparseable)
runtime_obs_without_anchor=$(stat_of runtime_obs_without_anchor)

# アンカー文字列があるのに正規形で書けていない finding は silent に降格させない
# (アンカー文字列そのものが無い正常系 = 非実測指摘 では WARNING を出さない — 形式違反と
#  正常系が区別できなくなるため)。
if [ "$anchor_unparseable" -gt 0 ] 2>/dev/null; then
  echo "WARNING: Verification: アンカーはあるが検出 regex に match しない finding ${anchor_unparseable} 件を measured=false に降格しました (raw pipe / => 右辺空 / 種別ラベル誤記 (repro|failing_test 以外) / 形式崩れ)。パイプを含むコマンドは ¦ で代替表記してください" >&2
  echo "[CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count=${anchor_unparseable}; cause=anchor_unparseable" >&2
fi

if [ "$runtime_obs_without_anchor" -gt 0 ] 2>/dev/null; then
  echo "WARNING: Likelihood-Evidence: runtime_observation を持つのに Verification: アンカーを欠く finding ${runtime_obs_without_anchor} 件を measured=false として降格しました (実測済み指摘は両方の添付が契約)" >&2
fi

if [ "$verification_conflict" -gt 0 ] 2>/dev/null; then
  echo "WARNING: 既存 verification.measured と description のアンカー有無が矛盾する finding ${verification_conflict} 件を検出しました (既存値を正として保持)" >&2
fi

echo "[CONTEXT] MEASURED_GATE=applied; blocking=${blocking}; demoted=${demoted}; non_blocking_total=${non_blocking_total}; assessment=${assessment}" >&2
exit 0
