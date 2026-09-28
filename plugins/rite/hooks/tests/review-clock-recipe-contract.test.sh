#!/bin/bash
# review-clock-recipe-contract.test.sh
#
# Pins the contract that `review-clock-open` / `review-clock-close` are names of the
# shared Bash blocks in references/review-stagnation.md, NOT subcommands of
# hooks/flow-state.sh (whose only clock verb is `review-clock`).
#
#   - the reference states the block/subcommand distinction and names the literal
#     substitutions the caller must make
#   - every referring site (pr-review open/close, fix open/close, recover close)
#     names the shared block and the placeholder value it substitutes
#   - no distribution file instructs running `flow-state.sh review-clock-open|close`,
#     whether the script path is bare, quoted, or written as inline code
#   - the close recipe ends in the real CLI verb `flow-state.sh review-clock --input`
#   - every `flow-state.sh review-*` verb written in skills/ and references/ is a
#     member of the dispatch set in flow-state.sh (recipe/dispatch agreement)
#
# These rules live only in markdown orchestration; no script fails if a later edit
# reintroduces the non-existent subcommand. A negative control removes each section-level
# pin's literal from a temp copy, asserts the copy actually changed, and confirms the same
# section grep no longer matches.
#
# T-07..T-18 run hooks/stop-failure.sh (the StopFailure hook) against payloads and then the
# close recipe copied from the reference, so a turn that ends on an API error (for example a
# usage limit) does not count the pause as work time:
#   T-07 open record gets ended_at at the failure, for any error_type; nothing else changes
#   T-08 existing ended_at kept            T-09 no record / other session untouched
#   T-10 upper-case UUID payload           T-11 traversal id onto an existing record
#   T-12 non-object record warns           T-13 payload without session_id or cwd
#   T-14 unwritable record warns           T-15 cwd in a linked worktree stamps the main root
#   T-16 close hours later submits the failure time; without the hook it spans the pause
#   T-17 recover close keeps kind=work and the hook's time
#   T-18 hooks.json registration
#
# When this test fails:
#   Re-read references/review-stagnation.md 「時計の入力と運用」 and the referring
#   sites, restore the wording, or update this test if the contract has changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_hermetic-env.sh
source "$SCRIPT_DIR/_hermetic-env.sh"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

STAGNATION_MD="$PLUGIN_ROOT/references/review-stagnation.md"
PR_REVIEW_MD="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
FIX_MD="$PLUGIN_ROOT/skills/fix/SKILL.md"
RECOVER_MD="$PLUGIN_ROOT/skills/recover/SKILL.md"
FLOW_STATE_SH="$PLUGIN_ROOT/hooks/flow-state.sh"

for f in "$STAGNATION_MD" "$PR_REVIEW_MD" "$FIX_MD" "$RECOVER_MD" "$FLOW_STATE_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

echo "=== review-clock-recipe-contract.test.sh ==="

# Section boundaries (start regex, end regex) per referring site.
CLOCK_START='^## 時計の入力と運用'
CLOCK_END='^## 観測と根因'
PR_OPEN_START='^### 4\.0 Review Cycle Start / Resume'
PR_OPEN_END='^### 4\.0\.A Pre-Review State Snapshot'
PR_CLOSE_START='^#### 6\.1\.S 停滞観測の保存'
PR_CLOSE_END='^#### 6\.1\.b PR Comment Post'
FIX_OPEN_START='^### 2\.1 Confirm Fix Approach'
FIX_OPEN_END='^### 2\.1\.A accept'
FIX_CLOSE_START='^## ステップ 3: 修正のコミット'
FIX_CLOSE_END='^### 3\.1 Verify Changes'
RECOVER_START='^### review-cycle の再開'
RECOVER_END='^### 5\.4 invoke'

PIN_BLOCK_NAMES='は本節の共有 Bash ブロックの名前であり'
PIN_ONLY_VERB='`flow-state\.sh` が受け付ける時計の CLI 動詞は `review-clock` だけである'
PIN_SUBSTITUTIONS='`\{clock_close_mode\}` は通常の `normal` または復旧時の `recover` へリテラル置換する'
PIN_PR_OPEN='共有ブロック `review-clock-open`.*`clock_kind=work` で実行する'
PIN_PR_CLOSE='共有ブロック `review-clock-close` を `clock_close_mode=normal` で実行して区間を保存する'
PIN_FIX_OPEN='共有ブロック `review-clock-open`.*`clock_kind=work` で実行し'
PIN_FIX_CLOSE='共有ブロック `review-clock-close` を `clock_close_mode=normal` で実行して修正区間を保存する'
PIN_RECOVER='共有ブロック `review-clock-close` を `clock_close_mode=recover` で実行して中断として閉じ'

pin() {
  local before=$FAIL
  assert_grep_in_section "$@"
  if [ "$FAIL" -gt "$before" ]; then
    if [ -n "$(SEC_START="$3" SEC_END="$4" awk '$0 ~ ENVIRON["SEC_START"], $0 ~ ENVIRON["SEC_END"]' "$2")" ]; then
      echo "MISSING RULE: $1 — pattern: $5" >&2
    else
      echo "SECTION NOT FOUND: $1 — heading drift? [$3 .. $4]" >&2
    fi
  fi
}

# --- T-01 (AC-1): the reference defines the block/subcommand distinction and the substitutions ---
pin "T-01: reference says the names are shared Bash block names" \
  "$STAGNATION_MD" "$CLOCK_START" "$CLOCK_END" "$PIN_BLOCK_NAMES"
pin "T-01: reference names review-clock as the only accepted subcommand" \
  "$STAGNATION_MD" "$CLOCK_START" "$CLOCK_END" "$PIN_ONLY_VERB"
pin "T-01: reference names the clock_close_mode substitution values" \
  "$STAGNATION_MD" "$CLOCK_START" "$CLOCK_END" "$PIN_SUBSTITUTIONS"

# --- T-02 (AC-1 / AC-2): each referring site names the shared block and its placeholder ---
pin "T-02: pr-review open site names the shared block and clock_kind" \
  "$PR_REVIEW_MD" "$PR_OPEN_START" "$PR_OPEN_END" "$PIN_PR_OPEN"
pin "T-02: pr-review close site names the shared block and clock_close_mode" \
  "$PR_REVIEW_MD" "$PR_CLOSE_START" "$PR_CLOSE_END" "$PIN_PR_CLOSE"
pin "T-02: fix open site names the shared block and clock_kind" \
  "$FIX_MD" "$FIX_OPEN_START" "$FIX_OPEN_END" "$PIN_FIX_OPEN"
pin "T-02: fix close site names the shared block and clock_close_mode" \
  "$FIX_MD" "$FIX_CLOSE_START" "$FIX_CLOSE_END" "$PIN_FIX_CLOSE"
pin "T-02: recover close site names the shared block and the recover mode" \
  "$RECOVER_MD" "$RECOVER_START" "$RECOVER_END" "$PIN_RECOVER"

# --- T-03 (AC-2): no distribution file instructs running the non-existent subcommand ---
# Command context only: a `bash …flow-state.sh review-clock-open` invocation, or the same
# string inside a fenced block, and the same verb after a bare or quoted path. Prose that
# merely quotes the block name must stay legal, so the scan keys on the script path
# immediately followed by the verb rather than on the bare name.
#
# The ERE lives in one variable that both the scan and its self-check read. Keeping two
# independent copies lets the scan's pattern drift while the self-check stays green on its
# own copy, which is exactly the "the scan is dead" case the self-check exists to catch.
SCAN_RE='flow-state\.sh"?'"'"'?[[:space:]]+review-clock-(open|close)'

scan_command_context() {
  local label="$1"
  local hits
  # Test files are excluded: they must be able to name the forbidden shape to check it.
  hits=$(grep -rnE "$SCAN_RE" \
    --include='*.md' --include='*.sh' --include='*.py' --exclude-dir=tests "$PLUGIN_ROOT" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    printf 'NON-EXISTENT SUBCOMMAND INSTRUCTED:\n%s\n' "$hits" >&2
    fail "$label"
  else
    pass "$label"
  fi
}
scan_command_context "T-03: no instruction to run flow-state.sh review-clock-open|close"

# Self-check: the same ERE the scan uses detects every forbidden shape in use here —
# bare path, quoted path, and inline code without a bash prefix.
scan_probe=$(printf '%s\n' \
  'bash {plugin_root}/hooks/flow-state.sh review-clock-open' \
  'bash "$plugin_root/hooks/flow-state.sh" review-clock-close' \
  '`flow-state.sh review-clock-open --input <path>`' \
  | grep -cE "$SCAN_RE" || true)
if [ "$scan_probe" = "3" ]; then
  pass "T-03: scan pattern matches every forbidden shape (self-check)"
else
  fail "T-03: scan pattern missed a forbidden shape (matched $scan_probe of 3) — the scan is dead"
fi

# --- T-04 (AC-2): the close recipe ends in the real CLI verb ---
pin "T-04: close recipe submits through flow-state.sh review-clock --input" \
  "$STAGNATION_MD" "$CLOCK_START" "$CLOCK_END" 'flow-state\.sh review-clock --input "\$clock_file"'

# --- T-05 (AC-3): recipe/dispatch agreement — documented review-* verbs ⊆ dispatch set ---
# LC_ALL=C on every sort/comm in this comparison: the sets carry hyphens, and a locale that
# ignores punctuation in collation would order them differently in sort than in comm.
dispatch_set=$(grep -oE '^[[:space:]]*(review-[a-z-]+)\)' "$FLOW_STATE_SH" | tr -d ' )' | LC_ALL=C sort -u)
if [ -z "$dispatch_set" ]; then
  fail "T-05: no review-* verbs found in flow-state.sh dispatch — extraction is dead"
else
  pass "T-05: flow-state.sh dispatch exposes review-* verbs"
fi
# The quote class matches the scan in T-03: a documented verb counts whether the path is
# bare or quoted, so a verb hidden behind a quoted path cannot escape the subset check.
documented_set=$(grep -rhoE 'flow-state\.sh"?'"'"'?[[:space:]]+review-[a-z-]+' \
  --include='*.md' "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/references" 2>/dev/null \
  | sed -E 's/.*[[:space:]]//' | LC_ALL=C sort -u)
if [ -z "$documented_set" ]; then
  fail "T-05: no documented flow-state.sh review-* verbs found — extraction is dead"
else
  pass "T-05: docs reference flow-state.sh review-* verbs"
fi
undocumented=$(LC_ALL=C comm -23 <(printf '%s\n' "$documented_set") <(printf '%s\n' "$dispatch_set"))
if [ -n "$undocumented" ]; then
  printf 'DOCUMENTED VERBS ABSENT FROM DISPATCH:\n%s\n' "$undocumented" >&2
  fail "T-05: every documented flow-state.sh review-* verb exists in the dispatch"
else
  pass "T-05: every documented flow-state.sh review-* verb exists in the dispatch"
fi

# --- T-06: negative control — removing each pinned literal breaks its section grep ---
negative_control() {
  local label="$1" file="$2" start="$3" end="$4" pattern="$5"
  local mutant
  if ! mutant=$(mktemp "${TMPDIR:-/tmp}/rite-clock-pin-mutant-XXXXXX"); then
    fail "$label (mktemp failed)"
    return
  fi
  grep -vE "$pattern" "$file" > "$mutant" || true
  if [ ! -s "$mutant" ]; then
    fail "$label (mutant copy is empty)"
    rm -f "$mutant"
    return
  fi
  # A pin that is already dead leaves the mutant identical to the source, and the section
  # grep below would then miss for the wrong reason and report pass. Require the mutation
  # to have removed something before reading anything into the miss.
  if ! assert_mutant_changed "$label" "$file" "$mutant"; then
    rm -f "$mutant"
    return
  fi
  local section
  section=$(SEC_START="$start" SEC_END="$end" awk '$0 ~ ENVIRON["SEC_START"], $0 ~ ENVIRON["SEC_END"]' "$mutant")
  if grep -qE "$pattern" <<< "$section"; then
    fail "$label (pin still matches after removing literal — pin is not live: $pattern)"
  else
    pass "$label"
  fi
  rm -f "$mutant"
}

negative_control "T-06: removing PIN_ONLY_VERB breaks T-01" \
  "$STAGNATION_MD" "$CLOCK_START" "$CLOCK_END" "$PIN_ONLY_VERB"
negative_control "T-06: removing PIN_PR_OPEN breaks T-02" \
  "$PR_REVIEW_MD" "$PR_OPEN_START" "$PR_OPEN_END" "$PIN_PR_OPEN"
negative_control "T-06: removing PIN_PR_CLOSE breaks T-02" \
  "$PR_REVIEW_MD" "$PR_CLOSE_START" "$PR_CLOSE_END" "$PIN_PR_CLOSE"
negative_control "T-06: removing PIN_FIX_OPEN breaks T-02" \
  "$FIX_MD" "$FIX_OPEN_START" "$FIX_OPEN_END" "$PIN_FIX_OPEN"
negative_control "T-06: removing PIN_FIX_CLOSE breaks T-02" \
  "$FIX_MD" "$FIX_CLOSE_START" "$FIX_CLOSE_END" "$PIN_FIX_CLOSE"
negative_control "T-06: removing PIN_RECOVER breaks T-02" \
  "$RECOVER_MD" "$RECOVER_START" "$RECOVER_END" "$PIN_RECOVER"

# --- T-07..T-18: StopFailure freezes the open clock segment ---
HOOK="$PLUGIN_ROOT/hooks/stop-failure.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SF_DIR=$(mktemp -d)
trap 'chmod -R u+w "$SF_DIR" 2>/dev/null || true; rm -rf "$SF_DIR"' EXIT
SF_STDERR="$SF_DIR/stderr"
SID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
OTHER="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

# An open record in the shape review-clock-open writes (no ended_at yet).
write_open_record() {
  mkdir -p "$(dirname "$1")"
  jq -n --arg start "$2" \
    '{review_context:{session_id:"ctx",run_id:"r1",pr_number:1,cycle:1,head:"abc"},segment_id:"seg.1",kind:"work",started_at:$start}' > "$1"
}
# Feeds the hook one StopFailure payload built from jq args; returns the hook's rc.
run_hook() {
  jq -nc "$@" '{hook_event_name:"StopFailure"} + $ARGS.named' \
    | bash "$HOOK" 2>"$SF_STDERR" >/dev/null
}
iso_ago() { jq -nr --argjson s "$1" '(now - $s) | floor | todate'; }
seconds_between() { jq -nr --arg a "$1" --arg b "$2" '($b | fromdateiso8601) - ($a | fromdateiso8601)'; }
leftover_tmp() { find "$(dirname "$1")" -name "$(basename "$1").*" | wc -l | tr -d ' '; }
show_stderr() { [ -s "$SF_STDERR" ] && sed 's/^/    stderr: /' "$SF_STDERR"; return 0; }

for etype in rate_limit server_error ""; do
  d="$SF_DIR/open-${etype:-none}"
  f="$d/.rite/state/review-clock-$SID.json"
  write_open_record "$f" "$(iso_ago 600)"
  before=$(jq -cS . "$f")
  t0=$(jq -nr 'now | floor')
  rc=0
  if [ -n "$etype" ]; then
    run_hook --arg cwd "$d" --arg session_id "$SID" --arg error_type "$etype" || rc=$?
  else
    run_hook --arg cwd "$d" --arg session_id "$SID" || rc=$?
  fi
  t1=$(jq -nr 'now | floor')
  end=$(jq -r '.ended_at // empty' "$f")
  end_epoch=$(jq -nr --arg e "$end" '$e | fromdateiso8601' 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && [[ "$end" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    && [ -n "$end_epoch" ] && [ "$end_epoch" -ge "$t0" ] && [ "$end_epoch" -le "$t1" ] \
    && [ "$(jq -cS 'del(.ended_at)' "$f")" = "$before" ] && [ "$(leftover_tmp "$f")" = 0 ]; then
    pass "T-07: error_type='${etype:-<missing>}' stamps ended_at at the failure; other fields unchanged"
  else
    fail "T-07: error_type='${etype:-<missing>}' rc=$rc ended_at='$end' window=$t0..$t1 record=$(cat "$f")"; show_stderr
  fi
done

d="$SF_DIR/closed"; f="$d/.rite/state/review-clock-$SID.json"
write_open_record "$f" "$(iso_ago 600)"
jq --arg e "$(iso_ago 300)" '.ended_at = $e' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
cp "$f" "$SF_DIR/closed.before"
rc=0; run_hook --arg cwd "$d" --arg session_id "$SID" || rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$f" "$SF_DIR/closed.before"; then
  pass "T-08: a record that already has ended_at is left byte-for-byte"
else
  fail "T-08: rc=$rc record=$(cat "$f")"; show_stderr
fi

d="$SF_DIR/none"; fo="$d/.rite/state/review-clock-$OTHER.json"
write_open_record "$fo" "$(iso_ago 600)"
cp "$fo" "$SF_DIR/none.before"
rc=0; run_hook --arg cwd "$d" --arg session_id "$SID" || rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$d/.rite/state/review-clock-$SID.json" ] \
  && cmp -s "$fo" "$SF_DIR/none.before" && [ "$(find "$d" -type f | wc -l | tr -d ' ')" = 1 ]; then
  pass "T-09: no record creates nothing; another session's open record is untouched"
else
  fail "T-09: rc=$rc files=$(find "$d" -type f | tr '\n' ' ')"; show_stderr
fi

d="$SF_DIR/upper"; f="$d/.rite/state/review-clock-$SID.json"
write_open_record "$f" "$(iso_ago 600)"
rc=0; run_hook --arg cwd "$d" --arg session_id "$(printf '%s' "$SID" | tr 'a-f' 'A-F')" || rc=$?
if [ "$rc" -eq 0 ] && jq -e 'has("ended_at")' "$f" >/dev/null \
  && [ "$(find "$d" -type f | wc -l | tr -d ' ')" = 1 ]; then
  pass "T-10: an upper-case payload UUID stamps the lower-case record"
else
  fail "T-10: rc=$rc files=$(find "$d" -type f | tr '\n' ' ')"; show_stderr
fi

d="$SF_DIR/traversal"; fo="$d/.rite/state/review-clock-$OTHER.json"
write_open_record "$fo" "$(iso_ago 600)"
# The intermediate directory exists, so without the id check the path lands on $fo.
mkdir -p "$d/.rite/state/review-clock-x"
cp "$fo" "$SF_DIR/traversal.before"
rc=0; run_hook --arg cwd "$d" --arg session_id "x/../review-clock-$OTHER" || rc=$?
landed=0; [ -f "$d/.rite/state/review-clock-x/../review-clock-$OTHER.json" ] && landed=1
if [ "$rc" -eq 0 ] && [ "$landed" = 1 ] && cmp -s "$fo" "$SF_DIR/traversal.before"; then
  pass "T-11: a traversal id leaves the record it would land on unchanged"
else
  fail "T-11: rc=$rc landed=$landed record=$(cat "$fo")"; show_stderr
fi

d="$SF_DIR/corrupt"; f="$d/.rite/state/review-clock-$SID.json"
mkdir -p "$(dirname "$f")"; printf '[1,2]\n' > "$f"
rc=0; run_hook --arg cwd "$d" --arg session_id "$SID" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$f")" = "[1,2]" ] \
  && grep -qF "[rite] WARNING: stop-failure: review clock record is not a JSON object; left unchanged: $f" "$SF_STDERR"; then
  pass "T-12: a record that is not a JSON object warns with its path and stays"
else
  fail "T-12: rc=$rc record=$(cat "$f")"; show_stderr
fi

d="$SF_DIR/partial"; f="$d/.rite/state/review-clock-$SID.json"
write_open_record "$f" "$(iso_ago 600)"
cp "$f" "$SF_DIR/partial.before"
rc_nosid=0; run_hook --arg cwd "$d" --arg error_type rate_limit || rc_nosid=$?
nosid_warned=0
grep -qF "[rite] WARNING: stop-failure: payload has no session_id" "$SF_STDERR" && nosid_warned=1
rc_nocwd=0; run_hook --arg session_id "$SID" --arg error_type rate_limit || rc_nocwd=$?
if [ "$rc_nosid" -eq 0 ] && [ "$rc_nocwd" -eq 0 ] && [ "$nosid_warned" = 1 ] \
  && cmp -s "$f" "$SF_DIR/partial.before" && [ "$(find "$d" -type f | wc -l | tr -d ' ')" = 1 ]; then
  pass "T-13: a payload without session_id warns and one without cwd exits; nothing changes"
else
  fail "T-13: rc=$rc_nosid/$rc_nocwd warned=$nosid_warned files=$(find "$d" -type f | tr '\n' ' ')"; show_stderr
fi

if [ "$(id -u)" -eq 0 ]; then
  skip "T-14: root bypasses dir-permission bits, so a read-only state dir cannot force the write failure"
else
  d="$SF_DIR/readonly"; f="$d/.rite/state/review-clock-$SID.json"
  write_open_record "$f" "$(iso_ago 600)"
  cp "$f" "$SF_DIR/readonly.before"
  chmod 555 "$d/.rite/state"
  rc=0; run_hook --arg cwd "$d" --arg session_id "$SID" || rc=$?
  chmod 755 "$d/.rite/state"
  if [ "$rc" -eq 0 ] && cmp -s "$f" "$SF_DIR/readonly.before" && [ "$(leftover_tmp "$f")" = 0 ] \
    && grep -qF "[rite] WARNING: stop-failure: failed to stamp ended_at on the review clock; the pause will count as work time: $f" "$SF_STDERR"; then
    pass "T-14: an unwritable record warns with its path; rc=0"
  else
    fail "T-14: rc=$rc record=$(cat "$f")"; show_stderr
  fi
fi

main="$SF_DIR/repo/main"; wt="$SF_DIR/repo/wt"
mkdir -p "$main"
if git -C "$main" init -q && git -C "$main" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init \
  && git -C "$main" worktree add -q "$wt" 2>/dev/null; then
  main=$(cd "$main" && pwd -P); wt=$(cd "$wt" && pwd -P)
  f="$main/.rite/state/review-clock-$SID.json"
  write_open_record "$f" "$(iso_ago 600)"
  rc=0; run_hook --arg cwd "$wt" --arg session_id "$SID" || rc=$?
  if [ "$rc" -eq 0 ] && jq -e 'has("ended_at")' "$f" >/dev/null && [ ! -e "$wt/.rite/state" ]; then
    pass "T-15: cwd in a linked worktree stamps the record under the main checkout's state root"
  else
    fail "T-15: rc=$rc record=$(cat "$f") wt_state=$([ -e "$wt/.rite/state" ] && echo present || echo absent)"; show_stderr
  fi
else
  fail "T-15: could not build the main checkout + linked worktree fixture"
fi

# T-16/T-17 run the close recipe copied from the reference against stubs: the recipe resolves
# the state root and flow-state path through them and submits through `review-clock --input`.
stub="$SF_DIR/stub-plugin"
mkdir -p "$stub/hooks" "$SF_DIR/fakebin"
cat > "$stub/hooks/state-path-resolve.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$STUB_STATE_ROOT"
EOF
cat > "$stub/hooks/flow-state.sh" <<'EOF'
#!/bin/bash
case "$1" in
  path) printf '%s\n' "$STUB_STATE_ROOT/.rite/sessions/$STUB_SID.flow-state" ;;
  review-clock) printf 'call\n' >> "$STUB_CAPTURE.calls"; cp "$3" "$STUB_CAPTURE" ;;
  *) exit 2 ;;
esac
EOF
# The recipe stamps with `date -u +...`; this stand-in answers five hours on.
later=$(jq -nr '(now + 18000) | floor | todate')
printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$later" > "$SF_DIR/fakebin/date"
chmod +x "$SF_DIR/fakebin/date"
recipe_src=$(awk '/^# review-clock-close$/{f=1} f && /^```$/{exit} f' "$STAGNATION_MD")
recipe=${recipe_src//\{plugin_root\}/$stub}
run_close() {
  local mode="$1" root="$2" capture="$3" script
  script=${recipe//\{clock_close_mode\}/$mode}
  STUB_STATE_ROOT="$root" STUB_SID="$SID" STUB_CAPTURE="$capture" PATH="$SF_DIR/fakebin:$PATH" \
    bash -c "$script" 2>>"$SF_STDERR"
}
if [[ "$recipe_src" == *'has("ended_at")'* ]] && [[ "$recipe_src" == *'flow-state.sh review-clock --input'* ]] \
  && [[ "$recipe" != *'{plugin_root}'* ]]; then
  pass "T-16: the close recipe was copied from the reference with its ended_at guard and submission"
else
  fail "T-16: close recipe not found or incomplete in $STAGNATION_MD"
fi

start=$(iso_ago 600)
d="$SF_DIR/e2e-hook"; f="$d/.rite/state/review-clock-$SID.json"
write_open_record "$f" "$start"
rc_h=0; run_hook --arg cwd "$d" --arg session_id "$SID" --arg error_type rate_limit || rc_h=$?
stamped=$(jq -r '.ended_at // empty' "$f")
rc_c=0; run_close normal "$d" "$SF_DIR/e2e-hook.json" || rc_c=$?
dn="$SF_DIR/e2e-nohook"
write_open_record "$dn/.rite/state/review-clock-$SID.json" "$start"
rc_n=0; run_close normal "$dn" "$SF_DIR/e2e-nohook.json" || rc_n=$?
sub_end=$(jq -r '.ended_at // empty' "$SF_DIR/e2e-hook.json" 2>/dev/null || true)
ctl_end=$(jq -r '.ended_at // empty' "$SF_DIR/e2e-nohook.json" 2>/dev/null || true)
work_hook=""; [ -n "$sub_end" ] && work_hook=$(seconds_between "$start" "$sub_end")
work_ctl=""; [ -n "$ctl_end" ] && work_ctl=$(seconds_between "$start" "$ctl_end")
if [ "$rc_h" -eq 0 ] && [ "$rc_c" -eq 0 ] && [ "$rc_n" -eq 0 ] && [ -n "$stamped" ] \
  && [ "$sub_end" = "$stamped" ] && [ "$(jq -r .kind "$SF_DIR/e2e-hook.json")" = work ] \
  && [ "$(grep -c . "$SF_DIR/e2e-hook.json.calls")" = 1 ] && [ ! -e "$f" ] \
  && [ -n "$work_hook" ] && [ "$work_hook" -lt 1800 ] \
  && [ "$ctl_end" = "$later" ] && [ "$(jq -r .kind "$SF_DIR/e2e-nohook.json")" = work ] \
  && [ -n "$work_ctl" ] && [ "$work_ctl" -ge 18000 ]; then
  pass "T-16: close five hours after the failure submits ${work_hook}s of work; without the hook ${work_ctl}s"
else
  fail "T-16: rc=$rc_h/$rc_c/$rc_n stamped=$stamped submitted=$sub_end control=$ctl_end later=$later work=$work_hook/$work_ctl"; show_stderr
fi

d="$SF_DIR/e2e-recover"; f="$d/.rite/state/review-clock-$SID.json"
write_open_record "$f" "$start"
rc_h=0; run_hook --arg cwd "$d" --arg session_id "$SID" || rc_h=$?
stamped=$(jq -r '.ended_at // empty' "$f")
rc_c=0; run_close recover "$d" "$SF_DIR/e2e-recover.json" || rc_c=$?
# Control: without the hook the recover close classifies the whole segment as an interruption.
dn="$SF_DIR/e2e-recover-nohook"
write_open_record "$dn/.rite/state/review-clock-$SID.json" "$start"
rc_n=0; run_close recover "$dn" "$SF_DIR/e2e-recover-nohook.json" || rc_n=$?
if [ "$rc_h" -eq 0 ] && [ "$rc_c" -eq 0 ] && [ "$rc_n" -eq 0 ] && [ -n "$stamped" ] \
  && [ "$(jq -r .ended_at "$SF_DIR/e2e-recover.json")" = "$stamped" ] \
  && [ "$(jq -r .kind "$SF_DIR/e2e-recover.json")" = work ] \
  && [ "$(jq -r .kind "$SF_DIR/e2e-recover-nohook.json")" = interruption ]; then
  pass "T-17: recover close after the hook keeps kind=work and the failure time"
else
  fail "T-17: rc=$rc_h/$rc_c/$rc_n stamped=$stamped submitted=$(cat "$SF_DIR/e2e-recover.json" 2>/dev/null)"; show_stderr
fi

sf_entries=$(jq -c '.hooks.StopFailure // []' "$HOOKS_JSON")
stop_cmds=$(jq -r '[.hooks.Stop[]?.hooks[]?.command] | join("\n")' "$HOOKS_JSON")
if [ "$(jq 'length' <<< "$sf_entries")" = 1 ] \
  && [ "$(jq -r '.[0] | has("matcher")' <<< "$sf_entries")" = false ] \
  && [ "$(jq -c '.[0].hooks' <<< "$sf_entries")" = '[{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/hooks/stop-failure.sh","timeout":10}]' ] \
  && [ -f "$HOOK" ] && [ "$stop_cmds" = 'bash ${CLAUDE_PLUGIN_ROOT}/hooks/stop-loop-continuation.sh' ]; then
  pass "T-18: hooks.json registers stop-failure.sh for every StopFailure; Stop keeps only the loop continuation"
else
  fail "T-18: StopFailure=$sf_entries Stop=$stop_cmds"
fi

print_summary "review-clock-recipe-contract.test.sh"
