#!/bin/bash
# bang-backtick-edit-hook.test.sh
#
# Regression tests for the PostToolUse(Edit|Write|MultiEdit) wrapper that
# guards rite plugin markdown against bang-backtick adjacency injection.
# Companion of `bang-backtick-check.sh` (which is the underlying scanner)
# and the `/rite:pr-create` / `/rite:ready` Phase 1.0 bulk gate.
#
# 経路 C (immediate per-edit detection).
#
# Pinned acceptance criteria:
#   AC-1 (Happy path: 経路 C 即時検出)
#     Edit/Write of a rite-plugin markdown that contains the parser-trigger
#     pattern emits a stderr warning while still exiting 0 (warn-only).
#   AC-3 (Boundary: false positive なし)
#     Edit/Write of a clean rite-plugin markdown is silent (exit 0, no
#     warning).
#   Matcher-limited (DoD §7 MUST NOT — "他 plugin edit に発火しない")
#     A file_path outside `plugins/rite/{commands,skills,agents,references}`
#     short-circuits to exit 0 with no scanner invocation.
#
# Usage: bash plugins/rite/hooks/tests/bang-backtick-edit-hook.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="$SCRIPT_DIR/.."
PLUGIN_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
HOOK="$HOOK_DIR/scripts/bang-backtick-edit-hook.sh"
CHECK_SCRIPT="$HOOK_DIR/scripts/bang-backtick-check.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

[ -f "$HOOK" ] || { echo "ERROR: hook not found at $HOOK" >&2; exit 1; }
[ -f "$CHECK_SCRIPT" ] || { echo "ERROR: check script not found at $CHECK_SCRIPT" >&2; exit 1; }

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# Build a temporary repo that mirrors the rite plugin layout so the hook's
# `plugins/rite/...` path filter sees what it expects.
make_repo() {
  local d
  d=$(mktemp -d) || return 1
  # Canonicalize: the hook resolves REPO_ROOT via `git rev-parse --show-toplevel`
  # (which follows symlinks), but FILE_PATH is built from this raw sandbox path.
  # On macOS the raw mktemp path is under /var/folders (symlinked to /private/...),
  # so the raw-vs-canonical prefix strip fails and the hook exits "outside repo"
  # before scanning — TC-1/TC-7 then see no warning . pwd -P aligns
  # the fixture path with what the hook canonicalizes to.
  d=$(cd "$d" && pwd -P) || return 1
  (
    set -e
    cd "$d"
    git init -q
    git -c user.email=t@test.local -c user.name=test commit -q --allow-empty -m init
    mkdir -p plugins/rite/skills/pr
    mkdir -p plugins/rite/skills
    mkdir -p plugins/rite/agents
    mkdir -p plugins/rite/references
    mkdir -p other-plugin/commands
  ) || return 1
  echo "$d"
}

cleanup_dirs=()
cleanup_files=()
cleanup() {
  # Disable set -e inside the trap — short-circuit `&&` chains return non-zero
  # when the predicate is false, which would otherwise abort the trap and
  # propagate to the script's exit code.
  set +e
  local d f
  for d in "${cleanup_dirs[@]+"${cleanup_dirs[@]}"}"; do
    # Sanity check: only rm directories under a known temp root that we created
    # via mktemp -d. Never accept the literal "/tmp" or a non-temp path. macOS
    # mktemp lives under /var/folders (canonicalized to /private/var/folders),
    # so accept those too or the sandboxes leak on the macOS runner .
    case "$d" in
      /tmp/tmp.*|/tmp/[A-Za-z0-9]*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
        if [ -d "$d" ]; then rm -rf "$d"; fi
        ;;
      *) ;;
    esac
  done
  for f in "${cleanup_files[@]+"${cleanup_files[@]}"}"; do
    if [ -n "$f" ] && [ -f "$f" ]; then rm -f "$f"; fi
  done
}
trap cleanup EXIT

# Build a PostToolUse-style JSON payload.
build_input() {
  local tool_name="$1" file_path="$2" cwd="$3"
  jq -n \
    --arg tn "$tool_name" \
    --arg fp "$file_path" \
    --arg cwd "$cwd" \
    '{hook_event_name:"PostToolUse", tool_name:$tn, tool_input:{file_path:$fp}, cwd:$cwd}'
}

# ----- TC-1: AC-1 — dirty rite plugin md emits warning, exit 0 -------------
echo "TC-1: AC-1 — dirty rite plugin md emits warning, exits 0"
repo=$(make_repo)
cleanup_dirs+=("$repo")
target="$repo/plugins/rite/skills/pr/sample.md"
# Inject a P1 pattern: backtick + space + bang + backtick adjacency.
printf '%s\n' "Some prose with \` !\` adjacency to trigger detection." > "$target"
input=$(build_input "Edit" "$target" "$repo")
hook_stderr=$(mktemp)
cleanup_files+=("$hook_stderr")
hook_rc=0
printf '%s' "$input" | bash "$HOOK" 2>"$hook_stderr" >/dev/null || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-1 exit code 0 (warn-only)"
else
  fail "TC-1 exit code expected 0, got $hook_rc"
fi
if grep -q "bang-backtick adjacency detected" "$hook_stderr"; then
  pass "TC-1 stderr contains 'bang-backtick adjacency detected'"
else
  fail "TC-1 stderr missing warning"
  cat "$hook_stderr" >&2
fi
# Negative assertion: hook script の "Style B" ACTION line に bash command substitution bug が
# 混入していないこと。double-quoted echo 内に literal `if ! cmd` (backtick 隣接) を書くと bash が
# command substitution として subshell 実行を試み、syntax error で Style B 修正例 ("if ! cmd")
# 部分が空文字に化ける silent UX regression を防ぐ (旧コミット e50d08e で 3 site に同形混入)。
if grep -qE "command substitution|構文エラー|unexpected end of file|unexpected EOF" "$hook_stderr"; then
  fail "TC-1 stderr contains bash syntax error (command substitution bug regression)"
  cat "$hook_stderr" >&2
else
  pass "TC-1 stderr free of bash command substitution syntax errors"
fi
# Positive assertion: ACTION ヒントの中核 ("Style B (expand 'if ! cmd')") が破損なく出力されていること
if grep -qF "expand 'if ! cmd'" "$hook_stderr"; then
  pass "TC-1 ACTION hint includes literal 'if ! cmd' (Style B example intact)"
else
  fail "TC-1 ACTION hint missing 'if ! cmd' literal (single-quote regression)"
  cat "$hook_stderr" >&2
fi
rm -f "$hook_stderr"

# ----- TC-2: AC-3 — clean rite plugin md is silent, exit 0 -----------------
echo "TC-2: AC-3 — clean rite plugin md is silent, exits 0"
repo=$(make_repo)
cleanup_dirs+=("$repo")
target="$repo/plugins/rite/skills/pr/clean.md"
# Use Style A (full-width corner brackets) — safe canonical rewrite.
printf '%s\n' "Some prose using full-width 「!」 instead of bang-backtick." > "$target"
input=$(build_input "Edit" "$target" "$repo")
hook_stderr=$(mktemp)
hook_rc=0
printf '%s' "$input" | bash "$HOOK" 2>"$hook_stderr" >/dev/null || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-2 exit code 0 (clean)"
else
  fail "TC-2 exit code expected 0, got $hook_rc"
fi
if [ ! -s "$hook_stderr" ] || ! grep -q "bang-backtick" "$hook_stderr"; then
  pass "TC-2 stderr silent for clean file"
else
  fail "TC-2 stderr unexpectedly contained warning"
  cat "$hook_stderr" >&2
fi
rm -f "$hook_stderr"

# ----- TC-3: matcher limited — file outside rite plugin tree skipped --------
echo "TC-3: file outside rite plugin tree → silent skip"
repo=$(make_repo)
cleanup_dirs+=("$repo")
target="$repo/other-plugin/commands/sample.md"
# Even with a P1 pattern present, the wrapper must not invoke the scanner.
printf '%s\n' "Some prose with \` !\` adjacency that should be ignored." > "$target"
input=$(build_input "Edit" "$target" "$repo")
hook_stderr=$(mktemp)
hook_rc=0
printf '%s' "$input" | bash "$HOOK" 2>"$hook_stderr" >/dev/null || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-3 exit code 0 (other plugin)"
else
  fail "TC-3 exit code expected 0, got $hook_rc"
fi
if [ ! -s "$hook_stderr" ] || ! grep -q "bang-backtick" "$hook_stderr"; then
  pass "TC-3 stderr silent for non-rite path"
else
  fail "TC-3 stderr unexpectedly contained warning (matcher leak)"
  cat "$hook_stderr" >&2
fi
rm -f "$hook_stderr"

# ----- TC-4: defense-in-depth — non Edit/Write tool short-circuits ---------
echo "TC-4: tool_name=Bash short-circuits to exit 0"
repo=$(make_repo)
cleanup_dirs+=("$repo")
target="$repo/plugins/rite/skills/pr/sample.md"
printf '%s\n' "Some prose with \` !\` adjacency." > "$target"
input=$(build_input "Bash" "$target" "$repo")
hook_stderr=$(mktemp)
hook_rc=0
printf '%s' "$input" | bash "$HOOK" 2>"$hook_stderr" >/dev/null || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-4 exit code 0 (Bash tool)"
else
  fail "TC-4 exit code expected 0, got $hook_rc"
fi
if [ ! -s "$hook_stderr" ] || ! grep -q "bang-backtick" "$hook_stderr"; then
  pass "TC-4 stderr silent for non-Edit/Write tool"
else
  fail "TC-4 stderr unexpectedly contained warning (tool filter leak)"
  cat "$hook_stderr" >&2
fi
rm -f "$hook_stderr"

# ----- TC-5: empty file_path — defensive exit 0 ----------------------------
echo "TC-5: empty file_path → exit 0"
repo=$(make_repo)
cleanup_dirs+=("$repo")
input=$(build_input "Edit" "" "$repo")
hook_stderr=$(mktemp)
hook_rc=0
printf '%s' "$input" | bash "$HOOK" 2>"$hook_stderr" >/dev/null || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-5 exit code 0 (empty file_path)"
else
  fail "TC-5 exit code expected 0, got $hook_rc"
fi
rm -f "$hook_stderr"

# ----- TC-6: missing file (deleted by Edit) — exit 0 silently --------------
echo "TC-6: missing target file → silent exit 0"
repo=$(make_repo)
cleanup_dirs+=("$repo")
target="$repo/plugins/rite/skills/pr/ghost.md"
# Note: target file is intentionally NOT created.
input=$(build_input "Edit" "$target" "$repo")
hook_stderr=$(mktemp)
hook_rc=0
printf '%s' "$input" | bash "$HOOK" 2>"$hook_stderr" >/dev/null || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-6 exit code 0 (missing file)"
else
  fail "TC-6 exit code expected 0, got $hook_rc"
fi
if [ ! -s "$hook_stderr" ] || ! grep -q "bang-backtick" "$hook_stderr"; then
  pass "TC-6 stderr silent for missing file"
else
  fail "TC-6 stderr unexpectedly contained warning"
fi
rm -f "$hook_stderr"

# ----- TC-7: skills/ subdirectory triggers detection (path filter coverage) -
echo "TC-7: rite skills/ subdir triggers detection (path filter coverage)"
repo=$(make_repo)
cleanup_dirs+=("$repo")
mkdir -p "$repo/plugins/rite/skills/example"
target="$repo/plugins/rite/skills/example/SKILL.md"
printf '%s\n' "Trigger: \` !\` adjacency in skills/." > "$target"
input=$(build_input "Write" "$target" "$repo")
hook_stderr=$(mktemp)
hook_rc=0
printf '%s' "$input" | bash "$HOOK" 2>"$hook_stderr" >/dev/null || hook_rc=$?
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-7 exit code 0"
else
  fail "TC-7 exit code expected 0, got $hook_rc"
fi
if grep -q "bang-backtick adjacency detected" "$hook_stderr"; then
  pass "TC-7 skills/ path triggers detection"
else
  fail "TC-7 skills/ path missing detection"
  cat "$hook_stderr" >&2
fi
rm -f "$hook_stderr"

# ----- TC-8: AC-4 — input extraction uses a single jq spawn -----------------
# The three separate jq calls (tool_name / file_path / cwd) were aggregated into
# one single-jq extraction joined on the unit separator (\x1f). A `jq` PATH-shim
# counts invocations; an out-of-scope path exits right after extraction (before
# the check script, which uses no jq), so the total jq count is exactly the one
# extraction call.
echo "TC-8: AC-4 — single jq spawn for input extraction"
repo=$(make_repo)
cleanup_dirs+=("$repo")
real_jq=$(command -v jq)
jq_shim_dir=$(mktemp -d)
cleanup_dirs+=("$jq_shim_dir")
jq_count_file="$jq_shim_dir/count"
cat > "$jq_shim_dir/jq" <<SHIM
#!/bin/sh
echo x >> "$jq_count_file"
exec "$real_jq" "\$@"
SHIM
chmod +x "$jq_shim_dir/jq"
# build_input runs BEFORE the shim is on PATH, so its jq is not counted.
input=$(build_input "Edit" "$repo/other-plugin/commands/sample.md" "$repo")
hook_rc=0
printf '%s' "$input" | PATH="$jq_shim_dir:$PATH" bash "$HOOK" 2>/dev/null >/dev/null || hook_rc=$?
jq_calls=$( [ -f "$jq_count_file" ] && wc -l < "$jq_count_file" | tr -d ' ' || echo 0 )
if [ "$hook_rc" -eq 0 ] && [ "$jq_calls" -eq 1 ]; then
  pass "TC-8 exactly 1 jq spawn for input extraction (AC-4)"
else
  fail "TC-8 expected 1 jq spawn, got $jq_calls (exit=$hook_rc)"
fi

# ----- TC-9: pre-filter front-loads before git rev-parse (non-scope path) ----
# The cheap `*plugins/rite/*.md` glob must reject non-scope paths BEFORE the repo
# root resolution, so a non-rite / out-of-scope edit spawns no git. A `git`
# PATH-shim records invocations; an out-of-scope path must leave it untouched.
echo "TC-9: non-scope path skips git rev-parse (front-loaded pre-filter)"
repo=$(make_repo)
cleanup_dirs+=("$repo")
git_shim_dir=$(mktemp -d)
cleanup_dirs+=("$git_shim_dir")
git_count_file="$git_shim_dir/count"
cat > "$git_shim_dir/git" <<SHIM
#!/bin/sh
echo x >> "$git_count_file"
exit 0
SHIM
chmod +x "$git_shim_dir/git"
input=$(build_input "Edit" "$repo/other-plugin/commands/sample.md" "$repo")
hook_rc=0
printf '%s' "$input" | PATH="$git_shim_dir:$PATH" bash "$HOOK" 2>/dev/null >/dev/null || hook_rc=$?
git_calls=$( [ -f "$git_count_file" ] && wc -l < "$git_count_file" | tr -d ' ' || echo 0 )
if [ "$hook_rc" -eq 0 ] && [ "$git_calls" -eq 0 ]; then
  pass "TC-9 no git rev-parse for non-scope path (pre-filter front-loaded)"
else
  fail "TC-9 expected 0 git spawns for non-scope path, got $git_calls (exit=$hook_rc)"
fi

# ----- Summary --------------------------------------------------------------
echo ""
echo "==> $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
