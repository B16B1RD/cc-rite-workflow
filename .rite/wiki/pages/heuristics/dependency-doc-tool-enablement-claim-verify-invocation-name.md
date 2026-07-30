---
type: "heuristics"
title: "依存要件ドキュメントの「ツールを入れれば有効化」主張は実コードの呼び出し名を grep で裏取りする"
domain: "heuristics"
description: "README 等の依存要件で「ツール X を入れれば機能 Y が有効化」と書く前に、実コードがそのツール名を literal に呼んでいるか grep で確認する。実装が別コマンド名（例: gdate ではなく date -d）を呼んでいると、そのツールを導入しても機能は有効化されず記述が不正確になる。"
created: "2026-07-24T17:57:51+09:00"
updated: "2026-07-24T17:57:51+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T083434Z-pr-2004.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T083743Z-pr-2004.md"
  - type: "reviews"
    ref: "raw/reviews/20260724T084754Z-pr-2004.md"
tags: []
confidence: medium
---

# 依存要件ドキュメントの「ツールを入れれば有効化」主張は実コードの呼び出し名を grep で裏取りする

## 概要

README 等の依存要件で「ツール X（例: coreutils / gdate）を入れれば機能 Y が有効化される」と書く前に、実コードがそのツール名を literal に呼んでいるかを grep で裏取りする。実装が別名や別コマンド（例: `gdate` ではなく `date -d`）を呼んでいる場合、そのツールを導入しても機能は有効化されず、記述が不正確になる。

## 詳細

起点事例で README（英日）が「`brew install coreutils` で `gdate` が入り Wiki 陳腐化検出が有効化される」と記述した。しかし実スクリプト `plugins/rite/hooks/scripts/wiki-lint-stale.sh` は `gdate` を一切呼ばず `date -d`（GNU date 拡張）のみを呼んでいた（148 行の事前検査、189 行の本走査）。

homebrew の coreutils formula は `g` 接頭辞付きツール（`gdate` 等）を追加するだけで、システムの `date` は BSD date のまま置き換わらない。したがって `brew install coreutils` を実行しても `date -d` は依然として失敗し、陳腐化検出は `stale_check_ok=skipped_no_gnu_date` 経路のままスキップされる。有効化するには coreutils の `gnubin` ディレクトリを `PATH` の先頭に追加し、`date` を GNU 版に解決させる必要がある。

この drift は tech-writer の Doc-Heavy PR Mode（実装との整合性を検証する 5 カテゴリプロトコル）が cycle 1 で検出し、fix で「gnubin を PATH に追加して `date` を GNU 版に解決させる」記述へ修正、cycle 2 で mergeable に収束した。

教訓: 「install X → enables Y」型の依存記述は、実コードがそのツール名を literal に呼んでいるか（`gdate` を呼ぶのか、`date` を呼ぶのか）を grep で確認してから書く。実装が別コマンド名を呼んでいれば、ツールの導入だけでは有効化されず、PATH 解決などの追加手順が必要になる。この裏取りは、より一般的な「ドキュメントの主張を実装と照合してから書く」原則（[カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る](./enumeration-compression-verify-blocking-classification.md)）の依存要件記述への適用である。

## 関連ページ

- [カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る](./enumeration-compression-verify-blocking-classification.md)

## ソース

- [PR #2004 review results](../../raw/reviews/20260724T083434Z-pr-2004.md)
- [PR #2004 fix results](../../raw/fixes/20260724T083743Z-pr-2004.md)
- [PR #2004 review results (cycle 2)](../../raw/reviews/20260724T084754Z-pr-2004.md)
