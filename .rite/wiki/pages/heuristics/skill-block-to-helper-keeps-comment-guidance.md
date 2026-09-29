---
type: "heuristics"
title: "SKILL.md のブロックを helper へ移すと、ブロック内コメントの手順情報が LLM から消える"
domain: "heuristics"
description: "SKILL.md の bash ブロックを helper スクリプトへ移すと、ブロック内のコメントとして LLM に見えていた手順情報（再実行の手段、placeholder の出所）が SKILL.md から消える。移設時はコメントの役割を散文に残すか helper の挙動に吸収する。必須化する引数は空値で続行していた正常経路が無いかを確かめ、引数検査の probe テストは拒否理由まで assert する。"
created: "2026-09-29T01:07:27Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T01:07:27Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T004630Z-pr-3349.md"
tags: ["skill", "helper", "refactor", "test"]
confidence: medium
promote: rite-plugin
---

# SKILL.md のブロックを helper へ移すと、ブロック内コメントの手順情報が LLM から消える

## 概要

SKILL.md の bash ブロックを helper スクリプトへ移すと、ブロック内のコメントとして LLM に見えていた手順情報（再実行の手段、placeholder の出所）が SKILL.md から消える。移設時はコメントの役割を散文に残すか helper の挙動に吸収する。必須化する引数は空値で続行していた正常経路が無いかを確かめ、引数検査の probe テストは拒否理由まで assert する。

## 詳細

SKILL.md の fenced bash にあるコメントは、LLM が手順を読むときの情報源でもある。helper へ移すと実行内容は保たれても、`--quiet` を外して再実行する手段や placeholder の出所注記が SKILL.md から消える。移設時は、そのコメントの役割を SKILL.md の散文に残すか、helper の出力や挙動で吸収する。dispatcher で引数を厳格に必須化すると、移設元が空値で best-effort に続行していた経路（Issue 番号を特定できない PR の作業メモリ同期など）が誤停止に変わる。必須にする引数は、空値が文書化済みの正常経路で来ないかを確かめる。引数検査の probe テストは、他の必須引数の不足でも同じ exit code になると何も固定しないので、必須引数を持たないサブコマンドで probe し、stderr の拒否理由まで assert する。

## 関連ページ

- （関連ページなし）

## ソース

- [helper への移設でコメントの手順情報が消えると指摘したレビュー結果](../../raw/reviews/20260929T004630Z-pr-3349.md)
