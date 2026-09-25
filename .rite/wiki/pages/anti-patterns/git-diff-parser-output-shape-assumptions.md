---
type: "anti-patterns"
title: "git diff の出力形状を前提にしたパーサは、git の設定と変更種別で黙って空振りする"
domain: "anti-patterns"
description: "git diff の出力形式と rename 検出は、変更パスの列挙結果を変える。対象範囲を検査する場合は引用・prefix の正規化に加え、移動元と移動先の両方を含む列挙契約が必要になる。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5[1m]", at: "2026-09-25T14:17:42Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T125803Z-pr-2582.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T070028Z-pr-2906.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T070742Z-pr-2906.md"
  - type: "reviews"
    resource: "raw/reviews/20260925T124519Z-pr-3087.md"
  - type: "reviews"
    resource: "raw/reviews/20260925T140903Z-pr-3095.md"
tags: ["git-diff", "parser", "silent-degradation", "portability"]
confidence: high
---

# git diff の出力形状を前提にしたパーサは、git の設定と変更種別で黙って空振りする

## 概要

`+++ b/<path>` の literal prefix 一致だけを入口にした diff パーサは、非 ASCII パス・pure rename・prefix なし設定の 3 条件で対象を 1 件も拾わず、「判定不能」が「未対応」に化ける silent degradation を起こす。空振りは例外を出さないため、機構は正常動作を名乗ったまま結論だけが反転する。

## 詳細

### 空振りする 3 条件

| 条件 | 出力形状 | 帰結 |
|---|---|---|
| `core.quotePath=true`（既定） | 非 ASCII パスが二重引用符 + 8 進エスケープで出る | literal 一致が外れる |
| pure rename（similarity index 100%） | `+++` 行を 1 つも出さない | 対象ファイルが列挙されない |
| `diff.noprefix=true` | `a/` `b/` prefix が消える | prefix 込みの一致が外れる |

いずれも「その変更が差分に存在しない」ことを意味しない。にもかかわらず、存在しないものとして扱う実装では、差分の有無を根拠にする判定（対応済み / 未対応、検査済み / 未検査）が反転する。

### 検出の手がかり

同一リポジトリの先行パーサが unquote 処理と条件付き prefix 剥がしを既に持っているのに、新規パーサがそれを継承していない — この非対称が目印になる。既存パーサが持つ正規化は、過去に同じ穴を踏んだ結果として足されていることが多く、新規実装が素の literal 一致で始まると同じ穴を再生産する。

### 書き方

- ファイル名の取得は `git diff --name-only -z`（NUL 区切り・quote なし）など、引用形式に依存しない経路を使う。移動元の削除も検査対象なら `--no-renames` を指定する
- 形状に依存する経路を選ぶなら、unquote と prefix 剥がしを入口に置き、rename を別経路で拾う
- 「1 件も拾えなかった」を成功ではなく判定不能として扱い、fail-loud にする

### 移動元の削除も対象範囲へ含める

rename 検出が有効な `--name-only` は、移動先だけを返すことがある。変更を許可したディレクトリへの移動であっても、対象外ディレクトリからの削除を伴うため、移動先だけの照合では範囲違反が通過する。範囲検査には `git diff --no-renames HEAD --name-only -z` を使い、削除元と追加先を別々に検査する。対象外から対象内へ staged rename する回帰テストを置くと、この列挙契約を実測できる。

### 形はパース側で正規化せず、呼び出し側で固定する

削除行と追加行を別々に走査する検出器で、削除側のヘッダから `a/` だけを剥がしていた。`diff.mnemonicPrefix=true` の環境ではヘッダが `c/` で始まり、除外パスの判定が外れて、検出すべき移動が見逃された。パース側で `a/` `c/` `i/` `w/` を列挙して剥がす方法もあるが、次に増える設定（外部 diff・textconv など）でまた漏れる。

- 呼び出し側で `--no-renames --src-prefix=a/ --dst-prefix=b/ --no-ext-diff --no-textconv` のように形を決める設定をすべて明示し、ユーザー設定を中和する
- 固定した項目ごとに、その設定を入れた sandbox で結果が変わらないことをテストで確かめる（固定しただけでテストが無い項目は、後の整理で外れても気付かない）
- 内容行の先頭が `-- ` や `++ ` だと diff 上では `--- ` / `+++ ` になる。ヘッダの判定は `diff --git` から最初の `@@` までに限り、削除側と追加側で同じガードを持たせる

### 1 つのパーサを直したら、同じ diff を読む兄弟パーサを洗う

ヘッダ区間を区別しない誤読は、同じ `-U0` diff を行頭の記号で読む別のスクリプトにも同じ形で残っていた。1 か所を直したら、`+++` / `---` / `diff --git` / `@@` を自前で解釈している箇所を grep で列挙し、同じガードを持つかを確かめる。ヘッダ区間の状態は、`diff --git` でのリセットと `@@` での遷移の両方をテストで押さえる（リセット漏れは複数ファイルの diff、遷移漏れは `++ ` / `-- ` で始まる内容行で検出できる）。

## 関連ページ

- [変数名の字句解析に依存した prefix 導出は壊れる](../patterns/bash-variable-name-lexing-defeats-prefix-derivation-regex.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T125803Z-pr-2582.md)

- [レビュー結果](../../raw/reviews/20260916T070028Z-pr-2906.md)
- [修正と回帰検証](../../raw/fixes/20260916T070742Z-pr-2906.md)
- [レビュー結果（diff の prefix 設定で除外判定が外れる移動の相殺）](../../raw/reviews/20260925T124519Z-pr-3087.md)
- [レビュー結果（++ で始まる追加行のヘッダ誤読）](../../raw/reviews/20260925T140903Z-pr-3095.md)
