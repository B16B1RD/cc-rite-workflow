---
type: "heuristics"
title: "検証ツールの保証文言は検証される不変量と非検出 gap に正確に対応させる"
domain: "heuristics"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/heuristics/verification-doc-guarantee-matches-invariants.md"
description: "機械検証ツール（drift-check / lint）を追加する PR では、手順書側の保証文言が実装の検証範囲を超えて「漏れは必ず検出される」と全称的に書かれやすい。"
created: "2026-07-03T18:30:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260703T174623Z-pr-1743.md"
  - type: "fixes"
    resource: "raw/fixes/20260703T175226Z-pr-1743.md"
  - type: "reviews"
    resource: "raw/reviews/20260703T180609Z-pr-1743.md"
tags: ["documentation", "drift-check", "overclaim", "guarantee", "contributing"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-03T18:30:00+00:00" }
---

# 検証ツールの保証文言は検証される不変量と非検出 gap に正確に対応させる

## 概要

機械検証ツール（drift-check / lint）を追加する PR では、手順書側の保証文言が実装の検証範囲を超えて「漏れは必ず検出される」と全称的に書かれやすい。検証されない編集箇所（設計上意図的に検査しない gap）が保証文に含まれると、寄稿者が手動確認を省略する経路を生み、ツールが防ごうとした失敗そのものを誘発する。保証文は「何が検証され（不変量の列挙）、何が検証されないか（gap の明示 + 手動確認手順）」を実装の不変量に正確に対応させる。

## 詳細

reviewer registry の 3-way 同期検証で実測。

### 失敗モード（cycle 1 で MEDIUM 検出）

- CONTRIBUTING.md が「a forgotten table row surfaces on the next lint even if you skip manual verification」と全称保証
- 実装の I2 は Available → Type Identifiers の**片方向 subset 検査のみ**で、Available Reviewers 行の書き忘れは logic-selected reviewer と区別できず**意図的に未検査**（スクリプト header に「The reverse direction is intentionally NOT checked」と明記済み）
- 保証文を過信した寄稿者が編集箇所の手動確認を省略 → 本 Issue が防ごうとした shotgun-surgery 漏れが再発する経路

### canonical 修正（2 cycle 収束の鍵）

1. **保証範囲の限定**: 「forgotten Type Identifiers row / agent profile は次回 lint で検出（不変量 I1/I3）。Available Reviewers 行は機械検証されない唯一の gap — 編集箇所 2 を手動確認」と、検出される対象と gap を不変量名で明示する
2. **3 面一貫伝播**: 同種の overclaim 表現（「machine-checked」の全称的表現）を `git grep` で列挙し、手順書の入口文・締め文・SoT 側注記（reviewers/SKILL.md）のすべてに同一の限定を伝播する。既に不変量限定で正確な表現（「row/slug consistency is machine-checked」= I3 限定）は対象外と判定する
3. **設計を変えず文書を設計に合わせる**: gap を塞ぐためのチェック拡張（I2 双方向化）に「logic-selected reviewer と区別不能」という設計理由がある場合、実装は変えず文書を実装に合わせる方向が正解（過剰反応の回避）

### 判定基準

- 保証文に「必ず」「すべて」「漏れなく」等の全称語が入ったら、実装の不変量リストと 1:1 で突合する
- gap が設計上意図的なら「なぜ検査できないか」の理由ごと文書化する（読者が gap を仕様として理解できる）

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [保証文 overclaim を MEDIUM 検出](../../raw/reviews/20260703T174623Z-pr-1743.md)
- [保証範囲の I1/I3 限定 + gap 明記 + 3 面伝播](../../raw/fixes/20260703T175226Z-pr-1743.md)
- [修正が指摘の意図を満たすことを確認、0 findings 収束](../../raw/reviews/20260703T180609Z-pr-1743.md)
