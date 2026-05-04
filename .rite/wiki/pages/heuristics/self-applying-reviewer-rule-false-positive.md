---
title: "Reviewer rule 自身を編集する PR は self-application false positive を verify する"
domain: "heuristics"
created: "2026-04-28T19:00:00+00:00"
updated: "2026-05-04T03:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260428T185933Z-pr-706.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T185144Z-pr-706.md"
  - type: "fixes"
    ref: "raw/fixes/20260504T030513Z-pr-800-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260504T030800Z-pr-800-cycle4.md"
tags: ["reviewer-rule", "self-application", "whitelist", "verification", "cross-check"]
confidence: high
---

# Reviewer rule 自身を編集する PR は self-application false positive を verify する

## 概要

reviewer rule (`tech-writer.md` / `_reviewer-base.md` 等) を編集する PR では、reviewer (a) が rule 文書内の例示・禁止語例 (`verified-review` / `cycle N F-Y で確立` 等) を **rule 文書自身に対して self-application** する false positive リスクが発生する。SoT Whitelist との cross-reference を Verification 手順に明示組み込みすることで根本解決。今後の reviewer rule 系 PR では self-application false positive を必ず check する canonical 対策。

## 詳細

### 失敗モード

PR #706 cycle 2 で F-03 (HIGH) として顕在化。`tech-writer.md` の Detection Checklist 6 番目で `verified-review cycle X` を「ジャーナルコメント禁止語例」として例示しつつ、同じ文書内で過去レビュー履歴を参照する `verified-review cycle N F-Y で確立` のような表現を **論理的に許容** する文脈で使用していた。reviewer がこの rule を **rule 文書自身** に適用すると、禁止語例の literal 出現を全て finding として検出する false positive 経路が成立する。

self-application false positive は以下の構造で発生する:

1. reviewer rule が「禁止語 X」を文書内に literal 例示
2. SoT Whitelist が「文脈 Y では X を許容」と直交する原則で許容
3. reviewer の Verification 手順が SoT Whitelist 適用順序を明示組み込みしていない
4. reviewer LLM が rule 文書を scan し、禁止語例を片方の原則のみで判定 → false positive

### 検出手段

- reviewer rule を編集する PR では、cycle 1 の reviewer 実行ログで rule 文書自体が finding 対象に含まれているかを確認 (`grep -F 'tech-writer.md' review-results/*.json` 等)
- rule 文書内の禁止語例 / 許容語例の出現箇所を grep し、両原則 (禁止と Whitelist) の cross-reference が prose で明示されているか確認
- self-application が発生する具体例 (rule 文書を rule で評価するシナリオ) を Verification 手順に test case として埋め込む

### Canonical 対策

1. **Whitelist 適用順序の明示組み込み**: reviewer rule の Verification 手順に「Grep で検出 → Whitelist 適用順序で許容判定をパスしたトークンを除外 → 残りを finding 発行」と明示。暗黙の前提では rite plugin self-application で false positive が発生する経路が残る。
2. **禁止語例 / 許容語例の cross-reference**: SoT 原則 (例: 原則 2 `no_journal_comment`) と Whitelist のような直交する原則を同一 reviewer rule で扱う場合、両者の cross-reference を prose で明示。
3. **Self-apply 閉ループ test**: reviewer rule を編集する PR の test plan に「reviewer (a) を rule 文書自身に適用して false positive 件数を測定」を追加し、5 件未満を gate 条件とする。
4. **Scope 内 / 外の分離判断**: cycle 2 で fix-introduced ではない pre-existing 見落としが検出された場合、HIGH のみ scope 内修正、MEDIUM 以下は別 Issue 化することで cycle 数を 4 に抑えて収束させる canonical pattern (PR #706 で実証)。

### 拡張: 履歴解説 reference の指摘を actual code との cross-check なしに fix すると regression を誘発する (PR #800 cycle 2-4 で実証)

PR #800 cycle 2 で reviewer (prompt-engineer) が `regression-history.md` の「事実関係ズレ」を MEDIUM 指摘し、`informational 寄り、PR 7-8 で対応可` と recommendation を付した。ユーザー判断で本 PR 内で 1 行 fix を選択したところ、cycle 3 で 2 reviewer (prompt-engineer + code-quality) が独立に「fix が SoT-aligned だった元 wording を壊した」と検出。cycle 4 で revert して mergeable 収束 (累計 4 cycle、CRITICAL revert 1 件)。

**根本原因**: reviewer 指摘の「事実関係ズレ」自体が **false positive** で、cycle 1 の元 wording は実装 code (cleanup.md / wiki/ingest.md の Phase 番号) と完全一致していた。reviewer LLM が prose 上の表現を「歴史記録としての正しさ」基準で評価し、実装 code との一致 (= SoT-aligned) を見落とした false positive 経路。

**Self-applying false positive との共通構造**: 本ページが扱う「reviewer rule 文書を rule で評価して false positive」と、本拡張の「履歴解説 reference を実装契約と切り離して評価して false positive」は同じ構造:

1. reviewer LLM が判定対象の context (rule 文書 / 履歴解説) を **狭い文脈で評価** する
2. SoT (実装 code / 既存実装契約) との cross-reference が prompt に組み込まれていない
3. reviewer の指摘を actual code との cross-check なしに採択 → 正しい記述を壊す regression

**Canonical 対策の汎化** (PR #800 cycle 3 で確立):

1. **「履歴解説」「事実関係」系の MEDIUM/LOW finding は採択前に actual code grep を必須化**: reviewer 指摘の対象 prose が参照する実装 (例: `Phase 5.X` 番号、`script.sh` の rc=N、`function-name`) を grep で確認し、prose 表現と実装契約が完全一致している場合は reviewer 指摘を `[fix:replied-only]` 扱いとする
2. **"textually fixed ≠ semantically correct"**: reviewer の literal wording 修正は意味論的整合性を保証しない。修正前後の wording が **どちらも同じ実装契約を正確に反映している** 場合、wording 改変は regression リスクの方が大きい
3. **revert は早い段階で**: 同 finding が 2 reviewer 独立検出された場合は cycle 4 までに revert する。revert 後の re-review で 0 findings になることが「元 wording が SoT-aligned だった」ことの decisive evidence

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重する](./respect-reviewer-no-action-recommendation.md)

## ソース

- [PR #706 cycle 4 final review](../../raw/reviews/20260428T185933Z-pr-706.md)
- [PR #706 fix results (cycle 2/3)](../../raw/fixes/20260428T185144Z-pr-706.md)
- [PR #800 cycle 3 fix (CRITICAL revert: 履歴解説 wording を SoT-aligned に戻し)](../../raw/fixes/20260504T030513Z-pr-800-cycle3.md)
- [PR #800 cycle 4 review (mergeable, revert で 0 findings 達成)](../../raw/reviews/20260504T030800Z-pr-800-cycle4.md)
