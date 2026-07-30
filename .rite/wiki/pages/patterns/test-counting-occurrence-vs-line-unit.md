---
title: "ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない"
domain: "patterns"
created: "2026-05-08T17:15:33+00:00"
updated: "2026-05-08T17:20:17+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260508T171533Z-pr-906.md"
  - type: "fixes"
    ref: "raw/fixes/20260508T172017Z-pr-906.md"
tags: ["bash", "test-design", "ratchet-test", "grep", "measurement-unit"]
confidence: high
---

# ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない

## 概要

charter 違反パターンの上限・下限を機械検証する ratchet test では、measurement unit は **occurrence (`grep -oE pattern | wc -l`)** に統一すること。`grep -c file` (line 単位) と混在させると、1 行に複数出現する phrase の集約 slim を後続 PR で行う際 ratchet 漏れを構造的に起こす。実測で `AskUserQuestion` occurrence 35 vs line 34、`🚨` occurrence 41 vs line 35 の差が確認された (1 行に複数出現する 6 個分の差)。読みやすさ優先のスニペットでは line 単位を許容するが、ratchet (測定 → 比較 → 進捗判定) 用途では occurrence を canonical とする。

## 詳細

### 単位混在が起こす silent regression

起点事例の cycle 1 で test reviewer が以下の単位混在を独立検出 (3 reviewer 中 2 reviewer が高信頼度合意):

```bash
# 上限 assert (occurrence 単位)
issue_count=$({ grep -oE 'Issue #[0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')
cycle_count=$({ grep -oE 'cycle [0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')

# 下限 assert (line 単位 ← 混在 BAD)
ask_count=$(grep -c 'AskUserQuestion' "$start_md" || true)
mandatory_count=$(grep -c 'Mandatory After' "$start_md" || true)
```

実機計測で line vs occurrence の差が露呈:

| Phrase | line 単位 (`grep -c`) | occurrence 単位 (`grep -oE \| wc -l`) | 差 |
|--------|---------------------|-----------------------------------|-----|
| `AskUserQuestion` | 34 | 35 | 1 |
| `🚨` | 35 | 41 | 6 |

「1 行に複数出現する `🚨` が 6 個ある」状況で line 単位を採用すると、後続 PR で `🚨` を集約 (例: 4 出現/行 → 1 出現/行) するスリム作業を行ったとき、line 数は 1 のまま動かないため ratchet が「進捗あり」と検知できない。occurrence 単位なら 4→1 で 3 occurrence 削減として正しく measure できる。

### canonical pattern (cycle 1 fix)

下限・上限すべての assert を occurrence 単位 (`grep -oE | wc -l`) に統一:

```bash
set -euo pipefail
# pipefail 防御として `{ ... || true; }` で囲むこと (関連: grep-oE-wc pipefail silent abort)
ask_count=$({ grep -oE 'AskUserQuestion' "$start_md" || true; } | wc -l | tr -d ' ')
mandatory_count=$({ grep -oE 'Mandatory After' "$start_md" || true; } | wc -l | tr -d ' ')
issue_count=$({ grep -oE 'Issue #[0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')
cycle_count=$({ grep -oE 'cycle [0-9]+' "$start_md" || true; } | wc -l | tr -d ' ')
bell_count=$({ grep -oE '🚨' "$start_md" || true; } | wc -l | tr -d ' ')
```

### 単位選択の判断基準

| 用途 | canonical 単位 | 理由 |
|------|-------------|------|
| ratchet test (上限・下限) | occurrence (`grep -oE \| wc -l`) | 1 行集約での進捗が measure できる |
| informational summary (人が読む) | line (`grep -c`) | 「N 行に登場する」が直感的 |
| 1 行 N 出現の集約 PR を予定 | occurrence 一択 | line 単位だと進捗 invisible |
| metavariable whitelisting あり | occurrence + filter | `Issue #N` (リテラル N) を除外する awk filter と組み合わせ |

### Mutation test での検証

起点事例の cycle 1 fix では、unit 統一が ratchet test の sensitivity を上げたことを mutation test で検証:

- single create で `--phase` 削除 → asymmetric=1/32 検出
- 同一 block 内 2 creates の 2 件目で `--phase` 欠落 → asymmetric=1/2 検出
- 空 file → 全 actual=0 で test 自体は abort せず emit ([grep-oE wc pipefail silent abort](../anti-patterns/grep-oe-wc-pipefail-silent-abort.md) で対策)

これらを定期的に runtime 検証することで、unit 変更で sensitivity が低下していないか確認できる ([Mutation Testing Test Fidelity](./mutation-testing-test-fidelity.md))。

## 関連ページ

- [`grep -oE | wc -l` が ratchet ideal 値到達時に pipefail で silent abort](../anti-patterns/grep-oe-wc-pipefail-silent-abort.md)
- [Mutation Testing Test Fidelity](./mutation-testing-test-fidelity.md)
- [Detection Mutation Strictness Symmetry](./detection-mutation-strictness-symmetry.md)

## ソース

- [PR #906 review results](../../raw/reviews/20260508T171533Z-pr-906.md)
- [PR #906 fix results (cycle 1)](../../raw/fixes/20260508T172017Z-pr-906.md)
