---
type: "heuristics"
title: "並行セッションが作るブランチは、レビュー前後のブランチ一覧比較に偽のずれを出す"
domain: "heuristics"
description: "レビュー中に同じリポジトリで別セッションがブランチを作ったり worktree を片付けたりすると、レビュー前後のブランチ一覧の比較が reviewer の漏れと区別できないずれを報告する。現在ブランチが変わっておらず、増減したブランチが他セッションの作業ブランチなら reviewer 由来ではないと判定する。"
created: "2026-09-29T01:07:27Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T01:07:27Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T002921Z-pr-3412.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T003742Z-pr-3397.md"
tags: ["multi-session", "review", "drift", "git-branch"]
confidence: medium
---

# 並行セッションが作るブランチは、レビュー前後のブランチ一覧比較に偽のずれを出す

## 概要

レビュー中に同じリポジトリで別セッションがブランチを作ったり worktree を片付けたりすると、レビュー前後のブランチ一覧の比較が reviewer の漏れと区別できないずれを報告する。現在ブランチが変わっておらず、増減したブランチが他セッションの作業ブランチなら reviewer 由来ではないと判定する。

## 詳細

共有リポジトリでは、他セッションの作業ブランチの作成・削除と、worktree を片付けてブランチだけ残す操作が、レビューの前後で起こる。ブランチ一覧のハッシュを比べる検査は、checkout 中のブランチを除外していても、片付けで checkout が外れたブランチや checkout されていないブランチの増減を拾う。ずれが出たら、現在ブランチが不変か、増減したブランチがどの worktree で使われているか（`git for-each-ref --format='%(refname:short) %(worktreepath)'`）を確かめてから reviewer の漏れと判定する。

## 関連ページ

- （関連ページなし）

## ソース

- [ブランチ一覧の比較が他セッションのブランチで drift を出したレビュー結果](../../raw/reviews/20260929T002921Z-pr-3412.md)
- [並行セッションのブランチ作成で drift が出たレビュー結果](../../raw/reviews/20260929T003742Z-pr-3397.md)
