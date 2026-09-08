#!/bin/bash
# Distribution-only lifecycle integration; external writes stay in a gh fixture.
set -euo pipefail
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_SCRIPT_DIR/_test-helpers.sh"
source "$TEST_SCRIPT_DIR/../scripts/lib/tempfile.sh"
rite_tempfile_init
rite_tempdir_new TEST_ROOT host-runtime-test
cp -R "$TEST_SCRIPT_DIR/../.." "$TEST_ROOT/distribution"
HOOKS="$TEST_ROOT/distribution/hooks"
REPO="$TEST_ROOT/consumer"
mkdir -p "$REPO" "$TEST_ROOT/bin"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b feat/issue-42
git -C "$REPO" remote add origin https://github.com/testowner/testrepo.git
printf 'schema_version: 2\n' > "$REPO/rite-config.yml"
printf 'readme\n' > "$REPO/README.md"
git -C "$REPO" add README.md rite-config.yml
git -C "$REPO" -c user.email=t@t.local -c user.name=t commit -qm fixture
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST RITE_STATE_ROOT CWD
export RITE_HOST=codex CODEX_THREAD_ID=12345678-1234-4234-8234-123456789abc
export TEST_ROOT
export PATH="$TEST_ROOT/bin:$PATH"
cat > "$TEST_ROOT/replica.md" <<'BODY'
## 📜 rite 作業メモリ

### セッション情報
- **Issue**: #42
- **最終更新**: 2026-01-01T00:00:00Z
- **フェーズ**: init
- **フェーズ詳細**: initialize

### 次のステップ
1. Continue workflow
BODY
cat > "$TEST_ROOT/bin/gh" <<'SHIM'
#!/bin/bash
case " $* " in
  *" -X PATCH "*)
    [ "${GH_FAIL_PATCH:-0}" != 1 ] || exit 23
    echo PATCH >> "$TEST_ROOT/effects"
    jq -r '.body' > "$TEST_ROOT/replica.md"
    exit 0 ;;
esac
case "$1 $2" in
  "repo view") echo testowner/testrepo ;;
  "api repos/testowner/testrepo/issues/comments/4242") cat "$TEST_ROOT/replica.md" ;;
  "api repos/testowner/testrepo/issues/42/comments") jq -n --rawfile body "$TEST_ROOT/replica.md" '{id:4242,body:$body}' ;;
  *) echo 'unexpected gh fixture call' >&2; exit 17 ;;
esac
SHIM
chmod +x "$TEST_ROOT/bin/gh"
run_boundary() { bash "$HOOKS/host-runtime.sh" "$1" --cwd "$REPO" --mode explicit "${@:2}"; }
run_flow() { (cd "$REPO" && bash "$HOOKS/flow-state.sh" "$@"); }
run_auto_hook() {
  jq -nc --arg cwd "$REPO" --arg sid "$CODEX_THREAD_ID" '{cwd:$cwd,session_id:$sid,tool_name:"Bash"}' |
    bash "$HOOKS/post-tool-wm-sync.sh"
}
state="$REPO/.rite/sessions/$CODEX_THREAD_ID.flow-state"
foreign="$REPO/.rite/sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.flow-state"
mkdir -p "$(dirname "$foreign")"
printf '{"schema_version":1,"session_id":"foreign","active":true}\n' > "$foreign"
printf 'foreign-legacy\n' > "$REPO/.rite-flow-state"
printf 'foreign-marker\n' > "$REPO/.rite/session-id"
run_boundary init > "$TEST_ROOT/init.out"
assert 'distribution init writes its plugin root' "$TEST_ROOT/distribution" "$(cat "$REPO/.rite/plugin-root")"
assert 'explicit init preserves shared session marker' foreign-marker "$(cat "$REPO/.rite/session-id")"
assert 'explicit init preserves legacy state' foreign-legacy "$(cat "$REPO/.rite-flow-state")"
assert 'explicit init does not migrate foreign state' 1 "$(jq -r .schema_version "$foreign")"
run_flow set --phase branch --issue 42 --branch feat/issue-42 --next 'Continue planning' > /dev/null
(cd "$REPO" && bash "$HOOKS/issue-claim.sh" claim --issue 42) > "$TEST_ROOT/claim.out"
assert 'claim uses the runtime owner' "$CODEX_THREAD_ID" "$(jq -r .session_id "$REPO/.rite/state/issue-claims/issue-42.json")"
run_boundary checkpoint > "$TEST_ROOT/checkpoint.out"
assert 'checkpoint uses the runtime flow state' "$CODEX_THREAD_ID" "$(jq -r .session_id "$state")"
assert 'replica actually receives phase change' branch "$(sed -n 's/^- \*\*フェーズ\*\*: //p' "$TEST_ROOT/replica.md")"
assert 'explicit checkpoint makes one PATCH' 1 "$(wc -l < "$TEST_ROOT/effects" | tr -d ' ')"
wm="$REPO/.rite/work-memory/issue-42.md"
revision=$(python3 "$HOOKS/work-memory-parse.py" "$wm" | jq -r .data.sync_revision)
run_auto_hook > "$TEST_ROOT/auto.out"
run_boundary checkpoint > "$TEST_ROOT/repeat.out"
assert 'explicit then automatic/repeated explicit does not duplicate PATCH' 1 "$(wc -l < "$TEST_ROOT/effects" | tr -d ' ')"
assert 'identical checkpoint keeps local WM revision' "$revision" "$(python3 "$HOOKS/work-memory-parse.py" "$wm" | jq -r .data.sync_revision)"
run_flow set --phase plan --issue 42 --pr 43 --branch feat/issue-42 --next 'Implement approved plan' > /dev/null
run_auto_hook > "$TEST_ROOT/auto-first.out"
run_boundary checkpoint > "$TEST_ROOT/explicit-second.out"
assert 'automatic then explicit does not duplicate PATCH' 2 "$(wc -l < "$TEST_ROOT/effects" | tr -d ' ')"
assert 'local WM follows state after automatic sync' plan "$(python3 "$HOOKS/work-memory-parse.py" "$wm" | jq -r .data.phase)"
assert 'local WM follows a newly assigned PR' 43 "$(python3 "$HOOKS/work-memory-parse.py" "$wm" | jq -r .data.pr_number)"
run_boundary next > "$TEST_ROOT/resume.out"
assert 'resume exposes exact next action' 'Implement approved plan' "$(jq -r .next_action "$TEST_ROOT/resume.out")"
assert 'resume keeps owner' "$CODEX_THREAD_ID" "$(jq -r .session_id "$state")"

run_flow set --phase branch --issue 42 --branch feat/issue-42 --next 'Inspect alternatives' > /dev/null
rc=0
GH_FAIL_PATCH=1 run_boundary checkpoint > "$TEST_ROOT/failure.out" 2> "$TEST_ROOT/failure.err" || rc=$?
assert 'replica helper failure fails the explicit boundary' 1 "$rc"
assert 'failed sync preserves retry phase' plan "$(jq -r .last_synced_phase "$state")"
assert 'failed sync leaves remote replica unchanged' plan "$(sed -n 's/^- \*\*フェーズ\*\*: //p' "$TEST_ROOT/replica.md")"
run_boundary checkpoint > "$TEST_ROOT/retry.out"
assert 'successful retry advances sync phase' branch "$(jq -r .last_synced_phase "$state")"

jq -n --arg command "touch $TEST_ROOT/never-executed" '{tool_name:"Bash",tool_input:{command:$command}}' > "$TEST_ROOT/tool.json"
run_boundary before-bash --payload-file "$TEST_ROOT/tool.json" > "$TEST_ROOT/guard.out"
assert 'command guard never executes the proposed command' false "$([ -f "$TEST_ROOT/never-executed" ] && echo true || echo false)"
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"gh issue create --title forbidden"}}' > "$TEST_ROOT/tool.json"
rc=0
run_boundary before-bash --payload-file "$TEST_ROOT/tool.json" > "$TEST_ROOT/deny.out" 2> "$TEST_ROOT/deny.err" || rc=$?
assert 'native deny JSON becomes an explicit stop status' 2 "$rc"
assert 'deny output preserves permissionDecision' deny "$(jq -r .hookSpecificOutput.permissionDecision "$TEST_ROOT/deny.out")"
jq -n --arg file "$REPO/README.md" '{tool_name:"Edit",tool_input:{file_path:$file},subagent_type:"reviewer"}' > "$TEST_ROOT/tool.json"
rc=0
run_boundary before-edit --payload-file "$TEST_ROOT/tool.json" > "$TEST_ROOT/edit-deny.out" 2> "$TEST_ROOT/edit-deny.err" || rc=$?
assert 'reviewer edit is stopped before parent worktree mutation' 2 "$rc"
printf '%s\n' '{"toolName":"Bash","toolInput":{"command":"echo unsafe"},"sessionId":"other"}' > "$TEST_ROOT/tool.json"
rc=0
run_boundary before-bash --payload-file "$TEST_ROOT/tool.json" > /dev/null 2> "$TEST_ROOT/invalid.err" || rc=$?
assert 'untranslated camelCase payload is rejected' 1 "$rc"
rc=0
run_boundary init --session '../foreign' > /dev/null 2> "$TEST_ROOT/identity.err" || rc=$?
assert 'invalid identity is rejected' 1 "$rc"
assert 'invalid operation keeps foreign state unchanged' 1 "$(jq -r .schema_version "$foreign")"
assert 'invalid operation keeps legacy state unchanged' foreign-legacy "$(cat "$REPO/.rite-flow-state")"

mv "$HOOKS/pre-tool-bash-guard.sh" "$HOOKS/pre-tool-bash-guard.saved"
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"echo allowed"}}' > "$TEST_ROOT/tool.json"
rc=0
run_boundary before-bash --payload-file "$TEST_ROOT/tool.json" > /dev/null 2> "$TEST_ROOT/missing.err" || rc=$?
assert 'missing required guard cannot report success' 1 "$rc"
count=$(wc -l < "$TEST_ROOT/effects" | tr -d ' ')
bash "$HOOKS/host-runtime.sh" checkpoint --cwd "$REPO" --mode auto > "$TEST_ROOT/native.out"
assert 'auto selection does not dispatch explicit side effects' "$count" "$(wc -l < "$TEST_ROOT/effects" | tr -d ' ')"
# Shared state and local WM must describe the actual linked working tree.
LINKED="$TEST_ROOT/linked"
git -C "$REPO" worktree add -qb feat/issue-42-linked "$LINKED"
printf 'linked change\n' >> "$LINKED/README.md"
git -C "$LINKED" add README.md
git -C "$LINKED" -c user.email=t@t.local -c user.name=t commit -qm linked
bash "$HOOKS/host-runtime.sh" checkpoint --cwd "$LINKED" --mode explicit > "$TEST_ROOT/linked.out"
assert 'linked worktree sync uses shared local WM' false "$([ -f "$LINKED/.rite/work-memory/issue-42.md" ] && echo true || echo false)"
assert 'shared local WM records the actual worktree branch' feat/issue-42-linked "$(python3 "$HOOKS/work-memory-parse.py" "$wm" | jq -r .data.branch)"
assert 'shared local WM records the actual worktree commit' "$(git -C "$LINKED" rev-parse --short HEAD)" "$(python3 "$HOOKS/work-memory-parse.py" "$wm" | jq -r .data.last_commit)"

# The edit checkpoint keeps native warn-only findings but fails missing helpers.
mkdir -p "$REPO/plugins/rite/skills/example"
printf '%s\n' 'Literal ` !` is unsafe in a command example.' > "$REPO/plugins/rite/skills/example/SKILL.md"
jq -n --arg file "$REPO/plugins/rite/skills/example/SKILL.md" '{tool_name:"Edit",tool_input:{file_path:$file}}' > "$TEST_ROOT/tool.json"
run_boundary after-edit --payload-file "$TEST_ROOT/tool.json" > "$TEST_ROOT/bang.out" 2> "$TEST_ROOT/bang.err"
assert_grep 'after-edit runs the existing bang guard' "$TEST_ROOT/bang.err" 'bang-backtick adjacency detected'
mv "$HOOKS/scripts/bang-backtick-check.sh" "$HOOKS/scripts/bang-backtick-check.saved"
rc=0
run_boundary after-edit --payload-file "$TEST_ROOT/tool.json" > /dev/null 2> "$TEST_ROOT/bang-missing.err" || rc=$?
assert 'after-edit helper failure is observable' 2 "$rc"

# The native Claude payload can bootstrap the shell identity without borrowing
# a shared marker. Shell metacharacters stay literal when the host env is loaded.
CLAUDE_TEST_SID="claude-'quoted'"
claude_input=$(jq -nc --arg cwd "$REPO" --arg sid "$CLAUDE_TEST_SID" '{cwd:$cwd,session_id:$sid,source:"explicit"}')
for repeat in 1 2; do
  printf '%s' "$claude_input" | RITE_HOST=claude CLAUDE_CODE_SESSION_ID= CLAUDE_SESSION_ID= \
    CLAUDE_ENV_FILE="$TEST_ROOT/claude.env" RITE_RUNTIME_EXPLICIT=1 bash "$HOOKS/session-start.sh"
done
assert 'Claude payload bootstrap is shell quoted and readable' "$CLAUDE_TEST_SID" "$(bash -c 'source "$1"; printf "%s" "$CLAUDE_CODE_SESSION_ID"' bash "$TEST_ROOT/claude.env")"
assert 'native bootstrap does not duplicate env side effects' 1 "$(wc -l < "$TEST_ROOT/claude.env" | tr -d ' ')"
assert 'native bootstrap preserves foreign shared marker' foreign-marker "$(cat "$REPO/.rite/session-id")"
rc=0
printf '%s' "$claude_input" | RITE_HOST=codex CODEX_THREAD_ID= bash "$HOOKS/session-start.sh" > /dev/null 2> "$TEST_ROOT/native-invalid.err" || rc=$?
assert 'missing Codex identity never borrows a Claude payload' 1 "$rc"

cp "$HOOKS/flow-state.sh" "$HOOKS/flow-state.saved"
printf '#!/bin/bash\nexit 23\n' > "$HOOKS/flow-state.sh"
rc=0
run_boundary next > /dev/null 2> "$TEST_ROOT/next-failure.err" || rc=$?
assert 'failed state resolver cannot become an empty successful resume' 23 "$rc"
print_summary host-runtime.test.sh
