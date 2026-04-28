---
title: "Reviewer rule 自身を編集する PR は self-application false positive を verify する"
domain: "heuristics"
created: "2026-04-28T19:00:00+00:00"
updated: "2026-04-28T19:00:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260428T185933Z-pr-706.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T185144Z-pr-706.md"
tags: ["reviewer-rule", "self-application", "whitelist", "verification"]
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

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #706 cycle 4 final review](../../raw/reviews/20260428T185933Z-pr-706.md)
- [PR #706 fix results (cycle 2/3)](../../raw/fixes/20260428T185144Z-pr-706.md)
