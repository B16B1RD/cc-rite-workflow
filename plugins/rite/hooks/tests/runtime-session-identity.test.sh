#!/bin/bash
# Exercise real distributed helpers against a checkout shared by three hosts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS="$PLUGIN_ROOT/hooks"
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST RITE_STATE_ROOT
ROOT=$(make_sandbox --branch develop)
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT
cd "$ROOT"
export RITE_STATE_ROOT="$ROOT" WM_PLUGIN_ROOT="$PLUGIN_ROOT"
SID_C=aaaaaaaa-1111-2222-3333-444444444444
SID_X=bbbbbbbb-1111-2222-3333-444444444444
SID_G=cccccccc-1111-2222-3333-444444444444
FOREIGN=dddddddd-1111-2222-3333-444444444444

host_env() {
  local host="$1" sid="$2"; shift 2
  local variable
  case "$host" in claude) variable=CLAUDE_CODE_SESSION_ID;; codex) variable=CODEX_THREAD_ID;; grok) variable=GROK_SESSION_ID;; esac
  env RITE_HOST="$host" "$variable=$sid" "$@"
}
wm_update() {
  local host="$1" sid="$2" issue="$3"; shift 3
  host_env "$host" "$sid" env WM_ISSUE_NUMBER="$issue" WM_SOURCE=test WM_PHASE=implement \
    WM_PHASE_DETAIL=running WM_NEXT_ACTION=review WM_BODY_TEXT=fixture \
    WM_REQUIRE_FLOW_STATE=true WM_READ_FROM_FLOW_STATE=true "$@" bash -c \
    'source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh"; update_local_work_memory'
}
seed_host() {
  local host="$1" sid="$2" issue="$3"
  host_env "$host" "$sid" bash "$HOOKS/flow-state.sh" set --phase implement --issue "$issue" --pr "$((issue + 100))" --next review >/dev/null
  host_env "$host" "$sid" bash "$HOOKS/issue-claim.sh" claim --issue "$issue" >/dev/null
  local resolved_path queue_sid
  resolved_path=$(host_env "$host" "$sid" bash "$HOOKS/flow-state.sh" path)
  queue_sid=$(basename "$resolved_path" .flow-state)
  mkdir -p "$ROOT/.rite/state"
  jq -n --argjson issue "$issue" '{issues:[$issue], cursor:0, mode:"merge"}' > "$ROOT/.rite/state/run-queue-$queue_sid.json"
  wm_update "$host" "$sid" "$issue" >/dev/null
}

# Both shared file generations deliberately point to a fourth, unrelated owner.
mkdir -p "$ROOT/.rite"
printf '%s' "$FOREIGN" > "$ROOT/.rite/session-id"
printf '%s' "$FOREIGN" > "$ROOT/.rite-session-id"
bash "$HOOKS/flow-state.sh" set --session "$FOREIGN" --phase implement --issue 99 --next review >/dev/null
printf '{"active":true,"session_id":"%s","issue_number":99}' "$FOREIGN" > "$ROOT/.rite-flow-state"
seed_host claude "$SID_C" 21 & pid_c=$!
seed_host codex "$SID_X" 22 & pid_x=$!
seed_host grok "$SID_G" 23 & pid_g=$!
for pid in "$pid_c" "$pid_x" "$pid_g"; do
  if wait "$pid"; then pass "concurrent host completes state/claim/queue/WM"; else fail "concurrent host failed"; fi
done
for spec in "claude $SID_C 21" "codex $SID_X 22" "grok $SID_G 23"; do
  read -r host sid issue <<< "$spec"
  assert "$host state belongs to runtime ID" "$sid" "$(jq -r .session_id "$ROOT/.rite/sessions/$sid.flow-state")"
  assert "$host issue identity" "$issue" "$(host_env "$host" "$sid" bash "$HOOKS/flow-state.sh" get --field issue_number)"
  assert "$host claim owner" "$sid" "$(jq -r .session_id "$ROOT/.rite/state/issue-claims/issue-$issue.json")"
  assert "$host queue uses same state owner" "$issue" "$(jq -r '.issues[0]' "$ROOT/.rite/state/run-queue-$sid.json")"
  assert_grep "$host WM reads its own PR" "$ROOT/.rite/work-memory/issue-$issue.md" "^pr_number: $((issue + 100))$"
  assert "$host restart reuses claim" own "$(host_env "$host" "$sid" bash "$HOOKS/issue-claim.sh" claim --issue "$issue")"
  assert "$host restart reuses queue" 0 "$(jq -r .cursor "$ROOT/.rite/state/run-queue-$sid.json")"
done
assert "shared session-id remains foreign" "$FOREIGN" "$(cat "$ROOT/.rite/session-id")"

assert "Codex acquires wiki lock" acquired "$(host_env codex "$SID_X" bash "$HOOKS/scripts/wiki-ingest-lock.sh" acquire)"
assert "wiki lock owner matches Codex state" "$SID_X" "$(cat "$ROOT/.rite/state/wiki-ingest-session.lockdir/session_id")"
assert "same Codex restart owns wiki lock" own "$(host_env codex "$SID_X" bash "$HOOKS/scripts/wiki-ingest-lock.sh" check)"
for spec in "claude $SID_C" "grok $SID_G"; do
  read -r host sid <<< "$spec"
  rc=0; host_env "$host" "$sid" bash "$HOOKS/scripts/wiki-ingest-lock.sh" acquire >/dev/null 2>&1 || rc=$?
  assert "$host cannot acquire live Codex lock" 11 "$rc"
  assert "$host cannot release Codex lock" skipped "$(host_env "$host" "$sid" bash "$HOOKS/scripts/wiki-ingest-lock.sh" release 2>/dev/null)"
done

# Selection is explicit, retains Claude priority, and never guesses among hosts.
assert "explicit host ignores conflicting foreign host env" "$SID_X" "$(env RITE_HOST=codex CODEX_THREAD_ID="$SID_X" CLAUDE_CODE_SESSION_ID="$SID_C" GROK_SESSION_ID="$SID_G" bash "$HOOKS/session-identity.sh")"
assert "Claude CODE env keeps priority" "$SID_C" "$(env CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_SESSION_ID="$FOREIGN" bash "$HOOKS/session-identity.sh")"
assert "Claude legacy env remains accepted" "$SID_C" "$(env CLAUDE_SESSION_ID="$SID_C" bash "$HOOKS/session-identity.sh")"
assert "Codex autodetection" "$SID_X" "$(env CODEX_THREAD_ID="$SID_X" bash "$HOOKS/session-identity.sh")"
assert "Grok autodetection" "$SID_G" "$(env GROK_SESSION_ID="$SID_G" bash "$HOOKS/session-identity.sh")"
assert "UUID normalization shared with strict consumers" "$SID_X" "$(env RITE_HOST=codex CODEX_THREAD_ID="$(printf '%s' "$SID_X" | tr 'a-f' 'A-F')" bash "$HOOKS/session-identity.sh")"
assert "explicit session bypasses missing selected host" "$ROOT/.rite/sessions/$SID_C.flow-state" "$(env RITE_HOST=codex bash "$HOOKS/flow-state.sh" path --session "$SID_C")"
assert "explicit strict session bypasses ambiguity" own "$(env CODEX_THREAD_ID="$SID_X" GROK_SESSION_ID="$SID_G" bash "$HOOKS/issue-claim.sh" check --issue 21 --session "$SID_C")"
assert "opaque runtime ID retains Layer 1" "$ROOT/.rite/sessions/opaque-session.flow-state" "$(host_env grok opaque-session bash "$HOOKS/flow-state.sh" path)"
rc=0; host_env grok opaque-session bash "$HOOKS/issue-claim.sh" claim --issue 24 >/dev/null 2>&1 || rc=$?
assert "opaque runtime ID rejected by strict claim without file fallback" 1 "$rc"
rc=0; host_env grok opaque-session bash "$HOOKS/scripts/wiki-ingest-lock.sh" release >/dev/null 2>&1 || rc=$?
assert "opaque runtime ID cannot release lock via legacy identity" 1 "$rc"

snapshot() {
  python3 - "$ROOT" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = sorted(p for p in root.rglob('*') if p.is_file() and '.git' not in p.parts)
h = hashlib.sha256()
for path in files:
    h.update(str(path.relative_to(root)).encode())
    h.update(path.read_bytes())
print(h.hexdigest())
PY
}
before=$(snapshot)
for scenario in missing_codex missing_grok empty_codex invalid_codex invalid_grok multiple same_id_multiple unknown; do
  bad_env=()
  case "$scenario" in
    missing_codex) bad_env=(RITE_HOST=codex);;
    missing_grok) bad_env=(RITE_HOST=grok);;
    empty_codex) bad_env=(CODEX_THREAD_ID=);;
    invalid_codex) bad_env=(RITE_HOST=codex CODEX_THREAD_ID=../foreign);;
    invalid_grok) bad_env=(RITE_HOST=grok GROK_SESSION_ID=$'bad\nsession');;
    multiple) bad_env=(CODEX_THREAD_ID="$SID_X" GROK_SESSION_ID="$SID_G");;
    same_id_multiple) bad_env=(CLAUDE_CODE_SESSION_ID="$SID_C" CODEX_THREAD_ID="$SID_C");;
    unknown) bad_env=(RITE_HOST=unsupported);;
  esac
  for operation in state_read state_write claim release_claim release_lock cleanup cleanup_issue sync wm; do
    command=()
    case "$operation" in
      state_read) command=(bash "$HOOKS/flow-state.sh" get --field issue_number --default 99);;
      state_write) command=(bash "$HOOKS/flow-state.sh" set --phase cleanup --issue 99 --next done);;
      claim) command=(bash "$HOOKS/issue-claim.sh" claim --issue 99);;
      release_claim) command=(bash "$HOOKS/issue-claim.sh" release --issue 22);;
      release_lock) command=(bash "$HOOKS/scripts/wiki-ingest-lock.sh" release);;
      cleanup) command=(bash "$HOOKS/cleanup-work-memory.sh");;
      cleanup_issue) command=(bash "$HOOKS/cleanup-work-memory.sh" --issue 22);;
      sync) command=(bash "$HOOKS/issue-comment-wm-sync.sh" fetch --issue 22 --out "$ROOT/should-not-exist");;
      wm) command=(env WM_ISSUE_NUMBER=22 WM_SOURCE=test WM_PHASE=cleanup WM_PHASE_DETAIL=test WM_NEXT_ACTION=none WM_BODY_TEXT=bad bash -c 'source "$WM_PLUGIN_ROOT/hooks/work-memory-update.sh"; update_local_work_memory');;
    esac
    rc=0
    out=$(env "${bad_env[@]}" "${command[@]}" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *ERROR:* ]]; then
      pass "$scenario $operation fails with diagnostic"
    else
      fail "$scenario $operation must fail loudly (rc=$rc): $out"
    fi
  done
  assert "$scenario leaves foreign/legacy/state/queue/WM/lock untouched" "$before" "$(snapshot)"
done

# Successful cleanup also keeps the other concurrently active host's WM intact.
host_env claude "$SID_C" bash "$HOOKS/cleanup-work-memory.sh" >/dev/null
assert "cleanup retains session owner" "$SID_C" "$(jq -r .session_id "$ROOT/.rite/sessions/$SID_C.flow-state")"
assert "own cleanup resets own flow-state" false "$(jq -r .active "$ROOT/.rite/sessions/$SID_C.flow-state")"
assert "own cleanup removes own WM" false "$(test -e "$ROOT/.rite/work-memory/issue-21.md" && echo true || echo false)"
assert_file_exists_or_fail "Codex WM survives Claude cleanup" "$ROOT/.rite/work-memory/issue-22.md"
assert_file_exists_or_fail "Grok WM survives Claude cleanup" "$ROOT/.rite/work-memory/issue-23.md"
assert "Codex remains active" true "$(jq -r .active "$ROOT/.rite/sessions/$SID_X.flow-state")"
print_summary "$(basename "$0")"
