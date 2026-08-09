#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
ROOT="$SCRIPT_DIR/../.."
BASE="$ROOT/agents/_reviewer-base.md"
GEN="$ROOT/skills/pr-review/references/reviewer-prompt-generator.md"
SKILL="$ROOT/skills/pr-review/SKILL.md"
TEMPLATES="$ROOT/skills/pr-review/references/integrated-report-templates.md"
SCHEMA="$ROOT/references/review-result-schema.md"
ARCHIVER="$ROOT/hooks/scripts/review-results-archive-or-rm.sh"

assert_grep "base requires Category #2 audit rows" "$BASE" 'Category #2 items MUST be listed'
assert_grep "base defines empty handling" "$BASE" 'When no item is logged, emit `なし`'
assert_grep "generated reviewer prompt contains audit section" "$GEN" '^### 監査ログ$'
assert_grep "collector retains Category #2 rows" "$SKILL" 'Category #2.*guardrail_audit_log'
assert_grep "collector derives the E2E display count from the array" "$SKILL" 'guardrail_audit_count = guardrail_audit_log\.length'
assert_grep "E2E minimization exempts audit output" "$SKILL" '例外 4:.*Guardrail 監査ログ.*guardrail_audit_count > 0'

full_count=$(awk '/^## full-mode-template$/{mode=1} mode && /^```markdown$/{fence=1; next} mode && fence && /^```$/{exit} mode && fence' "$TEMPLATES" | grep -c '^### Guardrail 監査ログ' || true)
verification_count=$(awk '/^## verification-mode-template$/{mode=1} mode && /^```markdown$/{fence=1; next} mode && fence && /^```$/{exit} mode && fence' "$TEMPLATES" | grep -c '^### Guardrail 監査ログ' || true)
assert "full report template renders audit log exactly once" "1" "$full_count"
assert "verification report template renders audit log exactly once" "1" "$verification_count"
assert_grep "collector and schema use canonical reviewer key" "$SKILL" 'guardrail_audit_log.*`reviewer`, `filter_category`'
assert_grep "schema has durable audit array" "$SCHEMA" '^[|] `guardrail_audit_log` [|] array [|]'
assert_grep "cleanup preserves non-empty audit arrays" "$ARCHIVER" 'guardrail_audit_log.*length > 0'

print_summary
