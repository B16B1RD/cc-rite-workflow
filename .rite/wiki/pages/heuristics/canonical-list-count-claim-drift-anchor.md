---
title: "新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する"
domain: "heuristics"
created: "2026-04-18T12:50:00+00:00"
updated: "2026-04-19T05:48:50Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T123408Z-pr-579.md"
  - type: "reviews"
    ref: "raw/reviews/20260418T124111Z-pr-579.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T123555Z-pr-579.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T004413Z-pr-585.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T004921Z-pr-585.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T050601Z-pr-590.md"
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

cycle 3 final レビューで「両 reviewer が cross-validation で一致指摘した pre-existing drift」が検出された場合、本 PR scope 外として `AskUserQuestion` で別 Issue 化するのが正規経路 (PR #579 で Issue #580 として切り出し済み、PR #590 で解消)。review サイクルで scope 外修正を混ぜ込むと PR diff が膨張し review gate 失敗の原因となる。

### scope 外 drift の後続 PR による解消ループ (PR #590 で実証)

PR #579 で Issue 化された pre-existing drift (`lint.md` L1371 の「5 site 対称化」宣言と canonical 一覧の登録 3 site の gap) は、PR #590 で 2 canonical 一覧 (9.3 exit code 節 + エラーハンドリング表) への Phase 6.2 / 8.3 placeholder gate 追記 (+4 lines / 1 file) で解消された。+4 lines / 2 reviewer (prompt-engineer + code-quality) 0 findings 承認 / re-review 不要という minimal cycle で完了しており、「scope 外 drift → 別 Issue 化 → 後続 PR で解消」フローが (a) review cycle 膨張の回避、(b) drift 恒久化の防止、両方を同時に達成する canonical 経路であることを実証した。

### 拡張: sentinel type enum 同期義務 (PR #585 で一般化)

PR #585 では `workflow_incident` sentinel の新規 type (`gitignore_drift`) を追加した際に、以下 2 つの enum SoT 一覧を同期すべきだが初版で欠落していた:

1. `docs/SPEC.md` / `docs/SPEC.ja.md` の sentinel type 一覧
2. `references/workflow-incident-emit-protocol.md` の type enum 列挙

新規 sentinel type を `workflow-incident-emit.sh` の `case "$TYPE"` に追加する PR は、上記 2 つの canonical 一覧 + 関連する detection-scope 表 (例: `issue/start.md` Phase 5.4.4.1) を **同一 PR で同期更新** する義務を負う。enum drift は skill writer (LLM) が「未登録の sentinel は発火しない」と silent に誤動作する根本原因になる。

canonical rule の汎化 (本ページの header title も拡張):

- 新規 `exit 1` 経路、新規 sentinel type、新規 incident type enum、新規 fail-fast gate のいずれを追加する PR も、同一ファイル内 / cross-file の canonical SoT 一覧を同期更新する義務を負う
- enum / 例外リスト / エラーハンドリング表は SoT の二重管理であり、片方だけの更新は silent drift
- 「N type 同期」「N entry 登録」counter 宣言を同期アンカーとして活用する

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)

## ソース

- [PR #579 review results (cycle 2)](../../raw/reviews/20260418T123408Z-pr-579.md)
- [PR #579 review results (cycle 3 final)](../../raw/reviews/20260418T124111Z-pr-579.md)
- [PR #579 fix results (cycle 2)](../../raw/fixes/20260418T123555Z-pr-579.md)
- [PR #585 review results](../../raw/reviews/20260419T004413Z-pr-585.md)
- [PR #585 fix results](../../raw/fixes/20260419T004921Z-pr-585.md)
- [PR #590 review results](../../raw/reviews/20260419T050601Z-pr-590.md)
