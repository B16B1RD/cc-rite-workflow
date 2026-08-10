---
title: "Bullet 内の bold emphasis は命令本体に集中させ、rationale は commit/PR layer に分離する"
domain: "patterns"
description: "bullet 内で MUST-DO 命令と META / rationale を混在させ rationale 側にだけ bold emphasis を適用すると、bullet スキャン読みで rationale が命令本体より目立つ emphasis 逆転が発生する。canonical pattern は説明・rationale を commit message + PR description layer に分離し、bullet 本文では命令本体に bold emphasis を集中させる責任分離。過去のレビュー cycle 1-3 で blockquote → 7-bullet 化 refactor + ラベル拡張 scope 拡張により F-01 (emphasis 逆転) と F-02 (length 偏り) が同根 (bullet 内 META 混在) で同時 surface → cycle 3 fix で META 削除 + 命令本体 bold 化 で defense-in-depth により同時解消し 0 findings 収束。"
created: "2026-05-18T10:36:15Z"
updated: "2026-05-18T10:36:15Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260518T095947Z-pr-1044.md"
  - type: "fixes"
    ref: "raw/fixes/20260518T100632Z-pr-1044.md"
  - type: "reviews"
    ref: "raw/reviews/20260518T101307Z-pr-1044.md"
  - type: "fixes"
    ref: "raw/fixes/20260518T101701Z-pr-1044.md"
  - type: "reviews"
    ref: "raw/reviews/20260518T102416Z-pr-1044.md"
tags: ["markdown", "prompt-engineering", "emphasis", "scannability", "responsibility-separation", "review-finding"]
confidence: high
---

# Bullet 内の bold emphasis は命令本体に集中させ、rationale は commit/PR layer に分離する

## 概要

bullet (numbered list / unordered list) 内で MUST-DO 命令と META / rationale 文を混在させ、rationale 側にだけ bold emphasis を適用すると、bullet スキャン読みで rationale が命令本体より目立つ **emphasis 逆転** が発生する。canonical pattern は、説明・rationale を commit message + PR description layer に分離し、bullet 本文では命令本体に bold emphasis を集中させる責任分離。

## 詳細

### 観測

`commands/pr/fix.md` Phase 1.2.0 Block 2 冒頭の block continuity note (~700 chars の単一 blockquote) を 7 項目 bullet list へ refactor した PR で、cycle 1-3 にわたって以下の階段的な emphasis 配分問題が surface した:

| Cycle | 観測 | 対応 |
|------|------|------|
| 1 | blockquote → 7 bullet 化により scannability 改善 (0 findings) | bullet 1 のラベル拡張 + L1088 注記の 5-bullet 化を scope 拡張で取り込み |
| 2 | bullet 1 内 MUST-DO 命令 (本来の命令本体) と META 文 (補足説明) が混在し、bold emphasis が META 側に偏った結果 visibility が逆転 (F-01) + bullet 1 が他 bullet より顕著に長くなった (F-02) | F-01 + F-02 を defense-in-depth で同時解消するため META 文を削除して命令本体を bold 化 |
| 3 | rationale を commit/PR layer に分離 + 命令本体を bold で強調する責任分離が prompt-engineering 観点で canonical (0 findings) | 構造的閉塞 |

### 失敗 mode

| ステージ | 失敗 |
|---------|------|
| 設計 | bullet 内に「命令本体」「rationale」「補足/META」を 1 段で並べる構造を採用 |
| 実装 | rationale の方が文字数が長い → bold を rationale 側にだけ適用すると、視覚的に rationale が dominant になる |
| 検証 | bullet スキャン読み (上から下に「最初の太字」を目で追う読み方) の visibility 経路を確認しない |

### canonical pattern (責任分離)

| Layer | 配置内容 |
|------|---------|
| Bullet 本文 (in markdown body) | **命令本体のみ** を bold emphasis でマーク (`**必ず X せよ**` 等)。rationale は最小限の 1 文補足で plain text |
| Commit message body / PR description | rationale / META 文 / 背景 / 設計判断を散文で展開 |

### 検出策

- **diff レベル**: bullet を新規追加 or refactor する PR では、bullet 内 `**...**` (bold) ブロックが「命令本体」か「rationale」かを review checklist に含める
- **post-state visual scan**: 改修後の bullet を「上から bold だけ拾って読む」test を実施し、その読み筋が要求された行動順を表しているか確認
- **review checklist**: prompt-engineer reviewer が `scope:out-of-this-pr` 推奨事項として「bullet 1 が他 bullet より顕著に長い」「bullet 内 emphasis が rationale 側に集中」を機械的に flag する基準を採用

### 関連する周辺観測

1. **Defense-in-depth による同時解消** — F-01 (emphasis 逆転) と F-02 (length 偏り) は同じ「bullet 内 META 混在」が両者の root cause だったため、META 削除 1 操作で 2 finding を同時閉塞できた。multi-finding が共通 root cause を持つ際は「片方ずつ fix」より「root cause 除去」が cycle 数を減らす canonical 対策
2. **inline pack vs scannability tradeoff** — heading-hierarchy-skip ページ で言及された「MUST-execute list は line ceiling より scannability を優先する判断基準が必要」と同型の tradeoff が emphasis 層でも発生

## 関連ページ

- [Markdown 大規模圧縮 refactor 時の heading hierarchy skip](../anti-patterns/heading-hierarchy-skip-on-large-markdown-compression.md)
- [prompt 内 numbered list は同型構造で書く（全 step に動作詳細 bullet を対称配置）](./prompt-numbered-list-isomorphic-structure.md)

## ソース

- [PR #1044 cycle 1 review](../../raw/reviews/20260518T095947Z-pr-1044.md)
- [PR #1044 cycle 1 fix](../../raw/fixes/20260518T100632Z-pr-1044.md)
- [PR #1044 cycle 2 review](../../raw/reviews/20260518T101307Z-pr-1044.md)
- [PR #1044 cycle 3 fix](../../raw/fixes/20260518T101701Z-pr-1044.md)
- [PR #1044 cycle 3 final review](../../raw/reviews/20260518T102416Z-pr-1044.md)
