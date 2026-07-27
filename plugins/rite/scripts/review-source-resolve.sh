#!/bin/bash
# rite workflow - Hybrid Review Source Resolution (Priority chain)
#
# Resolves WHICH review-result source `/rite:fix` should consume, following
# the Priority chain documented in skills/fix/SKILL.md ステップ 1.2.0:
#   Priority 0: explicit --review-file (caller's --review-file-path)
#   Priority 1: conversation context  (caller's --conversation-decision + receipt)
#   Priority 2: latest local JSON file (.rite/review-results/{pr_number}-*.json)
#   Priority 3: PR comment (backward-compat fall-through)
#   fallback  : none usable → caller routes to interactive fallback (ステップ 1.2.0.1)
#
# Extracted from `skills/fix/SKILL.md` ステップ 1.2.0 Selection logic block
# The old ~550-line inline bash block required
# the LLM to literal-substitute pr_number / review_file_path / Priority 1
# decision+receipt directly into the markdown fence; those substitution points
# are now this helper's CLI arguments. The Priority chain logic, observability
# markers, trap cleanup, and corrupt-file rename side effects are preserved
# verbatim.
#
# Usage:
#   bash review-source-resolve.sh \
#     --pr-number <n> \
#     --review-file-path <path|__RITE_UNSET__> \
#     --conversation-decision <use|none> \
#     --p1-scan-turns <n> \
#     --p1-scan-found <true|false>
#
# Arguments (all required; the caller substitutes them from ステップ 1.0 / 1.0.1
# values and the LLM's Priority 1 conversation judgement):
#   --pr-number             正規化済み PR 番号 (数値)。非数値は「未 substitute」とみなす。
#   --review-file-path      ステップ 1.0.1 の [CONTEXT] REVIEW_FILE_PATH=... 値。
#                           sentinel `__RITE_UNSET__` = --review-file 未指定。
#   --conversation-decision Priority 1 判定: 直前 assistant turn に `## 📜 rite レビュー結果`
#                           があれば `use`、なければ `none`。
#   --p1-scan-turns         Priority 1 receipt: scan した assistant turn 数 (use 時は 1 以上)。
#   --p1-scan-found         Priority 1 receipt: `true` (use) / `false` (none)。
#
# Output — stderr (observability / marker fidelity contract with fix.md):
#   全 `[CONTEXT] REVIEW_SOURCE*` / `[CONTEXT] REVIEW_SOURCE_*` WARNING を stderr へ emit。
#   解決完了時に最終 marker を emit する (fix.md 旧 L952 と verbatim):
#     [CONTEXT] REVIEW_SOURCE=<explicit_file|conversation|local_file|pr_comment|fallback>; \
#               review_source_path=<path or empty>; pr_number=<n>
#   下流の severity_map build ブロック (fix.md L979+) はこの marker を LLM 仲介で読み、
#   review_source / review_source_path を literal 置換する。markerフォーマット変更厳禁。
#
# Output — stdout:
#   なし。`[fix:error]` sentinel は **emit しない** ([fix:error] stdout 分離)。
#   fatal は stderr の `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=...` + 非ゼロ exit で signal し、
#   caller (fix.md) が `[fix:error]` を stdout へ出力する。
#
# Exit codes:
#   0 = review_source 解決成功 (fallback を含む — fallback は interactive への正常 routing)
#   1 = fatal (placeholder 残留 / Priority 1 receipt 不整合 / review_source 未解決) — caller が [fix:error] 出力
#   2 = usage error (引数欠落 / 不正)
#
# NOTE: `set -e` は意図的に省略する。本 helper は Priority chain を明示分岐
# (review_source="fallback"/"pr_comment" の set) で進めるため、個々の jq/find 失敗で
# abort してはならない。`set -o pipefail` のみ block 本体で有効化する (旧 block と同一)。
set -uo pipefail

# --- bash 4+ compat guard (mapfile builtin; Priority 2 で使用) ---
# fix.md ステップ 1.0.1 の canonical guard と対称。helper は独立プロセスのため
# defense-in-depth として再掲する。bash 3.2 (macOS default) では mapfile が無く
# Priority 2 が silent に Priority 3 へ fallthrough する regression を起こす。
# Source: GNU Bash 4.0 NEWS (https://tiswww.case.edu/php/chet/bash/NEWS)
if ! enable -p 2>/dev/null | grep -q mapfile && ! type mapfile >/dev/null 2>&1; then
  echo "ERROR: review-source-resolve.sh は bash 4.0+ を要求します (mapfile builtin)。現バージョン: ${BASH_VERSION:-unknown}" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=bash_version_incompatible" >&2
  exit 1
fi

# --- 引数 parse ---
pr_number=""
review_file_path=""
conversation_review_decision=""
p1_scan_turns=""
p1_scan_found=""
# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定 + `${2:-}` (nounset 非発火) の下で無限ループに
# 陥る。1 回目の shift で $# を確実に 0 にし、2 回目は no-op で安全に抜ける。
while [ $# -gt 0 ]; do
  case "$1" in
    --pr-number)             pr_number="${2:-}"; shift; shift ;;
    --review-file-path)      review_file_path="${2:-}"; shift; shift ;;
    --conversation-decision) conversation_review_decision="${2:-}"; shift; shift ;;
    --p1-scan-turns)         p1_scan_turns="${2:-}"; shift; shift ;;
    --p1-scan-found)         p1_scan_found="${2:-}"; shift; shift ;;
    *)
      echo "ERROR: review-source-resolve.sh: 未知の引数: $1" >&2
      exit 2
      ;;
  esac
done

# placeholder 残留の正規化: caller が LLM substitution を忘れて literal placeholder を
# 渡した場合、旧 inline block と同一 sentinel/ reason へマップして fidelity を保つ。
case "$review_file_path" in
  "{review_file_path_from_phase_1_0_1}")
    echo "ERROR: review_file_path placeholder が literal substitute されていません: '$review_file_path'" >&2
    echo "  caller は ステップ 1.0.1 の [CONTEXT] REVIEW_FILE_PATH=... 値を会話コンテキストから" >&2
    echo "  読み取り、--review-file-path に実値を渡す必要があります。" >&2
    echo "  substitute 値の例: __RITE_UNSET__ (default) / ./foo.json / /abs/path/bar.json" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_file_path_placeholder_residue" >&2
    exit 1
    ;;
esac
case "$conversation_review_decision" in
  "{conversation_review_decision}"|"") conversation_review_decision="__RITE_CONVERSATION_DECISION_UNSET__" ;;
esac
case "$p1_scan_turns" in
  "{p1_scan_turns}"|"") p1_scan_turns="__RITE_P1_SCAN_TURNS_UNSET__" ;;
esac
case "$p1_scan_found" in
  "{p1_scan_found}"|"") p1_scan_found="__RITE_P1_SCAN_FOUND_UNSET__" ;;
esac

# pr_number の数値 fail-fast gate。
# cleanup.md ステップ 6 の pr_number guard および pr-review.md ステップ 6.1.a と対称化。
# caller が literal substitute を忘れた場合 (pr_number が "{pr_number}" 等)、find が
# literal `{pr_number}-*.json` を探して常に 0 件を返し Priority 2 が silent fallthrough する
# 経路を早期に閉じる。FIX_FALLBACK_FAILED を emit して caller が `[fix:error]` を出力する。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: ステップ 1.2.0 の pr_number が literal substitute されていません (値: '$pr_number', 期待: 数値のみ非空)" >&2
    echo "  caller は ステップ 1.0 で正規化された pr_number を --pr-number に渡す必要があります" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 1
    ;;
esac

review_source=""
review_source_path=""

# signal-specific trap を block 冒頭で設置する (find_err tempfile の orphan 防止)。
# canonical pattern: references/bash-trap-patterns.md#signal-specific-trap-template を参照。
# Block 全体の scope を cover するため Priority 2 のネスト内ではなく block 冒頭に配置する。
#
# cleanup 関数内で `local _saved_rc=$?; rm -f ...; return $_saved_rc` を書いてはならない。
# trap handler が `'rc=$?; _rite_fix_p120_cleanup; exit $rc'` 形式で関数を呼ぶとき、関数入場時の
# `$?` は trap handler 内の直前 assignment `rc=$?` の exit code (= 0) であり、真のエラーコードは
# 既に trap handler 側の `rc` 変数に捕捉されている。したがって関数内で `$?` を保存しても常に 0 となり、
# `return $_saved_rc` は常に 0 を返す (コメントと実挙動が乖離する)。trap handler が最終 `exit $rc` で
# outer rc を使うため運用上は無害だが、将来関数を直接呼び出す拡張で silent regression する罠になる。
# trap handler の rc 捕捉に一本化する。
find_err=""
jq_val_err_p0=""
jq_val_err_p2=""
# 型ガードの jq stderr 退避先。ガードが通過する成功経路では elif の then ブロックに入らず
# inline の rm に到達しないため、他の tempfile と同じく cleanup 登録が必須。
vg_err_p0=""
vg_err_p2=""
_rite_fix_p120_cleanup() {
  rm -f "${find_err:-}" "${jq_val_err_p0:-}" "${jq_val_err_p2:-}" "${vg_err_p0:-}" "${vg_err_p2:-}"
}
trap 'rc=$?; _rite_fix_p120_cleanup; exit $rc' EXIT
trap '_rite_fix_p120_cleanup; exit 130' INT
trap '_rite_fix_p120_cleanup; exit 143' TERM
trap '_rite_fix_p120_cleanup; exit 129' HUP

# pipefail を有効化して pipeline 末尾以外のコマンド失敗も捕捉する
set -o pipefail

# corrupt file の退避 (rename) を 3 経路 (jq parse failure / schema_required_fields_missing /
# verification type guard) で共有する。複製は 2 箇所の時点で既に drift しており
# (schema-invalid 側に成功時の「対処」行・失敗時の mv stderr ヘッダと permission 診断行が欠け、
# indent も 4 空白だった)、手書き同期契約が守られていなかった。3 経路目を足すにあたり関数へ
# 集約し、あわせて schema-invalid 側の診断を jq parse 側の詳細版に揃えた (出力は増える方向のみ)。
_rite_rename_corrupt_file() {
  local target="$1" label="$2"
  local corrupt_epoch corrupt_suffix mv_err mv_rc
  corrupt_epoch=$(date +%s 2>/dev/null || printf '%s-%04x' "unknown" "$((RANDOM & 0xffff))")
  corrupt_suffix=".corrupt-${corrupt_epoch}"
  mv_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-corrupt-mv-err-XXXXXX" 2>/dev/null) || mv_err=""
  if mv "$target" "${target}${corrupt_suffix}" 2>"${mv_err:-/dev/null}"; then
    echo "  ${label} file をリネームしました: ${target}${corrupt_suffix}" >&2
    echo "  対処: 内容を確認後、手動で削除するか新しい review を生成してください" >&2
  else
    mv_rc=$?
    echo "  WARNING: ${label} file の rename に失敗 (rc=$mv_rc)。次回 fix で同じ WARNING が再発します" >&2
    if [ -n "$mv_err" ] && [ -s "$mv_err" ]; then
      echo "    詳細 (mv stderr):" >&2
      head -3 "$mv_err" | sed 's/^/      /' >&2
    fi
    echo "    対処: permission denied / read-only filesystem / cross-filesystem / target exists のいずれかを確認" >&2
    echo "    手動削除: rm \"$target\"" >&2
  fi
  [ -n "$mv_err" ] && rm -f "$mv_err"
  return 0
}

# verification 型ガードの述語判定。exit code で 3 状態を返し分けることで、caller が
# 「型崩れ (rc=1)」と「jq 自体の実行失敗 (rc>=2)」を別 reason に routing できるようにする。
# 両者を融合すると、verification を持たない JSON (例: findings 要素が非 object で nested access が
# rc=5 になるもの) にも verification_type_invalid という事実と異なる reason が付く。
# 判定式は review-result-schema.md §verification 型ガード (read 側) の canonical jq と literal 同一。
_rite_verification_type_check() {
  local file="$1" err_file="$2"
  jq -e '
    all(.findings[]?; (.verification == null) or (((.verification | type) == "object") and ((.verification.measured == null) or ((.verification.measured | type) == "boolean"))))
  ' "$file" >/dev/null 2>"$err_file"
}

# Priority 0: Explicit --review-file (from ステップ 1.0.1)
# sentinel `__RITE_UNSET__` (旧 `null` から変更) 以外で
# かつ非空の場合に Priority 0 を発火させる。`null` という literal 文字列を持つファイル名
# (`./null` ではない `null` 単独) も legitimate な path として処理される。
if [ -n "$review_file_path" ] && [ "$review_file_path" != "__RITE_UNSET__" ]; then
  if [ ! -f "$review_file_path" ]; then
    echo "エラー: --review-file で指定されたパスが存在しません: $review_file_path" >&2
    echo "[CONTEXT] REVIEW_SOURCE_MISSING=1; reason=explicit_file_not_found" >&2
    review_source="fallback"
    review_source_path=""
  elif jq_val_err_p0=$(mktemp "${TMPDIR:-/tmp}/rite-jq-val-err-p0-XXXXXX" 2>/dev/null) || true; ! jq empty "$review_file_path" 2>"${jq_val_err_p0:-/dev/null}"; then
    echo "エラー: --review-file で指定されたファイルが有効な JSON ではありません: $review_file_path" >&2
    [ -n "${jq_val_err_p0:-}" ] && [ -s "$jq_val_err_p0" ] && head -3 "$jq_val_err_p0" | sed 's/^/  /' >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_parse" >&2
    rm -f "${jq_val_err_p0:-}"
    review_source="fallback"
    review_source_path=""
  elif ! jq -e '
    (.schema_version | type == "string" and length > 0)
    and (.pr_number | type == "number")
    and (.findings | type == "array")
  ' "$review_file_path" >/dev/null 2>&1; then
    # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
    echo "エラー: --review-file の必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) が欠落: $review_file_path" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_schema_required_fields_missing" >&2
    review_source="fallback"
    review_source_path=""
  elif vg_err_p0=$(mktemp "${TMPDIR:-/tmp}/rite-verif-guard-err-p0-XXXXXX" 2>/dev/null) || vg_err_p0=""; \
       _rite_verification_type_check "$review_file_path" "${vg_err_p0:-/dev/null}"; vg_rc_p0=$?; \
       [ "$vg_rc_p0" -ne 0 ]; then
    # verification 型ガード (review-result-schema.md §verification 型ガード (read 側))。
    # 本ガードを cross-field invariant より前段に置くのは、`(.verification.measured // false)` を
    # 評価する下流 consumer (現時点では未配線 — schema.md の default mapping 節が正準として示す
    # 将来の consumer) に型崩れを到達させないため。本スクリプト内の後段 invariant (#2 / #4 / enum) は
    # .verification を参照しないので、ここでの順序は予防的配置であり、後段が rc=5 になるからではない。
    # 順序が観測可能な差を生むのは reason ラベル (先に評価した側が routing を取る) のみ。
    # measured の存在は要求しない (verification:{} は default mapping の対象として受理する)。
    if [ "$vg_rc_p0" -eq 1 ]; then
      echo "エラー: --review-file の findings[].verification が型崩れです (verification は object/null、measured は boolean/null のみ受理)" >&2
      echo "  期待: \"verification\": {\"measured\": bool, \"repro\": string|null, \"failing_test\": string|null} または欠落" >&2
      echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" >&2
    else
      # rc>=2 は jq 自身の失敗 (ランタイムエラー / バイナリ異常 / IO)。型崩れと同じ reason に
      # 融合すると、verification を持たない JSON にも type_invalid が付いて診断が事実とずれる。
      echo "エラー: --review-file の verification 型ガード実行中に jq が失敗しました (rc=$vg_rc_p0)" >&2
      [ -n "$vg_err_p0" ] && [ -s "$vg_err_p0" ] && head -3 "$vg_err_p0" | sed 's/^/  /' >&2
      echo "  原因候補: findings 要素が object でない / jq バイナリ異常 / OOM / ファイル IO エラー" >&2
      echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_guard_jq_failed; rc=$vg_rc_p0" >&2
    fi
    # tempfile は _rite_fix_p120_cleanup (trap 登録済) が回収する。ここで短絡 rm を書くと
    # 失敗が silent になり、同ファイルが find_err で是正済みの形式に逆行する。
    review_source="fallback"
    review_source_path=""
  elif ! jq -e '
    (.overall_assessment != "mergeable")
    or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
  ' "$review_file_path" >/dev/null 2>&1; then
    # Cross-field invariant (review-result-schema.md): overall_assessment=="mergeable" のときは
    # CRITICAL/HIGH かつ status==open の finding が存在してはならない。違反時は手書き JSON で
    # fix ループを silent に 0 件脱出させる bypass になるため fallback 経路に route する。
    echo "エラー: --review-file の cross-field invariant 違反: overall_assessment=\"mergeable\" だが CRITICAL/HIGH で status=\"open\" の finding が存在します" >&2
    echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=mergeable_has_open_blockers" >&2
    review_source="fallback"
    review_source_path=""
  elif ! jq -e '
    [.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0
  ' "$review_file_path" >/dev/null 2>&1; then
    # Cross-field invariant #4:
    # severity ∈ {CRITICAL, HIGH} ∧ scope == "nit-noted" は禁止 (blocker を nit に降格できない)。
    # 違反時は fallback 経路に route (invariant #2 と同じ FAIL routing)。
    # 1.0/1.0.0 JSON では .scope が欠落しているため `null == "nit-noted"` は false、本 check は
    # 規約的に発火しない (後方互換)。reviewer が CRITICAL を nit に降格させたい場合は severity を
    # MEDIUM/LOW へ自己降格し、original_severity フィールドに元値を保持すること。
    violation_count=$(jq '[.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' "$review_file_path" 2>/dev/null || echo "?")
    echo "エラー: --review-file の cross-field invariant #4 違反: severity ∈ {CRITICAL, HIGH} で scope=\"nit-noted\" の finding が $violation_count 件存在します" >&2
    echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=explicit_file_critical_high_scope_nit_noted; count=$violation_count" >&2
    review_source="fallback"
    review_source_path=""
  elif ! jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' "$review_file_path" >/dev/null 2>&1; then
    # overall_assessment enum validation (review-result-schema.md)
    oa_val=$(jq -r '.overall_assessment // "(null)"' "$review_file_path" 2>/dev/null)
    echo "WARNING: --review-file の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)" >&2
    echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
    review_source="fallback"
    review_source_path=""
  else
    # Priority 0: schema_version も Priority 2 と同じく検証するが、失敗時は直接 fallback へ
    # (ユーザーの明示意図を尊重 — Priority 1-3 に silent fall-through しない)
    # jq exit code を明示捕捉 (commit_sha 抽出と対称化)
    # `if ! var=$(cmd); then rc=$?` では 「!」 演算子が cmd の exit code を反転するため、
    # then ブランチ内の `$?` は 「!」 の結果 (= 0) を返す。`if cmd; then :; else rc=$?; fi` で取得する。
    if schema_version=$(jq -r '.schema_version // "unknown"' "$review_file_path" 2>/dev/null); then
      : # jq 成功
    else
      jq_sv_rc=$?
      echo "WARNING: --review-file の schema_version 抽出で jq が失敗 (rc=$jq_sv_rc)" >&2
      echo "  原因候補: jq バイナリ異常 / OOM / ファイル IO エラー" >&2
      echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_schema_version_jq_failed; rc=$jq_sv_rc" >&2
      schema_version="unknown"
    fi
    case "$schema_version" in
      "1.0.0"|"1.0"|"1.1.0")
        # schema 1.1.0 を accept list に追加。
        # 1.0/1.0.0 受信時は後段の ステップ 1.2.0.s に近接した default mapping ステップで
        # findings[].scope の severity ベース補完を実施する (review-result-schema.md
        # 後方互換性セクション参照)。本 case 内では schema_version をブロックレベルで
        # 受理するだけで、scope 補完は severity_map 構築の直前に集中させる。
        #
        # commit_sha stale detection (verified-review silent-failure C-1)
        # schema で `commit_sha` が required field として記録されているため、現 HEAD との比較で
        # stale file を検出する。mismatch 時は Priority 4 Interactive Fallback へ routing する
        # (ユーザーは「レビュー実行 / 別ファイル指定 / 中止」を選択可能)。
        # [CONTEXT] REVIEW_SOURCE_STALE=1 を emit して observability は維持する。
        # jq バイナリ異常 / I/O エラーと「.commit_sha フィールド不在 (legacy schema)」を区別する。
        # `2>/dev/null || echo ""` の素朴な実装はこの 2 ケースを silent に融合させ、stale detection を silent 無効化してしまう。
        json_commit_sha_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-p0-commit-sha-err-XXXXXX" 2>/dev/null) || json_commit_sha_err=""
        if json_commit_sha=$(jq -r '.commit_sha // empty' "$review_file_path" 2>"${json_commit_sha_err:-/dev/null}"); then
          : # jq 成功 (空 or 非空)
        else
          jq_p0_commit_sha_rc=$?
          echo "WARNING: --review-file の commit_sha 抽出で jq が失敗 (rc=$jq_p0_commit_sha_rc)" >&2
          [ -n "$json_commit_sha_err" ] && [ -s "$json_commit_sha_err" ] && head -3 "$json_commit_sha_err" | sed 's/^/  /' >&2
          echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=jq_error_on_commit_sha; priority=0" >&2
          json_commit_sha=""
        fi
        [ -n "$json_commit_sha_err" ] && rm -f "$json_commit_sha_err"
        if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
          echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2
          echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=git_rev_parse_head_failed" >&2
          head_sha=""
        fi
        if [ -n "$json_commit_sha" ] && [ -n "$head_sha" ] && [ "$json_commit_sha" != "$head_sha" ]; then
          # stale file 検出時は fallback 経路に route する。`RITE_FIX_ACKNOWLEDGE_STALE=1` 環境変数による
          # opt-in 続行経路は設けない。Claude Code Bash tool は呼び出し境界で env var を継承しないため
          # (anthropics/claude-code#2508)、ユーザーが env var を set する手段がなく dead code になる。
          # stale を承知で続行したいユーザーは Priority 4 Interactive fallback の「レビュー実行」or「別ファイル指定」
          # を選択する。stale な検出結果を無視したい特殊ケースは Priority 4 で「別ファイル指定」に同じ path を
          # 再入力することで実質的に対応可能 (ただし再度 stale warning が出る — 設計意図通り)。
          echo "⛔ ERROR: --review-file の commit_sha ($json_commit_sha) が現 HEAD ($head_sha) と不一致です" >&2
          echo "  このファイルは古い commit に対して生成されました。既修正項目を再指摘する可能性があります。" >&2
          echo "  対処 (いずれかを選択):" >&2
          echo "    1. /rite:pr-review を再実行して新しい review を生成する (推奨)" >&2
          echo "    2. 生成時点の commit ($json_commit_sha) に git checkout してから /rite:fix を実行する" >&2
          echo "[CONTEXT] REVIEW_SOURCE_STALE=1; reason=explicit_file_commit_sha_mismatch; json_sha=$json_commit_sha; head_sha=$head_sha" >&2
          echo "  fallback 経路に route します (Priority 4 Interactive fallback)" >&2
          review_source="fallback"
          review_source_path=""
        else
          review_source="explicit_file"
          review_source_path="$review_file_path"
        fi
        ;;
      *)
        echo "エラー: --review-file で指定されたファイルの schema_version が未知です: $schema_version" >&2
        echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=explicit_file_schema_version_unknown" >&2
        review_source="fallback"
        review_source_path=""
        ;;
    esac
  fi
fi

# Priority 1: Conversation context (caller が判断)
# ⚠️ caller への指示: Priority 0 が未発火 (review_source="") の状態で、同一 session 内の直前
# assistant turn に `## 📜 rite レビュー結果` を含む /rite:pr-review 出力が残っていれば、
# 会話コンテキストから findings を読み取り --conversation-decision use を渡す。
# 会話に review 結果がなければ --conversation-decision none を渡す。
# substitute 漏れ (literal placeholder 残留) は silent fallthrough / silent P1 hijack を起こすため fail-fast する。
if [ -z "$review_source" ]; then
  case "$conversation_review_decision" in
    use)
      case "$p1_scan_turns" in
        __RITE_P1_SCAN_TURNS_UNSET__|"")
          echo "ERROR: Priority 1 receipt p1_scan_turns が literal substitute されていません (decision=use)" >&2
          echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_receipt_missing" >&2
          exit 1
          ;;
        *[!0-9]*)
          echo "ERROR: Priority 1 receipt p1_scan_turns が数値ではありません: '$p1_scan_turns'" >&2
          echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_receipt_invalid" >&2
          exit 1
          ;;
      esac
      if [ "$p1_scan_found" != "true" ]; then
        echo "ERROR: Priority 1 decision=use だが p1_scan_found!=true ('$p1_scan_found')" >&2
        echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_receipt_inconsistent" >&2
        exit 1
      fi
      review_source="conversation"
      echo "[CONTEXT] REVIEW_SOURCE=conversation; pr_number=${pr_number}; p1_scan_turns=$p1_scan_turns; p1_scan_found=$p1_scan_found" >&2
      ;;
    none)
      # legitimate な「会話に review 結果なし」経路。receipt 不整合は observability 欠落として
      # WARNING のみ (fail-fast しない — Priority 2 以降に fallthrough)。
      case "$p1_scan_turns" in
        __RITE_P1_SCAN_TURNS_UNSET__|"") echo "WARNING: Priority 1 decision=none だが receipt p1_scan_turns が未設定" >&2 ;;
        *[!0-9]*) echo "WARNING: Priority 1 decision=none だが p1_scan_turns が非数値 ('$p1_scan_turns')" >&2 ;;
      esac
      case "$p1_scan_found" in
        true|false) ;;
        *) echo "WARNING: Priority 1 decision=none だが p1_scan_found が不正/未設定 ('$p1_scan_found')" >&2 ;;
      esac
      :  # Priority 2 以降に fallthrough
      ;;
    __RITE_CONVERSATION_DECISION_UNSET__)
      echo "ERROR: Priority 1 conversation_review_decision が literal substitute されていません" >&2
      echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_decision_unset" >&2
      exit 1
      ;;
    *)
      echo "ERROR: Priority 1 conversation_review_decision に未知の値: '$conversation_review_decision'" >&2
      echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_decision_invalid" >&2
      exit 1
      ;;
  esac
fi

# Priority 2: Local file — lexicographic sort で最新 timestamp を選択
# ファイル名は {pr_number}-YYYYMMDDHHMMSS.json 形式で timestamp が zero-padded のため
# 文字列 sort = 時系列 sort が成立する。BSD find 非互換の -printf を回避し portable に。
#
# SIGPIPE 対策: `find | sort -r | head -1` は pipefail 有効下で
# `head -1` 早期終了により `sort` が SIGPIPE (rc=141) を受け pipeline 失敗扱いとなる
# (bash-defensive-patterns.md Pattern 5 で禁止された anti-pattern)。
# mapfile + process substitution で pipeline を分離し、配列経由で先頭要素を取得する。
if [ -z "$review_source" ]; then
  # 読取先はリポジトリ共通の state ルート (state-path-resolve.sh) 基準。書込側
  # (hooks/review-result-save.sh) と同一の解決で、セッション worktree / main checkout の
  # どちらから実行しても同じ物理パスを読む。解決失敗時は従来の cwd 相対へフォールバック
  # (単一 checkout では同一パスのため挙動不変)。
  _p2_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if _p2_state_root=$(bash "$_p2_script_dir/../hooks/state-path-resolve.sh" "$PWD" 2>/dev/null) && [ -n "$_p2_state_root" ]; then
    _p2_results_dir="$_p2_state_root/.rite/review-results"
  else
    echo "WARNING: review-source-resolve: state-path-resolve.sh の解決に失敗。cwd 相対の .rite/review-results へフォールバックします" >&2
    _p2_results_dir=".rite/review-results"
  fi
  # results dir 不在を初回実行の正常経路として silent pass-through する
  # (初回 fix / fresh clone で確実に再現する UX bug の修正)。cleanup.md ステップ 6 と対称。
  if [ ! -d "$_p2_results_dir" ]; then
    # dir 不在 = 正常経路。Priority 3 へ silent fall-through。
    :
  else
    # mktemp 失敗時も WARNING を emit (format 概形は cleanup.md ステップ 6 と共有、rc capture は
    # reason=`mktemp_failure_norm_tmp` の SoT block (ステップ 1.2.0 schema 1.1.0 normalization、
    # 現在は scripts/review-findings-maps.sh へ委譲済みの
    # `if norm_tmp=$(mktemp ...); then ... else mktemp_norm_rc=$?; fi` 構造) と semantic 同期)。
    # 構造: bash の 「!」否定 pipeline では then 節内 $? が常に 0 になるため、SoT と同じ
    # `if cmd; then :; else rc=$?; fi` 形式を採用する。mktemp の native stderr は SoT (norm_tmp) と
    # 揃えて `2>/dev/null` で抑制する (本ファイル内の他 mktemp capture site と同じ pattern)。
    if find_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-find-err-XXXXXX" 2>/dev/null); then
      : # mktemp 成功 — find_err は valid path
    else
      mktemp_find_err_rc=$?
      echo "WARNING: find stderr 退避用 tempfile の mktemp に失敗しました (rc=$mktemp_find_err_rc)。find の IO エラー詳細は失われます" >&2
      echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
      echo "[CONTEXT] REVIEW_SOURCE_FIND_FAILED=1; reason=mktemp_failure_find_err; rc=$mktemp_find_err_rc" >&2
      find_err=""
    fi

    # mapfile + process substitution で SIGPIPE 経路を断ち、pipefail 下でも安全に動作する
    # sort の stderr も find_err に append して捕捉する (sort OOM / /tmp full を検出)。
    files_arr=()
    mapfile -t files_arr < <(find "$_p2_results_dir" -maxdepth 1 -type f -name "${pr_number}-*.json" 2>"${find_err:-/dev/null}" | sort -r 2>>"${find_err:-/dev/null}")
    latest_file="${files_arr[0]:-}"

    if [ -n "$find_err" ] && [ -s "$find_err" ]; then
      echo "WARNING: $_p2_results_dir/ 検索時にエラー発生:" >&2
      head -3 "$find_err" | sed 's/^/  /' >&2
      echo "  Priority 2 を IO エラーにより skip し、Priority 3 (PR コメント) に明示 routing します" >&2
      echo "[CONTEXT] REVIEW_SOURCE_FIND_FAILED=1; reason=local_file_find_io_error" >&2
      review_source="pr_comment"
      review_source_path=""
    fi
    # process substitution では内部コマンドの exit code が親に伝播しない。
    # ファイルが存在するのに配列が空の場合は sort/find failure を疑い WARNING を emit する。
    if [ ${#files_arr[@]} -eq 0 ] && [ -d "$_p2_results_dir" ]; then
      _p2_glob_check=("$_p2_results_dir"/"${pr_number}"-*.json)
      if [ -e "${_p2_glob_check[0]:-}" ]; then
        echo "WARNING: $_p2_results_dir/ にマッチするファイルが存在しますが mapfile 結果が空です (sort/find failure の可能性)" >&2
        echo "[CONTEXT] REVIEW_SOURCE_FIND_FAILED=1; reason=sort_or_mapfile_failure" >&2
      fi
      unset _p2_glob_check
    fi
    # 旧 `[ -n "$find_err" ] && rm -f && find_err=""` の short-circuit は
    # rm 失敗時に find_err="" 代入に到達せず、後続の trap cleanup が同じ rm を再実行する重複処理になっていた
    # (実害は軽微だが、rm 失敗が silent 抑制される問題は本 PR 全体の指摘事項と矛盾する)。
    # 改行 + rm 失敗時 WARNING + find_err="" を独立 statement で実行する。
    if [ -n "$find_err" ]; then
      if ! rm -f "$find_err"; then
        echo "WARNING: find_err tempfile の削除に失敗 ($find_err)。trap cleanup が後で再試行します" >&2
      fi
      find_err=""
    fi

    # find で見つかった latest_file が -f check で脱落した経路を silent にしない。
    # permission denied / symlink 破壊 / TOCTOU で stat 不能な場合、ユーザーは Priority 3 routing 理由を debug できない。
    if [ -n "$latest_file" ] && [ ! -f "$latest_file" ]; then
      echo "WARNING: find で発見した latest_file が -f check で失敗 ($latest_file)。permission / symlink 破壊の可能性" >&2
      echo "[CONTEXT] REVIEW_SOURCE_STAT_FAILED=1; reason=latest_file_stat_failure" >&2
      # Priority 2 stat failure branch で review_source を
      # 明示 set する (他の Priority 2 failure branch 〈jq parse / schema / commit_sha mismatch〉は
      # 全て `review_source="pr_comment"; review_source_path=""` を明示 set するが、stat failure
      # のみ最終強制昇格経路に依存していた非対称を解消)。
      review_source="pr_comment"
      review_source_path=""
    fi
    if [ -z "$review_source" ] && [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
      # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
      jq_val_err_p2=$(mktemp "${TMPDIR:-/tmp}/rite-jq-val-err-p2-XXXXXX" 2>/dev/null) || jq_val_err_p2=""
      if ! jq empty "$latest_file" 2>"${jq_val_err_p2:-/dev/null}"; then
        echo "WARNING: $latest_file は有効な JSON ではありません。Priority 3 (PR コメント) に routing します。" >&2
        [ -n "${jq_val_err_p2:-}" ] && [ -s "$jq_val_err_p2" ] && head -3 "$jq_val_err_p2" | sed 's/^/  /' >&2
        echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_json_parse_failure" >&2
        # verified-review M-6 (M10) 対応: corrupted file を .corrupt-{epoch} にリネームし、
        # 次回の lexicographic sort で選ばれないようにする。WARNING を出すだけで corrupted file を
        # 残すと、次回呼び出し時も同じファイルが最新 timestamp として選ばれ、同一 WARNING が
        # 繰り返される無限 ring に陥る。rename 手順は _rite_rename_corrupt_file に集約済
        # (経路ごとに変わるのはラベル語のみ)。
        _rite_rename_corrupt_file "$latest_file" "corrupted"
        review_source="pr_comment"
        review_source_path=""
      elif ! jq -e '
        (.schema_version | type == "string" and length > 0)
        and (.pr_number | type == "number")
        and (.findings | type == "array")
      ' "$latest_file" >/dev/null 2>&1; then
        # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
        echo "WARNING: $latest_file の必須フィールドが欠落。Priority 3 (PR コメント) に routing します。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_schema_required_fields_missing" >&2
        _rite_rename_corrupt_file "$latest_file" "schema-invalid"
        review_source="pr_comment"
        review_source_path=""
      elif vg_err_p2=$(mktemp "${TMPDIR:-/tmp}/rite-verif-guard-err-p2-XXXXXX" 2>/dev/null) || vg_err_p2=""; \
           _rite_verification_type_check "$latest_file" "${vg_err_p2:-/dev/null}"; vg_rc_p2=$?; \
           [ "$vg_rc_p2" -ne 0 ]; then
        # verification 型ガード (Priority 0 と対称。判定式と受理範囲の SoT は
        # review-result-schema.md §verification 型ガード (read 側))。
        if [ "$vg_rc_p2" -eq 1 ]; then
          echo "WARNING: $latest_file の findings[].verification が型崩れです (verification は object/null、measured は boolean/null のみ受理)。Priority 3 に routing します。" >&2
          echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_type_invalid" >&2
          # 型崩れは構造的な schema 違反で自己修復しないため、sibling instance と同じく rename して
          # 次回の lexicographic sort で選ばれないようにする (同一 WARNING の反復を防ぐ)。
          _rite_rename_corrupt_file "$latest_file" "type-invalid"
        else
          # rc>=2 は jq 自身の失敗。ファイルが壊れている証拠がないため rename しない
          # (破壊的操作を conflated signal で駆動しない)。routing だけ Priority 3 へ倒す。
          echo "WARNING: $latest_file の verification 型ガード実行中に jq が失敗しました (rc=$vg_rc_p2)。Priority 3 に routing します。" >&2
          [ -n "$vg_err_p2" ] && [ -s "$vg_err_p2" ] && head -3 "$vg_err_p2" | sed 's/^/  /' >&2
          echo "  原因候補: findings 要素が object でない / jq バイナリ異常 / OOM / ファイル IO エラー" >&2
          echo "  注: 破損が未証明のため .corrupt-{epoch} rename は行いません" >&2
          echo "  対処: /rite:pr-review を再実行すれば新しい timestamp のファイルが生成され本ファイルは選ばれなくなります (即時解消は手動削除: rm \"$latest_file\")" >&2
          echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_guard_jq_failed; rc=$vg_rc_p2" >&2
        fi
        # tempfile は _rite_fix_p120_cleanup (trap 登録済) が回収する (P0 側と同じ理由)。
        review_source="pr_comment"
        review_source_path=""
      elif ! jq -e '
        (.overall_assessment != "mergeable")
        or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
      ' "$latest_file" >/dev/null 2>&1; then
        # Cross-field invariant (review-result-schema.md): overall_assessment=="mergeable" のときは
        # CRITICAL/HIGH かつ status==open の finding が存在してはならない。
        # corrupt rename はしない (データは構造的に valid、ビジネスルール違反のみ)。
        echo "WARNING: $latest_file の cross-field invariant 違反 (mergeable だが open の CRITICAL/HIGH finding あり)。Priority 3 に routing します。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=local_file_cross_field_invariant_violated" >&2
        review_source="pr_comment"
        review_source_path=""
      elif ! jq -e '
        [.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0
      ' "$latest_file" >/dev/null 2>&1; then
        # Cross-field invariant #4:
        # severity ∈ {CRITICAL, HIGH} ∧ scope == "nit-noted" は禁止。
        # corrupt rename はしない (データは構造的に valid、ビジネスルール違反のみ)。
        # 1.0/1.0.0 JSON では .scope が欠落しているため本 check は規約的に発火しない (後方互換)。
        violation_count=$(jq '[.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' "$latest_file" 2>/dev/null || echo "?")
        echo "WARNING: $latest_file の cross-field invariant #4 違反 (severity ∈ {CRITICAL, HIGH} で scope=\"nit-noted\" の finding が $violation_count 件)。Priority 3 に routing します。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=local_file_critical_high_scope_nit_noted; count=$violation_count" >&2
        review_source="pr_comment"
        review_source_path=""
      elif ! jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' "$latest_file" >/dev/null 2>&1; then
        # overall_assessment enum validation (review-result-schema.md)
        oa_val=$(jq -r '.overall_assessment // "(null)"' "$latest_file" 2>/dev/null)
        echo "WARNING: $latest_file の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)。Priority 3 に routing します。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
        review_source="pr_comment"
        review_source_path=""
      else
        # schema_version 検証 (Priority 2 success 内で実施)
        # jq exit code を明示捕捉 (commit_sha 抽出と対称化)
        # `if ! var=$(cmd); then rc=$?` では 「!」 演算子が cmd の exit code を反転するため、
        # then ブランチ内の `$?` は 「!」 の結果 (= 0) を返す。`if cmd; then :; else rc=$?; fi` で取得する。
        if schema_version=$(jq -r '.schema_version // "unknown"' "$latest_file" 2>/dev/null); then
          : # jq 成功
        else
          jq_sv_rc=$?
          echo "WARNING: $latest_file の schema_version 抽出で jq が失敗 (rc=$jq_sv_rc)" >&2
          echo "  原因候補: jq バイナリ異常 / OOM / ファイル IO エラー" >&2
          echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_schema_version_jq_failed; rc=$jq_sv_rc" >&2
          schema_version="unknown"
        fi
        case "$schema_version" in
          "1.0.0"|"1.0"|"1.1.0")
            # schema 1.1.0 を accept list に追加 (Priority 2 case 文)。
            # Priority 0/2/3 の 3 sites を symmetric に保つ (review-result-schema.md
            # Schema Version SoT セクションの「読取側 (3 値受理義務、3 箇所で完全同期)」契約)。
            #
            # commit_sha stale detection (verified-review silent-failure C-1)
            # Priority 2 は lexicographic 最新ファイルを機械的に選ぶため、古い commit に対する
            # review 結果を silent に使用するリスクがある。現 HEAD と比較し、mismatch 時は Priority 3
            # (PR コメント) に routing する (Priority 2 の他の失敗経路と同じ扱い)。
            # 古い local file には fallback しない (Priority 2 schema doc の設計判断と整合)。
            # jq IO エラーを silent 化しない。
            json_commit_sha_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-p2-commit-sha-err-XXXXXX" 2>/dev/null) || json_commit_sha_err=""
            if json_commit_sha=$(jq -r '.commit_sha // empty' "$latest_file" 2>"${json_commit_sha_err:-/dev/null}"); then
              :
            else
              jq_p2_commit_sha_rc=$?
              echo "WARNING: $latest_file の commit_sha 抽出で jq が失敗 (rc=$jq_p2_commit_sha_rc)" >&2
              [ -n "$json_commit_sha_err" ] && [ -s "$json_commit_sha_err" ] && head -3 "$json_commit_sha_err" | sed 's/^/  /' >&2
              echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=jq_error_on_commit_sha; priority=2" >&2
              json_commit_sha=""
            fi
            [ -n "$json_commit_sha_err" ] && rm -f "$json_commit_sha_err"
            if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
              echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2
              echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=git_rev_parse_head_failed" >&2
              head_sha=""
            fi
            if [ -n "$json_commit_sha" ] && [ -n "$head_sha" ] && [ "$json_commit_sha" != "$head_sha" ]; then
              echo "WARNING: $latest_file の commit_sha ($json_commit_sha) が現 HEAD ($head_sha) と不一致です (stale)" >&2
              echo "  本ファイルは古い commit に対して生成されました。Priority 3 (PR コメント) に routing します。" >&2
              echo "  対処: /rite:pr-review を再実行すれば新しい timestamp + 現 HEAD の commit_sha を持つファイルが生成されます。" >&2
              echo "[CONTEXT] REVIEW_SOURCE_STALE=1; reason=local_file_commit_sha_mismatch; json_sha=$json_commit_sha; head_sha=$head_sha" >&2
              review_source="pr_comment"
              review_source_path=""
            else
              review_source="local_file"
              review_source_path="$latest_file"
              # 成功メッセージも stderr に統一する
              # ([CONTEXT] emit と stdout/stderr 規約を揃え、observability ログ専用ストリームを stderr に集約)
              echo "✅ ローカルファイルからレビュー結果を読み込みます: $latest_file" >&2
            fi
            ;;
          *)
            echo "WARNING: 未知の schema_version: $schema_version ($latest_file)" >&2
            echo "  対処: schema 定義は plugins/rite/references/review-result-schema.md を参照" >&2
            echo "  本ファイルをスキップし、次の優先順位のソース (Priority 3) を試行します。" >&2
            echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=local_file_schema_version_unknown" >&2
            # 明示的に Priority 3 (pr_comment) に routing する (dead state 防止)
            review_source="pr_comment"
            review_source_path=""
            ;;
        esac
      fi
    fi
  fi
fi

# Priority 3: PR comment (fall through to existing Broad Retrieval path if still unresolved)
if [ -z "$review_source" ]; then
  review_source="pr_comment"  # Existing ステップ 1.2 Broad Retrieval / Fast Path handles this
fi

# Priority 0/2/3/fallback の最終 review_source 値を
# machine-readable marker として emit する。Priority 1 `use` branch のみが
# `[CONTEXT] REVIEW_SOURCE=conversation` を emit する状態では、他 4 経路の observability が欠落する。
# schema.md `読取優先順位` セクションは「ステップ 4.5.3 / 4.6 で `{review_source}` を log に出すため
# conversation 経由で取り込んだ場合も他の Priority と同様に provenance を残す必要がある」と
# 明記するため、全経路で emit して契約を満たす。
# 対象: explicit_file (Priority 0)、conversation (Priority 1、既存 emit は残し defense-in-depth
# として後段でも emit)、local_file (Priority 2)、pr_comment (Priority 3)、fallback (Priority 0
# 失敗 → Interactive Fallback 経路)。
case "${review_source:-}" in
  explicit_file|local_file|pr_comment|conversation|fallback)
    echo "[CONTEXT] REVIEW_SOURCE=${review_source}; review_source_path=${review_source_path:-}; pr_number=${pr_number}" >&2
    ;;
  "")
    echo "ERROR: review_source が ステップ 1.2.0 終了時に空です (Priority chain の設計契約違反)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_source_unset_post_chain" >&2
    exit 1
    ;;
  *)
    echo "ERROR: review_source に未知の値: '$review_source' (Priority chain の設計契約違反)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_source_invalid_post_chain" >&2
    exit 1
    ;;
esac

# === ステップ 1.2.0 Selection logic block end ===
set +o pipefail
exit 0
