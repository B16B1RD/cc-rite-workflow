#!/bin/bash
# rite workflow - 帰結クラス降格政策 (Consequence-Class Demotion Gate) の決定論的後処理
#
# Responsibility: 実測必須ゲート (scripts/review-measured-gate.sh) 適用後のレビュー結果 JSON に対し、
# classification map (LLM が finding 発行者と別コンテキストで書いた class A/B 判定) を機械的に適用する。
# class A (放置すると今回の成果物の実行時挙動が変わる) が 0 件の cycle で、除外なし class B
# (帰結が検出網・可読性・文書整合に留まる) のみ non_blocking_findings[] へ移送し、
# exclusion 付き class B は blocking のまま残す。移送後の blocking 件数から
# overall_assessment / verdict を再確定する。ゲート契約の SoT は
# skills/fix/references/assessment-rules.md §5.3.0.C、語彙定義は
# references/severity-levels.md §帰結クラス軸「ゲート層の class A/B 降格政策」。
# 本 script は判定の適用に LLM の裁量を介在させないための唯一の強制層である。
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 5.3.0.C step 2 (5.3.0.M の後・5.3.1 mergeable 判定の前)。
#     判定は本 script の [CONTEXT] CLASS_DEMOTION_GATE= marker と書き換え後 JSON のみを入力とする。
#
# Usage:
#   bash review-class-demotion-gate.sh --input <review-result JSON path> --classification <class map JSON path>
#
# 入力 JSON (--input) は書き換え対象そのもの (in-place)。書き込みは tempfile + mv の atomic write。
# classification map (--classification) は read-only:
#   {"classifications": [{"id": "F-01", "class": "A", "scenario": "<判定文>"}, ...]}
#   class B は任意キー exclusion（非空文字列 = 既存記述の削除/弱体化の判定文）を持てる。
#
# Gate semantics (assessment-rules.md §5.3.0.C の verbatim 実装):
#   0. blocking (= findings[] のうち scope ∈ {current-pr, follow-up}) が 0 件なら no-op。
#      JSON に触らず CLASS_DEMOTION_GATE=noop を emit して exit 0 (再実行の冪等性はこの分岐が担う —
#      降格発動後の JSON は blocking 0 のため常にここへ落ちる)
#   1. 各 blocking finding の effective class を確定する
#      - **実測未判定 (verification.measured が boolean でない = 5.3.0.M が形式崩れアンカーを
#        blocking のまま残した形) の finding は分類対象外**。map を参照せず class A 側へ固定算入し
#        WARNING + CLASS_DEMOTION_UNDETERMINED_MEASURED を emit する — 「判定不能を降格に丸めない」
#        3 値モデルの保証を第 2 軸でも保つ (本政策の入力は宣言どおり実測付き blocking に限られる)
#      - map に同 id の well-formed エントリ (class="A"、または class="B" ∧ scenario 非空 ∧
#        exclusion キー欠落または exclusion が非空文字列) がある
#        → その class。consequence_class / consequence_scenario を finding へ記録する。
#        well-formed な exclusion があれば consequence_exclusion にも判定文を記録する
#      - それ以外 (エントリ欠落 / class が A・B 以外 / class B なのに scenario 欠落・空 /
#        class B で exclusion キーがあるのに非空文字列でない / 同 id の重複エントリ)
#        → **class A 扱い** (blocking 維持) + WARNING。判定不能を降格に
#        丸めない (AC-6)。consequence_class="A" のみ記録し scenario / exclusion は書かない
#      - 降格に入る経路は「well-formed な class B エントリかつ exclusion なし」のみ —
#        silent 降格は存在しない
#   2. effective class A が 0 件 ∧ 除外なし class B が 1 件以上のときのみ、除外なし class B を
#      non_blocking_findings[] へ append で移送する (severity / scope / id は維持)。
#      各移送要素に demotion = {policy: "class-b-demotion", reason: <判定文>} を付与する
#      (実測ゲート降格分との監査判別子 — review-result-schema.md §non_blocking_findings 配列)。
#      exclusion 付き class B は class B のまま blocking に残す。
#      class A が 1 件でも残る cycle では class B も blocking のまま (移送しない)
#   3. 移送後の blocking 件数から overall_assessment / verdict を両方向で確定する
#      (0 件 → mergeable / 1 件以上 → fix-needed。scripts/review-measured-gate.sh と同一式。
#      非発動 cycle では値は変わらないが同式で再代入し冪等性を保つ)
#   4. トップレベル class_demotion = {applied, class_a, class_b, demoted} を記録する (監査フラグ)
#
# consequence_class を分類入力にしない理由: 判定の入力と適用結果を同じフィールドに置くと、
# LLM の先書きがゲートを無音で迂回する (measured-gate の verification preset と同じ穴)。
# 本 script は map だけを読み、既存の consequence_class / consequence_scenario は算出結果で
# 無条件に上書きする (preset に判定を変える力がないため、reject フラグは不要)。
#
# トップレベルの他キー (reviewers / schema_version / commit_sha / guardrail_audit_log 等) は
# 変換 jq が触らずそのまま保持する。
#
# stdout contract: なし (全 emit は stderr。caller は [CONTEXT] marker を bash 出力として観測する)
#
# stderr contract:
#   [CONTEXT] CLASS_DEMOTION_GATE=noop; reason=no_blocking
#   [CONTEXT] CLASS_DEMOTION_GATE=applied; class_a=0; class_b={n}; demoted={n}; assessment={mergeable|fix-needed}
#   [CONTEXT] CLASS_DEMOTION_GATE=not-triggered; class_a={n}; class_b={n}; demoted=0; assessment={v}
#   [CONTEXT] CLASS_DEMOTION_UNCLASSIFIED=1; count={n}
#   [CONTEXT] CLASS_DEMOTION_UNDETERMINED_MEASURED=1; count={n}
#   [CONTEXT] CLASS_DEMOTION_GATE_FAILED=1; reason=...
#
# 失敗経路では外部コマンド (jq / mktemp / mv) の stderr 先頭 5 行を ERROR 行の直後に転記する
# (sibling の review-measured-gate.sh と同型。silent suppression 禁止)。
#
# Reason SoT (pr-review/SKILL.md の reason 表からは bullet 形式で参照される):
#   jq_missing                  — jq が PATH 上に無い (exit 1)
#   input_missing               — --input のパスが存在しない / 通常ファイルでない (exit 1)
#   input_unreadable            — --input の読み取り権限がない (exit 1)
#   json_invalid                — --input が jq parse 不能 (exit 1)
#   findings_not_array          — .findings が配列でない (exit 1)
#   non_blocking_not_array      — .non_blocking_findings がキー存在かつ非配列 (exit 1)
#   classification_missing      — --classification のパスが存在しない / 通常ファイルでない (exit 1)。
#                                 map なしの適用は「全件判定不能 = 全件 class A」と同値だが、
#                                 caller が分類判定そのものを飛ばした契約違反と区別できないため
#                                 fail-loud にする (per-finding の欠落だけを AC-6 の安全側に倒す)
#   classification_unreadable   — --classification の読み取り権限がない (exit 1)
#   classification_json_invalid — --classification が jq parse 不能 (exit 1)
#   classifications_not_array   — .classifications が配列でない / キー欠落 (exit 1)
#   classification_entry_not_object — .classifications 配列に object でない要素が混在 (exit 1)。
#                                 LLM 生成の malformation で map を作り直せば収束する caller 契約違反。
#                                 generic な jq_transform_failed に落とすと誤診断 + retry 経路から
#                                 漏れるため専用 reason で fail-loud させる (per-finding fail-safe と
#                                 隣接する defect class の一貫性)
#   jq_transform_failed         — ゲート変換 jq が非ゼロ終了 (exit 1)
#   stats_read_failed           — .stats.* の読み出し失敗、値が数値でない、統計間の不変条件
#                                 (class_a + class_b == blocking / unclassified <= class_a /
#                                 undetermined_measured <= class_a / demoted の applied 整合 —
#                                 applied 時 demoted は除外なし class B 件数、blocking_after は
#                                 class_a + 除外付き class B) が
#                                 破れている、または変換前の件数算出 jq (blocking_pre の no-op 判定 /
#                                 classification map の要素型検査) の失敗 (exit 1)。握り潰すと後続の
#                                 数値比較が空文字で偽になり fail-open になる (measured-gate と同根)
#   mktemp_failure              — 出力 tempfile の mktemp 失敗 (exit 1)
#   write_failure               — tempfile への書き出し失敗 (exit 1)
#   mv_failure                  — atomic mv 失敗 (exit 1)
#   signal_aborted              — INT / TERM / HUP で中断 (rc= / signal= を併記)。marker ゼロで
#                                 終わると caller が「失敗していない」と読む余地が残るため emit する
#
# Exit codes:
#   0  ゲート適用成功 (noop / applied / not-triggered。WARNING のみを含む)
#   1  ゲート適用失敗 (CLASS_DEMOTION_GATE_FAILED emit 済み)。**caller は LLM 適用へ fallback せず
#      [review:error] で停止する** (5.3.0.M と同じ fallback 禁止)
#   2  invocation error (引数欠落 / 未知フラグ)
#
# NOTE on shell flags: jq / mktemp / mv の rc を個別にハンドリングするため global `set -e` は使わない
# (sibling の scripts/review-measured-gate.sh と同方針)。
set -u

_rcd_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/control-char-neutralize.sh
source "$_rcd_script_dir/../hooks/control-char-neutralize.sh"

input=""
classification=""

usage() {
  cat <<'EOF'
Usage: review-class-demotion-gate.sh --input PATH --classification PATH

Options:
  --input PATH           帰結クラス降格政策を適用する review-result JSON (in-place 書き換え)
  --classification PATH  classification map JSON (read-only):
                         {"classifications": [{"id": "F-01", "class": "A"|"B",
                           "scenario": "...", "exclusion": "..."}]}
                         exclusion は class B の任意キー。非空文字列なら降格対象外。
  -h, --help             Show this help

Exit codes:
  0  Gate applied (noop / applied / not-triggered)
  1  Gate failed (caller must stop with [review:error]; do NOT fall back to LLM application)
  2  Invocation error
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --input) input="${2:-}"; shift; shift ;;
    --classification) classification="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$input" ] || [ -z "$classification" ]; then
  echo "ERROR: --input と --classification は必須です" >&2
  usage >&2
  exit 2
fi

_fail() {
  # $1 = reason, $2 = 人間向け説明
  echo "ERROR: $2" >&2
  if [ -n "${diag_file:-}" ] && [ -s "${diag_file:-}" ]; then
    head -5 "$diag_file" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  echo "[CONTEXT] CLASS_DEMOTION_GATE_FAILED=1; reason=$1" >&2
  exit 1
}

# jq 不在を json_invalid と誤ラベルしない (sibling と同じ guard)
if ! command -v jq >/dev/null 2>&1; then
  _fail jq_missing "jq が見つかりません (PATH を確認してください)"
fi

# 診断用 tempfile と trap は最初の jq 呼び出しより前に用意する (sibling と同順)
out_tmp=""
diag_file=""
_cleanup() {
  [ -n "${out_tmp:-}" ] && rm -f "$out_tmp"
  [ -n "${diag_file:-}" ] && rm -f "$diag_file"
  return 0
}
_signal_abort() {
  echo "ERROR: 帰結クラス降格ゲートが signal で中断されました (signal=$2)" >&2
  echo "[CONTEXT] CLASS_DEMOTION_GATE_FAILED=1; reason=signal_aborted; rc=$1; signal=$2" >&2
  _cleanup
  exit "$1"
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_signal_abort 130 INT' INT
trap '_signal_abort 143 TERM' TERM
trap '_signal_abort 129 HUP' HUP

if ! diag_file=$(mktemp "${TMPDIR:-/tmp}/rite-class-demotion-err-XXXXXX" 2>/dev/null); then
  diag_file=""
  echo "WARNING: 診断用 tempfile を作成できませんでした。失敗時の外部コマンド stderr は表示されません" >&2
fi

if [ ! -f "$input" ]; then
  _fail input_missing "帰結クラス降格ゲートの入力 JSON が見つかりません: $input"
fi
if [ ! -r "$input" ]; then
  _fail input_unreadable "帰結クラス降格ゲートの入力 JSON を読み取れません (権限): $input"
fi
if ! jq empty "$input" 2>"${diag_file:-/dev/null}"; then
  _fail json_invalid "帰結クラス降格ゲートの入力 JSON が parse できません: $input"
fi
if [ "$(jq -r '.findings | type' "$input" 2>"${diag_file:-/dev/null}")" != "array" ]; then
  _fail findings_not_array ".findings が配列ではありません: $input"
fi
non_blocking_type=$(jq -r 'if has("non_blocking_findings") then (.non_blocking_findings | type) else "absent" end' "$input" 2>"${diag_file:-/dev/null}")
if [ "$non_blocking_type" != "array" ] && [ "$non_blocking_type" != "absent" ]; then
  _fail non_blocking_not_array ".non_blocking_findings がキー存在かつ配列ではありません (type=$non_blocking_type): $input"
fi

# ---- no-op 判定 (classification 検証より前) ----
# blocking 0 件の cycle では分類判定そのものが不要なため、caller は map を書かずに step 2 を
# スキップしてよい……のではなく、本 helper 自体を呼ばないのが配線契約 (pr-review 5.3.0.C step 1)。
# それでも呼ばれた場合に map 不在で fail させないため、no-op 判定を map 検証より前に置く
# (降格発動後の再実行も blocking 0 でここに落ち、冪等に no-op となる)。
blocking_pre=$(jq -r '[.findings[] | select((.scope // "") as $s | $s == "current-pr" or $s == "follow-up")] | length' "$input" 2>"${diag_file:-/dev/null}")
case "$blocking_pre" in
  ''|*[!0-9]*) _fail stats_read_failed "blocking 件数を算出できません: '$blocking_pre'" ;;
esac
if [ "$blocking_pre" -eq 0 ]; then
  echo "[CONTEXT] CLASS_DEMOTION_GATE=noop; reason=no_blocking" >&2
  exit 0
fi

if [ ! -f "$classification" ]; then
  _fail classification_missing "classification map が見つかりません: $classification"
fi
if [ ! -r "$classification" ]; then
  _fail classification_unreadable "classification map を読み取れません (権限): $classification"
fi
if ! jq empty "$classification" 2>"${diag_file:-/dev/null}"; then
  _fail classification_json_invalid "classification map が parse できません: $classification"
fi
if [ "$(jq -r '.classifications | type' "$classification" 2>"${diag_file:-/dev/null}")" != "array" ]; then
  _fail classifications_not_array ".classifications が配列ではありません: $classification"
fi
# 非 object 要素は専用 reason で fail-loud させる (caller 契約違反 — map を作り直せば同 cycle で
# 収束するため、SKILL.md 5.3.0.C step 3 の retry 対象に含める)。generic な jq_transform_failed に
# 落とすと「helper 内部バグ」を示唆する誤診断 + retry 経路から漏れる。select による黙殺は
# finding に紐付かない garbage が無音になるため採らない (fail-loud 原則)。
non_object_count=$(jq -r '[.classifications[] | select(type != "object")] | length' "$classification" 2>"${diag_file:-/dev/null}")
case "$non_object_count" in
  ''|*[!0-9]*) _fail stats_read_failed "classification map の要素型検査に失敗しました: '$non_object_count'" ;;
esac
if [ "$non_object_count" -gt 0 ]; then
  _fail classification_entry_not_object "classification map の classifications 配列に object でない要素が ${non_object_count} 件あります (LLM 生成の malformation)。map を作り直してください: $classification"
fi

# ---- ゲート変換 ----
read -r -d '' JQ_PROG <<'JQEOF'
def gated: ((.scope // "") as $s | $s == "current-pr" or $s == "follow-up");

# 実測の有無が判定済みか (verification.measured が boolean)。scripts/review-measured-gate.sh の
# has_measured_bool と同一述語。**未判定 (verification 欠落 = 5.3.0.M が形式崩れアンカーを
# blocking のまま残した形) の gated finding は本ゲートの分類対象外**で、map を参照せず
# class A 側へ固定算入する — 「判定不能を降格に丸めない」保証 (3 値モデル) を第 2 軸でも保つ。
# これにより本政策の入力は宣言どおり「実測付き blocking」に限られる。
def has_measured_bool:
  ((.verification | type) == "object") and ((.verification.measured | type) == "boolean");

# well-formed 判定: 単一エントリ ∧ class が "A"、または class が "B" ∧ scenario が非空文字列
# ∧ (exclusion キー欠落 ∨ exclusion が非空文字列)。
# 降格に入る経路は well-formed B かつ exclusion なしのみ。判定不能 (エントリ欠落 / class 不正 /
# scenario 欠落 / exclusion 不正 / 重複) は class A 扱い (判定不能を降格に丸めない)。
# well-formed な exclusion 付き B は class B のまま残し、降格しない。
# $m は id -> エントリ配列の辞書。同 id の重複エントリは「分類出力の不正」として当該 finding
# を判定不能 (= class A) に倒す (どちらを採るかの裁量を持たない)。
def parse_exclusion($c):
  if ($c | has("exclusion") | not) then {ok: true, value: null}
  elif ($c.exclusion | type) == "string" and $c.exclusion != "" then {ok: true, value: $c.exclusion}
  else {ok: false, value: null}
  end;

def effective_class($m):
  ($m[(.id // null | tostring)] // []) as $e
  | if ($e | length) != 1 then {class: "A", scenario: null, unclassified: true, exclusion: null}
    else $e[0] as $c
    | if $c.class == "A" then
        {class: "A",
         scenario: (if ($c.scenario | type) == "string" and $c.scenario != "" then $c.scenario else null end),
         unclassified: false, exclusion: null}
      elif $c.class == "B" and ($c.scenario | type) == "string" and $c.scenario != "" then
        parse_exclusion($c) as $ex
        | if $ex.ok then
            {class: "B", scenario: $c.scenario, unclassified: false, exclusion: $ex.value}
          else {class: "A", scenario: null, unclassified: true, exclusion: null} end
      else {class: "A", scenario: null, unclassified: true, exclusion: null} end
    end;

# 分類の記録: gated finding のみ consequence_class / consequence_scenario を持つ。
# 既存値は算出結果で無条件に上書きする (map が唯一の入力 — preset は判定を変えられない)。
# 未判定 (has_measured_bool 偽) の gated finding は map を参照せず class A 固定 (scenario なし)。
# well-formed な exclusion がある class B は consequence_exclusion に判定文を残す (AC-4)。
def with_class($m):
  if gated then
    if has_measured_bool then
      effective_class($m) as $ec
      | .consequence_class = $ec.class
      | (if $ec.scenario != null then .consequence_scenario = $ec.scenario else del(.consequence_scenario) end)
      | (if $ec.exclusion != null then .consequence_exclusion = $ec.exclusion else del(.consequence_exclusion) end)
    else
      .consequence_class = "A"
      | del(.consequence_scenario)
      | del(.consequence_exclusion)
    end
  else . end;

def is_excluded_b:
  gated and .consequence_class == "B"
  and ((.consequence_exclusion | type) == "string") and .consequence_exclusion != "";

def is_demotable_b:
  gated and .consequence_class == "B" and (is_excluded_b | not);

($cls[0].classifications | group_by(.id // null) | map({key: ((.[0].id // null) | tostring), value: .})
 | from_entries) as $by_id
| .findings as $orig
| ($orig | map(with_class($by_id))) as $judged
| ($judged | map(select(gated))) as $blocking_set
| ($blocking_set | map(select(.consequence_class == "A")) | length) as $class_a
| ($blocking_set | map(select(.consequence_class == "B")) | length) as $class_b
| ($blocking_set | map(select(is_excluded_b)) | length) as $excluded
| ($class_a == 0 and ($blocking_set | map(select(is_demotable_b)) | length) >= 1) as $applied
| (if $applied then
     ($judged | map(select(is_demotable_b)
       | . + {demotion: {policy: "class-b-demotion", reason: (.consequence_scenario // "")}}))
   else [] end) as $demoted_set
| (if $applied then ($judged | map(select(is_demotable_b | not))) else $judged end) as $kept
| ($kept | map(select(gated)) | length) as $blocking_after
| {
    doc: (
      .findings = $kept
      | .non_blocking_findings = ((.non_blocking_findings // []) + $demoted_set)
      | .overall_assessment = (if $blocking_after == 0 then "mergeable" else "fix-needed" end)
      | .verdict = (if $blocking_after == 0 then "mergeable" else "fix-needed" end)
      | .class_demotion = {applied: $applied, class_a: $class_a, class_b: $class_b, demoted: ($demoted_set | length)}
    ),
    stats: {
      blocking: ($blocking_set | length),
      class_a: $class_a,
      class_b: $class_b,
      demoted: ($demoted_set | length),
      blocking_after: $blocking_after,
      # map 由来の判定不能 (エントリ欠落 / class 不正 / B の判定文欠落 / 重複)。
      # 母集団は分類対象 (gated ∧ 実測判定済み) に限る — 未判定 A 固定分を混ぜると
      # 「map を直せば解消する」件数と「アンカー書式を直せば解消する」件数が区別できない。
      unclassified: ([$orig[] | select(gated and has_measured_bool) | effective_class($by_id) | select(.unclassified)] | length),
      # 実測未判定のまま class A 固定した gated finding (5.3.0.M の形式崩れアンカー由来)。
      undetermined_measured: ([$orig[] | select(gated and (has_measured_bool | not))] | length),
      excluded: $excluded,
      applied: (if $applied then "true" else "false" end),
      assessment: (if $blocking_after == 0 then "mergeable" else "fix-needed" end)
    }
  }
JQEOF

if ! result=$(jq --slurpfile cls "$classification" "$JQ_PROG" "$input" 2>"${diag_file:-/dev/null}"); then
  _fail jq_transform_failed "帰結クラス降格ゲートの変換 jq が失敗しました: $input"
fi

# stats は 1 回の jq で全件読み、検証は main shell で行う (コマンド置換サブシェル内 _fail の
# fail-open 再生産を避ける — sibling と同根の理由)。
if ! stats_tsv=$(printf '%s\n' "$result" | jq -r '
  [ .stats.blocking, .stats.class_a, .stats.class_b, .stats.demoted,
    .stats.blocking_after, .stats.unclassified, .stats.undetermined_measured,
    .stats.excluded,
    .stats.applied, .stats.assessment ]
  | map(tostring) | @tsv' 2>"${diag_file:-/dev/null}"); then
  _fail stats_read_failed "ゲート統計の読み出し jq が失敗しました"
fi
IFS=$'\t' read -r blocking class_a class_b demoted blocking_after unclassified undetermined_measured excluded applied assessment \
  <<< "$stats_tsv"
for _stat_name in blocking class_a class_b demoted blocking_after unclassified undetermined_measured excluded; do
  _stat_val="${!_stat_name-}"
  case "$_stat_val" in
    ''|*[!0-9]*) _fail stats_read_failed "ゲート統計 $_stat_name が数値ではありません: '$_stat_val'" ;;
  esac
done
case "$applied" in
  true|false) ;;
  *) _fail stats_read_failed "ゲート統計 applied が boolean ではありません: '$applied'" ;;
esac
case "$assessment" in
  mergeable|fix-needed) ;;
  *) _fail stats_read_failed "ゲート統計 assessment が enum 外です: '$assessment'" ;;
esac

# 不変条件 (fail-closed): 分類の全数一致・判定不能の包含・移送件数の整合。
# 破れると「どの marker にも載らない finding」が無音で扱われる (sibling の内訳検証と同根)。
if [ "$((class_a + class_b))" -ne "$blocking" ]; then
  _fail stats_read_failed "ゲート統計の分類が母集団と一致しません (class_a=${class_a} + class_b=${class_b} != blocking=${blocking})"
fi
if [ "$unclassified" -gt "$class_a" ]; then
  _fail stats_read_failed "ゲート統計の判定不能件数が class A 件数を超えています (unclassified=${unclassified} > class_a=${class_a})"
fi
if [ "$undetermined_measured" -gt "$class_a" ]; then
  _fail stats_read_failed "ゲート統計の実測未判定件数が class A 件数を超えています (undetermined_measured=${undetermined_measured} > class_a=${class_a})"
fi
if [ "$excluded" -gt "$class_b" ]; then
  _fail stats_read_failed "ゲート統計の除外件数が class B 件数を超えています (excluded=${excluded} > class_b=${class_b})"
fi
if [ "$applied" = "true" ]; then
  [ "$demoted" -eq "$((class_b - excluded))" ] || _fail stats_read_failed "降格発動なのに移送件数が除外なし class B 件数と一致しません (demoted=${demoted} != class_b-excluded=$((class_b - excluded)))"
  [ "$blocking_after" -eq "$((class_a + excluded))" ] || _fail stats_read_failed "降格発動後の blocking 件数が class A + 除外付き B と一致しません (blocking_after=${blocking_after} != class_a+excluded=$((class_a + excluded)))"
else
  [ "$demoted" -eq 0 ] || _fail stats_read_failed "非発動なのに移送件数が 0 ではありません (demoted=${demoted})"
  [ "$blocking_after" -eq "$blocking" ] || _fail stats_read_failed "非発動なのに blocking 件数が変化しています (blocking_after=${blocking_after} != blocking=${blocking})"
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

if [ "$unclassified" -gt 0 ]; then
  echo "WARNING: 帰結クラス分類が欠落・不正 (エントリなし / class が A・B 以外 / class B なのに判定文なし / class B の exclusion が非空文字列でない / 同 id の重複エントリ) の blocking finding ${unclassified} 件を class A 扱い (blocking 維持) にしました。判定不能を降格に丸めません" >&2
  echo "[CONTEXT] CLASS_DEMOTION_UNCLASSIFIED=1; count=${unclassified}" >&2
fi

if [ "$undetermined_measured" -gt 0 ]; then
  echo "WARNING: 実測の有無が未判定 (verification 欠落 = 実測必須ゲートが形式崩れアンカーを blocking のまま残した形) の blocking finding ${undetermined_measured} 件を分類対象外として class A 側に算入しました (map のエントリは参照しません)。判定不能を降格に丸めない 3 値モデルの保証を第 2 軸でも保つためです。アンカー書式を直せば次 cycle で分類対象になります" >&2
  echo "[CONTEXT] CLASS_DEMOTION_UNDETERMINED_MEASURED=1; count=${undetermined_measured}" >&2
fi

if [ "$applied" = "true" ]; then
  echo "[CONTEXT] CLASS_DEMOTION_GATE=applied; class_a=${class_a}; class_b=${class_b}; demoted=${demoted}; assessment=${assessment}" >&2
else
  echo "[CONTEXT] CLASS_DEMOTION_GATE=not-triggered; class_a=${class_a}; class_b=${class_b}; demoted=0; assessment=${assessment}" >&2
fi
exit 0
