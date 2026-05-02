---
title: "AC 解消 statement の数値解釈は実装で裏取りする (PR description fact-check gate)"
domain: "heuristics"
created: "2026-05-02T00:30:00+09:00"
updated: "2026-05-02T00:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260502T001118Z-pr-761.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T001651Z-pr-761.md"
tags: [ac-resolution, fact-check, pr-description, numeric-interpretation, conflate-recurrence]
confidence: high
---

# AC 解消 statement の数値解釈は実装で裏取りする (PR description fact-check gate)

## 概要

PR description / commit message の Acceptance Criteria 解消 statement に「数値の解釈」(`N/N passed` の N は何を表すか、`X 件対応` の X はどこから来たか) が含まれる場合、その数値解釈を**実装 (テストランナー / カウンタ loop / 集計 script) を直接 grep して裏取りせずに書く**と、AC 解消対象だった conflate (混同) を別形で再現する経路を生む。test reviewer が `run-tests.sh` の loop 構造 (`for test_file in *.test.sh; TOTAL=$((TOTAL + 1))`) のような 1 行で確認できる事実を見落とした reviewer 自身の指摘で初検出される pattern。canonical 防御は (a) AC が「conflate 解消」「数値の事実誤認訂正」のような fact-check 系の場合は核心 statement に含まれる**全数値の取得コマンド** (`ls *.test.sh | wc -l`、`grep -c '^echo "TC-'` など) を併記、(b) PR description で「N 階層」として明示分離する記述パターン、(c) cycle 1 で見落とされた fact-check は cycle 2 で reviewer が必ず再実行する Anti-Degradation Guardrail (既存 [reviewer-scope-antidegradation](reviewer-scope-antidegradation.md) と pair) を運用に組み込む。

## 詳細

### 失敗の構造

PR #761 の cycle 1 review で test reviewer が HIGH として検出した事例:

- **AC-3 の文言**: 「PR description の TC 数 vs assertion 数 conflate を修正」
- **修正後 PR description の核心 statement (cycle 1 時点)**: 「`run-tests.sh` の最終出力 `36/36 passed` の `36` は assertion 数の合計」と記載
- **実装上の事実 (`run-tests.sh:13`)**: `for test_file in *.test.sh; do TOTAL=$((TOTAL + 1)); done` — TOTAL は **テストファイル数の loop counter**であり、assertion 数の集計ではない
- **失敗 mode**: AC-3 が解消したかった「TC 数 vs assertion 数」の conflate を、別形 (「assertion 数 vs ファイル数」) で再導入していた。AC 解消 statement そのものが AC で指摘された anti-pattern を再演している self-meta drift

### 教訓

AC 解消の核心 statement に数値解釈が含まれる場合、必ず実装で裏取りする。本 PR では以下のように cycle 2 で 3 階層に明示分離した:

| 階層 | 取得方法 | 値 |
|------|---------|---|
| ファイル数 | `ls plugins/rite/hooks/tests/*.test.sh \| wc -l` | 36 (`run-tests.sh` の `36/36 passed` の `36` はこれ) |
| TC 数 | `grep -c '^echo "TC-' plugins/rite/hooks/tests/*.test.sh` の合計 | 約 44 TC |
| assertion 数 | `grep -c 'pass\|_assert\|fail' *.test.sh` の合計 | 約 112 assertion (実行時のみカウント) |

各階層の取得コマンドを併記することで、後続 reviewer / contributor が同じ conflate を再導入できなくなる構造的防御が成立する。

### Convergence Pattern (cycle 1 → cycle 2 で 5 → 0 finding 収束)

PR #761 では cycle 1 で 5 findings (HIGH 1 + MEDIUM 2 + LOW 2)、cycle 2 で全件 FIXED 判定 + 新規 finding 0 という典型的な review-fix loop の正常収束パターンが観測された。これは [`fix-induced-drift-in-cumulative-defense`](../anti-patterns/fix-induced-drift-in-cumulative-defense.md) の累積対策 PR とは異なり、**通常の review-fix loop における健全な収束**として記録する価値がある (累積対策 PR の 13 cycle / 38+ cycle 軌跡と対比して、通常 PR は 2 cycle で converge する base rate の実例)。

### Anti-Degradation Guardrail との pair pattern

cycle 1 で fact-check を見落としたケースは、cycle 2 reviewer が必ず初回 scope を rerun する [reviewer-scope-antidegradation](reviewer-scope-antidegradation.md) の運用が前提となる。本 heuristic はその pair pattern として:

- **cycle 1 reviewer 側**: AC 解消 statement に数値が含まれている場合、その数値の出典 (実装 grep / カウンタ loop) を Verification 段階で明示確認
- **cycle 2 reviewer 側**: 「前回指摘の解消確認」だけでなく、AC 解消 statement 自身が AC 違反を再演していないか fact-check rerun

この 2 段で本 anti-pattern (AC self-meta drift) を decisive に検出可能になる。

### 適用範囲

本 heuristic は以下の文脈で発動する:

1. PR description / commit message に「N 件対応」「N/N passed」「N% improvement」など数値的 claim が含まれる
2. その数値が AC の核心解消条件 (conflate 解消 / 事実誤認訂正 / メトリクス検証) と直接 link している
3. 数値の出典 (テストランナー / カウンタ / ベンチマーク script) が repo 内に grep で 1 分以内に確認できる

3 件すべて該当する場合、reviewer は数値解釈を信じずに自分で実装 grep して verify することを必須化する (PR review checklist に追加可能)。

## 関連ページ

- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](reviewer-scope-antidegradation.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #761 cycle 1 fix — AC-3 解消 statement の数値解釈事実誤認 (HIGH)](../../raw/fixes/20260502T001118Z-pr-761.md)
- [PR #761 cycle 2 re-review — 5 → 0 finding 収束 + AC fact-check 教訓の formalization](../../raw/reviews/20260502T001651Z-pr-761.md)
