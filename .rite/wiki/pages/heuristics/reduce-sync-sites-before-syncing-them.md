---
type: "heuristics"
title: "「N 箇所で同期が必要」と指摘されたら、同期する前に N を減らせないか検討する"
domain: "heuristics"
promote: rite-plugin
description: "「read 経路 3 コピーのうち 1 つだけ変更されており、残り 2 つと SoT が未同期」という指摘に対する自然な反応は「残り 3 箇所を同期する」だが、過去のレビュー事例の cycle 1 では**変更した 1 箇所を revert する**ほうが安全だった。"
created: "2026-07-27T17:54:54+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260727T042311Z-pr-2036.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T051956Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T073316Z-pr-2044.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-29T21:32:36+09:00" }
---

# 「N 箇所で同期が必要」と指摘されたら、同期する前に N を減らせないか検討する

## 概要

「read 経路 3 コピーのうち 1 つだけ変更されており、残り 2 つと SoT が未同期」という指摘に対する自然な反応は「残り 3 箇所を同期する」だが、起点事例の cycle 1 では**変更した 1 箇所を revert する**ほうが安全だった。同期は同期対象を増やす方向であり、将来の drift 点を増やす。

## 詳細

revert を選んだ根拠は 3 つ:

- **(a) スコープ**: 残り 2 コピーと SoT は別 Issue が所有するファイルで、本 PR のスコープ外。スコープ外ファイルを「同期のため」に触ると、レビュー対象が本来の変更から拡散する。
- **(b) 機能していない**: write 側が当該フィールドを出力しない現状では、その述語は恒に偽で一度も発火しない。動いていないコードの 3 箇所同期は、検証できない変更を 3 倍に増やすだけ。
- **(c) 非対称そのものが消える**: revert すれば「1 箇所だけ違う」状態が存在しなくなる。同期は「全部同じ」状態を新たに作るが、次に誰かが 1 箇所だけ触れば同じ指摘が再発する。

**判断の型**: 同期指摘を受けたら、まず次を問う。

1. その述語・分岐は**今**動いているか（write 側が配線されているか、到達可能か）
2. 変更を revert すれば非対称が消えるか
3. 同期対象は自分のスコープ内か

3 つのうち「動いていない」「revert で消える」が成り立つなら、同期ではなく revert を選ぶ。同期は「両側が実際に動く」段階（write 側配線 PR）まで待ち、そのとき初めて 1 回で行う。

**関連する判断**: 同 PR では、read 側の型ガード追加が SoT の「ここには型ガードを置かない」という記述と衝突した指摘についても、型ガードごと revert して SoT 記述を真のまま保つ選択をした。reason 表・eval-order からも関連エントリを削除し、revert が中途半端に残らないようにしている。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [References 抽出 refactor では canonical contract の SoT を 1 reference に固定し他は anchor 参照のみとする](../patterns/single-sot-on-references-extract.md)
- [記録専用フィールドを判定入力に格上げする変更は 4 点を同時に同期する](./field-semantics-promotion-record-to-decision-input.md)

## ソース

- [fix 結果](../../raw/fixes/20260727T042311Z-pr-2036.md)

## 補強: 「同じ箇所が N cycle 連続で壊れた」は記述精度ではなく重複そのものを疑う signal

`docs/CONFIGURATION.md` の handoff 残存条件は cycle 1（片側だけの失敗記述）→ cycle 3（"one cycle" の量化）→ cycle 4（先行詞の崩壊）と **3 回連続で defect を出した**。毎回 fresh な散文で同じ条件を書き直し、そのたびに新しい欠陥を持ち込んでいる。

同じ条件を 2 箇所で独立に書き下すのをやめ、片方は**観測可能な帰結だけ**を述べて条件は SoT へ委譲するのが解だった。

> **判断の型**: 「同じ箇所が N cycle 連続で壊れた」を、その箇所の記述精度の問題として扱わない。**記述の重複そのものを疑う signal** として読む。

### ただし SoT 委譲チェーンの終端ノードは他から訂正されない

委譲は万能ではない。`CONFIGURATION.md` → `contract.md` のように「正確な条件は委譲先が SoT、ここでは再掲しない」と明示委譲すると、**委譲先の誤りは他のどのドキュメントからも訂正されない**。読者は必ずその記述に着地する。終端ノードの記述精度は、中間ノードより高い基準で保つ必要がある。委譲を張るときは委譲先の網羅性を同時に確認する。

## ソース（追記分）

- [同じ条件を 2 箇所で書き下し 3 cycle 連続で壊す](../../raw/fixes/20260729T051956Z-pr-2044.md)
- [SoT 委譲チェーンの終端ノード](../../raw/fixes/20260729T073316Z-pr-2044.md)
