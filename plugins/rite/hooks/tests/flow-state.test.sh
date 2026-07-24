#!/bin/bash
# Tests for plugins/rite/hooks/flow-state.sh (PR 2a refactor)
# Covers AC-2 (atomic write + flock), AC-3 (schema_version v2 → v3 migration)
# and the canonical subcommand contract (set/get/deactivate/migrate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
HOOK="$PLUGIN_ROOT/hooks/flow-state.sh"

if [ ! -x "$HOOK" ]; then
  echo "ERROR: $HOOK not found or not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

# Clean session-id env for standalone runs (Issue #1530). flow-state.sh resolves
# session_id env-first; the file-based sandboxes below must exercise the
# `.rite-session-id` fallback, so the dogfooding session's ambient
# CLAUDE_CODE_SESSION_ID must not leak in. TC-13/14/15 + T-01/T-02/T-04 set the
# vars explicitly per-command, overriding this unset. (run-tests.sh unsets the
# same vars for suite runs; this keeps `bash flow-state.test.sh` deterministic too.)
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

# Helper: prepare a sandbox with .rite-session-id and STATE_ROOT detection
new_sandbox() {
  local d sid
  d=$(make_plain_sandbox --soft)
  (cd "$d" && git init -q && echo a > a && git add a && \
    git -c user.email=t@test.local -c user.name=test commit -q -m init) >/dev/null
  sid="$(uuidgen 2>/dev/null || echo "11111111-2222-3333-4444-555555555555")"
  echo "$sid" > "$d/.rite-session-id"
  echo "$d|$sid"
}

# --- TC-1: set creates v3 schema file ---
echo "=== TC-1: set creates v3 schema file with branch (not branch_name) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 42 --branch "feat/issue-42" \
  --pr 0 --next "test next")
state_file="$d/.rite/sessions/${sid}.flow-state"
assert_file_exists_or_fail "state file written" "$state_file" || true
assert "schema_version=3" "3" "$(jq -r .schema_version "$state_file")"
assert "phase=plan" "plan" "$(jq -r .phase "$state_file")"
assert "branch field name = branch" "feat/issue-42" "$(jq -r .branch "$state_file")"
assert "no branch_name field" "null" "$(jq -r '.branch_name // \"null\"' "$state_file" 2>/dev/null || echo 'null')"
assert "active=true default" "true" "$(jq -r .active "$state_file")"
assert "error_count=0" "0" "$(jq -r .error_count "$state_file")"

# --- TC-2: get reads field ---
echo ""
echo "=== TC-2: get reads field and respects --default ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase implement --issue 7 --branch "x" --pr 0 --next "n")
got=$(cd "$d" && bash "$HOOK" get --field phase)
assert "get phase returns implement" "implement" "$got"
got=$(cd "$d" && bash "$HOOK" get --field nonexistent --default "FALLBACK")
assert "get nonexistent returns default" "FALLBACK" "$got"
got=$(cd "$d" && bash "$HOOK" get --field issue_number)
assert "get issue_number returns 7" "7" "$got"

# --- TC-3: deactivate sets active=false ---
echo ""
echo "=== TC-3: deactivate sets active=false and preserves other fields ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase ready --issue 42 --branch "b" --pr 99 --next "ready")
(cd "$d" && bash "$HOOK" deactivate --next "completed")
state_file="$d/.rite/sessions/${sid}.flow-state"
assert "active=false after deactivate" "false" "$(jq -r .active "$state_file")"
assert "phase preserved" "ready" "$(jq -r .phase "$state_file")"
assert "pr_number preserved" "99" "$(jq -r .pr_number "$state_file")"
assert "next_action updated" "completed" "$(jq -r .next_action "$state_file")"

# --- TC-4: --if-exists is no-op when file is missing ---
echo ""
echo "=== TC-4: --if-exists skips when file absent ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n" --if-exists)
if [ -f "$d/.rite/sessions/${sid}.flow-state" ]; then
  fail "TC-4: --if-exists created file even though file did not exist"
else
  pass "TC-4: --if-exists skipped correctly"
fi

# --- TC-5: --preserve-error-count keeps error_count ---
echo ""
echo "=== TC-5: --preserve-error-count keeps error_count across same-phase set ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n")
state_file="$d/.rite/sessions/${sid}.flow-state"
# Manually inject error_count=3 to simulate prior error tracking
jq '.error_count = 3' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n2" --preserve-error-count)
assert "error_count preserved" "3" "$(jq -r .error_count "$state_file")"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n3")
assert "error_count reset without flag" "0" "$(jq -r .error_count "$state_file")"

# --- TC-6: migrate v2 → v3 transforms phase enum and drops legacy fields ---
echo ""
echo "=== TC-6: migrate v2 → v3 reduces cleanup_*/ingest_*/create_* and drops legacy fields ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{
  "schema_version": 2,
  "active": true,
  "issue_number": 100,
  "branch_name": "old-branch",
  "phase": "cleanup_pre_ingest",
  "previous_phase": "cleanup",
  "pr_number": 5,
  "parent_issue_number": 0,
  "next_action": "old",
  "updated_at": "2026-05-22T00:00:00Z",
  "session_id": "${sid}",
  "last_synced_phase": "cleanup"
}
EOF
(cd "$d" && bash "$HOOK" migrate --verbose) >/dev/null 2>&1 || true
state_file="$d/.rite/sessions/${sid}.flow-state"
assert "schema_version bumped to 3" "3" "$(jq -r .schema_version "$state_file")"
assert "cleanup_pre_ingest → cleanup" "cleanup" "$(jq -r .phase "$state_file")"
assert "branch_name → branch (rename)" "old-branch" "$(jq -r .branch "$state_file")"
assert "branch_name dropped" "null" "$(jq -r '.branch_name // "null"' "$state_file")"
assert "previous_phase dropped" "null" "$(jq -r '.previous_phase // "null"' "$state_file")"
assert "last_synced_phase preserved" "cleanup" "$(jq -r '.last_synced_phase // "null"' "$state_file")"
assert "issue_number preserved" "100" "$(jq -r .issue_number "$state_file")"

# --- TC-7: migrate idempotent for already-v3 files ---
echo ""
echo "=== TC-7: migrate skips files already at v3 ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase fix --issue 7 --branch "b" --pr 1 --next "n")
state_file="$d/.rite/sessions/${sid}.flow-state"
before=$(jq -r .updated_at "$state_file")
sleep 1
out=$(cd "$d" && bash "$HOOK" migrate --verbose 2>&1)
after=$(jq -r .updated_at "$state_file")
assert "v3 file is skipped" "$before" "$after"
echo "$out" | grep -q "skip (already v3)" && pass "TC-7: skip message shown" || fail "TC-7: no skip message"

# --- TC-8: migrate maps various legacy phases correctly ---
echo ""
echo "=== TC-8: migrate phase reduction matrix (cleanup_*/ingest_*/create_*/implementing) ==="
# Note: `implementing` legacy phase maps to v3 `implement` (not `init`) because
# the v3 SoT enum keeps the `implement` value (`init branch plan implement lint
# pr review fix ...`). Only create_*/parent_progress_sync/unknown collapse into
# init.
for legacy_phase in cleanup_post_ingest cleanup_completed ingest_pre_lint ingest_post_lint ingest_completed create_interview create_completed implementing; do
  case "$legacy_phase" in
    cleanup_*) expected=cleanup ;;
    ingest_*) expected=ingest ;;
    implementing) expected=implement ;;
    create_*) expected=init ;;
  esac
  result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
  mkdir -p "$d/.rite/sessions"
  cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"$legacy_phase","session_id":"$sid","issue_number":0,"branch":"","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
  (cd "$d" && bash "$HOOK" migrate >/dev/null 2>&1) || true
  got=$(jq -r .phase "$d/.rite/sessions/${sid}.flow-state")
  assert "migrate $legacy_phase → $expected" "$expected" "$got"
done

# --- TC-8b: AC-8 — a performed migration is announced on stderr WITHOUT --verbose ---
echo ""
echo "=== TC-8b: AC-8 non-verbose migrate emits 'migrated:' to stderr; v3-only stays silent ==="
# Why: session-start auto path silences only stdout. If `migrated:` is gated on --verbose or
# moved to stdout, a real migration becomes silent and violates AC-8 (silent skip forbidden).
# NOTE (Issue #2008): each `err=$( … migrate … )` capture below records the exit code into $rc
# instead of discarding it with `|| true`, so a migrate crash cannot masquerade as a normal run.
# The root cause that made migrate exit non-zero on macOS — an unbraced `$sv→` in flow-state.sh
# tripping `set -u` under a non-UTF-8 locale — is fixed at source, so migrate exits 0. Capturing
# rather than discarding keeps the file from aborting under `set -e` (TC-8's own tolerance) while
# preserving the crash signal: TC-8b-b asserts the *absence* of output, so without an explicit rc
# assertion an aborted migrate would produce empty stderr and be scored as "correctly silent".
assert_migrate_rc() { # <tc-label> <rc>
  if [ "$2" = "0" ]; then
    pass "$1: migrate exits 0"
  else
    fail "$1: migrate exited $2 (expected 0 — crash would otherwise be indistinguishable from a normal run)"
  fi
}
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
rc=0; err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 ) || rc=$?
assert_migrate_rc "TC-8b-a" "$rc"
# Why: grep specificity に v[12]→v3 矢印と phase 変換 token を要求することで、emission format が
# `migrate done:` 等にリネームされた場合も regression を検出できる (format stability invariant)。
echo "$err" | grep -qE 'migrated:.*v[12]→v3.*[a-z_]+→[a-z_]+' \
  && pass "TC-8b-a: non-verbose migrate announces 'migrated:' on stderr with v→v3 + phase tokens" \
  || fail "TC-8b-a: non-verbose migrate format mismatch (expected 'migrated:.*v[12]→v3.*phase→phase'): '$err'"

# Why: v3-only file は migrate 対象外で出力を発生させてはならない。`skip (already v3)` は --verbose
# でのみ出力される invariant も同時に検証する (quiet session start での noise 抑制)。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase fix --issue 8 --branch "b" --pr 1 --next "n")
rc=0; err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 ) || rc=$?
# Why (Issue #2008 review F-04): this is the only negative assertion in TC-8b — it passes when the
# capture is empty. An aborted migrate also produces empty stderr, so the exit code is the sole
# remaining signal distinguishing "correctly silent" from "crashed before printing anything".
assert_migrate_rc "TC-8b-b" "$rc"
if echo "$err" | grep -q "migrated:\|skip (already v3)"; then
  fail "TC-8b-b: non-verbose migrate of v3-only emitted output (should be silent): '$err'"
else
  pass "TC-8b-b: non-verbose migrate of v3-only stays silent"
fi

# Why: AC-8 文面は v1/v2 両方を対象とする。`_migrate_file` の `jq -r '.schema_version // 1'`
# fallback で v1 (schema_version 欠落) と v2 の code path は等価だが、両方を invariant 化することで
# 将来 fallback 削除や schema_version 必須化が起きても regression を即検出できる。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"phase":"cleanup_pre_ingest","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
rc=0; err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 ) || rc=$?
assert_migrate_rc "TC-8b-c" "$rc"
echo "$err" | grep -qE 'migrated:.*v1→v3.*[a-z_]+→[a-z_]+' \
  && pass "TC-8b-c: non-verbose migrate of v1 (schema_version 欠落) announces 'migrated:' on stderr" \
  || fail "TC-8b-c: v1 schema 欠落 migrate did not emit expected 'migrated:.*v1→v3.*phase→phase' format: '$err'"

# Why: `cmd_migrate` は SESSION_DIR/*.flow-state を loop して `_migrate_file` を call するため、
# N 個の v2 file があれば N 行の `migrated:` が emit される。single-file test では loop 内の
# 重複処理や emission 抜けを検出できないため、multi-file の counter 一致を直接 assertion する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
sid2="00000000-0000-0000-0000-000000000002"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
cat > "$d/.rite/sessions/${sid2}.flow-state" <<EOF
{"schema_version":2,"phase":"create_branch","session_id":"$sid2","issue_number":4,"branch":"b2","pr_number":0,"next_action":"y","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
rc=0; err=$( (cd "$d" && bash "$HOOK" migrate >/dev/null) 2>&1 ) || rc=$?
assert_migrate_rc "TC-8b-d" "$rc"
# Why: 行頭 anchor `^  migrated:` で固定することで、将来 hook が `Already migrated:` 等の文言を
# 追加した場合の false match を防ぐ (TC-8b-e/g と同じ anchor 形式)。
migrated_count=$(echo "$err" | grep -c '^  migrated:' || true)
if [ "$migrated_count" = "2" ]; then
  pass "TC-8b-d: multi-file migrate emits 'migrated:' per file (count=2)"
else
  fail "TC-8b-d: expected 2 'migrated:' lines but got $migrated_count: '$err'"
fi

# Why: write IO 失敗時に false `migrated:` を emit すると AC-8 invariant が逆方向 (skip を migrated
# と誤報) で破られる。chmod 0555 で sessions dir を readonly にして mv 失敗経路を強制し、
# `migrated:` 行 0 件 + `Migration complete: 0 file` を assert することで、`_atomic_write` の rc
# 伝播が将来削除されても本テストが fail する (write-failure invariant の direct verification)。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
# Why (DAC probe): root / fakeroot / CAP_DAC_OVERRIDE 環境では chmod 0555 が DAC override で
# 無効化され write-failure path を強制できない。`id -u` 判定では fakeroot / capability bound
# scenario を捕捉できないため、実機 write probe で write 強制可能性を検出する。silent false-pass
# (write が通る環境で test が pass する誤検出) を防ぐ。
# Why (probe を sandbox 近接に配置): TMPDIR が別 filesystem を指す環境でも probe と sandbox の DAC
# 挙動を一致させるため、probe を sandbox dir 配下に作成する。
# Why: mktemp 失敗時の stderr を一時的に capture することで、TMPDIR が別 fs を指す / inode 枯渇 /
# permission denied 等の root cause を fail message から確認可能にする (silent な原因隠蔽を防ぐ)。
_dac_probe_err=$(mktemp "${TMPDIR:-/tmp}/rite-dac-probe-err-XXXXXX" 2>/dev/null) || _dac_probe_err=""
if ! _dac_probe_parent=$(mktemp -d "$d/_dac_probe.XXXXXX" 2>"${_dac_probe_err:-/dev/null}"); then
  _dac_probe_diag=""
  [ -n "$_dac_probe_err" ] && [ -s "$_dac_probe_err" ] && _dac_probe_diag=" ($(head -1 "$_dac_probe_err"))"
  [ -n "$_dac_probe_err" ] && rm -f "$_dac_probe_err"
  # Why: probe 構築失敗時は silent skip ではなく fail にする。test 自体の構築不能は AC-8 invariant の
  # 検証不能を意味し、observability を確保するため明示的に fail にする。
  fail "TC-8b-e/g: mktemp -d failed for DAC probe parent under $d$_dac_probe_diag"
else
  [ -n "$_dac_probe_err" ] && rm -f "$_dac_probe_err"
  _dac_probe="$_dac_probe_parent/probe"
  mkdir -p "$_dac_probe"
  chmod 0555 "$_dac_probe"
  # Why: redirect-open 失敗時の "Permission denied" 1 行が test output に混入することを避けるため、
  # subshell 内で `>` の open 自体を実行する。shell の redirect-open 失敗 message は `2>` 再リダイレクト
  # の前に直接 stderr へ出力されるため、subshell 化で外側に漏らさない設計。
  if ( echo x > "$_dac_probe/_probe_file" ) 2>/dev/null; then
    chmod +w "$_dac_probe" 2>/dev/null || true
    rm -rf "$_dac_probe_parent"
    pass "TC-8b-e/g: skipped (chmod 0555 ineffective in this env — DAC override / root / fakeroot; write-failure invariant unverifiable)"
  else
    chmod +w "$_dac_probe" 2>/dev/null || true
    rm -rf "$_dac_probe_parent"
    # Why (trap save/restore): 将来 top-level cleanup trap が flow-state.test.sh に導入されても、
    # 本 TC の `trap -` で外側 trap を破壊しないよう既存 trap を保存し eval で復元する。
    # POSIX `trap -p` 出力は shell に reinput 可能な proper quoting 形式であり、既存 trap が
    # 空の場合は `eval ""` が no-op になる (defense-in-depth)。
    # Why (異常終了時の restore): hard-fail test や signal kill (INT/TERM/HUP) で sandbox dir
    # が readonly のまま残ると後続 test が clean state を得られないため trap で restore を保証する。
    _tc8beg_saved_trap=$(trap -p EXIT INT TERM HUP)
    _tc8beg_test_cleanup() { chmod +w "$d/.rite/sessions" 2>/dev/null || true; }
    trap _tc8beg_test_cleanup EXIT INT TERM HUP
    chmod 0555 "$d/.rite/sessions"
    combined=$( (cd "$d" && bash "$HOOK" migrate) 2>&1 ) || true
    chmod +w "$d/.rite/sessions"
    trap - EXIT INT TERM HUP
    eval "$_tc8beg_saved_trap"
    # Why: 解除後の dead function/変数を unset し、後続 TC の shell scope (declare -f / スタック
    # トレース) にノイズが残らないようにする。
    unset -f _tc8beg_test_cleanup
    unset _tc8beg_saved_trap
    migrated_lines=$(echo "$combined" | grep -c '^  migrated:' || true)
    # Why: counter が inflate しない invariant の direct verification。`_atomic_write` 失敗時に
    # `_migrate_file` が rc=1 を返し counter が 0 のままであることを確認する。
    if [ "$migrated_lines" = "0" ] && echo "$combined" | grep -qE 'Migration complete: 0 file'; then
      pass "TC-8b-e/g: write-failure path emits no 'migrated:' and counter stays 0 (AC-8 negative regression + counter invariant)"
    else
      fail "TC-8b-e/g: write-failure path leaked output: migrated_lines=$migrated_lines; combined='$combined'"
    fi
  fi
fi
# Why: TC 内で導入した一時変数を後続 TC の shell scope に残さないため明示 unset する
# (`_tc8beg_test_cleanup` / `_tc8beg_saved_trap` の cleanup precedent と整合)。
unset _dac_probe_err _dac_probe_parent _dac_probe _dac_probe_diag 2>/dev/null || true

# Why: `--dry-run` preview は session-start.sh の stdout-only silence 経路で見える必要があるため
# stderr に出力されることを invariant 化する。stdout に戻る regression を即検出する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
mkdir -p "$d/.rite/sessions"
cat > "$d/.rite/sessions/${sid}.flow-state" <<EOF
{"schema_version":2,"phase":"ingest_pre_lint","session_id":"$sid","issue_number":3,"branch":"b","pr_number":0,"next_action":"x","active":true,"updated_at":"2026-05-22T00:00:00Z"}
EOF
rc=0; err=$( (cd "$d" && bash "$HOOK" migrate --dry-run >/dev/null) 2>&1 ) || rc=$?
assert_migrate_rc "TC-8b-f" "$rc"
if echo "$err" | grep -q 'would migrate:'; then
  pass "TC-8b-f: --dry-run preview goes to stderr"
else
  fail "TC-8b-f: --dry-run preview missing from stderr (regression — possibly moved back to stdout): '$err'"
fi

# --- TC-8b-h: the `${sv}`/`${cp}` braces around the U+2192 arrow are load-bearing ---
# Why (Issue #2008 review F-06): the braces were added because an unbraced variable abutting the
# multibyte arrow folds the arrow's leading byte into the variable name under a non-UTF-8 locale,
# tripping `set -u`. That failure mode does not reproduce on glibc — every locale available here
# (C / POSIX / C.UTF-8 / en_US.utf8) expands the unbraced form correctly — so a behavioural TC
# would be vacuous on the blocking Linux leg and the braces would read as a redundant style choice
# that a later formatting pass could strip with CI still green. A static guard pins them on every
# platform instead: no unbraced `$var` may sit directly against a non-ASCII byte. Comment lines are
# exempt so the surrounding rationale can quote the anti-pattern verbatim.
#
# The guard covers every `*.sh` under plugins/rite, not just flow-state.sh. The invariant is a
# whole-codebase one, and scoping the check to a single file while wording it as a rule would leave
# the class looking closed when it was not: the same shape lived in seven other places
# (pr-cycle-cleanup.sh and lib/worktree-git.sh, all on WARNING paths under `set -u`, where the
# failure turns a warning into a hard abort). Those were braced in the same change.
#
# Scope limits, stated honestly:
#   - Only leading-`#` comment LINES are exempt. A trailing comment quoting the anti-pattern
#     (`foo   # see $sv→v3`) is still reported; stripping trailing comments would require
#     distinguishing them from `#` inside strings and `${var#pat}`, which is not worth it here.
#   - bash fenced in SKILL.md / references is NOT scanned. Those blocks are executed by rite but
#     are not `*.sh` files, and extracting fences reliably is a separate job. Two such sites exist
#     today (skills/setup/SKILL.md, skills/pr-review/references/finding-cycling.md); neither runs
#     under `set -u`, so the failure mode there is garbled output rather than an abort.
echo ""
echo "=== TC-8b-h: no unbraced \$var abuts a multibyte character in any plugins/rite shell script ==="
#
# One awk pass per file, numbering against the ORIGINAL file. Piping through a
# comment-stripping filter first and numbering the survivors reports the offset
# within the filtered stream, not the real line — across ~200 files that is off by
# hundreds of lines and sends the reader to unrelated code.
_tc8bh_detect() {
  LC_ALL=C awk '!/^[[:space:]]*#/ && /\$[A-Za-z_][A-Za-z0-9_]*[^ -~]/ { print FILENAME ":" NR ": " $0 }' "$1"
}

# Positive control. This is a negative assertion — it passes when nothing is found — so a broken
# detector or an empty file list would report success. Prove the detector fires on a known
# violation through the SAME function the scan uses, otherwise a rotted pattern would sail through
# its own control.
_tc8bh_probe=$(mktemp "${TMPDIR:-/tmp}/rite-tc8bh-probe-XXXXXX.sh")
printf 'sv=2\necho "v$sv\xe2\x86\x92v3"\n' > "$_tc8bh_probe"
if [ "$(_tc8bh_detect "$_tc8bh_probe" | wc -l | tr -d '[:space:]')" = "1" ]; then
  pass "TC-8b-h control: the detector reports a known unbraced-\$var violation"
else
  fail "TC-8b-h control: the detector did NOT report a known violation — the scan below is vacuous"
fi
rm -f "$_tc8bh_probe"

unbraced_report=""
unbraced_total=0
_tc8bh_scanned=0
while IFS= read -r _sh; do
  _tc8bh_scanned=$((_tc8bh_scanned + 1))
  _found=$(_tc8bh_detect "$_sh")
  if [ -n "$_found" ]; then
    _hits=$(printf '%s\n' "$_found" | wc -l | tr -d '[:space:]')
    unbraced_total=$((unbraced_total + _hits))
    unbraced_report="$unbraced_report
$_found"
  fi
done < <(find "$PLUGIN_ROOT" -name '*.sh' -type f | sort)
# A discovery that returns nothing is a broken scan, not a clean one.
if [ "$_tc8bh_scanned" -eq 0 ]; then
  fail "TC-8b-h: found no *.sh under $PLUGIN_ROOT — the scan matched nothing to check (layout changed?)"
elif [ "$unbraced_total" = "0" ]; then
  pass "TC-8b-h: all variables abutting multibyte characters are brace-delimited ($_tc8bh_scanned files scanned)"
else
  fail "TC-8b-h: $unbraced_total line(s) hold an unbraced \$var abutting a multibyte character — brace them (\${var}) or a non-UTF-8 locale will fold the following byte into the name and trip set -u:$unbraced_report"
fi
unset -f _tc8bh_detect
unset unbraced_report unbraced_total _sh _hits _found _tc8bh_probe _tc8bh_scanned

# --- TC-9: phase enum validation warns but accepts unknown phase ---
echo ""
echo "=== TC-9: unknown phase warns but writes file (non-strict mode) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase unknown_phase --issue 1 --branch "b" --pr 0 --next "n") 2> "$d/stderr"
state_file="$d/.rite/sessions/${sid}.flow-state"
assert_file_exists_or_fail "state file written despite unknown phase" "$state_file" || true
grep -q "WARNING: unknown phase" "$d/stderr" && pass "TC-9: warning emitted" || fail "TC-9: no warning"

# --- TC-10: concurrent writes do not corrupt JSON (flock smoke test) ---
echo ""
echo "=== TC-10: concurrent set calls preserve JSON integrity ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(
  cd "$d"
  for i in 1 2 3 4 5; do
    bash "$HOOK" set --phase plan --issue "$i" --branch "b$i" --pr "$i" --next "n$i" &
  done
  wait
)
state_file="$d/.rite/sessions/${sid}.flow-state"
if jq -e . "$state_file" >/dev/null 2>&1; then
  pass "TC-10: JSON integrity preserved after 5 concurrent writes"
else
  fail "TC-10: JSON corrupted by concurrent writes"
fi

# --- TC-11: cmd_set preserves last_synced_phase across merge ---
echo ""
echo "=== TC-11: cmd_set preserves last_synced_phase (post-tool-wm-sync.sh runtime field) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 11 --branch "b" --pr 0 --next "n")
state_file="$d/.rite/sessions/${sid}.flow-state"
# Simulate post-tool-wm-sync.sh writing last_synced_phase as a runtime-only field.
jq '.last_synced_phase = "plan"' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
# A subsequent cmd_set must NOT wipe last_synced_phase (else wm-sync diff guard would
# fire every hook invocation and spam GitHub API calls).
(cd "$d" && bash "$HOOK" set --phase implement --issue 11 --branch "b" --pr 0 --next "n2")
assert "TC-11: last_synced_phase preserved across cmd_set merge" "plan" "$(jq -r '.last_synced_phase // "null"' "$state_file")"
assert "TC-11: phase updated as expected" "implement" "$(jq -r .phase "$state_file")"

# --- TC-12: cmd_set on corrupt JSON emits WARNING ---
echo ""
echo "=== TC-12: cmd_set on corrupt existing state emits WARNING (no silent overwrite) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
# Create a corrupt state file (invalid JSON) at the per-session path.
mkdir -p "$d/.rite/sessions"
state_file="$d/.rite/sessions/${sid}.flow-state"
printf '{this is not valid JSON' > "$state_file"
# cmd_set should succeed (defaults applied to merge) BUT emit a WARNING to stderr so
# operator can observe the silent-overwrite-into-zero-state situation.
(cd "$d" && bash "$HOOK" set --phase plan --issue 12 --branch "b" --pr 0 --next "n") 2> "$d/tc12.stderr"
if grep -q "WARNING: flow-state.sh cmd_set: existing state read failed" "$d/tc12.stderr"; then
  pass "TC-12: corrupt-JSON WARNING emitted"
else
  fail "TC-12: no WARNING for corrupt JSON (silent overwrite regression)"
fi
# 他 4 経路 (TC-16.1 / TC-17.1 / TC-20.1 / TC-20.2) と対称化。cmd_set corrupt-JSON 経路に
# 導入された $(basename) 化と head -3 | sed 's/^/  /' indented diagnostic を pin する。
# 前者が抜けると multi-tenant 絶対 path leak が silent に復活し、後者が抜けると
# observability 喪失 (jq parse error の中身が見えなくなる) が silent に復活する。
if grep -qE 'WARNING:.*\.rite/sessions/' "$d/tc12.stderr"; then
  fail "TC-12: WARNING に絶対 path (.rite/sessions/) が leak"
else
  pass "TC-12: WARNING に絶対 path leak なし"
fi
if grep -qE '^  [^ ]' "$d/tc12.stderr"; then
  pass "TC-12: corrupt JSON で診断 stderr の indented 行が出力される"
else
  fail "TC-12: 診断 stderr の indented 行が欠落"
fi
# Resulting file must be valid JSON (write proceeded with defaults).
if jq -e . "$state_file" >/dev/null 2>&1; then
  pass "TC-12: merged write produced valid JSON with defaults"
else
  fail "TC-12: merged write failed to produce valid JSON"
fi

# --- TC-13: AC-4 — CLAUDE_CODE_SESSION_ID env resolves session_id when .rite-session-id is absent ---
echo ""
echo "=== TC-13: AC-4 CLAUDE_CODE_SESSION_ID env-only resolution ==="
# Why: the root cause was that `_resolve_session_id` only honored
# CLAUDE_SESSION_ID, but Claude Code runtime sets CLAUDE_CODE_SESSION_ID. When
# `.rite-session-id` was absent, get/set silently degraded (empty + rc=0 / silent skip).
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase plan --issue 1142 --branch "fix/issue-1142" --pr 0 --next "n")
# Remove .rite-session-id to force env-var path.
rm -f "$d/.rite-session-id"
# `env -u CLAUDE_SESSION_ID` で legacy env も明示 unset し、TC-14 と完全対称化。
# precedence regression (CLAUDE_CODE_SESSION_ID 分岐削除) を TC-13 単体で検出可能にする。
got=$(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" get --field phase --default "EMPTY")
assert "TC-13.1: CLAUDE_CODE_SESSION_ID resolves get correctly" "plan" "$got"
(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" set --phase pr --next "after-fix" --if-exists)
got=$(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" get --field phase --default "EMPTY")
assert "TC-13.2: CLAUDE_CODE_SESSION_ID resolves set --if-exists correctly" "pr" "$got"
got=$(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" get --field next_action --default "EMPTY")
assert "TC-13.3: --if-exists write was not silently skipped" "after-fix" "$got"
# TC-13.4: 両 env-var 同時 set 時の precedence (CLAUDE_CODE_SESSION_ID が primary)
# 2 種類の sid を用意し、CCSID 側の state file が選択されることを assert する。
# これにより `_resolve_session_id` の if-branch 順序入れ替え regression を catch する。
result2=$(new_sandbox); d2="${result2%|*}"; sid2="${result2#*|}"
(cd "$d2" && bash "$HOOK" set --phase ready --issue 9999 --branch "br-ccsid" --pr 0 --next "ccsid-state")
rm -f "$d2/.rite-session-id"
# 別 sid (= 別 state file path) を CLAUDE_SESSION_ID に渡し、CCSID 側が勝つことを確認
got=$(cd "$d2" && env CLAUDE_CODE_SESSION_ID="$sid2" CLAUDE_SESSION_ID="deadbeef-0000-0000-0000-000000000000" bash "$HOOK" get --field next_action --default "EMPTY")
assert "TC-13.4: CLAUDE_CODE_SESSION_ID takes precedence over CLAUDE_SESSION_ID (primary)" "ccsid-state" "$got"

# --- TC-14: AC-4 backwards-compat — CLAUDE_SESSION_ID still works ---
echo ""
echo "=== TC-14: AC-4 backwards-compat CLAUDE_SESSION_ID still resolves ==="
# Why: keep the legacy env var name working so any out-of-tree tooling that
# already sets CLAUDE_SESSION_ID does not break.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase implement --issue 1142 --branch "b" --pr 0 --next "n")
rm -f "$d/.rite-session-id"
got=$(cd "$d" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$sid" bash "$HOOK" get --field phase --default "EMPTY")
assert "TC-14: legacy CLAUDE_SESSION_ID still resolves get" "implement" "$got"

# --- TC-15: AC-3 — cmd_get surfaces _resolve_session_id ERROR (no silencing) ---
echo ""
echo "=== TC-15: AC-3 cmd_get does not silence resolution ERROR ==="
# Why: cmd_get used `_resolve_session_id ... 2>/dev/null`, hiding the
# "ERROR: cannot resolve session_id" message. Now stderr must reach the operator.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 )
# ERE pattern: 文言の軽微なリネーム (e.g. cmd_get→get、prefix 変更) でも brittle に
# silent regression しないようにする (cmd_get と "cannot resolve" の組合せのみ assert)
if echo "$err" | grep -qE 'ERROR:.*cannot resolve session_id'; then
  pass "TC-15: cmd_get surfaces _resolve_session_id ERROR on stderr"
else
  fail "TC-15: cmd_get silenced resolution ERROR (regression of the resolution-ERROR fix): '$err'"
fi

# --- TC-16: AC-3 — cmd_get emits WARNING for stale .rite-session-id drift ---
echo ""
echo "=== TC-16: AC-3 cmd_get WARNs on stale .rite-session-id drift ==="
# Why: When `.rite-session-id` resolves to a sid whose state file does not exist,
# the caller's "get value" intent silently degrades to default. The fix
# emits a WARNING to make the drift observable. Truly first-time sessions (no
# `.rite-session-id`) stay silent (graceful no-op).
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
echo "deadbeef-0000-0000-0000-000000000000" > "$d/.rite-session-id"
err=$( (cd "$d" && bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 )
# ERE pattern で文言 drift に耐性 (`(path|file):` を含めない柔軟な anchor で
# WARNING 文言が path/file/その他に変わっても match する)。
if echo "$err" | grep -qE 'WARNING:.*cmd_get.*state file not found'; then
  pass "TC-16.1: cmd_get WARNs on stale sid drift"
else
  fail "TC-16.1: cmd_get silent on stale sid drift: '$err'"
fi
# basename leak 抑制 (multi-tenant 環境での絶対 path leak を防ぐ negative-assert)
if echo "$err" | grep -qE 'WARNING:.*\.rite/sessions/'; then
  fail "TC-16.1: stale sid WARNING に絶対 path (.rite/sessions/) が leak: '$err'"
else
  pass "TC-16.1: stale sid WARNING に絶対 path leak なし"
fi
# Truly first-time (no .rite-session-id) must stay silent (graceful contract).
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
# The resolution-ERROR is expected here; WARNING about state-file-not-found must NOT
# fire because we never resolved a sid.
if echo "$err" | grep -qE 'WARNING:.*cmd_get.*state file not found'; then
  fail "TC-16.2: cmd_get emitted state-file WARNING when sid was not resolved (regression)"
else
  pass "TC-16.2: cmd_get silent about state-file-not-found when sid resolution itself failed"
fi

# --- TC-17: AC-2 + AC-3 — cmd_set --if-exists WARNs on stale .rite-session-id drift ---
echo ""
echo "=== TC-17: AC-2/AC-3 cmd_set --if-exists WARNs on stale sid; first-time silent ==="
# Why: `--if-exists` silently skipped when sid resolved to a file
# that did not exist (stale `.rite-session-id`). Caller's intent (update active
# session state) was violated without any signal. Fix emits WARNING only when
# `.rite-session-id` exists (caller expected a session), staying silent for the
# truly first-time case that wiki/ingest.md (get) and ready 等 --if-exists caller rely on.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
echo "deadbeef-0000-0000-0000-000000000000" > "$d/.rite-session-id"
err=$( (cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n" --if-exists) 2>&1 )
if echo "$err" | grep -qE 'WARNING:.*cmd_set:.*if-exists skipped'; then
  pass "TC-17.1: cmd_set --if-exists WARNs on stale sid drift"
else
  fail "TC-17.1: cmd_set --if-exists silent on stale sid drift: '$err'"
fi
# basename leak 抑制 (multi-tenant 環境での絶対 path leak を防ぐ negative-assert)
if echo "$err" | grep -qE 'WARNING:.*\.rite/sessions/'; then
  fail "TC-17.1: stale sid WARNING に絶対 path (.rite/sessions/) が leak: '$err'"
else
  pass "TC-17.1: stale sid WARNING に絶対 path leak なし"
fi
# First-time session (no .rite-session-id, no env): cmd_set returns rc=1 + ERROR
# (resolution failure surfaces). The --if-exists silent-skip contract applies AFTER
# sid resolution succeeds, not before. First-time graceful means "no WARNING about
# --if-exists skip", not "rc=0" (実機: env 両方 unset で set --if-exists → rc=1 + ERROR)。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
combined=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n" --if-exists) 2>&1 || true )
# WARNING about "--if-exists skipped" must NOT appear because we never reached that branch.
if echo "$combined" | grep -qE 'WARNING:.*cmd_set:.*if-exists skipped'; then
  fail "TC-17.2: emitted --if-exists WARNING when sid resolution itself failed (regression)"
else
  pass "TC-17.2: silent about --if-exists skip when sid resolution failed (ERROR surfaces instead)"
fi

# --- TC-18: env-var session_id path-traversal validation ---
echo ""
echo "=== TC-18: env-var session_id path-traversal validation ==="
# Why: env-var paths and override path were resolving sid without validation,
# allowing "../../tmp/owned" to write state files outside .rite/sessions/.
# Pin the validator with negative tests for 4 entry points:
#  TC-18.1/2: env-var (CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID)
#  TC-18.3:   --session override
#  TC-18.4:   SESSION_ID_FILE content
# This ensures `_validate_session_id` chokepoint protects all 4 sources symmetrically.
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="../../tmp/pwned" bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*path-traversal'; then
  pass "TC-18.1: CLAUDE_CODE_SESSION_ID rejects '..' path traversal"
else
  fail "TC-18.1: path traversal not rejected: '$err'"
fi
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="abc/def" bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*path-traversal'; then
  pass "TC-18.2: CLAUDE_SESSION_ID rejects '/' path traversal"
else
  fail "TC-18.2: path traversal not rejected: '$err'"
fi
# TC-18.3: --session override 経路。validator が chokepoint で発火することを pin
err=$( (cd "$d" && bash "$HOOK" get --session "../../tmp/pwned" --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*path-traversal'; then
  pass "TC-18.3: --session override rejects '..' path traversal"
else
  fail "TC-18.3: override path traversal not rejected: '$err'"
fi
# TC-18.4: SESSION_ID_FILE 経路。.rite-session-id 内容も同じ validator を通る
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
echo "../../tmp/pwned-from-file" > "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*path-traversal'; then
  pass "TC-18.4: SESSION_ID_FILE content rejects '..' path traversal"
else
  fail "TC-18.4: SESSION_ID_FILE path traversal not rejected: '$err'"
fi

# --- TC-19: env-var session_id control-character validation (log injection guard) ---
echo ""
echo "=== TC-19: env-var session_id control-character validation (log injection guard) ==="
# Why: WARNING messages embedded $sid without escaping, allowing
# CLAUDE_CODE_SESSION_ID=$'innocent\nWARNING: fake injected' to inject fake
# WARNING lines into stderr (CRLF / log injection vector). Pin rejection of
# the 4 main control-char vectors:
#  TC-19.1: \n (newline — CRLF splitting primary vector)
#  TC-19.2: \t (tab)
#  TC-19.3: \r (CR — HTTP-style CRLF injection primary vector)
# Plus TC-19.4: 「reject 発生」だけでなく fake WARNING 行が **stderr に存在しない** ことを negative-assert
# (validator が partial regression した場合に injection が漏出しても rejection が出れば pass する穴を塞ぐ)
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID=$'sid-with\nnewline' bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*control characters'; then
  pass "TC-19.1: CLAUDE_CODE_SESSION_ID rejects embedded newline (log injection)"
else
  fail "TC-19.1: newline not rejected: '$err'"
fi
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID=$'sid\twith-tab' bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*control characters'; then
  pass "TC-19.2: CLAUDE_SESSION_ID rejects embedded tab (log injection)"
else
  fail "TC-19.2: tab not rejected: '$err'"
fi
# TC-19.3: \r (CR) — CRLF splitting attack の primary vector
err=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID=$'sid\rwith-cr' bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*control characters'; then
  pass "TC-19.3: CLAUDE_CODE_SESSION_ID rejects embedded CR (CRLF injection)"
else
  fail "TC-19.3: CR not rejected: '$err'"
fi
# TC-19.4 (negative assertion): injection 内容が stderr に**漏出していない**ことを assert
# validator partial regression (例: [[:cntrl:]] を `\n` のみに狭めた変更) に対する直接 guard
inj_err=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID=$'sid\nWARNING: fake injected by attacker' bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$inj_err" | grep -qE 'WARNING:.*fake injected by attacker'; then
  fail "TC-19.4: injection content leaked into stderr (validator regression): '$inj_err'"
else
  pass "TC-19.4: injection content not present in stderr (validator chokepoint pin)"
fi
# TC-19.5: --session override 経路 control-char rejection (TC-18 と symmetric な 4 entry point pin)
err=$( (cd "$d" && bash "$HOOK" get --session $'sid\nwith-newline' --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*control characters'; then
  pass "TC-19.5: --session override rejects embedded newline (control-char chokepoint)"
else
  fail "TC-19.5: --session override で control-char not rejected: '$err'"
fi
# TC-19.6: SESSION_ID_FILE 経路 control-char rejection
# 注: _resolve_session_id は SESSION_ID_FILE 内容に `tr -d '[:space:]'` を適用するため、
# tab / newline / CR は事前削除される。non-whitespace control char (\x01 = SOH、ASCII control) を使い、
# tr では削除されず validator に到達することを確認する (cntrl class chokepoint の symmetric pin)
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
printf 'sid\x01with-soh' > "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*control characters'; then
  pass "TC-19.6: SESSION_ID_FILE 内容 rejects embedded SOH (4 entry point の対称 pin 完成)"
else
  fail "TC-19.6: SESSION_ID_FILE control-char not rejected: '$err'"
fi
# TC-19.7: C1 8-bit 制御バイト (0x9b = 8-bit CSI introducer) rejection
# 旧 `=~ [[:cntrl:]]` は glibc が C/UTF-8 両ロケールで C1 (0x80-0x9f) を cntrl と
# 分類しないため 0x9b 入り session_id を素通ししていた。contains_ctrl
# (control-char-neutralize.sh と共有のバイト範囲定義) への置換で reject されることを pin。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID=$'sid\x9bwith-csi' bash "$HOOK" get --field phase --default "DEF" >/dev/null) 2>&1 || true )
if echo "$err" | grep -qE 'ERROR:.*invalid session_id.*control characters'; then
  pass "TC-19.7: CLAUDE_CODE_SESSION_ID rejects C1 0x9b byte"
else
  fail "TC-19.7: C1 0x9b not rejected: '$err'"
fi

# --- TC-20: cmd_get jq failure WARNING paths (corrupt JSON state file) ---
echo ""
echo "=== TC-20: cmd_get jq failure WARNING paths (silent-failure regression guard) ==="
# Why: cmd_get の jq 失敗経路 (--field / --jq-filter 両方) は WARNING + rc=0 + default 出力の
# 3 点を契約とする。corrupt JSON で発火させて 3 点同時に pin することで、stderr suppress +
# silent fallback への regression を検出する。診断 stderr の indented 行 (jq エラー内容) も
# 別 assert で pin し、診断行 silent 欠落も catch する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
# state file を作成してから内容を corrupt JSON に上書きする
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n") >/dev/null
state_file="$d/.rite/sessions/${sid}.flow-state"
echo "{this is not valid JSON" > "$state_file"
# TC-20.1: --field path で jq read failed WARNING + rc=0 + stdout に default 返却 + 診断行 (2-space indent)
combined=$( (cd "$d" && bash "$HOOK" get --field phase --default "DEF") 2>&1 )
get_rc=$?
if echo "$combined" | grep -qE 'WARNING:.*cmd_get: jq read failed'; then
  pass "TC-20.1: corrupt JSON で --field 経路の jq read failed WARNING が発火"
else
  fail "TC-20.1: WARNING missing on corrupt JSON --field: '$combined'"
fi
if [ "$get_rc" = "0" ]; then
  pass "TC-20.1: jq read failed でも rc=0 (silent-failure 解消経路の non-blocking 契約)"
else
  fail "TC-20.1: jq read failure で rc=$get_rc (expected 0)"
fi
if echo "$combined" | grep -qE '^DEF$'; then
  pass "TC-20.1: jq read failure でも stdout に default 返却"
else
  fail "TC-20.1: default not returned on jq read failure: '$combined'"
fi
# 診断 stderr の indented 行 (jq error 内容、`sed 's/^/  /'` で prefix される) が出ること
if echo "$combined" | grep -qE '^  [^ ]'; then
  pass "TC-20.1: jq read failure 時に診断 stderr の indented 行が出力される (observability 確保)"
else
  fail "TC-20.1: 診断 stderr の indented 行が欠落: '$combined'"
fi
# basename leak 抑制 (multi-tenant 環境での絶対 path leak を防ぐ negative-assert)
if echo "$combined" | grep -qE 'WARNING:.*\.rite/sessions/'; then
  fail "TC-20.1: WARNING に絶対 path (.rite/sessions/) が leak: '$combined'"
else
  pass "TC-20.1: WARNING に絶対 path leak なし (basename 化が機能している)"
fi
# TC-20.2: --jq-filter 経路の jq filter failed WARNING + rc=0 + stdout に default 返却 + 診断行
combined=$( (cd "$d" && bash "$HOOK" get --jq-filter '.phase' --default "DEF") 2>&1 )
get_rc=$?
if echo "$combined" | grep -qE 'WARNING:.*cmd_get: jq filter failed'; then
  pass "TC-20.2: corrupt JSON で --jq-filter 経路の jq filter failed WARNING が発火"
else
  fail "TC-20.2: WARNING missing on corrupt JSON --jq-filter: '$combined'"
fi
if [ "$get_rc" = "0" ]; then
  pass "TC-20.2: jq filter failed でも rc=0"
else
  fail "TC-20.2: jq filter failure で rc=$get_rc (expected 0)"
fi
if echo "$combined" | grep -qE '^DEF$'; then
  pass "TC-20.2: jq filter failure でも stdout に default 返却"
else
  fail "TC-20.2: default not returned on jq filter failure: '$combined'"
fi
if echo "$combined" | grep -qE '^  [^ ]'; then
  pass "TC-20.2: jq filter failure 時に診断 stderr の indented 行が出力される"
else
  fail "TC-20.2: 診断 stderr の indented 行が欠落: '$combined'"
fi
if echo "$combined" | grep -qE 'WARNING:.*\.rite/sessions/'; then
  fail "TC-20.2: WARNING に絶対 path (.rite/sessions/) が leak: '$combined'"
else
  pass "TC-20.2: WARNING に絶対 path leak なし"
fi

# --- TC-21: cmd_get --field/--jq-filter 両方未指定の ERROR rc=1 経路 ---
echo ""
echo "=== TC-21: cmd_get --field/--jq-filter required (contract pin) ==="
# Why: --field / --jq-filter 両方未指定時は cmd_get が ERROR + rc=1 を返す契約。state file が
# 存在する経路で発火させないと「state file 不在」分岐の WARNING + rc=0 path に流れて契約 pin が
# 成立しないため、事前に set で state file を作成する。将来引数 parser を loose にして default
# field を導入した場合の silent な behavioral drift を pin する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
# state file を作成する (state file 不在では cmd_get の "state file not found" WARNING + default + rc=0
# 分岐に流れて `--field or --jq-filter required` ERROR + rc=1 経路に到達しないため、本 TC では事前に
# state file を生成しておく)
(cd "$d" && bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n") >/dev/null
# get は意図的に rc=1 を返す経路 → 外側 set -e で abort しないよう || true を付与し
# subshell 内で得た rc を直接 capture する
combined=$( (cd "$d" && bash "$HOOK" get --default "DEF"; echo "__RC=$?") 2>&1 || true )
get_rc=$(printf '%s' "$combined" | sed -n 's/.*__RC=\([0-9]*\).*/\1/p')
combined="${combined%__RC=*}"
if echo "$combined" | grep -qE 'ERROR: --field or --jq-filter required'; then
  pass "TC-21.1: --field/--jq-filter 両方未指定で ERROR メッセージが stderr に出る"
else
  fail "TC-21.1: ERROR missing: '$combined'"
fi
if [ "$get_rc" = "1" ]; then
  pass "TC-21.1: --field/--jq-filter 両方未指定で rc=1 (契約 pin)"
else
  fail "TC-21.1: rc=$get_rc (expected 1)"
fi

# --- TC-22: env-set + state file 不在 + .rite-session-id 不在 の graceful 沈黙契約 ---
echo ""
echo "=== TC-22: env-set first-time silent contract (wiki/ingest.md get / ready 等 --if-exists caller 依存) ==="
# Why: env で sid 解決成功 + state file 不在 + .rite-session-id 不在 (Claude Code 起動直後 /
# wiki/ingest.md 初回呼び出し) では `[ -f "$SESSION_ID_FILE" ]` gate が false で graceful silent。
# 将来 gate が除去され「path 不在で常に WARN」に変わると、依存先で WARNING ノイズが大量発生
# する silent contract break を pin する。symmetric pin として cmd_set / cmd_get 両方を test する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
# TC-22.1: cmd_set --if-exists の symmetric pin
combined=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" set --phase plan --issue 1 --branch "b" --pr 0 --next "n" --if-exists) 2>&1 )
if echo "$combined" | grep -qE 'WARNING:.*cmd_set:.*if-exists skipped'; then
  fail "TC-22.1: env-set first-time で if-exists skipped WARNING が漏出 (gate 除去 regression): '$combined'"
else
  pass "TC-22.1: env-set first-time で cmd_set --if-exists が graceful silent (依存先契約保持)"
fi
# TC-22.2: cmd_get の symmetric pin (gate は cmd_get 側の同 [ -f "$SESSION_ID_FILE" ] 判定)
combined=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOK" get --field phase --default "DEF"; echo "__RC=$?") 2>&1 || true )
get_rc=$(printf '%s' "$combined" | sed -n 's/.*__RC=\([0-9]*\).*/\1/p')
combined="${combined%__RC=*}"
if echo "$combined" | grep -qE 'WARNING:.*cmd_get:.*state file not found'; then
  fail "TC-22.2: env-set first-time で state-file-not-found WARNING が漏出 (gate 除去 regression): '$combined'"
else
  pass "TC-22.2: env-set first-time で cmd_get が graceful silent (依存先契約保持)"
fi
# graceful 完了 invariant: rc=0 + stdout に default 返却 (依存先 wiki/ingest.md get / ready 等 --if-exists caller の契約)
if [ "$get_rc" = "0" ]; then
  pass "TC-22.2: env-set first-time で cmd_get が rc=0 (graceful contract)"
else
  fail "TC-22.2: env-set first-time で cmd_get rc=$get_rc (expected 0)"
fi
stdout_only=$(printf '%s' "$combined" | grep -E '^DEF$' || true)
if [ -n "$stdout_only" ]; then
  pass "TC-22.2: env-set first-time で stdout に default 返却 (graceful contract)"
else
  fail "TC-22.2: env-set first-time で stdout に default 返却なし: '$combined'"
fi

# --- TC-H1..H5: handoff one-shot marker ---
echo ""
echo "=== TC-H1: set --handoff writes handoff field ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase review --issue 1168 --branch b --pr 99 --next n --handoff "/rite:fix 99")
state_file="$d/.rite/sessions/${sid}.flow-state"
assert "TC-H1: handoff set" "/rite:fix 99" "$(jq -r '.handoff // "ABSENT"' "$state_file")"

echo ""
echo "=== TC-H2: set WITHOUT --handoff default-clears (no handoff key) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase review --issue 1168 --branch b --pr 99 --next n)
state_file="$d/.rite/sessions/${sid}.flow-state"
assert "TC-H2: handoff absent when --handoff omitted" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$state_file")"

echo ""
echo "=== TC-H3: consume-handoff prints value + deletes it (one-shot) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase fix --issue 1168 --branch b --pr 99 --next n --handoff "/rite:pr-review 99")
state_file="$d/.rite/sessions/${sid}.flow-state"
first=$(cd "$d" && bash "$HOOK" consume-handoff)
assert "TC-H3: first consume returns value" "/rite:pr-review 99" "$first"
assert "TC-H3: handoff deleted after consume" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$state_file")"
second=$(cd "$d" && bash "$HOOK" consume-handoff)
assert "TC-H3: second consume is empty (one-shot)" "" "$second"
# Other fields must survive the consume (del only touches .handoff)
assert "TC-H3: phase preserved through consume" "fix" "$(jq -r .phase "$state_file")"
assert "TC-H3: pr_number preserved through consume" "99" "$(jq -r .pr_number "$state_file")"

echo ""
echo "=== TC-H4: consume-handoff on file without handoff → empty + rc 0, WARNING 非発火 ==="
# Why: valid JSON だが handoff キー欠落の正常系。`// ""` で rc=0 のまま空 handoff を返し WARNING を出さない
# (corrupt 側 TC-H7 の WARNING 発火と対になる happy-path 側)。corrupt-read 対称化 (cmd_set / cmd_get /
# consume-handoff) の片側だけを pin すると、無条件 WARNING emit への revert を検出できないため、
# stderr を capture して WARNING 非発火を negative-assert する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase review --issue 1168 --branch b --pr 99 --next n)
_tch4_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-tch4-stderr-XXXXXX" 2>/dev/null) || _tch4_stderr="/dev/null"
out=$( (cd "$d" && bash "$HOOK" consume-handoff 2>"$_tch4_stderr"); echo "__RC=$?" )
rc=$(printf '%s' "$out" | sed -n 's/.*__RC=\([0-9]*\).*/\1/p')
val="${out%__RC=*}"; val="${val%$'\n'}"
assert "TC-H4: no handoff → empty output" "" "$val"
assert "TC-H4: no handoff → rc 0" "0" "$rc"
if [ "$_tch4_stderr" = "/dev/null" ]; then
  pass "TC-H4: WARNING 非発火 assert を skip (stderr capture tempfile 取得不可)"
elif grep -qE 'WARNING:.*consume-handoff.*handoff read failed' "$_tch4_stderr"; then
  fail "TC-H4: handoff キー欠落の正常系で corrupt-read WARNING が誤発火: '$(cat "$_tch4_stderr" 2>/dev/null)'"
else
  pass "TC-H4: handoff キー欠落の正常系で WARNING 非発火 (cmd_set / cmd_get 対称化の happy-path 側を pin)"
fi
[ "${_tch4_stderr:-/dev/null}" != "/dev/null" ] && rm -f "$_tch4_stderr"
unset _tch4_stderr

echo ""
echo "=== TC-H5: set --handoff then set without --handoff clears it (terminal transition) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
state_file="$d/.rite/sessions/${sid}.flow-state"
(cd "$d" && bash "$HOOK" set --phase fix --issue 1168 --branch b --pr 99 --next n --handoff "/rite:pr-review 99")
assert "TC-H5: handoff present after continuation set" "/rite:pr-review 99" "$(jq -r '.handoff // "ABSENT"' "$state_file")"
(cd "$d" && bash "$HOOK" set --phase fix --issue 1168 --branch b --pr 99 --next "terminal")
assert "TC-H5: handoff cleared by subsequent no-handoff set" "ABSENT" "$(jq -r '.handoff // "ABSENT"' "$state_file")"

echo ""
echo "=== TC-H6: consume-handoff fail-closed on _atomic_write failure ==="
# Why: cmd_consume_handoff の順序は jq del → _atomic_write → printf (delete-then-print)。
# 永続 FS 書込失敗下では _atomic_write が失敗し、printf に到達せず値が withhold される (stdout 空) +
# handoff が file に残存 + rc=0 に縮退する。これにより Stop hook は空 HANDOFF を読んで停止を許可し、
# print-then-delete 旧順序なら起きる「値出力済み + 削除失敗 → 無限 re-block」(AC-3 違反) を防ぐ。
# この correctness path に test がないと print-then-delete への revert を検出できないため pin する。
# 書込失敗の強制は TC-8b-e/g と同じ DAC-probe (chmod 0555) を流用する。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase fix --issue 1168 --branch b --pr 99 --next n --handoff "/rite:pr-review 99")
state_file="$d/.rite/sessions/${sid}.flow-state"
# DAC probe (同 TC-8b-e/g): root / fakeroot / CAP_DAC_OVERRIDE 環境では chmod 0555 が無効化され
# write-failure path を強制できないため、実機 write probe で強制可能性を検出し silent false-pass を防ぐ。
_dac_probe_err=$(mktemp "${TMPDIR:-/tmp}/rite-dac-probe-err-XXXXXX" 2>/dev/null) || _dac_probe_err=""
if ! _dac_probe_parent=$(mktemp -d "$d/_dac_probe.XXXXXX" 2>"${_dac_probe_err:-/dev/null}"); then
  _dac_probe_diag=""
  [ -n "$_dac_probe_err" ] && [ -s "$_dac_probe_err" ] && _dac_probe_diag=" ($(head -1 "$_dac_probe_err"))"
  [ -n "$_dac_probe_err" ] && rm -f "$_dac_probe_err"
  fail "TC-H6: mktemp -d failed for DAC probe parent under $d$_dac_probe_diag"
else
  [ -n "$_dac_probe_err" ] && rm -f "$_dac_probe_err"
  _dac_probe="$_dac_probe_parent/probe"
  mkdir -p "$_dac_probe"
  chmod 0555 "$_dac_probe"
  if ( echo x > "$_dac_probe/_probe_file" ) 2>/dev/null; then
    chmod +w "$_dac_probe" 2>/dev/null || true
    rm -rf "$_dac_probe_parent"
    pass "TC-H6: skipped (chmod 0555 ineffective in this env — DAC override / root / fakeroot; fail-closed path unverifiable)"
  else
    chmod +w "$_dac_probe" 2>/dev/null || true
    rm -rf "$_dac_probe_parent"
    # trap save/restore (TC-8b-e/g と同形): hard-fail / signal kill で sessions dir が readonly のまま
    # 残ると後続 test が clean state を得られないため restore を保証する。
    _tch6_saved_trap=$(trap -p EXIT INT TERM HUP)
    _tch6_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-tch6-stderr-XXXXXX" 2>/dev/null) || _tch6_stderr="/dev/null"
    _tch6_test_cleanup() {
      chmod +w "$d/.rite/sessions" 2>/dev/null || true
      [ "${_tch6_stderr:-/dev/null}" != "/dev/null" ] && rm -f "$_tch6_stderr"
    }
    trap _tch6_test_cleanup EXIT INT TERM HUP
    chmod 0555 "$d/.rite/sessions"
    out=$( (cd "$d" && bash "$HOOK" consume-handoff 2>"$_tch6_stderr"); echo "__RC=$?" )
    chmod +w "$d/.rite/sessions"
    rc=$(printf '%s' "$out" | sed -n 's/.*__RC=\([0-9]*\).*/\1/p')
    val="${out%__RC=*}"; val="${val%$'\n'}"
    assert "TC-H6: value withheld on write failure (stdout empty)" "" "$val"
    assert "TC-H6: rc 0 on write failure (Stop hook will allow stop)" "0" "$rc"
    assert "TC-H6: handoff retained in file (delete not persisted)" "/rite:pr-review 99" "$(jq -r '.handoff // "ABSENT"' "$state_file")"
    # 診断 ERROR が stderr に出ること (observability: write 失敗時の triage 用。cmd_set / _atomic_write の ERROR emission と対称)
    if [ "$_tch6_stderr" = "/dev/null" ]; then
      pass "TC-H6: 診断 ERROR assert を skip (stderr capture tempfile 取得不可)"
    elif grep -qE 'ERROR:.*consume-handoff.*handoff clear failed' "$_tch6_stderr"; then
      pass "TC-H6: write failure 時に診断 ERROR が stderr に emit される (observability)"
    else
      fail "TC-H6: write failure 時の診断 ERROR が欠落: '$(cat "$_tch6_stderr" 2>/dev/null)'"
    fi
    trap - EXIT INT TERM HUP
    eval "$_tch6_saved_trap"
    [ "${_tch6_stderr:-/dev/null}" != "/dev/null" ] && rm -f "$_tch6_stderr"
    unset -f _tch6_test_cleanup
    unset _tch6_saved_trap _tch6_stderr
  fi
fi
unset _dac_probe_err _dac_probe_parent _dac_probe _dac_probe_diag 2>/dev/null || true

echo ""
echo "=== TC-H7: consume-handoff on corrupt JSON → WARNING + empty + rc 0 ==="
# Why: corrupt JSON 時の fail-open (空 + rc=0 → Stop hook が停止許可) は AC-3 上正しい安全側挙動だが、
# `|| handoff=""` 形式は無診断で corrupt を検出できない。cmd_set / cmd_get と対称に WARNING を
# stderr へ emit することを pin し、silent fallback への revert を検出する。stdout 空 + rc=0 の
# fail-open 不変も同時に固定する (WARNING 追加で停止許可挙動が崩れていないこと)。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
state_file="$d/.rite/sessions/${sid}.flow-state"
# 正規 set で sessions dir + valid file を作ってから corrupt JSON で上書き (実際の FS corruption を模倣)
(cd "$d" && bash "$HOOK" set --phase fix --issue 1170 --branch b --pr 99 --next n --handoff "/rite:pr-review 99")
printf '{ this is not valid json' > "$state_file"
_tch7_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-tch7-stderr-XXXXXX" 2>/dev/null) || _tch7_stderr="/dev/null"
out=$( (cd "$d" && bash "$HOOK" consume-handoff 2>"$_tch7_stderr"); echo "__RC=$?" )
rc=$(printf '%s' "$out" | sed -n 's/.*__RC=\([0-9]*\).*/\1/p')
val="${out%__RC=*}"; val="${val%$'\n'}"
assert "TC-H7: corrupt JSON → empty output (fail-open)" "" "$val"
assert "TC-H7: corrupt JSON → rc 0 (Stop hook will allow stop)" "0" "$rc"
if [ "$_tch7_stderr" = "/dev/null" ]; then
  pass "TC-H7: WARNING assert を skip (stderr capture tempfile 取得不可)"
elif grep -qE 'WARNING:.*consume-handoff.*handoff read failed' "$_tch7_stderr"; then
  pass "TC-H7: corrupt JSON 時に WARNING が stderr に emit される (cmd_set / cmd_get と対称)"
else
  fail "TC-H7: corrupt JSON 時の WARNING が欠落: '$(cat "$_tch7_stderr" 2>/dev/null)'"
fi
[ "${_tch7_stderr:-/dev/null}" != "/dev/null" ] && rm -f "$_tch7_stderr"
unset _tch7_stderr
# ⚠️ sandbox 隔離の留意: TC-H7 は corrupt JSON を state_file に書き込んだまま終了する
# (corrupt 状態の観測が目的のため cleanup しないのは意図的)。本 TC より後ろに TC を追加する場合は、
# 残置された corrupt state_file を引き継がないよう必ず new_sandbox で独立 sandbox を取得すること
# (直後の TC-23 は準拠済み)。

# --- TC-23: jq stderr スニペットの control-char 中和 ---
echo ""
echo "=== TC-23: _emit_jq_err_snippet が jq stderr の制御文字を中和する ==="
# Why: corrupt state file 断片には ANSI escape / 制御バイトが含まれうる。これが jq stderr スニペット
# 経由で operator terminal に生のまま到達すると、カーソル移動 / 色 / タイトル書換え等で端末を駆動され
# うる。cmd_set / cmd_get(×2) / cmd_consume_handoff の 4 emission site を共通 helper
# `_emit_jq_err_snippet` に集約し、共通ヘルパー neutralize_ctrl (control-char-neutralize.sh /
# C0+DEL に加え C1 0x80-0x9f もバイト単位カバー) で `?` に 1:1 中和する。4 site が同一
# helper 経由のため 1 経路で中和ロジックを pin すれば全 site を固定できる (対称位置への伝播漏れを
# 構造的に回避)。jq 1.7 の parse error は入力バイトを echo しないため、`--jq-filter 'error("...")'`
# で jq の error builtin に生 ESC を載せて確実に jq stderr (= スニペット) へ出させる。
# assertion は 2-space indent の snippet 行に限定する: WARNING 行の `(filter: ...)` echo は caller
# 供給の filter 文字列 (corrupt-file 由来ではない) を含むため本 TC のスコープ外。
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
# valid な state file を作成 (error() は valid JSON に対しても runtime error を起こす)
(cd "$d" && bash "$HOOK" set --phase plan --issue 1173 --branch "b" --pr 0 --next "n") >/dev/null
esc=$(printf '\033')  # ESC (0x1b) を runtime 構築 —  等の表記揺れに依存せず決定論的
filter="error(\"${esc}[31mINJECTED${esc}[0m\")"
combined=$( (cd "$d" && bash "$HOOK" get --jq-filter "$filter" --default "DEF") 2>&1 )
# snippet = helper が emit する 2-space indent 診断行 (= jq stderr の corrupt-fragment 相当)
snippet=$(printf '%s\n' "$combined" | grep '^  ' || true)
# TC-23.1: jq filter failed WARNING 発火 (中和 helper を呼ぶ経路に到達した sanity pin)
if echo "$combined" | grep -qE 'WARNING:.*cmd_get: jq filter failed'; then
  pass "TC-23.1: jq filter failed WARNING 発火 (中和 helper 経路に到達)"
else
  fail "TC-23.1: WARNING missing: '$combined'"
fi
# TC-23.2 (core): snippet 行に生 ESC (0x1b) が残らない = 制御文字が中和されている
if printf '%s' "$snippet" | LC_ALL=C grep -q "$esc"; then
  fail "TC-23.2: snippet 行に生 ESC が残存 (control-char 中和が機能していない): '$(printf '%s' "$snippet" | cat -v)'"
else
  pass "TC-23.2: snippet 行の生 ESC が中和されている"
fi
# TC-23.3: 制御文字が中和マーカー '?' へ 1:1 置換され可読テキストは保持される
# (空削除への revert と snippet 全体 drop の両方を catch する)
if printf '%s' "$snippet" | grep -qF '?[31mINJECTED?[0m'; then
  pass "TC-23.3: 制御文字が '?' へ 1:1 置換され可読テキストが保持される"
else
  fail "TC-23.3: 中和マーカー '?' パターンが不在: '$(printf '%s' "$snippet" | cat -v)'"
fi
# TC-23.4: C1 8-bit 制御バイトの中和。U+009B (UTF-8: 0xc2 0x9b) は valid UTF-8
# として jq の error builtin / JSON 経路を素通りして snippet まで届く現実の攻撃バイト列
# (xterm 等は UTF-8 モードでも C1 を制御文字として解釈する)。旧 `s/[[:cntrl:]]/?/g` は glibc が
# C1 を cntrl と分類しないため 0x9b を素通ししていた。バイト単位 neutralize_ctrl は 2 バイト目の
# 0x9b を `?` 化するため、snippet 行に生 0x9b バイトが残らないことを pin する。
csi=$(printf '\xc2\x9b')  # U+009B CSI introducer (UTF-8)
filter_c1="error(\"CSI${csi}INJECTED\")"
combined_c1=$( (cd "$d" && bash "$HOOK" get --jq-filter "$filter_c1" --default "DEF") 2>&1 )
# grep -a: WARNING 行の `(filter: ...)` echo は caller 供給の生 0xc2 0x9b を含む (スコープ外 —
# TC-23 ヘッダー参照) ため combined が binary 判定され、-a なしでは行抽出が空になる。
snippet_c1=$(printf '%s\n' "$combined_c1" | grep -a '^  ' || true)
if [ -z "$snippet_c1" ]; then
  fail "TC-23.4: snippet 行が emit されていない (C1 経路に到達せず): '$(printf '%s' "$combined_c1" | cat -v)'"
elif printf '%s' "$snippet_c1" | LC_ALL=C grep -q $'\x9b'; then
  fail "TC-23.4: snippet 行に生 0x9b (C1 CSI) が残存: '$(printf '%s' "$snippet_c1" | cat -v)'"
else
  pass "TC-23.4: C1 0x9b (U+009B 経由) が snippet 行で中和されている"
fi

# --- TC-WT: --worktree field (multi-session §2) ---
echo ""
echo "=== TC-WT1: set --worktree then get returns the path ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase implement --issue 1362 --branch "feat/issue-1362" \
  --pr 0 --next "n" --worktree "/abs/worktrees/issue-1362")
state_file="$d/.rite/sessions/${sid}.flow-state"
assert "worktree field written" "/abs/worktrees/issue-1362" "$(jq -r .worktree "$state_file")"
got=$(cd "$d" && bash "$HOOK" get --field worktree)
assert "get --field worktree returns path" "/abs/worktrees/issue-1362" "$got"

echo ""
echo "=== TC-WT2: worktree is merge-preserved across a set without --worktree ==="
(cd "$d" && bash "$HOOK" set --phase lint --next "next")
assert "worktree preserved (merge-preserve like branch)" "/abs/worktrees/issue-1362" "$(jq -r .worktree "$state_file")"
assert "branch preserved alongside" "feat/issue-1362" "$(jq -r .branch "$state_file")"

echo ""
echo "=== TC-WT3: non-worktree session never gains the key (byte-identical / additive) ==="
result=$(new_sandbox); d2="${result%|*}"; sid2="${result#*|}"
(cd "$d2" && bash "$HOOK" set --phase implement --issue 999 --branch "x" --pr 0 --next "n")
state_file2="$d2/.rite/sessions/${sid2}.flow-state"
assert "no worktree key when --worktree never passed" "false" "$(jq 'has("worktree")' "$state_file2")"

# --- TC-24: non-UUID opaque session_id is ACCEPTED (Layer 1 format-agnostic contract) ---
# Why: `_validate_session_id` is the Layer 1 security-boundary validator and is
# format-agnostic BY DESIGN — it rejects path-traversal / control chars (pinned by TC-18/TC-19)
# but MUST keep ACCEPTING non-UUID opaque sids. pre-compact.test.sh TC-per-session-compact-independence-AC1 sets
# CLAUDE_CODE_SESSION_ID="session-aaaa-1371" and relies on `flow-state.sh path` resolving it to a
# per-session file. If this were ever routed through `_resolve-session-id.sh` (strict RFC 4122 /
# Layer 2), such sids would degrade to legacy fallback and the dependent tests would go SILENTLY
# vacuous. These positive assertions convert that silent-vacuous risk into a loud failure.
# SoT: references/session-id-validation-contract.md.
echo ""
echo "=== TC-24: non-UUID opaque session_id accepted (format-agnostic Layer 1 contract pin) ==="
opaque="session-aaaa-1371"

# TC-24.1: env-var (CLAUDE_CODE_SESSION_ID) — the exact at-risk path from pre-compact.test.sh
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$opaque" \
  bash "$HOOK" set --phase implement --issue 1383 --branch "refactor/issue-1383" --pr 0 --next "n") 2>&1 || true )
state_file="$d/.rite/sessions/${opaque}.flow-state"
if [ -f "$state_file" ]; then
  pass "TC-24.1: set accepts non-UUID env sid → .rite/sessions/${opaque}.flow-state"
else
  fail "TC-24.1: non-UUID env sid rejected/degraded (no per-session file). stderr: '$err'"
fi
got=$(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$opaque" bash "$HOOK" get --field phase --default "MISS")
assert "TC-24.1b: phase round-trips under non-UUID sid" "implement" "$got"

# TC-24.2: `path` resolves the non-UUID sid to the per-session file (not a legacy fallback path)
got_path=$( (cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$opaque" bash "$HOOK" path) 2>/dev/null || true )
case "$got_path" in
  */.rite/sessions/"${opaque}".flow-state)
    pass "TC-24.2: path resolves non-UUID sid to per-session file (no Layer 2 strict downgrade)" ;;
  *)
    fail "TC-24.2: path did not resolve to per-session file for non-UUID sid: '$got_path'" ;;
esac

# TC-24.3: SESSION_ID_FILE (.rite-session-id) content path also accepts non-UUID
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
printf '%s\n' "$opaque" > "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  bash "$HOOK" set --phase plan --issue 1383 --branch "b" --pr 0 --next "n") 2>&1 || true )
if [ -f "$d/.rite/sessions/${opaque}.flow-state" ]; then
  pass "TC-24.3: SESSION_ID_FILE non-UUID content accepted → per-session file"
else
  fail "TC-24.3: SESSION_ID_FILE non-UUID content rejected/degraded. stderr: '$err'"
fi

# TC-24.4: --session override path also accepts non-UUID (4-source symmetry with TC-18/TC-19)
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
rm -f "$d/.rite-session-id"
err=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  bash "$HOOK" set --session "$opaque" --phase review --issue 1383 --branch "b" --pr 0 --next "n") 2>&1 || true )
if [ -f "$d/.rite/sessions/${opaque}.flow-state" ]; then
  pass "TC-24.4: --session override non-UUID accepted → per-session file"
else
  fail "TC-24.4: --session override non-UUID rejected/degraded. stderr: '$err'"
fi

# --- TC-25: clear-worktree subcommand (Issue #1524) ---
# Surgical del(.worktree) mirroring cmd_deactivate: removes only the worktree key,
# preserves phase/active/branch, idempotent (no-op + no file churn when absent),
# non-blocking on a missing state file. Used by pr-cycle-cleanup.sh reap null-ing
# and session-start.sh dangling self-heal.
echo ""
echo "=== TC-25: clear-worktree removes worktree key, preserves others, idempotent ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && bash "$HOOK" set --phase implement --issue 1524 --branch "fix/issue-1524" --pr 0 --next "n" \
  --worktree "$d/.rite/worktrees/issue-1524")
sfile="$d/.rite/sessions/${sid}.flow-state"
assert "TC-25: worktree set via cmd_set" "$d/.rite/worktrees/issue-1524" "$(jq -r '.worktree // "ABSENT"' "$sfile")"
(cd "$d" && bash "$HOOK" clear-worktree)
assert "TC-25: worktree key removed" "false" "$(jq -r 'has("worktree")' "$sfile")"
assert "TC-25: phase preserved" "implement" "$(jq -r '.phase' "$sfile")"
assert "TC-25: active preserved" "true" "$(jq -r '.active' "$sfile")"
assert "TC-25: branch preserved" "fix/issue-1524" "$(jq -r '.branch' "$sfile")"
# Idempotent: re-clearing is a no-op (rc 0) AND must NOT rewrite the file (no
# updated_at churn → wm-sync diff guard stays quiet). Pin updated_at to a known
# PAST value after the first clear, then re-clear: the has("worktree") early-return
# guard means the second clear performs no write, so updated_at MUST stay pinned.
# (A `before==after` cat compare would NOT catch guard removal — the rewritten
# updated_at would equal the original within the same wall-clock second. Pinning a
# past value makes the assertion non-vacuous regardless of second-boundary timing.)
pin_ts="2020-01-01T00:00:00Z"
tmp_pin=$(mktemp); jq --arg ts "$pin_ts" '.updated_at = $ts' "$sfile" > "$tmp_pin" && mv "$tmp_pin" "$sfile"
(cd "$d" && bash "$HOOK" clear-worktree); rc=$?
assert "TC-25: idempotent re-clear rc=0" "0" "$rc"
assert "TC-25: idempotent re-clear performs no write (updated_at stays pinned)" "$pin_ts" "$(jq -r '.updated_at' "$sfile")"
# Non-blocking on a missing state file: resolving a sid with no file returns rc 0.
miss_rc=$( (cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  bash "$HOOK" clear-worktree --session "no-such-session-1524" >/dev/null 2>&1); echo $? )
assert "TC-25: clear-worktree on missing state file is non-blocking (rc 0)" "0" "$miss_rc"

# --- TC-26: --require-worktree data-layer detection marker (Issue #1595) ---
echo ""
echo "=== TC-26: --require-worktree emits WORKTREE_INVARIANT detection marker ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
sfile="$d/.rite/sessions/${sid}.flow-state"
# (a) worktree absent + --require-worktree → WORKTREE_INVARIANT=missing + WARNING, but write completes (non-blocking)
out_missing=$( (cd "$d" && bash "$HOOK" set --phase branch --issue 1595 --branch "fix/issue-1595" --pr 0 --next "n" --require-worktree) 2>&1 )
assert "TC-26: missing → WORKTREE_INVARIANT=missing marker" "missing" "$(echo "$out_missing" | grep -o 'WORKTREE_INVARIANT=[a-z]*' | head -1 | cut -d= -f2)"
assert "TC-26: missing → loud WARNING emitted" "1" "$(echo "$out_missing" | grep -c 'require-worktree set but worktree path is empty')"
assert "TC-26: missing → write still completes (phase recorded, non-blocking)" "branch" "$(jq -r '.phase' "$sfile")"
assert "TC-26: missing → no worktree key written" "false" "$(jq -r 'has("worktree")' "$sfile")"
# (b) worktree present + --require-worktree → WORKTREE_INVARIANT=ok, worktree recorded
out_ok=$( (cd "$d" && bash "$HOOK" set --phase branch --issue 1595 --branch "fix/issue-1595" --pr 0 --next "n" --worktree "$d/.rite/worktrees/issue-1595" --require-worktree) 2>&1 )
assert "TC-26: present → WORKTREE_INVARIANT=ok marker" "ok" "$(echo "$out_ok" | grep -o 'WORKTREE_INVARIANT=[a-z]*' | head -1 | cut -d= -f2)"
assert "TC-26: present → worktree path recorded" "$d/.rite/worktrees/issue-1595" "$(jq -r '.worktree // "ABSENT"' "$sfile")"
assert "TC-26: present → write completes (phase recorded, symmetric with case a)" "branch" "$(jq -r '.phase' "$sfile")"
# (c) backward compat: without --require-worktree → NO marker (unchanged behavior)
out_plain=$( (cd "$d" && bash "$HOOK" set --phase branch --issue 1595 --branch "fix/issue-1595" --pr 0 --next "n") 2>&1 )
assert "TC-26: backward compat → no WORKTREE_INVARIANT marker without flag" "0" "$(echo "$out_plain" | grep -c 'WORKTREE_INVARIANT')"

# --- TC-27: cycle_count is a merge-preserved additive field (#1701 review⇄fix circuit breaker) ---
echo ""
echo "=== TC-27: --cycle-count merge-preserve + reset (review⇄fix circuit breaker) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
sfile="$d/.rite/sessions/${sid}.flow-state"
# (a) set --cycle-count 3 → recorded
(cd "$d" && bash "$HOOK" set --phase review --issue 700 --branch "feat/700" --pr 42 --next "n" --cycle-count 3) >/dev/null
assert "TC-27: cycle_count=3 recorded" "3" "$(jq -r '.cycle_count // "ABSENT"' "$sfile")"
assert "TC-27: get returns 3" "3" "$(cd "$d" && bash "$HOOK" get --field cycle_count --default 0)"
# (b) merge-preserve: a set WITHOUT --cycle-count (e.g. review/fix phase transition) keeps the value
(cd "$d" && bash "$HOOK" set --phase fix --issue 700 --branch "feat/700" --pr 42 --next "n2") >/dev/null
assert "TC-27: cycle_count preserved across --cycle-count-less set" "3" "$(jq -r '.cycle_count // "ABSENT"' "$sfile")"
# (c) a later set overwrites cycle_count with a new value (increment is the caller's job, not the hook's)
(cd "$d" && bash "$HOOK" set --phase review --issue 700 --branch "feat/700" --pr 42 --next "n3" --cycle-count 4) >/dev/null
assert "TC-27: later set overwrites cycle_count to a new value (increment scenario)" "4" "$(jq -r '.cycle_count // "ABSENT"' "$sfile")"
# (d) reset with --cycle-count 0 removes the key (get falls back to default; fresh-entry reset)
(cd "$d" && bash "$HOOK" set --phase review --issue 700 --branch "feat/700" --pr 42 --next "n4" --cycle-count 0) >/dev/null
assert "TC-27: --cycle-count 0 removes the key" "false" "$(jq -r 'has("cycle_count")' "$sfile")"
assert "TC-27: get after reset returns default 0" "0" "$(cd "$d" && bash "$HOOK" get --field cycle_count --default 0)"
# (d2) reset while OMITTING issue/branch/pr (the actual iterate ステップ0.6 fresh-reset call shape):
#      --cycle-count 0 removes the key AND merge-preserve keeps issue/branch intact
(cd "$d" && bash "$HOOK" set --phase review --issue 700 --branch "feat/700" --pr 42 --next "seed" --cycle-count 3) >/dev/null
(cd "$d" && bash "$HOOK" set --phase review --next "fresh reset" --cycle-count 0) >/dev/null
assert "TC-27: reset with issue/branch omitted removes cycle_count key" "false" "$(jq -r 'has("cycle_count")' "$sfile")"
assert "TC-27: reset merge-preserves issue_number" "700" "$(jq -r '.issue_number' "$sfile")"
assert "TC-27: reset merge-preserves branch" "feat/700" "$(jq -r '.branch' "$sfile")"
# (e) backward compat: a fresh session that never sets --cycle-count has no cycle_count key
result=$(new_sandbox); d2="${result%|*}"; sid2="${result#*|}"
sfile2="$d2/.rite/sessions/${sid2}.flow-state"
(cd "$d2" && bash "$HOOK" set --phase branch --issue 701 --branch "feat/701" --pr 0 --next "n") >/dev/null
assert "TC-27: backward compat → no cycle_count key without --cycle-count" "false" "$(jq -r 'has("cycle_count")' "$sfile2")"

# --- TC-28: wm_comment_id is merge-preserved across cmd_set (#1810) ---
# wm_comment_id has NO --flag — it's written directly by issue-comment-wm-sync.sh's
# cache_comment_id() via `jq '. + {wm_comment_id: ...}'`, mirroring how post-tool-wm-sync.sh
# writes last_synced_phase. Repro: cache_comment_id writes the field, then any other skill's
# ordinary phase-transition `set` (no wm_comment_id awareness) must NOT wipe it.
echo ""
echo "=== TC-28: wm_comment_id merge-preserve across ordinary phase-transition set ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
sfile="$d/.rite/sessions/${sid}.flow-state"
(cd "$d" && bash "$HOOK" set --phase init --issue 1810 --branch "" --pr 0 --next "n") >/dev/null
# simulate cache_comment_id() writing directly to the state file
jq '. + {wm_comment_id: 999888}' "$sfile" > "$sfile.tmp" && mv "$sfile.tmp" "$sfile"
assert "TC-28: wm_comment_id=999888 written directly" "999888" "$(jq -r '.wm_comment_id // "ABSENT"' "$sfile")"
# an ordinary phase-transition set (no wm_comment_id flag exists) must preserve it
(cd "$d" && bash "$HOOK" set --phase branch --issue 1810 --branch "fix/issue-1810" --pr 0 --next "n2") >/dev/null
assert "TC-28: wm_comment_id preserved across unrelated phase-transition set" "999888" "$(jq -r '.wm_comment_id // "ABSENT"' "$sfile")"
assert "TC-28: phase transition itself still applied" "branch" "$(jq -r '.phase' "$sfile")"
# backward compat: a fresh session that never had wm_comment_id written has no such key
result=$(new_sandbox); d2="${result%|*}"; sid2="${result#*|}"
sfile2="$d2/.rite/sessions/${sid2}.flow-state"
(cd "$d2" && bash "$HOOK" set --phase branch --issue 1811 --branch "feat/1811" --pr 0 --next "n") >/dev/null
assert "TC-28: backward compat → no wm_comment_id key when never written" "false" "$(jq -r 'has("wm_comment_id")' "$sfile2")"
# write-time failure: a corrupted (non-numeric) wm_comment_id already on disk must make the
# unrelated set fail loud (rc!=0) via tonumber, not silently succeed with a wiped/garbage value
result=$(new_sandbox); d3="${result%|*}"; sid3="${result#*|}"
sfile3="$d3/.rite/sessions/${sid3}.flow-state"
(cd "$d3" && bash "$HOOK" set --phase init --issue 1812 --branch "" --pr 0 --next "n") >/dev/null
jq '. + {wm_comment_id: "not-a-number"}' "$sfile3" > "$sfile3.tmp" && mv "$sfile3.tmp" "$sfile3"
corrupt_set_rc=0
(cd "$d3" && bash "$HOOK" set --phase branch --issue 1812 --branch "fix/issue-1812" --pr 0 --next "n2") >/dev/null 2>&1 || corrupt_set_rc=$?
assert "TC-28: corrupt non-numeric wm_comment_id makes unrelated set fail (rc!=0)" "1" "$corrupt_set_rc"
# security fix (cycle 2 #1810): the write-side jq stderr (which quotes the corrupt raw value)
# must go through the same _emit_jq_err_snippet / neutralize_ctrl convention as the read side,
# not straight to the terminal unneutralized. Same TC-23.2 pattern: inject an ESC byte and
# assert it never reaches stderr raw.
result=$(new_sandbox); d4="${result%|*}"; sid4="${result#*|}"
sfile4="$d4/.rite/sessions/${sid4}.flow-state"
(cd "$d4" && bash "$HOOK" set --phase init --issue 1813 --branch "" --pr 0 --next "n") >/dev/null
esc=$(printf '\033')
jq --arg v "${esc}[31mnot-a-number" '. + {wm_comment_id: $v}' "$sfile4" > "$sfile4.tmp" && mv "$sfile4.tmp" "$sfile4"
corrupt_set_stderr=$( (cd "$d4" && bash "$HOOK" set --phase branch --issue 1813 --branch "fix/issue-1813" --pr 0 --next "n2") 2>&1 1>/dev/null || true )
if printf '%s' "$corrupt_set_stderr" | LC_ALL=C grep -q "$esc"; then
  fail "TC-28: corrupt wm_comment_id 由来の生 ESC が write エラー出力に残存 (control-char 中和が機能していない): '$(printf '%s' "$corrupt_set_stderr" | cat -v)'"
else
  pass "TC-28: corrupt wm_comment_id 由来の write エラー出力の生 ESC が中和されている"
fi

# --- T-01: AC-1 — distinct env CLAUDE_CODE_SESSION_ID → distinct per-session state files ---
echo ""
echo "=== T-01: AC-1 concurrent sessions sharing one state root stay isolated by env ==="
# Two sessions share one state root (the main checkout) but carry different
# CLAUDE_CODE_SESSION_ID. With env-first resolution each writes/reads its OWN
# {sid}.flow-state, so session B cannot contaminate session A's issue/phase.
result=$(new_sandbox); d="${result%|*}"
rm -f "$d/.rite-session-id"  # force env-first path (no shared fallback file)
sidA="aaaaaaaa-1111-2222-3333-444444444444"
sidB="bbbbbbbb-5555-6666-7777-888888888888"
(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sidA" bash "$HOOK" set --phase implement --issue 101 --branch "feat/a" --pr 0 --next "a")
(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sidB" bash "$HOOK" set --phase review --issue 202 --branch "feat/b" --pr 0 --next "b")
fileA="$d/.rite/sessions/${sidA}.flow-state"
fileB="$d/.rite/sessions/${sidB}.flow-state"
assert_file_exists_or_fail "T-01: session A state file exists" "$fileA" || true
assert_file_exists_or_fail "T-01: session B state file exists" "$fileB" || true
assert "T-01: session A issue isolated" "101" "$(jq -r .issue_number "$fileA")"
assert "T-01: session B issue isolated" "202" "$(jq -r .issue_number "$fileB")"
gotA=$(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$sidA" bash "$HOOK" get --field issue_number --default "X")
assert "T-01: session A read not contaminated by session B" "101" "$gotA"

# --- T-02: AC-3 — env-absent runtime falls back to .rite-session-id file ---
echo ""
echo "=== T-02: AC-3 env-absent → .rite-session-id file fallback (backward compat) ==="
result=$(new_sandbox); d="${result%|*}"; sid="${result#*|}"
(cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" set --phase plan --issue 303 --branch "feat/c" --pr 0 --next "c")
sfile="$d/.rite/sessions/${sid}.flow-state"
assert_file_exists_or_fail "T-02: fallback state file keyed by .rite-session-id sid" "$sfile" || true
got=$(cd "$d" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" get --field issue_number --default "X")
assert "T-02: env-absent get resolves via .rite-session-id file" "303" "$got"

# --- T-04: AC-1 — env wins when env CLAUDE_CODE_SESSION_ID and .rite-session-id differ ---
echo ""
echo "=== T-04: env CLAUDE_CODE_SESSION_ID takes precedence over a differing .rite-session-id ==="
# This is the regression guard for the precedence flip: file present (filesid) AND
# env present (envsid) but different → state MUST be written under envsid, not filesid.
result=$(new_sandbox); d="${result%|*}"; filesid="${result#*|}"
envsid="cccccccc-9999-0000-1111-222222222222"
(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$envsid" bash "$HOOK" set --phase fix --issue 404 --branch "feat/d" --pr 0 --next "d")
env_file="$d/.rite/sessions/${envsid}.flow-state"
file_file="$d/.rite/sessions/${filesid}.flow-state"
assert_file_exists_or_fail "T-04: state written under ENV sid (env wins)" "$env_file" || true
if [ -f "$file_file" ]; then
  fail "T-04: state must NOT be written under .rite-session-id file sid when env present"
else
  pass "T-04: file-sid state correctly absent (env took precedence over file)"
fi
# Smoke check only — NOT a precedence guard. The precedence flip is pinned by the two
# asserts above (env_file present + file_file absent); this end-to-end get would stay
# green even under the old file-first ordering (set writes filesid, get reads filesid).
got=$(cd "$d" && env -u CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID="$envsid" bash "$HOOK" get --field issue_number --default "X")
assert "T-04: get resolves via env sid (404, smoke)" "404" "$got"

if ! print_summary "$(basename "$0")" "flow-state.sh PR 2a refactor + silent-failure fixes + security/observability hardening + handoff marker + consume-handoff corrupt-read WARNING + jq stderr snippet control-char neutralization + C1 8-bit coverage via shared neutralize_ctrl + --worktree merge-preserve field + clear-worktree surgical del (Issue #1524) + non-UUID acceptance (Layer 1 format-agnostic contract pin)"; then
  exit 1
fi
