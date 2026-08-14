---
type: "heuristics"
title: "cycle が進んでも findings が減らないときは点修正をやめて構造を疑う"
domain: "heuristics"
promote: rite-plugin
description: "review⇄fix ループの健全な収束は「cycle ごとに指摘が減る」形で現れる。"
created: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260728T093135Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T014137Z-pr-2052.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T014656Z-pr-2052.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T061343Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T061745Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T100957Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T122258Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T111445Z-pr-2038-cycle2.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T105333Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T112831Z-pr-2038-cycle2.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T141004Z-pr-2038-cycle4.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T161841Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T170839Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T173829Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T183304Z-pr-2038-cycle4.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T190535Z-pr-2038-cycle5.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T232110Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T235835Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T003318Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T011259Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T014820Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T050903Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T055910Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T070208Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T082625Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T090203Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T103843Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T114912Z-pr-2038-cycle3.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T135506Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T152447Z-pr-2038-cycle5.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T160528Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T165144Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T230726Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T234533Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T002344Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T005839Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T013838Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T020813Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T050108Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T054003Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T064417Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260728T081222Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T030207Z-pr-2094.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T020301Z-pr-2094.md"
  - type: "fixes"
    resource: "raw/fixes/20260803T002010Z-pr-2094.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-03T07:46:56Z" }
---

# cycle が進んでも findings が減らないときは点修正をやめて構造を疑う

## 概要

review⇄fix ループの健全な収束は「cycle ごとに指摘が減る」形で現れる。減らないとき、多くの場合は**個々の指摘に個別対応している**ことが原因で、指摘されなかった箇所が次 cycle の指摘として戻ってくる。

判定材料は件数ではなく**内訳**である。毎 cycle の指摘を分類し、「前 cycle の修正が生んだ新しい drift」が支配的なら、点修正を続けても収束しない。

## 詳細

### 実測（11 cycle・通算 65 件）

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

## 詳細（追記: 後続 2 PR の実測）

**停止条件は結果を見る前に宣言する。** 「fix-introduced が過半かつ同一機構に集中したら巻き戻す」を cycle 2 の完了時点で宣言しておくと、cycle 3 で該当したときに作り込みを続ける誘惑を機械的に断てる。fix-introduced 指摘の**比率と集中箇所を cycle ごとに数える**のが判断材料になる（実測: cycle 2 の 7 件中 6 件、cycle 3 の 6 件中 4 件が直前の修正由来で、3 レビュアーが独立に「過剰設計」と判断し同一の最小解に収束した）。

**指摘数が反転したら個別パッチをやめる。** 局所修正を重ねると共有 SoT に条件付き分岐が積み上がり、cycle 4 では 7 指摘のうち 3 件が前 cycle の修正が生んだ seam になって指摘数が 4 → 7 と反転した。

**1 つの構造変更が複数の指摘を同時に解くなら、それが正しい修正。** 既存確認への畳み込みをやめて独立確認にしただけで、予算・溢れ規則・不変条件・選択肢集合の 4 指摘が同時に消えた。個別に 4 箇所直すと、それぞれが新しい seam になる。

**簡素化の成否は行数で確認できる。** 該当 cycle の修正は +17 / -21 行で正味 4 行の削減だった。**指摘に応じた修正が毎回増分になっているなら、それはパッチであって設計の修正ではない。**

**上限に達する前でも、前提が崩れたらループを止めて人間に返す。** 機械的な停止条件（cycle 上限）と、判断による停止（前提崩壊・スコープ判断・承認待ち）は別物であり、後者は上限とは独立に発火させる。

## ソース（追記分 4）

- [PR #2052 review results (cycle 3) — 3 レビュアーが独立に過剰設計と判断](../../raw/reviews/20260730T014137Z-pr-2052.md)
- [PR #2052 fix results (cycle 3) — 停止条件の事前宣言が効いた](../../raw/fixes/20260730T014656Z-pr-2052.md)
- [PR #2056 review results (cycle 4) — 指摘数が 4 → 7 へ反転](../../raw/reviews/20260730T061343Z-pr-2056.md)
- [PR #2056 fix results (cycle 4) — 1 構造変更で 4 指摘が同時消滅、正味 4 行減](../../raw/fixes/20260730T061745Z-pr-2056.md)

## 詳細（追記: 主題の収束と churn の区別）

**指摘が減らないことと、主題が収束していないことは別物である。** PR #2094 は 5 cycle 回っても収束しなかったが、内訳を分けると評価が反転する。

| 層 | cycle 3 | cycle 4 | cycle 5 |
|---|---|---|---|
| PR の主題（実装の振る舞い） | 0 件 | 0 件 | 0 件 |
| fix ループ自身が持ち込んだ散文・診断・テストラベル | 6 件 | 5 件（**全件**） | 6 件 |

cycle 4 では **blocking 5 件すべてが前 cycle の fix 由来**で、指摘の生成源が完全に反転していた。同じ cycle で error-handling が疑い所 6 点を全て潰し、security が injection 8+ ベクタで bypass なしを確認し、prompt-engineer は自らの昇格根拠を反証して撤回している。

**修正ループが自分で指摘を作り始めたら、それは主題の収束を意味する。** 残っているのはコードの振る舞いではなく churn であり、**この区別を報告で潰さないこと**。「5 cycle 未収束」とだけ書くと、実装に問題が残っているように読める。

### 収束局面での立ち回り

- **推奨事項を意図的に見送る。** 残りサイクル数が少ない局面では、編集中の行に推奨事項を重ねると新たなレビュー面を作る。見送りを commit message に明記して次サイクルへ送る。
- **件数ではなくコードの是非で選ぶ。** 「この診断追加を revert すれば 2 件消える」という選択肢が出ることがあるが、その診断が他 Issue の値転写を示す唯一の信号なら、撤去は中立ではなく悪化になる。
- **severity 分布の下方シフトを見る。** 実装の欠陥が尽きたかどうかは件数ではなく分布に出る（HIGH が残っていてもその中身がコメントの行番号参照なら、実装は収束している）。
- **レビュー側の取り下げも収束の兆候。** reviewer が前 cycle の推奨を「既存アサーションで解決済み」として明示的に取り下げ始めたら、両側が収束に向かっている。

### 計測の記述も同 cycle で更新する

修正がレビュー計測そのものを変える場合、PR 本文の実測値も同一 cycle で更新する。実例ではテストスイートの自己切断を直した結果、PR 本文が主張していた「develop baseline の Red は 9 件」が偽になった（中断が消えて全アサーションが走り 18 件に増えた）。放置すると、**その PR が別途 stale ドキュメントとして是正した当の問題を、PR 本文自身が再生産する**。

Red baseline の測り方（どのファイルを revert したか）を本文に明記しておくと、次のレビュアーが別の測り方をして phantom discrepancy を報告するのも防げる。

## ソース（追記分 5）

- [PR #2094 review results (cycle 5, non-converged) — 主題は 3 cycle 連続ゼロ、非収束の原因は fix ループ自身の churn](../../raw/reviews/20260803T030207Z-pr-2094.md)
- [PR #2094 review results (cycle 4) — blocking 5 件すべてが前 cycle の fix 由来](../../raw/reviews/20260803T020301Z-pr-2094.md)
- [PR #2094 fix results — レビューサイクルが進むと PR 本文が実体から乖離する](../../raw/fixes/20260803T002010Z-pr-2094.md)
