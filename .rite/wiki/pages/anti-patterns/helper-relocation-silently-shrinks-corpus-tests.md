---
type: "anti-patterns"
title: "本文を helper へ移すと、fenced block をコーパスにするテストの検査数が無言で減る"
domain: "anti-patterns"
description: "手順書の bash ブロックを helper へ移設すると、手順書群から fenced block を抽出して検査するテストのコーパスが縮み、検査数が警告なしに減る。件数合わせではなく、減った検査が運んでいた契約を明示ケースとして固定し直す。"
created: "2026-09-28T01:02:34Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T01:02:34Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260928T001746Z-pr-3349.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T003849Z-pr-3349.md"
tags: ["refactor", "test-corpus", "helper-extraction"]
confidence: medium
---

# 本文を helper へ移すと、fenced block をコーパスにするテストの検査数が無言で減る

## 概要

手順書の bash ブロックを helper へ移設すると、手順書群から fenced block を抽出して検査するテストのコーパスが縮み、検査数が警告なしに減る。件数合わせではなく、減った検査が運んでいた契約を明示ケースとして固定し直す。

## 詳細

一部のテストは、手順書（SKILL.md など）から fenced bash block を抽出し、それを入力コーパスとして hook や解析器にかける。ブロックを helper スクリプトへ移すと、そのブロックはコーパスから消える。テストは失敗せず、単に検査数が減るだけなので、移設の PR では気づかれにくい。

気づくための比較にも落とし穴がある。移設前後でテスト出力の件数を比べるとき、集計形式はテストごとに違う（✅ / `PASS: N` / `N checks passed` / `Results:`）。✅ だけを数えると `N checks passed` 形式のテストの減少が集計から漏れる。前後比較はすべての形式を数える。

減った分の戻し方:

- 減った検査が運んでいた契約（例: `^{commit}` の peel を commit と読まない）を特定し、それを明示ケースとして固定する。件数を戻すことが目的ではない。
- helper の関数本体をコーパスに足す案は採らない。hook が実際には解析しない対象を parse するだけで、守る契約を持たない。
- 明示ケースは rc だけでなく「誤読しないこと」まで assert する。元のコーパス検査が rc だけを見ていた場合、明示ケースのほうが強い検出力を持ち、元の検査が見逃していた変異を検出できる。

## 関連ページ

- [インライン処理の helper 抽出は「helper が起動しない」経路を新設し、marker 不在＝成功の消費規則を破る](./helper-extraction-creates-unstarted-path.md)
- [転記の網羅性は件数一致ではなく集合一致で検証する（件数一致は漏れと余剰が相殺して通る）](../heuristics/transcription-completeness-verified-by-set-equality.md)

## ソース

- [レビュー結果](../../raw/reviews/20260928T001746Z-pr-3349.md)
- [fix 結果](../../raw/fixes/20260928T003849Z-pr-3349.md)
