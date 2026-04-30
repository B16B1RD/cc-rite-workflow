---
title: "Bash tool 境界を跨ぐ値は [CONTEXT] sentinel として明示 emit する"
domain: "patterns"
created: "2026-04-30T01:58:00+00:00"
updated: "2026-04-30T01:58:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260430T014425Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260429T141610Z-pr-688.md"
tags: []
confidence: high
---

# Bash tool 境界を跨ぐ値は [CONTEXT] sentinel として明示 emit する

## 概要

bash block 内でシェル変数として計算した値を、別の Bash tool invocation の heredoc / placeholder substitution で参照する場合、Claude Code の Bash tool は invocation 境界でシェル状態を継承しないため、値を `[CONTEXT] KEY=$VALUE` 形式の sentinel として stdout / stderr に明示 emit する必要がある。block 内コメントが「partial corruption 防止」を主張していても、success/failure 両経路に対称な emit が実装されていない場合は self-contradiction として review reviewer の主指摘対象になる。

## 詳細

### 失敗形態

PR #688 cycle 49 H-1 の例: Phase 5.5.2 metrics block で `plan_deviation_count` を計算した後、success 経路で stdout/stderr に emit せず、Bash tool 境界でシェル変数が消失する構造的バグ。Claude が下流 heredoc placeholder に literal substitute する手段がないため、block 内コメントが「partial corruption 防止」を主張していても目的を達成できない (self-defeating defense)。

### Canonical pattern

1. **両経路に対称 emit**: success / failure 両方で `[CONTEXT] KEY=$VALUE` を stderr に emit する (排他フラグ `METRICS_SKIPPED` と `PLAN_DEVIATION_COUNT` のように)
2. **stderr 優先**: stdout が parsing pipeline の対象である場合 stderr を選ぶ。stdout pipeline の context が安全と判明している場合は stdout でも可
3. **sentinel KV 構造**: `KEY=VALUE` 形式で grep / sed の機械可読性を保つ。`KEY` には `=` を含めない
4. **block 内コメントと実装の整合**: 「○○ 防止」「partial corruption guard」等を主張する block は、対称な emit pattern が実装されていることをコメント直下で grep verify 可能にする

### 検出手段

- block 内コメントが「partial corruption / silent skip 防止」を主張する場合、success 経路と failure 経路の両方に [CONTEXT] emit が存在することを 1 PR で grep evidence として確認
- 累積対策 PR の review-fix loop では、block 内コメントの主張と実装の対称性を `## comment claim ↔ block emit` の checklist として審査項目化する

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #688 fix 記録 (cycle 49 H-1 self-defeating defense 修正)](../../raw/fixes/20260429T141610Z-pr-688.md)
- [PR #688 fix 記録 (4 件 fix + 17 件 umbrella issue 化)](../../raw/fixes/20260430T014425Z-pr-688.md)
