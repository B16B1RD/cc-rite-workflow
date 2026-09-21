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

write_config() {
  local repo="$1" enabled="$2" auto="$3"
  printf '%s\n' 'wiki:' "  enabled: $enabled" "  auto_query: $auto" > "$repo/rite-config.yml"
}

fresh_header() {
  local status="$1" session="$2" wt="$3" attempts="$4" paths="$5"
  local p oid
  printf '%s\n' \
    "### Wiki 適用証跡" \
    "issue: 7" \
    "session: ${session}" \
    "worktree: ${wt}" \
    "query: widget" \
    "executed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "status: ${status}" \
    "attempts: ${attempts}" \
    "diagnostic: -" \
    "head: $(git -C "$wt" rev-parse HEAD)" \
    "paths: ${paths}"
  IFS=',' read -r -a _ps <<<"$paths"
  for p in "${_ps[@]}"; do
    [ -n "$p" ] || continue
    oid=$(git -C "$wt" hash-object -- "$p")
    printf 'blob: %s=%s\n' "$p" "$oid"
  done
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

echo "=== none and disabled allow only when config agrees ==="
mem="$ROOT/mem.md"
write_config "$repo" true true
write_mem "$mem" "$(fresh_header none missing "$repo" 1 README)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "none allows"
else
  fail "none rc=$GRC out=$GOUT"
fi
write_config "$repo" false true
write_mem "$mem" "$(fresh_header disabled missing "$repo" 0 README)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "disabled allows"
else
  fail "disabled rc=$GRC out=$GOUT"
fi
write_config "$repo" true false
write_mem "$mem" "$(fresh_header auto_query_off missing "$repo" 0 README)"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "auto_query_off allows"
else
  fail "auto_query_off rc=$GRC out=$GOUT"
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
write_config "$repo" true true
ok_page() {
  local body="$1" decision="$2" reason="$3" evidence="$4"
  fresh_header ok missing "$repo" 1 README
  cat <<EOF
page: pages/a.md
rev: abc
excerpt: -
body: $body
decision: $decision
reason: $reason
evidence: $evidence
result: -
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

echo "=== declared status, missing fields, and stale success ==="
drop_line() {
  local key="$1" line
  while IFS= read -r line; do
    case "$line" in
      "${key}:"*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}
age=$(new_repo age)
age_flow="$ROOT/age.flow-state"
write_flow "$age_flow" implement 7 "$age"
age_mem="$ROOT/age.md"
write_mem "$age_mem" "$(fresh_header none age "$age" 1 README)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=config_mismatch' <<<"$GOUT"; then
  pass "none without config denies"
else
  fail "none without config rc=$GRC out=$GOUT"
fi
write_mem "$age_mem" "$(fresh_header disabled age "$age" 0 README)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=config_mismatch' <<<"$GOUT"; then
  pass "disabled without config denies"
else
  fail "disabled without config rc=$GRC out=$GOUT"
fi
write_config "$age" true false
write_mem "$age_mem" "$(fresh_header none age "$age" 1 README)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=config_mismatch' <<<"$GOUT"; then
  pass "none while auto_query is off denies"
else
  fail "none off rc=$GRC out=$GOUT"
fi
write_config "$age" true true
write_mem "$age_mem" "$(fresh_header auto_query_off age "$age" 0 README)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=config_mismatch' <<<"$GOUT"; then
  pass "auto_query_off while search is on denies"
else
  fail "off while on rc=$GRC out=$GOUT"
fi
write_mem "$age_mem" "$(fresh_header disabled age "$age" 0 README)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=config_mismatch' <<<"$GOUT"; then
  pass "disabled while enabled denies"
else
  fail "disabled while enabled rc=$GRC out=$GOUT"
fi
block=$(fresh_header none age "$age" 1 README)
write_mem "$age_mem" "$(printf '%s\n' "$block" | drop_line query)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=query_missing' <<<"$GOUT"; then
  pass "missing query denies"
else
  fail "query rc=$GRC out=$GOUT"
fi
write_mem "$age_mem" "$(printf '%s\n' "$block" | drop_line executed_at)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=executed_at_missing' <<<"$GOUT"; then
  pass "missing executed_at denies"
else
  fail "executed_at rc=$GRC out=$GOUT"
fi
write_mem "$age_mem" "$(printf '%s\n' "$block" | drop_line attempts)"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=attempts_missing' <<<"$GOUT"; then
  pass "missing attempts denies"
else
  fail "attempts rc=$GRC out=$GOUT"
fi
write_mem "$age_mem" "$(fresh_header none age "$age" 1 README)"
printf 'x\n' > "$age/LATER"
git -C "$age" add LATER
git -C "$age" commit -qm 'move head'
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=stale_head' <<<"$GOUT"; then
  pass "old head denies"
else
  fail "stale head rc=$GRC out=$GOUT"
fi
write_mem "$age_mem" "$(fresh_header none age "$age" 1 README)"
printf 'changed\n' >> "$age/README"
run_gate --mode commit --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=stale_content' <<<"$GOUT"; then
  pass "changed file denies"
else
  fail "stale content rc=$GRC out=$GOUT"
fi

echo "=== review evidence ==="
page_rev=$(printf '対象の識別子を照合してから実行する。\n' | git -C "$repo" hash-object -w --stdin)
printf 'evidence line\n' >> "$repo/README"
git -C "$repo" add README
git -C "$repo" commit -qm 'show evidence'
review_base=$(git -C "$repo" rev-parse HEAD~1)
applied_page() {
  local excerpt="$1" evidence="$2" result="$3"
  fresh_header ok missing "$repo" 1 README
  cat <<EOF
page: pages/a.md
rev: $page_rev
excerpt: $excerpt
body: read
decision: applied
reason: 対象の識別子を照合してから実行する
evidence: $evidence
result: $result
EOF
}
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' README 'printf ok')"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "excerpt and result allow commit"
else
  fail "ok commit rc=$GRC out=$GOUT"
fi
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "review evidence in diff allows"
else
  fail "review allow rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' README -)"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=result_missing' <<<"$GOUT"; then
  pass "evidence without result denies"
else
  fail "result rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(applied_page '本文に無い文' README 'printf ok')"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=excerpt_mismatch' <<<"$GOUT"; then
  pass "body read with foreign excerpt denies"
else
  fail "excerpt rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(applied_page - README 'printf ok')"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=excerpt_missing' <<<"$GOUT"; then
  pass "body read without excerpt denies"
else
  fail "excerpt missing rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' not-in-diff.txt 'printf ok')"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
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
if [ "$crc" -eq 0 ] && grep -q 'status: auto_query_off' "$cap_mem" && grep -q '^executed_at: ' "$cap_mem" && grep -q '^head: ' "$cap_mem" && grep -q '^attempts: 0$' "$cap_mem" && grep -q 'WIKI_APPLY_CAPTURE=auto_query_off' <<<"$(cat "$ROOT/cap.out")"; then
  run_gate --mode commit --worktree "$cap_repo" --flow-state "$cap_flow" --memory "$cap_mem"
  if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
    pass "capture records auto_query_off"
  else
    fail "capture gate rc=$GRC out=$GOUT mem=$(cat "$cap_mem")"
  fi
else
  fail "capture rc=$crc mem=$(cat "$cap_mem" 2>/dev/null) err=$(cat "$ROOT/cap.err")"
fi

echo "=== git-commit-file refreshes head; a later edit is stale ==="
land=$(new_repo land)
write_config "$land" true true
land_flow="$ROOT/land.flow-state"
write_flow "$land_flow" implement 7 "$land"
land_mem="$ROOT/land.md"
old_head=$(git -C "$land" rev-parse HEAD)
printf 'land\n' >> "$land/README"
git -C "$land" add README
write_mem "$land_mem" "$(fresh_header none land "$land" 1 README)"
land_msg="$ROOT/land-msg.txt"
printf 'feat: land the record\n\nwhy\n' > "$land_msg"
crc=0
WIKI_APPLY_FLOW_STATE="$land_flow" WIKI_APPLY_MEMORY="$land_mem" \
  bash "$COMMIT" --file "$land_msg" --worktree "$land" >"$ROOT/land.out" 2>"$ROOT/land.err" || crc=$?
new_head=$(git -C "$land" rev-parse HEAD)
recorded=$(sed -n 's/^head: //p' "$land_mem")
if [ "$crc" -eq 0 ] && [ "$old_head" != "$new_head" ] && [ "$recorded" = "$new_head" ]; then
  pass "commit refreshes head"
else
  fail "refresh rc=$crc old=$old_head new=$new_head recorded=$recorded err=$(cat "$ROOT/land.err") out=$(cat "$ROOT/land.out")"
fi
run_gate --mode review --worktree "$land" --flow-state "$land_flow" --memory "$land_mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "refreshed record still allows"
else
  fail "refreshed review rc=$GRC out=$GOUT"
fi
printf 'later\n' >> "$land/README"
run_gate --mode commit --worktree "$land" --flow-state "$land_flow" --memory "$land_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=stale_content' <<<"$GOUT"; then
  pass "edit after commit denies"
else
  fail "stale after commit rc=$GRC out=$GOUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
