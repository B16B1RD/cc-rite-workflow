---
title: "Peer pattern の drift 判定は canonical schema 不変条件で cross-check する"
domain: "patterns"
description: "reviewer が「neighbor pattern と drift」と指摘した際、neighbor 自身が drift 元の可能性があるため、canonical schema の不変条件 (例: `WORKFLOW_INCIDENT=1` family の `sep_count=3` semicolon-separated key=value invariant) で direction を機械検証してから fix する。隣接パターンの**方向**だけを真とすると逆方向に振る silent regression を招く。過去のレビュー事例 fix cycle 2 で実測 — cycle 1 fix が parenthetical `(rc=$var)` 形式に揃えたが canonical schema は semicolon-separated `; rc=$var` で `sep_count=3` invariant を持っており cycle 1 fix の方向が逆だった。sentinel family (`WORKFLOW_INCIDENT` vs `REVIEW_SOURCE_*`) は別 schema を持つため family を跨いだ cross-check は無効。"
promote: rite-plugin
created: "2026-05-18T04:00:00+00:00"
updated: "2026-05-18T04:00:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260518T031424Z-pr-1035.md"
tags: []
confidence: high
---

# Peer pattern の drift 判定は canonical schema 不変条件で cross-check する

## 概要

reviewer が「neighbor pattern と drift している」と指摘した際、neighbor 自身が drift 元である可能性があるため、`canonical schema` の不変条件 (例: `WORKFLOW_INCIDENT=1` family の `sep_count=3` semicolon-separated key=value invariant) で direction を機械検証してから fix する。隣接パターンの**方向**だけを真とすると逆方向に振ってしまう silent regression を招く。sentinel format drift 事例の fix cycle 2 で実測 (cycle 1 fix が parenthetical `(rc=$var)` 形式に揃えたが、canonical schema 側は semicolon-separated `; rc=$var` で `sep_count=3` 不変条件を持っており、cycle 1 fix の方向が逆だった)。

## 詳細

### 問題: neighbor pattern direction の二重 drift リスク

review fix サイクルで「site X が site Y と非対称」と指摘されたとき、典型的な fix は「site Y に合わせて site X を書き換える」だが、neighbor pattern Y 自身が past の partial fix で drift している可能性がある。両者を比較するだけでは「どちらが正しい方向か」を判定できないため、第 3 の参照点 = **canonical schema の不変条件**で direction を機械検証する必要がある。

### 実例: sentinel format drift 事例 (cycle 2)

`commit_err` mktemp failure の WARNING 文字列と fallback sentinel `details=` 値の format で 2 通り存在:

- A: `(rc=$mktemp_commit_err_rc)` (parenthetical)
- B: `; rc=$mktemp_commit_err_rc` (semicolon-separated key=value pair)

同事例の cycle 1 fix では「neighbor pattern (L797 find_err) が A 形式」を根拠に A 方向に揃えた。cycle 2 review で「`WORKFLOW_INCIDENT=1; type=...; details=...; rc=...` の canonical schema は `sep_count=3` semicolon-separated invariant で、A 形式は schema 違反」と CRITICAL 指摘。cycle 1 fix が逆方向に振った fix 自体が drift 源になっていた。

### Canonical schema 不変条件の cross-check 手順

1. **fix 候補の方向 A/B を特定する** (neighbor pattern との比較で suggest される方向)
2. **canonical schema の SoT を grep で特定する** (例: `references/workflow-incident-emit-protocol.md` の sentinel format 定義、TC 番号付きの testcase 列)
3. **不変条件を抽出する** (例: `sep_count=3`, `field 順序 type → details → 任意拡張`, `key=value 形式`)
4. **A 方向 / B 方向が不変条件を満たすか機械検証する**
5. **不変条件を満たす方向を採用する** (両方満たす場合は SoT の **canonical 例**との literal 一致で決定)

### Sentinel family 区別の必要性

`WORKFLOW_INCIDENT=1` family と `REVIEW_SOURCE_*_FAILED=1` family は別 schema を持つ。前者は `sep_count=3` semicolon-separated 不変条件、後者は parenthetical 形式が canonical の場合もある。canonical schema は **sentinel family 単位** で定義されており、family を跨いだ cross-check は無効。

family を識別する手順:
- sentinel 行の prefix (`WORKFLOW_INCIDENT=`, `REVIEW_SOURCE_*=`, etc) で family を確定
- 各 family の SoT (references/ 配下) を grep で特定
- 該当 family の不変条件のみを cross-check 対象とする

### 自動化への道筋

将来の `/rite:lint` で以下を機械検証する余地がある:

- `WORKFLOW_INCIDENT=1` を含む行が `sep_count=3` invariant を満たすか
- `details=` 値内に parenthetical `(rc=...)` が混入していないか
- canonical schema の SoT (references 配下) と各 emit site の field 順序が一致するか

### 関連: 4-cycle convergence pattern

同事例は cycle 1 で line anchor → cycle 2 で canonical schema 違反 → cycle 3 で line drift 再発 → cycle 4 で symbolic anchor 化により 0 findings に収束した 4 cycle 履歴を持つ。canonical schema cross-check が cycle 2 で発火していたのは、partial fix が cycle 1 で逆方向に振ったことを cycle 2 reviewer が canonical SoT との比較で気づいたため。**fix 前に canonical schema cross-check を行えば cycle 2 は scope 削減できた可能性**がある。

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](./drift-check-anchor-semantic-name.md)

## ソース

- [PR #1035 fix cycle 2 (canonical sentinel schema sep_count=3 invariant の peer cross-check)](../../raw/fixes/20260518T031424Z-pr-1035.md)
