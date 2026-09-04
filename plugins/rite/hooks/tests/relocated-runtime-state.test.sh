#!/bin/bash
# Tests for: relocate root `.rite-*` runtime state under `.rite/`.
# Failures are exit-nonzero so run-tests.sh counts FAILED and CI jobs fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$HOOKS_DIR/session-start.sh"
SID_HELPER="$HOOKS_DIR/_resolve-session-id-from-file.sh"
FLOW="$HOOKS_DIR/flow-state.sh"
CLEANUP_WM="$HOOKS_DIR/cleanup-work-memory.sh"
PLUGIN_ROOT="$(cd "$HOOKS_DIR/.." && pwd)"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"

unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT

run_session_start() {
  local cwd="$1" sid="${2:-aaaaaaaa-1111-2222-3333-444444444444}"
  jq -n --arg cwd "$cwd" --arg src "startup" --arg sid "$sid" \
    '{cwd: $cwd, source: $src, session_id: $sid}' \
    | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" >/dev/null 2>/dev/null || true
}

echo "=== relocated runtime state ==="

# T-01 / T-04: session-start writes the 4 file states to new paths, not root.
echo "T-01: session-start writers land on new paths"
d01="$TEST_DIR/t01"
mkdir -p "$d01"
sid01="bbbbbbbb-1111-2222-3333-444444444444"
run_session_start "$d01" "$sid01"
assert "T-01 session-id new path" "$sid01" "$(cat "$d01/.rite/session-id" 2>/dev/null)"
assert_file_exists_or_fail "T-01 plugin-root new path" "$d01/.rite/plugin-root"
[ ! -f "$d01/.rite-session-id" ]
assert "T-01 no legacy session-id at root" "0" "$?"
[ ! -f "$d01/.rite-plugin-root" ]
assert "T-01 no legacy plugin-root at root" "0" "$?"
[ ! -e "$d01/.rite-initialized-version" ]
assert "T-01 no legacy initialized-version at root" "0" "$?"
[ ! -e "$d01/.rite-settings-hooks-cleaned" ]
assert "T-01 no legacy settings-hooks-cleaned at root" "0" "$?"
[ ! -e "$d01/.rite-flow-debug.log" ]
assert "T-01 no legacy flow-debug.log at root" "0" "$?"
[ ! -d "$d01/.rite-work-memory" ]
assert "T-01 no legacy work-memory at root" "0" "$?"

# T-04 extension: work-memory-update and debug-log writers do not create root files.
echo "T-04: work-memory-update writes .rite/work-memory not root"
d04="$TEST_DIR/t04"
mkdir -p "$d04"
(
  cd "$d04"
  # shellcheck source=../work-memory-update.sh
  WM_SOURCE="test" WM_PHASE="init" WM_PHASE_DETAIL="d" WM_NEXT_ACTION="n" \
    WM_BODY_TEXT="body" WM_PLUGIN_ROOT="$PLUGIN_ROOT" WM_ISSUE_NUMBER="2430" \
    WM_SKIP_LOCK="true"
  export WM_SOURCE WM_PHASE WM_PHASE_DETAIL WM_NEXT_ACTION WM_BODY_TEXT WM_PLUGIN_ROOT WM_ISSUE_NUMBER WM_SKIP_LOCK
  # shellcheck disable=SC1091
  source "$HOOKS_DIR/work-memory-update.sh"
  update_local_work_memory
)
assert_file_exists_or_fail "T-04 WM new path" "$d04/.rite/work-memory/issue-2430.md"
[ ! -d "$d04/.rite-work-memory" ]
assert "T-04 no legacy WM dir" "0" "$?"
mode=$(stat -c '%a' "$d04/.rite/work-memory" 2>/dev/null || stat -f '%OLp' "$d04/.rite/work-memory")
assert "T-04 WM dir chmod 700" "700" "$mode"
assert_file_exists_or_fail "T-04 .rite/.gitignore" "$d04/.rite/.gitignore"
grep -qx '*' "$d04/.rite/.gitignore"
assert "T-04 .rite gitignore has star" "0" "$?"
grep -q '!wiki/' "$d04/.rite/.gitignore"
assert "T-04 .rite gitignore has wiki negation" "0" "$?"

echo "T-04: debug log path is .rite/logs/flow-debug.log"
for f in pre-tool-bash-guard.sh pre-tool-edit-guard.sh post-tool-wm-sync.sh; do
  grep -q '\.rite/logs/flow-debug.log' "$HOOKS_DIR/$f"
  assert "T-04 $f writes new debug log path" "0" "$?"
  if grep -E '>>.*"\$\{STATE_ROOT[^}]*\}/\.rite-flow-debug\.log"|>> *"\$STATE_ROOT/\.rite-flow-debug\.log"' "$HOOKS_DIR/$f" >/dev/null; then
    fail "T-04 $f still appends to legacy debug log"
  else
    pass "T-04 $f does not append to legacy debug log"
  fi
done

# T-02: old-only fixtures are readable.
echo "T-02: dual-read from legacy-only files"
d02="$TEST_DIR/t02"
mkdir -p "$d02"
uuid02="cccccccc-1111-2222-3333-444444444444"
printf '%s' "$uuid02" > "$d02/.rite-session-id"
out=$(bash "$SID_HELPER" "$d02" 2>/dev/null)
assert "T-02 _resolve-session-id-from-file reads legacy" "$uuid02" "$out"
# flow-state file path uses the same dual-read
mkdir -p "$d02/.rite/sessions"
printf '%s' "$uuid02" > "$d02/.rite-session-id"
path=$(RITE_STATE_ROOT="$d02" bash "$FLOW" path --session "$uuid02" 2>/dev/null || true)
# --session override skips the file; instead unset and use file
path=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID RITE_STATE_ROOT="$d02" bash "$FLOW" path 2>/dev/null) || path=""
assert "T-02 flow-state path uses legacy sid file" "$d02/.rite/sessions/${uuid02}.flow-state" "$path"

d02wm="$TEST_DIR/t02wm"
mkdir -p "$d02wm/.rite-work-memory"
printf '# 📜 rite 作業メモリ\n\n## Summary\n---\nschema_version: 1\nissue_number: 2430\nsync_revision: 5\npr_number: 4242\nloop_count: 7\n---\n\nfrom-old\n' \
  > "$d02wm/.rite-work-memory/issue-2430.md"
(
  cd "$d02wm"
  WM_SOURCE="test" WM_PHASE="plan" WM_PHASE_DETAIL="d" WM_NEXT_ACTION="n" \
    WM_BODY_TEXT="from-old" WM_PLUGIN_ROOT="$PLUGIN_ROOT" WM_ISSUE_NUMBER="2430" \
    WM_SKIP_LOCK="true"
  unset WM_PR_NUMBER
  export WM_SOURCE WM_PHASE WM_PHASE_DETAIL WM_NEXT_ACTION WM_BODY_TEXT WM_PLUGIN_ROOT WM_ISSUE_NUMBER WM_SKIP_LOCK
  # shellcheck disable=SC1091
  source "$HOOKS_DIR/work-memory-update.sh"
  update_local_work_memory
)
grep -q 'from-old' "$d02wm/.rite/work-memory/issue-2430.md"
assert "T-02 WM old-read then new-write" "0" "$?"
grep -q 'pr_number: 4242' "$d02wm/.rite/work-memory/issue-2430.md"
assert "T-02 WM carries pr_number from legacy frontmatter" "0" "$?"

# T-03: migrate old → new once; second run is no-op; both-exist does not clobber.
echo "T-03: session-start migrate is idempotent"
d03="$TEST_DIR/t03"
mkdir -p "$d03"
printf 'legacy-plugin' > "$d03/.rite-plugin-root"
printf 'legacy-sid' > "$d03/.rite-session-id"
printf '1.0.0' > "$d03/.rite-initialized-version"
printf 'cleaned' > "$d03/.rite-settings-hooks-cleaned"
printf 'oldlog' > "$d03/.rite-flow-debug.log"
mkdir -p "$d03/.rite-work-memory"
printf 'oldwm' > "$d03/.rite-work-memory/issue-1.md"
run_session_start "$d03" "dddddddd-dddd-dddd-dddd-dddddddddddd"
assert_file_exists_or_fail "T-03 plugin-root at new path" "$d03/.rite/plugin-root"
[ ! -e "$d03/.rite-plugin-root" ]
assert "T-03 legacy plugin-root removed after mv" "0" "$?"
assert "T-03 WM content preserved across dir mv" "oldwm" "$(cat "$d03/.rite/work-memory/issue-1.md" 2>/dev/null)"
[ ! -e "$d03/.rite-work-memory" ]
assert "T-03 legacy WM dir removed after mv" "0" "$?"
assert "T-03 debug log migrated" "oldlog" "$(cat "$d03/.rite/logs/flow-debug.log" 2>/dev/null)"
[ ! -e "$d03/.rite-flow-debug.log" ]
assert "T-03 legacy debug log removed after mv" "0" "$?"
assert_file_exists_or_fail "T-03 initialized-version at new path" "$d03/.rite/initialized-version"
[ ! -e "$d03/.rite-initialized-version" ]
assert "T-03 legacy initialized-version removed after mv" "0" "$?"
assert "T-03 settings-hooks-cleaned migrated" "cleaned" "$(cat "$d03/.rite/settings-hooks-cleaned" 2>/dev/null)"
[ ! -e "$d03/.rite-settings-hooks-cleaned" ]
assert "T-03 legacy settings-hooks-cleaned removed after mv" "0" "$?"
[ ! -e "$d03/.rite-session-id" ]
assert "T-03 legacy session-id removed after mv" "0" "$?"
# second run: new remains, old not recreated
new_sid_before=$(cat "$d03/.rite/session-id" 2>/dev/null || true)
run_session_start "$d03" "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
[ ! -e "$d03/.rite-plugin-root" ]
assert "T-03 second run does not recreate legacy plugin-root" "0" "$?"
# both-exist: migrate must not clobber dest. Use work-memory (session-start
# does not rewrite it after migrate; plugin-root is rewritten every start).
d03b="$TEST_DIR/t03both"
mkdir -p "$d03b/.rite/work-memory" "$d03b/.rite-work-memory"
printf 'NEWWM' > "$d03b/.rite/work-memory/issue-1.md"
printf 'OLDWM' > "$d03b/.rite-work-memory/issue-1.md"
run_session_start "$d03b"
assert "T-03 both-exist keeps new WM" "NEWWM" "$(cat "$d03b/.rite/work-memory/issue-1.md")"
assert "T-03 both-exist leaves old WM" "OLDWM" "$(cat "$d03b/.rite-work-memory/issue-1.md")"

# T-03 fail branch: mv failure emits WARNING and leaves src (work-memory).
echo "T-03: migrate mv failure warns and leaves src"
d03fail="$TEST_DIR/t03fail"
mkdir -p "$d03fail/.rite-work-memory"
printf 'keep' > "$d03fail/.rite-work-memory/issue-1.md"
shim="$TEST_DIR/mv-shim"
mkdir -p "$shim"
cat > "$shim/mv" <<'EOF'
#!/bin/bash
echo "mv: simulated failure" >&2
exit 1
EOF
chmod +x "$shim/mv"
err03=$(jq -n --arg cwd "$d03fail" --arg src "startup" --arg sid "ffffffff-ffff-ffff-ffff-ffffffffffff" \
  '{cwd: $cwd, source: $src, session_id: $sid}' \
  | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID PATH="$shim:$PATH" bash "$HOOK" 2>&1 >/dev/null || true)
printf '%s\n' "$err03" | grep -q 'WARNING: relocated-state-migrate: failed to migrate'
assert "T-03 mv failure emits WARNING" "0" "$?"
[ -d "$d03fail/.rite-work-memory" ]
assert "T-03 mv failure leaves legacy WM dir" "0" "$?"
[ ! -d "$d03fail/.rite/work-memory" ]
assert "T-03 mv failure does not create dest WM dir" "0" "$?"

# T-05: env priority CLAUDE_CODE_SESSION_ID > CLAUDE_SESSION_ID > new file > old file
echo "T-05: session_id resolution order"
d05="$TEST_DIR/t05"
mkdir -p "$d05/.rite"
uuid_new="11111111-1111-1111-1111-111111111111"
uuid_old="22222222-2222-2222-2222-222222222222"
uuid_env1="33333333-3333-3333-3333-333333333333"
uuid_env2="44444444-4444-4444-4444-444444444444"
printf '%s' "$uuid_new" > "$d05/.rite/session-id"
printf '%s' "$uuid_old" > "$d05/.rite-session-id"
path=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID RITE_STATE_ROOT="$d05" bash "$FLOW" path 2>/dev/null)
assert "T-05 new file beats old file" "$d05/.rite/sessions/${uuid_new}.flow-state" "$path"
path=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$uuid_env2" RITE_STATE_ROOT="$d05" bash "$FLOW" path 2>/dev/null)
assert "T-05 CLAUDE_SESSION_ID beats files" "$d05/.rite/sessions/${uuid_env2}.flow-state" "$path"
path=$(env CLAUDE_CODE_SESSION_ID="$uuid_env1" CLAUDE_SESSION_ID="$uuid_env2" RITE_STATE_ROOT="$d05" bash "$FLOW" path 2>/dev/null)
assert "T-05 CLAUDE_CODE_SESSION_ID beats CLAUDE_SESSION_ID" "$d05/.rite/sessions/${uuid_env1}.flow-state" "$path"

# T-07: both exist → new wins for readers
echo "T-07: new content wins when both exist"
d07="$TEST_DIR/t07"
mkdir -p "$d07/.rite"
printf '%s' "$uuid_new" > "$d07/.rite/session-id"
printf '%s' "$uuid_old" > "$d07/.rite-session-id"
out=$(bash "$SID_HELPER" "$d07" 2>/dev/null)
assert "T-07 from-file helper prefers new" "$uuid_new" "$out"

# invalid new must not fall through to valid old
d07b="$TEST_DIR/t07bad"
mkdir -p "$d07b/.rite"
printf 'not-a-uuid' > "$d07b/.rite/session-id"
printf '%s' "$uuid_old" > "$d07b/.rite-session-id"
out=$(bash "$SID_HELPER" "$d07b" 2>/dev/null)
assert "T-07 invalid new does not use valid old" "" "$out"

# T-06: one-liner order in skills + SoT
echo "T-06: plugin-root one-liner order"
needle='cat .rite/plugin-root 2>/dev/null || cat .rite-plugin-root 2>/dev/null || bash -c'
hits=$(grep -rF "$needle" "$REPO_ROOT/plugins/rite/skills" "$REPO_ROOT/plugins/rite/references/plugin-path-resolution.md" "$REPO_ROOT/plugins/rite/references/wiki-patterns.md" | wc -l | tr -d ' ')
assert "T-06 one-liner order present (>=15 sites, hits=$hits)" "yes" "$( [ "${hits:-0}" -ge 15 ] && echo yes || echo no )"
# skills must not cat the legacy file as the first (only) source
bare=$(grep -rI --include='*.md' -n 'plugin_root=$(cat \.rite-plugin-root' "$REPO_ROOT/plugins/rite/skills" || true)
assert "T-06 no skill one-liner starts at legacy path" "" "$bare"

# cleanup both dirs
echo "cleanup-work-memory deletes new, old, and both"
dcn="$TEST_DIR/cnew"; mkdir -p "$dcn/.rite/work-memory"; echo x > "$dcn/.rite/work-memory/issue-1.md"
( cd "$dcn" && bash "$CLEANUP_WM" --issue 1 >/dev/null )
[ ! -f "$dcn/.rite/work-memory/issue-1.md" ]
assert "cleanup new-only" "0" "$?"
dco="$TEST_DIR/cold"; mkdir -p "$dco/.rite-work-memory"; echo x > "$dco/.rite-work-memory/issue-1.md"
( cd "$dco" && bash "$CLEANUP_WM" --issue 1 >/dev/null )
[ ! -f "$dco/.rite-work-memory/issue-1.md" ]
assert "cleanup old-only" "0" "$?"
dcb="$TEST_DIR/cboth"
mkdir -p "$dcb/.rite/work-memory" "$dcb/.rite-work-memory"
echo n > "$dcb/.rite/work-memory/issue-1.md"
echo o > "$dcb/.rite-work-memory/issue-1.md"
( cd "$dcb" && bash "$CLEANUP_WM" --issue 1 >/dev/null )
[ ! -f "$dcb/.rite/work-memory/issue-1.md" ] && [ ! -f "$dcb/.rite-work-memory/issue-1.md" ]
assert "cleanup both dirs" "0" "$?"

# open worktree copy contract (static)
echo "open worktree copy prefers new dest"
open_md="$REPO_ROOT/plugins/rite/skills/open/SKILL.md"
grep -q 'cp "$repo_root/.rite/plugin-root" "$wt_path/.rite/plugin-root"' "$open_md"
assert "open copies new→new" "0" "$?"
grep -q 'cp "$repo_root/.rite-plugin-root" "$wt_path/.rite/plugin-root"' "$open_md"
assert "open copies old→new when only old exists" "0" "$?"
grep -qF "_ensure_dir_gitignore \"\$wt_path/.rite\" '!wiki/' '!wiki/**'" "$open_md"
assert "open 2.3-W writes .rite nested gitignore" "0" "$?"

echo "Read dual-path mentions legacy WM"
for f in skills/issue-update/SKILL.md skills/pr-create/SKILL.md skills/pr-review/SKILL.md \
         skills/ready/SKILL.md skills/rite-workflow/references/work-memory-format.md; do
  grep -qF '.rite-work-memory' "$REPO_ROOT/plugins/rite/$f"
  assert "Read dual-path in $(basename "$(dirname "$f")")/$(basename "$f")" "0" "$?"
done

# umask 077 on new session-id
echo "session-id umask 077 on new path"
dperm="$TEST_DIR/perm"
mkdir -p "$dperm"
run_session_start "$dperm" "$sid01"
perm=$(stat -c '%a' "$dperm/.rite/session-id" 2>/dev/null || stat -f '%OLp' "$dperm/.rite/session-id")
assert "session-id mode 600" "600" "$perm"

if ! print_summary "$(basename "$0")" " relocated runtime state"; then
  exit 1
fi
