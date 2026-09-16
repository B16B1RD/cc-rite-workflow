---
type: "anti-patterns"
title: "macOS の awk の == は UTF-8 ロケールで照合比較になり、別の日本語文字列を等しいと判定する"
domain: "anti-patterns"
description: "macOS 標準の awk は UTF-8 ロケールで文字列の == をロケール照合で比較するため、別の日本語見出しを同じ見出しと判定し、Linux の gawk / mawk では再現しない誤判定を起こす。"
created: "2026-09-14T06:55:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-16T12:07:00Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5"
    at: "2026-09-14T11:20:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260914T064706Z-pr-2803.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T110010Z-pr-2816.md"
  - type: "reviews"
    resource: "raw/reviews/20260915T022940Z-pr-2829.md"
  - type: "reviews"
    resource: "raw/reviews/20260915T025127Z-pr-2829.md"
  - type: "fixes"
    resource: "raw/fixes/20260915T021146Z-pr-2829.md"
  - type: "fixes"
    resource: "raw/fixes/20260915T023331Z-pr-2829.md"
  - type: "fixes"
    resource: "raw/fixes/20260915T025447Z-pr-2829.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T111808Z-pr-2910.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T112742Z-pr-2910-fix.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T114658Z-pr-2910.md"
tags: ["portability", "awk", "macos", "locale", "diagnostics"]
confidence: high
---

# macOS の awk の == は UTF-8 ロケールで照合比較になり、別の日本語文字列を等しいと判定する

## 概要

macOS 標準の awk は UTF-8 ロケールで文字列の == をロケール照合で比較するため、別の日本語見出しを同じ見出しと判定し、Linux の gawk / mawk では再現しない誤判定を起こす。

## 詳細

### 観測された症状

Markdown の特定の節（`### 却下台帳`）に属する表の行を数える awk が、`$0 == head` で見出しを判定していた。macOS の CI ランナー（`/usr/bin/awk`、`LC_ALL=en_US.UTF-8`）では、後続の別の節の見出し `### 別の節` も `$0 == head` に一致し、節に入り直して節の外の表の行まで数えた。Linux の gawk / mawk、ソースからビルドした onetrue awk、Linux 上でビルドした Apple 版 awk のいずれでも再現しなかった。日本語の文字どうしで照合順序上の重みが区別されず、等しいと扱われたと考えられる。

### 書き方

日本語を含む文字列の等値判定は、ロケール照合を通らないバイト比較で書く。

```awk
index($0, head) == 1 && length($0) == length(head) { in_sec = 1; next }
```

前方一致だけなら `index($0, prefix) == 1` で足りる。`length` を併せて見るのは、`### 却下台帳（旧）` のような前方一致するだけの別見出しを弾いて、元の `==` と同じ意味を保つためである。

### 手元で再現しないときは、実機で評価したい条件を評価される位置で出す

原因を手元で再現できず、CI の実機に一時診断を仕込んで特定した。このとき、見出し判定の規則（`$0 == head { ...; next }`）より後ろに行ごとの出力を置いたため、見出し行に対する別の条件（`/^### /`）の結果は `next` で飛ばされて一度も出力されなかった。それを「一致しなかった」と読み違え、未観測の原因が恒久コメントと follow-up Issue の要件に転記された。

- 評価したい条件は、それを飛ばしうる `next` / `exit` より前で出力する
- 移植性の修正で原因を 2 つ以上書くときは、それぞれに観測の根拠があるかを確かめ、未観測のものは書かない

### macOS の CI が止めないなら、式の形の pin を書き換えに強くする

macOS の CI ジョブが `continue-on-error` だと、macOS でだけ起きる誤判定が戻っても merge は止まらない。Linux のテストは `==` のままでも通るので、戻ったことを捕まえられるのは「`==` で比べていない」ことを確かめる静的な pin だけになる。

その pin を `\$0 [!=]= head` のような禁止形の grep だけで書くと、`$0==head`（空白なし）や `head == $0`（被演算子の順序違い）に書き換えて戻した変更を素通りし、テストは green のまま通る。判定式の出現数を数える pin も、代入行が残っていれば件数は変わらない。

- 禁止形の grep は、空白の有無と被演算子の順序に依らない形にする
- それに加えて、使う側の規則行そのもの（例: `is_head { in_sec=1 }`）が期待どおりの件数あることを肯定形で pin する。禁止形を網羅するより、正しい形が在ることを数えるほうが書き換えに強い

### 日本語を比べる helper はロケールを C に固定し、宣言行を pin する

別の helper で、日本語の見出しを正規表現リテラルで判定していた箇所を文字列比較に置き換えても、macOS の CI では同じ空出力が続いた。式を 1 つずつ直すと、同じ helper に残る他の `==` や正規表現の比較を取りこぼす。helper の冒頭で `export LC_ALL=C` を宣言すると、awk の文字列比較と正規表現の照合がすべてバイト単位になり、同種の取りこぼしがなくなった。Linux の awk ではこの宣言を消しても失敗が再現しないため、宣言行そのものを `grep -qx 'export LC_ALL=C'` のような静的テストで固定する。

### ロケールを C に固定すると文字クラスも ASCII に狭まる

`LC_ALL=C` の下では `[[:space:]]` が ASCII の空白しか表さない。固定する前は UTF-8 ロケールの gawk が全角空白（U+3000）も空白として削っていたため、「根拠のセルが全角空白だけの行を空とみなす」検査が、固定した途端に黙って通るようになった。固定と同時に、全角空白をバイト列として明示的に扱う:

```awk
awk -F'|' -v zs="$(printf '\343\200\200')" '
  function trim(s,   n, z) {
    z = length(zs)
    do {
      n = length(s)
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      if (index(s, zs) == 1) s = substr(s, z + 1)
      if (length(s) >= z && substr(s, length(s) - z + 1) == zs) s = substr(s, 1, length(s) - z)
    } while (length(s) != n)
    return s
  }
'
```

C ロケールでの `index` / `substr` / `length` はバイト単位で動くので、awk 実装に依らず同じ結果になる。ASCII 空白と全角空白が交互に並ぶ場合に備えて、長さが変わらなくなるまで繰り返す。

### 手元で再現しない失敗は、推定で式を替える前に観測を増やす

reviewer は Linux の gawk / mawk / `LC_ALL=C` でしか変異テストを回せず、macOS でだけ落ちる不具合を誰も検出できなかった。この種の不具合の番人は CI の macOS ジョブだけである。

- レビューの判定入力として CI の macOS ジョブ結果を必ず読む。`continue-on-error` のジョブでも、base ブランチで green なら PR 起因の回帰として merge 前に直す
- 推定で式を置き換える前に、既存の経験則（本ページ）と、CI の失敗件数が変わったかを照合する。件数が変わらないなら置き換えは原因に届いていない
- テストが helper を呼ぶときは stderr を捨てず、失敗時のメッセージに載せる。捨てると、CI でだけ落ちた失敗がどの理由で止まったかをログから追えない

### `awk -v` で渡した日本語見出しでも同じ誤一致が再発した — 比較を awk の外へ出す

上の事例から 2 日後、別のテストが同じ罠に落ちた。README の日英 2 版から `ステータス遷移:` 見出し直後の fence を切り出す helper が `awk -v h="$2" '$0 == h {f=1; next} …'` で見出し行を探していた。macOS の CI では ASCII 見出し `Status Transitions:` 側は正しく動く一方、日本語側は 70 行以上手前の `プラグインを削除するには:`（CJK 文字 + 末尾 `:` という同じ構造の行）に一致し、無関係な fence と段落が返って 4 つの assert が決定的に落ちた。Linux の gawk / mawk では再現せず、レビュー時に CI がまだ pending だったため誰も気付かないまま merge 直前まで進んだ。

本ページの経験則は Wiki に存在していたが、レビュー前の自動参照（キーワード照合）には現れなかった。Wiki は思い出させるだけで強制はしないため、同種の罠は awk に日本語文字列を渡す箇所を機械的に検出する側で塞ぐ必要がある。

**書き方（`index` + `length` より構造的な回避）**: 比較そのものを awk から外す。見出しは bash 側で `grep -nxF -- "$heading" "$file"` により行番号へ解決し（`-F` で正規表現を経由せず、`-x` で行全体一致、パターンとファイルが同じバイト列なのでロケールに依らない）、awk には整数だけを `-v n=` で渡して `NR == n` で位置決めする。`NR == n` は数値比較で `strcoll` もロケールも経由せず、gawk / mawk / macOS awk のすべてで同じ行に一致することを CI の macOS 実機で確認した。

```bash
heading_line() {
  HEADING_LINE=$(grep -nxF -- "$2" "$1" | cut -d: -f1)
  case "$HEADING_LINE" in
    ''|*$'\n'*) fail "heading '$2' is not found exactly once in ${1##*/}"; HEADING_LINE=0 ;;
  esac
}
fence_after() { awk -v n="$1" 'NR == n {f=1; next} f && /^```/ {c++; if (c==2) exit; next} f && c==1 {print}' "$2"; }
```

見出しがちょうど 1 回見つからなければその場で `fail` し、`HEADING_LINE=0` で下流の抽出を空にする。旧実装は未一致のとき空文字を返し、下流の assert が「fence が違う」「段落にトークンが無い」と別の原因を名乗っていた。

**修正の検証**: Linux ではこの欠陥を再現できないので、CI の macOS ログの失敗行（テスト名 + FAIL 行 + summary）を `failing_test` の実測アンカーにして blocking にし、修正後は同じ leg が PASS することで閉じる。移植性の修正はローカルの再実行では確認にならない。

## 関連ページ

- [移植性の指摘は「環境分岐を足す」より先に「その正規表現機能が本当に要るか」を疑う](../heuristics/portability-fix-questions-the-regex-feature-first.md)
- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](./locale-dependent-error-message-grep-assertion.md)

## ソース

- [再レビュー結果](../../raw/reviews/20260914T064706Z-pr-2803.md)
- [判定式を固定する静的 pin の抜け道を指摘したレビュー結果](../../raw/reviews/20260914T110010Z-pr-2816.md)
- [macOS CI だけの失敗を実測で blocking にしたレビュー結果](../../raw/reviews/20260915T022940Z-pr-2829.md)
- [ロケール固定で全角空白の検査が外れたと指摘したレビュー結果](../../raw/reviews/20260915T025127Z-pr-2829.md)
- [正規表現リテラルを文字列比較へ替えた fix 結果](../../raw/fixes/20260915T021146Z-pr-2829.md)
- [helper 全体をロケール C に固定した fix 結果](../../raw/fixes/20260915T023331Z-pr-2829.md)
- [全角空白をバイト列で削るようにした fix 結果](../../raw/fixes/20260915T025447Z-pr-2829.md)
- [`awk -v` に渡した日本語見出しが別行に一致した再発を CI ログで実測したレビュー結果](../../raw/reviews/20260916T111808Z-pr-2910.md)
- [見出しを grep で行番号に解決して awk へ整数で渡した fix 結果](../../raw/fixes/20260916T112742Z-pr-2910-fix.md)
- [行番号渡しが 3 実装で同じ行に一致することを確認したレビュー結果](../../raw/reviews/20260916T114658Z-pr-2910.md)
