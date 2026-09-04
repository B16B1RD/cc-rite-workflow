---
type: "anti-patterns"
title: "ゲートの判定基準を被検査側が選べると検査は自己無効化する"
domain: "anti-patterns"
description: "委譲先のラベルがパス除外にも使われるとき、呼び出し側が検査対象のパスをラベルに渡すと、内容に問題があっても無条件 clean が返る。判定基準はゲートされる側が選べない値（未 commit 差分など）から取る。"
created: "2026-09-04T13:54:13Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-04T13:54:13Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260904T091303Z-pr-2549.md"
  - type: "fixes"
    resource: "raw/fixes/20260904T092650Z-pr-2549.md"
tags: [skill-authoring, gate, self-invalidating-check]
confidence: high
promote: rite-plugin
---

# ゲートの判定基準を被検査側が選べると検査は自己無効化する

## 概要

委譲先のラベルがパス除外にも使われるとき、呼び出し側が検査対象のパスをラベルに渡すと、内容に問題があっても無条件 clean が返る。判定基準はゲートされる側が選べない値（未 commit 差分など）から取る。

## 詳細

番号参照検査を helper へ委譲したゲートで、呼び出し側が `--label` に raw のパスを渡していた。helper はそのラベルをパス除外判定にも使うため、検査対象そのものが除外集合に入り、内容に番号があっても無条件 clean が返った。ゲートの判定基準を、ゲートされる側（呼び出し側 LLM）が選べる値に取った形である。

対象を git の未 commit 差分から取るように変えると、呼び出し側がラベルやパス一覧を組み立てる必要がなくなり、この自己無効化は消える。判定対象・実行対象・承認文言が同じ木を見る、という既存の分類器規約と同型で、ここでは「除外集合」が判定対象になっている。

新しいゲートの引数を決めるとき、その値が (1) 走査対象の列挙、(2) 除外、(3) 成功/失敗の解釈、のいずれかに使われないかを先に見る。使われるなら、その値を呼び出し側が選べる形で渡してはならない。

## 関連ページ

- [ゲートに検査を足すより、実行者が選べる自由度を削る](../heuristics/reduce-gate-degrees-of-freedom.md)
- [破壊的操作を承認する分類器は判定・実行・承認文言が同じ対象を見ることを保証する](../heuristics/classifier-destructive-action-same-tree-alignment.md)
- [Canonical helper bypass: 既存集約 helper を bypass して inline 再実装する](./canonical-helper-bypass.md)

## ソース

- [レビュー結果](../../raw/reviews/20260904T091303Z-pr-2549.md)
- [fix 結果](../../raw/fixes/20260904T092650Z-pr-2549.md)
