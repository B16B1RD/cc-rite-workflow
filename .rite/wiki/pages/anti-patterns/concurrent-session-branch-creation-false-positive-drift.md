---
type: "anti-patterns"
title: "並行セッションの別 Issue ブランチ作成が post-review state verify の branch_list drift を誤検出させる"
domain: "anti-patterns"
description: "レビュー前後の branch 一覧ハッシュを比較して reviewer の READ-ONLY 違反を検出する仕組みは、別の並行セッションが同時に別 Issue 用のブランチを作成/削除しただけでも drift を報告する。検出対象（このレビューの reviewer）と観測対象（リポジトリ全体の branch 一覧）が一致していないための false positive。"
created: "2026-09-26T07:00:00+00:00"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T07:00:00+00:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T062846Z-pr-3117.md"
tags: ["multi-session", "false-positive", "branch-list-hash", "post-review-state-verify", "concurrent-session"]
confidence: medium
---

# 並行セッションの別 Issue ブランチ作成が post-review state verify の branch_list drift を誤検出させる

## 概要

reviewer の READ-ONLY enforcement を検証する post-review state verify は、レビュー開始前後の `git branch --list` ハッシュを比較して drift を検出する。この検出範囲はリポジトリ全体の branch 一覧であり、レビュー中の reviewer 自身の操作に限定されていない。マルチセッション環境で別のセッションが同時に別 Issue のセッション worktree ブランチを作成・削除すると、当該レビューの reviewer は何も変更していないにもかかわらず drift として報告される。

## 詳細

検出ロジックは「レビュー開始時の branch 一覧のハッシュ」と「レビュー終了時の branch 一覧のハッシュ」を比較するだけで、変更した主体を区別しない。これは単一セッション・単一ユーザーの前提では正しく機能するが、`/rite:batch-run` のように複数セッションが同一リポジトリで並行に別 Issue を処理する運用では、以下が起こる:

1. セッション A がレビュー対象 PR の reviewer を起動（branch 一覧のハッシュを記録）
2. セッション B が別 Issue のセッション worktree 用ブランチを作成（リポジトリ全体の branch 一覧が変化）
3. セッション A の reviewer が完了（branch 一覧のハッシュを再取得 → 不一致 → drift 報告）

drift の原因は reviewer の READ-ONLY 違反ではなく、無関係な並行セッションの正常な操作である。

## 関連ページ

- [sandbox のバインドマウントで raw git status が常時 dirty になる](../anti-patterns/sandbox-bind-mount-makes-raw-git-status-always-dirty.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T062846Z-pr-3117.md)
