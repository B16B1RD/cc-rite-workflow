---
type: "heuristics"
title: "権限に依存するテストの前提は euid のような代理条件ではなく os.access で実際に確かめる"
domain: "heuristics"
description: "root や CAP_DAC_OVERRIDE のような権限で成立しない前提を持つテストケースを書くとき、euid が 0 かどうかのような代理条件だけで判定すると、代理条件が実際の可否と一致しない環境で偽の失敗になる。os.access で実際にその操作ができるかを確かめてから加えると、root 環境でも偽の失敗にならない。"
created: "2026-09-26T06:12:43Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T06:12:43Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T060817Z-pr-3060.md"
  - type: "fixes"
    resource: "raw/fixes/20260926T055557Z-pr-3060.md"
tags: ["test", "permission", "environment", "portability"]
confidence: medium
---

# 権限に依存するテストの前提は euid のような代理条件ではなく os.access で実際に確かめる

## 概要

root や CAP_DAC_OVERRIDE のような権限で成立しない前提を持つテストケースを書くとき、euid が 0 かどうかのような代理条件だけで判定すると、代理条件が実際の可否と一致しない環境で偽の失敗になる。os.access で実際にその操作ができるかを確かめてから加えると、root 環境でも偽の失敗にならない。

## 詳細

### 起きたこと

「書き込み禁止のパーミッションでは書き込めない」ことを前提とするテストケースで、前提の成立を euid（実効ユーザ ID）が非 0 かどうかで判定していた。しかし CAP_DAC_OVERRIDE のような capability を持つ環境や root 環境では、euid が 0 でなくても実際には書き込めてしまう、あるいは euid が 0 でも制限がかかる場合があり、代理条件と実際の可否が食い違う。

### なぜ素通りするか

- euid や uid のような代理条件は「典型的な非特権環境」では実際の可否と一致するため、多くの CI 環境では問題が表面化しない
- 実際に権限昇格 capability を持つ環境（コンテナの root 実行、CAP_DAC_OVERRIDE 付与等）でだけ代理条件と実際の可否が乖離する

### やること

1. 権限に依存する前提を持つテストケースでは、euid のような代理条件で分岐せず、`os.access(path, os.W_OK)` のように**実際にその操作が可能かを直接確認**する
2. 確認した結果、前提が成立しない環境ではテストを skip し、成立する環境でだけ実行する
3. 前提の成立を確認するコードは、テスト本体の実行前に明示的に置き、なぜ skip したかをテスト出力に残す

## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](./fixture-mutation-isolates-invariants.md)

## ソース

- [代理条件と実際の可否の乖離を指摘したレビュー結果](../../raw/reviews/20260926T060817Z-pr-3060.md)
- [os.access で前提を確かめるよう修正した fix 結果](../../raw/fixes/20260926T055557Z-pr-3060.md)
