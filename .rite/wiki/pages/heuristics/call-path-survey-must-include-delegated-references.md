---
type: "heuristics"
title: "「この経路は X を呼ばない」の根拠は、委譲先ファイルまで含めた grep で取る"
domain: "heuristics"
description: "手順を別ファイルへ委譲する構造では、入口ファイルだけを grep して 0 件だったことは「呼ばない」の根拠にならない。委譲先まで含めて数えないと、結論が正しくても根拠が偽になり、次の変更者がその偽の前提の上に判断を積む。"
created: "2026-08-30T12:50:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-30T12:50:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260830T033236Z-pr-2471.md"
  - type: "fixes"
    resource: "raw/fixes/20260830T034210Z-pr-2471.md"
tags: []
confidence: high
promote: rite-plugin
---

# 「この経路は X を呼ばない」の根拠は、委譲先ファイルまで含めた grep で取る

## 概要

手順を別ファイルへ委譲する構造では、入口ファイルだけを grep して 0 件だったことは「呼ばない」の根拠にならない。委譲先まで含めて数えないと、結論が正しくても根拠が偽になり、次の変更者がその偽の前提の上に判断を積む。

## 詳細

### 何が起きたか

`flow-state.sh` に「`--issue 0` でキャッシュを落としても実害はない」という判断を入れ、その根拠として新規コメントに「cleanup は replica 同期を一切呼ばず」と書いた。根拠は `skills/cleanup/SKILL.md` を grep して `issue-comment-wm-sync` が 0 件だったこと。

実際には cleanup ステップ 11 が `skills/cleanup/references/archive-procedures.md` 経由で `issue-comment-wm-sync.sh update` を 2 回呼ぶ。入口ファイルには呼び出しが 1 行も無く、委譲先に全部ある。

**結論（実害なし）は正しかった** — cleanup の 2 呼び出しは `--issue` を明示するため、キャッシュを落としてもスキャンで拾い直し gh 往復が 1 増えるだけ。壊れていたのは根拠だけである。だからこそ質が悪い: 動作を確認しても検出できず、次に「cleanup は replica に触れない」を前提に判断する変更者が踏む。

同じ誤前提はテストのコメントにも複製されていた。根拠の誤りは、それを引用する側へそのまま伝播する。

### なぜ入口 grep で足りないと事前に気づけないか

「呼ばない」は**全称の否定**である。1 件見つければ肯定できるが、否定するには走査範囲の網羅を先に証明しなければならない。入口ファイルを開くと手順が書いてあるように見えるため、「ここに無いなら無い」と読んでしまう。委譲されている箇所は、入口側では 1 行の参照リンクにしか見えない。

### どう確かめるか

- **走査範囲を先に決める**: 入口ファイルが参照している同梱ファイル群まで含める。rite なら `skills/**/SKILL.md` だけでなく `skills/**/references/*.md` まで。`grep -rn <symbol> skills/<name>/` のようにディレクトリ単位で取る
- **0 件を根拠にするときだけ厳しくする**: 「呼ぶ」根拠は 1 件の hit で足りるが、「呼ばない」根拠は走査範囲の宣言とセットでしか書けない
- **結論と根拠を分けて検証する**: 動作確認は結論しか守らない。根拠の検証は grep をやり直すしかない
- **根拠を引用している箇所を同時に直す**: 誤った根拠はコメント・テストコメント・設計文書へ複製されている

### 適用範囲

rite の skills は手順を references へ切り出す構造を多用するため本ヒューリスティックが効きやすいが、対象は rite に限らない。「入口 + include」「dispatcher + handler」「base + mixin」など、実行される本体が入口ファイルの外にある構造すべてに当てはまる。

## 関連ページ

- [限界を説明する例は検出器に食わせ、「〜としてのみ使う」型の断定は grep で数えてから書く](./verify-explanatory-examples-against-the-detector.md)
- [新設要約文の「N 個の~系統」的な断定は対象外の類似構造を見落としやすい](../anti-patterns/unscoped-enumeration-claim-in-new-summary.md)

## ソース

- [レビュー結果](../../raw/reviews/20260830T033236Z-pr-2471.md)
- [fix 結果](../../raw/fixes/20260830T034210Z-pr-2471.md)
