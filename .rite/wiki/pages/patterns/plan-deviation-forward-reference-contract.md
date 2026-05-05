---
title: "計画変更時の前方参照契約"
domain: "patterns"
created: "2026-05-05T11:15:55+00:00"
updated: "2026-05-05T11:15:55+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260505T105152Z-pr-837.md"
  - type: "fixes"
    ref: "raw/fixes/20260505T105459Z-pr-837.md"
tags: []
confidence: high
---

# 計画変更時の前方参照契約

## 概要

評価レポート / 設計ドキュメントで「リスク緩和策」「Implementation 計画」を上方に書いた後、下方の「実施報告」「結果セクション」で計画逸脱 (一部未実施) が開示される構造では、リスク表 / 計画表側に **前方参照** (forward reference) を必ず追加する。前方参照を欠落させると、top-down reader が「計画通り実施された」と誤読し、内部矛盾が silent に流入する。

## 詳細

### 発生構造

1. ドキュメント前半で「リスク緩和策として施策 S3+S4 を同一 commit で実施」と claim する (planning 時点の意図)
2. ドキュメント後半で「S3/S4 は本 PR では未実施 (理由: cycle 数 risk)」と開示する (実施結果)
3. 前半の claim には後半への前方参照がないため、前半だけ読んだ reader は施策が実施されたと誤認する

PR #837 で評価レポート Section 7 (リスク緩和策) が `S3+S4 を同一 commit で実施` と claim し、Section 9.3 で `S3/S4 は未実施` と開示。tech-writer reviewer が LOW (内部矛盾) として検出した。リスク自体は実体化しなかったが、disclosure 順序として bottom-up でしか整合性が取れない構造。

### 解決パターン (PR #837 cycle 1 fix)

- **計画逸脱発生時はリスク表 / 計画表に前方参照を追加**: 例 `(注: 本 PR では未実施。理由は Section 9.3 を参照)`
- **計画変更時の前方参照契約を canonical 化**: 設計ドキュメントテンプレート / レビュー基準に「計画 vs 実施が divergence した場合、計画側 Section に前方参照を入れる」を明文化する
- **前方参照の対象は 3 site**: リスク表 (リスク緩和策の claim) / Implementation 表 (work item 列挙) / 結果セクション (実施報告) の 3 site すべてに前方参照を貼ることで、どの Section から読んでも整合性が保たれる

### 検出手段

- review 時に「計画 (上方) と実施 (下方) で claim が異なるか」を機械的に検査する。`grep -A 3 -i 'リスク\|計画\|実施'` 等で対応するセクションを抽出し、cross-reference の有無を確認
- 計画逸脱が PR 中で発生した場合、PR description / commit message にも明示する (ドキュメント側 + version control 側の両方で disclosure)

### 適用範囲

本パターンは評価レポート系ドキュメントだけでなく、以下の文書クラスにも適用する:

- 設計仕様書 (`docs/designs/*.md`) で FR (Functional Requirement) status が変更された場合
- PR description で「Test plan」と「実施結果」が divergence した場合
- 中長期 roadmap で「Q3 実施予定」と claim した item が Q4 にずれ込んだ場合

## 関連ページ

- [並列 Section 展開時の同名 heading 重複](../anti-patterns/parallel-section-same-heading-duplicate.md)
- [AC anchor / prose / コード emit 順は drift 検出 lint で 3 者同期する](./drift-check-anchor-prose-code-sync.md)

## ソース

- [PR #837 cycle 1 review (前方参照欠落 LOW 検出)](../../raw/reviews/20260505T105152Z-pr-837.md)
- [PR #837 fix (前方参照契約の canonical 化)](../../raw/fixes/20260505T105459Z-pr-837.md)
