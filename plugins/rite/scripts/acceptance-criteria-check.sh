#!/bin/bash
# rite workflow - 受入条件確認 (acceptance reviewer) の機械検査
#
# Responsibility: pr-review が acceptance reviewer を扱う 3 箇所の決定論的検査を担う。
#   extract — 関連 Issue body から `## 5. Acceptance Criteria` 配下の `### AC-N` 集合を抽出する
#   table   — acceptance reviewer の raw 出力の `### 受入条件確認` 表を、抽出集合と照合する
#   final   — 降格ゲート適用後のレビュー結果 JSON で、判定行の AC-ID 集合・受入条件確認の対象判定と
#             reviewers[] の整合・未充足行の finding が blocking に残るかを検査する
# 判定に LLM の裁量を介在させないための強制層であり、どの subcommand も入力を書き換えない。
#
# Called from:
#   - skills/pr-review/SKILL.md ステップ 1.3.1 (extract) / 5.1 (table) / 5.3 最終整合検査 (final)
#
# Usage:
#   acceptance-criteria-check.sh extract --body-file PATH
#   acceptance-criteria-check.sh table --expected AC-N,AC-M --input PATH
#   acceptance-criteria-check.sh final --expected AC-N,AC-M|"" --input PATH
#     (final の --expected は必須。空文字列は「対象外 (skipped) の cycle」を意味する)
#
# stdout contract:
#   extract — 成功 (target) 時に AC-ID のカンマ区切り 1 行。skipped / 失敗時は出力なし
#   table   — 成功時に判定行の JSON 配列 [{id, status, evidence}] (status は satisfied / unmet / unverified)
#   final   — なし
#
# stderr contract:
#   [CONTEXT] ACCEPTANCE_SCOPE=target; ids={ids}
#   [CONTEXT] ACCEPTANCE_SCOPE=skipped; reason=no_ac_section; headings={見出し or none}
#   [CONTEXT] ACCEPTANCE_TABLE=ok; rows={n}; unmet={ids}; unverified={ids}
#   [CONTEXT] ACCEPTANCE_FINAL=ok; unmet={ids}; unverified={ids}
#   [CONTEXT] ACCEPTANCE_FINAL=skipped; reason={no_issue|no_ac_section}
#   [CONTEXT] ACCEPTANCE_CHECK_FAILED=1; mode={mode}; reason={reason}[; detail]
#
# Reason SoT:
#   extract: input_missing / no_ac_ids / duplicate_ac_id
#   table:   input_missing / expected_invalid / jq_missing / table_missing / table_malformed /
#            table_empty / id_set_mismatch / status_invalid / evidence_missing /
#            unmet_finding_missing / jq_transform_failed
#   final:   expected_invalid / jq_missing / input_missing / json_invalid / gate_not_applied /
#            acceptance_criteria_missing / acceptance_row_invalid / acceptance_scope_mismatch /
#            id_set_mismatch / unmet_finding_not_blocking / jq_transform_failed
#
# Exit codes:
#   0  検査通過 (skipped を含む)
#   1  検査失敗 (ACCEPTANCE_CHECK_FAILED emit 済み。入力は不変)
#   2  invocation error (subcommand / 引数の欠落・未知)
set -u
# 判定列・見出しの日本語を awk の == と正規表現でバイト単位に比べる。macOS の awk は UTF-8 ロケールで
# 文字列の == をロケール照合で比べ、別の日本語文字列を等しいと判定しうる
export LC_ALL=C

mode="${1:-}"
[ $# -gt 0 ] && shift

body_file=""
expected=""
expected_given=0
input=""

usage() {
  cat <<'EOF'
Usage:
  acceptance-criteria-check.sh extract --body-file PATH
  acceptance-criteria-check.sh table --expected AC-N,AC-M --input PATH
  acceptance-criteria-check.sh final --expected AC-N,AC-M|"" --input PATH
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) body_file="${2:-}"; shift; shift ;;
    --expected) expected="${2:-}"; expected_given=1; shift; shift ;;
    --input) input="${2:-}"; shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

_fail() {
  # $1 = reason, $2 = 人間向け説明, $3 = marker に添える detail (任意)
  echo "ERROR: $2" >&2
  if [ -n "${3:-}" ]; then
    echo "[CONTEXT] ACCEPTANCE_CHECK_FAILED=1; mode=$mode; reason=$1; $3" >&2
  else
    echo "[CONTEXT] ACCEPTANCE_CHECK_FAILED=1; mode=$mode; reason=$1" >&2
  fi
  exit 1
}

# CRLF 本文でも見出し・表を同じく判定する (Issue body は CRLF で届くことがある)
_read_lf() { tr -d '\r' < "$1"; }

_check_expected_format() {
  printf '%s\n' "$expected" | grep -Eq '^AC-[0-9]+(,AC-[0-9]+)*$' \
    || _fail expected_invalid "--expected は AC-N のカンマ区切りで指定してください: $expected"
}

# $1 = 改行区切りの AC-ID (重複を含みうる), $2 = 人間向け説明。--expected との欠落・余分・重複を拒否する
_check_id_set() {
  local got want missing extra dup
  got=$(printf '%s\n' "$1" | sort)
  want=$(printf '%s\n' "$expected" | tr ',' '\n' | sort -u)
  missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got" | sort -u) | paste -sd, -)
  extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got" | sort -u) | paste -sd, -)
  dup=$(printf '%s\n' "$got" | uniq -d | paste -sd, -)
  if [ -n "$missing$extra$dup" ]; then
    _fail id_set_mismatch "$2" "missing=${missing}; extra=${extra}; duplicate=${dup}"
  fi
}

case "$mode" in
  extract)
    [ -n "$body_file" ] || { usage >&2; exit 2; }
    [ -f "$body_file" ] || _fail input_missing "--body-file が存在しません: $body_file"
    # fenced code block 内の見出しは数えない (テンプレート例示の混入を防ぐ)
    parsed=$(_read_lf "$body_file" | awk '
      /^[[:space:]]*```/ { in_fence = !in_fence; next }
      in_fence { next }
      /^## / {
        in_ac = ($0 ~ /^## 5\. Acceptance Criteria[[:space:]]*$/)
        if (in_ac) { found = 1 }
        else if (tolower($0) ~ /acceptance|受入/) { other = other (other == "" ? "" : ",") substr($0, 4) }
        next
      }
      in_ac && match($0, /^### AC-[0-9]+([:[:space:]]|$)/) {
        id = substr($0, 5, RLENGTH - 4); sub(/[:[:space:]]+$/, "", id)
        print "ID " id
      }
      END { print "FOUND " (found ? 1 : 0); print "OTHER " other }
    ')
    found=$(printf '%s\n' "$parsed" | sed -n 's/^FOUND //p')
    if [ "$found" != "1" ]; then
      other=$(printf '%s\n' "$parsed" | sed -n 's/^OTHER //p')
      echo "[CONTEXT] ACCEPTANCE_SCOPE=skipped; reason=no_ac_section; headings=${other:-none}" >&2
      exit 0
    fi
    ids=$(printf '%s\n' "$parsed" | sed -n 's/^ID //p')
    [ -n "$ids" ] || _fail no_ac_ids "## 5. Acceptance Criteria 見出しはあるが ### AC-N が 1 件もありません"
    dup=$(printf '%s\n' "$ids" | sort | uniq -d | paste -sd, -)
    [ -z "$dup" ] || _fail duplicate_ac_id "AC-ID が重複しています: $dup" "ids=$dup"
    joined=$(printf '%s\n' "$ids" | paste -sd, -)
    echo "[CONTEXT] ACCEPTANCE_SCOPE=target; ids=$joined" >&2
    printf '%s\n' "$joined"
    ;;

  table)
    { [ -n "$expected" ] && [ -n "$input" ]; } || { usage >&2; exit 2; }
    [ -f "$input" ] || _fail input_missing "--input が存在しません: $input"
    _check_expected_format
    command -v jq >/dev/null 2>&1 || _fail jq_missing "jq が見つかりません"
    # 表は 3 列、指摘事項は 5 列。指摘事項は 5 列目 (推奨対応) だけが raw pipe を含みうるため、
    # 重要度 / スコープ / 内容は左端からの固定位置で読み、列数は下限だけを見る。
    # LC_ALL=C の [[:space:]] は ASCII 空白だけなので、全角空白 (U+3000) も端から削り、全角空白だけの根拠を空とみなす
    parsed=$(_read_lf "$input" | awk -F'|' -v zs="$(printf '\343\200\200')" '
      function trim(s,   n, z) {
        z = length(zs)
        do {
          n = length(s)
          sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
          if (index(s, zs) == 1) s = substr(s, z + 1)
          if (length(s) >= z && substr(s, length(s) - z + 1) == zs) s = substr(s, 1, length(s) - z)
        } while (length(s) != n)
        return s
      }
      /^### / {
        sec = ($0 ~ /^### 受入条件確認[[:space:]]*$/) ? "ac" : ($0 ~ /^### 指摘事項[[:space:]]*$/) ? "fd" : ""
        if (sec == "ac") { seen_ac = 1 }
        hdr = 0; next
      }
      /^## / { sec = ""; next }
      sec == "" || $0 !~ /^[[:space:]]*\|/ { next }
      {
        hdr++
        if (hdr <= 2) next   # ヘッダ行と区切り行
        if (sec == "ac") {
          if (NF != 5) { print "MALFORMED"; next }
          print "ROW\t" trim($2) "\t" trim($3) "\t" trim($4)
        } else if (NF >= 7) {
          c = trim($5)
          if (match(c, /^\[AC-[0-9]+\]/)) print "FD\t" substr(c, 2, RLENGTH - 2) "\t" trim($2) "\t" trim($3)
        }
      }
      END { print "SEEN\t" (seen_ac ? 1 : 0) }
    ')
    [ "$(printf '%s\n' "$parsed" | awk -F'\t' '$1 == "SEEN" { print $2 }')" = "1" ] \
      || _fail table_missing "### 受入条件確認 見出しがありません"
    ! printf '%s\n' "$parsed" | grep -q '^MALFORMED$' \
      || _fail table_malformed "### 受入条件確認 表に 3 列でない行があります"
    rows=$(printf '%s\n' "$parsed" | grep '^ROW' || true)
    [ -n "$rows" ] || _fail table_empty "### 受入条件確認 表に判定行がありません"
    bad_id=$(printf '%s\n' "$rows" | awk -F'\t' '$2 !~ /^AC-[0-9]+$/ { print $2 }' | head -1)
    [ -z "$bad_id" ] || _fail table_malformed "AC 列が AC-N 形式ではありません: $bad_id"
    _check_id_set "$(printf '%s\n' "$rows" | cut -f2)" "判定表の AC-ID 集合が Issue と一致しません"
    bad_status=$(printf '%s\n' "$rows" | awk -F'\t' '$3 != "充足" && $3 != "未充足" && $3 != "未検証" { print $2 }' | head -1)
    [ -z "$bad_status" ] || _fail status_invalid "判定が 充足 / 未充足 / 未検証 のいずれでもありません: $bad_status" "ac=$bad_status"
    no_evidence=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "" { print $2 }' | paste -sd, -)
    [ -z "$no_evidence" ] || _fail evidence_missing "根拠が空の行があります: $no_evidence" "ac=$no_evidence"
    # 未充足行ごとに `[AC-N]` で始まる CRITICAL / current-pr の指摘が必要
    unmet=$(printf '%s\n' "$rows" | awk -F'\t' '$3 == "未充足" { print $2 }')
    for ac in $unmet; do
      printf '%s\n' "$parsed" | awk -F'\t' -v ac="$ac" '$1 == "FD" && $2 == ac && $3 == "CRITICAL" && $4 == "current-pr" { ok = 1 } END { exit !ok }' \
        || _fail unmet_finding_missing "未充足の $ac に対応する [${ac}] で始まる CRITICAL / current-pr の指摘がありません" "ac=$ac"
    done
    if ! rows_json=$(printf '%s\n' "$rows" | jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t"))
      | map({id: .[1],
             status: ({"充足": "satisfied", "未充足": "unmet", "未検証": "unverified"}[.[2]]),
             evidence: .[3]})'); then
      _fail jq_transform_failed "判定行を JSON に変換できません"
    fi
    printf '%s\n' "$rows_json"
    unverified=$(printf '%s\n' "$rows" | awk -F'\t' '$3 == "未検証" { print $2 }' | paste -sd, -)
    echo "[CONTEXT] ACCEPTANCE_TABLE=ok; rows=$(printf '%s\n' "$rows" | wc -l | tr -d ' '); unmet=$(printf '%s\n' "$unmet" | paste -sd, -); unverified=$unverified" >&2
    ;;

  final)
    # --expected は Issue 側の AC 集合 (1.3.1 の抽出結果)。結果 JSON は LLM が書き写すため、集合も対象判定も
    # JSON 自身ではなくこの値と突き合わせる。空文字列は対象外 cycle を表す
    { [ -n "$input" ] && [ "$expected_given" = 1 ]; } || { usage >&2; exit 2; }
    [ -z "$expected" ] || _check_expected_format
    command -v jq >/dev/null 2>&1 || _fail jq_missing "jq が見つかりません"
    [ -f "$input" ] || _fail input_missing "--input が存在しません: $input"
    jq -e 'type == "object"' "$input" >/dev/null 2>&1 || _fail json_invalid "JSON オブジェクトとして parse できません: $input"
    # 降格ゲート適用前の JSON では、降格された未充足 finding がまだ findings[] に残って見える
    jq -e '(.measured_gate | type) == "object"' "$input" >/dev/null \
      || _fail gate_not_applied "measured_gate がありません (5.3.0.M step 2 の適用後に実行する): $input"
    jq -e 'has("acceptance_criteria")' "$input" >/dev/null \
      || _fail acceptance_criteria_missing "acceptance_criteria キーがありません (5.3.0.M step 1 は常に書く)"
    jq -e '(.reviewers | type) == "array"' "$input" >/dev/null \
      || _fail json_invalid "reviewers が配列ではありません: $input"
    # jq の失敗は空文字列になり「違反なし」と区別できないため、置換ごとに終了コードを見る
    if ! skipped=$(jq -r '.acceptance_criteria | if type == "object" then (.skipped // "" | tostring) else "" end' "$input") \
      || ! ar_named=$(jq -r 'any(.reviewers[]; . == "acceptance-reviewer")' "$input") \
      || ! ar_found=$(jq -r 'any((.findings[]?, .non_blocking_findings[]?); type == "object" and .reviewer == "acceptance-reviewer")' "$input"); then
      _fail jq_transform_failed "acceptance_criteria / reviewers を読めません: $input"
    fi
    if [ -n "$skipped" ]; then
      case "$skipped" in
        no_issue|no_ac_section) ;;
        *) _fail acceptance_row_invalid "skipped の値が不正です: $skipped" ;;
      esac
      [ -z "$expected" ] || _fail acceptance_scope_mismatch "Issue に受入条件があるのに acceptance_criteria が skipped です" "skipped=$skipped; expected=$expected"
      if [ "$ar_named" = true ] || [ "$ar_found" = true ]; then
        _fail acceptance_scope_mismatch "acceptance_criteria が skipped なのに acceptance-reviewer が reviewers[] / 指摘にいます" "skipped=$skipped; reviewers=$ar_named; findings=$ar_found"
      fi
      echo "[CONTEXT] ACCEPTANCE_FINAL=skipped; reason=$skipped" >&2
      exit 0
    fi
    if ! invalid=$(jq -r '
      .acceptance_criteria as $ac
      | if ($ac | type) != "array" or ($ac | length) == 0 then "acceptance_criteria"
        else [$ac[] | select(
          (type != "object")
          or ((.id | type) != "string") or ((.id | test("^AC-[0-9]+$")) | not)
          or ((.status | type) != "string") or ((.status | IN("satisfied", "unmet", "unverified")) | not)
          or ((.evidence | type) != "string")
          or (if .status == "unmet" then ((.finding_id | type) != "string") else (.finding_id != null) end)
        ) | if type == "object" and (.id | type) == "string" then .id else "?" end] | join(",") end' "$input"); then
      _fail jq_transform_failed "acceptance_criteria の行を検査できません: $input"
    fi
    [ -z "$invalid" ] || _fail acceptance_row_invalid "acceptance_criteria の行が契約を満たしません: $invalid" "ac=$invalid"
    [ -n "$expected" ] || _fail acceptance_scope_mismatch "対象外の cycle なのに acceptance_criteria が判定行です" "expected="
    [ "$ar_named" = true ] || _fail acceptance_scope_mismatch "acceptance_criteria が判定行なのに reviewers[] に acceptance-reviewer がいません" "reviewers=false"
    if ! row_ids=$(jq -r '.acceptance_criteria[].id' "$input"); then
      _fail jq_transform_failed "判定行の ID を読めません: $input"
    fi
    _check_id_set "$row_ids" "acceptance_criteria の AC-ID 集合が Issue と一致しません"
    # 未充足行の finding は blocking 集合 (findings[] の current-pr) に、acceptance reviewer の [AC-N] 付きで残る
    if ! lost=$(jq -r '
      . as $doc
      | [.acceptance_criteria[] | select(.status == "unmet") | . as $row
         | select(([$doc.findings[]? | select(type == "object"
             and .id == $row.finding_id
             and .reviewer == "acceptance-reviewer"
             and .scope == "current-pr"
             and ((.description | type) == "string")
             and (.description | startswith("[" + $row.id + "]")))] | length) == 0)
         | "\($row.id):\($row.finding_id)"] | join(",")' "$input"); then
      _fail jq_transform_failed "未充足行の finding を検査できません: $input"
    fi
    [ -z "$lost" ] || _fail unmet_finding_not_blocking "未充足行の finding が最終 blocking 集合にありません: $lost" "lost=$lost"
    if ! unmet=$(jq -r '[.acceptance_criteria[] | select(.status == "unmet") | .id] | join(",")' "$input") \
      || ! unverified=$(jq -r '[.acceptance_criteria[] | select(.status == "unverified") | .id] | join(",")' "$input"); then
      _fail jq_transform_failed "判定行の ID を集計できません: $input"
    fi
    echo "[CONTEXT] ACCEPTANCE_FINAL=ok; unmet=$unmet; unverified=$unverified" >&2
    ;;

  -h|--help) usage; exit 0 ;;
  *) echo "ERROR: subcommand は extract / table / final のいずれかです: '${mode}'" >&2; usage >&2; exit 2 ;;
esac
