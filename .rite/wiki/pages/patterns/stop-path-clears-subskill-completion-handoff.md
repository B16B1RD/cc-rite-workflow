---
type: "patterns"
title: "停止で終える分岐から sub-skill を呼ぶときは、sub-skill が張った完了 handoff を phase を変えずに消してから止まる"
domain: "patterns"
description: "停止で終える分岐の手前に sub-skill を呼ぶ経路を足すと、sub-skill が戻りで張る完了 handoff が残り、Stop hook が停止を完了経路へ差し戻す。停止通知の前に handoff なしの set で消し、その set は phase を現在値のまま書く。"
created: "2026-10-01T16:55:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-01T16:55:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-01T16:55:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20261001T152306Z-pr-3602.md"
  - type: "reviews"
    resource: "raw/reviews/20261001T151452Z-pr-3602.md"
  - type: "fixes"
    resource: "raw/fixes/20261001T154600Z-pr-3602.md"
tags: []
confidence: high
promote: rite-plugin
---

# 停止で終える分岐から sub-skill を呼ぶときは、sub-skill が張った完了 handoff を phase を変えずに消してから止まる

## 概要

停止で終える分岐の手前に sub-skill を呼ぶ経路を足すと、sub-skill が戻りで張る完了 handoff が残り、Stop hook が停止を完了経路へ差し戻す。停止通知の前に handoff なしの set で消し、その set は phase を現在値のまま書く。

## 詳細

**なぜ差し戻されるか**: fix のような sub-skill は、戻るときに「次は完了通知を出せ」という handoff を flow-state に張る。呼び出し元がその後に完了ではなく停止で終えると、Stop hook は残った handoff を見て完了通知が無いことを差し戻す。停止の分岐から sub-skill を呼ぶ経路を新設したときに起き、既存の停止（目的逸脱・受入条件未検証）と同じ問題である。

**消し方は既存の停止と同じ形にする**: 停止通知の前に `--handoff` を付けない `flow-state.sh set` を 1 回実行する。set は handoff を既定で消すので、新しい機構は要らない。既存の停止経路と同じ形を再利用する。

**消すための set は phase を変えない**: 消去だけが目的の set で phase を書き換えると、別の遷移規則に当たる。fix から review へ移す通常 set は拒否され、set は rc=1 で何も書かず、handoff も残る。現在値（fix）のまま書けば遷移規則に当たらない。set が失敗したら、その WARNING / ERROR を停止通知に併記して握りつぶさない。

**検証は実行で行う**: 文言や fenced block の形を固定するテストでは、phase を変えたことによる拒否を検出できない。手順書の set を抜き出し、sandbox で fix が handoff を張った直後と同じ状態を作って実行し、rc=0 と handoff の消滅を assert する。phase を review に戻す変異でテストが落ちることも確かめる。複数のレビュアーが文言の整合を FIXED と判定した後で、実行して観測したレビュアーだけがこの拒否を検出した。

**同じ戻りの処理は 1 か所に書く**: 同じ戻り値への処理（再試行するか、停止するか）を表の行と下の段落の 2 か所に書くと、読み手によって再試行の有無が割れる。表の行は「その他の戻りは同段落の規則に従う」と委ね、規則は 1 か所に置く。再試行した sub-skill の戻りがどの規則に従うかも同じ段落に書く。

**書き込みを「機械的に止まる」と書かない**: linked worktree（detached の実験 worktree を含む）から state root を解決すると、main checkout の state root が返る。レビュアーが実験で helper を動かすと、稼働中の state に書き込みうる。bash の guard は helper 内部の書き込みを見ないので、その書き込みは機械的には止まらない。手順書には「blocked」と書かず、実行前に helper を読んで、state root・GitHub へ書く段は実行しないという判断を求める規則にする。遮断を前提にした旧文言が 0 件であることもテストで固定する。

## 関連ページ

- [手順書の bash 文は期待文字列で固定せず、抽出して実行するテストで固定する](./procedure-bash-extracted-and-executed-by-test.md)
- [Success-only Sentinel Design — sub-skill abort path sentinel 未定義](../anti-patterns/success-only-sentinel-design.md)

## ソース

- [停止前に handoff を消す形を既存の停止と揃えた fix 結果](../../raw/fixes/20261001T152306Z-pr-3602.md)
- [停止経路から sub-skill を呼ぶと完了経路へ差し戻されることを指摘したレビュー結果](../../raw/reviews/20261001T151452Z-pr-3602.md)
- [消去の set で phase を維持し、挙動テストで固定した fix 結果](../../raw/fixes/20261001T154600Z-pr-3602.md)
