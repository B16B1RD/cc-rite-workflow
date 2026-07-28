---
type: "heuristics"
title: "cycle が進んでも findings が減らないときは点修正をやめて構造を疑う"
domain: "heuristics"
description: "review⇄fix ループで cycle ごとの指摘件数が減らず、内訳が毎回「前 cycle の修正が生んだ新しい drift」になっているときは、個々の指摘に個別対応しても収束しない。指摘の内訳を分類し、同じクラスが再発しているなら述語や実装の本数といった構造に手を入れる。PR #2038 は 11 cycle・通算 65 件を要し、cycle 4 で「2 実装を並行して持つ構造」に到達して初めてクラスが閉じた。"
created: "2026-07-28T21:30:00+09:00"
updated: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260728T093135Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T100957Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T122258Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T111445Z-pr-2038-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T105333Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T112831Z-pr-2038-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T141004Z-pr-2038-cycle4.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T161841Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T170839Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T173829Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T183304Z-pr-2038-cycle4.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T190535Z-pr-2038-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T232110Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T235835Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T003318Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T011259Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T014820Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T050903Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T055910Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T070208Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T082625Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T090203Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T103843Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T114912Z-pr-2038-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T135506Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T152447Z-pr-2038-cycle5.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T160528Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T165144Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T230726Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T234533Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T002344Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T005839Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T013838Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T020813Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T050108Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T054003Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T064417Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T081222Z-pr-2038.md"
tags: []
confidence: high
---

# cycle が進んでも findings が減らないときは点修正をやめて構造を疑う

## 概要

review⇄fix ループの健全な収束は「cycle ごとに指摘が減る」形で現れる。減らないとき、多くの場合は**個々の指摘に個別対応している**ことが原因で、指摘されなかった箇所が次 cycle の指摘として戻ってくる。

判定材料は件数ではなく**内訳**である。毎 cycle の指摘を分類し、「前 cycle の修正が生んだ新しい drift」が支配的なら、点修正を続けても収束しない。

## 詳細

### 実測（PR #2038、11 cycle・通算 65 件）

| cycle | 件数 | 内訳 |
|---|---|---|
| 1 | 9 | 設計の穴（pin が件数ベースで配置を拘束しない） |
| 2 | 14 | **cycle 1 の修正が文書・pin・SoT に届いていない伝播漏れ**（全件がこれ） |
| 3 | 13 | **cycle 2 の修正が不完全**（`endswith` が行頭 `> ` を吸収し PATCH 破壊が残存） |
| 4 | 10 | **根本原因を特定** — read/write の 2 実装という構造。述語を 1 本化 |
| 5 | 14 | **1 本化の過程で付けた `2>/dev/null`** が新たな非収束ループを作った |
| 6 | 5 | 新しい実装欠陥ゼロ。残りは cycle 5 の伝播漏れのみ |

cycle 1→3 は同じ症状（read 側と write 側の述語がずれる）を 3 回別々に潰していた。cycle 4 で構造に手を入れてそのクラスは閉じたが、**構造を変える修正それ自体が cycle 5 の CRITICAL を生んだ**。

### 判定の目安

以下が揃ったら構造を疑う。

- 指摘の**内訳**が「前 cycle の修正由来」で支配されている
- 同じ**述語や条件を強化する**修正が 2 cycle 以上続いている
- 修正のたびに「別の抜け道」が見つかる（穴を塞ぐと隣に穴が開く）

### 切り替える手順

1. **症状ではなく実装の本数を数える。** 同じ判定が何箇所に書かれているか。何言語で書かれているか
2. **述語を 1 回だけ変え、そこから全 artifact を横断 sweep する。** 変えた語彙（例:「末尾 anchor」「contains」「3 段」）を grep で全ファイル横断で洗い出し、**一度に**揃える
3. **点修正に戻らない。** 指摘 1 件ずつに対応すると、指摘されなかった箇所が次 cycle に回る

### 構造変更それ自体をレビュー対象にする

cycle 5 の教訓は重い。**構造を変える修正は、次の欠陥の発生源になりうる。**

- 述語を 1 本化する過程で `2>/dev/null` が新規に付き、環境起因の失敗を caller 契約違反へ誤分類した
- ジャーナルコメントを不変条件記述へ機械的に置換した際、接頭辞の差し替えだけで文の主述が壊れ、**棄却された手法を要件として宣言する**文になった

修正の差分は、修正対象と同じ厳しさでレビューする。

### 自動検出できるものは先に潰す

cycle 5 では、指摘 14 件のうち 2 件が**リポジトリ自身の checker が rc=1 で機械検出できる**違反だった（ハードコード行番号 / ジャーナルコメント）。自動検出できる違反を reviewer に探させると 1 cycle 遅れる。**commit 前に repo の checker を全変更ファイルへ回す**だけでこのクラスは構造的に消える。

### サーキットブレーカーとの関係

`safety.max_review_cycles` は非収束を検出する最後の安全網であって、収束させる仕組みではない。上限に到達したら「さらに N cycle 回す」前に、本ページの判定を先に行う。上限到達時点の内訳が「前 cycle 由来」で支配されているなら、cycle を足しても同じ推移を繰り返す。

## 関連ページ

- [同じ述語を 2 言語で並行実装すると受理集合が環境で割れる](../anti-patterns/dual-language-predicate-divergence.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [累積対策 PR の 3 cycle 収束記録](./accumulated-pr-three-cycle-convergence.md)

## ソース

- [PR #2038 fix results (cycle 4)](../../raw/fixes/20260728T093135Z-pr-2038.md)
- [PR #2038 fix results (cycle 5)](../../raw/fixes/20260728T100957Z-pr-2038.md)
- [PR #2038 fix results (cycle 6, final)](../../raw/fixes/20260728T122258Z-pr-2038.md)
- [PR #2038 review results (cycle 2)](../../raw/reviews/20260727T111445Z-pr-2038-cycle2.md)
- [PR #2038 raw — 20260727T105333Z-pr-2038.md](../../raw/fixes/20260727T105333Z-pr-2038.md)
- [PR #2038 raw — 20260727T112831Z-pr-2038-cycle2.md](../../raw/fixes/20260727T112831Z-pr-2038-cycle2.md)
- [PR #2038 raw — 20260727T141004Z-pr-2038-cycle4.md](../../raw/fixes/20260727T141004Z-pr-2038-cycle4.md)
- [PR #2038 raw — 20260727T161841Z-pr-2038.md](../../raw/fixes/20260727T161841Z-pr-2038.md)
- [PR #2038 raw — 20260727T170839Z-pr-2038.md](../../raw/fixes/20260727T170839Z-pr-2038.md)
- [PR #2038 raw — 20260727T173829Z-pr-2038.md](../../raw/fixes/20260727T173829Z-pr-2038.md)
- [PR #2038 raw — 20260727T183304Z-pr-2038-cycle4.md](../../raw/fixes/20260727T183304Z-pr-2038-cycle4.md)
- [PR #2038 raw — 20260727T190535Z-pr-2038-cycle5.md](../../raw/fixes/20260727T190535Z-pr-2038-cycle5.md)
- [PR #2038 raw — 20260727T232110Z-pr-2038.md](../../raw/fixes/20260727T232110Z-pr-2038.md)
- [PR #2038 raw — 20260727T235835Z-pr-2038.md](../../raw/fixes/20260727T235835Z-pr-2038.md)
- [PR #2038 raw — 20260728T003318Z-pr-2038.md](../../raw/fixes/20260728T003318Z-pr-2038.md)
- [PR #2038 raw — 20260728T011259Z-pr-2038.md](../../raw/fixes/20260728T011259Z-pr-2038.md)
- [PR #2038 raw — 20260728T014820Z-pr-2038.md](../../raw/fixes/20260728T014820Z-pr-2038.md)
- [PR #2038 raw — 20260728T050903Z-pr-2038.md](../../raw/fixes/20260728T050903Z-pr-2038.md)
- [PR #2038 raw — 20260728T055910Z-pr-2038.md](../../raw/fixes/20260728T055910Z-pr-2038.md)
- [PR #2038 raw — 20260728T070208Z-pr-2038.md](../../raw/fixes/20260728T070208Z-pr-2038.md)
- [PR #2038 raw — 20260728T082625Z-pr-2038.md](../../raw/fixes/20260728T082625Z-pr-2038.md)
- [PR #2038 raw — 20260728T090203Z-pr-2038.md](../../raw/fixes/20260728T090203Z-pr-2038.md)
- [PR #2038 raw — 20260727T103843Z-pr-2038.md](../../raw/reviews/20260727T103843Z-pr-2038.md)
- [PR #2038 raw — 20260727T114912Z-pr-2038-cycle3.md](../../raw/reviews/20260727T114912Z-pr-2038-cycle3.md)
- [PR #2038 raw — 20260727T135506Z-pr-2038.md](../../raw/reviews/20260727T135506Z-pr-2038.md)
- [PR #2038 raw — 20260727T152447Z-pr-2038-cycle5.md](../../raw/reviews/20260727T152447Z-pr-2038-cycle5.md)
- [PR #2038 raw — 20260727T160528Z-pr-2038.md](../../raw/reviews/20260727T160528Z-pr-2038.md)
- [PR #2038 raw — 20260727T165144Z-pr-2038.md](../../raw/reviews/20260727T165144Z-pr-2038.md)
- [PR #2038 raw — 20260727T230726Z-pr-2038.md](../../raw/reviews/20260727T230726Z-pr-2038.md)
- [PR #2038 raw — 20260727T234533Z-pr-2038.md](../../raw/reviews/20260727T234533Z-pr-2038.md)
- [PR #2038 raw — 20260728T002344Z-pr-2038.md](../../raw/reviews/20260728T002344Z-pr-2038.md)
- [PR #2038 raw — 20260728T005839Z-pr-2038.md](../../raw/reviews/20260728T005839Z-pr-2038.md)
- [PR #2038 raw — 20260728T013838Z-pr-2038.md](../../raw/reviews/20260728T013838Z-pr-2038.md)
- [PR #2038 raw — 20260728T020813Z-pr-2038.md](../../raw/reviews/20260728T020813Z-pr-2038.md)
- [PR #2038 raw — 20260728T050108Z-pr-2038.md](../../raw/reviews/20260728T050108Z-pr-2038.md)
- [PR #2038 raw — 20260728T054003Z-pr-2038.md](../../raw/reviews/20260728T054003Z-pr-2038.md)
- [PR #2038 raw — 20260728T064417Z-pr-2038.md](../../raw/reviews/20260728T064417Z-pr-2038.md)
- [PR #2038 raw — 20260728T081222Z-pr-2038.md](../../raw/reviews/20260728T081222Z-pr-2038.md)
