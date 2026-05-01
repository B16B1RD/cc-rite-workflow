---
title: "新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する"
domain: "heuristics"
created: "2026-04-18T12:50:00+00:00"
updated: "2026-05-01T03:27:29Z"
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
  - type: "reviews"
    ref: "raw/reviews/20260419T112658Z-pr-599.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T114201Z-pr-599-rereview.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T112900Z-pr-599.md"
  - type: "reviews"
    ref: "raw/reviews/20260501T012144Z-pr-756.md"
  - type: "fixes"
    ref: "raw/fixes/20260501T020145Z-pr-756.md"
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

### 拡張: parallelism suffix drift (PR #599 で実証)

canonical 一覧の drift は「counter 数」「エントリの有無」だけでなく、**sibling entry 間の parallelism suffix (「N 種で同型」「N counter で同型」等) の書き漏れ**という微細形でも発生する。PR #599 で初版に `9.3 exit code` 節 L1739 Phase 8.3 entry の末尾に「で同型」suffix 3 文字が欠落したまま commit された事例を実測: エラーハンドリング表側 (L1754) は `2 種で同型` で揃っていたが、9.3 節側は `2 種` 止まりで parallel 関係が壊れていた (L1738 Phase 6.2 `3 種で同型` との比較で差分が露呈)。

- **検出経路**: prompt-engineer (LOW finding) と code-quality (推奨事項) が cross-validation で独立に同一箇所を検出。severity 評価は割れたが「drift が存在する」という判定は一致
- **fix 契約の拡張**: canonical rule が「エントリを同期追加する」だけでは不十分で、sibling entry 間の parallelism suffix (表現の揃え方) まで strict に揃える義務を含む。『5 site 対称化』counter は「数」の同期アンカーだが、parallelism suffix は「**表現の同期アンカー**」であり、両輪で機械検証する
- **fix の粒度**: 3 文字追加の micro-fix で 1 cycle 収束 (cycle 1: 1 finding → cycle 2: 0 findings mergeable)。本 PR scope に drift 解消が含まれ、かつ fixable な微細 drift は別 Issue 化ではなく本 PR 内で対応するのが loop 効率的 (ユーザー判定で Phase 5.3.0 mechanical demotion を override する価値がある)

教訓: 同一ファイル内で canonical 一覧が複数セクション (9.3 節 + エラーハンドリング表) に分散している場合、片方への追加・変更が他方と自動的に parallel になる保証はない。reviewer は両セクションの **「数」と「表現」の両軸** で parallel check を行う必要がある。機械 lint では「で同型」の有無は意味的に等価として検出困難なため、cross-reviewer cross-validation が canonical な検出経路。

### 拡張: header の caller list と実 caller の drift + TC enforce 義務 (PR #756 で追加)

PR #756 cycle 3 review で `_resolve-flow-state-path.sh` header の **Caller contract enumeration drift** が MEDIUM × 1 で検出された:

- header の Caller contract 節は `4 lifecycle hooks` のみを列挙していた
- 実 caller は `grep -rn _resolve-flow-state-path plugins/` で 6+ (post-tool-wm-sync.sh / pre-tool-bash-guard.sh / commands/issue/create-interview.md を含む)
- TC `TC-749-CALLER-CONTRACT` は keyword loop で 4 hook 名のみ enforce していたため、test 自体が drift を catch できない構造だった

これは canonical 一覧 (header の Caller contract) と SoT (実 caller の grep evidence) の drift であり、本ページが扱う「同一ファイル内 canonical 一覧の同期義務」を **header docstring と実 caller** の cross-file drift に拡張する典型例。

**canonical 拡張 rule** (PR #756 で追加):

1. **header の caller list は machine-verifiable な truth と同期する**: `grep -rn <helper-name> plugins/` の grep evidence ベースで literal SoT と同期。記憶や旧 caller 一覧に依存しない
2. **TC で全 caller を enforce する設計**: caller list を test fixture で keyword loop 検証する場合、4 hook 等の subset ではなく **6+ caller 全て** を enforce する。keyword loop の length 自体が「N caller 同期 counter」として機能 (`'5 site 対称化' counter` パターンの拡張)
3. **caller の category 分類**: 単純列挙ではなく「lifecycle / RITE_DEBUG-gated / command-level」のような category 別に分類することで、新規 caller 追加時に「どの category に入れるべきか」が明示され、無自覚な silent regression リスクが構造的に減少 (PR #756 fix で確立した pattern)
4. **TC が SoT と drift しない構造**: TC の caller list 自体が `grep -rn` evidence と直接対応していること。test fixture が「期待値リスト」をハードコードするのではなく、**grep 経由で動的に取得**するか、**static 一覧と grep evidence の double-check** を test 内で実施する

PR #756 fix で `_resolve-flow-state-path.sh` header に 6+ caller を category 別 (lifecycle hooks / observability hooks / command-level) で記述し、TC を全 caller enforce に拡張した。これにより同型 drift が将来再発した際に CI で decisive 検出可能になった。

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
- [PR #599 review results](../../raw/reviews/20260419T112658Z-pr-599.md)
- [PR #599 re-review results](../../raw/reviews/20260419T114201Z-pr-599-rereview.md)
- [PR #599 fix results](../../raw/fixes/20260419T112900Z-pr-599.md)
- [PR #756 cycle 3 review (caller contract enumeration drift MEDIUM)](../../raw/reviews/20260501T012144Z-pr-756.md)
- [PR #756 cycle 4 fix (header caller list を 6+ caller に拡張 + TC enforce 強化)](../../raw/fixes/20260501T020145Z-pr-756.md)
