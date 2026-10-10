#!/bin/bash
# gh stand-in holding one Issue work memory comment in a file, for tests that
# reach review-close. Install it as `gh` on PATH and point it at its files:
#   RITE_TEST_WM_BODY     the comment body (absent = the Issue has no work memory)
#   RITE_TEST_WM_LOG      every call is appended here
#   RITE_TEST_BASE_REF    baseRefName that `pr view` prints (unset = `pr view` fails, empty = prints nothing)
#   RITE_TEST_WM_FAIL     when this file exists, the named call fails:
#                         "list" (comment list), "patch", or "refetch" (every
#                         read after a successful PATCH; the mark sits next to
#                         this file so parallel fixtures do not share it)
[ -n "${RITE_TEST_WM_LOG:-}" ] && printf '%s\n' "$*" >> "$RITE_TEST_WM_LOG"
fail=$(cat "${RITE_TEST_WM_FAIL:-/nonexistent}" 2>/dev/null) || fail=""
patched="${RITE_TEST_WM_FAIL:-/nonexistent}.patched"
if [ "$fail" = refetch ] && [ -f "$patched" ]; then
  case "$*" in
    *"issues/comments/1 -X PATCH"*) ;;
    # the helper's own post-PATCH verification read (no --jq) is not the read under test
    *issues/*comments*--jq*) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
    *issues/comments/1) ;;
    *issues/*comments*) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
  esac
fi
case "$*" in
  "repo view"*) echo testowner/testrepo ;;
  "pr view"*)
    # RITE_TEST_BASE_REF: the PR's baseRefName. Unset = gh fails; set empty = gh prints an empty name
    [ -n "${RITE_TEST_BASE_REF+set}" ] || { echo "gh: no pull request (RITE_TEST_BASE_REF unset)" >&2; exit 1; }
    printf '%s\n' "$RITE_TEST_BASE_REF" ;;
  *issues/[0-9]*/comments*)
    [ "$fail" = list ] && { echo "HTTP 500: Internal Server Error" >&2; exit 1; }
    [ -f "$RITE_TEST_WM_BODY" ] || exit 0
    jq -n --rawfile b "$RITE_TEST_WM_BODY" '{id: 1, body: $b}' ;;
  *"issues/comments/1 -X PATCH"*)
    [ "$fail" = patch ] && { echo "HTTP 422: Validation Failed" >&2; exit 1; }
    # the helper sends the body as `-F body=@file`; the response is the updated comment
    for a in "$@"; do
      case "$a" in body=@*) cp "${a#body=@}" "$RITE_TEST_WM_BODY.new" && mv "$RITE_TEST_WM_BODY.new" "$RITE_TEST_WM_BODY" || exit 1 ;; esac
    done
    if [ "$fail" = refetch ]; then : > "$patched"; fi
    echo '{"id": 1}' ;;
  *--jq*issues/comments/1*|*issues/comments/1*--jq*) [ -f "$RITE_TEST_WM_BODY" ] && cat "$RITE_TEST_WM_BODY" ;;
  *issues/comments/1*) [ -f "$RITE_TEST_WM_BODY" ] && jq -n --rawfile b "$RITE_TEST_WM_BODY" '{id: 1, body: $b}' ;;
  *) exit 1 ;;
esac
