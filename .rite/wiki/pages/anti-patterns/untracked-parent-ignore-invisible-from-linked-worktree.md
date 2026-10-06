---
type: "anti-patterns"
title: "親ディレクトリに置いた未追跡の ignore ファイルは linked worktree から見えない"
domain: "anti-patterns"
description: "除外の担保を未追跡の .gitignore で自己完結させると、そのファイルは main checkout にだけ存在する。cwd が linked worktree の検査は同じ構成でも drift と判定する。担保を書く経路が複数あるときも、片方だけに足すともう一方で漏れる。"
created: "2026-10-06T13:40:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-10-06T13:40:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261006T125958Z-pr-3697.md"
  - type: "fixes"
    resource: "raw/fixes/20261006T131105Z-pr-3697.md"
tags: []
confidence: high
---

# 親ディレクトリに置いた未追跡の ignore ファイルは linked worktree から見えない

## 概要

ディレクトリ自身に `*` の `.gitignore` を置く自己完結の除外は、設定ファイルに触らずに済む反面、そのファイルが git に追跡されない。追跡されないファイルは linked worktree の checkout には複製されず、main checkout にだけ実在する。cwd が worktree の検査（lint など）は、同じ構成でも除外が無いと判定して drift を報告する。

## 詳細

- **検査の対象を固定する**: 検査は cwd ではなく state root（main checkout）で行う。同じファイルの別の検査が既に state root を使っているなら、対象を揃える 1 行の変更で済む。代わりに追跡される規則で担保する手もある。
- **作成経路が複数あるとき**: worktree を作る経路が手順書と共有ライブラリの両方にある場合、除外の書き込みを片方に足しただけでは、もう一方（再構築など）で漏れる。経路を洗い出し、ライブラリ側は既存の ensure helper を呼ぶ小さな関数にまとめて、成功経路の直後に全箇所から呼ぶ。
- **手順書の bash ブロックの変数**: 別のブロックで代入された変数に依存する新しい行は、必須変数の検査（`${var:?}`）で空のときの誤書き込み（root への書き込み）を fail-loud にする。

## 関連ページ

- [設定の既定パスを移すときは、旧パスが副次的に担っていた保証を新パスへ引き継ぐ](../heuristics/default-path-move-carries-incidental-guarantees.md)

## ソース

- [除外の担保が worktree から見えないことを指摘したレビュー結果](../../raw/reviews/20261006T125958Z-pr-3697.md)
- [検査対象を揃え再構築経路にも除外を足した fix 結果](../../raw/fixes/20261006T131105Z-pr-3697.md)
