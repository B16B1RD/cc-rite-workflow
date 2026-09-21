#!/usr/bin/env bash
# Wiki apply record: commit gate, review mismatch, and the two commit boundaries.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../scripts/wiki-apply-gate.sh"
CAPTURE="$SCRIPT_DIR/../scripts/wiki-apply-capture.sh"
COMMIT="$SCRIPT_DIR/../scripts/git-commit-file.sh"
GUARD="$SCRIPT_DIR/../pre-tool-bash-guard.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rite-wiki-apply-XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

new_repo() {
  local repo="$ROOT/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@test.local
  git -C "$repo" config user.name test
  git -C "$repo" config commit.gpgsign false
  printf 'init\n' > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -qm init
  (CDPATH= cd -- "$repo" && pwd -P)
}

write_flow() {
  local path="$1" phase="$2" issue="$3" wt="$4"
  jq -n --arg phase "$phase" --argjson issue "$issue" --arg wt "$wt" \
    '{phase:$phase, issue_number:$issue, worktree:$wt}' > "$path"
}

write_mem() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "# 📜 rite 作業メモリ" "" "## Detail" "$body" > "$path"
}

run_gate() {
  local rc=0
  GOUT=$(bash "$GATE" "$@" 2>"$ROOT/gate.err") || rc=$?
  GRC=$rc
}

echo "=== record missing ==="
repo=$(new_repo missing)
flow="$ROOT/missing.flow-state"
write_flow "$flow" implement 7 "$repo"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$ROOT/no-such.md"
if [ "$GRC" -eq 1 ] && grep -q 'reason=record_missing' <<<"$GOUT"; then
  pass "missing record denies"
else
  fail "missing record rc=$GRC out=$GOUT"
fi

base_block() {
  cat <<EOF
### Wiki 適用証跡
issue: 7
session: missing
worktree: $repo
query: widget
status: $1
attempts: 1
diagnostic: -
paths: README
EOF
}

echo "=== none and disabled allow; error and uninitialized deny ==="
mem="$ROOT/mem.md"
write_mem "$mem" "$(base_block none)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "none allows"
else
  fail "none rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(base_block disabled)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "disabled allows"
else
  fail "disabled rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(base_block error)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=status_error' <<<"$GOUT"; then
  pass "error denies"
else
  fail "error rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(base_block uninitialized)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=status_uninitialized' <<<"$GOUT"; then
  pass "uninitialized denies"
else
  fail "uninitialized rc=$GRC out=$GOUT"
fi

echo "=== field gaps and freshness ==="
ok_page() {
  local body="$1" decision="$2" reason="$3" evidence="$4"
  cat <<EOF
### Wiki 適用証跡
issue: 7
session: missing
worktree: $repo
query: widget
status: ok
attempts: 1
diagnostic: -
paths: README
page: pages/a.md
rev: abc
body: $body
decision: $decision
reason: $reason
evidence: $evidence
EOF
}
write_mem "$mem" "$(ok_page - applied because README)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=body_missing' <<<"$GOUT"; then pass "body missing"; else fail "body rc=$GRC out=$GOUT"; fi
write_mem "$mem" "$(ok_page read - because README)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=decision_missing' <<<"$GOUT"; then pass "decision missing"; else fail "decision rc=$GRC out=$GOUT"; fi
write_mem "$mem" "$(ok_page read applied '' README)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=reason_missing' <<<"$GOUT"; then pass "reason missing"; else fail "reason rc=$GRC out=$GOUT"; fi
write_mem "$mem" "$(base_block bogus)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=record_corrupt' <<<"$GOUT"; then pass "corrupt status"; else fail "corrupt rc=$GRC out=$GOUT"; fi

other="$ROOT/other.flow-state"
write_flow "$other" implement 7 "$repo"
write_mem "$mem" "$(ok_page read out '対象外' -)"
# session in the block is "missing" but this flow file's session is "other"
run_gate --mode commit --worktree "$repo" --flow-state "$other" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=session_mismatch' <<<"$GOUT"; then pass "session mismatch"; else fail "session rc=$GRC out=$GOUT"; fi

issue_flow="$ROOT/issue.flow-state"
write_flow "$issue_flow" implement 8 "$repo"
run_gate --mode commit --worktree "$repo" --flow-state "$issue_flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=issue_mismatch' <<<"$GOUT"; then pass "issue mismatch"; else fail "issue rc=$GRC out=$GOUT"; fi

wt_flow="$ROOT/wt.flow-state"
write_flow "$wt_flow" implement 7 "$repo"
write_mem "$mem" "$(ok_page read out '対象外' - | sed -e 's#^worktree: .*#worktree: /tmp/not-the-repo#' -e 's#^session: .*#session: wt#')"
run_gate --mode review --worktree "$repo" --flow-state "$wt_flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=worktree_mismatch' <<<"$GOUT"; then pass "worktree mismatch"; else fail "worktree rc=$GRC out=$GOUT"; fi

printf 'more\n' >> "$repo/OTHER"
git -C "$repo" add OTHER
write_mem "$mem" "$(ok_page read out '対象外' -)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=paths' <<<"$GOUT"; then pass "added path denies"; else fail "paths rc=$GRC out=$GOUT"; fi
git -C "$repo" reset -q HEAD -- OTHER
rm -f "$repo/OTHER"

echo "=== review evidence ==="
printf 'evidence line\n' >> "$repo/README"
git -C "$repo" add README
git -C "$repo" commit -qm 'show evidence'
write_mem "$mem" "$(ok_page read applied '対策を README へ書いた' README)"
run_gate --mode review --worktree "$repo" --base "$(git -C "$repo" rev-parse HEAD~1)" --flow-state "$flow" --memory "$mem"
# base...HEAD with base=parent should include README. The gate's --base is a branch name
# used as BASE...HEAD. A raw sha works as a revision.
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "review evidence in diff allows"
else
  fail "review allow rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(ok_page read applied '対策を書いた' 'not-in-diff.txt')"
run_gate --mode review --worktree "$repo" --base "$(git -C "$repo" rev-parse HEAD~1)" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=evidence_mismatch' <<<"$GOUT"; then
  pass "review evidence mismatch denies"
else
  fail "review deny rc=$GRC out=$GOUT"
fi

echo "=== phase cleanup skips ==="
clean="$ROOT/clean.flow-state"
write_flow "$clean" cleanup 7 "$repo"
run_gate --mode commit --worktree "$repo" --flow-state "$clean" --memory "$ROOT/no-such.md"
if [ "$GRC" -eq 0 ] && grep -q 'reason=phase' <<<"$GOUT"; then
  pass "cleanup phase skips"
else
  fail "cleanup rc=$GRC out=$GOUT"
fi

echo "=== git-commit-file deny does not move HEAD ==="
head_before=$(git -C "$repo" rev-parse HEAD)
msg="$ROOT/msg.txt"
printf 'feat: should not land\n\nwhy\n' > "$msg"
crc=0
WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$repo" >/tmp/wiki-apply-commit.out 2>"$ROOT/commit.err" || crc=$?
head_after=$(git -C "$repo" rev-parse HEAD)
if [ "$crc" -ne 0 ] && [ "$head_before" = "$head_after" ]; then
  pass "denied commit leaves HEAD"
else
  fail "commit rc=$crc before=$head_before after=$head_after err=$(cat "$ROOT/commit.err")"
fi

echo "=== missing gate script does not commit ==="
copy="$ROOT/copy"
mkdir -p "$copy/hooks/scripts/lib"
cp "$COMMIT" "$copy/hooks/scripts/git-commit-file.sh"
cp "$SCRIPT_DIR/../control-char-neutralize.sh" "$copy/hooks/control-char-neutralize.sh"
cp "$SCRIPT_DIR/../scripts/lib/canon-path.sh" "$copy/hooks/scripts/lib/canon-path.sh"
head_before=$(git -C "$repo" rev-parse HEAD)
crc=0
bash "$copy/hooks/scripts/git-commit-file.sh" --file "$msg" --worktree "$repo" >"$ROOT/copy.out" 2>"$ROOT/copy.err" || crc=$?
head_after=$(git -C "$repo" rev-parse HEAD)
if [ "$crc" -ne 0 ] && [ "$head_before" = "$head_after" ] && grep -q 'wiki apply gate が無い' <<<"$(cat "$ROOT/copy.err")"; then
  pass "missing script does not commit"
else
  fail "missing script rc=$crc err=$(cat "$ROOT/copy.err")"
fi

echo "=== guard deny and cleanup allow ==="
gin=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git commit -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$gin" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'permissionDecision' <<<"$gout" && grep -q 'deny' <<<"$gout" && grep -q 'wiki-apply-gate' <<<"$gout"; then
  pass "guard denies implement commit"
else
  fail "guard deny rc=$grc out=$gout"
fi
grc=0
gout=$(printf '%s' "$gin" | WIKI_APPLY_FLOW_STATE="$clean" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if [ "$grc" -eq 0 ] && [ -z "$gout" ]; then
  pass "guard allows cleanup commit"
else
  fail "guard cleanup rc=$grc out=$gout"
fi
grc=0
gout=$(printf '%s' "$gin" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_GATE_BIN="$ROOT/no-gate" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-missing' <<<"$gout"; then
  pass "guard denies when the gate script is missing"
else
  fail "guard missing rc=$grc out=$gout"
fi

echo "=== capture records auto_query_off without searching ==="
cap_repo=$(new_repo cap)
printf '%s\n' 'wiki:' '  enabled: true' '  auto_query: false' > "$cap_repo/rite-config.yml"
cap_flow="$ROOT/cap.flow-state"
write_flow "$cap_flow" implement 7 "$cap_repo"
cap_mem="$ROOT/cap.md"
crc=0
bash "$CAPTURE" --keywords widget --cwd "$cap_repo" --flow-state "$cap_flow" --memory "$cap_mem" >"$ROOT/cap.out" 2>"$ROOT/cap.err" || crc=$?
if [ "$crc" -eq 0 ] && grep -q 'status: auto_query_off' "$cap_mem" && grep -q 'WIKI_APPLY_CAPTURE=auto_query_off' <<<"$(cat "$ROOT/cap.out")"; then
  pass "capture records auto_query_off"
else
  fail "capture rc=$crc mem=$(cat "$cap_mem" 2>/dev/null) err=$(cat "$ROOT/cap.err")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
