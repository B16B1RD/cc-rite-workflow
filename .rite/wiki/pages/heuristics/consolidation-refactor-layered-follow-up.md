---
type: "heuristics"
title: "統合 refactor の追従は「実行テーブル → SoT/docs → references 例示 → 兄弟行」と層を降りる"
domain: "heuristics"
promote: rite-plugin
description: "レジストリ統合系 refactor の取りこぼしは層構造で現れる。cycle ごとに全域 grep の除外リスト（凍結ファイル・意図的言及）を明示的に引き継ぎ、凍結コピーは successor 注記 + follow-up Issue で一括追従を明記すると、後続 cycle の誤指摘と silent 残存の両方を防げる。"
created: "2026-07-17T12:04:54Z"
updated: "2026-07-17T12:04:54Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260717T110218Z-pr-1891.md"
  - type: "reviews"
    ref: "raw/reviews/20260717T112303Z-pr-1891.md"
  - type: "reviews"
    ref: "raw/reviews/20260717T115736Z-pr-1891.md"
  - type: "fixes"
    ref: "raw/fixes/20260717T110651Z-pr-1891.md"
tags: []
confidence: high
---

# 統合 refactor の追従は「実行テーブル → SoT/docs → references 例示 → 兄弟行」と層を降りる

## 概要

reviewer registry 統合（13→9 種）の PR は 4 cycle で収束し、各 cycle の指摘は毎回異なる「層」に集中した: cycle 1 = 降格アルゴリズムの SoT・周縁 docs（CHANGELOG.ja / CLAUDE.md / SPEC.md）、cycle 2 = references/ 配下の例示・Few-shot 教材・並行コピー、cycle 3 = 同一リスト内の兄弟行の取りこぼし。実行テーブル（選定・spawn）だけを更新して完了と錯覚するのが初期の典型で、修正対象は層をなして降りていく。

## 詳細

- **層の構造**: (0) 実行パスのテーブル（選定・spawn・キーワード検出）→ (1) アルゴリズム SoT（assessment-rules 等の分散列挙）と常時注入 doc（CLAUDE.md の数値）・bilingual CHANGELOG → (2) references/ の例示・Few-shot 教材・SKILL 本文と references の並行コピー → (3) 同一ファイル・同一リスト内の同種ラベル兄弟行。層 N を直した cycle のレビューは層 N+1 を検出する。
- **除外リストの引き継ぎ**: cycle ごとの全域 grep には「凍結ファイル（Non-Target 契約）・CHANGELOG 移行表・Legacy alias 表・successor 注記・歴史記述・media 資産」という意図的残存の除外リストを明示的に引き継ぐ。引き継がないと、後続 cycle の reviewer が追跡済み項目を「凍結対象外」と誤認して再指摘する（実際に cycle 3 で発生し、follow-up Issue 本文という一次証拠で棄却した）。reviewer 間で矛盾する主張（追跡済み vs 対象外）は follow-up Issue 本文を gh issue view で読むことで機械的に解決できる。
- **凍結コピーの扱い**: 分散列挙（Hypothetical 例外カテゴリ等）の可変コピーは PR 内で更新し、凍結コピー（MUST NOT 契約のファイル）は (a) 統合体側に successor 注記を書き、(b) follow-up Issue に「凍結解除時に N 箇所一括追従」（凍結ファイルの列挙 + それを grep するガードテストを含む）と明記して残置する。片側だけ更新するとガードテストが red になるため、一括追従の単位を Issue 本文に書くことが重要。
- **普遍断定の緩和**: 「全 reviewer 共通構造」のような coordinator の普遍断定は、構造の異なる新種（lens ベース profile）を導入した時点で false になる。断定を「A または B」に緩和し、寄稿ガイド（CONTRIBUTING の Adding a New Reviewer）も同時同期する。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [「網羅」を主張する列挙は grep 全数棚卸し + scope note で構造的に収束させる](./exhaustiveness-claims-require-mechanical-inventory.md)

## ソース

- [PR #1891 review results](../../raw/reviews/20260717T110218Z-pr-1891.md)
- [PR #1891 review results (cycle 2)](../../raw/reviews/20260717T112303Z-pr-1891.md)
- [PR #1891 review results (cycle 4, mergeable)](../../raw/reviews/20260717T115736Z-pr-1891.md)
- [PR #1891 fix results](../../raw/fixes/20260717T110651Z-pr-1891.md)
