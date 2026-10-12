---
type: "patterns"
title: "bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語、本文には Issue 番号を書いてよい"
domain: "patterns"
description: "CHANGELOG の英日ペアは同一 PR で同時更新し、バージョン見出しは英語の bracket 形式を維持する。本文の Issue 番号はリポジトリ文書として書いてよく、機械チェックの走査面には含めない。"
created: "2026-07-17T12:04:54Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260717T114250Z-pr-1891.md"
  - type: "fixes"
    resource: "raw/fixes/20260717T110651Z-pr-1891.md"
  - type: "fixes"
    resource: "raw/fixes/20260717T112606Z-pr-1891.md"
  - type: "reviews"
    resource: "raw/reviews/20260825T182043Z-pr-2364.md"
  - type: "reviews"
    resource: "raw/reviews/20260825T190409Z-pr-2369.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-25T19:13:44Z" }
---

# bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語、本文には Issue 番号を書いてよい

## 概要

バージョン見出しは ja 版でも英語の bracket 形式を維持する。（英日ペアを PR 単位で同期する運用と、本文に Issue 番号を書いてよいとする運用は現行仕様では廃止: 英日の CHANGELOG はリリース時に両方書き起こし、新規エントリに Issue/PR 番号は書かない。）

## 詳細

- （現行仕様では廃止）**PR 単位同期**: ja エントリを PR 時に書く運用は採らない。リリース準備の CHANGELOG 更新で EN / JA を同時に書き起こす。
- **見出しの言語**: 和訳するのはカテゴリ見出し（`### Changed` → `### 変更`）のみ。バージョン見出し `## [Unreleased]` / `## [x.y.z]` は ja 版でも英語 bracket 形式を維持する。release スクリプトが `-## [Unreleased]` → `+## [x.y.z]` の対称置換を両言語に適用する前提のため、見出しまで訳すと機械処理が非対称に壊れる。
- （現行仕様では廃止）**本文の Issue 番号は書いてよい**: 新規エントリに Issue/PR 番号は書かない（散文のみ、`git log` 末尾の番号も転記しない）。CHANGELOG は `number-reference-check.sh` の `--all` 走査対象に含まれる。

## 関連ページ

- [i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する](../heuristics/i18n-faithful-translation-source-error-accept-followup.md)
- [Issue 対応案の番号参照を未検証のまま転記すると事実誤認が伝播する](../anti-patterns/unverified-issue-proposal-reference-transcription.md)

## ソース

- [レビュー結果](../../raw/reviews/20260717T114250Z-pr-1891.md)
- [fix 結果](../../raw/fixes/20260717T110651Z-pr-1891.md)
- [fix 結果](../../raw/fixes/20260717T112606Z-pr-1891.md)
- [レビュー結果](../../raw/reviews/20260825T182043Z-pr-2364.md)
- [レビュー結果](../../raw/reviews/20260825T190409Z-pr-2369.md)
