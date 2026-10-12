---
type: "heuristics"
title: "受入条件が PR 本文を対象にするときは、本文の更新だけでは再レビューされない — 対応するファイルの修正と合わせて commit する"
domain: "heuristics"
description: "受入条件が PR 本文の表を対象にしていると、本文だけを直しても HEAD が変わらず、差分スコープの再レビューでは確認されない。対応するファイルの修正と同じ commit で直し、本文の状態は検証コマンドで固定する。表の突き合わせは項目の名前の集合ではなく行単位で行う。"
created: "2026-09-30T09:18:44Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-30T09:18:44Z" }
promote: rite-plugin
sources:
  - type: "reviews"
    resource: "raw/reviews/20260930T084327Z-pr-3516.md"
  - type: "fixes"
    resource: "raw/fixes/20260930T085259Z-pr-3516.md"
tags: ["review-loop", "acceptance-criteria", "pr-body", "inventory"]
confidence: medium
---

# 受入条件が PR 本文を対象にするときは、本文の更新だけでは再レビューされない — 対応するファイルの修正と合わせて commit する

## 概要

受入条件が PR 本文の表を対象にしている場合、表の突き合わせは項目の名前の集合ではなく行単位で行う。（「本文だけを直すと HEAD が変わらず再レビューで確認されない」は現行仕様では廃止: 本 cycle の PR 本文の修正だけでも fix は review へ再突入する。）

## 詳細

### 起きること

受入条件の 1 つが「PR 本文の棚卸し表が、全スキルの確認箇所を漏れなく載せている」だった。受入条件の確認で、表に 2 行の漏れが見つかった。スキルの名前の単位では全スキルが表に載っていたが、1 つのスキルの中に確認箇所が複数あり、その一部の行が無かった。

（現行仕様では廃止: 本 cycle の PR 本文の修正も fix の再突入条件に含まれるため、本文だけの修正が確認されずに残ることはない。）

### やること

- （現行仕様では廃止: PR 本文の修正を対応ファイルの commit に合わせる運用や、検証コマンドで本文を固定する運用は不要。本文の修正だけでも review へ再突入する）
- 棚卸しの突き合わせは行単位で行う。「スキルの名前がすべて載っている」ではなく「確認箇所の行がすべて載っている」を確かめる。箇条書きの中にある確認箇所も 1 行ずつ拾う
- 見出しや固定の文言を書き換えたら、旧文言を grep して、その文言を例として引用している別の文書を洗う

## 関連ページ

- [「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](./exhaustiveness-claims-require-mechanical-inventory.md)
- [CI が pending のまま閉じたレビューは失敗 job を観測できない — 完了後に担当 reviewer を CI 状態付きで reroll する](./ci-pending-at-review-close-reroll-finder-after-completion.md)

## ソース

- [棚卸し表の行の漏れを受入条件の確認で見つけたレビュー結果](../../raw/reviews/20260930T084327Z-pr-3516.md)
- [本文の修正をファイルの修正と合わせて commit した fix 結果](../../raw/fixes/20260930T085259Z-pr-3516.md)
