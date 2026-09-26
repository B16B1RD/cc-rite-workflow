---
type: "heuristics"
title: "同じ処理を 2 経路で実装したら fixture の「意地悪さ」も 2 経路で揃える"
domain: "heuristics"
description: "同じ処理を 2 つの入力形式・2 つの経路で実装したとき、新しく足した側の fixture が「素朴な形」しか持たないと、経路の**存在**は測れても経路の**正しさ**は測れない。"
created: "2026-08-02T09:53:11+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260801T184452Z-pr-2070.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T185220Z-pr-2070.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T035155Z-pr-3106.md"
tags: ["fixture-design", "dual-path", "mutation-testing", "test-strength"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T04:05:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T04:05:00Z" }
---

# 同じ処理を 2 経路で実装したら fixture の「意地悪さ」も 2 経路で揃える

## 概要

同じ処理を 2 つの入力形式・2 つの経路で実装したとき、新しく足した側の fixture が「素朴な形」しか持たないと、経路の**存在**は測れても経路の**正しさ**は測れない。既存側が生パイプ入りタイトル・コードスパン入りサマリーといった「厄介な入力」で処理との相互作用を pin しているなら、新設側にも同じ厄介さを持つ行を置く。

## 詳細

**ある PR の cycle 2 の実測**

テーブル形式に加えて OKF 箇条書き形式の走査経路を新設した。テーブル経路の fixture は既に以下で相互作用を pin していた。

- 生パイプ入りタイトル（TC-27）— セル境界とタイトル内リテラルの衝突
- コードスパン入りサマリー（TC-50）— マスク処理と抽出処理の干渉

一方、新設した箇条書き経路の fixture は、リンク・区切り・サマリーがマスク処理と**一切干渉しない形**しか持たなかった。結果、以下の変異がどちらも 172 PASS のまま生き残った。

| 注入した変異 | なぜ素朴 fixture では kill できないか |
|-------------|-----------------------------------|
| 形式 dispatch の行頭 anchor を外す | 素朴な行はどの位置でマッチしても同じ結果になる |
| summary 抽出の match をマスク前の行へ向ける | マスク対象の文字（コードスパン等）が fixture に無いため、マスク前後で行が同一 |

**素朴な fixture が測れるもの / 測れないもの**

| 測れる | 測れない |
|--------|---------|
| 経路が呼ばれること | 経路内の位置指定（anchor / 列位置）が正しいこと |
| 件数が 0 でないこと | 前処理（マスク・正規化）と抽出の**順序**が正しいこと |
| 基本形が通ること | 区切り文字とデータ内リテラルの衝突が処理されること |

**運用**

1. 新経路の fixture を書く前に、**既存経路の fixture が何を意地悪にしているか**を列挙する。テストファイル内の同種 TC を読めば分かる。
2. 同じ厄介さを新経路にも置く。ただし形式が違うので、厄介さの「表れ方」は形式に合わせて翻訳する（テーブルの生パイプ → 箇条書きならリンクテキスト内のパイプや区切り記号）。
3. **1 行足すごとに「どの変異を kill するために置くのか」をコメントで明示する**。これがないと、次の読み手は素朴な行と load-bearing な行を区別できず、整理の名目で削られる。
4. 件数の**両側**から捕らえる。hits だけでなく skipped_rows のような補集合側のカウンタも assert すると、片側だけずれる変異を拾える。

**片側 fixture は「宣言と検査の片側だけが存在する」形の一種**

「2 経路で同じ処理をする」と実装で宣言しながら、その宣言を破る変異が kill されない状態になっている。同ファイル内に既に対称の pin があるなら、その存在自体が「新設側にも要る」というシグナルである。

**同じフラグを 2 経路で使うときも同じ**

差分から変更ファイルを取る処理が、通常 commit では `git diff --no-renames`、merge commit では `git show --no-renames --remerge-diff` と 2 経路でフラグを使っていた。改名のテストの fixture に merge commit が無いため、merge 側の `--no-renames` を外す変異はテストで検出できない。フラグの意味をコメントで説明するときは、一時 repo で実挙動を確かめてから書く。「rename 検出が食い違うと元パスが落ちる」という説明は実測で外れていた（実際は `--name-only` が検出した改名の移動先しか出さないため）。

## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](./fixture-mutation-isolates-invariants.md)
- [テンプレート準拠の fixture では、生成器が実データで作る構造的逸脱を検出できない](./template-fixture-misses-generator-real-data-deviation.md)
- [accept fixture と reject fixture は設計目的が逆 — 安全側の形状を両方に適用すると順序契約が pin できなくなる](./accept-vs-reject-fixture-design-inversion.md)

## ソース

- [レビュー結果](../../raw/reviews/20260801T184452Z-pr-2070.md)
- [fix 結果](../../raw/fixes/20260801T185220Z-pr-2070.md)
- [レビュー結果](../../raw/reviews/20260926T035155Z-pr-3106.md)
