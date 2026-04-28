---
title: "DRY 集約助手の効果記述は『何が集約され、何が依然分散しているか』を明示する"
domain: "anti-patterns"
created: "2026-04-29T02:55:00+00:00"
updated: "2026-04-29T02:55:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260428T111028Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T105854Z-pr-688.md"
tags: ["dry", "helper-aggregation", "documentation-overstate", "drift-vector", "migration-completeness"]
confidence: high
---

# DRY 集約助手の効果記述は『何が集約され、何が依然分散しているか』を明示する

## 概要

DRY 化助手 (shared helper script / function) を導入する際、効果を「N 箇所更新が不要になり drift 防止」と記述しながら、実際には集約されたのは validation logic のような一部のみで、helper 名 list / 引数 schema / DEFAULT_* 配列のような他箇所の同期更新が依然必要なケース。caller は overstate されたコメントを読んで「片肺更新は構造的に防がれた」と誤解し、Issue 解決の核心理由 (drift 防止) と同型の drift を再発させる経路を許容する。

## 詳細

### PR #688 で実測した overstate パターン

PR #688 (累積 14 回目 38+ cycle、Issue #687 multi-state-aware flow-state read helper) cycle 12 review で MEDIUM × 2 として一斉 surface した:

#### Pattern 1: 集約スコープの overstate

`state-read.sh:62` / `flow-state-update.sh:67` のコメントが以下を主張:

> helper を 1 つ追加する際に 2 箇所更新が不要になり、drift 防止になる

実際には:

| 集約された | 集約されていない (依然 2 箇所同期更新を要する) |
|-----------|-----------------------------------------|
| validation logic (4 行 if/echo/exit) | helper 名 list (両ファイルに 7 entry × 2 箇所ハードコード重複) |
|  | 引数 schema (helper 関数に渡す arg の order / type) |
|  | error message format |

このコメント overstate は **Issue #687 root cause と同型の drift 再発許容経路** を文書レベルで許容する。読者が「2 箇所更新が不要」と誤読 → helper を追加する際に list 更新を 1 箇所のみで済ます → drift が発生。

#### Pattern 2: Migration 取り残し

新規 helper `_validate-helpers.sh` を 3 caller のうち 2 つ (`state-read.sh` / `flow-state-update.sh`) だけが使用し、3 つ目 (`resume-active-flag-restore.sh`) は旧 inline `for _helper in ...` ループを残存。3 caller 中 2/1 の不均一更新は DRY 化助手導入の **核心理由 (drift 防止) が部分的にしか達成されない** 状態。

cycle 12 fix で `_validate-helpers.sh` 呼び出しに置換し 3 caller 全てで一貫化したが、これは PR 内で発見された self-violation。

### 修正方針 (canonical)

集約助手を導入する際、コメントは「**何が集約され、何が依然分散しているか**」を両方明示する:

```bash
# 良い例 (PR #688 cycle 12 で適用)
# _validate-helpers.sh: helper 存在チェックの validation logic (4 行 if/echo/exit) を集約
# 注: helper 名 list (DEFAULT_HELPERS 7 entry) は依然両ファイルにハードコード重複している
#     真の DRY (DEFAULT_HELPERS 配列内蔵) は将来 Issue で検討
```

```bash
# 悪い例 (PR #688 cycle 12 で訂正済み)
# _validate-helpers.sh により helper を 1 つ追加する際に 2 箇所更新が不要になり、drift 防止になる
# (overstate: helper 名 list の 2 箇所ハードコード重複は依然存在)
```

### 真の DRY 化への path

集約助手を導入する PR で「真の DRY 化」を実現するには:

1. **助手内に DEFAULT_* 配列を内蔵**: helper 名 list を helper 自身に持たせて caller から API 経由で注入する
2. **caller が 1 箇所のみ更新で済む API 設計**: caller は新 helper 追加時に 1 行 (例: `_helper_validate "new-helper.sh"`) のみで済むように
3. **2 callsite の sed audit**: 既存 caller が 2 箇所重複を持つ場合、機械的に同期 audit する script を CI に追加

これら 3 点が揃わない PR は「validation logic だけ集約しました」とコメントに正直に書く。overstate は **Asymmetric Fix Transcription (PR #548) の文書版変種** であり、「対称位置の同期更新を要するが、コメントは片肺更新で済むかのように書く」drift vector を生む。

### 検出方法

PR review 時に以下を必須化:

- **集約 helper 導入の PR**: コメントで「N 箇所更新が不要」と謳う場合、`grep -c "helper-name" file_a file_b` で count 検証 (両ファイルに同数のハードコード重複が残っていれば overstate)
- **migration 取り残し**: `grep -rn "for _helper in"` のような旧 inline pattern が caller のいずれかに残っていないか確認 (3 caller 中 1 つが残ると DRY 化の意図が部分達成のみ)
- **DEFAULT_* 配列内蔵**: 真の DRY を要求する PR では集約 helper 内に list/array を持たせ、caller から「list の存在自体を knowing する code」を排除する

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)
- [兄弟 shell script の重複 helper は shared lib 抽出で解く](../heuristics/shell-script-shared-lib-extraction.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](./fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #688 cycle 12 fix (集約 overstate 訂正 + migration 取り残し解消, 7 findings)](../../raw/fixes/20260428T111028Z-pr-688.md)
- [PR #688 cycle 12 review (MEDIUM × 2 で集約 overstate / migration 取り残し検出)](../../raw/reviews/20260428T105854Z-pr-688.md)
