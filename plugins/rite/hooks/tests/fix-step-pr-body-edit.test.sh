#!/bin/bash
# pr-body-edit replaces the PR body and reports success only when gh succeeds;
# an empty body file or a failing gh stops with FIX_PR_BODY_EDIT_FAILED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
STEP="$SCRIPT_DIR/../../scripts/fix-step.sh"

fixture=$(mktemp -d) || exit 1
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
# Stub gh: records its arguments and exits with $GH_STUB_RC.
cat > "$fixture/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$GH_STUB_ARGS"
exit "${GH_STUB_RC:-0}"
EOF
chmod +x "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH" GH_STUB_ARGS="$fixture/gh-args"
printf 'fixed body\n' > "$fixture/body.md"
: > "$fixture/empty.md"

GH_STUB_RC=0 bash "$STEP" pr-body-edit --pr 12 --owner-repo o/r --body-file "$fixture/body.md" \
  > "$fixture/out" 2> "$fixture/err"
assert "success exits 0" "0" "$?"
assert "success emits the edited marker" "[CONTEXT] FIX_PR_BODY_EDITED=1; pr=12" "$(cat "$fixture/out")"
assert "gh receives the PR, repo and body file" "pr edit 12 -R o/r --body-file $fixture/body.md" \
  "$(tr '\n' ' ' < "$fixture/gh-args" | sed 's/ $//')"

GH_STUB_RC=1 bash "$STEP" pr-body-edit --pr 12 --owner-repo o/r --body-file "$fixture/body.md" \
  > "$fixture/out" 2> "$fixture/err"
assert "gh failure exits 1" "1" "$?"
assert "gh failure emits no edited marker" "" "$(cat "$fixture/out")"
assert_grep "gh failure emits the failed marker" "$fixture/err" '^\[CONTEXT\] FIX_PR_BODY_EDIT_FAILED=1; pr=12; reason=gh_pr_edit_failed$'

rm -f "$fixture/gh-args"
bash "$STEP" pr-body-edit --pr 12 --owner-repo o/r --body-file "$fixture/empty.md" \
  > "$fixture/out" 2> "$fixture/err"
assert "empty body exits 1" "1" "$?"
assert "empty body emits no edited marker" "" "$(cat "$fixture/out")"
assert_grep "empty body emits the failed marker" "$fixture/err" '^\[CONTEXT\] FIX_PR_BODY_EDIT_FAILED=1; pr=12; reason=body_file_empty$'
if [ -e "$fixture/gh-args" ]; then
  fail "empty body does not call gh"
else
  pass "empty body does not call gh"
fi

print_summary "$(basename "$0")" || exit 1
