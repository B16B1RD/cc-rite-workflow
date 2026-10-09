#!/bin/bash
# claim-source-wiring-static-pin.test.sh
#
# Static-pin for the claim-source rail (主張と出典の照合) wiring.
# Pins mechanical rails only: the section sits right after Number-reference and
# right before 5.3.0.M, runs every cycle, calls the three helper modes, the E2E
# omit rule, both report templates, and the issue-implement pre-commit call.
# Each pin is also run against a mutant copy without the pinned text, so a pin
# that matches nothing (or matches regardless) fails here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SKILL="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
TEMPLATES="$PLUGIN_ROOT/skills/pr-review/references/integrated-report-templates.md"
IMPLEMENT="$PLUGIN_ROOT/skills/issue-implement/SKILL.md"

for f in "$SKILL" "$TEMPLATES" "$IMPLEMENT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

echo "=== claim-source-wiring-static-pin.test.sh ==="

NUMREF_HEADING='#### Number-reference `--diff` (every cycle)'
CLAIM_HEADING='#### 主張と出典の照合 (every cycle)'
MEASURED_PREFIX='#### 5.3.0.M '
PIN_EVERY_CYCLE='incremental / light / verification でも skip せず、前 cycle の判定を使い回さない'
PIN_E2E9='**例外 9: ステップ 5.4 の `### 主張と出典の照合` section は E2E でも省略禁止**'
PIN_CLASS_A='5.3.0.C では `category == "claim_source"` を class A 固定とする'
TEMPLATE_HEADING='### 主張と出典の照合'

# 主張と出典の照合節の本文 (見出しから次の #### 見出しの手前まで)
claim_section() {
  awk -v h="$CLAIM_HEADING" '$0 == h { s = 1; next } s && /^#### / { exit } s { print }' "$1"
}

# 見出しの隣接: Number-reference の次の #### が照合節、照合節の次が 5.3.0.M
check_adjacency() {
  grep -E '^#### ' "$1" | awk -v a="$NUMREF_HEADING" -v b="$CLAIM_HEADING" -v c="$MEASURED_PREFIX" '
    prev == a && $0 == b { ab = 1 }
    prev == b && index($0, c) == 1 { bc = 1 }
    { prev = $0 }
    END { exit !(ab && bc) }'
}
check_every_cycle() { claim_section "$1" | grep -qF "$PIN_EVERY_CYCLE"; }
check_modes() {
  local body
  body=$(claim_section "$1")
  grep -qF 'claim-source-check.sh extract --base origin/{base_branch}' <<<"$body" \
    && grep -qF -- '--pr {pr_number} --repo {owner_repo}' <<<"$body" \
    && grep -qF 'claim-source-check.sh facts --rows' <<<"$body" \
    && grep -qF 'claim-source-check.sh table --rows' <<<"$body"
}
check_class_a() { claim_section "$1" | grep -qF "$PIN_CLASS_A"; }
check_e2e9() { awk '/^## E2E Output Minimization$/ { s = 1 } /^## Invocation Context/ { s = 0 } s' "$1" | grep -qF "$PIN_E2E9"; }
check_templates() { [ "$(grep -cxF "$TEMPLATE_HEADING" "$1")" = "2" ]; }
check_implement() {
  grep -qF 'claim-source-check.sh extract --base origin/{base_branch} --out' "$1" \
    && grep -qF '#### 5.1.1.0 主張と出典の照合（commit 前）' "$1" \
    && grep -qF 'table --rows <行 JSON> --input' "$1" \
    && ! grep -qE 'claim-source-check\.sh extract .*--pr ' "$1"
}

# pin を本物で通し、pin 対象を消した mutant で落ちることを確かめる
pin() {
  local label="$1" check="$2" file="$3" remove="$4"
  if "$check" "$file"; then pass "$label"; else fail "$label"; fi
  local mutant
  mutant=$(mktemp "${TMPDIR:-/tmp}/rite-claim-pin-mutant-XXXXXX") || { fail "$label (mktemp failed)"; return; }
  grep -vF -- "$remove" "$file" > "$mutant" || true
  if [ -s "$mutant" ] && ! cmp -s "$file" "$mutant" && ! "$check" "$mutant"; then
    pass "NC: $label is live"
  else
    fail "NC: $label is not live (mutant without [$remove] still passes)"
  fi
  rm -f "$mutant"
}

pin "照合節は Number-reference の直後・5.3.0.M の直前" check_adjacency "$SKILL" "$CLAIM_HEADING"
pin "照合節は毎 cycle・全行を実行する" check_every_cycle "$SKILL" "$PIN_EVERY_CYCLE"
pin "照合節は extract (PR 本文込み) / facts / table を呼ぶ" check_modes "$SKILL" 'claim-source-check.sh facts --rows'
pin "照合節は claim_source を class A に固定する" check_class_a "$SKILL" "$PIN_CLASS_A"
pin "E2E 例外 9 (照合 section の省略禁止)" check_e2e9 "$SKILL" "$PIN_E2E9"
pin "両テンプレートに照合 section" check_templates "$TEMPLATES" "$TEMPLATE_HEADING"
pin "issue-implement は commit 前に PR 本文なしで照合する" check_implement "$IMPLEMENT" 'table --rows <行 JSON> --input'

print_summary "claim-source-wiring-static-pin.test.sh"
