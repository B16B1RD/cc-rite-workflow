---
type: "heuristics"
title: "@tsv+IFS read の field-shift hazard 横断監査は cut-f免除と空フィールド可否の2条件で判定する"
domain: "heuristics"
promote: rite-plugin
description: "`jq '[...] | @tsv'` の出力を `IFS=$'\\t' read -r a b c` で読む実装は、POSIX の IFS whitespace 規則により、tab を含む IFS では連続する区切り文字が1個に圧縮される。"
created: "2026-07-06T23:20:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260706T141300Z-pr-1767.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-06T23:20:00+09:00" }
---

# @tsv+IFS read の field-shift hazard 横断監査は cut-f免除と空フィールド可否の2条件で判定する

## 概要

`jq '[...] | @tsv'` の出力を `IFS=$'\t' read -r a b c` で読む実装は、POSIX の IFS whitespace 規則により、tab を含む IFS では連続する区切り文字が1個に圧縮される。中間フィールドが空文字列になると後続フィールドが左シフトし、データが誤った変数に格納される（field-shift hazard）。複数の呼び出し箇所を横断監査する際は、以下の2条件で「真に修正が必要な箇所」のみを機械的に絞り込める。

## 詳細

### 判定条件

1. **読み取り方式**: `IFS=$'\t' read` を使っているか、`cut -f1`/`cut -f2`等を使っているか
   - `read` + tab を含む IFS: **hazard あり**（POSIX の "IFS whitespace" 特別扱いにより連続区切り文字が圧縮される）
   - `cut -fN`: **hazard なし**（`cut` は区切り文字を文字通り扱い、連続する区切り文字も圧縮しない。実機検証: `printf 'A\t\tC' | cut -f2` は空文字列を正しく返す）

2. **フィールドの空文字列可能性**: 各フィールドが構造的に空文字列になり得るか
   - `(.x // 0) + 1` のような数値演算結果は常に非空
   - `(.x // "null")` のような文字列 fallback も常に非空
   - 末尾フィールドのみが空になり得る場合、シフト先が存在しないため実害なし（末尾より後ろにシフトする対象がない）
   - 中間または先頭フィールドが空になり得る場合のみ、実際に hazard が顕在化する

### 実例（4 hook の横断監査結果）

| 判定対象 | 読み取り方式 | 空になり得るフィールド | 結論 |
|---------|------------|----------------------|------|
| `session-start.sh` の `_reset_active_state()` | `IFS=$'\t' read` | `issue_number`（中間） | **hazard あり → 修正** |
| `pre-tool-bash-guard.sh` | `cut -f1/-f2/-f3` | (該当なし、cut のため無関係) | hazard なし |
| `work-memory-update.sh` | `IFS=read`（デフォルト） | なし（全フィールド `// 0)+1` or `// "null"`） | hazard なし |
| `post-compact.sh` | 既に `join("")` + `IFS=$'\x1f' read` | (対応済み) | 対象外 |

### 修正方法

hazard ありと判定した箇所のみ、`jq` 側を `@tsv` → `join("")`、bash 側を `IFS=$'\t'` → `IFS=$'\x1f'`（ASCII unit separator、0x1F）に変更する。unit separator は POSIX の "IFS whitespace" 特別扱い対象外の文字であり、連続する区切り文字が圧縮されず、空フィールドを保持できる。fallback 値（`|| _composite=$'\t\t'` 等）の区切り文字数も同様に更新すること（3フィールドなら2つの区切り文字）。

### 適用時の注意

- hazard なしと判定した箇所を「念のため」書き換えない。既存の `@tsv`+`cut`パターンや全フィールド非空パターンは動作上問題がなく、不要な書き換えはスコープ逸脱になる
- 実機での挙動再現（`printf`/`echo` で疑似データを流し込み修正前後を比較）により、判定の正しさを客観的に検証できる

## 関連ページ

- （関連ページなし）

## ソース

- [PR #1767 review results](../../raw/reviews/20260706T141300Z-pr-1767.md)
