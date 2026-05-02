---
title: "grep -c || echo 0 が \"0\\n0\" を吐き出す double-print 罠"
domain: "anti-patterns"
created: "2026-05-03T05:50:00+09:00"
updated: "2026-05-03T05:50:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260502T171105Z-pr-784.md"
  - type: "fixes"
    ref: "raw/fixes/20260502T171352Z-pr-784.md"
tags: ["bash", "grep", "test-script", "silent-failure"]
confidence: high
---

# grep -c || echo 0 が "0\n0" を吐き出す double-print 罠

## 概要

bash で `count=$(grep -cE pattern file || echo 0)` パターンを使うと、grep が match 0 件 (exit 1) のとき count 変数が `"0\n0"` (改行付き 2 行) に汚染される。`grep -c` は POSIX 仕様上 match 0 件でも stdout に "0\n" を出力するため、`|| echo 0` の fallback echo が追加で 0 を吐き、後続の `[ "$count" -gt 0 ]` 等の integer test が exit 2 + stderr 警告となる。

## 詳細

### 問題の構造

- `grep -c` は POSIX grep(1p) 仕様で match 0 件の場合も stdout に `0` を出力 + exit 1 を返す
- bash の `$(cmd1 || cmd2)` は cmd1 が失敗 (exit ≠ 0) すると **cmd1 の stdout も保持したまま** cmd2 を追加実行し、両方の stdout を結合する
- 結果: `count="0\n0"` (改行付き複数行) → `[ "$count" -gt 0 ]` が `bash: [: 0\n0: integer expression expected` で exit 2

### 同リポジトリでの既存警告

`plugins/rite/hooks/tests/session-start.test.sh:760` 付近に作者自身の警告コメント
が既に存在しており、同罠が以前にも踏まれていたことが分かる。それにも関わらず PR #784 で
新規 metatest が同じ罠を再導入した — **「プロジェクト内の慣用パターン参照不足」が原因**で、
既存ファイルに警告コメントが書かれていても新規追加時に参照されなければ意味がない。

### 正しいパターン

```bash
# OK: || true で exit 1 を吸収し、空文字を ${var:-0} で 0 にデフォルト化
count=$(grep -cE pattern file 2>/dev/null || true)
count=${count:-0}

# OK: -- で grep の終了 status を切り離す
if grep -qE pattern file; then
  count=$(grep -cE pattern file)
else
  count=0
fi
```

### 教訓

- bash test を新規追加するときは、既存 metatest を 1 ファイル以上参照して同種パターンが
  どう書かれているかを確認すること
- 「既存警告コメントは新規ファイルから参照されない」前提で、`session-start.test.sh:760`
  のような重要な慣用警告は **wiki 経験則化 (本ページ) して横断参照可能** にする方が信頼できる

## 関連ページ

- （関連ページなし）

## ソース

- [PR #784 review results](raw/reviews/20260502T171105Z-pr-784.md)
- [PR #784 fix results](raw/fixes/20260502T171352Z-pr-784.md)
