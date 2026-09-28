---
type: "patterns"
title: "テストで「同じ行」を固定するなら行単位で判定し、否定条件は肯定側と同じ述語の否定で書く"
domain: "patterns"
description: "bash の [[ \"$out\" == *A*B* ]] は glob の * が改行をまたぐため、A と B が同じ行にあることを固定しない。行単位の判定は awk の index で書く。失敗時だけ出す通知は、成功経路のテストで stdout を受け取り、肯定側と同じ述語の否定を条件にして「出ていない」ことを固定する。否定条件を文言リテラルで書くと、文言の変更で黙って空振りになる。"
created: "2026-09-28T12:36:22Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T12:36:22Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260928T115704Z-pr-3397.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T121202Z-pr-3397.md"
tags: []
confidence: high
---

# テストで「同じ行」を固定するなら行単位で判定し、否定条件は肯定側と同じ述語の否定で書く

## 概要

bash の `[[ "$out" == *A*B* ]]` は glob の `*` が改行をまたぐため、A と B が同じ行にあることを固定しない。行単位の判定は awk の index で書く。失敗時だけ出す通知は、成功経路のテストで stdout を受け取り、肯定側と同じ述語の否定を条件にして「出ていない」ことを固定する。否定条件を文言リテラルで書くと、文言の変更で黙って空振りになる。

## 詳細

**行単位の判定**: `[[ "$out" == *"$a"*"$b"* ]]` は、A の行と B の行が離れていても真になる。同じ行を固定したいときは `awk -v p="$a" -v q="$b" 'index($0,p) && index($0,q)'` のように行ごとに判定する。`grep | grep -q` は pipefail 下で上流の SIGPIPE が混ざり、lint にも掛かるので使わない。

**成功経路にも否定条件を持たせる**: 失敗時だけ出す通知は、成功経路のテストが stdout を捨てていると、成功時にも出てしまう退行を検出できない。成功経路のテストで stdout を受け取り、通知が無いことを条件に加える。

**否定は肯定と同じ述語で書く**: 否定条件を通知の文言リテラルで書くと、そのリテラルを肯定側で固定するテストが無い限り、文言の変更で黙って空振りになる。肯定側と同じ述語（例: 同じ行に state のパスと `/rite:recover` がある）の否定で書く。

**fail メッセージに判定材料を出す**: 否定条件を連言に足したら、fail メッセージにもその判定材料（stdout）を出す。出さないと、落ちたときに表示値がすべて正常に見えて原因が読めない。

**効果は mutation で確かめる**: 強化した pin は、生き残っていた mutant が修正後に FAIL することを確かめてから commit する。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)

## ソース

- [fix 結果](../../raw/fixes/20260928T115704Z-pr-3397.md)
- [レビュー結果](../../raw/reviews/20260928T121202Z-pr-3397.md)
