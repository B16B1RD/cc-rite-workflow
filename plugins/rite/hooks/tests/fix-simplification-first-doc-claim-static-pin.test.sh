#!/bin/bash
# fix-simplification-first-doc-claim-static-pin.test.sh
#
# Static-pin meta-test for the doc-claim rules in /rite:fix Simplification-First:
#   - the checklist limits "規則の一般化" to machine-evaluated rules and defines the
#     minimal diff for prose claims as delete/narrow first, enumerate-and-match before
#     widening (Simplification-First section)
#   - reviewer recommendations are candidates, not designs; prose-claim fixes are
#     cross-checked against the implementation before being applied (ステップ 2.1 / 2.3)
#   - commit body carries a `simplification-first:` paragraph when the Escalation
#     trigger holds, and the Root Cause Gate treats its absence as `missing`
#     (ステップ 3.2 / 3.2.1)
#   - the gate does NOT require that paragraph when the trigger does not hold
#
# These rules live only in markdown orchestration; no script would fail if a later
# edit silently dropped one of them. This test pins the literals so such a regression
# fails loudly. A negative control removes each pinned literal from a temp copy and
# confirms the same section grep no longer matches (so the pins are proven live).
#
# When this test fails:
#   Re-read fix/SKILL.md Simplification-First / 2.1 / 2.3 / 3.2 / 3.2.1 and restore the
#   rule text, or update this test if the contract has legitimately changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
FIX_MD="$PLUGIN_ROOT/skills/fix/SKILL.md"

if [ ! -f "$FIX_MD" ]; then
  echo "ERROR: $FIX_MD not found" >&2
  exit 1
fi

echo "=== fix-simplification-first-doc-claim-static-pin.test.sh ==="

# Section boundaries (start regex, end regex) and the pinned literal per rule.
SF_START='^### Simplification-First Response Principle'
SF_END='^### 2\.1 Confirm Fix Approach'
S21_START='^### 2\.1 Confirm Fix Approach'
S21_END='^### 2\.1\.A'
S23_START='^### 2\.3 Apply the Fix'
S23_END='^### 2\.3\.1'
S32_START='^### 3\.2 Generate Commit Message'
S32_END='^### 3\.2\.1 Root Cause Gate'
S321_START='^### 3\.2\.1 Root Cause Gate'
S321_END='^### 3\.3'

PIN_GENERALIZE='「規則の一般化」は機械が評価する規則（分岐・ガード・述語）に限る'
PIN_DOC_MIN='文書の主張（契約文・確認手順など人が読む記述）の最小差分は削除・限定を先に取る'
PIN_ENUMERATE='主張が名指しする集合を実装で列挙し一致を確認した上で書く'
PIN_CANDIDATE='推奨対応（`recommendation` 列）は候補であって設計ではない'
PIN_CROSSCHECK='主張が名指しする集合（実装の経路・出力・判定値）を実装で列挙し、主張と一致するか確認する'
PIN_CROSSCHECK_SHOW='列挙結果は修正案の提示に併記する'
PIN_MISMATCH='不一致なら修正案を適用せず、主張を限定するか削除する案に差し替える'
PIN_TRIGGER_COMMIT='commit body の `simplification-first:` 段落（ステップ 3\.2）として書く'
PIN_BODY_PARA='`simplification-first:` 段落（Escalation trigger 成立時のみ）'
PIN_GATE_CHECK='Escalation trigger 成立時は `simplification-first:` 段落の有無も判定し、いずれかの欠落を `missing` とする'
PIN_GATE_NOT_REQUIRED='trigger 不成立の cycle では `simplification-first:` 段落を要求しない'
PIN_OPTION1='or \(Escalation trigger 成立時\) a `simplification-first: \{paragraph\}` paragraph'

# pin: assert_grep_in_section, plus the missing rule name on stderr so a red run
# says which literal disappeared without scrolling the stdout stream.
pin() {
  local before=$FAIL
  assert_grep_in_section "$@"
  if [ "$FAIL" -gt "$before" ]; then
    echo "MISSING RULE: $1 — pattern: $5" >&2
  fi
}

# --- T-01 (AC-1): checklist item 1 limits generalization and defines doc-claim minimal diff ---
pin "T-01: 規則の一般化 is limited to machine-evaluated rules" \
  "$FIX_MD" "$SF_START" "$SF_END" "$PIN_GENERALIZE"
pin "T-01: doc-claim minimal diff = delete/narrow first" \
  "$FIX_MD" "$SF_START" "$SF_END" "$PIN_DOC_MIN"
pin "T-01: widening requires enumerate-and-match against implementation" \
  "$FIX_MD" "$SF_START" "$SF_END" "$PIN_ENUMERATE"
pin "T-01: Escalation trigger routes the decision into the commit body paragraph" \
  "$FIX_MD" "$SF_START" "$SF_END" "$PIN_TRIGGER_COMMIT"
assert_not_grep "T-01: old 'chat 1 行 + commit に書く' instruction is gone" \
  "$FIX_MD" '^追加で直すなら commit に「なぜ削除ではないか」を書く。$'

# --- T-02 (AC-2): recommendation is a candidate; prose-claim fixes are cross-checked in 2.3 ---
pin "T-02: 2.1 states recommendation is a candidate, not a design" \
  "$FIX_MD" "$S21_START" "$S21_END" "$PIN_CANDIDATE"
pin "T-02: 2.3 requires enumerate-and-match before applying a doc-claim fix" \
  "$FIX_MD" "$S23_START" "$S23_END" "$PIN_CROSSCHECK"
pin "T-02: 2.3 shows the enumeration alongside the proposed fix" \
  "$FIX_MD" "$S23_START" "$S23_END" "$PIN_CROSSCHECK_SHOW"
pin "T-02: 2.3 replaces a mismatching widening with narrow/delete" \
  "$FIX_MD" "$S23_START" "$S23_END" "$PIN_MISMATCH"

# --- T-03 (AC-3): 3.2 lists the paragraph; 3.2.1 Step 1 checks it ---
pin "T-03: 3.2 commit body lists simplification-first paragraph (trigger only)" \
  "$FIX_MD" "$S32_START" "$S32_END" "$PIN_BODY_PARA"
pin "T-03: 3.2.1 Step 1 treats missing simplification-first paragraph as missing" \
  "$FIX_MD" "$S321_START" "$S321_END" "$PIN_GATE_CHECK"
pin "T-03: 3.2.1 Step 2 option 1 can add the simplification-first paragraph" \
  "$FIX_MD" "$S321_START" "$S321_END" "$PIN_OPTION1"

# --- T-05 (AC-4 / AC-5): the paragraph is required only when the trigger holds ---
pin "T-05: 3.2.1 does not require the paragraph when the trigger does not hold" \
  "$FIX_MD" "$S321_START" "$S321_END" "$PIN_GATE_NOT_REQUIRED"
assert_not_grep "T-05: no rule requires simplification-first paragraph unconditionally" \
  "$FIX_MD" 'simplification-first:` 段落.*(常に|毎 cycle|全 cycle)'

# --- T-04 (AC-6): negative control — removing each pinned literal breaks its section grep ---
# assert_grep_in_section counts a miss as FAIL, so the mutant copies are checked with the
# same awk section slice + grep -qE directly and the *absence* is what passes.
negative_control() {
  local label="$1" start="$2" end="$3" pattern="$4"
  local mutant
  if ! mutant=$(mktemp -p "${TMPDIR:-/tmp}"); then
    fail "$label (mktemp failed)"
    return
  fi
  # Drop every line containing the literal (grep -v with the same ERE used by the pin).
  grep -vE "$pattern" "$FIX_MD" > "$mutant" || true
  if [ ! -s "$mutant" ]; then
    fail "$label (mutant copy is empty)"
    rm -f "$mutant"
    return
  fi
  # ENVIRON avoids awk -v escape processing (`\.` would otherwise warn and be rewritten).
  local section
  section=$(SEC_START="$start" SEC_END="$end" awk '$0 ~ ENVIRON["SEC_START"], $0 ~ ENVIRON["SEC_END"]' "$mutant")
  if printf '%s\n' "$section" | grep -qE "$pattern"; then
    fail "$label (pin still matches after removing literal — pin is not live: $pattern)"
  else
    pass "$label"
  fi
  rm -f "$mutant"
}

negative_control "T-04: removing PIN_GENERALIZE breaks T-01" "$SF_START" "$SF_END" "$PIN_GENERALIZE"
negative_control "T-04: removing PIN_CANDIDATE breaks T-02" "$S21_START" "$S21_END" "$PIN_CANDIDATE"
negative_control "T-04: removing PIN_CROSSCHECK breaks T-02" "$S23_START" "$S23_END" "$PIN_CROSSCHECK"
negative_control "T-04: removing PIN_GATE_CHECK breaks T-03" "$S321_START" "$S321_END" "$PIN_GATE_CHECK"
negative_control "T-04: removing PIN_GATE_NOT_REQUIRED breaks T-05" "$S321_START" "$S321_END" "$PIN_GATE_NOT_REQUIRED"

print_summary "fix-simplification-first-doc-claim-static-pin.test.sh"
