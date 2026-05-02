---
title: "Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格"
domain: "heuristics"
created: "2026-04-16T19:37:16Z"
updated: "2026-05-02T15:58:59Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260416T031452Z-pr-540.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T173035Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T043538Z-pr-589.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T155859Z-pr-779.md"
tags: ["review", "severity", "likelihood-evidence", "cross-validation", "hypothetical", "literal-output-contract"]
confidence: high
---

# Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格

## 概要

reviewer が finding を HIGH/MEDIUM/LOW で提出する際、Likelihood-Evidence anchor（tool=Read/Grep, path=..., line=... の形式）を伴わない場合は自動的に「推奨事項」に降格させる gate を適用する。これにより憶測ベースの findings を severity から分離し、fix 対象を客観的根拠のあるものに集中できる。

## 詳細

### Anchor フォーマット

```
Likelihood-Evidence: tool=Read, path=plugins/rite/hooks/scripts/wiki-ingest-commit.sh, line=341
Likelihood-Evidence: tool=Grep, pattern='if ! .*; then$', path=plugins/rite/, matches=3
```

- `tool`: 検出に使用したツール (`Read` / `Grep` / `Bash`)
- `path`: 対象ファイルパス（相対）
- `line` または `pattern`: 具体的な位置または検索条件
- `matches`: grep 時の件数

### 降格のルーティング

| 降格理由 | severity | 扱い |
|--------------|---------|------|
| anchor 提示あり | CRITICAL/HIGH/MEDIUM/LOW | fix 対象 |
| anchor なし、推測のみ | — | 推奨事項（fix 対象外、discussion のみ） |
| Hypothetical（将来の他 Phase 変更に依存する仮定的リスク） | — | 推奨事項（現状コードで発火しないため fix 対象外） |

PR #540 では 2 件の finding が「Observed Likelihood Gate により推奨事項に降格」され、severity distribution は `HIGH: 0, MEDIUM: 0` に収束した。PR #589 では error-handling reviewer の HIGH 指摘 2 件が「Likelihood-Evidence anchor 欠落 + Hypothetical（Phase 5.1 将来変更に依存）」のため Phase 5.3.0 safety net で機械的降格され、同じく `HIGH: 0, MEDIUM: 0` に収束。Hypothetical 降格は anchor 欠落と独立した orthogonal な降格軸として加えるのが canonical（Claude Code の Bash tool は invocation ごとに独立 shell を生成するため、bash fenced block 終了で trap 自動 cleanup される事実が降格根拠となった）。

### Triple Cross-validation による severity boost

複数の reviewer が同一箇所を anchor 付きで独立検出した場合、severity を boost する:

| 独立検出人数 | boost 条件 | 例 |
|------------|-----------|---|
| 2 人 (double) | MEDIUM → HIGH | PR #548 cycle 5 F-01 (error-handling HIGH + code-quality LOW → HIGH 合意) |
| 3 人 (triple) | HIGH → HIGH (固定) / 高確度扱い | PR #548 cycle 3 F-01 (prompt-engineer + code-quality + error-handling) |

triple 合意は recurring pattern の可能性が高いため、fix 時に「他の類似箇所が無いか」を grep で網羅確認する合図になる。

### 憶測ベース findings のリスク

anchor を伴わない finding は以下のリスクを持つ:

- 実装を grep せず推測で書かれているため、fix 対象が存在しないケースあり
- 別 reviewer が同じ推測で overlapping finding を書くと false consensus が形成される
- fix 側が anchor の不在を気付かず wild goose chase する

このため evidence anchor を「findings 提出の必須フォーマット」として明示化する設計が有効。

### Reviewer literal output contract の重要性 (PR #779)

PR #779 で観測した sub-pattern: **reviewer がレビュー本文中に Likelihood-Evidence 相当の記述を持っていても、`Likelihood-Evidence:` という literal anchor を含めていなければ Phase 5.3.0 で mechanical 降格される**。

PR #779 では prompt-engineer が以下のような構造を持つ MEDIUM finding を返した:

- file:line に具体位置を提示 (`SKILL.md:21-28`)
- 内容 (WHAT) と影響 (WHY) を明確に記述
- 推奨対応 (FIX) を具体的に提示

しかし **`Likelihood-Evidence: tool=...` の literal 記述が無かった** ため、`pr/review.md` Phase 5.3.0 の mechanical safety net が「anchor 欠落」と判定し推奨事項に降格 → 結果として `[review:mergeable]` (0 blocking findings) と判定された。

#### Canonical 対策

reviewer agent file (`agents/{type}-reviewer.md`) の Output Format 例 / Detection Process 指示で、`Likelihood-Evidence:` literal を **finding template の必須フィールド** として明示する:

```markdown
| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| HIGH | src/foo.ts:42 | ... 内容 ... <br> Likelihood-Evidence: tool=Read, path=src/foo.ts, line=42 | ... 推奨 ... |
```

reviewer 側 prompt template の改修と、Phase 5.3.0 mechanical gate の literal grep 仕様を pair で同期させることで、本 sub-pattern の silent 降格 (= reviewer の判定品質と無関係に finding が消える経路) を解消できる。

#### 影響の orthogonality

本 sub-pattern と Hypothetical 降格軸 (PR #589) は orthogonal — reviewer 内容の構造的問題 (literal anchor 欠落) と reviewer 判定の論理的問題 (現状コード非依存の仮定的リスク) は別軸で処理されるため、両 gate を独立に通過する必要がある。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #540 review (Observed Likelihood Gate 実装例、2 件降格)](raw/reviews/20260416T031452Z-pr-540.md)
- [PR #548 cycle 3 review (triple cross-validation boost)](raw/reviews/20260416T173035Z-pr-548.md)
- [PR #589 review (Hypothetical 降格軸の追加実証 — HIGH x2 → 推奨事項降格)](raw/reviews/20260419T043538Z-pr-589.md)
- [PR #779 review (literal anchor 欠落で MEDIUM → 推奨事項降格、reviewer literal output contract の重要性実証)](raw/reviews/20260502T155859Z-pr-779.md)
