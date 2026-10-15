---
type: "heuristics"
title: "fork を再試行中のサブシェルは SIGTERM で止まらないので、fork 失敗の probe は timeout -s KILL で打ち切る"
domain: "heuristics"
description: "ulimit -u で fork 失敗を誘発するサブシェルは、bash が fork を再試行している間 timeout 既定の SIGTERM では止まらず孤児として残り、コマンド置換を十数秒待たせる。打ち切りは SIGKILL を直接送る timeout -s KILL で行い、-k は監視対象が先に終わると KILL が送られないため頼らない。"
created: "2026-10-15T08:18:52Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-15T08:18:52Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261015T074827Z-pr-3907.md"
  - type: "fixes"
    resource: "raw/fixes/20261015T075316Z-pr-3907.md"
tags: []
confidence: high
---

# fork を再試行中のサブシェルは SIGTERM で止まらないので、fork 失敗の probe は timeout -s KILL で打ち切る

## 概要

ulimit -u で fork 失敗を誘発するサブシェルは、bash が fork を再試行している間 timeout 既定の SIGTERM では止まらず孤児として残り、コマンド置換を十数秒待たせる。打ち切りは SIGKILL を直接送る timeout -s KILL で行い、-k は監視対象が先に終わると KILL が送られないため頼らない。

## 詳細

テストで「fork の失敗が出力に現れること」を確かめる対照として、`( ulimit -u 1; /bin/true; /bin/true )` のようにプロセス数上限 1 のサブシェルを走らせると、bash は fork に失敗しても間隔を空けて再試行を続ける。この間に timeout が既定の SIGTERM を送っても再試行中のサブシェルは終わらず、親から切り離された孤児が `$(...)` のパイプを握ったまま残る。コマンド置換はパイプが閉じるまで戻らないため、3 秒で打ち切ったつもりの対照が実測で約 15 秒かかった。

`timeout -s KILL 3` にすると SIGKILL は捕捉できないので、3 秒で終わり孤児も残らない（実測で孤児 0 件）。`timeout -k` は「SIGTERM の後に監視対象がまだ生きていれば KILL を送る」仕組みで、監視対象（外側の bash）が先に終わると KILL が送られず、孫の孤児はそのまま残る。

判定側に影響しない打ち切り方の変更なので、修正は timeout の引数差し替えと理由のコメントだけで済む。fork 失敗の検出を英語のエラー文言で行う場合は、ロケールを `LC_ALL=C` に固定しないと翻訳された文言で一致しなくなる点も併せて確認する。

## 関連ページ

- [Race window probe の identification power: outcome classification で test の真正性を担保する](../patterns/race-window-probe-identification-power.md)
- [GNU ツールの代替 shim は exit code だけでなく期限・シグナル範囲まで契約を全部再現する](../patterns/gnu-tool-shim-full-contract-reproduction.md)

## ソース

- [レビュー結果](../../raw/reviews/20261015T074827Z-pr-3907.md)
- [fix 結果](../../raw/fixes/20261015T075316Z-pr-3907.md)
