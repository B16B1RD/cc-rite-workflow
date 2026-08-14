---
title: "dead reference 整理では live citation と historical 記述を区別する"
domain: "heuristics"
description: "削除・改名されたファイル / シンボルへの参照を整理する PR では、すべての出現を一律に書き換えるのではなく、「現行 SoT として現在形・行番号付きで参照する live citation（=修正対象）」と「過去形・period-accurate な旧名を残す historical 記述（=据え置き）」を区別する。"
promote: rite-plugin
created: "2026-05-24T18:01:50Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260524T175056Z-pr-1132.md"
  - type: "fixes"
    resource: "raw/fixes/20260528T073410Z-pr-1166.md"
  - type: "fixes"
    resource: "raw/fixes/20260528T083422Z-pr-1166.md"
tags: ["historical-preservation", "rename-pr", "retired-fixture"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-28T08:53:59+00:00" }
---

# dead reference 整理では live citation と historical 記述を区別する

## 概要

削除・改名されたファイル / シンボルへの参照を整理する PR では、すべての出現を一律に書き換えるのではなく、「現行 SoT として現在形・行番号付きで参照する live citation（=修正対象）」と「過去形・period-accurate な旧名を残す historical 記述（=据え置き）」を区別する。後者は CHANGELOG / migration-guide / design-snapshot として正しい記述であり、書き換えると歴史の正確性を損なう。

## 詳細

### 背景

`flow-state-update.sh`（v2→v3 で `flow-state.sh set` に統合・実ファイル不在）への dead reference を整理した起点事例は、tech-writer / prompt-engineer の 2 reviewer がともに実装一致を全項目検証し 0 findings（mergeable）で収束した。この doc-heavy な dead-ref 整理 PR から得た判断基準:

### live citation と historical 記述の判別

| 分類 | 特徴 | 対応 |
|------|------|------|
| **live citation** | 現行ツールとして現在形で参照、行番号付き（例: `flow-state-update.sh:221` を「現行 schema の SoT」として引用）、構造図・フィールド表・caller 列挙に列挙 | 実態（`flow-state.sh set`）へ修正、または行番号非依存の記述へ整理 |
| **historical 記述** | 過去形・period-accurate な旧名（commit message 引用、PR 履歴 record、設計当時のスナップショット） | 据え置き。CHANGELOG / migration-guide / design-snapshot は旧名で正しい |

同じ design doc 内でも、現在形・行番号付きの live citation は修正対象、過去形のスナップショット記述は historical として保持、と混在しうる（`multi-session-state.md` で実測）。「design docs は一律 historical だから対象外」という粗い除外は誤りで、参照の時制と SoT 主張の有無で個別判定する。

### find/replace 一括 rename の落とし穴

writer 列などを find/replace で一括 rename すると、従来は dead file 参照のため grep 検証「不能」だった主張が、live file への検証「可能」な反証へ変化しうる。実態検証を伴わずに機械置換すると、誤った主張を「検証可能な誤り」として固定してしまう。実例: `flow-state.sh` は `session-ownership.sh` を source していない（source するのは `state-path-resolve.sh` のみ）ため、caller 列挙は rename ではなく**除去**が正しかった。rename 前に実 caller を grep で確認する。

### schema drift は別種として切り出す

dead-ref 整理の最中に発見した別種の drift（`schema_version: 2→3` / phase enum 11→13 / `previous_phase` 削除等の schema drift）は、dead reference とは異なる問題種別のため同 PR に混ぜず別 Issue（#1131）に切り出す。スコープを混在させると検証範囲と収束 cycle が膨らむ。

### rename PR では active emit site と retired/historical 参照を峻別する

同じ判別軸は dead-ref 整理に限らず **rename refactor 全般**に適用される。sentinel rename 事例 (`:completed` → `:returned-to-caller`) は「旧 literal を歴史的記録として保持 (rewrite しない)」を原則としたが、cycle 16 で retired sub-skill (interview) の test fixture `[interview:completed]` をうっかり新形式に over-rename し、cycle 20 で develop 形式へ revert した。教訓:

- **rename 対象は「現行の active emit site」のみ**。retired / historical な対象 (引退した sub-skill の fixture、design-snapshot、AC の grep コマンド記録) は rename 対象外で、disclaimer 付き保持か旧形式 revert が正しい。
- **historical-preservation の網羅性**: 1 つの doc 群 (例 `docs/designs/`) に disclaimer を追加したら、同じ理由で残る sibling (`issue-622-repro.md` ↔ `issue-634-repro.md` 等) にも網羅追加して一貫性を保つ (cycle 16 → 17 で実施)。
- **scope 確認**: test fixture が `commands/`・`skills/` scope 外であることを grep で確認すれば、AC の残存チェック grep にも影響しない (over-rename は AC を満たしたまま historical 正確性だけ壊す silent regression)。

### 検証

live dead ref の消滅は grep で検証する（SPEC / skills reference / design docs = 0 件）。残存してよいのは historical のみ。この direction（outbound dead ref の消滅）に加え、ファイル削除時は inbound 参照も grep する（[[asymmetric-fix-transcription]] で確立した breadth × direction の 2 軸）。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)](../anti-patterns/stale-historical-comment-after-state-change.md)

## ソース

- [PR #1132 review results](../../raw/reviews/20260524T175056Z-pr-1132.md)
