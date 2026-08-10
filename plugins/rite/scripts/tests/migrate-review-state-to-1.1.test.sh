#!/bin/bash
# Tests for scripts/migrate-review-state-to-1.1.sh
# Usage: bash plugins/rite/scripts/tests/migrate-review-state-to-1.1.test.sh
#
# Strategy: the migration script resolves its default REPO_ROOT via
# hooks/state-path-resolve.sh (the same anchor as review-result-save.sh).
# These tests pin the linked-worktree path (の state-root 統一,
# regression tests deferred to): a regression back to
# `git rev-parse --show-toplevel` would resolve the worktree root, miss the
# main-root JSON, and turn the migration into a silent no-op. The sandbox
# mirrors the plugin layout (scripts/ + hooks/) inside a real git repo with a
# linked worktree, following review-result-state-root.test.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$(cd "$SCRIPTS_DIR/../hooks" && pwd)"

# jq gate は mktemp より前に置く (mktemp 後に trap 未設置のまま exit すると temp dir が orphan 残置される)
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  git -C "$TEST_DIR/repo" worktree remove --force "$TEST_DIR/repo/.rite/worktrees/issue-99" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== migrate-review-state-to-1.1.sh tests ==="

# --- sandbox: git repo + plugin layout (scripts/ + hooks/) + linked worktree ---
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
mkdir -p "$REPO/scripts" "$REPO/hooks"
cp "$SCRIPTS_DIR/migrate-review-state-to-1.1.sh" "$REPO/scripts/"
cp "$HOOKS_DIR/state-path-resolve.sh" "$REPO/hooks/"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
git -C "$REPO" worktree add -q "$REPO/.rite/worktrees/issue-99" -b test-branch main
WT="$REPO/.rite/worktrees/issue-99"
MAIN_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)
MIGRATE="$MAIN_ROOT/scripts/migrate-review-state-to-1.1.sh"

# 1.0 fixture: state-root (main checkout) 側にのみ置く。worktree 側には置かない =
# --show-toplevel 回帰なら空 dir scan で silent no-op になる
mkdir -p "$MAIN_ROOT/.rite/review-results"
json_10() {
  cat <<'JSON'
{
  "schema_version": "1.0",
  "pr_number": 42,
  "findings": [
    { "id": "F-01", "severity": "HIGH", "file": "src/a.ts", "line": 1,
      "description": "x", "suggestion": "y", "status": "open" }
  ]
}
JSON
}
json_10 > "$MAIN_ROOT/.rite/review-results/42-20260101000000.json"

# ─── TC-1: --dry-run を worktree cwd から実行すると main-root の 1.0 JSON を検出する ───
echo "TC-1: --dry-run from worktree cwd detects the main-root 1.0 JSON"
rc=0
dry_out=$( (cd "$WT" && bash "$MIGRATE" --dry-run) 2>&1 ) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$dry_out" | grep -qF "would migrate ${MAIN_ROOT}/.rite/review-results/42-20260101000000.json"; then
  pass "TC-1: dry-run resolved the state root and found the target"
else
  fail "TC-1: expected 'would migrate <main-root JSON>' (rc=$rc). got: $dry_out"
fi
# dry-run はファイルを変更しない
ver=$(jq -r '.schema_version' "$MAIN_ROOT/.rite/review-results/42-20260101000000.json")
if [ "$ver" = "1.0" ]; then
  pass "TC-1: dry-run leaves the file unmodified"
else
  fail "TC-1: dry-run mutated the file (schema_version=$ver)"
fi

# ─── TC-2: apply を worktree cwd から実行すると main-root の JSON が migrate される ───
echo "TC-2: apply from worktree cwd migrates the main-root JSON in place"
rc=0
(cd "$WT" && bash "$MIGRATE") >/dev/null 2>&1 || rc=$?
ver=$(jq -r '.schema_version' "$MAIN_ROOT/.rite/review-results/42-20260101000000.json")
scope=$(jq -r '.findings[0].scope // "missing"' "$MAIN_ROOT/.rite/review-results/42-20260101000000.json")
if [ "$rc" -eq 0 ] && [ "$ver" = "1.1.0" ]; then
  pass "TC-2: schema_version bumped to 1.1.0 on the state-root file"
else
  fail "TC-2: expected schema_version=1.1.0 (rc=$rc), got '$ver' — migration likely no-oped on the worktree root"
fi
if [ "$scope" = "current-pr" ]; then
  pass "TC-2: HIGH finding backfilled with scope=current-pr"
else
  fail "TC-2: expected scope=current-pr, got '$scope'"
fi
# accepted-fingerprints 初期化も state-root 側に着地する
if [ -f "$MAIN_ROOT/.rite/state/accepted-fingerprints-42.txt" ]; then
  pass "TC-2: accepted-fingerprints state initialized under the state root"
else
  fail "TC-2: accepted-fingerprints-42.txt missing under $MAIN_ROOT/.rite/state/"
fi

# ─── TC-3: REPO_ROOT env 明示指定は state-root 既定を上書きする ───
echo "TC-3: explicit REPO_ROOT env overrides the state-root default"
json_10 > "$MAIN_ROOT/.rite/review-results/43-20260101000000.json"
ALT="$TEST_DIR/alt"
mkdir -p "$ALT"
rc=0
(cd "$WT" && REPO_ROOT="$ALT" bash "$MIGRATE") >/dev/null 2>&1 || rc=$?
ver=$(jq -r '.schema_version' "$MAIN_ROOT/.rite/review-results/43-20260101000000.json")
if [ "$rc" -eq 0 ] && [ "$ver" = "1.0" ]; then
  pass "TC-3: REPO_ROOT=\$ALT left the state-root file untouched (override wins)"
else
  fail "TC-3: expected untouched schema_version=1.0 (rc=$rc), got '$ver'"
fi

# ─── TC-4: 非 git cwd + REPO_ROOT 未設定は従来どおり ERROR exit 1 ───
echo "TC-4: non-git cwd without REPO_ROOT still fail-fasts with exit 1"
NOGIT="$TEST_DIR/nogit"
mkdir -p "$NOGIT"
rc=0
err_out=$( (cd "$NOGIT" && bash "$MIGRATE") 2>&1 ) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$err_out" | grep -q "ERROR: REPO_ROOT could not be resolved"; then
  pass "TC-4: non-git cwd exits 1 with the resolution ERROR"
else
  fail "TC-4: expected rc=1 + resolution ERROR, got rc=$rc: $err_out"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
