---
title: "Markdown code fence の balance は commit 前に awk で機械検証する"
domain: "patterns"
created: "2026-04-20T01:10:00+00:00"
updated: "2026-04-20T01:10:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260419T162557Z-pr-608-cycle2.md"
tags: []
confidence: high
---

# Markdown code fence の balance は commit 前に awk で機械検証する

## 概要

Bash block 末尾に新規 statement を追加する際、既存の閉じフェンス ``` ``` ``` 直前に挿入すると closing fence が欠落し fence count が奇数になる silent regression が発生する。後続の散文や Skill 呼び出し指示が bash コードとして誤解釈され、slash command preprocessor 層や renderer 層で CRITICAL な構造破綻を引き起こす。commit 前に `awk '/^```/{c++} END{print c}' file.md` で fence 数が偶数であることを機械検証する。

## 詳細

### 事象 (PR #608 cycle 2)

前 fix commit で `if ! ...; then ... fi` ブロックを既存閉じフェンスの直前に挿入した際、`fi` 行の直後に独立した閉じフェンス ``` ``` ``` が必要であることを 3 箇所すべて見落とした。結果として `cleanup.md` の bash code fence count が 144 (偶数、balanced) → 153 (奇数、UNBALANCED) になり、後続の散文 + Skill 呼び出し指示が bash code として renderer / preprocessor で誤解釈される構造バグに発展した (CRITICAL × 3)。

### canonical 検証コマンド

```bash
awk '/^```/{c++} END{print c}' path/to/file.md
# 結果が偶数 (0, 2, 4, ...) なら OK、奇数なら UNBALANCED
```

より具体的に diff を見るには:

```bash
# 開始/閉じ fence のみ抽出して目視確認
grep -n '^```' path/to/file.md | head -40
# bash blocks の総数 (概算)
grep -c '^```bash' path/to/file.md
```

### 適用タイミング

- bash block 末尾に新規 statement (`fi` / `done` / 新コマンド) を追加した後
- 既存 bash block を split / merge する編集の後
- review で「indentation drift」「code block の途中から散文っぽい行」が見えたとき

### 補強策

- pre-commit hook に `awk '/^```/{c++} END{exit c%2}' file.md` を組み込む
- `/rite:lint` の command-file-check で fence balance を検査する (将来実装候補)
- reviewer は code fence 境界の違和感 (indentation drift / 散文混入) を CRITICAL 候補として検出する

### 関連する失敗様態

- code fence 内に別の code fence を置こうとした結果、外側の fence が閉じる
- `> \`\`\`bash` のような quoted fence と通常 fence の混在
- edit 時に `old_string` が複数 fence を含み、一部のみ replace される

いずれも fence balance check で即検出可能。

## 関連ページ

- （関連ページなし）

## ソース

- [PR #608 fix cycle 2 (CRITICAL × 3 fence balance)](raw/fixes/20260419T162557Z-pr-608-cycle2.md)
