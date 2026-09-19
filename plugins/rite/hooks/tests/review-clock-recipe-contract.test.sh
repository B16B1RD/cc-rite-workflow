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
# When this test fails:
#   Re-read references/review-stagnation.md 「時計の入力と運用」 and the referring
#   sites, restore the wording, or update this test if the contract has changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  if printf '%s\n' "$section" | grep -qE "$pattern"; then
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

print_summary "review-clock-recipe-contract.test.sh"
