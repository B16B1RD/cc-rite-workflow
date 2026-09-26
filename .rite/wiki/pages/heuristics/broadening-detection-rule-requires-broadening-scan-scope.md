---
type: "heuristics"
title: "検出規則を広げても走査範囲が先頭語限定のままだと同型の取りこぼしが残る"
domain: "heuristics"
description: "複合コマンドの構造検出をセグメント先頭語だけに限定すると、time や coproc のような前置語を伴う構造を取りこぼす。判定基準を広げる際は、走査対象の範囲も同じ粒度に広げる必要がある。"
created: "2026-09-26T14:05:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T14:05:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T134852Z-pr-3147.md"
  - type: "fixes"
    resource: "raw/fixes/20260926T135505Z-pr-3147.md"
tags: []
confidence: high
---

# 検出規則を広げても走査範囲が先頭語限定のままだと同型の取りこぼしが残る

## 概要

複合コマンドの構造検出をセグメント先頭語だけに限定すると、time や coproc のような前置語を伴う構造を取りこぼす。判定基準を広げる際は、走査対象の範囲も同じ粒度に広げる必要がある。

## 詳細

cd を含みうるコマンドを一律 dynamic 扱いにする粗い規則へ置き換えた際、構造（サブシェル・グループ化等）の検出ロジックが「非 nested セグメントの先頭語」だけを見ていたため、time や coproc を前置した複合コマンドで構造ありと判定されず取りこぼしが発生した。

修正では先頭語の特別扱いをやめ、非 nested セグメントのどこかに構造を開く語があるかどうかの照合 1 つに一本化し、coproc も構造語の集合へ追加した。判定範囲を広げたことで既存の commit / merge 判定への影響がないかを、plugin 全体の fenced bash ブロック全件で確認してから適用した。

教訓: 粗い規則を導入・拡張するときは、「何を検出するか」という判定基準だけでなく、「どこを見るか」という走査対象の範囲も同じ粒度に揃える必要がある。走査を先頭語や特定位置に限定したまま判定基準だけ広げると、規則自体は正しくても取りこぼしが生じる。

## 関連ページ

- [ゲートの検査範囲を広げると、それまで skip で素通りしていた呼び出し元も新たに検査対象へ入る](../heuristics/widening-gate-scope-pulls-in-previously-skipped-callers.md)
- [ガードの対象を種別で狭めると、広い対象に付随して効いていた制約が機械的な裏付けを失う](../heuristics/narrowing-guard-scope-drops-incidental-enforcement.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T134852Z-pr-3147.md)
- [修正結果](../../raw/fixes/20260926T135505Z-pr-3147.md)
