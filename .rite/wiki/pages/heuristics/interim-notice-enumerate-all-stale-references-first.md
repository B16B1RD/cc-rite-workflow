---
type: "heuristics"
title: "暫定注記は対象成果物内の同種表記を全数列挙してから書く"
domain: "heuristics"
description: "陳腐化した成果物（再生成できない動画等）への暫定注記を書くとき、注記が言及する「旧表記」の範囲は対象成果物内の同種表記を最初に全数把握してから決める。"
created: "2026-07-26T20:51:40+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260726T112624Z-pr-2029.md"
  - type: "reviews"
    resource: "raw/reviews/20260726T114240Z-pr-2029.md"
  - type: "fixes"
    resource: "raw/fixes/20260726T112821Z-pr-2029.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-26T20:51:40+09:00" }
---

# 暫定注記は対象成果物内の同種表記を全数列挙してから書く

## 概要

陳腐化した成果物（再生成できない動画等）への暫定注記を書くとき、注記が言及する「旧表記」の範囲は対象成果物内の同種表記を最初に全数把握してから決める。部分列挙のまま注記を出すと、次のレビュー cycle で Enumeration Completeness（列挙完全性）の指摘として再指摘され、文言拡張だけの往復で cycle を 1 回消費する。全数把握は生成元ソース（composition）の Read / 対象範囲の grep で機械的にできる。

## 詳細

起点事例で実測した 3 cycle の往復:

- **cycle 1**: 動画が旧 owner のインストールコマンドを表示している指摘 → Demo 節に「動画内のインストールコマンドは旧 owner 表記」の注記を追加（このとき言及したのはコマンド 1 箇所のみ）。
- **cycle 2**: tech-writer が composition ソースを Read し、動画の outro フッター URL にも旧 owner が映ることを検出。「注記の列挙が不完全」として MEDIUM/current-pr の指摘 → 注記を「インストールコマンドおよび末尾のフッター URL」の 2 箇所列挙に拡張。
- **cycle 3**: `git grep -i <旧owner> -- media/` の結果が「コマンド + フッター URL の 2 箇所ちょうど」（3 つ目なし）であることを実測確認して mergeable。

教訓:

- 注記を書く前に `git grep <旧表記> -- <成果物ソースのディレクトリ>` を 1 回走らせて全数を列挙していれば、cycle 1 の注記で完結し cycle 2 の往復は不要だった。
- 収束確認も同じ grep で「注記の列挙 == ソース内の全数」を機械的に判定できる。レビュアーの主観に依存しない終了条件になる。
- 文言拡張の修正でも英日ペア README は必ず同時更新する（片側のみの修正は i18n parity で再指摘される）。
- reviewer に「前 cycle 実測の再利用可」と許可しても、各 reviewer は独立再実測を選ぶ傾向がある（許可しても品質は落ちず、収束確認の証拠が毎 cycle 新鮮になる）。

## 関連ページ

- [リポジトリ owner rename の一括置換はリポジトリ外成果物に届かない](./repo-rename-sweep-misses-external-artifacts.md)
- [カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る](./enumeration-compression-verify-blocking-classification.md)

## ソース

- [PR #2029 review results (cycle 2)](../../raw/reviews/20260726T112624Z-pr-2029.md)
- [PR #2029 review results (cycle 3, mergeable)](../../raw/reviews/20260726T114240Z-pr-2029.md)
- [PR #2029 fix results (cycle 2)](../../raw/fixes/20260726T112821Z-pr-2029.md)
