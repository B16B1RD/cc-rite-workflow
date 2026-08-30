---
type: "heuristics"
title: "同一箇所への指摘が N cycle 連続したら、その箇所が何番目のコピーかを数える"
domain: "heuristics"
promote: rite-plugin
description: "review-fix loop で同じ箇所への指摘が cycle をまたいで繰り返すとき、追加パッチを当て続けるのが自然な反応になる。"
created: "2026-08-06T02:49:27Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260806T013318Z-pr-2120.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T02:49:27Z" }
---

# 同一箇所への指摘が N cycle 連続したら、その箇所が何番目のコピーかを数える

## 概要

review-fix loop で同じ箇所への指摘が cycle をまたいで繰り返すとき、追加パッチを当て続けるのが自然な反応になる。しかし原因が「その箇所の品質」ではなく「**その箇所が N 番目のコピーであること**」にある場合、パッチはコピー間の分岐をさらに広げるだけで終わる。ある PR の cycle 4 で orchestrator が 5 reviewer 全員にこのシグナルを明示して投げたところ、**5 者中 4 者が「単純化すべきは本 PR のコードではなく、リポジトリ内に 4 コピーある idiom の側だ」という同一の結論を返した**。

## 詳細

### 判別法 — コピー数を数える

| 原因 | 症状 | 答え |
|---|---|---|
| その箇所の品質 | 指摘内容が cycle ごとに別の欠陥を指す | 追加パッチ |
| N 番目のコピーであること | 指摘が「他のコピーとの差分」に集中する | 共有 helper への抽出 |

判別は `git grep` で**同じ idiom のコピー数を数える**ことでつく。コピーが 1 つなら品質の問題、複数あって各コピーの形が分岐しているならコピーの問題である。

### 実例 — 4 コピーが 4 通りに分岐していた

本 PR で問題になったのは「ディレクトリに `*` だけの `.gitignore` を同梱する」idiom で、リポジトリ内に 4 コピーあった。4 コピーは以下がすべて分岐していた。

- guard の形（`[ -f ]` = 存在検査 / `[ -s ]` = 中身検査）
- 失敗時の扱い（無音 / WARNING）
- `LC_ALL=C` の有無
- `[CONTEXT]` marker の有無

この状態では、**新しいコピーを書く人がどれを写すかで品質が決まる**。実際に本 PR は 3 番目の書き手として、2 コミット前に強化された形ではなく強化前の形を写していた。パッチを当てても 5 番目のコピーが同じ賭けを繰り返す。

### 抽出は follow-up、blocking にはしない

4 reviewer の一致した推奨は「**共有 helper への抽出は follow-up Issue とする**」だった。本 PR 単独では live defect が無いため blocking にはならない。指摘の連続がシグナルとして意味を持つのは「次に何をすべきか」の判断であって、当該 PR の merge 可否ではない。

これを混同すると、抽出という大きな変更を review-fix loop の途中に押し込むことになり、loop 自体が新しい drift の供給源になる。

### 転記元の選び方（コピーが残っている間の運用）

抽出が済むまでの間、新しいコピーを書くときは **`git grep` でパターンの全サイトを列挙し、各サイトの最終更新を `git log -S` で確認してから写す**。「直近に読んだ先例」を無自覚に選ぶと、強化の履歴を巻き戻す方向へ転記する。

本 PR の cycle 1 では、修正時に 4 サイトを並べたところ **多数派（2/4）は既に新形式で、転記元だけが少数派**だった。列挙していれば選択を誤らなかった。

### 「この機構が何を買ったか」を測る

cycle 4 では、cycle 3 で追加した中和のうち一部が **no-op** であることが実測された。`$to` の唯一の供給元（`--phase`）に対しては、同一実行の数行前に既存の `unknown phase` WARNING が raw バイトをそのまま出すため、中和は防御になっていない。

reviewer はこれを**指摘ではなく計測として報告**した。既存行の中和追加は運用環境の宣言（単一ユーザー開発機）下で要求できないためである。**買えていない部分を正直に記録しておくと、後の cycle で同じ観点が再提起されたときの打ち切り根拠になる。**

## 関連ページ

- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [新規スクリプトは同種の兄弟スクリプトの最新の防御を引き継ぐ](./new-script-inherits-latest-sibling-defenses.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #2120 review results (cycle 4)](../../raw/reviews/20260806T013318Z-pr-2120.md)
