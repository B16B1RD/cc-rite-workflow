---
title: "複数 PR にまたがる incremental 追加履歴を単一 PR に誤集約する (multi-PR provenance aggregation error)"
domain: "anti-patterns"
created: "2026-06-03T08:38:00Z"
updated: "2026-06-03T08:38:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260603T041655Z-pr-1255.md"
  - type: "reviews"
    ref: "raw/reviews/20260603T042748Z-pr-1255.md"
  - type: "fixes"
    ref: "raw/fixes/20260603T042218Z-pr-1255.md"
tags: ["provenance", "attribution", "git-pickaxe", "intra-file-contradiction", "symmetrization-pr"]
confidence: medium
---

# 複数 PR にまたがる incremental 追加履歴を単一 PR に誤集約する (multi-PR provenance aggregation error)

## 概要

対称化 / 要約 PR で「先行 PR が追加したガード・機能の履歴」を散文で要約するとき、**複数 PR にまたがって incremental に追加された項目を単一 PR に誤集約する** failure mode。同一ファイル内の正しい帰属記述と矛盾する intra-file contradiction を生む。git pickaxe (`git log -S '<literal>'`) で各項目の実 introducing commit/PR を特定し、同一ファイル内 cross-reference との突合 + propagation scan (`git grep`) の 3 点で検証する。

## 詳細

### 背景となった起点事例

起点事例 (fingerprint-cycling §4 split に single-invocation 注記と placeholder 表を追加) は §4 ↔ pr/review.md 7.4.2 の対称化シリーズの一環。§4 注記が先行 PR のガード移植履歴を要約する際、以下の LOW finding が cycle 1 で surface した:

- 注記 (L173) が `write/empty/empty-result/empty-url の各 exit 1 ガード (PR #1251 で追加)` (違反文の verbatim 引用) と記載し、**4 ガードすべてを単一 PR に帰属**させていた
- しかし git 履歴上、#1251 (`ad0d85cf`) が追加したのは **3 ガードのみ**。4 つ目の empty-url ガード (`empty_issue_url`) は **#1252 (`0fab5174`) 由来**
- 同一ファイルの L247 が `refs #1252` と **正しく帰属**しており、L173 の誤集約と **intra-file contradiction** を形成していた

教訓: 対称化 PR で先行 PR のガード移植履歴を要約する際、複数 PR にまたがる incremental な追加履歴を単一 PR に誤集約しやすい。集約された数 (4) と各 PR の実追加数 (3 + 1) の差が、同ファイル内の正しい参照と衝突する。

### 検出と修正のメソドロジー

cycle 1 fix で帰属を #1251 (3 ガード) / #1252 (empty-url ガード) に分割して intra-file contradiction を解消。修正前後で以下の git ベース検証を実施した:

1. **git pickaxe で実 provenance を特定**: `git log -S '<guard literal>'` で各ガード (例: `empty_issue_url`) を導入した実 commit を特定する。コミット SHA (`ad0d85cf` = #1251 / `0fab5174` = #1252) と PR 番号を対応づけて、散文の帰属主張を裏取りする
2. **同一ファイル内 cross-reference との突合**: 同じ PR 番号を参照する他の箇所 (L247 の `refs #1252`) が散文の帰属と矛盾しないか確認する。intra-file contradiction は誤集約の決定的な検出シグナル
3. **propagation scan で伝播範囲を確定**: `git grep 'PR #1251'` / `git grep 'PR #1252'` で同種の誤帰属が他箇所に伝播していないかを確認する。起点事例では誤集約が L173 のみに限定され、伝播なしを確認した

cycle 2 の再レビューで両 reviewer (prompt-engineer / code-quality) が git 履歴 (`ad0d85cf` = #1251 / `0fab5174` = #1252) で修正を独立実証検証し、placeholder 表 7 個と §4 bash 実態の完全一致・伝播漏れなしを機械検証して指摘ゼロ・mergeable 到達。multi-PR provenance 誤集約の修正は git pickaxe (`git log -S`) と同一ファイル内 cross-reference の双方で検証可能であることが実測された。

### 適用範囲

- 対称化 / 要約 PR で先行 PR のガード・機能の移植履歴を散文で記述する場合
- 同一機能群が複数 PR にまたがって incremental に追加された経緯を「PR #N で追加」と単一 PR に集約要約する場合
- 散文内の PR 帰属主張が、同一ファイル内の別箇所の PR 参照と数・対象で衝突しうる場合 (intra-file contradiction の検出を優先トリガーにする)

## 関連ページ

- [reviewer の regression 主張は revert test (git show / git diff) で PR 由来か pre-existing かを独立検証する](../heuristics/reviewer-regression-claim-revert-test-attribution.md)
- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](../heuristics/prose-cited-implementation-behavioral-verification.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #1255 review results](../../raw/reviews/20260603T041655Z-pr-1255.md)
- [PR #1255 review results (cycle 2)](../../raw/reviews/20260603T042748Z-pr-1255.md)
- [PR #1255 fix results](../../raw/fixes/20260603T042218Z-pr-1255.md)
