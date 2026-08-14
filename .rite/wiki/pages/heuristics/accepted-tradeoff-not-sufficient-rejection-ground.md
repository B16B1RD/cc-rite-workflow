---
type: "heuristics"
title: "「既存ドキュメントが accepted trade-off と書いている」は指摘却下の十分条件ではない"
domain: "heuristics"
description: "reviewer が finding を出したとき、helper の header や設計ドキュメントに「これは意図的な trade-off であり accepted」と書かれていることを根拠に却下する経路がある。"
created: "2026-08-06T02:49:27Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260806T001717Z-pr-2120.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T02:49:27Z" }
---

# 「既存ドキュメントが accepted trade-off と書いている」は指摘却下の十分条件ではない

## 概要

reviewer が finding を出したとき、helper の header や設計ドキュメントに「これは意図的な trade-off であり accepted」と書かれていることを根拠に却下する経路がある。PR #2120 cycle 2 で、security が `control-char-neutralize.sh` header の Trade-off (accepted) 記述を根拠に非 finding と判断し、error-handling が同じ箇所を MEDIUM finding とした。裏取りの結果、**header の記述自体は事実だったが、その正当化は当該サイトに届いていなかった**。accepted 表記は「その判断が過去に下された」ことの記録であって、目の前のサイトに対する反証ではない。

## 詳細

### 却下する前に確認する 2 点

| 確認項目 | 外れているときの意味 |
|---|---|
| **(a) 正当化の射程** | その accepted 判断が明示的に限定している条件に、当該サイトが含まれるか |
| **(b) 修正が trade-off を取り崩すか** | 提案された修正が accepted された不利益を実際に再導入するか |

**両方が成立して初めて accepted 表記は反証になる。** 片方でも外れていれば、accepted 記述は「別のケースについての判断」を引用しているに過ぎない。

### 実例 — 射程が当該サイトを含んでいなかった

`control-char-neutralize.sh` の header は「制御文字をバイト単位で潰すためロケール依存メッセージが判読不能になりうるが、これは accepted」と書いていた。ただし正当化の条件が併記されており、`The call sites are diagnostic-only output for corrupt/unknown input` と射程を限定していた。問題になったサイトは **bash 自身が出す redirect-setup エラー**で、corrupt/unknown input の診断ではない。射程外である。

```
✗ header に「accepted」とある → 非 finding
✓ header の accepted 条件を読む → 「call site が corrupt input の診断であること」
   → 当該 call site は bash 自身の診断 → 射程外 → accepted は適用されない
```

### 実例 — 修正が trade-off を取り崩さなかった

決定的だったのは (b) の側である。提案された修正は、失敗するコマンドに `LC_ALL=C` を前置して**上流メッセージを ASCII 化する**もので、neutralizer 自体には一切手を触れない。中和の強度は変わらず、その行に対して no-op になるだけである。

「accepted trade-off だから触るな」という反論は実質「中和を弱めるな」という主張であり、この修正はそれに該当しない。**trade-off を受け入れる必要自体を消す修正は、その trade-off の accepted 表記では却下できない。**

これは一般化できる: 安全機構が邪魔をすると感じたとき、機構を緩める修正と、機構に渡る入力を機構が問題視しない形へ変える修正は、レビュー上まったく別物として扱う。後者は accepted trade-off の射程外にある。

### 裏取りのコストは低い

本ケースで矛盾の解消に必要だったのは、両者の主張の重み付けではなく **片方が前提とした事実の裏取り 1 回**だった。同 PR の cycle 1 でも、error-handling が「既存 convention は silent」を前提に fail-loud 化を不要と判断したが、その convention は 2 コミット前に更新済みで、より新しい同種経路の rationale コメントが当該ケースを名指ししていた。前提崩壊により立場が維持できなくなり、エスカレーション不要で合意が成立している。

**reviewer 間の矛盾を見たら、まず両者が引用している「既存の記述」が現在も成立するかを grep で確認する。** 重み付けの議論はその後でよい。

### なお実測が必要な部分

`LC_ALL=C` prefix が bash 自身の redirect-setup エラーのロケールに効くことは、POSIX の simple command 処理順（redirection が assignment より先という読み方もある）から自明ではない。本ケースでは orchestrator が独立に実測して効くことを確認した。**「射程外だから直せる」と判断したあとも、その修正が実際に効くことは別途実測する。**

## 関連ページ

- [修正に添えるコメントは機構を語るほど次サイクルの検証対象面を広げる — 根拠はテストに置く](./comment-rationale-widens-review-surface.md)
- [制御文字中和を通した出力への grep assert はロケールで検出能力を失う](../anti-patterns/locale-dependent-error-message-grep-assertion.md)

## ソース

- [PR #2120 review results (cycle 2)](../../raw/reviews/20260806T001717Z-pr-2120.md)
