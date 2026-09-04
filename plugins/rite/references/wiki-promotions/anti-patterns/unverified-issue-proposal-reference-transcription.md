---
type: "anti-patterns"
title: "Issue 対応案の番号参照を未検証のまま転記すると事実誤認が伝播する"
domain: "anti-patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/anti-patterns/unverified-issue-proposal-reference-transcription.md"
created: "2026-06-09T19:40:00+00:00"
updated: "2026-06-09T19:40:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260609T191537Z-pr-1325.md"
  - type: "fixes"
    ref: "raw/fixes/20260609T191759Z-pr-1325.md"
  - type: "reviews"
    ref: "raw/reviews/20260609T192157Z-pr-1325.md"
tags: []
confidence: high
---

# Issue 対応案の番号参照を未検証のまま転記すると事実誤認が伝播する

## 概要

Issue body の対応案文字列を成果物にそのまま転記すると、対応案自体に含まれる事実誤認（Issue 番号を PR とラベルする等の参照種別の取り違え）がドキュメントへ伝播する。番号参照は転記前に `gh issue view` / `gh pr view` で種別を実機検証し、repo 既存記法（` (実装:)` 形式）と整合させること。

## 詳細

起点事例（docs archive 注記追加、1 行変更）で実測されたサイクル:

- **発生経路**: Issue の対応案に書かれた参照種別ラベルを実装時に verbatim 転記したが、実体は Issue と PR が混在しておりラベルが誤っていた。stale reference を是正する変更自体が二次的な不正確参照を導入した。
- **検出**: tech-writer（Doc-Heavy mode）と code-quality の 2 reviewer が独立に同一 file:line で検出し High Confidence 統合（HIGH 1 件）。`gh pr view 1088` が "Could not resolve to a PullRequest" を返すことが決定打。
- **修正**: repo 既存記法（`docs/SPEC.md`「、実装: 」/ `references/issue-create-with-projects.md` / `SKILL.md` の 5+ 箇所と同型）に合わせ `(で機構撤去 (実装:)、start.md 自体も で削除済)` へ正規化。cycle 2 で 0 findings、2 cycle で mergeable 収束。
- **検証手法**: ① `gh issue view {number}` / `gh pr view {number}` による参照種別の実機照合、② 既存記法箇所との Grep 突合で対称箇所の残存ゼロ確認。
- **副次教訓**: 同一行編集のついでに非ブロッキングのスペーシング推奨（セル末尾 ` |`）も適用し、追加 cycle を発生させなかった（同一行の nit は fix に同梱して cycle 数を抑える）。

防止策: Issue 対応案・レビューコメント・過去ドキュメント等の「転記元テキスト」に含まれる番号参照（`#NNNN` / `PR #NNNN` / `Issue #NNNN`）は、転記時に種別・状態を gh CLI で検証してから書く。転記元の権威性（Issue 起票者が書いた対応案）は事実正確性を保証しない。

## 関連ページ

- fix コメント / commit message で hallucinated canonical reference を生成する (`Wiki provenance: ./hallucinated-canonical-reference.md`)
- Asymmetric Fix Transcription (対称位置への伝播漏れ) (`Wiki provenance: ./asymmetric-fix-transcription.md`)

## ソース

- Review results (`Wiki provenance: ../../raw/reviews/20260609T191537Z-pr-1325.md`)
- Fix results (`Wiki provenance: ../../raw/fixes/20260609T191759Z-pr-1325.md`)
- Review results (cycle 2) (`Wiki provenance: ../../raw/reviews/20260609T192157Z-pr-1325.md`)
