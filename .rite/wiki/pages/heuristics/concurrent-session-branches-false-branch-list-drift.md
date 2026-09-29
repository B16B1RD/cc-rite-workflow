---
type: "heuristics"
title: "並行セッションが作るブランチは、レビュー前後のブランチ一覧比較に偽のずれを出す"
domain: "heuristics"
description: "レビュー中に同じリポジトリで別セッションがブランチを作ったり worktree を片付けたりすると、レビュー前後のブランチ一覧の比較が reviewer の漏れと区別できないずれを報告する。現在ブランチと HEAD の不変性を確認し、増減したブランチの作者を確認できなければ帰属未確認として扱う。"
created: "2026-09-29T01:07:27Z"
generated: { by: "rite-wiki-ingest/gpt-6", at: "2026-09-29T05:09:59.094345+00:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T044754Z-pr-3432.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T002921Z-pr-3412.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T003742Z-pr-3397.md"
tags: ["multi-session", "review", "drift", "git-branch"]
confidence: medium
---

# 並行セッションが作るブランチは、レビュー前後のブランチ一覧比較に偽のずれを出す

## 概要

レビュー中に同じリポジトリで別セッションがブランチを作ったり worktree を片付けたりすると、レビュー前後のブランチ一覧の比較が reviewer の漏れと区別できないずれを報告する。現在ブランチと HEAD の不変性を確認し、増減したブランチの作者を確認できなければ帰属未確認として扱う。

## 詳細

共有リポジトリでは、他セッションの作業ブランチの作成・削除と、worktree を片付けてブランチだけ残す操作が、レビューの前後で起こる。ブランチ一覧のハッシュを比べる検査は、checkout 中のブランチを除外していても、片付けで checkout が外れたブランチや checkout されていないブランチの増減を拾う。ずれが出たら、現在ブランチが不変か、増減したブランチがどの worktree で使われているか（`git for-each-ref --format='%(refname:short) %(worktreepath)'`）を確かめてから reviewer の漏れと判定する。

作業ツリーが clean で HEAD が不変でも、共有ブランチ一覧の増減を誰が起こしたかまでは確定しない。並行 worktree の存在は別セッションによる変更の可能性を示す証拠であり、作者を特定できないずれは reviewer に帰属させず、帰属未確認として記録する。

## 関連ページ

- （関連ページなし）

## ソース

- [ブランチ一覧の比較が他セッションのブランチで drift を出したレビュー結果](../../raw/reviews/20260929T002921Z-pr-3412.md)
- [並行セッションのブランチ作成で drift が出たレビュー結果](../../raw/reviews/20260929T003742Z-pr-3397.md)

- [レビュー結果](../../raw/reviews/20260929T044754Z-pr-3432.md)
