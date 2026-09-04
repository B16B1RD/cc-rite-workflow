---
title: "転記の網羅性は件数一致ではなく集合一致で検証する（件数一致は漏れと余剰が相殺して通る）"
type: heuristics
domain: "heuristics"
description: "ある一覧から別の一覧へ項目を転記した成果物（CHANGELOG / 対応表 / 移行チェックリスト等）のレビューで「両者の件数が一致するか」だけを検証すると、1 件の転記漏れと 1 件の余剰が同時に起きたときに相殺されて通る。両側から識別子の集合を機械抽出して要素単位で突合すると、漏れ・余剰・取り違えの 3 種を 1 回の照合で検出できる。"
created: "2026-08-30T10:28:04Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260830T102118Z-pr-2485.md"
tags: ["review-verification", "set-equality", "transcription-completeness", "changelog", "bilingual-parity", "offsetting-error"]
confidence: medium
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-30T10:28:04Z" }
---

# 転記の網羅性は件数一致ではなく集合一致で検証する（件数一致は漏れと余剰が相殺して通る）

## 概要

ある一覧から別の一覧へ項目を転記した成果物（CHANGELOG / 対応表 / 移行チェックリスト等）のレビューで「両者の件数が一致するか」だけを検証すると、1 件の転記漏れと 1 件の余剰が同時に起きたときに相殺されて通る。両側から識別子の集合を機械抽出して要素単位で突合すると、漏れ・余剰・取り違えの 3 種を 1 回の照合で検出できる。

## 詳細

### なぜ件数一致では足りないか

転記は「元の一覧を読みながら書き写す」作業であり、**漏れと余剰は独立事象ではなく同じ誤読から同時に生まれる**。典型は、隣接する 2 項目のうち一方を飛ばして他方を二重に書く、あるいは似た項目を取り違えて別の識別子を書く形で、いずれも件数は変わらない。

さらに、転記元が「コミット subject の末尾番号」のように**別の番号体系**を含む場合（PR 番号を書くべき場所に Issue 番号を書く、その逆）、件数一致は取り違えを一切検出しない。集合の要素は変わっているのに濃度だけが保存されるためである。

count はスカラーへ縮約された情報で「どの要素が欠けたか」を失う。この構造は [共有 /tmp の leak 検査は count delta ではなく path 集合差分 (comm -13) で行う](../patterns/shared-tmp-leak-check-path-set-difference.md) と同型だが、あちらの相殺は並列プロセスの独立事象から生じるのに対し、本項の相殺は**単一の転記行為の中**で生じる。並列実行が無い場面でも成立するため「逐次だから安全」という反論が効かない。

### 検証の形

両側から識別子を機械抽出して集合として突合する。起点事例（リリース準備 PR の CHANGELOG レビュー）では次の形を採った:

```bash
# 転記元: 前回タグ以降の実装 commit → subject 末尾の番号は PR 番号
# それを closing keyword で Issue 番号へ解決してから集合にする
git log v0.13.2..HEAD --format='%s' --no-merges \
  | grep -oE '#[0-9]+' | tail -1 | tr -d '#' \
  | while read -r pr; do
      gh pr view "$pr" --json body --jq '.body' \
        | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
        | grep -oE '[0-9]+' | head -1
    done | sort -u > expected_ids

# 転記先: CHANGELOG の当該セクションから (#NNNN) を抽出
sed -n '/^## \[0.14.0\]/,/^## \[/p' CHANGELOG.md \
  | grep -oE '\(#[0-9]+\)' | tr -d '(#)' | sort -u > actual_ids

comm -3 expected_ids actual_ids   # 空なら集合一致
```

`comm -3` の左列が転記漏れ、右列が余剰（または取り違えの片割れ）を名指しする。件数比較だとこの 2 列が同数のときに通ってしまう。

### 第 2 軸 — 配置の一致も組で見る

英日ペアのように**同じ集合を 2 つの成果物が持つ**場合、識別子の集合一致だけでは「番号は両方にあるがセクションが違う」ドリフト（片方が Fixed、他方が 変更）を検出できない。識別子単独ではなく `(セクション, 識別子)` の**組**を抽出して比較すると、この軸も同じ 1 回の照合で閉じる。

```bash
# セクション見出しを状態として持ち、(section, id) の組を出す
awk '/^### /{sec=$2} /\(#[0-9]+\)/{ match($0,/\(#[0-9]+\)/); print sec, substr($0,RSTART+2,RLENGTH-3) }' \
  CHANGELOG.md | sort > en_pairs
```

日本語側は見出し語彙が異なる（`Fixed` ↔ `修正`）ため、比較前に対応表で正規化する。正規化表そのものが転記対象になるので、対応させる見出し語彙は両ファイルの実在見出しから抽出して作る（手書きしない）。

### 適用範囲

「一覧 A の全項目が一覧 B に現れること」を人間が読んで確かめる場面すべて。CHANGELOG のほか、Issue のタスクリストと実装 PR の対応、設定キーの移行表、reviewer が出した指摘と fix コミットの対応などが該当する。逆に、対象が数件で目視で全要素を保持できる規模なら集合化のコストが上回るため、機械抽出は要らない。

## 関連ページ

- [共有 /tmp の leak 検査は count delta ではなく path 集合差分 (comm -13) で行う](../patterns/shared-tmp-leak-check-path-set-difference.md)
- [新設要約文の「N 個の~系統」的な断定は対象外の類似構造を見落としやすい](../anti-patterns/unscoped-enumeration-claim-in-new-summary.md)

## ソース

- [レビュー結果](../../raw/reviews/20260830T102118Z-pr-2485.md)
