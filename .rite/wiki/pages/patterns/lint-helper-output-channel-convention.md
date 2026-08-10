---
title: "新規 lint helper は findings→stdout / summary→stderr(log()) の出力チャネル規約を兄弟 helper に揃える"
domain: "patterns"
description: "hooks/scripts/ に新規 lint / check helper を追加するとき、summary 行 (`==> Total ... findings: N`) は `echo` (stdout) ではなく `log()` (stderr, `--quiet` 尊重) で出力し、findings→stdout / progress+summary→stderr という兄弟 helper 多数派 (sh-cross-ref-check.sh 等) の出力チャネル規約に揃える。caller (lint.md) は `2>&1` 捕捉のため機能影響ゼロだが、揃えないと `--quiet` 時に新規 helper だけ summary が抑制されない非対称が残る。過去のレビューで bash-heaviness-check.sh の summary が echo(stdout) だった非対称を code-quality + error-handling 2 reviewer が独立指摘、1 行修正 (echo→log) で解消。findings 本体は stdout 維持。"
created: "2026-06-01T10:48:51+09:00"
updated: "2026-06-01T10:48:51+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260601T002552Z-pr-1222.md"
  - type: "fixes"
    ref: "raw/fixes/20260601T010229Z-pr-1222.md"
tags: ["bash", "lint-helper", "stdout-stderr-channel", "quiet-flag", "sibling-convention-conformance"]
confidence: high
---

# 新規 lint helper は findings→stdout / summary→stderr(log()) の出力チャネル規約を兄弟 helper に揃える

## 概要

`hooks/scripts/` に新規 lint / check helper を追加するとき、summary 行 (`==> Total ... findings: N` 等) は `echo` (stdout) ではなく `log()` (stderr, `--quiet` 尊重) で出力し、「findings 本体 → stdout / progress + summary → stderr」という兄弟 helper 多数派 (sh-cross-ref-check.sh / bang-backtick-check.sh / comment-line-ref-check.sh 等) の出力チャネル規約に揃える。caller (lint.md) は `2>&1` で merge 捕捉するため機能影響はゼロだが、揃えないと `--quiet` 指定時に新規 helper だけ summary が抑制されない非対称が残る。

## 詳細

### 問題

新規 `bash-heaviness-check.sh` の summary 行が `echo "==> Total bash-heaviness findings: ${total}"` (stdout) で実装されていた。先行 helper の多数派は同じ summary を `log()` (stderr、`QUIET=1` で抑制) で出力する。lint.md の Phase 3.x は全 helper を `--all 2>&1` で呼び出し regex で finding 数を抽出するため機能差は出ないが、以下の非対称が残る:

- `--quiet` 指定時に新規 helper だけ summary を抑制できない
- findings 本体 (stdout) と progress / summary (stderr) のチャネル分離規約からの逸脱

code-quality と error-handling の 2 reviewer が独立にこの非対称を指摘した (cycle 1)。1 行修正 (`echo` → `log`) で解消し、テスト・lint.md の regex 抽出は `2>&1` 捕捉のため無影響だった。

### canonical pattern

```bash
log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }   # stderr + --quiet 尊重
...
cat "$FINDINGS_FILE"                                        # findings 本体 → stdout (維持)
log "==> Total ... findings: ${total}"                     # summary → stderr (log 経由)
```

findings 本体は stdout のまま維持し、summary / progress のみ `log()` 経由に揃える。これで caller の `2>&1` 捕捉 + regex 抽出を壊さずに `--quiet` 尊重とチャネル一貫性を両立できる。

### 適用条件

新規 helper 追加 / 既存 helper 改修時は、兄弟 helper の `log()` 定義と出力チャネル割り当てを 1 つ参照して同型にする。`echo` 派の先例 (wiki-growth-check.sh / gitignore-health-check.sh) もあるため絶対規約ではないが、多数派 (log 派) に揃えるのが `--quiet` 一貫性の点で望ましい。

## 関連ページ

- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [PR #1222 review results](../../raw/reviews/20260601T002552Z-pr-1222.md)
- [PR #1222 fix results](../../raw/fixes/20260601T010229Z-pr-1222.md)
