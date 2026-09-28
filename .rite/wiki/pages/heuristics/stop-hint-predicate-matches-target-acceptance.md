---
type: "heuristics"
title: "新しい state 操作は既存 state との組み合わせを実際の入口から試し、停止ヒントは案内先が受理する状態でだけ出す"
domain: "heuristics"
description: "新しい state 操作を足すと、保留中の見直しや検証途中の未コミット編集など既存 state との組み合わせで前進できなくなる経路が生まれる。helper を直接呼ぶ単体テストは入口の gate を通らないため、この行き止まりを検出できない。停止メッセージのヒントを出す条件が案内先操作の受理条件より広いと、案内が循環する。"
created: "2026-09-28T05:02:36Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T05:02:36Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260928T040457Z-pr-3376.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T043924Z-pr-3376.md"
tags: ["state-machine", "dead-end", "hint", "integration-test"]
confidence: high
---

# 新しい state 操作は既存 state との組み合わせを実際の入口から試し、停止ヒントは案内先が受理する状態でだけ出す

## 概要

新しい state 操作を足すと、保留中の見直しや検証途中の未コミット編集など既存 state との組み合わせで前進できなくなる経路が生まれる。helper を直接呼ぶ単体テストは入口の gate を通らないため、この行き止まりを検出できない。停止メッセージのヒントを出す条件が案内先操作の受理条件より広いと、案内が循環する。

## 詳細

### 観測された行き止まり

レビューの途中で受入条件を改訂し、同じレビューを続けるための操作（reconcile）を足したところ、次の既存 state との組み合わせで前進できない経路が複数見つかった。

- 見直し（replan）が保留中
- phase が review のまま完了した cycle がある
- 検証途中の未コミット編集が残っている

helper の単体テストはレビュー開始操作を直接呼ぶため、cycle の gate や修正範囲の検証を経由する経路を通らず、これらを検出できなかった。

### ヒントが循環する形

停止メッセージは「run が active なら reconcile を案内する」という条件でヒントを出していた。一方、reconcile は見直し未完了や観測ゼロの状態を拒否する。ヒントの条件が受理条件より広いため、案内に従うと拒否され、同じ停止に戻った。

### 直し方

- 新しい操作の受理条件、その後の工程の条件（再開ガード、clean tree の要求、見直し未完了の gate）、停止ヒントの述語をそろえる
- ヒントは案内先が受理する状態でだけ出す。すでに記録済みなら、次に行う操作を示す
- 保留中の義務（見直し）を新しい操作で消さない。次の観測へ持ち越し、通常の規則で再評価する
- テストは helper を直接呼ぶだけでなく、cycle の gate など実際の入口を通して行き止まりを固定する

## 関連ページ

- [仕様改訂の境界をまたいで観測を比べると停止判定が狂う — 各観測はその区間の基準と比べる](../anti-patterns/cross-boundary-comparison-after-spec-revision.md)
- [失敗時の復旧ヒントは呼び出し元の切り詰めと cwd の違いを越えて届く形で書く](./recovery-hint-survives-caller-truncation-and-cwd.md)

## ソース

- [レビュー結果（新しい state 操作と既存 state の組み合わせによる行き止まり）](../../raw/reviews/20260928T040457Z-pr-3376.md)
- [fix 結果（受理条件・後続工程・ヒント述語をそろえる）](../../raw/fixes/20260928T043924Z-pr-3376.md)
