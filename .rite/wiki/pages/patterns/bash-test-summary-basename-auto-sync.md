---
title: "bash test の summary 行は $(basename \"$0\") で自動同期する"
domain: "patterns"
created: "2026-05-03T05:50:00+09:00"
updated: "2026-05-03T05:50:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260502T171105Z-pr-784.md"
  - type: "fixes"
    ref: "raw/fixes/20260502T171352Z-pr-784.md"
tags: ["bash", "test-script", "self-reference", "drift-prevention"]
confidence: high
---

# bash test の summary 行は $(basename "$0") で自動同期する

## 概要

bash test スクリプトの summary 行 (`echo "─── foo summary ───"` 等) で実ファイル名を hardcode
すると、ファイル rename / コピー作成時に表示名と実体が drift する。`$(basename "$0")` で実行
ファイル名から自動取得すれば rename 後も常に整合し、cross-file consistency を維持できる。

## 詳細

### 問題

新規 bash test 追加時に summary 行を hardcode で書くと、以下のような drift が発生する:

```bash
# NG: hardcode するとファイル rename で drift
echo "─── 4-site-symmetry summary ───"
# ファイルが test-4-site-symmetry.sh から 4-site-symmetry.test.sh に rename されると
# 表示名 (4-site-symmetry) と実ファイル名 (4-site-symmetry.test.sh) が drift する
```

### 正しいパターン

```bash
# OK: $0 から自動取得
script_name=$(basename "$0")
echo "─── $script_name summary ───"
```

### 同リポジトリでの先行採用

`plugins/rite/hooks/tests/cross-session-guard-invocation-symmetry.test.sh` 等の既存 metatest は
既にこのパターンを採用しており、本パターンは「個別の発明」ではなく「リポジトリ慣用に追従すべき
共有規約」である。新規 bash test 追加時は **既存 13+ metatest の summary 行スタイルを 1 件以上
確認** してから書き始めること。

### 教訓

- bash test の自己参照は常に `$(basename "$0")` で行う (hardcode 禁止)
- リポジトリに既に複数の test 慣用パターンが confirmed されている場合、新規追加は必ず
  既存 1 件以上を参照する (LLM の独自設計より高信頼)
- summary 行 / header コメント / log message 等、自己参照する箇所はすべて同パターンを使う

## 関連ページ

- （関連ページなし）

## ソース

- [PR #784 review results](raw/reviews/20260502T171105Z-pr-784.md)
- [PR #784 fix results](raw/fixes/20260502T171352Z-pr-784.md)
