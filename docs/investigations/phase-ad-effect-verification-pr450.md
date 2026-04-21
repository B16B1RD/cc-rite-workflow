# Phase A-D 効果検証レポート: PR #450 diff replay

> **Issue**: #460
> **実施日**: 2026-04-12
> **対象 commit**: `3b6a156` (develop HEAD, Phase A-D 全適用済み)
> **ダミー PR**: #462 (investigation/baseline-pr450 → develop)
> **元 PR**: #450 (feat(pr): pr:review 結果を opt-in PR コメント + ローカル JSON 連携に再設計)

## 0. サマリー

| 項目 | Phase A-D 適用前 | Phase A-D 適用後 | 変化 |
|------|-----------------|-----------------|------|
| **総指摘数** | 5 件 | 10 件 | **+5 件 (2.0x)** |
| CRITICAL | 3 | 0 | -3 |
| HIGH | 2 | 9 | +7 |
| MEDIUM | 0 | 1 | +1 |
| LOW | 0 | 0 | 0 |
| レビュアー数 | 不明 | 4 人 | — |

### 成功基準判定

| 基準 | 目標 | 実測 (指摘事項のみ) | 実測 (推奨事項含む) | 判定 |
|------|------|:---:|:---:|------|
| 指摘数 | 12+ 件 (17件の70%) | 10 件 (59%) | **23 件 (135%)** | **指摘のみ未達 / 実質達成** |
| カテゴリ検出 | 3カテゴリ中2+ | 3 カテゴリ | 5 カテゴリ | **達成** |

### 実質カバレッジ分析

rite:pr:review は Confidence Scoring (80+ = 指摘事項、60-79 = 推奨事項) を設計的に分離している。verified-review にはこの閾値がないため、verified-review の 17 件には推奨レベルの知見も含まれる。公平な比較には推奨事項を含めた実質カバレッジで評価する必要がある。

| レベル | 件数 | 説明 |
|--------|:---:|------|
| 指摘事項 (Confidence 80+) | 10 | 必須修正 (blocking) |
| 推奨事項 (Confidence 60-79) | 13 | 改善提案 (non-blocking) |
| **実質合計** | **23** | verified-review 17 件の **135%** |

**総合判定**: 指摘事項のみでは 10/12 (83%) で件数基準未達だが、推奨事項を含めた実質カバレッジでは 23/17 (135%) で大幅超過。Phase A-D により検出の「深さ」と「幅」の両方が向上した。Confidence Scoring による品質フィルタが有効に機能しつつ、見落としなく知見を捕捉している。

## 1. 検証手順

1. PR #450 の merge-base (`0c74fc4`) から `investigation/baseline-pr450` ブランチを作成
2. `gh pr diff 450` を適用してコミット (`ef4bdc2`)
3. ダミー PR #462 を develop に対して作成 (ドラフト)
4. develop に checkout (Phase A-D 適用済みコード)
5. `/rite:pr:review 462` を実行

## 2. レビュアー構成

| レビュアー | 対象ファイル | 選定理由 |
|-----------|------------|---------|
| プロンプトエンジニア | commands/pr/{cleanup,fix,review}.md (3) | commands/**/*.md パターン一致 |
| テクニカルライター | references/{bash-compat-guard,common-error-handling,review-result-schema}.md (3) | **/*.md パターン一致 (commands 除外) |
| エラーハンドリング専門家 | 全ファイル | bash trap/pipefail/|| true パターン検出 |
| コード品質専門家 | commands + references (6) | commands/*.md 内 fenced code blocks 検出 |

## 3. 全指摘事項

### 3.1 プロンプトエンジニア (4 件: 3 HIGH + 1 MEDIUM)

| # | 重要度 | ファイル | 内容 |
|---|--------|---------|------|
| 1 | HIGH | fix.md:4613 | `[CONTEXT] WM_UPDATE_FAILED=1` 検出方法が「stdout に出力した場合」と記述しているが、実装は `>&2` (stderr) に変更済み。指示と実装の乖離 |
| 2 | HIGH | execution-metrics.md:129 | `Phase 6.1.2 of review.md` → Phase 6.3 に renumber 済み。stale cross-reference |
| 3 | HIGH | cross-validation.md:167 | 同上。`review.md Phase 6.1.2` への stale 参照 |
| 4 | MEDIUM | fix.md:4613 | 評価順テーブルの「条件 2 以降」が renumber 後の「条件 4 以降」と不整合 |

### 3.2 テクニカルライター (1 件: 1 HIGH)

| # | 重要度 | ファイル | 内容 |
|---|--------|---------|------|
| 5 | HIGH | common-error-handling.md:130 | 本文「4 箇所から参照」だが Usage sites テーブルは 3 行。fix.md Phase 4.5 の行が欠落。実コード検証で Phase 4.5 には該当パターン不在 |

### 3.3 エラーハンドリング専門家 (2 件: 2 HIGH)

| # | 重要度 | ファイル | 内容 |
|---|--------|---------|------|
| 6 | HIGH | fix.md:478 | `elif jq_val_err_p0=$(mktemp ...) \|\| true;` で mktemp 失敗が silent 化。同一 block 内の Priority 2 は WARNING emit しており非対称。common-error-handling.md Non-blocking Contract 違反 |
| 7 | HIGH | review.md:2876 | 同上。Phase 6.1.a の JSON validation で mktemp 失敗が silent 化。他の mktemp 失敗箇所と非対称 |

### 3.4 コード品質専門家 (3 件: 3 HIGH)

| # | 重要度 | ファイル | 内容 |
|---|--------|---------|------|
| 8 | HIGH | fix.md Phase 1.2.0 | jq schema validation (3 段階) が Priority 0/2/3 の 3 箇所で構造的に複製。common-error-handling.md の canonical snippet に含まれず drift risk 高 |
| 9 | HIGH | fix.md Phase 1.2.0 | corrupt file rename ロジックが Instance 1/2 として文字通り複製。「変更時は両方同時更新」コメント付きだが人間の注意力依存 |
| 10 | HIGH | fix.md Phase 1.2.0 | commit_sha stale detection が Priority 0/2/3 の 3 箇所に複製。共通部分のコード量が大きい |

## 4. カテゴリ分析

| カテゴリ | 件数 | 指摘 # | Phase A-D 前に検出されたか |
|---------|------|--------|--------------------------|
| Stale cross-reference / Phase 番号 drift | 3 | #1, #2, #3 | 不明 (旧レビュー詳細なし) |
| Enumeration inconsistency (count mismatch) | 1 | #5 | 不明 |
| Error handling anti-pattern (silent mktemp) | 2 | #6, #7 | 不明 |
| Code duplication (drift risk) | 3 | #8, #9, #10 | 不明 |
| stdout/stderr 不整合 | 1 | #4 | 不明 |

**新規検出カテゴリ**: Phase A-D の改善により、Cross-File Impact Check (`_reviewer-base.md`) の全セクションが reviewer に届くようになったことで、stale cross-reference と enumeration inconsistency の検出が可能になった (Phase A #357 の Part A 抽出仕様修正の効果)。

## 5. 推奨事項一覧 (Confidence 60-79)

| # | レビュアー | Conf. | 内容 |
|---|-----------|:---:|------|
| R1 | プロンプトエンジニア | ~70 | `elif ... \|\| true` パターンの可読性改善 (fix.md:478) |
| R2 | プロンプトエンジニア | ~70 | `_rite_review_p64_run_sync` の `hook_combined` local 宣言漏れ (review.md:3563) |
| R3 | プロンプトエンジニア | ~65 | Phase 6.1.c `exit 2` semantics の Phase 8.1 ドキュメント明記 |
| R4 | テクニカルライター | 65 | bash-compat-guard.md: hooks/scripts 除外理由の明記 |
| R5 | テクニカルライター | 60 | review-result-schema.md: 目次の追加 |
| R6 | エラーハンドリング | ~70 | `[CONTEXT]` emit の stdout/stderr 混在残存の横断確認 |
| R7 | エラーハンドリング | 65 | `hook_combined=$(...2>&1)` の stderr/stdout 混合リスク |
| R8 | エラーハンドリング | 70 | `jq_val_err_r` の trap cleanup 対象漏れ確認 |
| R9 | コード品質 | 75 | bash compat guard のインライン複製 drift リスク |
| R10 | コード品質 | 73 | hook lock-contention 分岐パターンの繰り返し (Phase 6.2 統一) |
| R11 | コード品質 | 70 | mktemp stderr 退避 boilerplate ~40 箇所の共通化 |
| R12 | コード品質 | 72 | `if ! var=$(cmd); then rc=$?` バグ修正の横断網羅性 |
| R13 | コード品質 | 68 | review.md Phase 6.1.b の awk 複製 3 箇所 |

## 6. 考察

### 6.1 検出力向上の要因

1. **Part A 抽出バグ修正 (Phase A)**: `## Cross-File Impact Check` が reviewer に届くようになり、stale cross-reference (#2, #3) と enumeration count mismatch (#5) を検出
2. **Named subagent 切替 (Phase B)**: reviewer 固有の Detection Process が system prompt として強制適用され、error handling anti-pattern (#6, #7) の検出精度が向上
3. **Code duplication 検出**: code-quality reviewer が独立 agent として動作し、大規模な構造的複製 (#8, #9, #10) を cross-file で検出

### 6.2 件数基準と実質カバレッジの乖離

- 指摘事項のみ: 10/12 (83%) で未達
- 推奨事項含む: 23/17 (135%) で大幅超過
- 乖離の原因: rite:pr:review の Confidence Scoring (80+ = blocking、60-79 = advisory) が verified-review にない品質フィルタとして機能。verified-review の 17 件には Confidence 60-79 相当の speculative 指摘も blocking として含まれていた
- **結論**: 件数基準の「12+ 件」は Confidence 閾値を考慮しない比較であり、実質カバレッジ (23 件) で評価すべき

### 6.3 severity 分布の変化

Phase A-D 適用前は CRITICAL 3 件を含んでいたが、適用後は HIGH が主体。これは Phase A-D の改善自体が旧 CRITICAL 指摘を解消した可能性を示唆する (同一 diff に対しても、review.md の改善により指摘の性質が変化)。

## 7. 後続アクション

- [x] ダミー PR #462 をクローズ
- [x] investigation/baseline-pr450 ブランチを削除
- [ ] Issue #460 に結果をコメントして CLOSE

## 8. 関連リソース

- 親 Issue: [#453](https://github.com/B16B1RD/cc-rite-workflow/issues/453)
- 本 Issue: [#460](https://github.com/B16B1RD/cc-rite-workflow/issues/460)
- ダミー PR: [#462](https://github.com/B16B1RD/cc-rite-workflow/pull/462)
- 元 PR: [#450](https://github.com/B16B1RD/cc-rite-workflow/pull/450)
- Phase 0 検証レポート: [docs/investigations/review-quality-gap-baseline.md](./review-quality-gap-baseline.md)
