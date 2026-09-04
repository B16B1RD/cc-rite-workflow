---
type: "anti-patterns"
title: "守るべき失敗モードを「検証対象なし」へ分類する後条件ゲートは、その失敗モードを最初から素通しする"
domain: "anti-patterns"
description: "後条件ゲートの verdict 分類に sibling helper の判断をそのまま写すと、写し元の呼び出し文脈でだけ正しい「検証対象なし」の定義が持ち込まれ、ゲートが塞ぐべき当の状態が clean bill に落ちる。骨格の再利用と判断の再利用は別物である。"
created: "2026-08-30T11:20:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-30T11:20:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260830T011225Z-pr-2470.md"
  - type: "fixes"
    resource: "raw/fixes/20260830T012124Z-pr-2470.md"
tags: [gate-design, sibling-copy, verdict-classification]
confidence: high
---

# 守るべき失敗モードを「検証対象なし」へ分類する後条件ゲートは、その失敗モードを最初から素通しする

## 概要

後条件ゲート（post-condition gate）は「手順が実際に効いたか」を実態から確かめる機構である。その verdict 分類に `skipped`（検証対象なし）のような無害カテゴリを設けるとき、その定義を sibling helper から写すと、**写し元の呼び出し文脈でだけ正しい判断**が持ち込まれる。結果として、ゲートが塞ぐために作られた当の状態が `skipped` に落ち、clean bill として無音で通過する。骨格（config 探索・trap・API 呼び出しの作法）の再利用と、判断（この状態は drift ではない）の再利用は別物である。

## 詳細

### 発生事例

`/rite:open` の「Projects Status → In Progress」手順は全 result 分岐が non-blocking で、手順を飛ばした場合も helper が失敗した場合も同じ無音になる。散文の「skip 禁止」とインライン化を既に施しても再発したため、**盤面の実 Status を読む後条件ゲート**を新設した。

このゲートは既存の board 検査 helper から骨格を写した。同時に「盤面未登録（item がボードに無い）は drift ではない」という判断も写した。写し元は `auto_add` を使わない文脈で走るため、その判断は正しい。しかし写し先は `auto_add: true` の直後に走る — **item の不在は「手順が実行されなかった証拠」そのもの**である。

さらに第 2 の網（残留検知の watchdog）も同じ状態を除外していたため、二重の網の両方をすり抜けた。

### 失敗の構造

1. 新設ゲートの実装で、同型の既存 helper から骨格を写す
2. 骨格に付随する verdict 分類（`skipped` / `not_applicable` の定義）も一緒に写る
3. 写し元の分類は写し元の呼び出し文脈（前段で何が保証されているか）に依存している
4. 写し先ではその前提が成立しない、あるいは反転している
5. ゲートが塞ぐ対象の状態が無害カテゴリへ落ち、**新設ゲートが最初からその状態を素通しする分岐を持って生まれる**
6. 別レイヤの網も同じ分類を採っていれば、多層防御が同時に無効化される

### 対策

1. **verdict の各カテゴリについて「この値を返す入力集合」を具体的に列挙する**。無害カテゴリに落ちる入力の中に、ゲートの動機となった failure mode が混じっていないかを個別に確認する
2. **同型分類を別 helper から借りるときは、呼び出し文脈の前提が同じかを明示的に確認する**。「この gate は `auto_add: true` の直後に走る」のような前提は写し元には書かれていない
3. **多層防御では、各層が同じ除外条件を持っていないかを対で点検する**。層ごとに別の除外基準を持たせるか、除外基準そのものを共有 SoT に置いて 1 箇所で見えるようにする
4. **mutation で確かめる**: 動機となった failure mode を再現する fixture を置き、`emit <無害カテゴリ>` → `emit ok` の書き換えでテストが赤くなるかを実測する。緑のままなら、その failure mode はテストにもゲートにも到達していない

### 骨格の再利用と判断の再利用

sibling helper からの流用は、防御規約（trap の順序・制御文字の無害化・tree 解決）については積極的に継承すべきである（[新規 helper は既存 sibling の安全規約に整合させる](../heuristics/new-helper-conform-to-sibling-safety-conventions.md)）。継承してはならないのは**分類判断**で、こちらは呼び出し文脈に依存する。レビュー時は「写した行のうち、どれが規約でどれが判断か」を分けて読む。

### marker 契約の付随する罠

同じ PR で観測された関連事象: ゲートが emit する marker の値を `jq -r '.result // "failed"'` で作ると、入力が空文字・非 JSON のとき jq は何も出さずに終わり、`//` の fallback は発火しない。marker が空になると「marker が出ていない」と機械的に区別できず、**可視化のために足した marker が最も必要な失敗時にだけ消える**。変数へ落とした直後の `[ -z "$x" ] && x=<default>` が要る。

## 関連ページ

- [新規 helper は既存 sibling の安全規約に整合させる（trap・tree 解決・制御文字無害化）](../heuristics/new-helper-conform-to-sibling-safety-conventions.md)
- [独立した判定層は既存層の分岐の内側に置かない — 層ごとに別 marker を持たせ可否は failure marker の不在で決める](../patterns/independent-gate-layer-outside-existing-branch.md)
- [ガードの識別力は「そのガード単独で発火する形状」の fixture とガード固有文言 assert で担保する](../heuristics/guard-discriminating-power-requires-solo-firing-fixture.md)
- [新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される](./upstream-silent-path-defeats-new-logged-guard.md)

## ソース

- [レビュー結果](../../raw/reviews/20260830T011225Z-pr-2470.md)
- [fix 結果](../../raw/fixes/20260830T012124Z-pr-2470.md)
