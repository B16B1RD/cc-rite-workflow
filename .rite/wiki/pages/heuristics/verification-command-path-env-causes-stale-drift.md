---
type: "heuristics"
title: "検証コマンドの環境指定に PATH を入れると hook 実行環境との差で stale 判定になる"
domain: "heuristics"
description: "検証コマンドを登録するとき、実行環境の PATH を明示指定すると、その値が hook 実行時の実際の PATH と食い違い、commit 前ゲートで検証記録が stale と判定される。往復が増える。"
created: "2026-09-26T05:45:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T05:45:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260926T051339Z-pr-3060.md"
tags: ["bash", "PATH", "verification", "hook"]
confidence: medium
---

# 検証コマンドの環境指定に PATH を入れると hook 実行環境との差で stale 判定になる

## 概要

検証コマンドを登録するとき、実行環境の PATH を明示指定すると、その値が hook 実行時の実際の PATH と食い違い、commit 前ゲートで検証記録が stale と判定される。往復が増える。

## 詳細

修正計画に登録する検証コマンドは、記録した内容が commit 前ゲートで再実行され、結果が記録と一致することを確認される。この再実行は hook が持つ実行環境（PATH を含む）で行われる。

検証コマンドの文字列自体に特定の PATH 値を埋め込む（例: 開発時の shell の PATH をそのままコマンド文字列へ書く）と、その PATH は hook 実行環境の PATH と一致しない場合がある（シェルの初期化ファイルの違い、対話 shell と非対話 shell の差など）。この食い違いにより、コマンドの実行結果自体は同じでも、記録された文字列としての完全一致検証が失敗し、stale（陳腐化）と判定される。

記録が stale と判定されると、commit 前ゲートは検証済みとして扱わず、再度の検証・再登録が必要になり、review-fix loop の往復が増える。

検証コマンドは、実行環境に依存する値（PATH 等）を文字列に埋め込まず、hook が実行する環境でそのまま再実行可能な形（相対パスや `command -v` 等の環境解決に依存しない形）で記録する。

## 関連ページ

- [判定手段を差し替えるときは、旧手段が暗黙に提供していた失敗条件を列挙してから移す](./replacing-a-judgment-mechanism-drops-its-implicit-failure-conditions.md)

## ソース

- [修正結果](../../raw/fixes/20260926T051339Z-pr-3060.md)
