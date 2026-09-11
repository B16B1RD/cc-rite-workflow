#!/bin/bash
# rite workflow - Measured CONFIRMED Gate (実測必須ゲート) の決定論的後処理
#
# Responsibility: レビュー結果 JSON の findings[] に対し、`internal 内容` (= description) 列の
# `Verification:` アンカーを機械的に検出して findings[].verification を設定し、非実測 finding を
# non_blocking_findings[] へ移送し、残った blocking 件数から overall_assessment を確定する。
# ゲート契約の SoT は references/severity-levels.md §実測必須ゲート、適用手順の SoT は
# skills/fix/references/assessment-rules.md §5.3.0.M。本 script はその 2 文書の実行側であり、
# 判定に LLM の裁量を介在させないための唯一の強制層である。
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
# --reject-preset-verification は算出結果と矛盾する既存 boolean を拒否する。
# 一致する既存値は再適用の冪等性のため保持する。フラグなしでは矛盾を WARNING + 保持とする。
# 形式崩れアンカーはフラグ・既存 boolean に依らず error とし、入力を書き換えない。
# 冪等性は同一引数での再実行に限る。
#
# Gate semantics:
#   1. findings[] の各要素について verification を確定する
#      - .verification.measured が boolean で既に入っている → 既存値を正として上書きしない
#        (本ゲートの算出結果と食い違う場合は WARNING のみ。§4.5 の契約)
#        `verification: {}` / `measured: null` は read 側型ガードが「未判定」として受理する形であり
#        「設定済み」とはみなさない — 本 script が算出する
#      - `--reject-preset-verification` 指定時は、上記「既存値かつ本ゲートの算出結果と食い違う」を
#        **caller 契約違反として hard fail** させる (下記 Why 参照)
#      - gated な形式崩れアンカー (stage 1 真 ∧ `=>` あり ∧ stage 2 偽) → 書込み前に error。
#      - それ以外 → description を 2 段判定し measured を決める
#   2. measured=false かつ gate 対象 scope (current-pr / follow-up) の finding を
#      non_blocking_findings[] へ **append** で移送する (既存要素は保持)。
#      scope=nit-noted は本ゲートの対象外のため非実測でも findings[] に残る
#   3. 移送後の findings[] のうち gate 対象 scope の件数 (= blocking 件数) から
#      overall_assessment と verdict を両方向で確定する (0 件 → mergeable / 1 件以上 → fix-needed)。
#      **verdict は本 script が唯一の書き手**で、caller (pr-review.md ステップ 5.3.0.M step 1) は
#      書かない。merge ゲート (hooks/pre-tool-bash-guard.sh) が読む必須キーであり、両者を同一式から
#      同時に代入することで「ゲートが判定を反転させた cycle で 2 つの判定が食い違う」経路を消す。
#      契約の SoT は references/review-result-schema.md §verdict と reviewers
#
# トップレベルの他キー (reviewers / schema_version / commit_sha / guardrail_audit_log 等) は
# 変換 jq が触らずそのまま保持する。`reviewers` (実回収名簿) は caller が step 1 で書く。
#
# 2 段判定 (assessment-rules.md §5.3.0.M の verbatim 実装):
#   stage 1 = アンカー marker の**存在**判定。種別キーワードも colon 直後の空白も条件に含めず、
#             装飾文字と全角コロンを吸収する「正規化」形で書く (列挙形にすると列挙漏れの形が
#             stage 1/2 の両方から外れ WARNING ゼロで降格する = 本 script が閉じた silent failure)
#   stage 2 = 正規形アンカーの full match 判定。stage 1 が真かつ stage 2 が偽の finding は
#             「アンカーはあるが形式崩れ」として WARNING を出す。帰結は第 3 の述語 ($re_arrow、
#             定義の SoT は assessment-rules.md §5.3.0.M) が真かで分かれる:
#               真 → error + MEASURED_GATE_FAILED reason=anchor_undetermined
#               偽 → measured=false で降格      + MEASURED_DEMOTED_ON_ANCHOR
#             絞らないと stage 1 の意図的に緩い存在判定が拾う散文がそのまま恒久 blocking へ昇格し、
#             /rite:fix には直す対象が無いまま max_review_cycles まで空転する
#
# stdout contract: なし (全 emit は stderr。caller は [CONTEXT] marker を bash 出力として観測する)
#
# stderr contract:
#   [CONTEXT] MEASURED_GATE=applied; blocking={n}; demoted={n}; non_blocking_total={n}; assessment={v}
#   [CONTEXT] MEASURED_GATE_FAILED=1; reason=anchor_undetermined; count={n}; findings={ids}
#   [CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable
#   [CONTEXT] MEASURED_RUNTIME_OBS_WITHOUT_ANCHOR=1; count={n}
#   [CONTEXT] MEASURED_GATE_FAILED=1; reason=...
#
# anchor_undetermined と anchor_demoted_marker は排他で、和は「stage 1 真 ∧ stage 2 偽」の総数に
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
#   anchor_undetermined         — gated finding の形式崩れアンカー (exit 1、count / findings を併記、入力不変)
#   verification_preset_by_caller — --reject-preset-verification 指定下で、本ゲートの算出結果と食い違う
#                                  既存 verification.measured を検出 (exit 1、書き換えはしない)
#   mktemp_failure              — 出力 tempfile の mktemp 失敗 (exit 1)
#   write_failure               — tempfile への書き出し失敗 (exit 1)
#   mv_failure                  — atomic mv 失敗 (exit 1)
#
# Eval-order enumeration (reason 表と併せて参照する emit reasons の documented set):
# emit reasons sequence = (`jq_missing` / `input_missing` / `input_unreadable` / `json_invalid` /
#   `findings_not_array` / `non_blocking_not_array` / `jq_transform_failed` / `stats_read_failed` /
#   `scope_enum_violation` / `anchor_undetermined` / `verification_preset_by_caller` / `mktemp_failure` / `write_failure` / `mv_failure`)
# `signal_aborted` は signal trap 由来で線形の emit 順に載らないため本 enumeration から除外する
# (hooks/review-nonblocking-record.sh と同じ慣行)。reason 表には下記のとおり載せる。
#   signal_aborted              — INT / TERM / HUP で中断 (rc= / signal= を併記)。marker ゼロで
#                                 終わると caller が「失敗していない」と読む余地が残るため emit する
#
# Exit codes:
#   0  ゲート適用成功 (WARNING のみを含む)
#   1  ゲート適用失敗 (MEASURED_GATE_FAILED emit 済み)。**caller は LLM 分類へ fallback せず
#      reviewer reject + reroll または [review:error] へ routing する**
#   2  invocation error (引数欠落 / 未知フラグ)
#
# NOTE on shell flags: jq / mktemp / mv の rc を個別にハンドリングするため global `set -e` は使わない
# (sibling の scripts/review-findings-maps.sh と同方針)。
set -u

_rmg_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/control-char-neutralize.sh
source "$_rmg_script_dir/../hooks/control-char-neutralize.sh"

input=""
reject_preset=0

usage() {
  cat <<'EOF'
Usage: review-measured-gate.sh --input PATH [--reject-preset-verification]

Options:
  --input PATH                    実測必須ゲートを適用する review-result JSON (in-place 書き換え)
  --reject-preset-verification    本ゲートの算出結果 (実測あり / 実測なし) と食い違う既存
                                  verification.measured を caller 契約違反として hard fail させる
                                  (pr-review step 2 から常時指定)
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
    head -5 "$diag_file" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
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

# 散文の marker 言及と実測アンカーの形式崩れを同一セグメント内の arrow で区別する。
# prefix は stage 1 と共有し、suffix は assessment-rules.md の literal とテストで同期する。
# 走査長の上限は marker 数 × セグメント長による二次的な増大を避けるため。
def has_arrow: (desc | test($re_stage1 + $re_arrow));

# この述語に該当する gated finding は書込み前に拒否する。
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

# 形式崩れを含む変換結果は保存しない。正常入力の既存 boolean は保持する。
def with_verification:
  if has_measured_bool then .
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
      # verdict は overall_assessment と同じ blocking 件数から同時に代入する。merge ゲートが読む
      # 必須キーで、caller (5.3.0.M step 1) は書かない — caller が書いても本代入が無条件に上書き
      # するため、書けば必ず捨てられる推測値になる (step 1 時点では移送後の blocking 件数が未確定)。
      # verification の preset 尊重 (--reject-preset-verification が存在する理由) とは向きが逆で、
      # verdict 側に preset を弾くフラグは要らない。
      | .verdict = (if $blocking == 0 then "mergeable" else "fix-needed" end)
      # provenance は毎回 object 全体を置換し、前回の commit / 統計との混在を防ぐ。
      | .measured_gate = {
          commit_sha: .commit_sha,
          applied_at: $applied_at,
          blocking: $blocking,
          demoted: ($demoted | length),
          anchor_undetermined: (
            [$orig[] | select(gated and undetermined_on_anchor)] | length
          )
        }
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
      # 形式崩れ error と marker のみの診断を排他に集計する。
      anchor_undetermined_ids: ([$orig[] | select(gated and undetermined_on_anchor) | .id]),
      anchor_undetermined: (
        [$orig[] | select(gated and undetermined_on_anchor)] | length
      ),
      anchor_demoted_marker: (
        [$orig[] | select(gated and marker_present and (anchored | not)
                          and (has_arrow | not))] | length
      ),
      # 実測済みを主張する Likelihood-Evidence があるのに Verification アンカーが無い不整合
      # (§4.4 SHOULD: 両方添付が契約)。母集団を gated に限る理由は anchor_unparseable と同じ。
      runtime_obs_without_anchor: (
        [$orig[] | select(gated and (desc | test($re_runtime_obs)) and (anchored | not))] | length
      ),
      # boolean の先書きが算出結果と食い違う場合は caller 契約違反。
      verification_conflict: (
        [$orig[] | select(has_measured_bool)
         | select(.verification.measured != anchored)] | length
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

# POSIX/BSD date does not support GNU %N. Seconds resolution is sufficient for
# an execution receipt and remains valid RFC 3339 on every supported runner.
applied_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ") || _fail timestamp_generation_failed "measured_gate.applied_at を生成できませんでした"
case "$applied_at" in
  ????-??-??T??:??:??Z) ;;
  *) _fail timestamp_generation_failed "measured_gate.applied_at が RFC 3339 UTC 形式ではありません: $applied_at" ;;
esac

if ! result=$(jq \
  --arg applied_at "$applied_at" \
  --arg re_stage1 '(?i)verification[*_`[:space:]]*[:：]' \
  --arg re_detect '(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(repro|failing_test)[[:space:]]+(?:(?!=>|<br)[^|])+=>[ \t]*(?!<br)[^|[:space:]]' \
  --arg re_extract '(?m)(?:^|<br\s*/?>|[\s|>(])[-[:space:]]*Verification:[[:space:]]*(?<label>repro|failing_test)[[:space:]]+(?<lhs>(?:(?!=>|<br)[^|])+)=>[ \t]*(?<rhs>(?!<br)[^|[:space:]](?:(?!<br)[^|])*)' \
  --arg re_arrow '(?:(?!<br)[^\n。]){0,2000}=>' \
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

# 「stage 1 真 ∧ stage 2 偽」の母集団は形式崩れ error / marker のみの 2 subset に排他分割される。分割が母集団を
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
  printf '%s\n' "$result" | jq -r '.stats.scope_unknown_list[]' 2>"${diag_file:-/dev/null}" \
    | head -10 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  if [ "$scope_unknown" -gt 10 ]; then
    echo "  ... (残り $((scope_unknown - 10)) 件は省略)" >&2
  fi
  _fail scope_enum_violation "scope enum 違反のため、ゲートを適用せず停止しました: $input"
fi

if [ "$anchor_undetermined" -gt 0 ]; then
  if ! finding_ids=$(printf '%s\n' "$result" | jq -r '.stats.anchor_undetermined_ids | map(tostring) | join(",")' 2>"${diag_file:-/dev/null}"); then
    _fail stats_read_failed "形式崩れアンカーの finding ID を読み出せません"
  fi
  echo "ERROR: Verification: の形式崩れを検出しました。該当 finding のみ reviewer reject + reroll してください。記法: Verification: repro <cmd> => <観測> / Verification: failing_test <path> => <失敗出力>。アンカー直前は行頭・改行タグ・空白とし、コマンドのパイプは ¦ に置換してください" >&2
  printf '[CONTEXT] MEASURED_GATE_FAILED=1; reason=anchor_undetermined; count=%s; findings=%s' "$anchor_undetermined" "$finding_ids" | neutralize_ctrl >&2
  printf '\n' >&2
  exit 1
fi

if [ "$reject_preset" -eq 1 ] && [ "$verification_conflict" -gt 0 ]; then
  echo "ERROR: findings[] に、description から本ゲートが算出する判定 (実測あり / 実測なし) と食い違う verification.measured が ${verification_conflict} 件あらかじめ設定されています。ゲート適用前の JSON に verification を書いてはいけません (アンカー検出を経ない値が blocking 判定に入り、実測必須ゲートが無音で迂回されます)" >&2
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
#  正常系が区別できなくなるため)。形式崩れ error は保存前に処理済み。
if [ "$anchor_demoted_marker" -gt 0 ]; then
  echo "WARNING: Verification: marker はあるが正規形アンカーとして検出できず同一セグメント内に => を持たない finding ${anchor_demoted_marker} 件を検出しました (marker の後ろに => が無い / marker と => の間に改行 / <br> / 句点が挟まる / marker から => までが判別子の上限を超える)。実測を主張する指摘なら <LHS> => <RHS> 形のアンカーを marker と同一セグメント内に置き、パイプを含むコマンドは ¦ で代替表記してください" >&2
  echo "[CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count=${anchor_demoted_marker}; cause=anchor_unparseable" >&2
fi

if [ "$runtime_obs_without_anchor" -gt 0 ]; then
  echo "WARNING: Likelihood-Evidence: runtime_observation を持つのに Verification: の正規形アンカーを欠く finding ${runtime_obs_without_anchor} 件を検出しました (実測済み指摘は両方の添付が契約)。Verification: marker 自体が無い finding は measured=false へ降格します (この場合 ON_ANCHOR marker は出ません)。marker のみの診断は MEASURED_DEMOTED_ON_ANCHOR を参照してください" >&2
  echo "[CONTEXT] MEASURED_RUNTIME_OBS_WITHOUT_ANCHOR=1; count=${runtime_obs_without_anchor}" >&2
fi

if [ "$verification_conflict" -gt 0 ]; then
  echo "WARNING: 既存 verification.measured が本ゲートの算出結果と食い違う finding ${verification_conflict} 件を検出しました (既存値を正として保持)" >&2
fi

echo "[CONTEXT] MEASURED_GATE=applied; blocking=${blocking}; demoted=${demoted}; non_blocking_total=${non_blocking_total}; assessment=${assessment}" >&2
exit 0
