---
type: "anti-patterns"
title: "git diff の出力形状を前提にしたパーサは、git の設定と変更種別で黙って空振りする"
domain: "anti-patterns"
description: "git diff の出力形状は、利用者の設定（引用・prefix・hunk の結合幅・textconv）と rename 検出で変わる。解析側で形の列挙を増やすより、呼び出し引数で形を固定し、固定した引数ごとに外すと落ちるテストを置く。範囲検査では移動元と移動先の両方を列挙する。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T06:02:43Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-28T05:02:36Z" }
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
  - type: "reviews"
    resource: "raw/reviews/20260928T043614Z-pr-3387.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T050041Z-pr-3387.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T044436Z-pr-3387.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T050633Z-pr-3387.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T052332Z-pr-3387.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T053004Z-pr-3387.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T054345Z-pr-3387.md"
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

### 既存パーサの規則を引き継がない再実装が同じ穴を再生産する

新しい機能のために `git diff -U0` のパーサを書き直したところ、hunk 内の `--- ` / `+++ ` で始まる内容行をファイル見出しと読み、同じファイルの後続 hunk を失った。既存の共有パーサが持つ「`diff --git` から最初の `@@` までだけ見出しを読む」ガードを引き継いでいなかった。次の cycle では、既存パーサが固定している `--src-prefix` / `--dst-prefix` も引き継いでおらず、利用者の gitconfig（`diff.noprefix` / `diff.mnemonicPrefix`）で出力が変わる穴が見つかった。修正は新しい機構を足さず、既存パーサと同じ規則へ差し戻す形で行った。git の出力を読む処理を新しく書くときは、先に同じ出力を読む既存の処理を探し、その正規化と固定を一式で引き継ぐ。

### 存在判定と取得は同じ対象を見る。git の失敗を「無い」に倒さない

- `ls-tree` の先頭行だけで「ファイルとして存在するか」を判定すると、末尾スラッシュ付きのディレクトリ path が子要素の blob によって通ってしまう。`ls-tree -z` の出力から、名前が要求した path と一致する blob だけを採る形にし、判定と取得が同じ対象（`{head}:{path}`）を見るようにする
- `git show` の失敗を黙って「行なし」に倒すと、公開した reason 表（git 失敗）と実際に返る reason（契約が見つからない）が食い違う。種類確認（`ls-tree` で blob か）を取得の前に行い、それ以外の失敗は git 失敗として止める。stderr の文言照合には頼らない
- 種類確認の前に冗長な存在確認（`rev-parse`）を重ねない。前の cycle で足した `rev-parse` を削ると、直後の `ls-tree` が返す具体的な失敗理由がそのまま利用者に届くようになった（足した確認が後段の診断を隠していた）
- 修正後は旧実装へ戻す変異を入れ、追加したテストがそれぞれ落ちることを確かめる。前の cycle の修正が足した分岐に、外すと落ちるテストが無いことは変異で初めて分かった

### 設定を flag の列挙で塞ぐと隣接する設定が残る — hunk の結合幅

prefix と textconv を固定した後、`-U0` の hunk 範囲をそのまま変更行とみなす解析に、別の設定の穴が見つかった。利用者の gitconfig に `diff.interHunkContext` があると、近接する hunk が間の未変更行ごと 1 つに結合され、解析は未変更行を変更行として受理する。`-U0` を指定しても結合幅は別の設定なので防げない。

- hunk 範囲を変更行として扱う解析は `--inter-hunk-context=0` も呼び出し側で固定する
- 設定を与えた fixture で、hunk の間の行が拒否されることをテストで固定する
- 出力の形を変えうる設定は一式で考え、1 つ塞ぐたびに隣接する設定を確かめる。後のレビューでは `--no-ext-diff` と `--no-color` がまだ固定されていないことも挙げられた
- 同じ `-U0` の出力を解析する既存の helper にも結合幅を固定していないものがあった。1 か所を固定したら、同じ出力を読む兄弟の呼び出しを grep で洗う

### 利用者の設定を与えるテストは、その設定が出力を変える経路で与える

`diff.mnemonicPrefix` が接頭辞を変えるのは index や作業ツリーとの比較だけで、commit 同士の `A...B` では `a/` `b/` のまま出る。commit 間差分を解析する処理にこの設定を与える回帰ケースは、固定の有無を何も区別しない。設定を与えるテストを足すときは、その設定が実際に出力を変える経路かを先に確かめる。

textconv の固定を確かめるには、行数を変えるドライバ（各行を重複させる `sed p` など）を `.git/info/attributes` と `diff.<name>.textconv` で与えるとよい。固定が外れると行番号のずれとして検出できる。

固定した引数ごとに、その引数を外すとテストが落ちることを変異で確かめる。追加した引数（`--no-textconv` など）を外しても通るテストは、その引数の意図を固定していない。この変更では、接頭辞・結合幅・textconv の各固定について、複数の reviewer が変異で落ちることを確かめ、blocking 0 件で収束した

## 関連ページ

- [変数名の字句解析に依存した prefix 導出は壊れる](../patterns/bash-variable-name-lexing-defeats-prefix-derivation-regex.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T125803Z-pr-2582.md)

- [レビュー結果](../../raw/reviews/20260916T070028Z-pr-2906.md)
- [修正と回帰検証](../../raw/fixes/20260916T070742Z-pr-2906.md)
- [レビュー結果（diff の prefix 設定で除外判定が外れる移動の相殺）](../../raw/reviews/20260925T124519Z-pr-3087.md)
- [レビュー結果（++ で始まる追加行のヘッダ誤読）](../../raw/reviews/20260925T140903Z-pr-3095.md)
- [レビュー結果（hunk 内の内容行を見出しと読む再実装）](../../raw/reviews/20260928T043614Z-pr-3387.md)
- [レビュー結果（prefix 固定の未継承と ls-tree の存在判定）](../../raw/reviews/20260928T050041Z-pr-3387.md)
- [fix 結果（既存パーサの規則へ差し戻す）](../../raw/fixes/20260928T044436Z-pr-3387.md)
- [fix 結果（出力形式を呼び出し引数で固定し、ls-tree の判定を blob の名前一致へ差し替え）](../../raw/fixes/20260928T050633Z-pr-3387.md)
- [レビュー結果（hunk の結合幅の設定と、出力を変えない設定の回帰ケース）](../../raw/reviews/20260928T052332Z-pr-3387.md)
- [fix 結果（hunk の結合幅の固定と、設定が効く経路での変異確認）](../../raw/fixes/20260928T053004Z-pr-3387.md)
- [レビュー結果（固定した引数ごとの変異確認と、未固定の引数・兄弟 helper）](../../raw/reviews/20260928T054345Z-pr-3387.md)
