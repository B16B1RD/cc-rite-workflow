---
type: "heuristics"
title: "複数の書き込み口がある資源は、最後の共有口に政策検査を置く"
domain: "heuristics"
description: "同じ資源へ commit する経路が複数あるとき、政策検査を 1 呼び出し口だけに置くと、別経路が拒否済みの pending を無検査で着地させる。検査本体は最後の共有書き込み口に置き、呼び出し口は薄い呼び出しに縮小する。"
created: "2026-09-06T08:10:46Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-06T08:10:46Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T075557Z-pr-2580.md"
tags: [wiki, gate, write-path, last-mouth]
confidence: high
promote: rite-plugin
---

# 複数の書き込み口がある資源は、最後の共有口に政策検査を置く

## 概要

同じ資源へ commit する経路が複数あるとき、政策検査を 1 呼び出し口だけに置くと、別経路が拒否済みの pending を無検査で着地させる。検査本体は最後の共有書き込み口に置き、呼び出し口は薄い呼び出しに縮小する。

## 詳細

Wiki のように ingest と lint が同じ commit helper を呼ぶ構成では、番号参照の検査を ingest 側だけに置くと、hit で止まった pending を lint が無差別 stage して通してしまう。検査を最後の共有口（commit helper）へ移せば、呼び出し口が増えても同じゲートを通る。

呼び出し口に残すのは helper 呼び出しと、hit を書き換えループへ倒す rc 捕捉だけにする。新しい exit code を増やさず、既存の政策拒否（rc=1）に乗せる。skip は書き込みが起きない経路（push-only / dry-run / no-pending）に限る。

呼び出し口ごとに検査を複製すると、片方だけ直して drift する。最後の口に置けば複製も抜けも起きない。

## 関連ページ

- [ゲートに検査を足すより、実行者が選べる自由度を削る](./reduce-gate-degrees-of-freedom.md)
- [兄弟 shell script の重複 helper は shared lib 抽出で解く](./shell-script-shared-lib-extraction.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T075557Z-pr-2580.md)
