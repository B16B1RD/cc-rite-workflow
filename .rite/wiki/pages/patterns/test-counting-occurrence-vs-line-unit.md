---
title: "ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない"
domain: "patterns"
description: "charter 違反パターンの上限・下限を機械検証する ratchet test では、measurement unit は **occurrence (`grep -oE pattern | wc -l`)** に統一すること。"
created: "2026-05-08T17:15:33+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260508T171533Z-pr-906.md"
  - type: "fixes"
    resource: "raw/fixes/20260508T172017Z-pr-906.md"
  - type: "fixes"
    resource: "raw/fixes/20260807T082131Z-pr-2135.md"
tags: ["bash", "test-design", "ratchet-test", "grep", "measurement-unit"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T18:40:00+09:00" }
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

### 長い 1 行段落では `grep -c` が黙って過小評価する

上表の「informational summary は line 単位でよい」は、**1 行が短い**ことを暗黙の前提にしている。長い段落を 1 行で書く markdown ではこの前提が崩れる。

ある PR で `docs/CONFIGURATION.md` の safety 表・backstop 節（いずれも 1 行 1000 字超）に count pin を掛けたところ、期待値 3 に対し `grep -c` の実測が 2 を返した。同一行に対象文字列が 2 つ同居していたためである。`grep -o ... | wc -l` に変えると 4 が返り、そこで初めて「下限制約の記述も同じ網に入る」ことが判明した — **単位の誤りが件数を狂わせただけでなく、pin の対象集合の理解そのものを誤らせていた**。

したがって ratchet 用途でなくとも、**行長が制御できない散文ファイルに count pin を掛けるときは occurrence 単位を使う**。line 単位が許容できるのは「1 行 1 出現」が構造的に保証される場合（コード行・表の 1 行 1 レコード等）に限る。

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
- [pin の説明文に pin 対象の literal を書くと、注記自身が出現数に数えられて count pin が落ちる](../anti-patterns/pin-note-containing-pinned-literal.md)

## ソース

- [レビュー結果](../../raw/reviews/20260508T171533Z-pr-906.md)
- [fix 結果](../../raw/fixes/20260508T172017Z-pr-906.md)
- [長い 1 行段落での grep -c 過小評価](../../raw/fixes/20260807T082131Z-pr-2135.md)
