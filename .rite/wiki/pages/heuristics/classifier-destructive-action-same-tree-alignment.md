---
title: "破壊的操作を承認する分類器は判定・実行・承認文言が同じ対象を見ることを保証する"
domain: "heuristics"
description: "判定 (working tree)・破棄 (index 復元)・承認文言 (「確認済み」) の 3 者不一致は informed consent を壊す。一致させられない dirty (staged/untracked) は判定前に保護経路へ倒す。過去のレビュー事例 実測。"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/heuristics/classifier-destructive-action-same-tree-alignment.md"
created: "2026-07-13T09:15:00Z"
updated: "2026-07-13T09:15:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260713T000901Z-pr-1840.md"
tags: []
confidence: high
---

# 破壊的操作を承認する分類器は判定・実行・承認文言が同じ対象を見ることを保証する

## 概要

「検証してから破棄」型のフローでは、(1) 判定が読む対象、(2) 破棄コマンドが作用する対象、(3) ユーザー承認文言が主張する対象、の 3 者が一致していないと、承認プロンプトが未検証の内容について「確認済み」と過大主張し、承認の informed consent が壊れる。3 者を一致させられないケースは判定対象から除外して安全側 (保護経路) へ倒す。

## 詳細

起点事例の discardable 判定 (未コミット変更がマージ済み内容と diff 同一なら破棄提案) で実際に起きた不一致:

- 判定: working tree vs origin の比較 (`git diff`)
- 破棄: `git checkout -- :/` は **index** から復元 (tree-ish 省略時)。staged 変更がある場合、判定が見ていない index 内容が worktree へ蘇生し、破棄が意図どおり動かない
- 文言: 「diff 同一を確認済み」— staged / untracked は比較していないのに全 dirty について主張

解決は「判定対象を unstaged の tracked 変更のみに限定し、staged / untracked を含む dirty は判定前に divergent (stash 案内 = 保護経路) へ倒す」こと。これにより discardable では index == HEAD が保証され、`checkout -- :/` (index 復元) = HEAD 復元が成立し、文言の「diff 同一」も全 dirty に対して真になる — 3 者が同時に整合する。

付随の教訓: porcelain X 列の gate regex (`grep '^[^ ]'`) は全 XY 組合せ表で機械検証する。除外クラスに `?` を 1 文字入れただけで untracked が素通りし、5 reviewer が独立検出する結果になった。

## 適用条件

- ユーザー承認を経て破棄・上書き・stash 等の破壊的操作を行うワークフロー分岐の設計・レビュー
- 「〜を確認済み」と提示する承認プロンプトの文言設計

## 関連

- [[pathspec-miss-exit-zero-defeats-diff-guard]] — 同 PR の判定側縮退挙動
- [[mechanical-test-over-declarative-invariant]] — 決定論的分類器は SKILL.md 内でも awk アンカー抽出 + placeholder 置換で fixture テスト化できる (本 PR で 8 TC + mutation 検証を実施)
