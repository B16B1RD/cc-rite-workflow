---
type: "heuristics"
title: "同一指摘が複数 Issue に分かれたら対応 PR は該当する全 Issue を Closes で列挙する"
domain: "heuristics"
description: "レビュー由来の指摘は単独 Issue と follow-up Issue（同じ PR の残存指摘の集約）の 2 経路で起票されうる。対応 PR が片方だけを Closes すると、もう片方は実装済みのまま open で残り孤児化する。timeline に cross-reference が無い Issue は close スキルも関連 PR を検出できないため、PR 本文で該当する全 Issue を Closes で列挙する。"
created: "2026-09-11T10:18:45Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-11T10:18:45Z" }
sources:
  - type: "retrospectives"
    resource: "raw/retrospectives/20260911T093543Z-issue-2646.md"
tags: []
confidence: medium
promote: rite-plugin
---

# 同一指摘が複数 Issue に分かれたら対応 PR は該当する全 Issue を Closes で列挙する

## 概要

レビュー由来の指摘は単独 Issue と follow-up Issue（同じ PR の残存指摘の集約）の 2 経路で起票されうる。対応 PR が片方だけを Closes すると、もう片方は実装済みのまま open で残り孤児化する。timeline に cross-reference が無い Issue は close スキルも関連 PR を検出できないため、PR 本文で該当する全 Issue を Closes で列挙する。

## 詳細

test-coverage の指摘が、レビュー中のトリアージで単独 Issue として起票され、同時にマージ時の残存非実測指摘の集約として follow-up Issue にも含まれた。対応 PR は follow-up Issue だけを Closes したため、単独 Issue は実装が完了していながら open のまま残った。

- **孤児化の帰結**: 単独 Issue の timeline には対応 PR の cross-reference が付かない。close スキルは timeline から関連 PR を探すため、実装済みであることを機械的に検出できず、人間が気付いて手動クローズするまで残る
- **原因は起票経路の重複**: レビューのトリアージ（別 Issue 作成）とマージ時の follow-up 集約は独立に動く。同じ指摘が両方に載ることは設計上ありうるため、起票側で重複を防ぐより、対応側で「この PR が解消する指摘に紐づく Issue はどれか」を全件列挙するほうが確実に閉じる
- **対処**: PR を作る前に、対応する指摘の `file:line` と説明で open Issue を検索し、同じ指摘を扱う Issue をすべて `Closes #N` に列挙する。既に片方だけで merge 済みなら、残った Issue は追加作業なしで手動クローズし、コメントで対応 PR を参照して timeline に cross-reference を残す

## 関連ページ

- [verification-only な残作業 Issue は PR パイプラインを経由せず issue-close で直接検証する](./verification-only-residual-task-direct-close.md)

## ソース

- [close retrospective](../../raw/retrospectives/20260911T093543Z-issue-2646.md)
