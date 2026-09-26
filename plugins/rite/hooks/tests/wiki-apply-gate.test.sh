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

echo "=== empty worktree field still resolves the memory from the issue ==="
# Without --memory the gate builds the path from the flow-state issue number.
# The worktree field is empty for sessions that never record one; it must not
# shift the issue number out of place. The record says issue 7 and the flow says
# 8, so issue_mismatch proves both the issue and the memory path were resolved.
write_mem "$repo/.rite/work-memory/issue-8.md" "$(ok_page read out '対象外' -)"
empty_wt_flow="$ROOT/emptywt.flow-state"
jq -n '{phase:"review", issue_number:8, worktree:""}' > "$empty_wt_flow"
no_wt_flow="$ROOT/nowt.flow-state"
jq -n '{phase:"review", issue_number:8}' > "$no_wt_flow"
pushd "$repo" >/dev/null
for case_flow in "$empty_wt_flow" "$no_wt_flow"; do
  rc=0
  GOUT=$(env -u WIKI_APPLY_MEMORY -u WIKI_APPLY_FLOW_STATE bash "$GATE" \
    --mode review --worktree "$repo" --flow-state "$case_flow" 2>"$ROOT/gate.err") || rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'reason=issue_mismatch' <<<"$GOUT" && ! grep -q 'record_missing' <<<"$GOUT"; then
    pass "review resolves memory: $(basename "$case_flow")"
  else
    fail "review $(basename "$case_flow") rc=$rc out=$GOUT"
  fi
done
jq -n '{phase:"implement", issue_number:8, worktree:""}' > "$empty_wt_flow"
rc=0
GOUT=$(env -u WIKI_APPLY_MEMORY -u WIKI_APPLY_FLOW_STATE bash "$GATE" \
  --mode commit --worktree "$repo" --flow-state "$empty_wt_flow" 2>"$ROOT/gate.err") || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=skip' <<<"$GOUT" && grep -q 'reason=worktree' <<<"$GOUT"; then
  pass "commit with empty worktree skips"
else
  fail "commit empty worktree rc=$rc out=$GOUT"
fi
popd >/dev/null
rm -rf "$repo/.rite"

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
# review でも blob を照合する。別セッションの記録で blob だけを書き換える
other_blob=$(printf 'other\n' | git -C "$age" hash-object --stdin)
write_mem "$age_mem" "$(fresh_header none other-session "$age" 1 README \
  | sed -e "s#^blob: README=.*#blob: README=${other_blob}#")"
run_gate --mode review --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=stale_content' <<<"$GOUT"; then
  pass "review denies a changed blob"
else
  fail "review stale content rc=$GRC out=$GOUT"
fi
# --mode を省略したときは commit として照合する。別セッションの記録は、commit なら
# session で拒否され、review なら session を見ずに stale_content へ進むので区別できる
run_gate --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=session_mismatch' <<<"$GOUT"; then
  pass "omitted mode rejects another session's record like commit"
else
  fail "omitted mode rc=$GRC out=$GOUT"
fi

echo "=== unknown mode ==="
for bad_mode in bogus reveiw ""; do
  run_gate --mode "$bad_mode" --worktree "$age" --flow-state "$age_flow" --memory "$age_mem"
  if [ "$GRC" -ne 0 ] && ! grep -q 'WIKI_APPLY_GATE=' <<<"$GOUT" \
    && grep -q 'commit' "$ROOT/gate.err" && grep -q 'review' "$ROOT/gate.err"; then
    pass "mode '$bad_mode' is rejected with the accepted values"
  else
    fail "mode '$bad_mode' rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
  fi
done

echo "=== flag without a value ==="
for flag in --mode --worktree --base --flow-state --memory; do
  run_gate "$flag"
  if [ "$GRC" -ne 0 ] && ! grep -q 'WIKI_APPLY_GATE=' <<<"$GOUT" \
    && grep -q -- "$flag requires a value" "$ROOT/gate.err"; then
    pass "$flag without a value is rejected with a reason"
  else
    fail "$flag without value rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
  fi
done

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
# branch.base read from rite-config.yml with a trailing comment
cp "$repo/rite-config.yml" "$ROOT/cfg.bak"
printf '%s\n' 'branch:' "  base: \"$review_base\"    # base branch" >> "$repo/rite-config.yml"
run_gate --mode review --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "review reads branch.base with a trailing comment"
else
  fail "commented base rc=$GRC out=$GOUT"
fi
cp "$ROOT/cfg.bak" "$repo/rite-config.yml"
printf '%s\n' 'branch:' '  base: "no-such-base-ref"    # base branch' >> "$repo/rite-config.yml"
run_gate --mode review --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=base_diff_unreadable' <<<"$GOUT" \
   && grep -qF 'ERROR: git diff no-such-base-ref...HEAD' "$ROOT/gate.err" \
   && grep -q 'unknown revision' "$ROOT/gate.err"; then
  pass "review denies an unreadable base diff instead of matching an empty diff"
else
  fail "unreadable base rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
fi
# with the same unreadable base, a review whose pages are all out and a commit do not deny
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' README 'printf ok' | sed 's/^decision: applied/decision: out/')"
run_gate --mode review --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "review without applied pages ignores an unreadable base diff"
else
  fail "out-only review rc=$GRC out=$GOUT"
fi
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' README 'printf ok')"
run_gate --mode commit --worktree "$repo" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "commit ignores an unreadable base diff"
else
  fail "commit unreadable base rc=$GRC out=$GOUT"
fi
cp "$ROOT/cfg.bak" "$repo/rite-config.yml"
# a failing textconv driver must not break the evidence diff (textconv is not used)
printf '%s\n' 'README diff=broken' > "$repo/.git/info/attributes"
git -C "$repo" config diff.broken.textconv false
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
git -C "$repo" config --unset diff.broken.textconv
rm -f "$repo/.git/info/attributes"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "review evidence diff ignores a failing textconv driver"
else
  fail "textconv review rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
fi

# a diff larger than one environment value (128 KiB) still reaches the evidence check
# the evidence is only in the last line of the body, so allow needs the whole diff text
head -c 300000 /dev/zero | tr '\0' 'x' | fold -w 100 > "$repo/large.txt"
printf 'tail-only-evidence-marker\n' >> "$repo/large.txt"
git -C "$repo" add large.txt
git -C "$repo" commit -qm 'large change'
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' tail-only-evidence-marker 'printf ok')"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "review handles a diff larger than one environment value"
else
  fail "large diff review rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
fi
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' not-in-diff.txt 'printf ok')"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=evidence_mismatch' <<<"$GOUT"; then
  pass "large diff review still denies evidence outside the diff"
else
  fail "large diff mismatch rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
fi
# the diff files are removed when the gate exits
gate_tmp="$ROOT/gate-tmp"
mkdir -p "$gate_tmp"
TMPDIR="$gate_tmp" run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=evidence_mismatch' <<<"$GOUT" && [ -z "$(ls -A "$gate_tmp")" ]; then
  pass "gate leaves no diff files behind"
else
  fail "gate cleanup rc=$GRC out=$GOUT left=$(ls -A "$gate_tmp")"
fi
# the diff files go under TMPDIR; an unusable TMPDIR is a deny, not a silent skip
TMPDIR="$ROOT/no-such-tmp" run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=tmp_unavailable' <<<"$GOUT"; then
  pass "unusable TMPDIR denies with tmp_unavailable"
else
  fail "tmp_unavailable rc=$GRC out=$GOUT"
fi
# a staged listing that cannot be read is a deny, not an empty list
cp "$repo/.git/index" "$ROOT/index.bak"
printf 'broken' > "$repo/.git/index"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$flow" --memory "$mem"
cp "$ROOT/index.bak" "$repo/.git/index"
if [ "$GRC" -eq 1 ] && grep -q 'reason=staged_unreadable' <<<"$GOUT" && grep -q 'ERROR: staged' "$ROOT/gate.err"; then
  pass "unreadable staged listing denies with staged_unreadable"
else
  fail "staged_unreadable rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
fi
write_mem "$mem" "$(applied_page '対象の識別子を照合してから実行する。' README 'printf ok')"

# A review resumed from another session reads the record written by the session
# that implemented or fixed. Review does not authorize a commit, so it does not
# bind the record to the current session; the other checks still apply.
later_flow="$ROOT/later.flow-state"
write_flow "$later_flow" implement 7 "$repo"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$later_flow" --memory "$mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT" && ! grep -q 'session_mismatch' <<<"$GOUT"; then
  pass "review from another session allows"
else
  fail "review other session rc=$GRC out=$GOUT"
fi
run_gate --mode commit --worktree "$repo" --flow-state "$later_flow" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=session_mismatch' <<<"$GOUT"; then
  pass "commit from another session still denies"
else
  fail "commit other session rc=$GRC out=$GOUT"
fi
later_mem="$ROOT/later-mem.md"
write_mem "$later_mem" "$(applied_page '対象の識別子を照合してから実行する。' README 'printf ok' | sed -e 's#^worktree: .*#worktree: /tmp/not-the-repo#')"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$later_flow" --memory "$later_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=worktree_mismatch' <<<"$GOUT"; then
  pass "review from another session still checks worktree"
else
  fail "review other session worktree rc=$GRC out=$GOUT"
fi
write_mem "$later_mem" "$(applied_page '対象の識別子を照合してから実行する。' README 'printf ok' | sed -e 's#^head: .*#head: 0000000000000000000000000000000000000000#')"
run_gate --mode review --worktree "$repo" --base "$review_base" --flow-state "$later_flow" --memory "$later_mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=stale_head' <<<"$GOUT"; then
  pass "review from another session still checks head"
else
  fail "review other session head rc=$GRC out=$GOUT"
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

echo "=== unreadable flow-state denies ==="
bad="$ROOT/bad.flow-state"
printf '{\n' > "$bad"
run_gate --mode commit --worktree "$repo" --flow-state "$bad" --memory "$mem"
if [ "$GRC" -eq 1 ] && grep -q 'reason=state_unreadable' <<<"$GOUT"; then
  pass "corrupt flow-state denies commit"
else
  fail "corrupt flow rc=$GRC out=$GOUT"
fi
gin=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git commit -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$gin" | WIKI_APPLY_FLOW_STATE="$bad" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-unreadable' <<<"$gout"; then
  pass "guard denies commit when flow-state is unreadable"
else
  fail "guard corrupt rc=$grc out=$gout"
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
dash_c=$(jq -n --arg cwd "/tmp" --arg cmd "git -C $repo commit -m x" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$dash_c" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'permissionDecision' <<<"$gout" && grep -q 'deny' <<<"$gout" && grep -q 'wiki-apply-gate' <<<"$gout"; then
  pass "guard denies git -C of the session worktree"
else
  fail "guard -C rc=$grc out=$gout"
fi
other=$(new_repo other)
other_cmd=$(jq -n --arg cwd "$repo" --arg cmd "git -C $other commit -m x" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$other_cmd" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if [ "$grc" -eq 0 ] && [ -z "$gout" ]; then
  pass "guard allows git -C of another worktree"
else
  fail "guard other -C rc=$grc out=$gout"
fi
dyn_cmd=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git -C \"$wt\" commit -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$dyn_cmd" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-unresolved' <<<"$gout" || grep -q 'review-commit-evidence' <<<"$gout"; then
  pass "guard denies an unresolvable git -C commit"
else
  fail "guard dynamic -C rc=$grc out=$gout"
fi
mkdir -p "$repo/sub"
sub_cmd=$(jq -n --arg cwd "$repo/sub" '{tool_name:"Bash", tool_input:{command:"git commit -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$sub_cmd" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-gate' <<<"$gout"; then
  pass "guard denies commit from a subdirectory"
else
  fail "guard subdir rc=$grc out=$gout"
fi
away=$(jq -n --arg cwd "$repo" --arg cmd "cd $other && git commit -m x" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$away" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if [ "$grc" -eq 0 ] && [ -z "$gout" ]; then
  pass "guard allows cd to another repository"
else
  fail "guard cd rc=$grc out=$gout"
fi
alla=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git commit -a -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$alla" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-index' <<<"$gout"; then
  pass "guard denies git commit -a"
else
  fail "guard -a rc=$grc out=$gout"
fi
other_a=$(jq -n --arg cwd "$repo" --arg cmd "git -C $other commit -a -m x" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$other_a" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if [ "$grc" -eq 0 ] && [ -z "$gout" ]; then
  pass "guard allows git commit -a in another worktree"
else
  fail "guard other -a rc=$grc out=$gout"
fi
amend=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git commit --amend -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$amend" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-gate' <<<"$gout" && ! grep -q 'wiki-apply-index' <<<"$gout"; then
  pass "guard does not treat --amend as -a"
else
  fail "guard amend rc=$grc out=$gout"
fi
patchc=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git commit -p -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$patchc" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-index' <<<"$gout"; then
  pass "guard denies git commit -p"
else
  fail "guard -p rc=$grc out=$gout"
fi
longpatch=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git commit --patch -m x"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$longpatch" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-index' <<<"$gout"; then
  pass "guard denies git commit --patch"
else
  fail "guard --patch rc=$grc out=$gout"
fi
heredoc=$(jq -n --arg cwd "$repo" --arg cmd "$(printf '%s\n' "cat <<'EOF'" note EOF "git commit -m x")" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$heredoc" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-gate' <<<"$gout"; then
  pass "guard sees a commit after a heredoc"
else
  fail "guard heredoc rc=$grc out=$gout"
fi
head_before=$(git -C "$repo" rev-parse HEAD)
crc=0
WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$repo" -- -a >"$ROOT/extra.out" 2>"$ROOT/extra.err" || crc=$?
head_after=$(git -C "$repo" rev-parse HEAD)
if [ "$crc" -ne 0 ] && [ "$head_before" = "$head_after" ] && grep -q 'index の照合を外す' <<<"$(cat "$ROOT/extra.err")"; then
  pass "git-commit-file rejects -a"
else
  fail "extra -a rc=$crc err=$(cat "$ROOT/extra.err")"
fi
crc=0
WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$repo" -- -p >"$ROOT/extra-p.out" 2>"$ROOT/extra-p.err" || crc=$?
head_after=$(git -C "$repo" rev-parse HEAD)
if [ "$crc" -ne 0 ] && [ "$head_before" = "$head_after" ] && grep -q 'index の照合を外す' <<<"$(cat "$ROOT/extra-p.err")"; then
  pass "git-commit-file rejects -p"
else
  fail "extra -p rc=$crc err=$(cat "$ROOT/extra-p.err")"
fi
for _cluster in "-av -m x" "-qa -m x" "-pv -m x" "-am msg" "--interactive -m x" "--pathspec-from-file=paths.txt -m x"; do
  cluster=$(jq -n --arg cwd "$repo" --arg cmd "git commit $_cluster" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
  grc=0
  gout=$(printf '%s' "$cluster" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
  if grep -q 'wiki-apply-index' <<<"$gout"; then
    pass "guard denies git commit $_cluster"
  else
    fail "guard cluster $_cluster rc=$grc out=$gout"
  fi
done
# 値の三形態: 束ねの末尾が値を取る、同じトークンに値が続く、次トークンが値。
for _index_args in "-qm msg" "-qF file" "-mfix" "-uno" "-q -m msg"; do
  got=$(python3 "$SCRIPT_DIR/../scripts/lib/review-fix-scope.py" classify-extras -- $_index_args)
  if [ "$got" = index ]; then
    pass "classify keeps index for $_index_args"
  else
    fail "classify $_index_args got $got"
  fi
done
qm=$(jq -n --arg cwd "$repo" '{tool_name:"Bash", tool_input:{command:"git commit -qm message"}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$qm" | WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" bash "$GUARD" 2>"$ROOT/guard.err") || grc=$?
if grep -q 'wiki-apply-gate' <<<"$gout" && ! grep -q 'wiki-apply-index' <<<"$gout"; then
  pass "guard does not treat -qm message as a pathspec"
else
  fail "guard -qm rc=$grc out=$gout"
fi
crc=0
WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$repo" -- -av >"$ROOT/extra-av.out" 2>"$ROOT/extra-av.err" || crc=$?
head_after=$(git -C "$repo" rev-parse HEAD)
if [ "$crc" -ne 0 ] && [ "$head_before" = "$head_after" ] && grep -q 'index の照合を外す' <<<"$(cat "$ROOT/extra-av.err")"; then
  pass "git-commit-file rejects -av in scope"
else
  fail "extra -av rc=$crc err=$(cat "$ROOT/extra-av.err")"
fi
crc=0
WIKI_APPLY_FLOW_STATE="$clean" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$repo" -- -a >"$ROOT/extra-clean.out" 2>"$ROOT/extra-clean.err" || crc=$?
if ! grep -q 'index の照合を外す' <<<"$(cat "$ROOT/extra-clean.err")"; then
  pass "git-commit-file cleanup does not reject -a"
else
  fail "cleanup -a rc=$crc err=$(cat "$ROOT/extra-clean.err")"
fi
crc=0
WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$other" -- -a >"$ROOT/extra-other.out" 2>"$ROOT/extra-other.err" || crc=$?
if ! grep -q 'index の照合を外す' <<<"$(cat "$ROOT/extra-other.err")"; then
  pass "git-commit-file other worktree does not reject -a"
else
  fail "other -a rc=$crc err=$(cat "$ROOT/extra-other.err")"
fi
crc=0
WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$repo" -- -qm x >"$ROOT/extra-qm.out" 2>"$ROOT/extra-qm.err" || crc=$?
head_after=$(git -C "$repo" rev-parse HEAD)
if [ "$crc" -ne 0 ] && [ "$head_before" = "$head_after" ] \
  && grep -q 'record_missing' <<<"$(cat "$ROOT/extra-qm.err")" \
  && ! grep -q 'index の照合を外す' <<<"$(cat "$ROOT/extra-qm.err")"; then
  pass "git-commit-file keeps -qm as an index commit"
else
  fail "extra -qm rc=$crc err=$(cat "$ROOT/extra-qm.err")"
fi
crc=0
WIKI_APPLY_FLOW_STATE="$flow" WIKI_APPLY_MEMORY="$ROOT/no-such.md" \
  bash "$COMMIT" --file "$msg" --worktree "$repo" -- --trailer 'Signed-off-by: T <t@t.example>' >"$ROOT/extra-trailer.out" 2>"$ROOT/extra-trailer.err" || crc=$?
head_after=$(git -C "$repo" rev-parse HEAD)
if [ "$crc" -ne 0 ] && [ "$head_before" = "$head_after" ] \
  && grep -q 'record_missing' <<<"$(cat "$ROOT/extra-trailer.err")" \
  && ! grep -q 'index の照合を外す' <<<"$(cat "$ROOT/extra-trailer.err")"; then
  pass "git-commit-file keeps an in-scope trailer value"
else
  fail "trailer rc=$crc err=$(cat "$ROOT/extra-trailer.err")"
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

echo "=== capture from a subdirectory reads the worktree config ==="
sub_repo=$(new_repo subcap)
write_config "$sub_repo" true true
mkdir -p "$sub_repo/nested"
sub_flow="$ROOT/subcap.flow-state"
write_flow "$sub_flow" implement 7 "$sub_repo"
sub_mem="$ROOT/subcap.md"
crc=0
bash "$CAPTURE" --keywords widget --cwd "$sub_repo/nested" --flow-state "$sub_flow" --memory "$sub_mem" >"$ROOT/subcap.out" 2>"$ROOT/subcap.err" || crc=$?
if [ -f "$sub_mem" ] && ! grep -q 'status: auto_query_off' "$sub_mem"; then
  pass "subdir capture keeps the worktree auto_query"
else
  fail "subdir capture rc=$crc mem=$(cat "$sub_mem" 2>/dev/null) err=$(cat "$ROOT/subcap.err")"
fi

echo "=== a linked worktree reads the main checkout config ==="
lw_main=$(new_repo lwmain)
# enabled: false にするのは、gate が worktree 側（config なし = 有効扱い）を読むと
# disabled の記録を拒否し、main の config を読んだときだけ許可するため
printf '%s\n' 'wiki:' '  enabled: false' > "$lw_main/rite-config.yml"
lw="$ROOT/lwwt"
git -C "$lw_main" worktree add -q -b feat/lw "$lw" >/dev/null 2>&1
lw=$(CDPATH= cd -- "$lw" && pwd -P)
lw_flow="$ROOT/lw.flow-state"
write_flow "$lw_flow" implement 7 "$lw"
lw_mem="$ROOT/lw.md"
crc=0
bash "$CAPTURE" --keywords widget --cwd "$lw" --flow-state "$lw_flow" --memory "$lw_mem" >"$ROOT/lw.out" 2>"$ROOT/lw.err" || crc=$?
if [ "$crc" -eq 0 ] && grep -q 'status: disabled' "$lw_mem"; then
  run_gate --mode commit --worktree "$lw" --flow-state "$lw_flow" --memory "$lw_mem"
  if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
    pass "worktree capture and gate use the main checkout wiki.enabled"
  else
    fail "worktree gate rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
  fi
else
  fail "worktree capture rc=$crc mem=$(cat "$lw_mem" 2>/dev/null) err=$(cat "$ROOT/lw.err")"
fi
rm -f "$lw_main/rite-config.yml" "$lw_mem"
crc=0
bash "$CAPTURE" --keywords widget --cwd "$lw" --flow-state "$lw_flow" --memory "$lw_mem" >"$ROOT/lw2.out" 2>"$ROOT/lw2.err" || crc=$?
if grep -q "WARNING: .*$lw/rite-config.yml.*$lw_main/rite-config.yml" "$ROOT/lw2.err" \
  && ! grep -q 'WARNING' "$ROOT/lw2.out"; then
  pass "capture without any config warns on stderr with both tried paths"
else
  fail "no-config capture rc=$crc out=$(cat "$ROOT/lw2.out") err=$(cat "$ROOT/lw2.err")"
fi
run_gate --mode commit --worktree "$lw" --flow-state "$lw_flow" --memory "$lw_mem"
if grep -q "WARNING: .*$lw_main/rite-config.yml" "$ROOT/gate.err" && ! grep -q 'WARNING' <<<"$GOUT"; then
  pass "gate without any config warns on stderr with the tried path"
else
  fail "no-config gate rc=$GRC out=$GOUT err=$(cat "$ROOT/gate.err")"
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

echo "=== open writes phase=implement before issue-implement commits ==="
# The block and the commit resolve the same flow-state through the session env,
# so the commit reads what open wrote instead of a hand-made flow file.
OPEN_MD="$SCRIPT_DIR/../../skills/open/SKILL.md"
FS="$SCRIPT_DIR/../flow-state.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
tag_lines=$(grep -n '^# open-implement-state$' "$OPEN_MD" | cut -d: -f1)
step4_line=$(grep -n '^## ステップ 4: 実装$' "$OPEN_MD" | cut -d: -f1)
invoke_line=$(grep -n '^skill: rite:issue-implement$' "$OPEN_MD" | cut -d: -f1)
if [ "$(printf '%s\n' "$tag_lines" | grep -c .)" -eq 1 ] && [ -n "$step4_line" ] && [ -n "$invoke_line" ] \
  && [ "$tag_lines" -gt "$step4_line" ] && [ "$tag_lines" -lt "$invoke_line" ]; then
  pass "the implement-state block appears once, inside ステップ 4 before the invoke"
else
  fail "implement-state block placement tag=$tag_lines step4=$step4_line invoke=$invoke_line"
fi
impl_block="$ROOT/open-implement-state.sh"
awk -v root="$PLUGIN_ROOT" '
  /^# open-implement-state$/ { copy=1; next }
  copy && /^```$/ { exit }
  copy { gsub(/\{plugin_root\}/, root); gsub(/\{issue_number\}/, "7");
         gsub(/\{branch_name\}/, "fix/issue-7-x"); print }
' "$OPEN_MD" > "$impl_block"
if [ -s "$impl_block" ] && ! grep -q '{' "$impl_block"; then
  pass "the extracted block is complete"
else
  fail "extracted block is empty or keeps a placeholder: $(cat "$impl_block")"
fi
opn=$(new_repo open-implement)
write_config "$opn" true true
open_state="$ROOT/open-state"
mkdir -p "$open_state"
open_env() {
  env -u CLAUDE_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID RITE_HOST=claude \
    CLAUDE_CODE_SESSION_ID=550e8400-e29b-41d4-a716-446655440077 RITE_STATE_ROOT="$open_state" "$@"
}
open_env bash "$FS" set --phase plan --issue 7 --branch fix/issue-7-x --pr 0 \
  --worktree "$opn" --parent-issue 5 --next test >/dev/null
open_flow=$(open_env bash "$FS" path)
before=$(jq -c '{worktree, branch, issue_number, parent_issue_number}' "$open_flow")
open_env bash "$impl_block" >"$ROOT/open-block.out" 2>&1
after=$(jq -c '{worktree, branch, issue_number, parent_issue_number}' "$open_flow")
if [ "$(jq -r '.phase' "$open_flow")" = implement ] && [ "$before" = "$after" ]; then
  pass "the block sets phase=implement and keeps worktree, branch, issue and parent"
else
  fail "block state phase=$(jq -r '.phase' "$open_flow") before=$before after=$after out=$(cat "$ROOT/open-block.out")"
fi
open_mem="$ROOT/open.md"
old_head=$(git -C "$opn" rev-parse HEAD)
printf 'open\n' >> "$opn/README"
git -C "$opn" add README
write_mem "$open_mem" "$(fresh_header none 550e8400-e29b-41d4-a716-446655440077 "$opn" 1 README)"
# The guard parses the documented commit block before it runs; an unparsable
# block is denied under phase=implement and never reaches git-commit-file.sh.
IMPL_MD="$SCRIPT_DIR/../../skills/issue-implement/SKILL.md"
commit_block=$(awk -v root="$PLUGIN_ROOT" '
  /^# implement-commit$/ { copy=1; next }
  copy && /^```$/ { exit }
  copy { gsub(/\{plugin_root\}/, root); gsub(/\{changed_files\}/, "README");
         gsub(/\{branch_name\}/, "fix/issue-7-x"); gsub(/\{commit_message\}/, "fix: x"); print }
' "$IMPL_MD")
impl_gin=$(jq -n --arg cwd "$opn" --arg cmd "$commit_block" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
grc=0
gout=$(printf '%s' "$impl_gin" | open_env WIKI_APPLY_MEMORY="$open_mem" bash "$GUARD" 2>"$ROOT/impl-guard.err") || grc=$?
if [ -n "$commit_block" ] && ! grep -qE '\{[a-z_]+\}' <<<"$commit_block" && [ "$grc" -eq 0 ] && ! grep -q 'deny' <<<"$gout"; then
  pass "the guard lets the documented implement commit block through under phase=implement"
else
  fail "implement commit block guard rc=$grc out=$gout block=$commit_block"
fi
open_msg="$ROOT/open-msg.txt"
printf 'fix: implement commit\n\nwhy\n' > "$open_msg"
crc=0
open_env WIKI_APPLY_MEMORY="$open_mem" \
  bash "$COMMIT" --file "$open_msg" --worktree "$opn" >"$ROOT/open.out" 2>"$ROOT/open.err" || crc=$?
new_head=$(git -C "$opn" rev-parse HEAD)
recorded=$(sed -n 's/^head: //p' "$open_mem")
if [ "$crc" -eq 0 ] && [ "$old_head" != "$new_head" ] && [ "$recorded" = "$new_head" ]; then
  pass "the implement commit passes the gate and refreshes head"
else
  fail "implement commit rc=$crc old=$old_head new=$new_head recorded=$recorded err=$(cat "$ROOT/open.err")"
fi
run_gate --mode review --worktree "$opn" --flow-state "$open_flow" --memory "$open_mem"
if [ "$GRC" -eq 0 ] && grep -q 'WIKI_APPLY_GATE=allow' <<<"$GOUT"; then
  pass "review after the implement commit allows"
else
  fail "review after implement rc=$GRC out=$GOUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
