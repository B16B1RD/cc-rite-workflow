---
type: "anti-patterns"
title: "git diff の出力形状を前提にしたパーサは、git の設定と変更種別で黙って空振りする"
domain: "anti-patterns"
description: "`+++ b/<path>` の literal prefix 一致だけを入口にした diff パーサは、非 ASCII パス・pure rename・prefix なし設定の 3 条件で対象を 1 件も拾わず、「判定不能」が「未対応」に化ける silent degradation を起こす。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-06T16:10:23Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T125803Z-pr-2582.md"
tags: ["git-diff", "parser", "silent-degradation", "portability"]
confidence: high
---

# git diff の出力形状を前提にしたパーサは、git の設定と変更種別で黙って空振りする

## 概要

`+++ b/<path>` の literal prefix 一致だけを入口にした diff パーサは、非 ASCII パス・pure rename・prefix なし設定の 3 条件で対象を 1 件も拾わず、「判定不能」が「未対応」に化ける silent degradation を起こす。空振りは例外を出さないため、機構は正常動作を名乗ったまま結論だけが反転する。

## 詳細

### 空振りする 3 条件

| 条件 | 出力形状 | 帰結 |
|---|---|---|
| `core.quotePath=true`（既定） | 非 ASCII パスが二重引用符 + 8 進エスケープで出る | literal 一致が外れる |
| pure rename（similarity index 100%） | `+++` 行を 1 つも出さない | 対象ファイルが列挙されない |
| `diff.noprefix=true` | `a/` `b/` prefix が消える | prefix 込みの一致が外れる |

いずれも「その変更が差分に存在しない」ことを意味しない。にもかかわらず、存在しないものとして扱う実装では、差分の有無を根拠にする判定（対応済み / 未対応、検査済み / 未検査）が反転する。

### 検出の手がかり

同一リポジトリの先行パーサが unquote 処理と条件付き prefix 剥がしを既に持っているのに、新規パーサがそれを継承していない — この非対称が目印になる。既存パーサが持つ正規化は、過去に同じ穴を踏んだ結果として足されていることが多く、新規実装が素の literal 一致で始まると同じ穴を再生産する。

### 書き方

- ファイル名の取得は `git diff --name-only -z`（NUL 区切り・quote なし）など、形状が設定に依存しない経路を使う
- 形状に依存する経路を選ぶなら、unquote と prefix 剥がしを入口に置き、rename を別経路で拾う
- 「1 件も拾えなかった」を成功ではなく判定不能として扱い、fail-loud にする

## 関連ページ

- [変数名の字句解析に依存した prefix 導出は壊れる](../patterns/bash-variable-name-lexing-defeats-prefix-derivation-regex.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T125803Z-pr-2582.md)
