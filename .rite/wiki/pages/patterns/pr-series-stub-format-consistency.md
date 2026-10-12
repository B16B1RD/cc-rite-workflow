---
title: "PR シリーズ間で stub 残置 markdown formatting を踏襲する"
domain: "patterns"
description: "PR シリーズで複数 references を順次抽出する場合、最初の PR で確立された stub 残置 markdown formatting (`> **Moved (Issue #N PR M/T)**:` 形式) を新規 reference 抽出時にも踏襲することで、保守者が `git grep` で stub 一覧を機械検索できる traceability を維持する。"
created: "2026-05-04T05:30:00+00:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260504T051358Z-pr-802-cycle2.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-08T13:37:28Z" }
---

# PR シリーズ間で stub 残置 markdown formatting を踏襲する

## 概要

（現行仕様では廃止: 本ページの stub 形式 `Moved (Issue/PR 番号 M/T)` は、Issue / PR 番号を永続成果物に書かない原則に反し、`commands/` も廃止されて plugin 内に当該形式の stub は存在しない。）

## 詳細

（現行仕様では廃止: 上記のとおり。）

## 関連ページ

- （関連ページなし）

## ソース

- [cosmetic fix](../../raw/fixes/20260504T051358Z-pr-802-cycle2.md)
