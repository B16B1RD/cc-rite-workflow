---
type: "heuristics"
title: "exit 0 で終わる hook の stderr はモデルに届かない — 行動を促す失敗通知は stdout にも出す"
domain: "heuristics"
description: "SessionStart のように exit 0 で終わる hook では、stderr はデバッグログにしか残らず、モデルやユーザーに届くのは stdout だけである。state の再有効化の失敗のように、読んだ側に次の行動（recover の実行など）を促したい通知は、stdout にも 1 行出し、テストで固定する。"
promote: rite-plugin
created: "2026-09-28T12:36:22Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T12:36:22Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260928T112849Z-pr-3397.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T111422Z-pr-3397.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T114443Z-pr-3397.md"
tags: []
confidence: high
---

# exit 0 で終わる hook の stderr はモデルに届かない — 行動を促す失敗通知は stdout にも出す

## 概要

SessionStart のように exit 0 で終わる hook では、stderr はデバッグログにしか残らず、モデルやユーザーに届くのは stdout だけである。state の再有効化の失敗のように、読んだ側に次の行動（recover の実行など）を促したい通知は、stdout にも 1 行出し、テストで固定する。

## 詳細

**stderr だけの WARNING は失敗を隠す**: hook が失敗を stderr に書いても、exit 0 で終われば会話には何も残らない。resume 時の state の再有効化に失敗した経路が WARNING を stderr にしか出していなかったため、モデルは失敗を知らないまま続行した。失敗分岐に stdout の 1 行（対象の state のパスと `/rite:recover` の案内）を足して解消した。

**通知の要否は「誰が次に動くか」で決める**: 診断のための詳細は stderr でよい。読んだ側が行動を変える必要がある通知だけを stdout にも出す。

**受入条件の「一致」は対象を列挙する**: resume 後の入口（batch-run の再開段階、pr-review の E2E 判定、Stop の watchdog）の判定を揃えるとき、稼働中の失敗処理と再起動時の再開は別の契約なので、同じ phase でも続行先が違ってよい。受入条件に「一致」と書くときは対象の phase を列挙し、この種の意図的な差を外しておく。

**受入条件を途中で改訂したら受入条件確認だけ再実行する**: 改訂で増えた要求（stdout への通知）は、受入条件確認の reviewer を改訂後の本文で再実行すれば同じ cycle で blocking として拾える。

## 関連ページ

- [新規 lint helper は findings→stdout / summary→stderr(log()) の出力チャネル規約を兄弟 helper に揃える](../patterns/lint-helper-output-channel-convention.md)

## ソース

- [fix 結果](../../raw/fixes/20260928T112849Z-pr-3397.md)
- [レビュー結果](../../raw/reviews/20260928T111422Z-pr-3397.md)
- [レビュー結果](../../raw/reviews/20260928T114443Z-pr-3397.md)
