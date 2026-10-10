---
type: "patterns"
title: "固定だった挙動を設定化したら、仕様書と README の固定記述を 1 回の grep で全数洗い出す"
domain: "patterns"
description: "固定の挙動を設定で選べるようにすると、仕様書のコマンド表・フロー図・設定表や README に固定の記述が散らばって残る。一部だけ直すとレビューのたびに残りが指摘されるので、旧挙動を表す語で一度に全数を洗い出してから直す。"
created: "2026-10-10T01:04:42Z"
generated: { by: "manual/claude-opus-5-5", at: "2026-10-10T02:51:06Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261009T233431Z-pr-3735.md"
  - type: "fixes"
    resource: "raw/fixes/20261010T001835Z-pr-3735.md"
  - type: "reviews"
    resource: "raw/reviews/20261010T003759Z-pr-3735.md"
tags: ["documentation-sync", "configuration", "grep-inventory"]
confidence: high
---

# 固定だった挙動を設定化したら、仕様書と README の固定記述を 1 回の grep で全数洗い出す

## 概要

固定の挙動を設定で選べるようにすると、仕様書のコマンド表・フロー図・設定表や README に固定の記述が散らばって残る。一部だけ直すとレビューのたびに残りが指摘されるので、旧挙動を表す語で一度に全数を洗い出してから直す。

## 詳細

squash 固定だったマージを設定で squash / merge から選べるようにした変更で、仕様書の一部の行と README の表は直したが、同じ仕様書のコマンド表・フロー図と、トップレベルの設定表への設定キーの追加、README のコミット列挙が旧挙動のまま残った。レビューは最初の cycle で一部を指摘し、別の cycle で残りを指摘した。直した箇所の近くだけを見て直すと、同じファイルの別の節が取り残される。

手順は次のとおり。

1. 旧挙動を表す語（大文字小文字・ハイフンの有無の表記ゆれを含む）で、仕様書・README 英日・設定文書・skill をまとめて grep する
2. ヒットをすべて一覧にし、新しい挙動に合わせる行と、条件付きで正しい行（「既定の squash では」など）を分ける
3. 設定キーを足したら、設定の一覧表（トップレベル節の表）にも行を足す
4. 直した後に同じ grep を回して確かめられるのは、旧挙動の語が条件付きで正しい行のほかに残っていないことだけである。直すべき箇所を取りこぼしていないことは、対象の性質から導いた別の検索（新しい設定キーの出現箇所、設定表やコマンド表の行など、新しい挙動を書くべき場所の一覧）で確かめる（[スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)）

英日の README のように内容を揃える文書は、片方だけ直さず両方を同じ変更で直す。

## 関連ページ

- [「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](../heuristics/exhaustiveness-claims-require-mechanical-inventory.md)
- [スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)

## ソース

- [レビュー結果](../../raw/reviews/20261009T233431Z-pr-3735.md)
- [fix 結果](../../raw/fixes/20261010T001835Z-pr-3735.md)
- [レビュー結果](../../raw/reviews/20261010T003759Z-pr-3735.md)
