#!/bin/bash
# 設計規則の節が各 SoT に実在し、規則を指すリンクが実在するファイルと見出しに解決することを固定する。
# 検査するのは、各規則節の実在と代表規則、実装者の入口（coding-principles）から各規則節へのリンク、
# 規則ファイル間のリンクの解決まで。reviewer が実行時に規則を読む経路は検査しない。
# 規則の本文は references 側が SoT であり、入口側は 1 行のポインタだけを持つ。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

RITE="$SCRIPT_DIR/../.."
REFS="$RITE/references"
PRINCIPLES="$RITE/skills/rite-workflow/references/coding-principles.md"

# 規則節: ファイル|節見出し|節内に必ず残る代表規則（正常系の pin）
RULES=(
  "sentinel-contract.md|## 設計規則|成功以外の終了経路（中断・エラー）も区別できる sentinel を定義し"
  "hook-guard-design-rules.md|## 脅威モデルと fail 方向|旧実装が例外で拒否していた入力を列挙し、新実装でも拒否されることを確かめる"
  "hook-guard-design-rules.md|## 制御文字と診断|を使うと C1 制御バイトを見逃す"
  "hook-guard-design-rules.md|## 防御の検証|防御を外す mutation で FAIL する pin を置く"
  "hook-guard-design-rules.md|## hook の有効化と範囲|同じ条件を読む全 hook を grep し"
  "git-worktree-patterns.md|## Worktree と git 操作の規則|\`.git\` を直書きせず \`git rev-parse --git-path\` を使う"
  "wiki-patterns.md|## ingest・lint の検出規則|判定 regex を共有する。片方だけ狭いと"
  "state-read-evolution.md|## 状態パス・再入ガードの規則|処理した範囲を、処理本体と同じ単位で記録し、最新と一致するときだけ skip する"
  "gh-cli-patterns.md|## PR 作成・運用の規則|に \`--base\` を明示する"
)

# 節本文の抽出。節見出しから次の `## ` 見出しまたは `---` の手前まで。
section_body() {
  local line on=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$on" -eq 0 ]; then
      [ "$line" = "$2" ] && on=1
      continue
    fi
    case "$line" in '## '*|'---') break ;; esac
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
printf '## 設計規則\n\n## 別の節\n成功以外の終了経路\n' > "$FIX_DIR/outside.md"
if rule_in_section "$FIX_DIR/outside.md" '## 設計規則' '成功以外の終了経路'; then
  fail "a rule outside its section must not satisfy the pin"
else
  pass "a rule outside its section does not satisfy the pin"
fi
printf '# t\n' > "$FIX_DIR/no-section.md"
if rule_in_section "$FIX_DIR/no-section.md" '## 設計規則' '成功以外の終了経路'; then
  fail "a missing section must not satisfy the pin"
else
  pass "a missing section does not satisfy the pin"
fi

# 到達性: 実装者の入口が規則を指すこと、規則本文にリンク先が実在すること。
assert_grep "coding-principles points to the sentinel rules" "$PRINCIPLES" \
  'references/sentinel-contract\.md#設計規則'
assert_grep "coding-principles points to the hook/guard rules" "$PRINCIPLES" \
  'references/hook-guard-design-rules\.md\)'
assert_grep "coding-principles points to the state rules" "$PRINCIPLES" \
  'references/state-read-evolution\.md#状態パス再入ガードの規則'
assert_grep "coding-principles points to the PR rules" "$PRINCIPLES" \
  'references/gh-cli-patterns\.md#pr-作成運用の規則'
assert_grep "coding-principles points to the wiki rules" "$PRINCIPLES" \
  'references/wiki-patterns\.md#ingestlint-の検出規則'
assert_grep "hook rules link the worktree section" "$REFS/hook-guard-design-rules.md" \
  'git-worktree-patterns\.md#worktree-と-git-操作の規則'
assert_grep "hook rules link the sentinel section" "$REFS/hook-guard-design-rules.md" \
  'sentinel-contract\.md#設計規則'

# リンクの解決: 規則ファイルへの `<相対パス>.md(#<anchor>)?` を、リンク元のディレクトリ基準で解決する。
# ファイルの実在と、アンカーがあれば参照先の見出しの slug との一致を確かめる。
# slug は小文字化、空白を `-`、見出しに現れる `・` を除去して作る。
heading_slug() {
  local h=${1#\#\# }
  h=${h//・/}; h=${h// /-}
  printf '%s' "$h" | tr 'A-Z' 'a-z'
}
anchor_resolves() {
  local target=$1 want=$2 line fence=0
  while IFS= read -r line; do
    case "$line" in '```'*) fence=$((1 - fence)); continue ;; esac
    [ "$fence" -eq 0 ] || continue
    case "$line" in '## '*) [ "$(heading_slug "$line")" = "$want" ] && return 0 ;; esac
  done < "$target"
  return 1
}
# 引数: リンク元ファイル リンク文字列（`path.md` または `path.md#anchor`）。解決できれば 0。
link_resolves() {
  local src=$1 ref=$2 tfile want=""
  tfile=${ref%%#*}
  case "$ref" in *'#'*) want=${ref#*#} ;; esac
  [ -f "$(dirname "$src")/$tfile" ] || return 1
  [ -z "$want" ] || anchor_resolves "$(dirname "$src")/$tfile" "$want"
}
refs_found=0
for src in "$PRINCIPLES" "$REFS/hook-guard-design-rules.md" "$REFS/wiki-patterns.md"; do
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    refs_found=$((refs_found + 1))
    if link_resolves "$src" "$ref"; then
      pass "$(basename "$src"): $ref resolves"
    else
      fail "$(basename "$src"): $ref does not resolve"
    fi
  done < <(grep -oE '\]\([^)]*(sentinel-contract|hook-guard-design-rules|state-read-evolution|git-worktree-patterns|gh-cli-patterns|wiki-patterns)\.md[^)]*\)' "$src" | sed -e 's/^](//' -e 's/)$//')
done
[ "$refs_found" -ge 8 ] && pass "rule links were found ($refs_found)" || fail "too few rule links found ($refs_found)"

# 負例: 階層を誤ったリンクは解決しない。
printf '## 設計規則\n' > "$FIX_DIR/target.md"
printf '[x](../references/target.md#設計規則)\n' > "$FIX_DIR/link.md"
if link_resolves "$FIX_DIR/link.md" "../references/target.md#設計規則"; then
  fail "a link with a wrong directory must not resolve"
else
  pass "a link with a wrong directory does not resolve"
fi
if link_resolves "$FIX_DIR/link.md" "target.md#設計規則"; then
  pass "a correct relative link resolves"
else
  fail "a correct relative link should resolve"
fi

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

# 負例: コードフェンス内の見出しは解決対象にしない。
printf '```\n## 設計規則\n```\n' > "$FIX_DIR/fenced.md"
if anchor_resolves "$FIX_DIR/fenced.md" '設計規則'; then
  fail "a heading inside a code fence must not resolve"
else
  pass "a heading inside a code fence does not resolve"
fi

if ! print_summary "$(basename "$0")" \
  "機構別の設計規則節と、規則へのリンクの解決。規則本文は plugins/rite/references/ が SoT。"; then
  exit 1
fi
