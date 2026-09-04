---
title: "新規 lint helper は findings→stdout / summary→stderr(log()) の出力チャネル規約を兄弟 helper に揃える"
domain: "patterns"
description: "`hooks/scripts/` に新規 lint / check helper を追加するとき、summary 行は stderr（`log()`、`--quiet` 尊重）へ出し、findings 本体は stdout に残す。findings を stdout に出す契約は、呼び出し側がコマンド置換で stdout を閉じると指摘が会話から消え、非ゼロ終了の検出結果が握り潰されるため、チャネル割り当てと呼び出し方は対で守る。"
created: "2026-06-01T10:48:51+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260601T002552Z-pr-1222.md"
  - type: "fixes"
    resource: "raw/fixes/20260601T010229Z-pr-1222.md"
  - type: "reviews"
    resource: "raw/reviews/20260904T004239Z-pr-2544.md"
  - type: "fixes"
    resource: "raw/fixes/20260904T005810Z-pr-2544.md"
tags: ["bash", "lint-helper", "stdout-stderr-channel", "quiet-flag", "sibling-convention-conformance"]
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-04T01:26:01Z" }
verified:
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-04T01:26:01Z" }
---

# 新規 lint helper は findings→stdout / summary→stderr(log()) の出力チャネル規約を兄弟 helper に揃える

## 概要

`hooks/scripts/` に新規 lint / check helper を追加するとき、summary 行は stderr（`log()`、`--quiet` 尊重）へ出し、findings 本体は stdout に残す。findings を stdout に出す契約は、呼び出し側がコマンド置換で stdout を閉じると指摘が会話から消え、非ゼロ終了の検出結果が握り潰されるため、チャネル割り当てと呼び出し方は対で守る。

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

### caller は findings stdout をコマンド置換で閉じない

チャネル規約のもう片面は呼び出し側にある。findings 本体を stdout に出す helper を `out=$(bash helper.sh ...)` で包むと、指摘は変数へ吸い込まれ会話に現れない。helper が検出ありで非ゼロ終了する設計なら、コマンド置換は rc=1 の出力ごと握り、オーケストレータは「指摘ゼロ」と誤読する。

呼び出し側の正規形は、findings を会話へ流す（コマンド置換しない）。rc だけが要るなら findings を捨てるリダイレクトではなく、helper 側で summary を stderr に分けたうえで呼び出しを素通しする。stdout をパースしたい別経路があるなら、会話表示用の実行とパース用の実行を分け、表示用を置換で閉じない。

この失敗は機械検出できる（スキル本文の fenced bash で、findings を stdout に出す helper 呼び出しが `$(...)` に包まれているか）。

### 適用条件

新規 helper 追加 / 既存 helper 改修時は、兄弟 helper の `log()` 定義と出力チャネル割り当てを 1 つ参照して同型にする。`echo` 派の先例 (wiki-growth-check.sh / gitignore-health-check.sh) もあるため絶対規約ではないが、多数派 (log 派) に揃えるのが `--quiet` 一貫性の点で望ましい。

## 関連ページ

- [stderr ノイズ削減: truncate ではなく selective surface で解く](../heuristics/stderr-selective-surface-over-truncate.md)

## ソース

- [レビュー結果](../../raw/reviews/20260601T002552Z-pr-1222.md)
- [fix 結果](../../raw/fixes/20260601T010229Z-pr-1222.md)
- [裸番号検出の cycle 1 レビュー結果](../../raw/reviews/20260904T004239Z-pr-2544.md)
- [裸番号検出の修正結果](../../raw/fixes/20260904T005810Z-pr-2544.md)
