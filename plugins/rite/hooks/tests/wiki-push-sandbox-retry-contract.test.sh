#!/bin/bash
# Static contract for Issue #2049: every raw-commit caller retries an exit-4
# push outside the sandbox and keeps an unresolved failure visible at completion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

check_caller() {
  local label="$1" file="$2" section_pattern="$3" section
  section="$(awk -v start="$section_pattern" '
    index($0, start) { capture=1 }
    capture { print }
    capture && /^---$/ { exit }
  ' "$file")"

  assert "$label: section found" "1" "$([ -n "$section" ] && echo 1 || echo 0)"
  assert "$label: retry uses push-only helper" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF 'wiki-worktree-commit.sh --push-only' || true) >= 1 ))"
  assert "$label: retry explicitly disables sandbox" "1" \
    "$(printf '%s\n' "$section" | grep -cF 'dangerouslyDisableSandbox: true' || true)"
  assert "$label: retry emits success outcome" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF 'echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=ok;' || true) == 1 ))"
  assert "$label: retry emits failure outcome" "1" \
    "$(( $(printf '%s\n' "$section" | grep -cF 'echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=failed;' || true) == 1 ))"
  assert "$label: unresolved push is visible in completion" "1" \
    "$(printf '%s\n' "$section" | grep -cF '⚠️ Wiki push 未完了:' || true)"
}

echo "=== wiki push sandbox retry caller parity (#2049) ==="
check_caller review "$PLUGIN_ROOT/skills/pr-review/SKILL.md" '#### 6.5.W.2 Wiki Raw Commit'
check_caller fix "$PLUGIN_ROOT/skills/fix/SKILL.md" '### 4.6.W.2 Wiki Raw Commit'
check_caller issue-close "$PLUGIN_ROOT/skills/issue-close/SKILL.md" '### 4.4.W.2 Wiki Raw Commit'

if ! print_summary "$(basename "$0")" "sandbox-disabled wiki push retry + completion visibility parity (#2049)"; then
  exit 1
fi
