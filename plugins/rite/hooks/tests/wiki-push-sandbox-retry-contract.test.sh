#!/bin/bash
# Static contract for the wiki push retry path: every raw-commit caller retries an exit-4
# push outside the sandbox and keeps an unresolved failure visible at completion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

check_caller() {
  local label="$1" file="$2" section_pattern="$3" rc_predicate="$4" section
  section="$(awk -v start="$section_pattern" '
    index($0, start) { capture=1 }
    capture { print }
    capture && /^---$/ { exit }
  ' "$file")"

  assert "$label: section found" "1" "$([ -n "$section" ] && echo 1 || echo 0)"
  assert "$label: attempt ID uses portable seconds/pid/random components" "1" \
    "$(printf '%s\n' "$section" | grep -cF -- '$(date +%s)-$$-$RANDOM' || true)"
  assert "$label: attempt ID does not use non-portable date nanoseconds" "0" \
    "$(printf '%s\n' "$section" | grep -cF -- 'date +%s%N' || true)"
  assert "$label: retry uses push-only helper" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF 'wiki-ingest-commit.sh --push-only' || true) >= 1 ))"
  assert "$label: retry is gated on caller exit 4" "1" \
    "$(printf '%s\n' "$section" | grep -cF "$rc_predicate" || true)"
  assert "$label: retry explicitly disables sandbox" "1" \
    "$(printf '%s\n' "$section" | grep -cF 'dangerouslyDisableSandbox: true' || true)"
  assert "$label: retry emits success outcome" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF 'echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=ok;' || true) == 1 ))"
  assert "$label: retry emits failure outcome" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF 'echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=failed;' || true) == 1 ))"
  assert "$label: unresolved push is visible in completion" "1" \
    "$(printf '%s\n' "$section" | grep -cF '⚠️ Wiki push 未完了:' || true)"
  assert "$label: completion predicate is scoped to current attempt" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF '現在の `WIKI_PUSH_ATTEMPT` と同じ `attempt=`' || true) == 1 ))"
  assert "$label: successful retry suppresses unresolved warning" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF 'その attempt に `WIKI_INGEST_PUSH_RETRY=ok` が無い場合だけ' || true) == 1 ))"
}

echo "=== wiki push sandbox retry caller parity ==="
check_caller review "$PLUGIN_ROOT/skills/pr-review/SKILL.md" '#### 6.5.W.2 Wiki Raw Commit' '`commit_rc=4` を観測した場合'
check_caller fix "$PLUGIN_ROOT/skills/fix/SKILL.md" '### 4.6.W.2 Wiki Raw Commit' '`wiki_ingest_commit_rc=4` を観測した場合'
check_caller issue-close "$PLUGIN_ROOT/skills/issue-close/SKILL.md" '### 4.4.W.2 Wiki Raw Commit' '`commit_rc=4` を観測した場合'

echo ""
echo "=== push-only runtime: legacy layout without wiki worktree ==="
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
remote="$fixture/remote.git"
repo="$fixture/repo"
git init -q --bare "$remote"
git init -q "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" remote add origin "$remote"
printf 'seed\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm seed
git -C "$repo" branch -M develop
git -C "$repo" push -q origin develop
git -C "$repo" switch -qc wiki
printf 'wiki seed\n' > "$repo/wiki.md"
git -C "$repo" add wiki.md
git -C "$repo" commit -qm 'wiki seed'
git -C "$repo" push -q origin wiki
git -C "$repo" switch -q develop
printf '%s\n' 'wiki:' '  enabled: true' '  branch_strategy: separate_branch' '  branch_name: wiki' > "$repo/rite-config.yml"
mkdir -p "$repo/.rite/wiki/raw/reviews"
printf '%s\n' '---' 'ingested: false' '---' 'raw' > "$repo/.rite/wiki/raw/reviews/pr-test.md"

# Reject the first push after the local wiki commit lands.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$remote/hooks/pre-receive"
chmod +x "$remote/hooks/pre-receive"
rc=0
first_out=$(cd "$repo" && bash "$PLUGIN_ROOT/hooks/scripts/wiki-ingest-commit.sh" 2>&1) || rc=$?
assert "legacy raw commit reports exit 4 when initial push is rejected" "4" "$rc"
assert "legacy raw commit reports push=failed" "1" \
  "$(printf '%s\n' "$first_out" | grep -cF 'push=failed' || true)"
assert "fixture truly has no wiki worktree" "0" "$([ -d "$repo/.rite/wiki-worktree" ] && echo 1 || echo 0)"

# Sandbox-disabled retry is represented by removing the rejection boundary;
# the command itself is exactly the caller's fixed push-only entrypoint.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$remote/hooks/pre-receive"
rc=0
retry_out=$(cd "$repo" && bash "$PLUGIN_ROOT/hooks/scripts/wiki-ingest-commit.sh" --push-only 2>&1) || rc=$?
assert "push-only retry succeeds without wiki worktree" "0" "$rc"
assert "push-only retry reports push=ok" "1" \
  "$(printf '%s\n' "$retry_out" | grep -cF 'push=ok; mode=push-only' || true)"
assert "successful retry advances origin/wiki" \
  "$(git -C "$repo" rev-parse wiki)" "$(git --git-dir="$remote" rev-parse wiki)"

# A still-blocked retry remains exit 4 and therefore keeps the completion
# warning predicate unresolved.
wiki_parent=$(git -C "$repo" rev-parse wiki)
wiki_tree=$(git -C "$repo" rev-parse 'wiki^{tree}')
wiki_local=$(printf 'local only\n' | git -C "$repo" commit-tree "$wiki_tree" -p "$wiki_parent")
git -C "$repo" update-ref refs/heads/wiki "$wiki_local" "$wiki_parent"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$remote/hooks/pre-receive"
rc=0
failed_retry_out=$(cd "$repo" && bash "$PLUGIN_ROOT/hooks/scripts/wiki-ingest-commit.sh" --push-only 2>&1) || rc=$?
assert "push-only retry preserves exit 4 on repeated failure" "4" "$rc"
assert "failed retry remains visibly push=failed" "1" \
  "$(printf '%s\n' "$failed_retry_out" | grep -cF 'push=failed; mode=push-only' || true)"

if ! print_summary "$(basename "$0")" "sandbox-disabled wiki push retry + completion visibility parity"; then
  exit 1
fi
