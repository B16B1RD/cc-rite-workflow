---
title: "Reviewer の Likelihood-Evidence anchor 未提示が現実的 finding の機械的降格を誘発"
domain: "anti-patterns"
promote: rite-plugin
created: "2026-05-18T20:30:00+09:00"
updated: "2026-05-18T20:30:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260518T112318Z-pr-1045.md"
tags: []
confidence: medium
---

# Reviewer の Likelihood-Evidence anchor 未提示が現実的 finding の機械的降格を誘発

## 概要

Hypothetical Exception Categories (security/database/devops/dependencies) 外の reviewer (prompt-engineer / code-quality / tech-writer 等) が、grep で示せる現実的 finding を出しながら `Likelihood-Evidence:` anchor を出力しないことで、Phase 5.3.0 Observed Likelihood Gate (Post-Reviewer Safety Net) によって CRITICAL/HIGH/MEDIUM/LOW-MEDIUM 重要度の指摘がすべて推奨事項に機械的降格される失敗 mode。reviewer 側の出力契約が self-enforcing でないため、blocking とすべき指摘が silent に非 blocking 化される。

## 詳細

### 発生機序

`_reviewer-base.md#observed-likelihood-gate` で定義される **Demonstrable Proof of Burden** ルール: reviewer は finding の重要度を主張する際、`Likelihood-Evidence: tool=Grep, path=src/foo.ts, line=42` 形式の anchor を **finding 内容欄に literal で記述** することで、現実の call path から observable な問題であることを証明する責務を負う。anchor が欠落した finding は Hypothetical (思考実験ベース) として扱われ、Phase 5.3.0 mechanical Gate が以下の降格を実施する:

| 元重要度 | Likelihood-Evidence anchor あり | Likelihood-Evidence anchor なし AND Hypothetical Exception 外 |
|---------|--------------------------------|----------------------------------------------------------------|
| CRITICAL / HIGH / MEDIUM / LOW-MEDIUM | blocking として保持 | **推奨事項に降格** |
| LOW | blocking として保持 | **削除** |

Hypothetical Exception Categories は `security` / `database` / `devops` / `dependencies` の 4 reviewer のみ。それ以外の reviewer (prompt-engineer / code-quality / tech-writer / api / frontend / test / type-design / error-handling / performance) は **必ず anchor を出力しなければ** すべての finding が機械的降格対象となる。

### 観測事例（review）

`pr-review-toolkit:prompt-engineer-reviewer` agent が `commands/pr/references/anchor-naming-convention.md` に対し以下 2 件の確信度 80 以上 finding を出力した:

- F-01 (line 100): §3.2 が `pages/anti-patterns/asymmetric-fix-transcription.md` の path を直接引用し、同 file 内 §5 の「Wiki page への直接リンクを使わない」方針と矛盾 (確信度 88)
- F-02 (line 131): §4.2 row 3 の `bulk-create-pattern.md:118` anchor が §2.1/§3.1 の minimum form 原則と矛盾 (確信度 85)

両 finding ともに **`Likelihood-Evidence:` anchor を出力していなかった** ため、Phase 5.3.0 が機械的に 2 件すべてを推奨事項に降格し、結果として overall assessment が `[review:mergeable]` (0 blocking) になった。実際は文書の self-consistency 違反で merge 前修正が望ましい指摘だが、blocking 化されずユーザーの手動判断に委ねられた。

### Anti-pattern 構造

1. **reviewer の identity 文書 (Core Principles / Detection Process / Detailed Checklist / Output Format)** には Likelihood-Evidence anchor の出力契約が明示されている
2. しかし subagent body 内で reviewer が finding 表を生成する際、anchor 列の追加を **silent に skip する経路** がある (template に anchor 列が含まれていない場合、subagent が追加する判断を下さないと anchor 不在のままになる)
3. orchestrator 側の Phase 5.3.0 Gate は **存在しないものを mechanically 検出して降格する** のみで、reviewer に anchor 出力を要求する押し返しは行わない
4. 結果として「reviewer は出力契約を満たさず、orchestrator は契約違反を mechanical 降格でカバーする」非対称が成立し、blocking finding が silent に消失する

### 予防策

#### 経路 A: reviewer 側の出力契約強化

- reviewer agent body の Output Format 章に「指摘事項テーブルの `内容` 列には必ず `Likelihood-Evidence: tool=<Grep|Read|Glob>, path=..., line=...` を含めること」を MUST レベルで明示
- subagent 起動時の system prompt に同制約を inject (Phase 4.3 の `{shared_reviewer_principles}` 経由)
- Hypothetical Exception 4 categories 以外の reviewer がこれを satisfy していない場合、`review.md` Phase 5.1 collection で WARNING を emit してから Phase 5.3.0 に進む

#### 経路 B: orchestrator 側の降格通知強化

- Phase 5.3.0 で finding を降格した際、降格件数を completion report の冒頭に明示 (現状は「Observed Likelihood 降格結果」セクションで詳細表示するが、件数 + reviewer 別 breakdown を summary 行に追加)
- 降格件数が 1 以上の場合、`AskUserQuestion` で「降格された指摘を blocking として扱うか / そのまま mergeable とするか」をユーザーに確認

#### 経路 C: anchor 自動 inject

- Phase 5.1 collection で reviewer 出力を parse し、anchor がない finding に対して file:line と推定 tool を自動追記 (LLM-based augmentation)。anchor の正確性は保証されないが、ratchet として降格を回避

### 関連する failure mode

- **Self-violation cascade** ([asymmetric-fix-transcription.md](./asymmetric-fix-transcription.md) の self-referential 事例): 予防対象の anti-pattern を文書化する self-referential 経路で、当該 anti-pattern を文書自身が踏む同型再発。本 anti-pattern も「reviewer が出力契約を満たすべき設計の文書が、reviewer の output 契約違反を mechanical で吸収する設計と共存している」という self-referential 構造を持つ
- **Silent demote chain**: Phase 5.3.0 → Phase 7.1 candidate filter → Phase 7.7 post-condition gate の連鎖で、降格された finding が actionable/boundary 分類を持たず `design_confirmation` (no action) として扱われる経路。本 anti-pattern と組み合わさると、blocking-worthy 指摘が completion report の disposition table で件数のみ表示される

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #1045 review results](../../raw/reviews/20260518T112318Z-pr-1045.md)
