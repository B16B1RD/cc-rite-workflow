---
type: "heuristics"
title: "カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る"
domain: "heuristics"
promote: rite-plugin
description: "README 等の案内板化でカテゴリ列挙を短縮する際、ブロッキング/informational の区別を SoT（実装側のカテゴリ表）で確認せずに削ると、ブロッキングカテゴリが脱落して実装とのImplementation Coverage 乖離を生む。"
created: "2026-07-23T19:20:00+09:00"
updated: "2026-07-23T19:20:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260723T094207Z-pr-1980.md"
  - type: "fixes"
    ref: "raw/fixes/20260723T094612Z-pr-1980.md"
  - type: "reviews"
    ref: "raw/reviews/20260723T100548Z-pr-1980-cycle2.md"
tags: []
confidence: medium
---

# カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る

## 概要

README 等の案内板化でカテゴリ列挙を短縮する際、ブロッキング/informational の区別を SoT（実装側のカテゴリ表）で確認せずに削ると、ブロッキングカテゴリが脱落して実装とのImplementation Coverage 乖離を生む。informational カテゴリの削除は無害だが、ブロッキング集合は完全に保つ必要がある。

## 詳細

README の仕様詳細を docs 正本へ委譲する圧縮 PR で、`/rite:wiki-lint` の検出カテゴリ列挙を「矛盾・陳腐化・孤児・壊れた相互参照」の 4 つに短縮したところ、実装のブロッキング検出カテゴリは 5 つ（矛盾・陳腐化・孤児・欠落概念・壊れた相互参照）であり、欠落概念（missing_concept）が脱落していた（Doc-Heavy レビューで MEDIUM 1 件として検出）。同時に削った未登録 raw（unregistered_raw）は informational のため脱落は無害だった。

有効だった進め方:

- **削る前に分類を確認する**: 削る対象が実装のどの分類（ブロッキング = 網羅必須 / informational = 省略可）に属すかを、SoT（実装側スキルのカテゴリ表）を Read してから判断する。「読者にとって details かどうか」だけで削ると、網羅性を主張する列挙（`A, B, and C` の形）から必須要素が欠ける。
- **修正は plain language 再追加**: 脱落したカテゴリをコード識別子（内部カウンタ名等）なしの平文（「missing concepts / 欠落概念」）で再追加すると、「内部識別子をドキュメントに書かない」という元の受入基準（grep 検証）を維持したままブロッキング集合の完全性を回復できる。informational カテゴリは再追加しない（指摘の本質のみに対応し過剰反応を避ける）。
- **英日同期**: 修正はローカライズペア（README.md / README.ja.md）へ対称に適用する。
- **収束の観察**: この種の圧縮 PR ではブロッキング集合の乖離だけが blocking finding となり、cycle 2 で指摘 0 件の mergeable に到達した（2 cycle 収束）。残ったスコープ外候補（リンク到達性・表記一貫性の推奨）はユーザー確認のうえ Decision Log 記録で決着し、Issue 化しなかった — README 圧縮系 PR ではこの種の推奨が boundary/actionable として残りやすい。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin](./universal-claim-prose-invalidated-by-path-addition.md)

## ソース

- [PR #1980 review results](../../raw/reviews/20260723T094207Z-pr-1980.md)
