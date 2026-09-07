#!/usr/bin/env bash
# Hermetic behavior tests for the extracted helper and the actual SKILL caller.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
contains() { "$REAL_GREP" -qF -- "$2" "$1"; }
lacks() { ! contains "$1" "$2"; }
export REAL_GREP=$(command -v grep) REAL_MKTEMP=$(command -v mktemp)
export CASE_DIR="$TEST_DIR/case"
SANDBOX="$TEST_DIR/plugin"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/hooks" "$TEST_DIR/bin" "$CASE_DIR/tmp"
cp "$PLUGIN_ROOT/scripts/fix-work-memory-update.sh" "$SANDBOX/scripts/fix-work-memory-update.sh"
cp "$PLUGIN_ROOT/hooks/control-char-neutralize.sh" "$SANDBOX/hooks/control-char-neutralize.sh"
TARGET="$SANDBOX/scripts/fix-work-memory-update.sh"
export TMPDIR="$CASE_DIR/tmp"
export PATH="$TEST_DIR/bin:$PATH"
cat > "$TEST_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE_DIR/git.log"
case "$1" in
  branch) [ "$BRANCH_RC" = 0 ] || { echo 'branch IO error' >&2; exit "$BRANCH_RC"; }; printf '%s\n' "$BRANCH" ;;
  diff)
    if [ -n "$TEST_SIGNAL" ]; then kill -s "$TEST_SIGNAL" "$(cat "$CASE_DIR/helper.pid")"; fi
    [ "$DIFF_RC" = 0 ] || { echo 'diff IO error' >&2; exit "$DIFF_RC"; }
    cat "$CASE_DIR/diff.fixture" ;;
  *) exit 99 ;;
esac
STUB
cat > "$TEST_DIR/bin/grep" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = -oE ] && [ "$BODY_GREP_RC" != 0 ]; then
  echo 'body read error' >&2
  exit "$BODY_GREP_RC"
fi
exec "$REAL_GREP" "$@"
STUB
cat > "$TEST_DIR/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
n=0; [ ! -f "$CASE_DIR/mktemp.count" ] || read -r n < "$CASE_DIR/mktemp.count"
n=$((n + 1)); printf '%s\n' "$n" > "$CASE_DIR/mktemp.count"
[ "$n" != "$MKTEMP_FAIL_AT" ] || exit 1
exec "$REAL_MKTEMP" "$@"
STUB
cat > "$SANDBOX/hooks/issue-comment-wm-sync.sh" <<'STUB'
#!/usr/bin/env bash
args=("$@")
transform=''; changed=''; history=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --transform) transform=$2; shift ;;
    --changed-files-file) changed=$2; shift ;;
    --content-file) history=$2; shift ;;
  esac
  shift
done
printf '%s\n' "$transform" >> "$CASE_DIR/order"
printf '%s\0' "${args[@]}" > "$CASE_DIR/$transform.args"
case "$transform" in
  update-progress)
    cp "$changed" "$CASE_DIR/changed.actual"
    printf '%s' "$changed" > "$CASE_DIR/changed.path"
    printf '%s\n' "$PROGRESS_OUT"; exit "$PROGRESS_RC" ;;
  append-section)
    cp "$history" "$CASE_DIR/history.actual"
    printf '%s\n' "$HISTORY_OUT"; exit "$HISTORY_RC" ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/"*
# Expectations deliberately pin pre-extraction formatting, including rename tabs.
printf 'A\tnew.ts\nM\t日本語 file.md\nD\told.ts\nR100\tbefore.ts\tafter.ts\n' > "$TEST_DIR/diff.fixture"
printf '%s\n' '- `new.ts` - 追加' '- `日本語 file.md` - 変更' '- `old.ts` - 削除' $'- `before.ts\tafter.ts` - 名前変更' > "$TEST_DIR/changed.expected"
cat > "$TEST_DIR/body.fixture" <<'BODY'
日本語本文 "引用" 'single' $(touch BODY_INJECTION) `touch BODY_BACKTICK`
Fixes #42
Closes #99
BODY
cat > "$TEST_DIR/history.fixture" <<'HISTORY'
日本語の履歴 "引用" 'single' $HOME $(touch HISTORY_INJECTION) `touch HISTORY_BACKTICK`
EOF
\n は文字列のまま
HISTORY
IMPL='✅ 完了 "引用" $(touch STATUS_INJECTION)'
TEST_STATUS='🔄 進行中 `touch STATUS_BACKTICK`'
DOC='⬜ 未着手'
reset_case() {
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/tmp"
  cp "$TEST_DIR/"*.fixture "$CASE_DIR/"
  cp "$CASE_DIR/body.fixture" "$CASE_DIR/pr body.txt"
  cp "$CASE_DIR/history.fixture" "$CASE_DIR/history.txt"
  printf 'branch:\n  base: "main"\n' > "$CASE_DIR/rite-config.yml"
  printf 'other invocation' > "$CASE_DIR/tmp/rite-fix-pr-body-grep-err-other"
  export BRANCH='fix/issue-77-other' BRANCH_RC=0 DIFF_RC=0 BODY_GREP_RC=0 MKTEMP_FAIL_AT=0 TEST_SIGNAL=''
  export PROGRESS_OUT='status=success' HISTORY_OUT='status=success' PROGRESS_RC=0 HISTORY_RC=0
  HISTORY_FILE="$CASE_DIR/history.txt"
}
run() {
  RC=0
  (cd "$CASE_DIR" && bash -c 'echo $$ > "$CASE_DIR/helper.pid"; exec bash "$@"' _ "$TARGET" \
    --pr-body-file "$CASE_DIR/pr body.txt" --history-file "$HISTORY_FILE" \
    --impl-status "$IMPL" --test-status "$TEST_STATUS" --doc-status "$DOC") > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
}
marker() { check "$1 marker" contains "$CASE_DIR/out" "[CONTEXT] FIX_WM_UPDATE=$2; issue_number=$3"; }
reason() { check "$1 retained reason" contains "$CASE_DIR/err" "reason=$2"; }
no_calls() { check "$1 suppresses WM calls" test ! -e "$CASE_DIR/order"; }
cleaned() {
  local files=("$CASE_DIR/tmp/"*)
  check "$1 removes only owned tempfiles" test "${#files[@]}" = 1
  check "$1 preserves other invocation tempfile" contains "$CASE_DIR/tmp/rite-fix-pr-body-grep-err-other" 'other invocation'
  check "$1 preserves PR input" test -f "$CASE_DIR/pr body.txt"
  check "$1 preserves history input" test -f "$CASE_DIR/history.txt"
}

echo '--- normal payload and issue resolution ---'
reset_case; run
check 'normal rc' test "$RC" = 0
marker normal success 42
check 'body first match overrides branch' lacks "$CASE_DIR/git.log" 'branch --show-current'
# Frozen pre-extraction resolver: compare platform-local legacy behavior, since
# its GNU regex extensions do not promise the same value under BSD tools.
# Keep this oracle independent of the extracted helper; config changes belong
# to a separate change, not this compatibility-preserving extraction.
legacy_base=$(
  set +e
  cd "$CASE_DIR"
  base_branch=$(grep -E '^\s*base:' rite-config.yml 2>/dev/null | head -1 \
    | sed 's/.*base:[[:space:]]*"\?\([^"]*\)"\?.*/\1/')
  [ -z "$base_branch" ] && base_branch="develop"
  printf '%s' "$base_branch"
)
check 'base config preserves pre-extraction diff range' contains "$CASE_DIR/git.log" "diff --name-status origin/${legacy_base}...HEAD"
if ! contains "$CASE_DIR/git.log" "diff --name-status origin/${legacy_base}...HEAD"; then
  printf 'expected base: %s\n' "$legacy_base"
  cat "$CASE_DIR/git.log"
fi
printf 'update-progress\nappend-section\n' > "$CASE_DIR/order.expected"
check 'progress precedes history' cmp -s "$CASE_DIR/order.expected" "$CASE_DIR/order"
check 'A/M/D/R payload matches original fixture' cmp -s "$TEST_DIR/changed.expected" "$CASE_DIR/changed.actual"
check 'history stays literal data' cmp -s "$TEST_DIR/history.fixture" "$CASE_DIR/history.actual"
check 'PR input stays literal data' cmp -s "$TEST_DIR/body.fixture" "$CASE_DIR/pr body.txt"
printf '%s\0' update --issue 42 --transform update-progress --impl-status "$IMPL" --test-status "$TEST_STATUS" --doc-status "$DOC" --changed-files-file "$(cat "$CASE_DIR/changed.path")" > "$CASE_DIR/progress.expected"
printf '%s\0' update --issue 42 --transform append-section --section レビュー対応履歴 --content-file "$CASE_DIR/history.txt" > "$CASE_DIR/history.expected"
check 'progress exact argument boundaries and statuses' cmp -s "$CASE_DIR/progress.expected" "$CASE_DIR/update-progress.args"
check 'history exact argument boundaries' cmp -s "$CASE_DIR/history.expected" "$CASE_DIR/append-section.args"
for injected in BODY_INJECTION BODY_BACKTICK HISTORY_INJECTION HISTORY_BACKTICK STATUS_INJECTION STATUS_BACKTICK; do
  check "$injected never executed" test ! -e "$CASE_DIR/$injected"
done
check 'helper leaves final fix sentinel to caller' lacks "$CASE_DIR/out" '[fix:'
cleaned normal

reset_case; printf 'No issue reference\n' > "$CASE_DIR/pr body.txt"; rm "$CASE_DIR/rite-config.yml"; run
marker fallback success 77
check 'default base branch preserved' contains "$CASE_DIR/git.log" 'origin/develop...HEAD'
reset_case; printf 'Resolves #12\n' > "$CASE_DIR/pr body.txt"; run; marker resolves success 12
reset_case; printf 'Closes #45\n' > "$CASE_DIR/pr body.txt"; run; marker closes success 45
reset_case; BODY_GREP_RC=1; run
marker 'grep no match with diagnostic' success 77
check 'grep exit 1 diagnostic remains warning' contains "$CASE_DIR/err" 'WARNING: pr_body grep'
check 'grep exit 1 does not retain failure' lacks "$CASE_DIR/err" 'WM_UPDATE_FAILED=1'
reset_case; printf 'No issue\n' > "$CASE_DIR/pr body.txt"; BRANCH=feature/no-issue; run
reason unresolved issue_number_not_found; marker unresolved failed ''; no_calls unresolved

for missing in empty missing; do
  reset_case
  if [ "$missing" = empty ]; then : > "$CASE_DIR/pr body.txt"; else rm "$CASE_DIR/pr body.txt"; fi
  run; check "$missing body rc" test "$RC" = 1
  reason "$missing body" pr_body_tmp_empty_or_missing; no_calls "$missing body"
done
reset_case; BODY_GREP_RC=2; run
check 'body IO soft rc' test "$RC" = 0
reason 'body IO' pr_body_grep_io_error; no_calls 'body IO'
check 'body IO does not fallback' test ! -e "$CASE_DIR/git.log"
reset_case; printf 'No issue\n' > "$CASE_DIR/pr body.txt"; BRANCH_RC=128; run
reason 'branch IO' branch_grep_io_error; no_calls 'branch IO'; cleaned 'branch IO'
reset_case; DIFF_RC=128; run
reason diff git_diff_failed; no_calls diff; cleaned diff

# Calls 1/2/3/4 are body stderr, changed-file, diff stderr, WM stderr.
for spec in '1:1:mktemp_failed_pr_body_grep_err' '2:0:git_diff_failed'; do
  reset_case; IFS=: read -r MKTEMP_FAIL_AT expected_rc expected_reason <<< "$spec"; run
  check "mktemp $MKTEMP_FAIL_AT rc" test "$RC" = "$expected_rc"
  reason "mktemp $MKTEMP_FAIL_AT" "$expected_reason"; no_calls mktemp; cleaned mktemp
done
reset_case; printf 'No issue\n' > "$CASE_DIR/pr body.txt"; MKTEMP_FAIL_AT=2; run
check 'branch temp fatal rc' test "$RC" = 1
reason 'branch temp' mktemp_failed_branch_grep_err; no_calls 'branch temp'; cleaned 'branch temp'
for MKTEMP_INDEX in 3 4; do
  reset_case; MKTEMP_FAIL_AT=$MKTEMP_INDEX; run
  marker 'optional stderr tempfile failure' success 42; cleaned 'optional tempfile'
done

echo '--- WM status and history preparation ordering ---'
for stage in progress history; do
  for state in no_comment error absent; do
    reset_case
    case "$state" in
      no_comment) response='status=skipped; reason=no_comment'; expected=skipped ;;
      error) response='status=error; reason=patch_failed'; expected=failed ;;
      absent) response=''; expected=failed ;;
    esac
    if [ "$stage" = progress ]; then PROGRESS_OUT=$response; else HISTORY_OUT=$response; fi
    # The WM protocol is the status line, including status failures with rc=0.
    run; marker "$stage $state" "$expected" 42
    if [ "$state" = no_comment ]; then
      check "$stage no_comment has no stale flag" lacks "$CASE_DIR/err" 'WM_UPDATE_FAILED=1'
    else reason "$stage $state" "wm_sync_${stage}_failed"; fi
    if [ "$stage" = progress ]; then
      check "$stage $state suppresses history" test ! -e "$CASE_DIR/append-section.args"
    fi
    cleaned "$stage $state"
  done
done
reset_case; PROGRESS_OUT=''; PROGRESS_RC=1; run
reason 'WM nonzero without status' wm_sync_progress_failed
for history_path in empty missing; do
  reset_case
  if [ "$history_path" = empty ]; then HISTORY_FILE=''; else HISTORY_FILE="$CASE_DIR/missing-history"; fi
  run; reason "$history_path history" wm_sync_history_failed
  check "$history_path history follows progress" test -f "$CASE_DIR/update-progress.args"
  check "$history_path history does not append" test ! -e "$CASE_DIR/append-section.args"
done
for state in 'status=skipped; reason=no_comment' 'status=error; reason=patch_failed'; do
  reset_case; HISTORY_FILE=''; PROGRESS_OUT=$state; run
  check 'unprepared history ignored before progress success' lacks "$CASE_DIR/err" 'reason=wm_sync_history_failed'
done

for spec in INT:130 TERM:143 HUP:129; do
  reset_case; IFS=: read -r TEST_SIGNAL expected_rc <<< "$spec"; run
  check "$TEST_SIGNAL exit code" test "$RC" = "$expected_rc"
  marker "$TEST_SIGNAL" failed 42; cleaned "$TEST_SIGNAL"
done

echo '--- execute caller extracted from actual SKILL ---'
check 'failed history preparation retains cleanup before clearing its path' contains "$PLUGIN_ROOT/skills/fix/SKILL.md" '確保済みの履歴ファイルを削除してからパスを空文字にする'
check 'status fallback includes committed changes' contains "$PLUGIN_ROOT/skills/fix/SKILL.md" 'helper と同じ `git diff --name-status "origin/{base_branch}...HEAD"`'
check 'failed completion maps to retained failure' contains "$PLUGIN_ROOT/skills/fix/SKILL.md" '`FIX_WM_UPDATE=failed` の場合も `WM_UPDATE_FAILED=1` を保持'

# Extract the first bash fence in 4.5; never reimplement the caller in this test.
awk '/^### 4\.5 / { section=1 } section && /^```bash$/ { block=1; next } block && /^```$/ { exit } block { print }' \
  "$PLUGIN_ROOT/skills/fix/SKILL.md" > "$TEST_DIR/caller.template"
check 'SKILL caller extracted' test -s "$TEST_DIR/caller.template"
cp "$TARGET" "$TEST_DIR/helper.original"
for failure in normal missing syntax invalid-args zero-marker INT TERM HUP; do
  reset_case
  cp "$TEST_DIR/helper.original" "$TARGET"
  case "$failure" in
    missing) rm "$TARGET" ;;
    syntax) printf 'if ; then\n' > "$TARGET" ;;
    invalid-args)
      printf '#!/usr/bin/env bash\nexec bash "%s" --unknown-option\n' "$TEST_DIR/helper.original" > "$TARGET" ;;
    zero-marker) printf '#!/usr/bin/env bash\nexit 0\n' > "$TARGET" ;;
    INT|TERM|HUP) TEST_SIGNAL=$failure ;;
  esac
  sed -e "s|{plugin_root}|$SANDBOX|g" \
    -e "s|{pr_body_file}|$CASE_DIR/pr body.txt|g" -e "s|{history_file}|$CASE_DIR/history.txt|g" \
    -e 's|{impl_status}|✅ 完了|g' -e 's|{test_status}|🔄 進行中|g' -e 's|{doc_status}|⬜ 未着手|g' \
    "$TEST_DIR/caller.template" > "$CASE_DIR/caller.sh"
  # Preserve the real helper while recording its PID for signal injection.
  if [ -n "$TEST_SIGNAL" ]; then
    mv "$TARGET" "$SANDBOX/scripts/helper-signal.sh"
    printf 'echo $$ > "$CASE_DIR/helper.pid"\nexec bash "%s" "$@"\n' "$SANDBOX/scripts/helper-signal.sh" > "$TARGET"
  fi
  RC=0
  (cd "$CASE_DIR" && bash "$CASE_DIR/caller.sh") > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
  if [ "$failure" = normal ]; then
    marker 'actual caller normal' success 42
    check 'normal caller has no startup failure' lacks "$CASE_DIR/err" 'reason=wm_update_helper_failed'
  elif [ -n "$TEST_SIGNAL" ]; then
    case "$failure" in INT) expected_rc=130 ;; TERM) expected_rc=143 ;; HUP) expected_rc=129 ;; esac
    check "caller $failure propagates signal rc" test "$RC" = "$expected_rc"
    marker "caller $failure" failed 42
    check "caller $failure exposes rc" contains "$CASE_DIR/err" "rc=$expected_rc"
  else
    reason "caller $failure" wm_update_helper_failed
    check "caller $failure exits nonzero" test "$RC" -ne 0
  fi
  check "caller $failure removes PR input" test ! -e "$CASE_DIR/pr body.txt"
  check "caller $failure removes history input" test ! -e "$CASE_DIR/history.txt"
  check "caller $failure preserves other run input" test -f "$CASE_DIR/body.fixture"
  check "caller $failure preserves other run tempfile" test -f "$CASE_DIR/tmp/rite-fix-pr-body-grep-err-other"
done
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
