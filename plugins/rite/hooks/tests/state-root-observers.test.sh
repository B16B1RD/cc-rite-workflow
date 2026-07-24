#!/bin/bash
# state-root-observers.test.sh
#
# Pin the state-path-resolve based root resolution of the observation-surface
# scripts unified in the review-result state-root change (Issue #1831,
# regression tests deferred to Issue #1845):
#
#   TC-1..3  hooks/scripts/review-schema-version-check.sh --all (scan-root 解決)
#   TC-4..5  hooks/review-skip-notification.sh              (表示パス解決)
#
# A regression back to `git rev-parse --show-toplevel` would split the writer
# root and the reader root in a linked-worktree session: the scanner reads an
# empty directory and drift detection silently no-ops. The sandbox mirrors the
# plugin layout (hooks/ + hooks/scripts/) inside a real git repo with a linked
# worktree, same as review-result-state-root.test.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  # linked worktree を先に外さないと rm -rf 後の git 参照が残る
  git -C "$TEST_DIR/repo" worktree remove --force "$TEST_DIR/repo/.rite/worktrees/issue-99" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== state-root-observers tests ==="

if ! command -v jq >/dev/null 2>&1; then
  # Emit the counted form so the runner rolls this into its "N skipped" headline —
  # a whole file that exits 0 without running anything would otherwise be scored
  # as a pass (Issue #2008 review I-03).
  echo "  ⏭️ SKIP: jq not available — state-root-observers requires jq"
  echo "SKIP: 1"
  exit 0
fi

# --- sandbox: git repo + plugin layout + linked worktree ---
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
mkdir -p "$REPO/hooks/scripts"
cp "$HOOKS_DIR/state-path-resolve.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/review-skip-notification.sh" "$REPO/hooks/"
cp "$HOOKS_DIR/scripts/review-schema-version-check.sh" "$REPO/hooks/scripts/"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"
git -C "$REPO" worktree add -q "$REPO/.rite/worktrees/issue-99" -b test-branch main
WT="$REPO/.rite/worktrees/issue-99"

# 期待パスは git / resolver が返す正規化済み root から導出する (macOS の /var → /private/var
# symlink で literal $REPO との文字列比較が不一致になるため。sibling suite と同じ理由)
MAIN_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)
RESOLVED_ROOT=$(cd "$WT" && bash "$MAIN_ROOT/hooks/state-path-resolve.sh")

# drift fixture: state-root (main checkout) 側にのみ置く。worktree 側の
# .rite/review-results/ は存在しない = --show-toplevel 回帰なら空 scan で rc=0 になる
mkdir -p "$MAIN_ROOT/.rite/review-results"
printf '{"schema_version":"9.9.9","findings":[]}\n' \
  > "$MAIN_ROOT/.rite/review-results/99-20260101000000.json"

# ─── TC-1: --all を worktree cwd から実行すると state-root の drift を検出する ───
echo "TC-1: --all from worktree cwd scans the state root (drift detected)"
rc=0
(cd "$WT" && bash "$MAIN_ROOT/hooks/scripts/review-schema-version-check.sh" --all --quiet) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "TC-1: state-root drift detected from worktree cwd (rc=1)"
else
  fail "TC-1: expected rc=1 (drift), got rc=$rc — --all scan root likely regressed to worktree toplevel"
fi

# ─── TC-2: --repo-root 明示指定は state-root 既定を上書きする ───
echo "TC-2: explicit --repo-root overrides the state-root default"
rc=0
(cd "$WT" && bash "$MAIN_ROOT/hooks/scripts/review-schema-version-check.sh" --all --quiet --repo-root "$WT") >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "TC-2: --repo-root=\$WT scans the (empty) worktree dir → clean (rc=0)"
else
  fail "TC-2: expected rc=0 (explicit override wins), got rc=$rc"
fi

# ─── TC-3: 非 git cwd では従来どおり ERROR exit 2 (fail-fast 維持) ───
echo "TC-3: non-git cwd still fail-fasts with exit 2"
NOGIT="$TEST_DIR/nogit"
mkdir -p "$NOGIT"
rc=0
(cd "$NOGIT" && bash "$MAIN_ROOT/hooks/scripts/review-schema-version-check.sh" --all --quiet) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "TC-3: non-git cwd exits 2 (resolver did not convert it to silent success)"
else
  fail "TC-3: expected rc=2 (invocation error), got rc=$rc"
fi

# ─── TC-4: skip-notification の表示パスが state-root 絶対パスになる ───
echo "TC-4: skip-notification displays the state-root absolute path from worktree cwd"
notif_out=$( (cd "$WT" && bash "$MAIN_ROOT/hooks/review-skip-notification.sh" \
  --post-comment-mode false --pr 99 --file-timestamp 20260101000000 --local-save-failed "") 2>&1 ) || true
expected_line="ローカルファイル: ${RESOLVED_ROOT}/.rite/review-results/99-20260101000000.json"
if printf '%s\n' "$notif_out" | grep -qF "$expected_line"; then
  pass "TC-4: display path anchors to the resolved state root"
else
  fail "TC-4: expected '$expected_line' in output. got: $notif_out"
fi
if printf '%s\n' "$notif_out" | grep -qF "ローカルファイル: .rite/review-results/"; then
  fail "TC-4: cwd-relative display path leaked (regression to pre-unification format)"
else
  pass "TC-4: no cwd-relative display path"
fi

# ─── TC-5: resolver 不在時は WARNING + cwd 相対へフォールバック ───
echo "TC-5: skip-notification falls back to cwd-relative display when resolver is missing"
NORES="$TEST_DIR/nores/hooks"
mkdir -p "$NORES"
cp "$HOOKS_DIR/review-skip-notification.sh" "$NORES/"
# state-path-resolve.sh を意図的に置かない
fallback_out=$( (cd "$TEST_DIR/nores" && bash "$NORES/review-skip-notification.sh" \
  --post-comment-mode false --pr 99 --file-timestamp 20260101000000 --local-save-failed "") 2>&1 ) || true
if printf '%s\n' "$fallback_out" | grep -q "WARNING: state-path-resolve.sh の解決に失敗"; then
  pass "TC-5: fallback WARNING surfaced"
else
  fail "TC-5: fallback WARNING missing. got: $fallback_out"
fi
if printf '%s\n' "$fallback_out" | grep -qF "ローカルファイル: .rite/review-results/99-20260101000000.json"; then
  pass "TC-5: cwd-relative display path used as fallback"
else
  fail "TC-5: cwd-relative fallback path missing. got: $fallback_out"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
