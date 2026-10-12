#!/bin/bash
# 設計規則の節が各 SoT に実在し、規則を指すポインタとリンクのアンカーが実在する見出しに解決する
# ことを固定する。reviewer からの到達は sentinel・状態・hook/guard の規則だけを検査する
# （worktree・Wiki・PR 運用の規則は既存のスキルの参照から到達する）。
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
  local line on=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$on" -eq 0 ]; then
      [ "$line" = "$2" ] && on=1
      continue
    fi
    case "$line" in '## '*) break ;; esac
    printf '%s\n' "$line"
  done < "$1"
}

# 節内に代表規則が実在するか。節の外に同じ語があっても通さない。
rule_in_section() {
  local body
  body=$(section_body "$1" "$2") || return 1
  grep -qF -- "$3" <<<"$body"
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

# アンカーの解決: ポインタとリンクの `<file>.md#<anchor>` が、参照先の見出しの slug に一致すること。
# slug は小文字化、空白を `-`、`・` と `（）` と `、` を除去（GitHub の規則に合わせる）。
heading_slug() {
  local h=${1#\#\# }
  h=${h//・/}; h=${h//（/}; h=${h//）/}; h=${h//、/}; h=${h// /-}
  printf '%s' "$h" | tr 'A-Z' 'a-z'
}
anchor_resolves() {
  local target=$1 want=$2 line
  while IFS= read -r line; do
    case "$line" in '## '*) [ "$(heading_slug "$line")" = "$want" ] && return 0 ;; esac
  done < "$target"
  return 1
}
refs_found=0
for src in "$SEC_REVIEWER" "$ERR_REVIEWER" "$REFS/hook-guard-design-rules.md" "$REFS/wiki-patterns.md"; do
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    refs_found=$((refs_found + 1))
    tfile=${ref%%#*}; tfile=${tfile##*/}; want=${ref#*#}
    if anchor_resolves "$REFS/$tfile" "$want"; then
      pass "$(basename "$src"): $tfile#$want resolves to a heading"
    else
      fail "$(basename "$src"): $tfile#$want does not resolve to a heading"
    fi
  done < <(grep -oE '[A-Za-z0-9_-]+\.md#[^) ]+' "$src" | grep -E '^(sentinel-contract|state-read-evolution|git-worktree-patterns)\.md#')
done
[ "$refs_found" -ge 5 ] && pass "anchor references were found ($refs_found)" || fail "too few anchor references found ($refs_found)"

# 負例: 改名後の見出しに対する古いアンカーは解決しない。
printf '## 状態パス・再入ガードの規則\n' > "$FIX_DIR/renamed.md"
if anchor_resolves "$FIX_DIR/renamed.md" '状態パス再入ガードの規則'; then
  pass "slug rule drops the middle dot"
else
  fail "slug rule should drop the middle dot"
fi
printf '## 状態パスと再入ガードの規則\n' > "$FIX_DIR/renamed2.md"
if anchor_resolves "$FIX_DIR/renamed2.md" '状態パス再入ガードの規則'; then
  fail "an anchor left behind by a rename must not resolve"
else
  pass "an anchor left behind by a rename does not resolve"
fi

if ! print_summary "$(basename "$0")" \
  "機構別の設計規則節と reviewer ポインタ。規則本文は plugins/rite/references/ が SoT。"; then
  exit 1
fi
