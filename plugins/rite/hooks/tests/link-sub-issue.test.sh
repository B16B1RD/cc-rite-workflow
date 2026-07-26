#!/bin/bash
# link-sub-issue.test.sh
#
# Pin static invariants of `scripts/link-sub-issue.sh`: placeholder rejection
# (an unsubstituted `{owner}` / `{repo}` must fail-fast rather than silently
# call the gh API with a literal placeholder), arg-count validation, and the
# JSON output skeleton shape. Runtime gh calls are not mocked here.
#
# Caller side: also verify the Variant B JSON fallback keeps a JSON-valid escape
# so the caller can parse the fallback result. The parent+Sub-Issue create/link
# logic was extracted from create.md into
# `scripts/decompose-issues.sh`, so the Variant B fallback now lives there
# (the Decompose path) rather than inline in create.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
TARGET="$PLUGIN_ROOT/scripts/link-sub-issue.sh"
DECOMPOSE_SH="$PLUGIN_ROOT/scripts/decompose-issues.sh"
HANDLER_REF="$PLUGIN_ROOT/references/sub-issue-link-handler.md"

for f in "$TARGET" "$DECOMPOSE_SH" "$HANDLER_REF"; do
  [ -f "$f" ] || { echo "ERROR: required file not found: $f" >&2; exit 1; }
done

echo "=== Phase 1: link-sub-issue.sh placeholder rejection ==="
# Unsubstituted Markdown placeholder must be rejected fail-fast (no silent gh API call).
rc=0
out=$(bash "$TARGET" '{owner}' 'repo' '1' '2' 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "TC-01 unsubstituted owner placeholder → non-zero exit (got $rc)"
else
  fail "TC-01 unsubstituted owner placeholder silently passed (exit 0)"
fi

rc=0
out=$(bash "$TARGET" 'B16B1RD' '{repo}' '1' '2' 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "TC-02 unsubstituted repo placeholder → non-zero exit"
else
  fail "TC-02 unsubstituted repo placeholder silently passed"
fi

echo "=== Phase 2: link-sub-issue.sh argument count validation ==="
rc=0
out=$(bash "$TARGET" 'owner' 'repo' '1' 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "TC-03 missing 4th positional arg → non-zero exit"
else
  fail "TC-03 missing 4th positional arg silently passed"
fi

echo "=== Phase 3: decompose-issues.sh Variant B JSON fallback safety ==="
# Hand-built JSON in the fallback path was historically prone to quote-escape
# breakage; the canonical `jq -n --arg err "$link_result" ...` form prevents that.
# This fallback was moved from create.md into decompose-issues.sh (the Decompose
# path) — assert it against its new home, NOT delete the contract.
# Assert (a) the "fatal exit" message is preserved, (b) construction goes through
# `jq -n`, (c) the produced JSON actually parses.
assert_grep "decompose-issues.sh Variant B fallback has JSON status=failed" "$DECOMPOSE_SH" 'link-sub-issue\.sh fatal exit'
assert_grep "decompose-issues.sh Variant B fallback builds JSON via jq -n" "$DECOMPOSE_SH" 'link_result=.\(jq -n'

# Runtime sanity: the fallback pattern's output JSON must parse via jq.
# Simulate the fallback locally with a stderr containing tricky characters.
trick_err='gh: "Could not resolve" to PullRequest with "id"='
fallback_json=$(jq -n --arg err "$trick_err" '{status:"failed",message:"link-sub-issue.sh fatal exit",warnings:[$err]}')
if printf '%s' "$fallback_json" | jq -e . >/dev/null 2>&1; then
  pass "TC-04 fallback JSON via jq -n parses cleanly even with quoted stderr"
else
  fail "TC-04 fallback JSON failed to parse: $fallback_json"
fi
if [ "$(printf '%s' "$fallback_json" | jq -r '.status')" = "failed" ]; then
  pass "TC-05 fallback JSON has status=failed"
else
  fail "TC-05 fallback JSON missing status=failed: $fallback_json"
fi

echo "=== Phase 4: handler reference enumerates active caller (create.md) ==="
assert_grep "sub-issue-link-handler.md references active caller create.md" "$HANDLER_REF" "create\.md.*ステップ 5\.4"

echo "=== Phase 5: link-sub-issue.sh emits JSON status field ==="
# script source 中に `"status"` キーが含まれること (output JSON skeleton 確認)
assert_grep "link-sub-issue.sh emits JSON with status field" "$TARGET" '"status"'
# Split per-status assertions so a removed status (e.g. dropping the
# `already-linked` idempotency path) fails its specific assertion instead of
# being masked by the OR-grep.
assert_grep "link-sub-issue.sh handles 'ok' status (successful link)" "$TARGET" '"ok"'
assert_grep "link-sub-issue.sh handles 'already-linked' status (idempotency)" "$TARGET" '"already-linked"'
assert_grep "link-sub-issue.sh handles 'failed' status (gh fatal)" "$TARGET" '"failed"'

print_summary "$(basename "$0")" "If you change the link-sub-issue.sh argument contract (4 positional args), JSON output schema, or remove the placeholder rejection, update this test, the consuming scripts/decompose-issues.sh + scripts/backfill-sub-issues.sh + sub-issue-link-handler.md, the manual recovery command in skills/issue-create/SKILL.md (link_failures 復旧手順の 4 positional args literal), the usage example in references/graphql-helpers.md, hooks/tests/create-md-invocation-symmetry.test.sh (TC-5b が 4-positional-arg 隣接形を pin), and scripts/tests/decompose-issues.test.sh (stub が 4-arg contract + JSON schema を複製). 列挙は 4-arg contract / JSON schema の literal を持つ consumer の全数 (literal を持たない設計ドキュメントは除く — grep link-sub-issue で棚卸し済)."
