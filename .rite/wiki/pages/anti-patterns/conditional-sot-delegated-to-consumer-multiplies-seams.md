---
type: "anti-patterns"
title: "SoT を consumer 依存の条件付きにすると seam が増え、指摘数が反転する"
domain: "anti-patterns"
description: "共有 SoT（reference）と複数 consumer を持つ構成で、個別指摘へ局所修正を重ねると、SoT 側に条件付き分岐が積み上がる。"
created: "2026-07-30T15:40:55Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260730T061343Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T061745Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T063315Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T063609Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T093514Z-pr-2056.md"
tags: ["sot", "consumer", "seam", "shared-reference", "convergence"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-30T15:40:55Z" }
---

# SoT を consumer 依存の条件付きにすると seam が増え、指摘数が反転する

## 概要

共有 SoT（reference）と複数 consumer を持つ構成で、個別指摘へ局所修正を重ねると、SoT 側に条件付き分岐が積み上がる。「上限は consumer が既に使う質問数を差し引いた残枠」「溢れの扱いは consumer 側の規定に従う」のような**条件付き SoT** は、各 consumer 側に対応規定を書く義務を生み、書き漏れが次の指摘になる。

実測では、この積み上げによって cycle 4 の 7 指摘のうち 3 件が cycle 3 の修正が生んだ seam になり、**指摘数が 4 → 7 と反転**した。

## 詳細

### 対策: SoT は単一 default を持つ

**SoT は単一の default を持ち、consumer 固有の事情は consumer 側の設計を変えて吸収する。** 本事例では consumer 側を「専用の確認を発行する」形に揃えることで、SoT の条件分岐を丸ごと撤去できた。

### 転写ではなくポインタで共有する

同じ規則を両 consumer に書くと片方への転写漏れが起きる。SoT に単一定義を置き、consumer からは 1 行のポインタで指す。

**要約は必ず lossy になる。** SoT のエラー処理表が 2 つの signal で分岐しているのを consumer 側で「A → CONTRADICTED, otherwise UNVERIFIED」と要約したところ、もう一方の signal による失敗が逆判定へ落ちた。**consumer にはポインタだけを置き、条件は書かない。** 列挙形式の要約は完全であるかのように読まれるため、要約に載らない規則は consumer 側で落ちる。

### 「複製しない」と宣言した節を grep で検算する

「エラー処理は reference にのみ存在し本体には複製しない」と宣言した同じ節の表に、エラー処理の行が残っていた。宣言と実体の乖離は、**宣言を信じた読み手が reference を見に行かない**経路を作る。宣言したら宣言どおりに削り、`grep` で 0 件を確認する。

判定が一致している間は実害が出ないため気付かれにくく、片側だけを編集した次の変更で silent に二重化する。**単一定義を宣言したら、宣言文と実体を同じ cycle で grep 照合する。**

### SoT を直したら転記先を全部 grep する

SoT に判別子を足した cycle で、同じ規則を転記していた consumer 2 箇所のうち 1 箇所しか同期していなかった。**SoT 変更は「SoT を引用・要約している全箇所」の同期とセットで 1 commit にする。**

削除も同様で、SoT から default rule を削除した同じ commit で consumer 側にその default rule を根拠として引く文を追加していた事例がある。

### 単一定義へ畳む修正は旧記述の除去まで 1 セット

規則を SoT 節へ集約した際、旧記述を残すと「本節が唯一の定義」という宣言自体が偽になる。集約時は (1) SoT へ規則を置く (2) 旧記述を参照へ置換 (3) grep で規則が 1 箇所であることを確認、まで実行する。

規定の追加先は SoT 節を選び、**表の行へ複製しない**。行へ複製すると、後から同じ判定を出す行が増えたときに転記漏れが起きる。

### 共有 SoT を新設するときは「全 consumer に効く規則」を節として切り出す

新設した共有 reference に「検査ロジック」は集約できても、再入時ガードや注記の扱いといった**運用ルール**を consumer 側に置くと、もう一方の consumer が継承できない乖離が生じる。仕様が MUST で「同一 reference を参照し複製しない」と定めていても、**reference に書かれていない規則は構造的に共有されない**。

## 関連ページ

- [SoT の引用が強度修飾子を落とす](./sot-quote-drops-strength-qualifier.md)
- [転写時にスコープ量化子が膨張する](./transcription-scope-quantifier-inflation.md)
- [同期先を減らしてから同期する](../heuristics/reduce-sync-sites-before-syncing-them.md)

## ソース

- [SoT を consumer 依存にすると seam が増える](../../raw/reviews/20260730T061343Z-pr-2056.md)
- [単一 default への回帰](../../raw/fixes/20260730T061745Z-pr-2056.md)
- [転記先の同期漏れ](../../raw/reviews/20260730T063315Z-pr-2056.md)
- [要約は必ず lossy](../../raw/fixes/20260730T063609Z-pr-2056.md)
- [共有 SoT の責務分割ミス](../../raw/reviews/20260730T093514Z-pr-2056.md)
