#!/usr/bin/env bash
# Contract test for the wiki-ingest summary authoring seam.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$SCRIPT_DIR/../../skills/wiki-ingest/SKILL.md"
PASS=0
FAIL=0

check_literal() {
  local label="$1" literal="$2"
  if grep -Fq -- "$literal" "$SKILL"; then
    PASS=$((PASS + 1)); echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $label" >&2
  fi
}

echo "=== wiki summary authoring contract ==="
check_literal "summary forbids descriptive number references" '番号参照を書かず、番号が担っていた観測事実・条件・因果を自己完結した散文で記述する'
check_literal "summary is shared by description and index" 'page frontmatter `description` と index.md のサマリー列へ同一文言を掲載する'
check_literal "description uses the summary without rewording" '値は上表の番号なし Why 要約をそのまま使い、独自の短縮・言い換えをしない'
check_literal "step 6 passes the literal description" 'index 用の別要約を生成しない'

echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
