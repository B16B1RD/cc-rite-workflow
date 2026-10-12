#!/bin/bash
# sentinel・hook/guard・worktree・状態パス・Wiki 検出・PR 運用の設計規則が、各機構の SoT 節に実在し、
# reviewer 定義のポインタから到達できることを固定する。
# 規則の本文は references 側が SoT であり、reviewer 側は 1 行のポインタだけを持つ。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

RITE="$SCRIPT_DIR/../.."
REFS="$RITE/references"
SEC_REVIEWER="$RITE/agents/security-reviewer.md"
ERR_REVIEWER="$RITE/agents/error-handling-reviewer.md"

# 規則節: ファイル|節見出し|節内に必ず残る代表規則（正常系の pin）
RULES=(
  "sentinel-contract.md|## 設計規則|3 経路を定義し"
  "hook-guard-design-rules.md|## 脅威モデルと fail 方向|旧実装が例外で拒否していた入力を列挙"
  "hook-guard-design-rules.md|## 制御文字と診断|C1 制御バイトを見逃す"
  "hook-guard-design-rules.md|## 防御の検証|防御を外す mutation で FAIL する pin"
  "hook-guard-design-rules.md|## hook の有効化と範囲|同じ条件を読む全 hook を grep"
  "git-worktree-patterns.md|## Worktree と git 操作の規則|git rev-parse --git-path"
  "wiki-patterns.md|## ingest・lint の検出規則|判定 regex を共有する"
  "state-read-evolution.md|## 状態パス・再入ガードの規則|処理した範囲を、処理本体と同じ単位で記録"
  "gh-cli-patterns.md|## PR 作成・運用の規則|--base"
)

# 節本文の抽出。節見出しから次の `## ` 見出しの手前まで。
section_body() {
  awk -v h="$2" '
    $0 == h { on = 1; next }
    on && /^## / { exit }
    on { print }
  ' "$1"
}

# 節内に代表規則が実在するか。節の外に同じ語があっても通さない。
rule_in_section() {
  section_body "$1" "$2" | grep -qF -- "$3"
}

for entry in "${RULES[@]}"; do
  IFS='|' read -r file heading phrase <<<"$entry"
  path="$REFS/$file"
  assert_file_exists_or_fail "$file exists" "$path" || exit 1
  if rule_in_section "$path" "$heading" "$phrase"; then
    pass "$file '$heading' carries the rule: $phrase"
  else
    fail "$file '$heading' lost the rule: $phrase"
  fi
done

# 負例: 節が空の fixture と、代表規則が節の外にだけある fixture は検出される。
FIX_DIR=$(mktemp -d) || { fail "fixture dir could not be created"; exit 1; }
trap 'rm -rf "$FIX_DIR"' EXIT
printf '## 設計規則\n\n## 別の節\n3 経路を定義し\n' > "$FIX_DIR/outside.md"
if rule_in_section "$FIX_DIR/outside.md" '## 設計規則' '3 経路を定義し'; then
  fail "a rule outside its section must not satisfy the pin"
else
  pass "a rule outside its section does not satisfy the pin"
fi
printf '# t\n' > "$FIX_DIR/no-section.md"
if rule_in_section "$FIX_DIR/no-section.md" '## 設計規則' '3 経路を定義し'; then
  fail "a missing section must not satisfy the pin"
else
  pass "a missing section does not satisfy the pin"
fi

# 到達性: reviewer 定義が規則節を指すこと、規則本文にリンク先が実在すること。
assert_grep "security-reviewer points to the hook/guard rules" "$SEC_REVIEWER" \
  '^rationale: \.\./references/hook-guard-design-rules\.md$'
assert_grep "error-handling-reviewer points to the sentinel rules" "$ERR_REVIEWER" \
  '^rationale: \.\./references/sentinel-contract\.md#設計規則$'
assert_grep "error-handling-reviewer points to the state rules" "$ERR_REVIEWER" \
  '^rationale: \.\./references/state-read-evolution\.md#状態パス再入ガードの規則$'
assert_grep "hook rules link the worktree section" "$REFS/hook-guard-design-rules.md" \
  'git-worktree-patterns\.md#worktree-と-git-操作の規則'
assert_grep "hook rules link the sentinel section" "$REFS/hook-guard-design-rules.md" \
  'sentinel-contract\.md#設計規則'

if ! print_summary "$(basename "$0")" \
  "機構別の設計規則節と reviewer ポインタ。規則本文は plugins/rite/references/ が SoT。"; then
  exit 1
fi
