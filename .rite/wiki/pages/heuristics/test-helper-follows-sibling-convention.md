---
title: "新規 test helper は同ディレクトリ sibling test の既存 helper 慣習を踏襲する (counter + summary 報告)"
domain: "heuristics"
description: "bash test に新規 helper (skip 等) を追加するときは echo のみの最小実装ではなく、同ディレクトリ sibling test file の確立済み helper 慣習 (counter init + increment + Summary 報告) を踏襲する。最小実装だと CI ログで skip 件数と全 PASS を判別できず observability が劣化する。表示文言の逐語コピーではなく「counter + summary 報告」という構造的慣習を踏襲し、Summary 行形式は file-local 既存形式を優先する。過去のレビューで code-quality が actionable 検出。過去のレビューで「skip を素の echo で実装しカウンタ・マーカー基準の走査からカバレッジ欠落が観測できなくなる」同型パターンを再確認、skip 自体の不要化 (前提確定) を代替対策として提示。"
created: "2026-06-09T07:58:52+00:00"
updated: "2026-07-20T10:36:25+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T235117Z-pr-1921.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T064947Z-pr-1318.md"
tags: ["test", "bash", "observability", "convention", "skip-counter"]
confidence: medium
---

# 新規 test helper は同ディレクトリ sibling test の既存 helper 慣習を踏襲する (counter + summary 報告)

## 概要

bash test スクリプトに新しい helper (`skip()` / `pass()` / `fail()` 等) を追加するときは、echo のみの最小実装で済ませず、**同ディレクトリの sibling test file が既に確立している helper 慣習 (カウンタ変数の初期化 + helper 内 increment + Summary 行での報告) を踏襲する**。最小実装だと CI ログで「skip された件数」と「全件 PASS」が判別できず、test observability が劣化する。

## 詳細

### 症状

起点事例で新規追加した `skip()` helper が echo のみの実装だった:

```bash
skip() {
  echo "  ⏭️  SKIP: $1"
}
```

これは `SKIP` カウンタを増やさず、Summary 行 (`PASS: $PASS` / `FAIL: $FAIL` のみ) にも反映されない。root 環境では権限ベースの 2 テスト (chmod 0500 を使う負例) が skip されるが、その事実が Summary に現れず `PASS: 13 / FAIL: 0` としか出力されないため、CI ログから「2 件 skip されたのか、全件実行で PASS したのか」が判別できない。

### sibling の確立済み慣習

同ディレクトリの sibling test file (`notification.test.sh` / `pre-compact.test.sh`) は **三点セット** を持っていた:

1. ファイル冒頭での `SKIP=0` 初期化 (`PASS=0` / `FAIL=0` と並ぶ)
2. `skip()` 内での `SKIP=$((SKIP + 1))`
3. Summary 行への `SKIP` 反映

新規 helper はこの確立済み慣習に揃えるべきだった。code-quality reviewer が actionable recommendation として検出し、fix で三点セットに統一した。

### Summary 形式は file-local 既存形式を優先

ただし「sibling と完全一致」ではなく、**file 内一貫性 > cross-file 統一** を優先する。例: sibling は `=== Results: N passed, N failed, N skipped ===` の 1 行形式だが、対象 file は既に `PASS: $PASS` / `FAIL: $FAIL` の複数行形式を採用していたため、そこに `SKIP: $SKIP` を 1 行追加する方が file-local には整合的。踏襲すべきは「counter + summary 報告という構造的慣習」であり、表示文言の逐語コピーではない。

### 教訓

- test helper を追加する PR では、着手時に **同ディレクトリの sibling test file を 1-2 個 grep して既存 helper の構造 (counter init / increment / summary 反映) を確認** してから書く。
- 「echo だけの helper」は動くが observability を欠く。root skip / env-gated skip がある test では特に、skip 件数が Summary に出ないと「未実行 (skip) なのに全 PASS に見える」false-confidence を生む。

### 再発事例: 前提不成立時の skip が `FAIL: 0` のまま観測不能になる（再確認）

SSH host alias 対応 PR のテストでも、前提条件不成立時の skip を `pass` ではなく素の `echo` で実装したため、skip 発火時にアサーション数が減っても `FAIL: 0` のまま表示され、カウンタ・マーカー基準の走査からカバレッジ欠落が観測できなくなる同型パターンが検出された。skip 自体を不要にする (前提を確定的に作る) のがより本筋の対策として提示された — カウンタ三点セットの追加より優先度が高い代替手段。

## 関連ページ

- [bash test の summary 行は `$(basename "$0")` で自動同期する](../patterns/bash-test-summary-basename-auto-sync.md)

## ソース

- [PR #1318 review results (cycle 1)](../../raw/reviews/20260609T064947Z-pr-1318.md)
- [PR #1921 review results — 前提不成立時 skip の echo 実装によるカウンタ観測不能パターンを再確認、skip 自体の不要化 (前提確定) を代替対策として提示](../../raw/reviews/20260719T235117Z-pr-1921.md)
