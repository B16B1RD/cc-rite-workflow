#!/usr/bin/env bash
# Markdown helper for the 却下台帳 section on the 6.1.d record comment.
#
# The section lives between the pointer table (or variant-B intro) and the
# `📎 non_blocking_count:` line. First-line marker and last-line sentinel of
# the parent comment are never rewritten here.
#
# Usage:
#   bash nb-sweep-ledger.sh extract --body-file <path>
#   bash nb-sweep-ledger.sh append --ledger-file <path> --entries-file <path>
#   bash nb-sweep-ledger.sh merge-into --body-file <path> --ledger-file <path>
#   bash nb-sweep-ledger.sh tally --entries-file <path> [--record <basename>]
#
# extract  stdout: the ### 却下台帳 section (empty if absent). exit 0 when
#          the body is readable even if no ledger exists.
# append   appends table rows to a ledger file (creates header if missing).
#          Every appended row must end with a 出典 cell holding the basename of
#          the review JSON the sweep read ({pr}-{14 digits}[~{4 hex}].json);
#          otherwise nothing is appended (reason=entries_source_invalid).
#          An existing 4-column header and its separator are upgraded to the
#          5-column form; existing 4-column rows are kept as they are.
# merge-into  splices --ledger-file into --body-file immediately before
#          `📎 non_blocking_count:`. Replaces an existing ### 却下台帳.
#          Empty ledger-file is a no-op (does not insert a heading).
# tally    stdout: `issued=K; recorded=M` counted from the 判定 cell of the
#          entries rows (escaped pipes inside a cell do not shift columns).
#          With --record, every row's 出典 cell must equal that basename;
#          otherwise nothing is printed (reason=entries_record_mismatch).
#          Entries are what an interrupted sweep already filed, so a leftover
#          from another review JSON must stop the sweep instead of standing in
#          for this sweep's filing.
#
# extract の出力は節末尾の空行を含まない。merge-into は台帳の前後を空行 1 行ずつに揃える。
# このため同じ本文に extract → merge-into を繰り返しても本文は変わらず、空行も増えない。
#
# Heading / section-boundary matching ignores a trailing CR and uses index()
# prefix matches (macOS awk compares `==` by locale collation and treats a
# different Japanese heading as equal). extract output and a spliced
# merge-into body are LF; the empty-ledger no-op leaves the body untouched.
# review-nonblocking-record.sh counts ledger rows with the same predicates.
#
# Exit:
#   0  success (including extract-with-no-section / merge no-op)
#   1  missing file / malformed body / write failure (fail-loud)
#   2  argument error
set -euo pipefail

cmd=""
body_file=""
ledger_file=""
entries_file=""
record_base=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    extract|append|merge-into|tally)
      [ -z "$cmd" ] || { echo "ERROR: multiple subcommands" >&2; exit 2; }
      cmd=$1; shift ;;
    --body-file) body_file=${2:-}; shift 2 ;;
    --ledger-file) ledger_file=${2:-}; shift 2 ;;
    --entries-file) entries_file=${2:-}; shift 2 ;;
    --record) record_base=${2:-}; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$cmd" ] || { echo "ERROR: subcommand required (extract|append|merge-into|tally)" >&2; exit 2; }

MARKER='## 📜 rite 非実測指摘の記録'
LEDGER_HEAD='### 却下台帳'
COUNT_LINE='📎 non_blocking_count:'

ledger_header() {
  printf '%s\n\n' "$LEDGER_HEAD"
  printf '%s\n' '| finding_id | file:line | 判定 | 判定文 | 出典 |'
  printf '%s\n' '|------------|-----------|------|--------|------|'
}

extract_section() {
  local src=$1
  awk -v head="$LEDGER_HEAD" '
    { sub(/\r$/, ""); is_head = (index($0, head) == 1 && length($0) == length(head)) }
    is_head { in_sec=1 }
    in_sec {
      if (index($0, "📎 non_blocking_count:") == 1) { exit }
      if (index($0, "### ") == 1 && !is_head) { exit }
      # 空行は次の非空行を出すときにまとめて出す。節末尾の空行は出力に含めない
      if ($0 ~ /^[ \t]*$/) { pend = pend $0 "\n"; next }
      printf "%s", pend; pend = ""
      print
    }
  ' "$src"
}

case "$cmd" in
  extract)
    [ -n "$body_file" ] || { echo "ERROR: --body-file is required" >&2; exit 2; }
    if [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; then
      echo "ERROR: body file unreadable: $body_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=extract; reason=body_unreadable" >&2
      exit 1
    fi
    if [ ! -s "$body_file" ]; then
      echo "ERROR: body file empty: $body_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=extract; reason=body_empty" >&2
      exit 1
    fi
    extract_section "$body_file"
    echo "[CONTEXT] NB_SWEEP_LEDGER=ok; op=extract" >&2
    ;;

  append)
    [ -n "$ledger_file" ] || { echo "ERROR: --ledger-file is required" >&2; exit 2; }
    [ -n "$entries_file" ] || { echo "ERROR: --entries-file is required" >&2; exit 2; }
    if [ ! -f "$entries_file" ] || [ ! -s "$entries_file" ]; then
      echo "ERROR: entries file missing or empty: $entries_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=append; reason=entries_missing" >&2
      exit 1
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/rite-nb-ledger-XXXXXX") || {
      echo "ERROR: mktemp failed" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=append; reason=mktemp_failed" >&2
      exit 1
    }
    rows=""
    cleanup() { rm -f -- "$tmp" "$rows"; }
    trap cleanup EXIT HUP INT TERM
    rows=$(mktemp "${TMPDIR:-/tmp}/rite-nb-rows-XXXXXX") || {
      echo "ERROR: mktemp failed" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=append; reason=mktemp_failed" >&2
      exit 1
    }
    # drop header-only lines from entries (caller may paste a full table)
    grep -E '^\| ' "$entries_file" | grep -Ev '^\|[-: |]+\|$' | grep -Ev '^\| finding_id ' > "$rows" || true
    # cleanup の follow-up 起票は出典セルで起票済みの指摘を同定する。出典を欠いた行を書くと、
    # その行は最新 JSON とだけ照合される旧形式に黙って戻るため、1 行でも欠ければ何も書かない。
    if bad=$(grep -Ev '^\|.*\|.*\|.*\|.*\|[[:space:]]*[0-9]+-[0-9]{14}(~[0-9a-f]{4})?\.json[[:space:]]*\|[[:space:]]*$' "$rows"); then
      echo "ERROR: entries row lacks a 出典 cell (review JSON basename) as its last column:" >&2
      # shellcheck source=../control-char-neutralize.sh
      source "$(dirname "${BASH_SOURCE[0]}")/../control-char-neutralize.sh"
      # 途中で読むのをやめる head は、不正行がパイプバッファを超えると printf を SIGPIPE で落とし、
      # pipefail で直後の reason 行を出さずに終わる。入力を最後まで読む sed で先頭 3 行だけを出す
      printf '%s\n' "$bad" | sed -n '1,3p' | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=append; reason=entries_source_invalid" >&2
      exit 1
    fi
    if [ ! -f "$ledger_file" ] || [ ! -s "$ledger_file" ]; then
      ledger_header > "$tmp"
    else
      # 4 列の列ヘッダと直後の区切り行だけを 5 列へ置き換える。既存の 4 列行は書き換えない
      awk '
        { line = $0; sub(/\r$/, "", line) }
        index(line, "| finding_id ") == 1 && split(line, c, "|") == 6 {
          print "| finding_id | file:line | 判定 | 判定文 | 出典 |"; upgraded = 1; next
        }
        upgraded == 1 && line ~ /^[|][-: |]+[|]$/ && split(line, c, "|") == 6 {
          print "|------------|-----------|------|--------|------|"; upgraded = 0; next
        }
        { upgraded = 0; print }
      ' "$ledger_file" > "$tmp"
      # ensure trailing newline before appending rows
      [ -n "$(tail -c 1 "$tmp" 2>/dev/null)" ] && printf '\n' >> "$tmp"
    fi
    cat "$rows" >> "$tmp"
    if ! mv -- "$tmp" "$ledger_file"; then
      echo "ERROR: ledger write failed: $ledger_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=append; reason=write_failed" >&2
      exit 1
    fi
    tmp=""
    rm -f -- "$rows"
    trap - EXIT HUP INT TERM
    echo "[CONTEXT] NB_SWEEP_LEDGER=ok; op=append" >&2
    ;;

  merge-into)
    [ -n "$body_file" ] || { echo "ERROR: --body-file is required" >&2; exit 2; }
    [ -n "$ledger_file" ] || { echo "ERROR: --ledger-file is required" >&2; exit 2; }
    if [ ! -f "$body_file" ] || [ ! -s "$body_file" ]; then
      echo "ERROR: body file missing or empty: $body_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=merge-into; reason=body_empty" >&2
      exit 1
    fi
    first=$(head -n 1 "$body_file")
    case "$first" in
      "$MARKER"*) ;;
      *)
        echo "ERROR: body first line is not the 6.1.d marker" >&2
        echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=merge-into; reason=body_marker_missing" >&2
        exit 1
        ;;
    esac
    if ! grep -qE "^${COUNT_LINE}" "$body_file"; then
      echo "ERROR: body missing ${COUNT_LINE} line" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=merge-into; reason=count_line_missing" >&2
      exit 1
    fi
    if [ ! -s "$ledger_file" ]; then
      echo "[CONTEXT] NB_SWEEP_LEDGER=ok; op=merge-into; action=noop" >&2
      exit 0
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/rite-nb-merge-XXXXXX") || {
      echo "ERROR: mktemp failed" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=merge-into; reason=mktemp_failed" >&2
      exit 1
    }
    cleanup() { rm -f -- "$tmp"; }
    trap cleanup EXIT HUP INT TERM
    # Drop any existing ledger section, then insert the provided ledger
    # immediately before the count line.
    awk -v head="$LEDGER_HEAD" -v count="📎 non_blocking_count:" -v ledger_file="$ledger_file" '
      { sub(/\r$/, ""); is_head = (index($0, head) == 1 && length($0) == length(head)); is_count = (index($0, count) == 1) }
      is_head { skip=1; next }
      skip {
        if (is_count || index($0, "### ") == 1) { skip=0 }
        else next
      }
      is_count {
        # count 行の直前の空行は捨て、空行 1 行 + 台帳 (前後の空行を除く) + 空行 1 行に揃える
        pend = ""
        if (ledger_file != "") {
          print ""
          lpend = ""; started = 0
          while ((getline line < ledger_file) > 0) {
            sub(/\r$/, "", line)
            if (line ~ /^[ \t]*$/) { if (started) lpend = lpend line "\n"; continue }
            printf "%s", lpend; lpend = ""
            print line; started = 1
          }
          close(ledger_file)
          print ""
        }
      }
      # 空行は次の非空行を出すときにまとめて出す (count 行の直前では上で捨てる)
      $0 ~ /^[ \t]*$/ { pend = pend $0 "\n"; next }
      { printf "%s", pend; pend = ""; print }
      END { printf "%s", pend }
    ' "$body_file" > "$tmp"
    if [ ! -s "$tmp" ]; then
      echo "ERROR: merge-into produced empty body" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=merge-into; reason=merge_empty" >&2
      exit 1
    fi
    if ! grep -qE "^${COUNT_LINE}" "$tmp"; then
      echo "ERROR: merge-into dropped ${COUNT_LINE}" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=merge-into; reason=count_line_dropped" >&2
      exit 1
    fi
    if ! mv -- "$tmp" "$body_file"; then
      echo "ERROR: body write failed: $body_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=merge-into; reason=write_failed" >&2
      exit 1
    fi
    tmp=""
    trap - EXIT HUP INT TERM
    echo "[CONTEXT] NB_SWEEP_LEDGER=ok; op=merge-into; action=spliced" >&2
    ;;
  tally)
    [ -n "$entries_file" ] || { echo "ERROR: --entries-file is required" >&2; exit 2; }
    if [ ! -f "$entries_file" ] || [ ! -r "$entries_file" ]; then
      echo "ERROR: entries file unreadable: $entries_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=tally; reason=entries_missing" >&2
      exit 1
    fi
    # append と同じ行だけを数える。セル内のエスケープ済みパイプは区切りにしない
    if ! counts=$({ grep -E '^\| ' "$entries_file" || true; } | { grep -Ev '^\|[-: |]+\|$' || true; } \
      | { grep -Ev '^\| finding_id ' || true; } \
      | awk -v want="$record_base" '
          { line = $0; sub(/\r$/, "", line); gsub(/\\\|/, "", line); n = split(line, c, "|")
            route = c[4]; gsub(/^[ \t]+|[ \t]+$/, "", route)
            src = c[n - 1]; gsub(/^[ \t]+|[ \t]+$/, "", src)
            if (want != "" && src != want) bad = 1
            if (route == "issued") issued++
            else if (route == "recorded") recorded++ }
          END { if (bad) exit 3; printf "issued=%d; recorded=%d\n", issued, recorded }'); then
      echo "ERROR: entries rows do not all name the review JSON this sweep read (${record_base}): $entries_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=tally; reason=entries_record_mismatch" >&2
      exit 1
    fi
    printf '%s\n' "$counts"
    echo "[CONTEXT] NB_SWEEP_LEDGER=ok; op=tally" >&2
    ;;
esac
