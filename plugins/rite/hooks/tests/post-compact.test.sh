#!/bin/bash
# Tests for post-compact.sh (PostCompact hook)
# Usage: bash plugins/rite/hooks/tests/post-compact.test.sh
set -euo pipefail

issue_text() { printf 'Issue #%s' "$1"; }

# Hermeticity guard: flow-state.sh path resolves session_id with
# priority env CLAUDE_CODE_SESSION_ID > env CLAUDE_SESSION_ID > .rite-session-id
# file. When this test suite runs inside a live Claude Code
# session, that session's own id leaks into every `bash "$HOOK"` invocation
# below and silently overrides the file-based per-session fixtures written by
# write_per_session_state(), making the hook resolve a nonexistent (or wrong)
# flow-state file and exit with empty output. Unsetting both here forces every
# invocation to resolve session_id from the fixture's `.rite-session-id` file,
# matching the intended test isolation.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-compact.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Prerequisite check: jq is required
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

setup_test() {
  local test_cwd="$TEST_DIR/$1"
  mkdir -p "$test_cwd"
  # Create minimal state-path-resolve.sh mock
  mkdir -p "$test_cwd/.git"
  echo "$test_cwd"
}

# Helper: write a per-session flow-state file (schema v3) for the given dir.
# Returns nothing; writes .rite-session-id + .rite/sessions/<sid>.flow-state.
# Auto-injects schema_version=3 if missing so flow-state.sh migrate (run by
# session-start.sh, but not post-compact.sh) does not silently rewrite the
# fixture mid-test. For post-compact.sh specifically the migrate step is not
# invoked, but the helper keeps the schema-version contract consistent with
# the other hooks' tests.
write_per_session_state() {
  local dir="$1"
  local content="$2"
  local sid="${3:-test-sid-$(basename "$dir")}"
  mkdir -p "$dir/.rite/sessions"
  printf '%s' "$sid" > "$dir/.rite-session-id"
  local merged
  if printf '%s' "$content" | grep -q '"schema_version"'; then
    merged="$content"
  elif printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    merged=$(printf '%s' "$content" | jq -c '. + {schema_version: 3}')
  else
    merged="$content"
  fi
  printf '%s\n' "$merged" > "$dir/.rite/sessions/${sid}.flow-state"
}

# Helper: path to the per-session compact-state file. Mirrors
# post-compact.sh's derivation: .rite/sessions/<sid>.flow-state → .compact-state.
compact_state_path() {
  local dir="$1"
  local sid="${2:-test-sid-$(basename "$dir")}"
  echo "$dir/.rite/sessions/${sid}.compact-state"
}

# Helper: register a per-session id WITHOUT a flow-state file. Used by cleanup
# tests that need a deterministic per-session compact-state path but no active
# (or any) flow-state file.
write_session_id_only() {
  local dir="$1"
  local sid="${2:-test-sid-$(basename "$dir")}"
  mkdir -p "$dir/.rite/sessions"
  printf '%s' "$sid" > "$dir/.rite-session-id"
}

echo "=== post-compact.sh tests ==="

# --- TC-001: active flow + recovering → stdout output + normal transition ---
echo "TC-001: Active flow + recovering → auto-recovery"
TC_DIR=$(setup_test "tc001")
write_per_session_state "$TC_DIR" \
  '{"active": true, "issue_number": 42, "phase": "implement", "next_action": "Continue coding", "loop_count": 1, "pr_number": 10, "branch": "feat/issue-42-test"}'
CS_TC001="$(compact_state_path "$TC_DIR")"
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-03-14T12:00:00Z", active_issue: 42}' > "$CS_TC001"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Auto-compact recovery"; then
  pass "stdout contains auto-recovery message"
else
  fail "stdout missing auto-recovery message: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "$(issue_text 42)"; then
  pass "stdout contains issue number"
else
  fail "stdout missing issue number"
fi
COMPACT_VAL=$(jq -r '.compact_state' "$CS_TC001" 2>/dev/null) || COMPACT_VAL=""
if [ "$COMPACT_VAL" = "normal" ]; then
  pass "compact_state transitioned to normal"
else
  fail "compact_state is '$COMPACT_VAL', expected 'normal'"
fi

# --- TC-002: manual compact → state re-injection only ---
echo "TC-002: Manual compact → no auto-continue instruction"
TC_DIR=$(setup_test "tc002")
write_per_session_state "$TC_DIR" \
  '{"active": true, "issue_number": 42, "phase": "review", "next_action": "Review PR", "loop_count": 0, "pr_number": 5, "branch": "feat/issue-42-test"}'
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-03-14T12:00:00Z", active_issue: 42}' > "$(compact_state_path "$TC_DIR")"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "manual"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Compact recovery"; then
  pass "stdout contains recovery message for manual"
else
  fail "stdout missing recovery message: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "Auto-compact recovery"; then
  fail "manual should not contain auto-compact recovery"
else
  pass "manual does not contain auto-compact recovery"
fi

# --- TC-003: no flow state → cleanup + no stdout ---
echo "TC-003: No flow state → cleanup, no output"
TC_DIR=$(setup_test "tc003")
# Register a session id (no flow-state file) so the per-session compact-state
# path is deterministic; the missing flow-state drives the cleanup branch.
write_session_id_only "$TC_DIR"
CS_TC003="$(compact_state_path "$TC_DIR")"
jq -n '{compact_state: "recovering"}' > "$CS_TC003"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output"
else
  fail "unexpected stdout: $OUTPUT"
fi
if [ ! -f "$CS_TC003" ]; then
  pass "compact state cleaned up"
else
  fail "compact state not cleaned up"
fi

# --- TC-004: active=false → cleanup + no stdout ---
echo "TC-004: Active=false → cleanup, no output"
TC_DIR=$(setup_test "tc004")
write_per_session_state "$TC_DIR" '{"active": false, "issue_number": 42}'
CS_TC004="$(compact_state_path "$TC_DIR")"
jq -n '{compact_state: "recovering"}' > "$CS_TC004"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output"
else
  fail "unexpected stdout: $OUTPUT"
fi
if [ ! -f "$CS_TC004" ]; then
  pass "compact state cleaned up"
else
  fail "compact state not cleaned up"
fi

# --- TC-005: compact_state=normal → no action ---
echo "TC-005: compact_state=normal → no action"
TC_DIR=$(setup_test "tc005")
write_per_session_state "$TC_DIR" '{"active": true, "issue_number": 42}'
jq -n '{compact_state: "normal"}' > "$(compact_state_path "$TC_DIR")"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "no stdout output for normal state"
else
  fail "unexpected stdout: $OUTPUT"
fi

# --- TC-per-session-detect-A (AC-LOCAL-2): per-session active=true + recovering → recovery output ---
# Verifies post-compact reads & writes the per-session file (not legacy) when
# a valid SID + per-session file exists, and that the
# `.active=true` precondition path still triggers recovery.
echo "TC-per-session-detect-A (AC-LOCAL-2): per-session + recovering → auto-recovery from per-session file"
TC_DIR=$(setup_test "tc680a")
sid680a="aaaabbbb-cccc-dddd-eeee-ffffaaaa1111"
mkdir -p "$TC_DIR/.rite/sessions"
echo "$sid680a" > "$TC_DIR/.rite-session-id"
printf '# rite test sandbox config\n' > "$TC_DIR/rite-config.yml"
per_session_file="$TC_DIR/.rite/sessions/${sid680a}.flow-state"
jq -n '{active: true, issue_number: 680, phase: "phase5_review", next_action: "review", loop_count: 0, pr_number: 0, branch: "refactor/issue-680-test", session_id: "'"$sid680a"'"}' > "$per_session_file"
cs680a="$(compact_state_path "$TC_DIR" "$sid680a")"
jq -n '{compact_state: "recovering", compact_state_set_at: "2026-04-30T12:00:00Z", active_issue: 680}' > "$cs680a"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if echo "$OUTPUT" | grep -q "Auto-compact recovery" && echo "$OUTPUT" | grep -q "$(issue_text 680)"; then
  pass "TC-per-session-detect-A: recovery output read from per-session file (.active=true preserved)"
else
  fail "TC-per-session-detect-A: expected Auto-compact recovery for $(issue_text 680) from per-session, got: $OUTPUT"
fi
# Counter-assertion: compact_state transitioned to normal
cs_state=$(jq -r '.compact_state' "$cs680a" 2>/dev/null)
if [ "$cs_state" = "normal" ]; then
  pass "TC-per-session-detect-A: compact_state transitioned to normal after per-session recovery"
else
  fail "TC-per-session-detect-A: compact_state expected 'normal', got '$cs_state'"
fi

# --- TC-per-session-detect-B: per-session active=false + recovering → cleanup ---
echo "TC-per-session-detect-B: per-session active=false → cleanup (no recovery)"
TC_DIR=$(setup_test "tc680b")
sid680b="22222222-3333-4444-5555-666666666666"
mkdir -p "$TC_DIR/.rite/sessions"
echo "$sid680b" > "$TC_DIR/.rite-session-id"
printf '# rite test sandbox config\n' > "$TC_DIR/rite-config.yml"
jq -n '{active: false, issue_number: 681}' > "$TC_DIR/.rite/sessions/${sid680b}.flow-state"
cs680b="$(compact_state_path "$TC_DIR" "$sid680b")"
jq -n '{compact_state: "recovering"}' > "$cs680b"

OUTPUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>/dev/null) || true
if [ -z "$OUTPUT" ]; then
  pass "TC-per-session-detect-B: per-session active=false → no recovery output (silent exit)"
else
  fail "TC-per-session-detect-B: expected silent exit on active=false, got: $OUTPUT"
fi
if [ ! -f "$cs680b" ]; then
  pass "TC-per-session-detect-B: compact_state cleaned up on per-session inactive flow"
else
  fail "TC-per-session-detect-B: compact_state not cleaned up"
fi

echo ""

# --------------------------------------------------------------------------
# TC-helper-failure-stderr-passthrough (AC-1 / AC-LOCAL-1)
# --------------------------------------------------------------------------
echo "TC-helper-failure-stderr-passthrough: helper failure → ERROR pass-through + skip WARNING"

HOOKS_REAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
sbx_749="$(mktemp -d "$TEST_DIR/sbx-hooks-XXXXXX")"
cp -a "$HOOKS_REAL_DIR/." "$sbx_749/"
cat > "$sbx_749/flow-state.sh" <<'FAKE_RESOLVER_EOF'
#!/bin/bash
echo "ERROR: TC-helper-failure simulated flow-state.sh path failure" >&2
exit 1
FAKE_RESOLVER_EOF
chmod +x "$sbx_749/flow-state.sh"

# post-compact.sh exits early when no flow_state — the TC only validates stderr
# pass-through, not the legacy fallback (which was removed in PR 2a / Phase F-3).
dir_749="$TEST_DIR/tc749-passthrough"
mkdir -p "$dir_749"

stderr_file="$(mktemp "$TEST_DIR/stderr.749.XXXXXX")"
echo "{\"cwd\": \"$dir_749\", \"source\": \"auto\"}" \
  | bash "$sbx_749/post-compact.sh" >/dev/null 2>"$stderr_file" || true
stderr_749="$(cat "$stderr_file")"

if printf '%s' "$stderr_749" | grep -qF 'TC-helper-failure simulated flow-state.sh path failure'; then
  pass "ERROR line from flow-state.sh passed through to caller stderr"
else
  fail "Expected ERROR pass-through; got stderr: $stderr_749"
fi
# PR 2a refactor (Phase F-3): the legacy fallback was removed. post-compact now
# emits a "flow-state.sh path resolution failed — skip" WARNING and aborts the
# recovery branch. The previous "Legacy fallback path was loaded" assertion was
# removed accordingly.
if printf '%s' "$stderr_749" | grep -qF 'flow-state.sh path resolution failed'; then
  pass "Skip WARNING emitted to stderr (no legacy fallback in v3)"
else
  fail "Expected skip WARNING; got stderr: $stderr_749"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────
# Reconciliation block runtime coverage (PR != 0 path).
# The reconciliation block surfaces distinct root-cause tokens in plain WARNINGs
# (state_root_inaccessible / state_root_toctou_race / pr_deleted_or_inaccessible
# / post_compact_gh_pr_view_failed / post_compact_gh_repo_view_failed /
# post_compact_reconciliation_failed) but none of the prior TCs set pr_number
# to a non-zero value, so the entire block is otherwise dark. Exercise it with
# a PATH-injected gh / projects-status-update.sh mock so a misclassification
# refactor fails here instead of in production.
# ──────────────────────────────────────────────────────────────────────────

_setup_recon_env() {
  local label="$1" gh_behavior="$2" reconcile_result="${3:-updated}" git_remote_url="${4:-}"
  local dir="$TEST_DIR/recon-$label"
  mkdir -p "$dir/bin"
  if [ -n "$git_remote_url" ]; then
    # Real git repo (not the `mkdir -p .git` non-repo stub below) so
    # resolve_owner_repo() can actually parse `origin` — used by TC-RECON-09
    # to exercise the git-remote fast path's *success* case at the caller
    # level, instead of always falling through to the gh repo view mock.
    ( cd "$dir" && git init -q && git remote add origin "$git_remote_url" )
  else
    mkdir -p "$dir/.git"
  fi
  # flow-state with pr_number=42 → reconciliation block enters
  write_per_session_state "$dir" \
    '{"active": true, "issue_number": 42, "phase": "ready", "next_action": "Ready", "loop_count": 0, "pr_number": 42, "branch": "feat/issue-42-recon"}'
  jq -n '{compact_state: "recovering", compact_state_set_at: "2026-04-01T00:00:00Z", active_issue: 42}' \
    > "$(compact_state_path "$dir")"
  # Minimal rite-config so awk projects.enabled detection picks up `true`
  cat > "$dir/rite-config.yml" <<'YAML'
github:
  projects:
    enabled: true
    project_number: 1
YAML

  case "$gh_behavior" in
    pr_view_404)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "could not resolve to a PullRequest with the number of 42" >&2; exit 1 ;;
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "api graphql") echo "Todo" ;;
  *) exit 0 ;;
esac
EOF
      ;;
    pr_view_403)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "HTTP 403: rate limit exceeded" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
      ;;
    repo_view_fail)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "false" ;;
  "repo view") echo "auth required" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
      ;;
    happy)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "false" ;;
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "api graphql") echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"In Review"}]}}]}}}}}' ;;
  *) exit 0 ;;
esac
EOF
      ;;
    git_remote_bypass)
      # `repo view` is deliberately broken — if git-remote resolution didn't
      # actually run (or silently fell through to this fallback), the
      # reconciliation block would surface post_compact_gh_repo_view_failed.
      # `pr view` / `api graphql` additionally assert the *correct* resolved
      # value (o/r, from the host-alias origin below) is what's actually
      # passed through — without this, a regression that drops the
      # `cd "$STATE_ROOT"` anchor (this dogfood repo's own ambient origin
      # happens to also resolve successfully, just to the wrong repo) would
      # silently pass this fixture. See MOCK ASSERTION FAILED handling below.
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view")
    if ! printf '%s\n' "$*" | grep -q -- '--repo o/r'; then
      echo "MOCK ASSERTION FAILED: expected --repo o/r, got: $*" >&2
      exit 1
    fi
    echo "false"
    ;;
  "repo view") echo "auth required (should not be called — git-remote should resolve first)" >&2; exit 1 ;;
  "api graphql")
    if ! { printf '%s\n' "$*" | grep -q -- '-f owner=o' && printf '%s\n' "$*" | grep -q -- '-f repo=r'; }; then
      echo "MOCK ASSERTION FAILED: expected -f owner=o -f repo=r, got: $*" >&2
      exit 1
    fi
    echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"In Review"}]}}]}}}}}'
    ;;
  *) exit 0 ;;
esac
EOF
      ;;
    mismatch_then_reconcile)
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "false" ;;
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "api graphql") echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Todo"}]}}]}}}}}' ;;
  *) exit 0 ;;
esac
EOF
      ;;
    cancelled_terminal)
      # Board sits on Cancelled — a terminal Status
      # (references/projects-integration.md, "Terminal Status Set"). The PR is Ready, so
      # every other condition for the mismatch branch holds; only the terminal exclusion
      # keeps this row from being dragged back to In Review.
      cat > "$dir/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view") echo "false" ;;
  "repo view") echo '{"owner":{"login":"o"},"name":"r"}' ;;
  "api graphql") echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":1},"fieldValues":{"nodes":[{"field":{"name":"Status"},"name":"Cancelled"}]}}]}}}}}' ;;
  *) exit 0 ;;
esac
EOF
      ;;
  esac
  chmod +x "$dir/bin/gh"

  # Mock projects-status-update.sh — return failure when reconcile_result=failed,
  # otherwise return JSON the reconciliation block expects.
  cat > "$dir/bin/projects-status-update.sh" <<EOF
#!/bin/bash
echo '{"result":"$reconcile_result"}'
EOF
  chmod +x "$dir/bin/projects-status-update.sh"

  echo "$dir"
}

# TC-RECON-02: pr_deleted_or_inaccessible classification (false-positive guard)
echo "TC-RECON-02: gh pr view 'could not resolve PullRequest' → pr_deleted_or_inaccessible classification"
recon_dir=$(_setup_recon_env "pr-deleted" "pr_view_404")
recon_stderr="$(mktemp "$TEST_DIR/recon-pr-deleted-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'pr_deleted_or_inaccessible' "$recon_stderr"; then
  pass "pr_deleted_or_inaccessible root cause hint set (not gh_pr_view_failed)"
else
  fail "expected pr_deleted_or_inaccessible hint; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi
if grep -qE 'post_compact_gh_pr_view_failed' "$recon_stderr"; then
  fail "post_compact_gh_pr_view_failed wrongly emitted for closed-PR case"
else
  pass "post_compact_gh_pr_view_failed NOT emitted for closed-PR case"
fi

# TC-RECON-03: distinguish gh_pr_view_failed (HTTP 403) from pr_deleted
echo "TC-RECON-03: gh pr view 'HTTP 403 rate limit' → post_compact_gh_pr_view_failed classification"
recon_dir=$(_setup_recon_env "pr-403" "pr_view_403")
recon_stderr="$(mktemp "$TEST_DIR/recon-pr-403-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'post_compact_gh_pr_view_failed' "$recon_stderr"; then
  pass "post_compact_gh_pr_view_failed emitted for 403 case"
else
  fail "expected post_compact_gh_pr_view_failed; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi
if grep -qE 'pr_deleted_or_inaccessible' "$recon_stderr"; then
  fail "pr_deleted_or_inaccessible wrongly emitted for 403 case (classification leak)"
else
  pass "pr_deleted_or_inaccessible NOT emitted for 403 case (no classification leak)"
fi

# TC-RECON-04: mktemp degradation surfaces stderr_capture=disabled
echo "TC-RECON-04: mktemp failure tags stderr_capture=disabled in emitted incident"
recon_dir=$(_setup_recon_env "mktemp-fail" "pr_view_403")
# Shadow mktemp to fail only for the pr_view tempfile pattern
cat > "$recon_dir/bin/mktemp" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    # 本番は ${TMPDIR:-/tmp}/rite-pc-pr-err-XXXXXX を渡すため、
    # sandbox (TMPDIR 設定) 環境でも intercept できるよう両形にマッチさせる
    /tmp/rite-pc-pr-err-*|"${TMPDIR:-/tmp}"/rite-pc-pr-err-*) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$recon_dir/bin/mktemp"
recon_stderr="$(mktemp "$TEST_DIR/recon-mktemp-fail-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'mktemp failed for pr_view_err' "$recon_stderr"; then
  pass "WARNING fired for pr_view_err mktemp failure"
else
  fail "missing pr_view_err mktemp WARNING; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi
if grep -qE 'stderr_capture=disabled' "$recon_stderr"; then
  pass "stderr_capture=disabled tag propagated to emitted incident details"
else
  fail "stderr_capture=disabled tag missing from emitted incident; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi

# TC-RECON-05: happy path surfaces no reconciliation-failure WARNING (negative control)
echo "TC-RECON-05: happy reconciliation path → no failure WARNING"
recon_dir=$(_setup_recon_env "happy" "happy" "updated")
recon_stderr="$(mktemp "$TEST_DIR/recon-happy-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
# Status is already "In Review", so the mismatch branch never runs and the block must
# stay silent. The failure root-cause hints below appear only inside failure WARNINGs,
# so finding any one on a clean run signals a classification regression firing falsely.
if grep -qE '(post_compact_[a-z_]+|state_root_(inaccessible|toctou_race)|pr_deleted_or_inaccessible)' "$recon_stderr"; then
  fail "happy path wrongly surfaced a reconciliation-failure WARNING (false positive): $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
else
  pass "happy path surfaces no reconciliation-failure WARNING (negative control)"
fi

# TC-RECON-05b: board on the terminal Status Cancelled → no mismatch, no reconciliation.
# The positive control is TC-RECON-06 below, which reaches the same code path from Todo
# and does emit the mismatch line — so a failure here means the terminal exclusion was
# dropped, not that the fixture never entered the block.
echo "TC-RECON-05b: board Status=Cancelled → no mismatch, no reconciliation"
recon_dir=$(_setup_recon_env "cancelled" "cancelled_terminal")
recon_stderr="$(mktemp "$TEST_DIR/recon-cancelled-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'post-compact mismatch detected' "$recon_stderr"; then
  fail "Cancelled board wrongly treated as a Status mismatch: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
else
  pass "Cancelled board is not reported as a mismatch"
fi
if grep -qE 'post-compact reconciliation (succeeded|jq payload build failed)|post_compact_reconciliation_failed' "$recon_stderr"; then
  fail "reconciliation ran against a terminal Cancelled board: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
else
  pass "no reconciliation attempted for a terminal Cancelled board"
fi

# TC-RECON-06: reconcile failed → post_compact_reconciliation_failed hint
echo "TC-RECON-06: reconcile result=failed → post_compact_reconciliation_failed hint"
recon_dir=$(_setup_recon_env "recon-fail" "mismatch_then_reconcile" "failed")
recon_stderr="$(mktemp "$TEST_DIR/recon-failed-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'post_compact_reconciliation_failed' "$recon_stderr"; then
  pass "post_compact_reconciliation_failed emitted when reconcile returns failed"
else
  fail "expected post_compact_reconciliation_failed; got: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
fi

# TC-RECON-07: gh repo view failure → cascade emit guard
# Strict count: exactly 1 incident (the repo view failure itself). The
# subsequent graphql / reconcile path is guarded by `exit 0` to prevent
# double-emit; a relaxed `<= 2` threshold would let 0-emit silent drops pass.
echo "TC-RECON-07: gh repo view failure → exactly one repo failure incident"
recon_dir=$(_setup_recon_env "repo-fail" "repo_view_fail")
recon_stderr="$(mktemp "$TEST_DIR/recon-repo-fail-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
incident_count=$(grep -cE 'post_compact_gh_repo_view_failed' "$recon_stderr" || echo 0)
if [ "$incident_count" -eq 1 ]; then
  pass "repo view failure emits exactly 1 WARNING (cascade guard functional)"
else
  fail "repo view failure emitted $incident_count WARNINGs (expected exactly 1)"
fi
if grep -qE 'post_compact_gh_repo_view_failed' "$recon_stderr"; then
  pass "TC-RECON-07 WARNING is attributed via post_compact_gh_repo_view_failed token"
else
  fail "TC-RECON-07 WARNING emitted but not attributed via post_compact_gh_repo_view_failed token: $(head -c 500 "$recon_stderr")"
fi

# TC-RECON-09: SSH Host alias origin → git-remote fast path bypasses a broken
# gh repo view (the actual #1899 scenario). Every fixture above uses a fake
# `mkdir -p .git` non-repo, so all of them fail to parse via git-remote and
# fall through to (and exercise) the gh repo view fallback — none exercises
# the git-remote fast path's *success* case at the caller level.
echo "TC-RECON-09: SSH Host alias origin → git-remote fast path bypasses broken gh repo view"
recon_dir=$(_setup_recon_env "git-remote-success" "git_remote_bypass" "updated" "git@github.com-work:o/r.git")
recon_stderr="$(mktemp "$TEST_DIR/recon-git-remote-success-stderr.XXXXXX")"
echo "{\"cwd\": \"$recon_dir\", \"source\": \"auto\"}" \
  | env PATH="$recon_dir/bin:$PATH" bash "$HOOK" >/dev/null 2>"$recon_stderr" || true
if grep -qE 'post_compact_gh_repo_view_failed' "$recon_stderr"; then
  fail "git-remote fast path did not bypass the broken gh repo view fallback: $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
else
  pass "git-remote fast path bypasses broken gh repo view (real #1899 scenario, caller-level)"
fi
if grep -qE 'MOCK ASSERTION FAILED' "$recon_stderr"; then
  fail "git-remote fast path resolved the WRONG repo (not o/r from the alias origin): $(head -c 500 "$recon_stderr" | tr '\n' ' ')"
else
  pass "git-remote fast path resolved the exact owner/repo from the alias origin (o/r), not just any repo"
fi

# TC-CONFIG-PARSE: post-compact.sh が rite-config.yml の awk parse 失敗を silent skip ではなく
# WARNING で surface する経路を保持していることを static に pin する。awk-gating コードが削除
# された場合や hint string が変わった場合に検出する。behavioral test は gh CLI shim 等が必要で
# 重いため、source grep で contract をピン留めする。
echo "TC-CONFIG-PARSE: awk parse failure surfaces WARNING with config_parse_failed hint"
if grep -q 'post_compact_config_parse_failed' "$HOOK"; then
  pass "post-compact.sh contains 'config_parse_failed' root_cause_hint"
else
  fail "post-compact.sh missing 'config_parse_failed' root_cause_hint — awk parse failure may silently fall to 'projects disabled' classification"
fi
if grep -qE '(awk_pe_rc|awk_pn_rc)' "$HOOK"; then
  pass "post-compact.sh distinguishes awk rc (config parse failure vs Projects disabled)"
else
  fail "post-compact.sh missing awk rc capture — awk failure cannot be distinguished from projects.enabled=false"
fi

# TC-RECON-08: command substitution は pipeline ではないため `set -o pipefail` だけでは jq -n の
# 失敗を outer rc に伝播しない。`JQ_PAYLOAD=$(jq -n ...) || JQ_PAYLOAD_RC=$?` の rc capture と
# `post_compact_jq_payload_build_failed` hint emit が削除されると、ENV 不整合 / locale / OOM 起因の
# jq 失敗時に projects status sync が silent に degraded する経路ができる。static pin で回帰防御。
echo "TC-RECON-08: jq -n payload build failure handling is wired (rc capture + jq_payload_build_failed hint)"
if grep -q 'JQ_PAYLOAD_RC' "$HOOK"; then
  pass "post-compact.sh contains JQ_PAYLOAD_RC capture (jq -n failure detection)"
else
  fail "post-compact.sh missing JQ_PAYLOAD_RC capture — command substitution swallows jq -n exit code"
fi
if grep -q 'post_compact_jq_payload_build_failed' "$HOOK"; then
  pass "post-compact.sh contains post_compact_jq_payload_build_failed hint"
else
  fail "post-compact.sh missing post_compact_jq_payload_build_failed hint — jq payload failure cannot be triaged"
fi

# --- TC-COMPACT-STATE-CORRUPT: jq failure on .compact_state surfaces WARNING ---
# A regression that drops the _compact_val_rc check would let a corrupt
# COMPACT_STATE silently route to the non-recovering branch with no audit trail.
echo "TC-COMPACT-STATE-CORRUPT: corrupt .rite-compact-state surfaces WARNING with rc"
TC_DIR=$(setup_test "tc-compact-corrupt")
write_per_session_state "$TC_DIR" \
  '{"active": true, "issue_number": 99, "phase": "implement", "branch": "feat/issue-99-test"}'
printf 'not-valid-json{{' > "$(compact_state_path "$TC_DIR")"
STDERR_OUT=$(echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | bash "$HOOK" 2>&1 >/dev/null) || true
if printf '%s' "$STDERR_OUT" | grep -qE 'post-compact: jq parse of \.compact_state failed \(rc=[1-9]'; then
  pass "TC-COMPACT-STATE-CORRUPT: WARNING surfaces real jq rc on corrupt compact-state"
else
  fail "TC-COMPACT-STATE-CORRUPT: expected WARNING with rc on corrupt compact-state; got: $STDERR_OUT"
fi

# --- TC-LEGACY-FALLBACK: sid unresolvable → legacy .rite-compact-state cleaned up ---
# When the session id cannot be resolved (no .rite-session-id file AND no
# CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID env), flow-state.sh path exits non-zero,
# FLOW_STATE="", and post-compact.sh falls back to the legacy shared
# "$STATE_ROOT/.rite-compact-state". With no flow-state file the "no flow state →
# clean up and exit" branch removes that legacy file. Seeding it and asserting removal
# pins that the fallback targets the legacy path: a per-session COMPACT_STATE would
# leave this seeded file untouched. env -u strips any ambient session id so the
# fallback is deterministic (fixture-based TCs write .rite-session-id, which wins).
echo "TC-LEGACY-FALLBACK: sid unresolvable → legacy .rite-compact-state cleaned up"
TC_DIR=$(setup_test "tc-legacy-fallback")
printf '%s\n' '{"compact_state": "recovering", "compact_state_set_at": "2026-03-14T12:00:00Z", "active_issue": 55}' > "$TC_DIR/.rite-compact-state"
lf_rc=0
lf_err=$(mktemp "$TEST_DIR/stderr.XXXXXX")
echo '{"cwd": "'"$TC_DIR"'", "source": "auto"}' | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" >/dev/null 2>"$lf_err" || lf_rc=$?
if [ "$lf_rc" -ne 0 ]; then
  fail "TC-LEGACY-FALLBACK: hook should exit 0 (got rc=$lf_rc); stderr: $(cat "$lf_err")"
elif [ -f "$TC_DIR/.rite-compact-state" ]; then
  fail "TC-LEGACY-FALLBACK: legacy .rite-compact-state should be cleaned up when session id is unresolvable"
else
  pass "TC-LEGACY-FALLBACK: legacy .rite-compact-state removed via fallback cleanup path"
fi
# $lf_err lives under $TEST_DIR and is reclaimed by the file-level `trap cleanup EXIT`,
# matching the other stderr-tempfile sites in this file (no per-TC rm).

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
