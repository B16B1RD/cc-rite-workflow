---
type: "heuristics"
title: "受入条件の範囲を実装側の都合で黙って狭めると、書かれたとおりに未充足と判定される"
domain: "heuristics"
description: "受入条件の本文が範囲を限定していないのに、実装が helper の制約を理由に一部を範囲外とすると、acceptance レビューは条件を書かれたとおりに読んで未充足とする。範囲を絞るなら条件を先に改訂し、絞らないなら helper を直す。"
created: "2026-10-01T01:19:14Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-10-01T01:19:14Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261001T005011Z-pr-3571.md"
  - type: "fixes"
    resource: "raw/fixes/20261001T010038Z-pr-3571.md"
tags: []
confidence: medium
---

# 受入条件の範囲を実装側の都合で黙って狭めると、書かれたとおりに未充足と判定される

## 概要

受入条件の本文が範囲を限定していないのに、実装が helper の制約を理由に一部を範囲外とすると、acceptance レビューは条件を書かれたとおりに読んで未充足とする。範囲を絞るなら条件を先に改訂し、絞らないなら helper を直す。

## 詳細

観測例では、条件の文面は「base 側の変更ファイル」と範囲を限定していなかったが、実装は消えたパスに hash を取れないという helper の制約を理由に、削除と改名を範囲外とした。条件の本文は変えなかったので、acceptance レビューは書かれたとおりに判定し、未充足とした。

**選択肢は 2 つだけ**: 範囲を絞るなら条件の本文を先に改訂して合意を取る。絞らないなら helper を直す。helper を直せば満たせる場合は、範囲を絞らずに helper 側を直す方が早く収束した。

**手順を要約した別ファイルの追従**: 手順を要約している別のファイル（括弧書きの説明や案内文）は、手順書の工程の追加に追従し忘れやすい。同じ節内で、再試行の案内が新しく追加した専用ブロックではなく旧来の汎用手順を指したまま残る例もある。範囲や工程を変えたら、要約側と再試行の案内の行き先を同時に確かめる。

## 関連ページ

- [Sub-Issue series で AC 緩和が発生したら設計 doc 側にも back-propagation する](./design-doc-ac-back-propagation.md)
- [作業ツリーの内容 hash を証跡にするなら、削除されたパスを表す値を持たせる](./evidence-hash-needs-deleted-path-representation.md)

## ソース

- [範囲を狭めた実装が未充足と判定されたレビュー結果](../../raw/reviews/20261001T005011Z-pr-3571.md)
- [helper 側を直して範囲を保った修正結果](../../raw/fixes/20261001T010038Z-pr-3571.md)
