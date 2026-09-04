#!/bin/bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
FIX="$ROOT/plugins/rite/skills/fix/SKILL.md"
REVIEW="$ROOT/plugins/rite/skills/pr-review/SKILL.md"
pass=0
fail=0

check() {
  label=$1 pattern=$2 file=$3
  if grep -qF "$pattern" "$file"; then
    echo "  ✅ $label"; pass=$((pass + 1))
  else
    echo "  ❌ $label"; fail=$((fail + 1))
  fi
}

check "fix は file JSON の receipt を検査" '.measured_gate.commit_sha == .commit_sha' "$FIX"
check "fix は未適用 JSON で停止" '[fix:error] reason=gate_not_applied' "$FIX"
check "pr-review は incremental も連続レール" 'full / incremental を問わない単一の連続レール' "$REVIEW"
check "pr-review は gate helper を実行" 'bash {plugin_root}/scripts/review-measured-gate.sh' "$REVIEW"
check "pr-review は save helper を実行" 'bash {plugin_root}/hooks/review-result-save.sh' "$REVIEW"

echo "PASS: $pass"
echo "FAIL: $fail"
[ "$fail" -eq 0 ]
