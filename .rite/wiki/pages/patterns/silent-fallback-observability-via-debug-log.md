---
title: "【現行仕様では廃止】resolver / helper 失敗時の silent fallback は debug log で観測性を確保する"
domain: "patterns"
description: "`RITE_DEBUG` gate の debug log で legacy fallback を観測する方式は採らない。想定外の失敗はエラーで止め、fallback を置く場合は常に可視の warning を出す。legacy の `.rite-flow-state` fallback も撤去済み。"
promote: rite-plugin
created: "2026-04-30T08:03:08Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260430T074655Z-pr-750-cycle-1.md"
  - type: "reviews"
    resource: "raw/reviews/20260430T074221Z-pr-750.md"
  - type: "reviews"
    resource: "raw/reviews/20260709T055242Z-pr-1808.md"
  - type: "fixes"
    resource: "raw/fixes/20260709T055810Z-pr-1808.md"
tags: [observability, silent-failure, debug-log, defense-in-depth]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-09T06:56:16+00:00" }
---

# 【現行仕様では廃止】resolver / helper 失敗時の silent fallback は debug log で観測性を確保する

## 概要

（現行仕様では廃止: resolver 失敗時に legacy 値へ fallback し、その観測を `RITE_DEBUG` gate の debug log に任せる方式は採らない。想定外の失敗はエラーで止め、fallback を置く場合は常に可視の warning を出す。legacy の `.rite-flow-state` fallback も、現行は v3 のみで撤去済み。）

## 詳細

### 問題の構造 / Canonical fix

（現行仕様では廃止: `RITE_DEBUG` gated の debug log で silent legacy fallback を観測する canonical fix と、fallback が解決先を変える場合の常時 WARNING 事例は、legacy fallback 自体の撤去により成立しない。）

### 上位 Pattern との関係

- `mktemp-failure-surface-warning.md` は mktemp 単体の silent 握り潰しを WARNING + `[CONTEXT]` sentinel で可視化する pattern。本 pattern はそれを「resolver / helper 経由の silent fallback」へ一般化したもの
- `stderr-merge-silent-sentinel-suppression.md` は `2>&1 | head` で sentinel が消える self-defeating observability の anti-pattern。本 pattern は「stderr を tempfile に退避 + RITE_DEBUG gated emit」で対称的に解決する

## 関連ページ

- [バグ修正PRが新設したエラーパス自身にも回帰テストを追加する](./bugfix-new-error-path-needs-regression-test.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)
- [`2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される (self-defeating observability)](../anti-patterns/stderr-merge-silent-sentinel-suppression.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [fix 結果](../../raw/fixes/20260430T074655Z-pr-750-cycle-1.md)
- [レビュー結果](../../raw/reviews/20260430T074221Z-pr-750.md)
