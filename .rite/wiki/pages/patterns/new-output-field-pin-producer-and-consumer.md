---
type: "patterns"
title: "新設した出力フィールドは producer と consumer の両側を pin する — consumer が表なら行単位で pin する"
domain: "patterns"
description: "producer 側の emit だけを assert しても「値が出ること」しか保証されず、「値が使われること」は保証されない。消費側の条件が消えても全 assertion が緑を通り、フィールドが誰にも読まれなくなる変更を検出できない。消費者が分岐表なら「表が存在する」ではなく「各行が存在する」を測る — 自分が新設した行ほど、既存行のパターンに巻き込まれて検査済みに見える。PR #2070 cycle 3-4 で 2 サイクル連続で発覚。"
created: "2026-08-02T09:53:11+09:00"
updated: "2026-08-02T09:53:11+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260801T202243Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T211356Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T223635Z-pr-2070.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T224211Z-pr-2070.md"
tags: ["producer-consumer", "static-pin", "branch-table", "test-strength"]
confidence: high
---

# 新設した出力フィールドは producer と consumer の両側を pin する — consumer が表なら行単位で pin する

## 概要

stdout フィールド・sentinel・marker など「出力の契約」を新設したとき、producer 側の emit だけを assert するテストは **「値が出ること」しか保証せず、「値が使われること」は保証しない**。消費者側からその値を読む条件が消えても全 assertion が緑を通るため、フィールドが誰にも読まれなくなる変更を検出できない。

さらに消費者が **分岐表**（marker → 表示文言のマッピング表など）である場合、「表が存在する」ことを測るだけでは足りない。**各行が存在する**ことを測る。自分が新設した行ほど、既存行のパターンに巻き込まれて「検査済み」に見える。

## 詳細

**PR #2070 cycle 3 で発覚した producer 片側 pin**

新しい stdout フィールドについて producer 側の emit だけを assert し、その値を読む唯一の消費者（完了レポートの note 展開表）は無防備だった。展開表から当該条件が消えても全 assertion が緑を通る = フィールドが誰にも読まれなくなる変更を検出できない。同じファイルは**別の箇所では consumer を静的 pin する慣行を既に確立していた**のに、新フィールドにだけ適用されていなかった。

**PR #2070 cycle 4 で発覚した「表の 1 行だけ pin」**

cycle 3 の指摘に対応して「note 展開表が新フィールドを条件に含むこと」を assert したが、pin したのは **4 行中 1 行だけ**だった。同じ PR が新設したもう 1 行（両欠損の共起ケース）は条件も本文も無検査で、削除しても全緑を通る。しかも本文 assert は 2 行にマッチするため、行を特定していなかった。

**チェックリスト**

新しい出力フィールドを足すとき、以下を対で置く。

| pin する対象 | 測る内容 | 欠けると何が通るか |
|-------------|---------|------------------|
| producer | 当該フィールドが emit される | （これだけだと）消費者側の削除 |
| consumer | 当該フィールドを条件に含む分岐が存在する | フィールドが誰にも読まれなくなる変更 |
| consumer が表なら各行 | 各行の条件と本文が個別に存在する | 新設行の削除（既存行のパターンに吸収される） |

**行を特定する assert の書き方**

本文 assert が複数行にマッチするなら、その assert は行を特定していない。条件文字列と本文文字列を同一行で結ぶ形（1 行全体を literal で pin する / 条件と本文を含む単一行の regex にする）にして、対象行を一意に絞る。

**唯一の確認法は変異**

「新設行を消す変異を作って落ちるか」を確かめる以外に、行単位 pin が効いていることを確認する方法はない（[[mutation-testing-measures-assertion-strength]]）。目視レビューでは、既存行のパターンにマッチしているだけの assert と、新設行を特定している assert を区別できない。

**探し方: 「宣言」の側から探す**

PR #2070 cycle 3 の blocking 5 件中 3 件は「コメントや手順書が『こう振る舞う』と宣言しているのに、それを固定する assertion が無い」形だった（マスクは削除ではなく置換 / 除外の判定単位は行ではなくサマリー / 新フィールドに消費者がいる）。いずれも既存の別経路には対称の pin が存在した。**コード中の「〜すること」「〜と同一にする」という宣言を grep して、その宣言を破る変異が kill されるかを確かめる**方向が効率的である。

## 関連ページ

- [静的 parity テストには到達性 pin と emit pin を対で足す — 出現数 + 行順だけでは semantics を守れない](./static-parity-pin-needs-reachability-and-emit-pins.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [実装が分岐しているならテストも分岐の数だけ要る — 既定構成の経路こそ抜けやすい](../heuristics/implementation-branch-count-equals-test-branch-count.md)

## ソース

- [PR #2070 review results (cycle 3)](../../raw/reviews/20260801T202243Z-pr-2070.md)
- [PR #2070 fix results (cycle 3)](../../raw/fixes/20260801T211356Z-pr-2070.md)
- [PR #2070 review results (cycle 4)](../../raw/reviews/20260801T223635Z-pr-2070.md)
- [PR #2070 fix results (cycle 4)](../../raw/fixes/20260801T224211Z-pr-2070.md)
