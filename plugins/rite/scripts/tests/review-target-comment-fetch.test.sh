#!/usr/bin/env bash
# Behavioral checks for the extracted comment fetch/validation/handoff path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../review-target-comment-fetch.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/run"
export TMPDIR="$fixture/run"
export GH_RESPONSE_FILE="$fixture/response.json"
export GH_CALL_LOG="$fixture/gh-call"
export GH_STATUS=0
cat > "$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$GH_CALL_LOG"
if [ "${GH_STATUS:-0}" -ne 0 ]; then
  echo 'mock API failure' >&2
  exit "$GH_STATUS"
fi
cat "$GH_RESPONSE_FILE"
STUB
chmod +x "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"

PASS=0
FAIL=0
check() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}
run() {
  rm -f "$TMPDIR"/* "$GH_CALL_LOG"
  rc=0
  bash "$TARGET" --owner-repo example/project --pr 42 --comment-id 7 "$@" \
    > "$fixture/out" 2> "$fixture/err" || rc=$?
}
no_handoff() {
  [ ! -e "$TMPDIR/rite-fix-target-body-42-7.txt" ] &&
    [ ! -e "$TMPDIR/rite-fix-target-author-42-7.txt" ] &&
    [ ! -e "$TMPDIR/rite-fix-target-author-skip-42-7.txt" ]
}
no_intermediates() {
  local files
  shopt -s nullglob
  files=("$TMPDIR"/rite-fix-intermediate-* "$TMPDIR"/rite-fix-raw-*)
  [ "${#files[@]}" -eq 0 ]
}
response() {
  jq -n --arg body "$1" --arg author "$2" --arg url "$3" \
    '{body:$body,user:{login:$author},issue_url:$url}' > "$GH_RESPONSE_FILE"
}

body=$'Review body with literal `code`, $(text), and a second line\nsecond line'
response "$body" reviewer 'https://api.github.com/repos/example/project/issues/42'
run
check 'successful handoff' test "$rc" -eq 0
check 'API selector is unchanged' grep -qxF 'api repos/example/project/issues/comments/7' "$GH_CALL_LOG"
check 'body preserved verbatim' test "$(cat "$TMPDIR/rite-fix-target-body-42-7.txt")" = "$body"
check 'author preserved' grep -qxF reviewer "$TMPDIR/rite-fix-target-author-42-7.txt"
check 'author mention enabled' grep -qxF false "$TMPDIR/rite-fix-target-author-skip-42-7.txt"
check 'handoff paths emitted' grep -qF "body_file=$TMPDIR/rite-fix-target-body-42-7.txt" "$fixture/err"
check 'phase order retained' test "$(sed -n 's/.*BLOCK_\([ABC]\)_COMPLETE=.*/\1/p' "$fixture/err" | tr -d '\n')" = ABC
check 'success cleans intermediates' no_intermediates
check 'success keeps stdout empty' test ! -s "$fixture/out"

response body '' 'https://api.github.com/repos/example/project/pull/42'
run
check 'deleted author is accepted' test "$rc" -eq 0
check 'deleted author suppresses mention' grep -qxF true "$TMPDIR/rite-fix-target-author-skip-42-7.txt"
check 'deleted author handoff remains empty' test ! -s "$TMPDIR/rite-fix-target-author-42-7.txt"

response body reviewer 'https://api.github.com/repos/example/project/issues/43'
run
check 'different PR is rejected' test "$rc" -eq 1
check 'different PR reason retained' grep -qF 'reason=pr_number_mismatch' "$fixture/err"
check 'different PR never reaches phase C' test "$(grep -c 'BLOCK_C_COMPLETE' "$fixture/err" || true)" -eq 0
check 'different PR cleans upstream and handoff' no_intermediates
check 'different PR leaves no handoff' no_handoff

GH_STATUS=1 run
check 'API error stops execution' test "$rc" -eq 1
check 'API error cannot leave handoff' no_handoff
check 'API error keeps diagnostic' grep -qF 'mock API failure' "$fixture/err"

printf '%s\n' 'not json' > "$GH_RESPONSE_FILE"
run
check 'malformed JSON stops execution' test "$rc" -eq 1
check 'malformed JSON leaves no upstream files' no_intermediates

response '' reviewer 'https://api.github.com/repos/example/project/issues/42'
run
check 'empty body is rejected' test "$rc" -eq 1
check 'empty body leaves no handoff' no_handoff

run --pr '{pr_number}'
check 'unsubstituted argument fails before API call' test "$rc" -eq 2
check 'invalid arguments do not call API' test ! -e "$GH_CALL_LOG"

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
