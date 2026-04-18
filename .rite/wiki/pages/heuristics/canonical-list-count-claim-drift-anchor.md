---
title: "新規 exit 1 経路追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する"
domain: "heuristics"
created: "2026-04-18T12:50:00+00:00"
updated: "2026-04-18T12:50:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T123408Z-pr-579.md"
  - type: "reviews"
    ref: "raw/reviews/20260418T124111Z-pr-579.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T123555Z-pr-579.md"
tags: []
confidence: high
---

# 新規 exit 1 経路追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する

## 概要

bash block に新規 `exit 1` fail-fast 経路を追加する PR は、同一ファイル内の 2 種の canonical SoT 一覧 (`9.3 exit code` 節の例外リスト / エラーハンドリング表) を **必ず同時更新** する義務を負う。また、コメント内の「5 site 対称化」「N site で同型」のような連番 counter 宣言は、canonical 一覧と実装の drift 検出アンカーとして機能し、`grep` で「counter 宣言 vs 実登録数」の gap を検出可能にする。

## 詳細

### 失敗モード (PR #579 cycle 2 で実測)

PR #579 cycle 1 で placeholder residue gate を 6 site 目として追加した際、cross-validation cycle 2 review で 2 件の MEDIUM 同期漏れが検出された:

- **F-04**: `9.3 exit code` 節の「例外 (`exit 1` fail-fast)」リストに新規 gate の該当行を追加し忘れ
- **F-05**: エラーハンドリング表 (エラー / 対処 / Phase 列) に同 gate の対応行を追加し忘れ

これらは drift 防止用の SoT (Single Source of Truth) 一覧であり、片方だけの更新は「文書化されていない `exit 1` 経路」に読者が遭遇する regression を生む。

### Canonical rule

新規 `exit 1` fail-fast 経路を bash block に追加する PR は、同一ファイル内の以下 2 つの canonical SoT 一覧を **必ず同時更新** する:

1. `9.3 exit code` 節の「例外 (`exit 1` fail-fast)」リスト
2. エラーハンドリング表 (列: エラー / 対処 / Phase)

### 『N site 対称化』counter を drift 検出アンカーとして活用 (PR #579 cycle 3 final heuristic)

コメント内の「既存 5 site と対称化」「N site で同型」「DRIFT-CHECK ANCHOR: N 箇所 explicit sync」のような連番 counter 宣言は、意図しない副作用として drift 検出アンカーの役割を果たす:

- 新規 site が追加された時、counter が `5 → 6` に update されているかを `grep` で機械検証可能
- reviewer が「カウント宣言 vs 実登録数」の gap を grep で検出できる
- 将来の reader が canonical 一覧の網羅性を counter から逆算可能

### scope 外 drift の扱い

cycle 3 final レビューで「両 reviewer が cross-validation で一致指摘した pre-existing drift」が検出された場合、本 PR scope 外として `AskUserQuestion` で別 Issue 化するのが正規経路 (PR #579 で Issue #580 として切り出し済み)。review サイクルで scope 外修正を混ぜ込むと PR diff が膨張し review gate 失敗の原因となる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)

## ソース

- [PR #579 review results (cycle 2)](../../raw/reviews/20260418T123408Z-pr-579.md)
- [PR #579 review results (cycle 3 final)](../../raw/reviews/20260418T124111Z-pr-579.md)
- [PR #579 fix results (cycle 2)](../../raw/fixes/20260418T123555Z-pr-579.md)
