#!/bin/bash
# rite workflow - Review Findings Maps Build (severity_map / scope_map + schema 1.1.0 normalization)
#
# Responsibility: file-based review source (Priority 0/2: local_file / explicit_file) の
# findings[] から severity_map_json / scope_map_json を構築・検証する。構築に先立ち
# schema 1.1.0 後方互換 normalization を適用する:
#   (a) schema 1.0/1.0.0 の scope 欠落を severity-based default mapping で補完
#   (b) cross-field invariant #5 (pre_existing=false × scope=nit-noted) の auto-correct
#   (e) 致命性仕分け — gated finding (scope ∈ {current-pr, follow-up}) のうち
#       `verification.measured == true ∧ severity ∈ {CRITICAL, HIGH}` だけを findings[] に残し、
#       残りを non_blocking_findings[] へ `demotion_reason: "non_fatal"` 付きで移送する
# mutation 発生時のみ normalized tempfile に書き出して以降の jq が参照し、本 script 終了時に
# trap で削除する (caller への file hand-off はしない。normalization の発生は
# [CONTEXT] REVIEW_SOURCE_* retained flag で LLM コンテキストに伝達される)。
#
# Called from:
#   - skills/fix/SKILL.md ステップ 1.2.0 "On Priority 2 success" (旧 ~154 行 inline block を委譲)。
#     Priority 3 (pr_comment) の string-based 鏡像は
#     fix.md 内の 1.2.0.s 節に inline のまま残る (同 logic の鏡像。jq filter を変更する際は両方を同期すること)
#
# Usage:
#   bash review-findings-maps.sh --review-source <local_file|explicit_file|...> \
#     --review-source-path <path> [--repo-root DIR]
#
# Behavior by --review-source:
#   local_file / explicit_file : normalization + maps build を実行
#   その他 (pr_comment 等)      : no-op で exit 0 (旧 inline block の外側 if guard と同一)
#
# stdout contract: なし (severity_map_json / scope_map_json は構築検証のみ、値は emit しない。
#   fix.md 下流の map 参照は LLM が review JSON から conceptual map を再構築する契約)
#
# stderr contract (旧 inline block から verbatim 移設。LLM は caller の bash 出力として観測する):
#   [CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1; reason=scope_omitted_in_v1_0; ...
#   [CONTEXT] REVIEW_SOURCE_AUTO_CORRECTED=1; reason=pre_existing_false_scope_nit_noted; ...
#   [CONTEXT] FIX_FATAL_TRIAGE=applied; fatal=<n>; moved=<m>
#   [CONTEXT] REVIEW_SOURCE_NORMALIZATION_FAILED=1; reason=jq_mutation_failed|mktemp_failure_norm_tmp; ...
#   [CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=jq_duplicate_check_failed; ...
#   [CONTEXT] FIX_FALLBACK_FAILED=1; reason=severity_map_build_failed|scope_map_build_failed; ...
#   [CONTEXT] FIX_FALLBACK_FAILED=1; reason=measured_undetermined; findings=F-xx,...; ...
#   [CONTEXT] FIX_FALLBACK_FAILED=1; reason=severity_enum_violation; findings=F-xx,...; ...
#   [CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_jq_failed|fatal_triage_mktemp_failed
#                                          |fatal_triage_id_union_violation|fatal_triage_mv_failed; ...
#
# Reason SoT (fix.md の reason 表からは bullet 形式で参照される — 委譲済 reason は
# fix.md 内で `reason=` 構文を使わない規約):
#   scope_omitted_in_v1_0             — schema 1.0/1.0.0 の scope 欠落を default mapping で補完 (非ブロッキング)
#   pre_existing_false_scope_nit_noted — invariant #5 違反を current-pr に auto-correct (非ブロッキング)
#   measured_undetermined             — gated finding に verification.measured (boolean) が無い (exit 1、
#                                       caller が [fix:error] に昇格。未判定を blocking / non-blocking の
#                                       どちらにも倒さない — fail-loud)
#   severity_enum_violation           — findings[].severity が enum 外 (exit 1、既存 scope enum 違反と同形)
#   fatal_triage_jq_failed            — 致命性仕分けの検査 / 移送 jq が失敗 (exit 1、部分適用を残さない)
#   fatal_triage_mktemp_failed        — 移送出力用 tempfile の mktemp が失敗 (exit 1)
#   fatal_triage_id_union_violation   — 移送後 JSON の自己検証違反 (non_blocking_findings が非配列、または
#                                       id が書式違反 / 和集合で重複)。mv せず exit 1 (入力は無変更)
#   fatal_triage_mv_failed            — 移送後 JSON の atomic mv が失敗 (exit 1、入力は無変更)
#   jq_mutation_failed                — normalization jq mutation が失敗、原 JSON のまま続行 (非ブロッキング)
#   mktemp_failure_norm_tmp           — normalization 用 tempfile の mktemp が失敗、原 JSON のまま続行 (非ブロッキング)
#   jq_duplicate_check_failed         — 重複 file:line 検出用 jq が失敗、severity_map 構築は続行 (非ブロッキング)
#   severity_map_build_failed         — severity_map 構築用 jq が失敗 (exit 1、caller が [fix:error] に昇格)
#   scope_map_build_failed            — scope_map 構築用 jq が失敗、scope_map_json="{}" で続行 (非ブロッキング)
#
# Eval-order enumeration (reason 表と併せて参照する emit reasons の documented set):
# emit reasons sequence = (`scope_omitted_in_v1_0` / `pre_existing_false_scope_nit_noted` / `jq_mutation_failed` / `mktemp_failure_norm_tmp` / `fatal_triage_jq_failed` / `severity_enum_violation` / `measured_undetermined` / `fatal_triage_mktemp_failed` / `fatal_triage_id_union_violation` / `fatal_triage_mv_failed` / `jq_duplicate_check_failed` / `severity_map_build_failed` / `scope_map_build_failed`)
#
# Exit codes:
#   0  正常 (no-op source / maps build 成功 / 非ブロッキング WARNING のみ)
#   1  severity_map 構築失敗、または致命性仕分けの失敗 (FIX_FALLBACK_FAILED emit 済み。caller が
#      [fix:error] を stdout 出力する — [fix:error] stdout 分離契約のため本 helper は emit しない)
#   2  invocation error (引数欠落 / repo-root cd 失敗)
#
# NOTE on shell flags: 旧 inline block は jq / mktemp の rc を明示ハンドリングするため
# global `set -e` を使わない。verbatim 移植のため本 helper も同様。
set -u

_rfm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/control-char-neutralize.sh
source "$_rfm_dir/../hooks/control-char-neutralize.sh"

review_source=""
review_source_path=""

usage() {
  cat <<'EOF'
Usage: review-findings-maps.sh --review-source SOURCE --review-source-path PATH

Options:
  --review-source SOURCE       local_file | explicit_file (それ以外は no-op exit 0)
  --review-source-path PATH    review-result JSON のパス
  -h, --help                   Show this help

Exit codes:
  0  Normal (no-op / success / non-blocking warnings)
  1  severity_map build failed (caller must emit [fix:error])
  2  Invocation error
EOF
}

# 各値付きフラグは `shift; shift` で消費する
while [ $# -gt 0 ]; do
  case "$1" in
    --review-source) review_source="${2:-}"; shift; shift ;;
    --review-source-path) review_source_path="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# 旧 inline block の外側 if guard と同一: file-based source 以外は何もしない
if [ "$review_source" != "local_file" ] && [ "$review_source" != "explicit_file" ]; then
  exit 0
fi

if [ -z "$review_source_path" ]; then
  echo "ERROR: --review-source-path は file-based source ($review_source) で必須です" >&2
  usage >&2
  exit 2
fi

# 致命性仕分けの書き戻し先。normalization は review_source_path を tempfile へ差し替えるため、
# 永続 review-result JSON のパスを別変数で保持する (P3 経路では fix.md が raw_json を書き出した
# tempfile がこれに当たる — 経路によらず「caller が渡した入力ファイル」が書き戻し先になる)。
orig_source_path="$review_source_path"

# tempfile cleanup trap: norm_tmp は同一プロセス内で hand-off されるため、旧 inline block の
# 「bash block 終了の trap EXIT で削除される」契約をそのまま script 終了時に履行する
norm_tmp=""
handed_off_norm_tmp=""
triage_tmp=""
jq_err=""
_cleanup() {
  [ -n "${norm_tmp:-}" ] && rm -f "$norm_tmp"
  [ -n "${handed_off_norm_tmp:-}" ] && rm -f "$handed_off_norm_tmp"
  [ -n "${triage_tmp:-}" ] && rm -f "$triage_tmp"
  [ -n "${jq_err:-}" ] && rm -f "$jq_err"
  return 0
}
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

# ---- 旧 fix.md ステップ 1.2.0 severity_map build block の faithful port ----
# schema 1.1.0 後方互換 normalization (scope default mapping + invariant #5 auto-correct)。
# 本 script は file-based path 用 (Priority 0/2 共通)。Priority 3 (pr_comment, raw_json string) は
# fix.md が raw_json を tempfile へ書き出して本 helper を呼ぶため、致命性仕分けの実装は 1 本に閉じる。
#
# 動作:
# (a) schema_version == "1.0"|"1.0.0" の場合、findings[] に欠落している scope を severity から
#     default mapping (CRITICAL/HIGH/MEDIUM → current-pr、LOW-MEDIUM/LOW → nit-noted) で補完。
#     1 件以上補完したら [CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1 を emit。
# (b) invariant #5: pre_existing == false ∧ scope == "nit-noted" の finding を検出。
#     1 件以上あれば WARNING + [CONTEXT] REVIEW_SOURCE_AUTO_CORRECTED=1 を emit し、
#     scope を current-pr に自動書き換え。
# (c) (a) または (b) で mutation が発生した場合のみ、normalized tempfile に書き出し、
#     review_source_path を tempfile path に差し替えて downstream で参照させる。
# (d) 後方互換: invariant #5 は pre_existing フィールドが存在する 1.1.0 JSON のみで発火する
#     (1.0/1.0.0 では default mapping は scope を補完するのみで pre_existing は補完しない)。
norm_sv=$(jq -r '.schema_version // "unknown"' "$review_source_path" 2>/dev/null || echo "unknown")
norm_defaulted_count=0
norm_corrected_count=0
case "$norm_sv" in
  "1.0.0"|"1.0")
    norm_defaulted_count=$(jq '[.findings[]? | select(has("scope") | not)] | length' "$review_source_path" 2>/dev/null || echo 0)
    ;;
esac
norm_corrected_count=$(jq '[.findings[]? | select(.pre_existing == false and .scope == "nit-noted")] | length' "$review_source_path" 2>/dev/null || echo 0)
if [ "${norm_defaulted_count:-0}" -gt 0 ] || [ "${norm_corrected_count:-0}" -gt 0 ]; then
  if norm_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-fix-normalized-XXXXXX" 2>/dev/null); then
    if jq '
      .findings |= map(
        (if has("scope") then . else .scope = (
          if .severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" then "current-pr"
          else "nit-noted"
          end
        ) end)
        | (if .pre_existing == false and .scope == "nit-noted" then .scope = "current-pr" else . end)
      )
    ' "$review_source_path" > "$norm_tmp" 2>/dev/null; then
      if [ "${norm_defaulted_count:-0}" -gt 0 ]; then
        echo "WARNING: $norm_defaulted_count findings の scope を schema 1.0 後方互換で severity-based default mapping により補完しました" >&2
        echo "[CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1; reason=scope_omitted_in_v1_0; count=$norm_defaulted_count; schema_version=$norm_sv" >&2
      fi
      if [ "${norm_corrected_count:-0}" -gt 0 ]; then
        echo "WARNING: $norm_corrected_count findings が invariant #5 違反 (pre_existing=false × scope=nit-noted) のため scope を current-pr に auto-correct しました" >&2
        echo "[CONTEXT] REVIEW_SOURCE_AUTO_CORRECTED=1; reason=pre_existing_false_scope_nit_noted; count=$norm_corrected_count" >&2
      fi
      review_source_path="$norm_tmp"
      # hand-off 完了: 下流の severity_map 構築が review_source_path 経由で参照するため、
      # 二重 rm 回避 + downstream 参照保護として handed_off_norm_tmp に path を保持する
      # (severity_map build 完了後、script 終了の trap EXIT で削除される)。
      handed_off_norm_tmp="$norm_tmp"
      norm_tmp=""
    else
      rm -f "$norm_tmp"
      norm_tmp=""
      echo "WARNING: schema 1.1.0 normalization jq が失敗 — 原 JSON のまま続行します" >&2
      echo "[CONTEXT] REVIEW_SOURCE_NORMALIZATION_FAILED=1; reason=jq_mutation_failed" >&2
    fi
  else
    mktemp_norm_rc=$?
    echo "WARNING: schema 1.1.0 normalization 用 mktemp が失敗しました (rc=$mktemp_norm_rc) — 原 JSON のまま続行します" >&2
    echo "  対処: /tmp の容量 / inode 枯渇 / read-only filesystem / permission denied を確認してください" >&2
    echo "[CONTEXT] REVIEW_SOURCE_NORMALIZATION_FAILED=1; reason=mktemp_failure_norm_tmp; rc=$mktemp_norm_rc" >&2
  fi
fi

# ---- 致命性仕分け (fatal triage) ----
# gated finding (scope ∈ {current-pr, follow-up}) を 2 つに割る。判定は本 helper の決定論で行い、
# LLM は下の [CONTEXT] FIX_FATAL_TRIAGE= marker を読むだけにする (fix.md ステップ 1.2.0)。
#
#   fatal = verification.measured == true ∧ severity ∈ {CRITICAL, HIGH}   → findings[] に残す
#   moved = 上記以外の gated finding                                       → non_blocking_findings[] へ移送
#
# 移送要素は severity を書き換えず `demotion_reason: "non_fatal"` を付す (既存 `demotion` オブジェクトは
# pr-review 5.3.0.C の class B 降格専用の判別子なので触らない — 出所が混ざると 6.1.d の降格理由併記が
# 非致命移送にも誤発火する)。scope == "nit-noted" は gated ではないため対象外 (従来どおり認知のみ)。
#
# 移送が 1 件以上あるときだけ、入力ファイル ($orig_source_path) へ tempfile + mv で atomic に書き戻す。
# 永続化するのは `non_blocking_findings[]` が「移送分の全文の唯一の保存先」であり、iterate 5.S の
# nb-sweep (hooks/scripts/nb-sweep-collect.sh) が永続 JSON から同配列を読むため — ephemeral に留めると
# 移送分が sweep 母集団から silent に脱落する。書き戻す文書は normalization 適用後のものを含む
# (findings[] だけ書き換えて scope 正規化を落とすと同一ファイル内で整合が崩れるため)。
# measured_gate receipt は pr-review が「ゲートを適用した時点」の統計であり、本仕分けは別ゲートの
# 記録なので再計算しない (receipt の意味を後から書き換えない)。
#
# 未判定 (verification.measured が boolean でない) は blocking にも non-blocking にも倒さず exit 1。
fatal_triage_undetermined=""
fatal_triage_bad_severity=""
fatal_triage_bad_severity=$(jq -r '
  [.findings[]? | select(
    (.severity | IN("CRITICAL","HIGH","MEDIUM","LOW-MEDIUM","LOW")) | not
  ) | (.id // "F-?")] | join(",")
' "$review_source_path" 2>/dev/null || echo "__JQ_FAILED__")
if [ "$fatal_triage_bad_severity" = "__JQ_FAILED__" ]; then
  echo "ERROR: severity enum 検査用 jq が失敗しました" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_jq_failed" >&2
  exit 1
fi
if [ -n "$fatal_triage_bad_severity" ]; then
  echo "ERROR: findings[].severity が enum 外の finding があります: $fatal_triage_bad_severity" >&2
  echo "  受理値: CRITICAL / HIGH / MEDIUM / LOW-MEDIUM / LOW" >&2
  echo "  対処: /rite:pr-review を再実行してレビュー結果を作り直してください" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=severity_enum_violation; findings=$fatal_triage_bad_severity" >&2
  exit 1
fi

fatal_triage_undetermined=$(jq -r '
  [.findings[]? | select((.scope == "current-pr") or (.scope == "follow-up"))
   | select(((.verification | type) != "object") or ((.verification.measured | type) != "boolean"))
   | (.id // "F-?")] | join(",")
' "$review_source_path" 2>/dev/null || echo "__JQ_FAILED__")
if [ "$fatal_triage_undetermined" = "__JQ_FAILED__" ]; then
  echo "ERROR: 実測判定の検査用 jq が失敗しました" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_jq_failed" >&2
  exit 1
fi
if [ -n "$fatal_triage_undetermined" ]; then
  echo "ERROR: verification.measured を持たない gated finding があります: $fatal_triage_undetermined" >&2
  echo "  未判定を blocking / non-blocking のどちらにも倒さず停止します (fail-loud)" >&2
  echo "  対処: /rite:pr-review を再実行し、実測必須ゲートを適用したレビュー結果を作り直してください" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=measured_undetermined; findings=$fatal_triage_undetermined" >&2
  exit 1
fi

fatal_triage_counts=$(jq -r '
  def gated: (.scope == "current-pr") or (.scope == "follow-up");
  def fatal: gated and (.verification.measured == true)
             and ((.severity == "CRITICAL") or (.severity == "HIGH"));
  [([.findings[]? | select(fatal)] | length),
   ([.findings[]? | select(gated and (fatal | not))] | length)] | @tsv
' "$review_source_path" 2>/dev/null || echo "__JQ_FAILED__")
if [ "$fatal_triage_counts" = "__JQ_FAILED__" ]; then
  echo "ERROR: 致命性仕分けの件数算出 jq が失敗しました" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_jq_failed" >&2
  exit 1
fi
fatal_count=$(printf '%s' "$fatal_triage_counts" | cut -f1)
moved_count=$(printf '%s' "$fatal_triage_counts" | cut -f2)

if [ "${moved_count:-0}" -gt 0 ]; then
  # 書き出し先は入力ファイルと同一ディレクトリに取る (mv を跨デバイスにせず atomic に保つ)
  if ! triage_tmp=$(mktemp "${orig_source_path}.triage.XXXXXX" 2>/dev/null); then
    triage_mktemp_rc=$?
    echo "ERROR: 致命性仕分け用 tempfile の mktemp が失敗しました (rc=$triage_mktemp_rc)" >&2
    echo "  対処: $(dirname "$orig_source_path") の容量 / inode 枯渇 / read-only filesystem / permission denied を確認してください" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_mktemp_failed; rc=$triage_mktemp_rc" >&2
    exit 1
  fi
  # 移送は 1 回の jq で findings[] の絞り込みと non_blocking_findings[] への追記を同時に行う
  # (部分適用を残さないため)。append であり置換ではない — 実測ゲート降格分 / class B 降格分の
  # 既存要素はそのまま保持し、移送分を末尾に足す。
  # 再入冪等性: 移送済み finding は findings[] に残らないため、同一 JSON への再実行は moved=0 に
  # なり本ブロックへ入らない (二重移送しない)。fix --nb-sweep が 1.2.0 を再通過しても同じ。
  if jq '
    def gated: (.scope == "current-pr") or (.scope == "follow-up");
    def fatal: gated and (.verification.measured == true)
               and ((.severity == "CRITICAL") or (.severity == "HIGH"));
    (.non_blocking_findings //= [])
    | .non_blocking_findings = (.non_blocking_findings
        + [.findings[]? | select(gated and (fatal | not)) | . + {demotion_reason: "non_fatal"}])
    | .findings = [.findings[]? | select((gated | not) or fatal)]
  ' "$review_source_path" > "$triage_tmp" 2>/dev/null; then
    :
  else
    triage_jq_rc=$?
    rm -f "$triage_tmp"
    triage_tmp=""
    echo "ERROR: 致命性仕分けの移送 jq が失敗しました (rc=$triage_jq_rc)" >&2
    echo "  影響: 移送を部分適用したまま fix を続行しないため停止します (入力ファイルは無変更)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_jq_failed; rc=$triage_jq_rc" >&2
    exit 1
  fi

  # 書き戻し前の自己検証: 本経路は hooks/review-result-save.sh を通らない書き込み経路のため、
  # 同 helper が保存境界で見ている不変条件 (non_blocking_findings が配列 / id が 2 配列の和集合で
  # 一意かつ ^F-[0-9]{2,}$) をここで確認する。違反時は mv せず非ゼロ終了し、壊れた JSON を永続化しない。
  if ! jq -e '
    ((.non_blocking_findings | type) == "array")
    and ((.findings | type) == "array")
    and (([.findings[]?, .non_blocking_findings[]? | .id // ""] ) as $ids
         | ($ids | all(test("^F-[0-9]{2,}$"))) and (($ids | unique | length) == ($ids | length)))
  ' "$triage_tmp" >/dev/null 2>&1; then
    rm -f "$triage_tmp"
    triage_tmp=""
    echo "ERROR: 移送後 JSON の自己検証に失敗しました (non_blocking_findings の型、または id の書式 / 和集合の一意性)" >&2
    echo "  影響: 壊れた JSON を永続化しないため書き戻しを中止します (入力ファイルは無変更)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_id_union_violation" >&2
    exit 1
  fi

  if ! mv "$triage_tmp" "$orig_source_path" 2>/dev/null; then
    triage_mv_rc=$?
    rm -f "$triage_tmp"
    triage_tmp=""
    echo "ERROR: 移送後 JSON の atomic mv に失敗しました: $orig_source_path (rc=$triage_mv_rc)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_mv_failed; rc=$triage_mv_rc" >&2
    exit 1
  fi
  triage_tmp=""
  echo "WARNING: $moved_count findings (実測ありだが CRITICAL/HIGH ではない gated 指摘) を non_blocking_findings[] へ移送しました (severity は不変)" >&2
  # downstream は書き戻し後の入力ファイルを参照する。normalization tempfile はもう使わない。
  [ -n "${handed_off_norm_tmp:-}" ] && rm -f "$handed_off_norm_tmp"
  handed_off_norm_tmp=""
  review_source_path="$orig_source_path"
fi
echo "[CONTEXT] FIX_FATAL_TRIAGE=applied; fatal=${fatal_count:-0}; moved=${moved_count:-0}" >&2

# verified-review H-1/H-2 対応: jq の exit code を明示捕捉する。
# `duplicate_keys=$(jq ...)` / `severity_map_json=$(jq -c ...)` を exit code を check せずに書くと、
# jq バイナリ異常 / OOM / TOCTOU (別プロセスが file を rm / truncate) で silent に空文字になる。
# 重複警告が silent skip し、severity_map 構築が無音で空になる regression を防ぐため、
# if-else で exit code を独立 capture する。
jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-jq-err-XXXXXX" 2>/dev/null) || jq_err=""

# line フィールドの nullable sentinel 正規化
# review-result-schema.md L92 で line は `integer | null` (null が行非依存指摘の sentinel) に変更。
# `(.line | tostring)` を素朴に使うと `null` が `"null"` 文字列に変換される (jq `tostring` の仕様) ため
# `src/foo.ts:null` のような key が生成され、`line: 0` legacy の key と混在すると key 衝突するリスクがある。
# 後方互換で `line == 0` / `line == null` の両方を `"anchor"` sentinel に正規化することで、
# 同一ファイル複数の行非依存指摘が key 衝突で silent に畳み込まれるのを防ぐ。
if duplicate_keys=$(jq -r '[.findings[] | (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end))] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
  if [ -n "$duplicate_keys" ]; then
    echo "WARNING: 重複 file:line を持つ finding を検出しました (severity 上書きの可能性):" >&2
    printf '%s\n' "$duplicate_keys" | sed 's/^/  - /' >&2
    echo "  jq from_entries は同一 key を後勝ちで畳み込みます。重複行に対する severity は最後の finding の値が採用されます。" >&2
    echo "  対処: review-result JSON 内の重複 file:line を手動確認してください。" >&2
  fi
else
  jq_dup_rc=$?
  echo "WARNING: 重複 file:line 検出用 jq が失敗しました (rc=$jq_dup_rc) — silent data loss 検出を skip します" >&2
  [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "  影響: 同一 file:line の重複 severity 警告が出ないため、後段で最後勝ち畳み込みが silent に発生する可能性があります" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=jq_duplicate_check_failed; rc=$jq_dup_rc" >&2
  # severity_map 構築は続行する (重複警告の喪失は non-blocking 失敗として扱う)
fi

# duplicate_keys と同じ nullable sentinel 正規化を適用
if severity_map_json=$(jq -c '[.findings[] | {key: (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end)), value: .severity}] | from_entries' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
  :
else
  jq_smap_rc=$?
  echo "ERROR: severity_map 構築用 jq が失敗しました (rc=$jq_smap_rc)" >&2
  [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "  対処: review-result JSON ($review_source_path) の内容と jq バイナリを確認してください" >&2
  echo "  影響: severity_map が空のまま後段に流れ、指摘 0 件と誤認される silent regression を防ぐため fail-fast します" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=severity_map_build_failed; rc=$jq_smap_rc" >&2
  # [fix:error] は stdout 分離契約のため caller が emit する (本 helper は非ゼロ exit のみ)
  exit 1
fi
# M2: scope_map を severity_map と並行構築。
# findings[].scope は schema 1.1.0 で導入され、1.0/1.0.0 JSON では normalization 段階で
# severity-based default mapping により補完済み (上記 (a))。本 step では normalization 後の
# review_source_path から scope を file:line key で map 化する。
# 後段の ステップ 1.3 (classification) / ステップ 1.4 (display) / ステップ 2.1 (entry routing) /
# ステップ 4.6 (acknowledged_nit_count 計算) で参照される。
if scope_map_json=$(jq -c '[.findings[] | {key: (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end)), value: .scope}] | from_entries' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
  :
else
  jq_scmap_rc=$?
  echo "WARNING: scope_map 構築用 jq が失敗しました (rc=$jq_scmap_rc) — scope-based routing が無効化されます (legacy blocking 扱い)" >&2
  [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=scope_map_build_failed; rc=$jq_scmap_rc" >&2
  scope_map_json="{}"
fi
[ -n "$jq_err" ] && rm -f "$jq_err"
jq_err=""

exit 0
