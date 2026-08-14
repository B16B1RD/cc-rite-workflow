---
type: "heuristics"
title: "fail-loud ガードは同じ帰結を持つ全出口に張る（症状側から出口を網羅する）"
domain: "heuristics"
description: "silent データ損失（空文字が返る等）に fail-loud ガードを追加するとき、**指摘された 1 出口だけを塞ぐと、同じ帰結に至る兄弟出口が残って次サイクルで同型指摘として返ってくる**。"
created: "2026-08-05T09:26:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260804T155148Z-pr-2111-cycle5.md"
  - type: "fixes"
    resource: "raw/fixes/20260804T155921Z-pr-2111-cycle5.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T110153Z-pr-2114.md"
tags: ["fail-loud", "guard", "exit-exhaustive", "sibling-exit", "trap", "boundary-tc", "static-pin"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T00:40:00+09:00" }
---

# fail-loud ガードは同じ帰結を持つ全出口に張る（症状側から出口を網羅する）

## 概要

silent データ損失（空文字が返る等）に fail-loud ガードを追加するとき、**指摘された 1 出口だけを塞ぐと、同じ帰結に至る兄弟出口が残って次サイクルで同型指摘として返ってくる**。ガードを追加する前に「この関数が異常値を返す経路は他に何本あるか」を症状側から遡って出口を列挙し、まとめて塞ぐ。

## 詳細

### 失敗の構造

wiki-index-update helper（PR #2111）の cycle 4 で「行末区切り欠落 = 捨てフラグメント非空」の 1 出口に exit 1 ガードを入れたが、cycle 5 のレビューで**同じ帰結（空文字が返る）に至る兄弟出口が 2 本**（セル数不足での早期 return とループ 0 回転）残っていることを 4 レビュアーが独立に指摘した。新ガード追加のたびに「同じ帰結の兄弟経路」が指摘される形で blocking 件数が下げ止まっていた。

### Canonical fix

1. **症状（異常値が返る）側から関数の全 return 経路を列挙する** — 原因側（この入力が壊れている）からではなく、帰結側から遡ると出口が漏れなく列挙できる
2. 兄弟出口を**1 本のガード**（セル数ガード）に畳む — 出口ごとに個別ガードを増やすより保守面が小さい
3. **ガードの下限を境界 TC で pin する** — 正当な空セル 5 列行が rc=0 で通ることを固定し、過剰発火側（正当値の棄却）への倒れも同時に防ぐ

### 付随した教訓（同 cycle で確定した同種の「全経路」規律）

- **安全網の主張は不成立経路を先に探す**: 「失敗しても後段の lint が拾う」という記述は新規追加経路でしか成立せず、更新経路では登録行が旧値のまま残ってもどの lint 観点にも載らないことが実測で判明した。安全網を文書に書くときは、その安全網が発火しない経路を先に探し、不成立側では「表示した ERROR が唯一のシグナル」と明記する
- **trap は canonical 4 行形 + mktemp 前武装**: exit code を契約にする helper で EXIT 単独 trap を mktemp 後に武装すると、SIGINT のタイミング次第で exit 0（成功 marker なし・仕事もしていない）の silent no-op になる（実測 12 回中 6 回）。宣言 → cleanup 関数 → 4 行 trap → mktemp の順序を守る
- **docstring の不変条件 1 つに TC 1 本**: 文書化した性質（FIRST link 同定・回収は毎回走る）は、その性質を壊す変異が現行スイート green のままなら未 pin。狙い撃ち TC を足してから変異で殺せることを確認する

### 拡張 (PR #2114): 静的 pin にも同じ「兄弟を数える」規律が要る

同じ規律は fail-loud ガードだけでなく **pin / assertion** にも効く。PR #2114 cycle 1 で「TC の stderr assert が vacuous」と 1 本名指しで指摘され、指摘された箇所だけを anchor し直したところ、cycle 2 で残りが返ってきた:

- 同じ helper が持つ stderr 転送は **3 本 (jq / mkdir / mv)** あり、pin が付いたのは mkdir だけだった。mv は無検査のまま残り、cycle 2 で rm 側にも捕捉を足したことで 4 本目が生まれた
- 同様に「A と B を弁別する」と invariant を明記しながら、pin したのは判定不能側 (B) だけだった。正常側 (A) の文言を B へ潰しても全 green。cycle 3 で「もう片側」として返ってきた

**指摘は 1 本しか名指ししないが、守るべき invariant は通常その族全体に及ぶ**。有効な問いは症状側からの列挙と同じ形で:

> この pin が守る対象は、このファイルに何本あるか。

対になる概念（正常/異常、A/B の弁別、producer/consumer）を宣言したら、**両側に pin を置く**。片側だけ pin した対は次のサイクルで必ずもう片側が出てくる。

**helper 本体を厚く pin しても、その呼び出し元は別の面**でもある。PR #2114 では helper 本体を 60 assert まで固めた一方、唯一の呼び出し元（skill の bash block）を固定する層はゼロで、呼び出しを PR 前の形へ戻しても全 114 test file が green だった。機構を足した commit では「機構本体」だけでなく「機構が呼ばれていること」も pin する（該当区間を grep して呼び出し 1 本 + 旧形 0 本を assert する静的 pin で足りる）。

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](../patterns/trap-register-before-mktemp.md)
- [修正が既存の no-op 経路を有効化すると、その経路に潜んでいたバグが初めて顕在化する](../anti-patterns/fix-activates-dormant-no-op-path-reveals-latent-bug.md)

## ソース

- [Review cycle 5: sibling-exit coverage for fail-loud guards and safety-net verification](../../raw/reviews/20260804T155148Z-pr-2111-cycle5.md)
- [Fix cycle 5: exit-exhaustive fail-loud guards, canonical trap, honest safety-net docs](../../raw/fixes/20260804T155921Z-pr-2111-cycle5.md)
- [PR #2114 fix results (cycle 2) — pin が守る対象の兄弟を数える](../../raw/fixes/20260805T110153Z-pr-2114.md)
