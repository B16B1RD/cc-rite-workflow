#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.."
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state/.rite"

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
  jq -n --arg base "${MOCK_BASE:-main}" --arg head "${MOCK_HEAD:-develop}" \
    --arg oid "0123456789abcdef0123456789abcdef01234567" \
    '{baseRefName:$base,headRefName:$head,headRefOid:$oid,commits:[{oid:$oid}]}'
elif [ "$1" = "api" ]; then
  oid="0123456789abcdef0123456789abcdef01234567"
  if [ "${MOCK_UNREVIEWED:-0}" = 1 ]; then printf '[]\n'
  else jq -n --arg oid "$oid" '[{merged_at:"2026-08-01T00:00:00Z",merge_commit_sha:$oid}]'; fi
else
  exit 64
fi
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Keep repository resolution deterministic while isolating state output.
export PATH="$TMP_ROOT/bin:$PATH"
export RITE_STATE_ROOT="$TMP_ROOT/state"

head_oid=$(bash "$HOOKS_DIR/release-promotion-verify.sh" 88)
test "$head_oid" = "0123456789abcdef0123456789abcdef01234567"
jq -e '.pr_number == 88 and .base == "main" and .head == "develop" and (.commits | length == 1)' \
  "$TMP_ROOT/state/.rite/release-promotions/88.json" >/dev/null

if MOCK_UNREVIEWED=1 bash "$HOOKS_DIR/release-promotion-verify.sh" 89 >/dev/null 2>&1; then
  echo "FAIL: unreviewed commit was accepted" >&2
  exit 1
fi
if MOCK_BASE=develop MOCK_HEAD=feature bash "$HOOKS_DIR/release-promotion-verify.sh" 90 >/dev/null 2>&1; then
  echo "FAIL: non-promotion PR shape was accepted" >&2
  exit 1
fi

echo "release-promotion-verify tests passed"
