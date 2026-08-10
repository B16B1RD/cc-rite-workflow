---
type: "patterns"
title: "bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語・新規エントリは number-free に保つ"
domain: "patterns"
description: "CHANGELOG.md / CHANGELOG.ja.md のロケールペアは PR 単位で同時更新するのが確立慣習で、片側のみの更新は cross-file impact（i18n parity）違反として HIGH になる。"
created: "2026-07-17T12:04:54Z"
updated: "2026-07-17T12:04:54Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260717T114250Z-pr-1891.md"
  - type: "fixes"
    ref: "raw/fixes/20260717T110651Z-pr-1891.md"
  - type: "fixes"
    ref: "raw/fixes/20260717T112606Z-pr-1891.md"
tags: []
confidence: high
---

# bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語・新規エントリは number-free に保つ

## 概要

CHANGELOG.md / CHANGELOG.ja.md のロケールペアは PR 単位で同時更新するのが確立慣習で、片側のみの更新は cross-file impact（i18n parity）違反として HIGH になる。訳し方と番号参照にもそれぞれ機械チェックに裏付けられた慣習がある。

## 詳細

- **PR 単位同期**: リリース時のバージョンバンプ commit は `## [Unreleased]` → `## [x.y.z]` の promote のみを行い翻訳はしない。したがって ja エントリは PR 時に書かなければ永続的に欠落する。git log で「CHANGELOG.md に触れた過去 commit が両ファイル同時更新か」を確認すると慣習の実在を検証できる。
- **見出しの言語**: 和訳するのはカテゴリ見出し（`### Changed` → `### 変更`）のみ。バージョン見出し `## [Unreleased]` / `## [x.y.z]` は ja 版でも英語 bracket 形式を維持する。release スクリプトが `-## [Unreleased]` → `+## [x.y.z]` の対称置換を両言語に適用する前提のため、見出しまで訳すと機械処理が非対称に壊れる。
- **number-free の新規エントリ**: 新規 [Unreleased] エントリには `(#NNNN)` を書かず、散文で変更内容と rationale を自己完結させる（number-reference-check が機械検出する）。既存リリース節に残る番号は grandfathered な既存負債で revert test fail（PR scope 外）。「既存エントリも番号付きだから」は反論にならない — check の対象は新規追加行であり、過去の同種対応 PR も [Unreleased] エントリから番号を除去して収束している。

## 関連ページ

- [i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する](../heuristics/i18n-faithful-translation-source-error-accept-followup.md)

## ソース

- [PR #1891 review results (cycle 3)](../../raw/reviews/20260717T114250Z-pr-1891.md)
- [PR #1891 fix results](../../raw/fixes/20260717T110651Z-pr-1891.md)
- [PR #1891 fix results (cycle 2)](../../raw/fixes/20260717T112606Z-pr-1891.md)
