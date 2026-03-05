#!/bin/bash
# rite workflow - Issue Body Safe Update
# Deterministic script for the fetch/validate and validate/apply steps
# of the 3-step safe Issue body update pattern.
#
# The 3-step pattern:
#   Step 1 (fetch):  issue-body-safe-update.sh fetch --issue <number>
#   Step 2 (edit):   Claude reads tmpfile_read, writes updated body to tmpfile_write
#   Step 3 (apply):  issue-body-safe-update.sh apply --issue <number> \
#                      --tmpfile-read <path> --tmpfile-write <path> --original-length <n>
#
# Fetch mode outputs:
#   tmpfile_read=<path>
#   tmpfile_write=<path>
#   original_length=<n>
#
# Apply mode validates and applies the update:
#   - Rejects empty write file
#   - Rejects body shrinkage below 50% of original (body loss prevention)
#   - Uses --body-file for safe gh issue edit
#
# Options:
#   --issue           Issue number (required)
#   --tmpfile-read    Path to temp file with original body (apply mode)
#   --tmpfile-write   Path to temp file with updated body (apply mode)
#   --original-length Original body length in bytes (apply mode)
#   --parent          Use this flag to indicate parent Issue update (changes error to WARNING)
#   --diff-check      Verify a change was actually made (skip apply if identical)
#
# Exit codes:
#   0: Success or skip (non-blocking)
#   1: Argument error
set -euo pipefail

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

ISSUE=""
TMPFILE_READ=""
TMPFILE_WRITE=""
ORIGINAL_LENGTH=""
IS_PARENT=false
DIFF_CHECK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)           ISSUE="$2"; shift 2 ;;
    --tmpfile-read)    TMPFILE_READ="$2"; shift 2 ;;
    --tmpfile-write)   TMPFILE_WRITE="$2"; shift 2 ;;
    --original-length) ORIGINAL_LENGTH="$2"; shift 2 ;;
    --parent)          IS_PARENT=true; shift ;;
    --diff-check)      DIFF_CHECK=true; shift ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$ISSUE" ]]; then
  echo "ERROR: --issue is required" >&2
  exit 1
fi

err_level="WARNING"
if [[ "$IS_PARENT" == false ]]; then
  err_level="WARNING"
fi

case "$MODE" in
  fetch)
    tmpfile_read=$(mktemp)
    tmpfile_write=$(mktemp)
    trap 'rm -f "$tmpfile_read" "$tmpfile_write"' EXIT

    gh issue view "$ISSUE" --json body --jq '.body' > "$tmpfile_read"

    if [ ! -s "$tmpfile_read" ]; then
      echo "${err_level}: Issue body の取得に失敗。更新をスキップします" >&2
      exit 0
    fi

    original_length=$(wc -c < "$tmpfile_read")
    echo "original_length=$original_length"
    echo "tmpfile_read=$tmpfile_read"
    echo "tmpfile_write=$tmpfile_write"

    # Disable trap so files persist for Step 2/3
    trap - EXIT
    ;;

  apply)
    if [[ -z "$TMPFILE_READ" || -z "$TMPFILE_WRITE" || -z "$ORIGINAL_LENGTH" ]]; then
      echo "ERROR: apply mode requires --tmpfile-read, --tmpfile-write, --original-length" >&2
      exit 1
    fi

    if [ ! -s "$TMPFILE_WRITE" ]; then
      echo "${err_level}: 更新内容が空。更新をスキップします" >&2
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    # Body length comparison safety check
    updated_length=$(wc -c < "$TMPFILE_WRITE")
    if [[ "${updated_length:-0}" -lt $(( ${ORIGINAL_LENGTH:-1} / 2 )) ]]; then
      echo "${err_level}: 更新後の body が元の50%未満 (${updated_length}/${ORIGINAL_LENGTH})。body 消失の可能性があるためスキップします" >&2
      rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
      exit 0
    fi

    # Diff check (optional, for idempotent updates like checkbox toggle)
    if [[ "$DIFF_CHECK" == true ]]; then
      if diff -q "$TMPFILE_READ" "$TMPFILE_WRITE" > /dev/null 2>&1; then
        echo "INFO: 変更なし（既に更新済み）"
        rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
        exit 0
      fi
    fi

    gh issue edit "$ISSUE" --body-file "$TMPFILE_WRITE"

    rm -f "$TMPFILE_READ" "$TMPFILE_WRITE"
    ;;

  *)
    echo "ERROR: Unknown mode: $MODE (expected: fetch, apply)" >&2
    exit 1
    ;;
esac
