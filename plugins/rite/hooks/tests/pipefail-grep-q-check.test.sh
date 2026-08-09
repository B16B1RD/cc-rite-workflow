#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
SCRIPT="$SCRIPT_DIR/../scripts/pipefail-grep-q-check.sh"
SBX="$(make_plain_sandbox)"; trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/plugins/rite/hooks"
fixture="$SBX/plugins/rite/hooks/fixture.sh"

cat > "$fixture" <<'EOF'
printf '%s|%s\n' "$a" "$b" | grep -q x
{ cmd; } | grep -q x
docker ps | grep -q x
enable -p | grep -q mapfile
printf '%s\n' "$json" | jq -r '.items[]' | grep -q child
EOF
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "true site yields warning rc" "1" "$rc"
assert "only the true jq producer is detected" "1" "$(printf '%s' "$out" | grep -c '^\[pipefail-grep-q\]')"
assert "quoted pipe in printf is not misparsed" "0" "$(printf '%s' "$out" | grep -c 'immediate producer.*%s' || true)"
assert "brace group is exempt" "0" "$(printf '%s' "$out" | grep -c 'immediate producer.*{ cmd' || true)"
assert "bounded docker ps probe is exempt" "0" "$(printf '%s' "$out" | grep -c 'producer.*docker ps' || true)"
assert "immediate jq stage is reported" "1" "$(printf '%s' "$out" | grep -c "producer before grep -q: jq -r" || true)"
assert "bounded enable probe is exempt" "0" "$(printf '%s' "$out" | grep -c 'producer.*enable -p' || true)"

printf '%s\n' 'stream_many | grep -q x # drift-check-ignore: bounded fixture' > "$fixture"
out=$(bash "$SCRIPT" --all --repo-root "$SBX" --quiet 2>&1); rc=$?
assert "ignore marker suppresses finding" "0" "$rc"
assert "ignored run reports zero" "1" "$(printf '%s' "$out" | grep -c 'Total pipefail-grep-q findings: 0')"

REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
out=$(bash "$SCRIPT" --all --repo-root "$REPO_ROOT" --quiet 2>&1); rc=$?
assert "known full-tree findings make the check non-clean" "1" "$rc"
assert "known full-tree finding total is pinned" "6" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\]')"
assert "wiki-lint-orphans known site is reported" "1" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/hooks/scripts/wiki-lint-orphans\.sh:')"
assert "wiki-growth known sites are reported" "2" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/hooks/scripts/wiki-growth-check\.sh:')"
assert "wiki-lint-broken-refs known sites are reported" "2" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/hooks/scripts/wiki-lint-broken-refs\.sh:')"
assert "backfill known site is reported" "1" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\] plugins/rite/scripts/backfill-sub-issues\.sh:')"
assert "review-source-resolve remains outside the finding set" "0" "$(printf '%s\n' "$out" | grep -c '^\[pipefail-grep-q\].*review-source-resolve\.sh:' || true)"
print_summary "pipefail-grep-q-check.sh"
