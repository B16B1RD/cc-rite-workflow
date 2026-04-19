---
title: "Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格"
domain: "heuristics"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-19T04:50:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260416T031452Z-pr-540.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T173035Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T043538Z-pr-589.md"
tags: ["review", "severity", "likelihood-evidence", "cross-validation", "hypothetical"]
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

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #540 review (Observed Likelihood Gate 実装例、2 件降格)](raw/reviews/20260416T031452Z-pr-540.md)
- [PR #548 cycle 3 review (triple cross-validation boost)](raw/reviews/20260416T173035Z-pr-548.md)
- [PR #589 review (Hypothetical 降格軸の追加実証 — HIGH x2 → 推奨事項降格)](raw/reviews/20260419T043538Z-pr-589.md)
