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

CHANGELOG の英日ペアは同一 PR で同時更新し、バージョン見出しは英語の bracket 形式を維持する。本文の Issue 番号はリポジトリ文書として書いてよく、機械チェックの走査面には含めない。

## 詳細

- **PR 単位同期**: リリース時のバージョンバンプ commit は `## [Unreleased]` → `## [x.y.z]` の promote のみを行い翻訳はしない。したがって ja エントリは PR 時に書かなければ永続的に欠落する。git log で「CHANGELOG.md に触れた過去 commit が両ファイル同時更新か」を確認すると慣習の実在を検証できる。
- **見出しの言語**: 和訳するのはカテゴリ見出し（`### Changed` → `### 変更`）のみ。バージョン見出し `## [Unreleased]` / `## [x.y.z]` は ja 版でも英語 bracket 形式を維持する。release スクリプトが `-## [Unreleased]` → `+## [x.y.z]` の対称置換を両言語に適用する前提のため、見出しまで訳すと機械処理が非対称に壊れる。
- **本文の Issue 番号は書いてよい**: CHANGELOG はマーケットプレイス配布物ではなくリポジトリ文書なので、番号-free 面（配布先だけで完結する文書）の対象外である。`number-reference-check.sh` の既定走査面から CHANGELOG を外し、全ファイル走査でも CHANGELOG 上の番号を報告しない。過去リリース節に既にある番号は負債ではなく、この方針と一致する。
- **リリース時に書くエントリの番号は PR 番号ではなく Issue 番号に解決する**: リリース準備でバージョン節を新規に書き起こす経路（`/release` の CHANGELOG テンプレートは Issue 番号プレースホルダを指定する）では、起点になる `git log --oneline {前タグ}..develop` の各 subject 末尾の番号が squash merge の付けた **PR 番号**である。そのまま転記すると全エントリが PR 番号になり、公開リリースノートの恒久的な参照先が要求元 Issue ではなく実装 PR を指す。`gh pr view {n} --json body` の `Closes #N` で PR→Issue を解決してから書く。番号の種別は `gh pr view {n}` と `gh issue view {n}` のどちらが解決に成功するかで機械的に確定でき、`gh pr view` が `Could not resolve to a PullRequest` を返す番号は Issue である。
- **書く側と走査面の食い違いは決着済み**: かつては `[Unreleased]` 追記経路が number-free、リリース書き起こし経路が番号あり、で規約が割れていた。canonical は「CHANGELOG に番号を書く」側。走査面から外すことで機械検出が方針と逆向きに 322 件を積む状態を止めた。lint スキルの個別注記と仕様書の旧記述は対象外。

## 関連ページ

- [i18n 同期 PR の忠実翻訳は原本の誤りを転写する — 検出時は accept + 両側同時修正 follow-up で決着する](../heuristics/i18n-faithful-translation-source-error-accept-followup.md)
- [Issue 対応案の番号参照を未検証のまま転記すると事実誤認が伝播する](../anti-patterns/unverified-issue-proposal-reference-transcription.md)

## ソース

- [PR #1891 review results (cycle 3)](../../raw/reviews/20260717T114250Z-pr-1891.md)
- [PR #1891 fix results](../../raw/fixes/20260717T110651Z-pr-1891.md)
- [PR #1891 fix results (cycle 2)](../../raw/fixes/20260717T112606Z-pr-1891.md)
- [PR #2364 review results](../../raw/reviews/20260825T182043Z-pr-2364.md)
- [PR #2369 review results](../../raw/reviews/20260825T190409Z-pr-2369.md)
