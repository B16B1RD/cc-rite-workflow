---
type: "patterns"
title: "排他性を pin するテストは件数固定に加えて配置を両方向で固定する（在る側と無い側の 2 assert）"
domain: "patterns"
description: "「この marker を emit してよいのは 1 箇所だけ」「このガードを持つのは 3 ステップだけ」という**排他性**の主張を pin するとき、`grep -c` による出現数固定だけでは足りない。"
created: "2026-08-08T17:40:00+09:00"
updated: "2026-08-08T17:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260808T072312Z-pr-2150-cycle3.md"
  - type: "fixes"
    ref: "raw/fixes/20260808T072610Z-pr-2150-cycle3-fix.md"
  - type: "fixes"
    ref: "raw/fixes/20260808T074827Z-pr-2150-cycle4.md"
tags: []
confidence: high
---

# 排他性を pin するテストは件数固定に加えて配置を両方向で固定する（在る側と無い側の 2 assert）

## 概要

「この marker を emit してよいのは 1 箇所だけ」「このガードを持つのは 3 ステップだけ」という**排他性**の主張を pin するとき、`grep -c` による出現数固定だけでは足りない。件数固定は marker の**追加**（増殖）を捕まえるが、同じ marker を別の分岐へ**移設**する変異は総数が変わらないため素通しする。

さらに、範囲抽出（`assert_grep_in_section` 等）による配置 pin も**片方向だけでは変異が生存する**。「在る側」と「無い側」の 2 assert を併置して初めて主張が確定する。

## 詳細

### 3 段階の pin と、それぞれが取り逃すもの

| pin | 捕まえる | 取り逃す |
|-----|---------|---------|
| 存在 assert（`assert_grep`） | marker の削除 | 増殖・移設 |
| 件数固定（`grep -c` = N） | 増殖・削除 | **移設**（総数不変） |
| 片方向の配置 pin | その arm からの消失 or 別 arm への出現のどちらか一方 | もう一方 |
| 両方向の配置 pin | 上記すべて | — |

### 両方向が要る理由（統合できない）

- 「**この arm に 1 つ在る**」だけでは、arm ラベルの入れ替えを捕まえられない。範囲抽出のレンジが両 arm を含んでしまうと、marker が隣の arm へ移っても範囲内に留まるため緑のまま通る
- 「**別の arm に 1 つも無い**」だけでは、marker が case 文の外や別ステップへ移設されたときに検出できない。無い側の主張は満たされ続ける

両方を併置して初めて「唯一の emit が意図した arm 内に在る」が確定する。冗長に見えるが、片方を削ると必ず生存する変異クラスが生まれる。

```bash
# positive: 意図した arm の中に 1 つ在る
assert "delegation marker is emitted only from the in_worktree_unrecorded arm" "1" \
  "$(awk -v start='...' -v end='...' '$0 ~ start, $0 ~ end' "$FILE" | grep -c '^ *echo "\[CONTEXT\] MARKER=1')"

# negative: 隣の arm には 1 つも無い
assert "in_worktree arm never emits the delegation marker" "0" \
  "$(awk -v start='...' -v end='...' '$0 ~ start, $0 ~ end' "$FILE" | grep -c '^ *echo "\[CONTEXT\] MARKER=1')"
```

### 実行行にアンカーする

内側の `grep` は**実行行の形**（行頭の空白 + `echo` / `printf`）でアンカーする。marker 名だけを見ると、同じ marker 名に言及する散文・コメント行が範囲内にあるだけで positive 側が充足し、pin が実質的に無効化される。逆に `echo` 形だけを見ると `printf '%s\n' "..."` 形の emit を追加する変異が negative 側で生存する（実測: プラグイン全体に printf 形の `[CONTEXT]` emit が 29 箇所あり、書き換えは現実的な変異）。

### テスト名は述語より広い主張を名乗らない

「排他性を pin する」というテスト名を付けながら、実際に固定しているのが総数だけということがある。次の読み手は名前を読んで「排他性は pin 済み」と判断するため、名前と述語の gap はそのまま防護の穴になる。名前が約束する壊れ方すべてに mutant を当て、1 つでも生存したら**名前を狭めるか述語を広げるかの二択**で、放置は選べない。

## 関連ページ

- [assert のラベルが述語より広い範囲を名乗ると「虚偽主張」クラスの欠陥になる](../anti-patterns/assert-label-overclaims-predicate-scope.md)
- [awk -v 代入はバックスラッシュを剥がす — escape 付きパターンを渡した範囲指定 assert は常に PASS する](../anti-patterns/awk-v-assignment-strips-backslash-in-range-pattern.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)

## ソース

- [PR #2150 review results (cycle 3)](../../raw/reviews/20260808T072312Z-pr-2150-cycle3.md)
- [PR #2150 fix results (cycle 3)](../../raw/fixes/20260808T072610Z-pr-2150-cycle3-fix.md)
- [PR #2150 fix results (cycle 4)](../../raw/fixes/20260808T074827Z-pr-2150-cycle4.md)
