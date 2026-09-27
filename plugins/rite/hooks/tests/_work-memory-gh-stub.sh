#!/bin/bash
# gh stand-in holding one Issue work memory comment in a file, for tests that
# reach review-close. Install it as `gh` on PATH and point it at its files:
#   RITE_TEST_WM_BODY     the comment body (absent = the Issue has no work memory)
#   RITE_TEST_WM_LOG      every call is appended here
#   RITE_TEST_WM_FAIL     when this file exists, the named call fails:
#                         "list" (comment list) or "patch"
[ -n "${RITE_TEST_WM_LOG:-}" ] && printf '%s\n' "$*" >> "$RITE_TEST_WM_LOG"
fail=$(cat "${RITE_TEST_WM_FAIL:-/nonexistent}" 2>/dev/null) || fail=""
case "$*" in
  "repo view"*) echo testowner/testrepo ;;
  *issues/[0-9]*/comments*)
    [ "$fail" = list ] && { echo "HTTP 500: Internal Server Error" >&2; exit 1; }
    [ -f "$RITE_TEST_WM_BODY" ] || exit 0
    jq -n --rawfile b "$RITE_TEST_WM_BODY" '{id: 1, body: $b}' ;;
  *"issues/comments/1 -X PATCH"*)
    [ "$fail" = patch ] && { echo "HTTP 422: Validation Failed" >&2; exit 1; }
    jq -r .body > "$RITE_TEST_WM_BODY.new" && mv "$RITE_TEST_WM_BODY.new" "$RITE_TEST_WM_BODY" ;;
  *issues/comments/1*) [ -f "$RITE_TEST_WM_BODY" ] && cat "$RITE_TEST_WM_BODY" ;;
  *) exit 1 ;;
esac
