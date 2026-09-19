#!/bin/bash
# critic-evidence-claim-static-pin.test.sh
#
# Static-pin for Critic evidence↔claim correspondence (pr-review 5.2.2).
# Pins mechanical rails only: heading adjacency, reject routing, template
# shape, E2E omit rule, and that multiplicity/severity are not evidence.
# Semantic T-02..T-07 case evaluations live in the PR body, not here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SKILL="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
TEMPLATES="$PLUGIN_ROOT/skills/pr-review/references/integrated-report-templates.md"
FACT="$PLUGIN_ROOT/skills/pr-review/references/fact-check.md"
BASE="$PLUGIN_ROOT/agents/_reviewer-base.md"
ASSESS="$PLUGIN_ROOT/skills/fix/references/assessment-rules.md"
SEV="$PLUGIN_ROOT/references/severity-levels.md"
VERIFY="$PLUGIN_ROOT/skills/pr-review/references/reviewer-prompt-verification.md"

for f in "$SKILL" "$TEMPLATES" "$FACT" "$BASE" "$ASSESS" "$SEV" "$VERIFY"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

echo "=== critic-evidence-claim-static-pin.test.sh ==="

DEDUP_START='^#### Deduplication$'
CORR_START='^#### 5\.2\.2 Evidence-Claim Correspondence$'
FACT_START='^#### Fact-Checking Phase$'
S52_START='^### 5\.2 Cross-Validation$'
S521_START='^### 5\.2\.1 '
S54_START='^### 5\.4 Integrated Report Generation$'
S6_START='^## ステップ 6:'


PIN_ACCEPTANCE='acceptance-reviewer.*統合しない'
PIN_DEDUP_AFTER='類似指摘の merge は 5\.2\.2 の'
PIN_NO_HIGHEST='根拠不足の複数件を最高 severity で 1 件にまとめない'
PIN_NO_FLAG='不採用の補強に使わない'
PIN_NO_HELPER='helper / 新スキーマ / 常設承認は増やさない'
PIN_NO_VERIF_WRITE='findings\[\]\.verification` は書かない'
PIN_ZERO_SKIP='指摘 0 件なら skip'
PIN_FC_SKIP_RUN='Fact-Check skip（`enabled: false` または external 0）でも本節は実行する'
PIN_VERIFY_SAME='verification モードも同一'
PIN_NOT_IN_FINDINGS='findings\[\]` に入れない'
PIN_EXCLUDE_ALL='全指摘事項から外'
PIN_RETAIN_COUNT='evidence_claim_rejected_count ='
PIN_M_NO_WRITE='5\.2\.2 不採用は `全指摘事項` に残さず'
PIN_REJECT_HEADING='### 根拠と主張の不対応'
PIN_ADOPT='既存 5\.3\.0\.M / 5\.3\.0\.C へ'
PIN_NO_NEW_RULE='新規約を元要求違反の根拠にしない'
PIN_EXISTING_PATH='無条件の non-blocking 化・mergeable 化・verification 手編集はしない'
PIN_NOT_NB='不採用は `### 実測なし指摘` へ混ぜない'
PIN_MEASURED_AFTER='採用後の `measured=true` は観測記録'
PIN_NO_REPLACE='5\.3\.0\.M の構文判定は置き換えない'
PIN_S52_NO_PROMOTE='対応確認（5\.2\.2）の前に High Confidence 扱いへ上げない'
PIN_E2E8='例外 8: ステップ 5\.4 の `### 根拠と主張の不対応`'
PIN_E2E8_COUNT='evidence_claim_rejected_count > 0'
PIN_S54_BEFORE='`### 全指摘事項` より前'
PIN_S54_NO_SHARE='見出しを共用せず'
PIN_TPL_REASON='不採用理由'
PIN_BASE_LEAP='観測を悪影響へ飛ばさない'
PIN_ASSESS_NO_READOPT='findings\[\]` から外した指摘は fix 対象に戻さない'
PIN_SEV_NOT_PROOF='主張する欠陥の成立そのものではない'
PIN_SEV_KEEP='5\.3\.0\.M の blocking 分類は維持する'
PIN_VERIFY_PROMPT='Critic 5\.2\.2 の証拠'
PIN_FACT_PIPE='Evidence-Claim Correspondence → Fact-Check'
PIN_FACT_ORDER='### 根拠と主張の不対応（該当がある場合のみ）'

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

# Adjacency: Dedup heading, then 5.2.2, then Fact-Checking, with no other #### between.
adjacency() {
  local order
  order=$(awk '
    /^#### Deduplication$/ { d=NR }
    /^#### 5\.2\.2 Evidence-Claim Correspondence$/ { c=NR }
    /^#### Fact-Checking Phase$/ { f=NR }
    /^#### / { if (d && !c && $0 !~ /^#### Deduplication$/) extra_before=1
               if (c && !f && $0 !~ /^#### 5\.2\.2 Evidence-Claim Correspondence$/ && $0 !~ /^#### Fact-Checking Phase$/) extra_mid=1 }
    END {
      if (!d || !c || !f) { print "missing"; exit }
      if (d < c && c < f && !extra_before && !extra_mid) print "ok"
      else print "bad"
    }
  ' "$SKILL")
  if [ "$order" = "ok" ]; then
    pass "adjacency: Dedup then 5.2.2 then Fact-Checking, no extra ####"
  else
    fail "adjacency: Dedup then 5.2.2 then Fact-Checking, no extra #### (got $order)"
  fi
}

tpl_count() {
  local n
  n=$(grep -c '^### 根拠と主張の不対応（該当がある場合のみ）$' "$TEMPLATES" || true)
  if [ "$n" = "2" ]; then
    pass "templates: reject heading appears twice (full + verification)"
  else
    fail "templates: reject heading appears twice (full + verification) (got $n)"
  fi
}

tpl_before_findings() {
  local ok
  ok=$(awk '
    /^### 根拠と主張の不対応/ { r=NR }
    /^### 全指摘事項$/ { if (r && NR==r+10) n++ ; r=0 }
    END { print n+0 }
  ' "$TEMPLATES")
  # heading + comment(4) + blank + table header + sep + row + blank = 10 lines to 全指摘事項
  # Don't pin exact gap; pin that each reject heading is followed by 全指摘事項
  # before the next ### that is not a table comment.
  local pairs
  pairs=$(awk '
    /^### / {
      if ($0 ~ /^### 根拠と主張の不対応/) { pending=1; next }
      if (pending && $0 ~ /^### 全指摘事項$/) { ok++; pending=0; next }
      if (pending) { bad++; pending=0 }
    }
    END { print ok+0, bad+0 }
  ' "$TEMPLATES")
  set -- $pairs
  if [ "$1" = "2" ] && [ "$2" = "0" ]; then
    pass "templates: reject heading is immediately before 全指摘事項 twice"
  else
    fail "templates: reject heading is immediately before 全指摘事項 twice (ok=$1 bad=$2)"
  fi
}

negative_control() {
  local label="$1" file="$2" start="$3" end="$4" pattern="$5"
  local mutant
  if ! mutant=$(mktemp "${TMPDIR:-/tmp}/rite-ecc-pin-mutant-XXXXXX"); then
    fail "$label (mktemp failed)"
    return
  fi
  grep -vE "$pattern" "$file" > "$mutant" || true
  if [ ! -s "$mutant" ]; then
    fail "$label (mutant copy is empty)"
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

adjacency
tpl_count
tpl_before_findings

pin "Dedup keeps acceptance-reviewer non-merge" \
  "$SKILL" "$DEDUP_START" "$CORR_START" "$PIN_ACCEPTANCE"
pin "Dedup merge waits for 5.2.2" \
  "$SKILL" "$DEDUP_START" "$CORR_START" "$PIN_DEDUP_AFTER"
pin "Dedup does not take highest severity for weak evidence" \
  "$SKILL" "$DEDUP_START" "$CORR_START" "$PIN_NO_HIGHEST"
pin "Flagged-by-multiple is not reject reinforcement" \
  "$SKILL" "$DEDUP_START" "$CORR_START" "$PIN_NO_FLAG"

pin "5.2.2 forbids new helper/schema/standing approval" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NO_HELPER"
pin "5.2.2 does not write verification" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NO_VERIF_WRITE"
pin "5.2.2 skips when zero findings" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_ZERO_SKIP"
pin "5.2.2 still runs when Fact-Check skips" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_FC_SKIP_RUN"
pin "5.2.2 same procedure in verification mode" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_VERIFY_SAME"
pin "reject is not placed in findings[]" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NOT_IN_FINDINGS"
pin "reject is removed from 全指摘事項" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_EXCLUDE_ALL"
pin "5.2.2 retains rejected count after judgment" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_RETAIN_COUNT"
assert_grep "5.3.0.M step 1 does not write 5.2.2 rejects" "$SKILL" "$PIN_M_NO_WRITE"
pin "reject records under dedicated heading" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_REJECT_HEADING"
pin "valid proof stays on 5.3.0.M/C" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_ADOPT"
pin "new convention is not original-requirement proof" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NO_NEW_RULE"
pin "blocked/undetermined/contradiction keep existing paths" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_EXISTING_PATH"
pin "reject is not mixed into 実測なし指摘" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NOT_NB"
pin "measured=true after adopt is observation record" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_MEASURED_AFTER"
pin "5.2.2 does not replace measured-gate syntax" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NO_REPLACE"

pin "5.2 does not promote High Confidence before 5.2.2" \
  "$SKILL" "$S52_START" "$S521_START" "$PIN_S52_NO_PROMOTE"
assert_grep "E2E exception 8 names the reject section" "$SKILL" "$PIN_E2E8"
assert_grep "E2E exception 8 keys off rejected count" "$SKILL" "$PIN_E2E8_COUNT"
pin "5.4 places reject section before 全指摘事項" \
  "$SKILL" "$S54_START" "$S6_START" "$PIN_S54_BEFORE"
pin "5.4 does not share CONTRADICTED heading" \
  "$SKILL" "$S54_START" "$S6_START" "$PIN_S54_NO_SHARE"

pin "template reason column present (full+verification share file)" \
  "$TEMPLATES" '^### 根拠と主張の不対応' '^### 全指摘事項$' "$PIN_TPL_REASON"
pin "fact-check pipeline includes correspondence before Fact-Check" \
  "$FACT" '^## Overview$' '^## Configuration$' "$PIN_FACT_PIPE"
pin "fact-check section order lists reject heading" \
  "$FACT" '^### Section Ordering in Report$' '^> \*\*HYPOTHETICAL' "$PIN_FACT_ORDER"
pin "reviewer-base forbids observation-to-harm leap" \
  "$BASE" '^## Verification: runtime 実測の添付$' '^## Scope Assignment Flowchart$' "$PIN_BASE_LEAP"
pin "assessment-rules forbids fix re-adoption" \
  "$ASSESS" '^## 5\.3\.1 Assessment Rules$' '^## 5\.3\.3' "$PIN_ASSESS_NO_READOPT"
pin "severity-levels: measured is not entailment" \
  "$SEV" '^## 実測必須ゲート' '^## Severity' "$PIN_SEV_NOT_PROOF"
pin "severity-levels keeps adopted blocking path" \
  "$SEV" '^## 実測必須ゲート' '^## Severity' "$PIN_SEV_KEEP"
pin "verification prompt points at 5.2.2" \
  "$VERIFY" '失敗 job が本 PR' '^## 制約$' "$PIN_VERIFY_PROMPT"

assert_not_grep "no independent evidence-claim helper script" \
  "$SKILL" 'review-evidence-claim-gate\.sh'
assert_not_grep "no standing human approval added in 5.2.2" \
  "$SKILL" '常設承認を新設'

negative_control "NC: PIN_NOT_IN_FINDINGS is live" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NOT_IN_FINDINGS"
negative_control "NC: PIN_EXCLUDE_ALL is live" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_EXCLUDE_ALL"
negative_control "NC: PIN_RETAIN_COUNT is live" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_RETAIN_COUNT"
negative_control "NC: PIN_NO_HELPER is live" \
  "$SKILL" "$CORR_START" "$FACT_START" "$PIN_NO_HELPER"
negative_control "NC: PIN_E2E8 is live" \
  "$SKILL" '^## E2E Output Minimization$' '^## Invocation Context' "$PIN_E2E8"
negative_control "NC: PIN_S52_NO_PROMOTE is live" \
  "$SKILL" "$S52_START" "$S521_START" "$PIN_S52_NO_PROMOTE"
negative_control "NC: PIN_ASSESS_NO_READOPT is live" \
  "$ASSESS" '^## 5\.3\.1 Assessment Rules$' '^## 5\.3\.3' "$PIN_ASSESS_NO_READOPT"

print_summary "critic-evidence-claim-static-pin.test.sh"
