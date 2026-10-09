---
type: "heuristics"
title: "手順書で停止を見分ける条件は、stderr の先頭一致ではなく、その行が現れるかで書く"
domain: "heuristics"
promote: rite-plugin
description: "helper が内部で呼ぶ別スクリプトの ERROR 行が先に出る経路では、「stderr が X で始まる」という条件が成り立たず、停止が汎用のエラー項へ流れる。見分けは行の有無で書き、見分けに使う文字列が似た接頭辞の別の出力と衝突しないかも確かめる。"
created: "2026-10-09T19:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-09T19:10:23Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261009T153627Z-pr-3727.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T154017Z-pr-3727.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T154606Z-pr-3727.md"
tags: ["procedure", "stderr", "stop-discrimination"]
confidence: high
---

# 手順書で停止を見分ける条件は、stderr の先頭一致ではなく、その行が現れるかで書く

## 概要

helper が内部で呼ぶ別スクリプトの ERROR 行が先に出る経路では、「stderr が X で始まる」という条件が成り立たず、停止が汎用のエラー項へ流れる。見分けは行の有無で書き、見分けに使う文字列が似た接頭辞の別の出力と衝突しないかも確かめる。

## 詳細

### 起きたこと

スキルを通らずに Issue 作成スクリプトを呼んだときの停止を、手順書は「stderr が `...gate:` で始まる」で見分けていた。helper は内部で flow-state.sh や state-path-resolve.sh を呼び、それらの ERROR 行が先に出る経路があるため、条件が成り立たない。2 名の reviewer が実際に実行して独立に検出した（blocking 1 件）。見分けの条件に当たらない停止は、直後の汎用エラー項（再試行・手動作成）へ流れていた。

### 直し方

- 誤った限定（先頭一致）を削り、「その行が stderr に現れるか」で見分ける。条件を足して補うのではなく、誤った限定を取り除く
- 見出しの条件が違う停止は、同じ箇条に混ぜず別の箇条に分ける
- 停止の箇条どうしが同時に当てはまらないこと（gate の終了経路が排他であること）を確かめる。修正後の再レビューでは 2 名とも実行して排他を確かめた

### 見分けに使う文字列の衝突を確かめる

見分けに使う文字列は、似た接頭辞を持つ別の出力と衝突しないかまで確かめる。この例では、記録の消費に失敗したときの文言（`issue-create gate could not be consumed`）は `gate:` のコロンを持たないため、「Issue は作られていない」の箇条には当たらない。判別条件を変えたら、どの分岐にも当たらない出力が残らないかを実際の出力で確かめる。

## 関連ページ

- [成功経路にも出る prefix を失敗の判別子にしてはならない](../anti-patterns/success-path-prefix-as-failure-detector.md)

## ソース

- [レビュー結果（先頭一致の条件が成り立たない経路）](../../raw/reviews/20261009T153627Z-pr-3727.md)
- [fix 結果（行の有無で見分ける箇条へ分ける）](../../raw/fixes/20261009T154017Z-pr-3727.md)
- [レビュー結果（排他と文字列の衝突の確認）](../../raw/reviews/20261009T154606Z-pr-3727.md)
