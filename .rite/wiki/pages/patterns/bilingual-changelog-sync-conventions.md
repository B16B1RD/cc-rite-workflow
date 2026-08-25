---
type: "patterns"
title: "bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語・新規エントリは number-free に保つ"
domain: "patterns"
description: "CHANGELOG.md / CHANGELOG.ja.md のロケールペアは PR 単位で同時更新するのが確立慣習で、片側のみの更新は cross-file impact（i18n parity）違反として HIGH になる。"
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
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-25T18:26:48Z" }
---

# bilingual CHANGELOG は PR 単位で同期し、バージョン見出しは英語・新規エントリは number-free に保つ

## 概要

CHANGELOG.md / CHANGELOG.ja.md のロケールペアは PR 単位で同時更新するのが確立慣習で、片側のみの更新は cross-file impact（i18n parity）違反として HIGH になる。訳し方と番号参照にもそれぞれ機械チェックに裏付けられた慣習がある。

## 詳細

- **PR 単位同期**: リリース時のバージョンバンプ commit は `## [Unreleased]` → `## [x.y.z]` の promote のみを行い翻訳はしない。したがって ja エントリは PR 時に書かなければ永続的に欠落する。git log で「CHANGELOG.md に触れた過去 commit が両ファイル同時更新か」を確認すると慣習の実在を検証できる。
- **見出しの言語**: 和訳するのはカテゴリ見出し（`### Changed` → `### 変更`）のみ。バージョン見出し `## [Unreleased]` / `## [x.y.z]` は ja 版でも英語 bracket 形式を維持する。release スクリプトが `-## [Unreleased]` → `+## [x.y.z]` の対称置換を両言語に適用する前提のため、見出しまで訳すと機械処理が非対称に壊れる。
- **number-free の新規エントリ**: 新規 [Unreleased] エントリには `(#NNNN)` を書かず、散文で変更内容と rationale を自己完結させる（number-reference-check が機械検出する）。既存リリース節に残る番号は grandfathered な既存負債で revert test fail（PR scope 外）。「既存エントリも番号付きだから」は反論にならない — check の対象は新規追加行であり、過去の同種対応 PR も [Unreleased] エントリから番号を除去して収束している。

- **リリース時に書くエントリの番号は PR 番号ではなく Issue 番号に解決する**: リリース準備でバージョン節を新規に書き起こす経路（`/release` の CHANGELOG テンプレートは `(#{issue_number})` を指定する）では、起点になる `git log --oneline {前タグ}..develop` の各 subject 末尾の番号が squash merge の付けた **PR 番号**である。そのまま転記すると全エントリが PR 番号になり、公開リリースノートの恒久的な参照先が要求元 Issue ではなく実装 PR を指す。`gh pr view {n} --json body` の `Closes #N` で PR→Issue を解決してから書く。番号の種別は `gh pr view {n}` と `gh issue view {n}` のどちらが解決に成功するかで機械的に確定でき、`gh pr view` が `Could not resolve to a PullRequest` を返す番号は Issue である。
- **番号の慣習は 2 経路で食い違っている（未解消）**: 上の「number-free の新規エントリ」は `[Unreleased]` へ PR ごとに書き足す経路の規約で、`number-reference-check.sh` が `CHANGELOG.md` / `CHANGELOG.ja.md` を number-free surface として `DEFAULT_TARGETS` に列挙している。一方リリース時に書き起こす経路は `/release` テンプレートの `(#{issue_number})` に従い番号を書く。実運用は後者に寄っており、`number-reference-check.sh --all` の検出は 322 件（大半が過去リリース節）で規約として機能していない。どちらを canonical にするかは未決着で、決めるまで毎リリースで同じ指摘が再発する。

## 関連ページ

- [i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する](../heuristics/i18n-faithful-translation-source-error-accept-followup.md)
- [Issue 対応案の番号参照を未検証のまま転記すると事実誤認が伝播する](../anti-patterns/unverified-issue-proposal-reference-transcription.md)

## ソース

- [PR #1891 review results (cycle 3)](../../raw/reviews/20260717T114250Z-pr-1891.md)
- [PR #1891 fix results](../../raw/fixes/20260717T110651Z-pr-1891.md)
- [PR #1891 fix results (cycle 2)](../../raw/fixes/20260717T112606Z-pr-1891.md)
- [PR #2364 review results](../../raw/reviews/20260825T182043Z-pr-2364.md)
