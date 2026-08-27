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
#
# extract  stdout: the ### 却下台帳 section (empty if absent). exit 0 when
#          the body is readable even if no ledger exists.
# append   appends table rows to a ledger file (creates header if missing).
# merge-into  splices --ledger-file into --body-file immediately before
#          `📎 non_blocking_count:`. Replaces an existing ### 却下台帳.
#          Empty ledger-file is a no-op (does not insert a heading).
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    extract|append|merge-into)
      [ -z "$cmd" ] || { echo "ERROR: multiple subcommands" >&2; exit 2; }
      cmd=$1; shift ;;
    --body-file) body_file=${2:-}; shift 2 ;;
    --ledger-file) ledger_file=${2:-}; shift 2 ;;
    --entries-file) entries_file=${2:-}; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$cmd" ] || { echo "ERROR: subcommand required (extract|append|merge-into)" >&2; exit 2; }

MARKER='## 📜 rite 非実測指摘の記録'
LEDGER_HEAD='### 却下台帳'
COUNT_LINE='📎 non_blocking_count:'

ledger_header() {
  printf '%s\n\n' "$LEDGER_HEAD"
  printf '%s\n' '| finding_id | file:line | 判定 | 判定文 |'
  printf '%s\n' '|------------|-----------|------|--------|'
}

extract_section() {
  local src=$1
  awk -v head="$LEDGER_HEAD" '
    $0 == head { in_sec=1 }
    in_sec {
      if ($0 ~ /^📎 non_blocking_count:/) { exit }
      if (in_sec && /^### / && $0 != head) { exit }
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
    cleanup() { rm -f -- "$tmp"; }
    trap cleanup EXIT HUP INT TERM
    if [ ! -f "$ledger_file" ] || [ ! -s "$ledger_file" ]; then
      ledger_header > "$tmp"
    else
      cat "$ledger_file" > "$tmp"
      # ensure trailing newline before appending rows
      [ -n "$(tail -c 1 "$tmp" 2>/dev/null)" ] && printf '\n' >> "$tmp"
    fi
    # drop header-only lines from entries (caller may paste a full table)
    grep -E '^\| ' "$entries_file" | grep -Ev '^\|[-: |]+\|$' | grep -Ev '^\| finding_id ' >> "$tmp" || true
    if ! mv -- "$tmp" "$ledger_file"; then
      echo "ERROR: ledger write failed: $ledger_file" >&2
      echo "[CONTEXT] NB_SWEEP_LEDGER=failed; op=append; reason=write_failed" >&2
      exit 1
    fi
    tmp=""
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
    awk -v head="$LEDGER_HEAD" -v count="^📎 non_blocking_count:" -v ledger_file="$ledger_file" '
      $0 == head { skip=1; next }
      skip {
        if ($0 ~ count) { skip=0 }
        else if (/^### / && $0 != head) { skip=0 }
        else next
      }
      $0 ~ count {
        if (ledger_file != "") {
          while ((getline line < ledger_file) > 0) print line
          close(ledger_file)
          print ""
        }
      }
      { print }
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
esac
