---
title: "節の表示条件を変えたら inbound の位置参照を grep して文言同期する"
domain: "heuristics"
description: "ドキュメント / command 定義の 1 節を「常時表示」から「条件付き表示 (on-demand / Optional)」へ変えると、その節を「下記 (below)」「FAQ below」のような**固定位置を含意する文言で参照していた常時表示テキスト**が dangling reference 化する。"
created: "2026-06-10T12:41:54Z"
updated: "2026-06-10T12:41:54Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260610T123423Z-pr-1387.md"
tags: []
confidence: high
---

# 節の表示条件を変えたら inbound の位置参照を grep して文言同期する

## 概要

ドキュメント / command 定義の 1 節を「常時表示」から「条件付き表示 (on-demand / Optional)」へ変えると、その節を「下記 (below)」「FAQ below」のような**固定位置を含意する文言で参照していた常時表示テキスト**が dangling reference 化する。節の表示条件を変える修正では、その節への inbound 参照を grep し、**参照側の位置含意文言も同 cycle で更新する**こと。さもないと「常時表示される側がいつも表示されない側を『すぐ下にある』と案内する」矛盾が次レビュー cycle で指摘され、修正が新たな指摘を誘発する induced regression になる。

## 詳細

review-fix ループで実測。cycle 1 で getting-started.md の `## Phase 4.5` を `(On Demand)` 化し冒頭「run phases in order」契約に on-demand 例外を明記した (F-01 修正)。ところが cycle 2 で、**常時表示される** Troubleshooting 項目8 が「See the "Multiple sessions at once" FAQ **below** for the operating rules」と案内していたため、on-demand 化で通常 sweep では表示されない FAQ を「below」で指す dangling reference になった (F-03)。F-01 の修正自体が F-03 を誘発した形で、レビュアーがこれを正しく検出した。

### canonical 対策

- **表示条件を変える節には、その節への inbound 参照を必ず grep する**: heading 名 / 節タイトルで `grep -rn` し、`below` / `above` / `下記` / `上記` / `すぐ下` のような位置含意語を含む参照を洗い出す。
- **参照側の文言から位置含意を除去する**: 「below を見よ」ではなく「(条件) のとき表示される FAQ を参照」のように、表示条件に整合する案内へ書き換える。あるいは参照側に最小要点を直接埋め込んで参照依存自体を断つ。
- **線形実行 command 定義に条件付き Phase を足すときは Optional/On-Demand マーカーで矛盾を防ぐ** (関連 sub-lesson): 「run the following phases in order」契約を持つ command md に条件ゲート付き Phase を追加する場合、heading に `(Optional)` / `(On Demand)` を付け、冒頭契約に on-demand 例外を明記する (workflow.md Phase 5 `(Optional)` が先例)。これを怠ると「線形実行せよ」と「条件付きで表示せよ」が衝突し、実行 LLM がノイズ表示か契約黙殺かで不定になる (F-01 の root cause)。

### 隣接 anti-pattern (同 PR で同時実測)

- **broken cross-reference (Decision Log エントリ誤参照)**: 「(design D-N)」のような Decision Log 参照を書くときは、その D-N が実際に当該主張を扱う決定エントリかを確認する。起点事例では dogfood deferral を「design D-9」と参照したが、D-9 は `schema_version` bump 省略の決定で dogfood とは無関係だった (F-02)。**存在するが無関係なエントリへの参照**は、存在しないエントリ参照 (hallucinated-canonical-reference) と同様に読者を誤誘導する。参照を書く前に対象エントリの内容を 1 行確認するのが安価で確実。

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)

## ソース

- [PR #1387 review results](../../raw/reviews/20260610T123423Z-pr-1387.md)
