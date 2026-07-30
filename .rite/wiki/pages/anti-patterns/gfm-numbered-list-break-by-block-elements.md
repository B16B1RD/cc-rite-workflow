---
title: "GFM 番号付きリスト分断: 連番途中に block 要素を挟むと新規リストとして render される"
domain: "anti-patterns"
created: "2026-05-13T06:43:41Z"
updated: "2026-05-13T06:43:41Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260513T060555Z-pr-946.md"
  - type: "fixes"
    ref: "raw/fixes/20260513T060844Z-pr-946.md"
tags: ["markdown", "gfm", "rendering", "numbered-list", "review-finding", "cross-validated"]
confidence: high
---

# GFM 番号付きリスト分断: 連番途中に block 要素を挟むと新規リストとして render される

## 概要

GFM (GitHub Flavored Markdown) で `1. ... N.` の連番リストを書く際、items 間に table / paragraph / 注釈などの block 要素を挟むと、後続 item が新規リスト (`1. ` から再採番) として render される。連番の論理的連続性が表示上は分断され、読者は items 4-5 を「別のリスト」と誤認する。

## 詳細

### 観測

`commands/wiki/ingest.md` Phase 4 overview の番号付きリスト (items 1-4) と、新規追加した item 5 「関連ページの特定」の間に、(a) `#### アクション判定表` table と (b) `**注意**: ...` paragraph が挟まれていた。GFM render 上、item 5 が新規リスト (`1. ` から再採番) として表示され、items 1-4 と論理的に連続している意図が破断していた。

cross-validation: prompt-engineer reviewer (confidence 75) と code-quality reviewer (confidence 80) が独立検出。同一ファイル内の他の numbered-list (Phase 5.0 / Phase 8.3) は中間に block 要素を挟まず連続配置を維持していたため、原因仮説 (GFM の list-continuation 仕様) は文書内サンプルとの対比で立証された。

### 発生条件

- 番号付きリスト items 間に以下の block 要素のいずれかが挟まる場合に発生:
  - table (`| ... |` 行)
  - paragraph (空行で区切られた説明文)
  - `**注意**:` 等の強調パラグラフ
  - blockquote (`> ...`)
- inline 要素 (例: bold/italic 装飾、リンク) は同一段落内なら影響なし

### Canonical fix (cross-validated)

PR #946 fix で 2 通りの解決手段が canonical として確立:

1. **item を 1 行形式に圧縮**: `N. **短い見出し**: 簡潔な説明` の 1 行 bullet に保ち、補足は別 sub-heading に切り出す
2. **補足情報を別 h4 sub-heading に独立化**: 連番リストの直後に `#### サブセクション` を配置し、table / paragraph はその下に格納する。connecting prose (例: 「以下の表は item 4 の判定基準を補足します」) を sub-heading 冒頭に置くことで連続性を視覚化

PR #946 では (2) を採用し、Phase 4 overview list 直下に `#### アクション判定表 (Step 4 用)` を配置することで item 1-5 の連続性を回復した。

### 検出シグナル

- GFM プレビュー (GitHub PR diff / VSCode preview) で連番が `1, 2, 3, 4, 1` のように再採番される
- `grep -nE '^[0-9]+\. ' file.md` の連番が論理的に連続しているのに表示が破断する
- review で「items 4-5 が別リストに見える」「step N が突然 step 1 になっている」指摘が挙がる

### 防御策

- 番号付きリストを書く際は items 間に block 要素 (table / paragraph / 強調) を挟まない
- 補足情報が必要な場合は別 sub-heading に切り出す
- PR review 時は GFM プレビューで連番の連続性を視覚確認する
- 長い説明が必要な item は inline `(詳細は §X.Y 参照)` で逃がす

## 関連ページ

- [prompt 内 numbered list は同型構造で書く（全 step に動作詳細 bullet を対称配置）](../patterns/prompt-numbered-list-isomorphic-structure.md)

## ソース

- [PR #946 review (HIGH 合意: Markdown list 分断の構造的 anti-pattern)](../../raw/reviews/20260513T060555Z-pr-946.md)
- [PR #946 fix (canonical fix 2 通りの確立)](../../raw/fixes/20260513T060844Z-pr-946.md)
