---
type: "heuristics"
title: "記録専用フィールドを判定入力に格上げする変更は 4 点を同時に同期する"
domain: "heuristics"
promote: rite-plugin
description: "「これまで記録・表示にしか使っていなかったフィールドを、これからは判定の入力にする」という変更は一見小さいが、そのフィールドを読む経路・語る文書・書く経路のすべてに影響が及ぶ。"
created: "2026-07-27T17:54:54+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260727T041403Z-pr-2036.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-27T17:54:54+09:00" }
---

# 記録専用フィールドを判定入力に格上げする変更は 4 点を同時に同期する

## 概要

「これまで記録・表示にしか使っていなかったフィールドを、これからは判定の入力にする」という変更は一見小さいが、そのフィールドを読む経路・語る文書・書く経路のすべてに影響が及ぶ。起点事例の cycle 1 では 5 reviewer 中 3-4 名が独立に、この格上げ由来の SoT 非同期を検出した (CRITICAL 1 / HIGH 6)。

## 詳細

格上げ変更で同時発生した 5 つの欠陥は、すべて「片側だけ触った」ことに帰着する:

1. **同一 invariant の複数コピー間の非対称** — cross-field invariant の述語を read 経路 3 箇所 (P0/P2/P3) のうち 1 箇所だけ変更し、SoT ドキュメントも未更新。結果、同一 JSON が経路により受理/拒否に割れる。
2. **SoT 内での新旧規則の同居** — 旧規則 (「欠落 = false」の 1 層解釈) を禁止する注記を追加しても、同じファイルの canonical コードブロック・prospective 段落・サブフィールド表の前置きが旧規則のまま残ると、禁止対象の式を SoT 自身が「正準」として先に提示する導線が残る。
3. **判定時点に存在しないフィールドでの定義** — 集計値を `verification.measured == true` で定義したが、その判定が走る時点では JSON が未生成。実際の検出媒体 (本文中のアンカー regex) と語彙がずれ、literal 解釈すると判定そのものが壊れる。
4. **prompt に同時注入される文書どうしの正面衝突** — reviewer prompt は複数ファイルから抽出・結合されるため、片方だけ更新すると reviewer が「記録専用」と「blocking を決める」という逆の説明を同時に受け取る。
5. **相対リンクの深さ誤り** — 同一リストの近接行が `../../references/` なのに新規行だけ `../../../references/` で解決不能。`realpath -m` による機械検証で確定できる類の欠陥。

**チェックリスト化する 4 点**:

| # | 確認 | 手段 |
|---|------|------|
| (a) | そのフィールドを評価する全コピー | フィールド名を grep し、read 経路すべてを列挙してから同期する |
| (b) | SoT 内に残る旧規則記述 | 同一ファイル内の canonical コードブロック・前置き・prospective 段落を棚卸しする |
| (c) | 判定時点でのフィールド実在 | 判定が走るフェーズと、そのフィールドが書かれるフェーズの前後関係を確認する |
| (d) | 同時注入される他文書 | 抽出元ファイルの一覧を変更影響の grep 対象に含める |

**read 側と write 側を別 PR に分割する場合の追加要件**: 分割そのものが欠陥になりうる。read 側単独マージ時の挙動 — fail-safe 方向に倒れるか、経路間で判定が割れないか — を明示的に文書化する。本 PR では「欠落 = 未判定 = blocking (安全側)」という 3 値モデルを SoT に明記することで、write 側未配線の期間も判定が壊れないようにした。

## 関連ページ

- [SoT 同期は detection 側と authoring 側の双方向に書く — 片側だけでは機構が silent に空振りする](./sot-bidirectional-detection-and-authoring-sync.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #2036 review results](../../raw/reviews/20260727T041403Z-pr-2036.md)
