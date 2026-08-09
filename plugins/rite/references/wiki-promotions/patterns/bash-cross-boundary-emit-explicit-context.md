---
title: "Bash tool 境界を跨ぐ値は [CONTEXT] sentinel として明示 emit する"
domain: "patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/patterns/bash-cross-boundary-emit-explicit-context.md"
promoted_from: "wiki:/pages/patterns/bash-cross-boundary-emit-explicit-context.md"
created: "2026-04-30T01:58:00+00:00"
updated: "2026-05-19T12:30:00Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260430T014425Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260429T141610Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260514T082816Z-pr-953.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T114404Z-pr-1062.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T122133Z-pr-1062.md"
tags: []
confidence: high
---

# Bash tool 境界を跨ぐ値は [CONTEXT] sentinel として明示 emit する

## 概要

bash block 内でシェル変数として計算した値を、別の Bash tool invocation の heredoc / placeholder substitution で参照する場合、Claude Code の Bash tool は invocation 境界でシェル状態を継承しないため、値を `[CONTEXT] KEY=$VALUE` 形式の sentinel として stdout / stderr に明示 emit する必要がある。block 内コメントが「partial corruption 防止」を主張していても、success/failure 両経路に対称な emit が実装されていない場合は self-contradiction として review reviewer の主指摘対象になる。

## 詳細

### 失敗形態

累積 14 回目の cycle 49 H-1 の例: Phase 5.5.2 metrics block で `plan_deviation_count` を計算した後、success 経路で stdout/stderr に emit せず、Bash tool 境界でシェル変数が消失する構造的バグ。Claude が下流 heredoc placeholder に literal substitute する手段がないため、block 内コメントが「partial corruption 防止」を主張していても目的を達成できない (self-defeating defense)。

### Canonical pattern

1. **両経路に対称 emit**: success / failure 両方で `[CONTEXT] KEY=$VALUE` を stderr に emit する (排他フラグ `METRICS_SKIPPED` と `PLAN_DEVIATION_COUNT` のように)
2. **stderr 優先**: stdout が parsing pipeline の対象である場合 stderr を選ぶ。stdout pipeline の context が安全と判明している場合は stdout でも可
3. **sentinel KV 構造**: `KEY=VALUE` 形式で grep / sed の機械可読性を保つ。`KEY` には `=` を含めない
4. **block 内コメントと実装の整合**: 「○○ 防止」「partial corruption guard」等を主張する block は、対称な emit pattern が実装されていることをコメント直下で grep verify 可能にする

### 検出手段

- block 内コメントが「partial corruption / silent skip 防止」を主張する場合、success 経路と failure 経路の両方に [CONTEXT] emit が存在することを 1 PR で grep evidence として確認
- 累積対策 PR の review-fix loop では、block 内コメントの主張と実装の対称性を `## comment claim ↔ block emit` の checklist として審査項目化する

### Sub-pattern: sub-skill 内 bash 変数 guard は常に false

/rite:issue:start の sub-skill 抽出 (G2) で 3 reviewer 独立検出の CRITICAL: sub-skill 内に `FINALIZE_ABORT` のような bash 変数を unset/set して abort 判定の guard とする実装は、Claude Code が sub-skill 内の Bash tool 呼び出しを別 invocation として扱うため変数が常に空 (=false 評価) となる構造的 dead code になる。caller→sub-skill→caller の往復で guard を有効化したい場合、bash 変数ではなく `[CONTEXT] KEY=VALUE` sentinel として stdout/stderr に emit し、caller 側で grep 検出する canonical pattern に従う必要がある。新規 sub-skill 抽出 refactor の review 観点として「sub-skill 境界を跨ぐ guard 変数が bash 変数か CONTEXT sentinel か」を必須項目化する。

### Sub-pattern: 単一 invocation 内に detect+emit 物理統合する代替 canonical（cycle 3-4）

cross-Bash-call shell var の構造的回避策には [CONTEXT] sentinel emit (canonical 1) に加えて、もう 1 つの canonical alternative がある: **同一 Bash invocation 内に「detect + emit」を物理統合する** (canonical 2)。物理統合事例の cycle 3 で fix.md Phase 2.1.A の 「Step 2 で fingerprint 計算 → Step 3 で state file への append」が独立 Bash invocation として実装されていた結果、Step 2 で計算した fingerprint shell var が Step 3 invocation 境界で消失 + 各 step が per-finding loop 内で iterate していたため重複 emit を引き起こす CRITICAL を検出。cycle 4 で `per-finding loop は単一 invocation 内に閉じる` invariant に依拠して Step 2/3 を物理統合 (= 同一 Bash block 内で「fingerprint 計算 + append」を完結) することで、(1) cross-call boundary 自体を消去して shell var transport の必要性を排除し、(2) 同一 loop iteration 内で 1 append のみ発生する invariant が成立するため重複 emit も同時に構造的解消。

**Canonical 1 (sentinel emit) vs Canonical 2 (物理統合) の選択基準**:

| 状況 | Canonical | 理由 |
|------|-----------|------|
| 検出 step と消費 step が別 phase / 別 file で実行される | Canonical 1 (sentinel emit) | invocation 境界が unavoidable で値 transport が必要 |
| 検出 step と消費 step が同一 phase 内で連続実行され、消費先が同一 step で完結する | Canonical 2 (物理統合) | より少ない LoC で boundary を消去でき重複 emit invariant も同時に成立 |
| per-finding / per-iteration loop の内側で detect → emit する | Canonical 2 (物理統合) | loop iteration の atomicity に依拠して step 順序保証を獲得 |

新規実装で「Step を分割するべきか」判断する際は、cross-call shell var transport が本質的に必要かを最初に問うこと。不要なら物理統合を default 選択肢として、boundary 自体を作らない方向が構造的に堅牢。

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #688 fix 記録 (cycle 49 H-1 self-defeating defense 修正)](../../raw/fixes/20260429T141610Z-pr-688.md)
- [PR #688 fix 記録 (4 件 fix + 17 件 umbrella issue 化)](../../raw/fixes/20260430T014425Z-pr-688.md)
- [PR #953 review 記録 (sub-skill 内 bash 変数 guard が常に false の CRITICAL 検出)](../../raw/reviews/20260514T082816Z-pr-953.md)
- [PR #1062 cycle 1 review (per-finding loop 内で Step 2/Step 3 が独立 Bash invocation だった結果 shell var cross-call 消失 + 重複 emit が CRITICAL として検出)](../../raw/reviews/20260519T114404Z-pr-1062.md)
- [PR #1062 cycle 4 mergeable (cycle 4 で Step 2/3 物理統合により cross-call boundary を消去、per-finding loop の単一 invocation invariant 依拠で重複 emit も構造的解消、4 cycle (18→6→3→3→0) 構造的収束)](../../raw/reviews/20260519T122133Z-pr-1062.md)
