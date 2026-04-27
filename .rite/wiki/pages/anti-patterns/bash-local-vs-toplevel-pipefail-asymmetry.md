---
title: "function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差で writer/reader 非対称が偶然 mask される"
domain: "anti-patterns"
created: "2026-04-27T23:01:24+00:00"
updated: "2026-04-27T23:01:24+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260426T231807Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T232316Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T233931Z-pr-688.md"
tags: ["bash", "set-e", "pipefail", "writer-reader-asymmetry", "silent-failure"]
confidence: high
---

# function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差で writer/reader 非対称が偶然 mask される

## 概要

`set -euo pipefail` 配下の同型コードでも、**function 内の `local v=$(cmd)` と top-level の `v=$(cmd)` は `set -e` 伝播の挙動が異なる**。前者は `local` builtin が常に exit 0 を返すため pipeline の exit 1 を mask して continuation するが、後者は exit 1 が伝播し helper script 全体を silent kill する。この非対称により、writer 側 (`local v=$(...)`) で偶然 mask されている pipefail bug が、reader 側 (top-level `v=$(...)`) で初めて顕在化する経路が生まれる。canonical fix は両側で `v=$(cmd) || v=""` の defensive 吸収を対称化すること。

## 詳細

### 症状

- writer (`flow-state-update.sh:_resolve_schema_version` 関数内) と reader (`state-read.sh` top-level) で **同型コード** を書いていたにもかかわらず、reader 側だけが silent exit を発生させた。
- 再現条件: `flow_state:` セクションは存在するが特定キー (`schema_version:`) が欠落する degenerate config (例: `enabled: true` のみの YAML)。
- `set -euo pipefail` + grep no-match (exit 1) の組み合わせで、reader 側の top-level `v=$(grep -E ... | head -1 || true)` が pipefail で exit 1 → `set -e` で helper 全体を silent kill。
- writer 側は `local v=$(...)` の形だったため、`local` builtin の exit 0 が pipeline 失敗を mask して継続。

### Root cause

`local v=$(cmd)` は構文上 **2 つの操作** に分解される:

1. `cmd` の実行 (subshell で pipefail 適用)
2. `local v=...` の代入 (`local` builtin の実行)

bash は **最後に実行された builtin の exit code** を `$?` として返す。`local` は常に exit 0 を返すため、`cmd` 内部の pipeline failure が `local` で覆い隠される (= `set -e` が発火しない)。

一方 top-level の `v=$(cmd)` は単一の代入操作で、`cmd` の exit code がそのまま `$?` になる。pipefail で `grep` が exit 1 を返すと `set -e` が即座に発火する。

### 検出パターン

- error-handling reviewer が `state-read.sh:78-91` を HIGH 指摘、security reviewer が独立に MEDIUM 指摘 → cross-validation で confidence boost。
- 別の reviewer が writer 側 (`flow-state-update.sh:87-109`) を「同型コードだが偶然 mask されている fragile path」として併せて指摘。

### canonical fix

両側で **明示的に `|| v=""` を付ける**:

```bash
# Reader (top-level)
v=$(grep -E '^\s+schema_version:' rite-config.yml | head -1 || true) || v=""

# Writer (function 内)  ※既存 mask に依存せず明示化
local v
v=$(grep -E '^\s+schema_version:' rite-config.yml | head -1 || true) || v=""
```

writer 側は本来 fix 不要 (偶然 mask されている) だが、defense-in-depth として対称化する。`local v=$(...)` の `local` mask に依存し続けると、後で `local` を外すだけで silent regression に戻る。

### 検証手段

degenerate config を fixture で再現する TC を追加:

```bash
# Fixture: schema_version 欠落 config
cat > rite-config.yml <<EOF
flow_state:
  enabled: true
EOF

# helper の exit code と stdout を assert
output=$(bash plugins/rite/hooks/state-read.sh --field phase --default "")
rc=$?
assert_eq "$rc" 0  # silent kill ではなく正常終了
assert_eq "$output" ""  # default 値が返る
```

### scope 判断

- AC-4 完全達成のためには writer 側にも対称 fix が望ましい。
- ただし scope が膨張するため別 Issue 推奨 (security reviewer が「writer 側にも同形 guard を追加する別 Issue」として記録)。
- reader 側だけ explicit guard で対称化する fix が当該 PR の scope に最適。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](../anti-patterns/bash-if-bang-rc-capture.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)

## ソース

- [PR #688 review results (cycle 1)](raw/reviews/20260426T231807Z-pr-688.md)
- [PR #688 fix results (cycle 1)](raw/fixes/20260426T232316Z-pr-688.md)
- [PR #688 fix results (cycle 3 — user scope expansion)](raw/fixes/20260426T233931Z-pr-688.md)
