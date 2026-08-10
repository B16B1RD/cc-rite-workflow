---
title: "Bash 配列の slash-deletion は要素を空文字列に置換するだけで削除しない"
domain: "anti-patterns"
description: "`cleanup_dirs=("${arr[@]/$target}")` 形式の bash パラメータ展開は各要素内の `pattern` 一致部分を空文字列に置換するだけで配列スロットを削除しない。trap 等の cleanup ループが `[ -n "$d" ]` filter で空要素を skip する設計だと「機能的には安全」に見えるが、反復ごとに空要素が累積し配列サイズが test cycle と比例して肥大する silent failure。完全削除を保証する明示的再構築 helper (`for d in "${arr[@]:-}"; do [ -n "$d" ] && [ "$d" != "$target" ] && new+=("$d"); done` + `${#new[@]}` 分岐) で `set -u` 安全に対応。過去のレビューで 10 反復後 10 → 0 累積を実測、shellcheck カスタムルール / CI grep で `[@]/$` ban する構造的予防が推奨。"
created: "2026-05-16T13:30:00+09:00"
updated: "2026-05-16T13:30:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260516T041304Z-pr-991.md"
tags: []
confidence: high
---

# Bash 配列の slash-deletion は要素を空文字列に置換するだけで削除しない

## 概要

`cleanup_dirs=("${cleanup_dirs[@]/$target}")` のような bash パラメータ展開 `${arr[@]/pattern}` は、各要素内の `pattern` 一致部分を空文字列に置換するだけで配列スロット自体を削除しない。配列の長さは維持されたまま空要素が残るため、ループで `+=` するごとに「実要素 + 過去 cycle 分の空要素」で配列が単調増加する silent failure を起こす。

## 詳細

### 現象

```bash
cleanup_dirs=()
for i in 1 2 3; do
  SBX="/tmp/sandbox-$i"
  cleanup_dirs+=("$SBX")
  cleanup_dirs=("${cleanup_dirs[@]/$SBX}")  # ← 削除のつもり
done
echo "${#cleanup_dirs[@]}"  # 期待: 0、実測: 3 (空要素 3 つが累積)
```

3 回 add/remove ループを回すと、`cleanup_dirs` には 3 個の空要素 (`""`) が残る。`${arr[@]/pattern}` は **各要素に対する文字列置換** であり、`pattern` 全体一致でも要素は配列から removed されず空文字列 `""` に置換されるだけ。

### なぜ silent failure か

trap 等の cleanup ループが `for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done` のように空要素を skip する filter を持っていれば「機能的には安全」に見える。しかし以下の劣化が起きる:

1. **配列サイズが test cycle と比例して肥大** (cleanup ループの O(n) 走査負荷)
2. **観測性低下**: `echo "${cleanup_dirs[@]}"` で空要素も dump され、stderr ログの S/N 比が悪化
3. **境界条件で罠化**: `${#cleanup_dirs[@]}` を「残数 0 で完了」判定に使う code path があれば、空要素が居座って 0 にならず無限ループに陥る経路が新規導入される

### 修正パターン

完全削除を保証する明示的な再構築 (helper 関数化推奨):

```bash
_remove_from_array() {
  local target="$1"
  local d
  local new=()
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ "$d" != "$target" ] && new+=("$d")
  done
  if [ ${#new[@]} -gt 0 ]; then
    cleanup_dirs=("${new[@]}")
  else
    cleanup_dirs=()
  fi
}
```

ポイント:

- `${cleanup_dirs[@]:-}` で空配列展開 (`set -u` 安全)
- `[ -n "$d" ]` filter で過去の slash-deletion 残骸 (空要素) も同時クリア (defensive)
- `if/else` で空配列代入 `cleanup_dirs=()` を明示 (`("${new[@]}")` は空展開で `("")` の 1 要素配列を作る経路あり)

### 実測検証

10 反復後の累積を測定:

| パターン | 10 反復後 `${#cleanup_dirs[@]}` |
|---------|------------------------------|
| `${arr[@]/$target}` (旧) | 10 (空要素累積) |
| `_remove_from_array "$target"` (新) | 0 |

### 構造的予防

- `shellcheck` カスタムルール / CI grep で `\[@\]/\$` パターンを ban する保険を入れる
- test fixture では配列操作 helper を共通化して 1 箇所にロジックを集約する (`_test-helpers.sh` 集約候補)

## 関連ページ

- [grep -oe / wc を pipefail 下で連結すると silent abort する](./grep-oe-wc-pipefail-silent-abort.md)

## ソース

- [PR #991 review results](../../raw/reviews/20260516T041304Z-pr-991.md)
