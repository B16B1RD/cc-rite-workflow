---
title: "Fix の完成判定は shell script 単体動作ではなく実ワークフロー発火実績で行う"
domain: "heuristics"
created: "2026-04-17T00:15:00+00:00"
updated: "2026-04-17T00:15:00+00:00"
sources:
  - type: "retrospectives"
    ref: "raw/retrospectives/20260416T094137Z-issue-532.md"
tags: ["verification", "workflow", "silent-regression", "testing"]
confidence: high
---

# Fix の完成判定は shell script 単体動作ではなく実ワークフロー発火実績で行う

## 概要

修正が動いていると主張する前に、shell script 単体のテストデータではなく、自然な workflow 経路を通った commit 履歴上の発火実績を確認する。手動投入のテストデータと自然発火を混同すると、silent regression を見逃す。

## 詳細

### 背景

Issue #532（Wiki 機能が実ワークフローで発火しない問題）の根本原因調査で、以下の盲点が浮き彫りになった:

- 先行修正 #528/#529（Wiki raw commit の shell script 化）は shell script 単体では正常に動作していた
- しかし実 commit 履歴を精査すると、自然な PR ワークフローから発火した raw source は**ゼロ件**だった
- wiki branch に残っていた 7 commits は全て「修正作業中に開発者が検証目的で手動実行した残骸」であり、E2E 発火実績ではなかった
- 結果、「直ったと報告済み」の機能が実質的には死に体のまま数サイクル放置された

### 失敗のメカニズム

1. **単体テストの成功 = E2E 成功と誤認**: shell script を手動 invocation で動作確認しただけで「直った」と判断
2. **呼び出し元の到達経路を検証していない**: `review.md` Phase 6.5.W.2 / `fix.md` Phase 4.6.W.2 / `close.md` Phase 4.4.W.2 など、shell script を呼ぶべき上位経路が early-return などで実行されていない可能性を見落とし
3. **出力の有無を実 commit 履歴で確認していない**: 「script の stdout を見て OK」ではなく、「wiki branch に自然発火の commit が出現したか」を見る必要があった

### 検証のための観察ポイント

| 観察対象 | NG (見落としがち) | OK (E2E 実証) |
|---------|-----------------|--------------|
| Shell script | 手動実行で stdout が期待通り | 実ワークフロー経路から commit が出現 |
| Hook / Phase | コード上に記述されている | 実行 log やメッセージで発火痕跡が確認できる |
| テストデータ | 手動投入のサンプル | 本番ワークフローが生成したファイル |
| Fix の健全性 | 単体テスト Green | 直近 N 件の PR に対応する artifact が生成されている |

### 適用条件

- 「ある条件下で silent に skip され得る経路」を含む機能の修正
- 多層にネストされた Phase / hook / callback の実行を必要とする機能
- 単体テストでは観測できない side effect（commit / push / file generation など）に依存する機能

### 対策

- Fix 完了を宣言する前に、最低 1 件は **自然な workflow サイクルを通した commit/artifact の出現**を確認する
- Unit test とは別に「E2E firing trace」をチェックリスト化する
- 監視スクリプト（例: `wiki-growth-check.sh`）で「直近 N 件の PR に対応する artifact が存在するか」を自動判定できるようにしておく

## 関連ページ

- （関連ページなし）

## ソース

- [Issue #532 close retrospective](raw/retrospectives/20260416T094137Z-issue-532.md)
