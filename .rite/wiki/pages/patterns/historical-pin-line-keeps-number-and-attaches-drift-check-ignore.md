---
type: "patterns"
title: "テストの歴史的ピン行は番号を残し行末へ drift-check-ignore を付ける"
domain: "patterns"
description: "番号参照検査はテスト内の歴史的番号ピンも検出する。ピン契約は文字列の完全一致なので番号を消すと検査は通るがピンが壊れる。行末コメントとして drift-check-ignore を付け、照合対象の文字列値は変えない。"
created: "2026-09-15T10:36:56Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-15T10:36:56Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260915T100345Z-pr-2855.md"
  - type: "fixes"
    resource: "raw/fixes/20260915T101257Z-pr-2855.md"
tags: ["testing", "number-reference", "drift-check-ignore", "historical-pin"]
confidence: high
promote: rite-plugin
---

# テストの歴史的ピン行は番号を残し行末へ drift-check-ignore を付ける

## 概要

番号参照検査はテスト内の歴史的番号ピンも検出する。ピン契約は文字列の完全一致なので番号を消すと検査は通るがピンが壊れる。行末コメントとして drift-check-ignore を付け、照合対象の文字列値は変えない。

## 詳細

テストが旧行の本文を完全一致で固定しているとき、その本文に番号トークンが残る。番号参照検査はキーワードの有無を問わず 3-4 桁の番号を拾うため、ピン行もヒットする。隣接する grep 用の行だけに opt-out があっても、代入行そのものに無ければ検査は落ちる。

誤った直し方は番号を本文から消すことである。検査は通るが、完全一致の期待値が変わるのでピン契約が壊れる。出典は「番号削除はピン契約を壊す」と述べている。

正しい直し方は次の 3 点である。

- ピン本文（番号を含む文字列値）は維持する
- 行末へ `# drift-check-ignore` を付ける。コメントは文字列値の外に置き、照合期待値は変えない
- 同じピン文字列を持つ隣接行に既に ignore があるかは伝播確認の材料であり、代入行側の欠落を vis-a-vis で埋める理由にはならない。欠落している行へ付ける

番号参照検査は「番号がある」ことだけを見る。opt-out を付けてもピン文字列を消しても検査は通る。どちらで通ったかは検査では区別できない。ピン契約を守るのは呼び出し側の判断であり、検出器の通過を完成条件にしてはならない。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [operational-bash-heaviness の exempt / pipe-refactor レビューは claim を信用せず empirical 検証で gate する](../heuristics/bash-heaviness-exempt-refactor-review-verification.md)

## ソース

- [レビュー結果](../../raw/reviews/20260915T100345Z-pr-2855.md)
- [fix 結果](../../raw/fixes/20260915T101257Z-pr-2855.md)
