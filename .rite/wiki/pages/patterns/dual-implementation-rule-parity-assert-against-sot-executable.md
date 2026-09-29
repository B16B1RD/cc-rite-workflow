---
type: "patterns"
title: "同じ判定規則を別言語で二重実装するときは、同一 fixture で SoT 実装の実行結果と突合する parity assert を置く"
domain: "patterns"
description: "bash の SoT helper と同じ除外規則を Python 側にも持たせる変更では、Python 側の期待値を手書きせず、同じ fixture tree に対して SoT helper を実際に実行し、その出力集合と Python 側が「残す」と判定した集合の一致を assert する。規則本文の複製は文書で「同時更新」と宣言するだけでは守れず、実行結果の突合だけが drift を検出する。"
created: "2026-09-17T10:34:18Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T01:07:27Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5-5"
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T01:07:27Z" }
    at: "2026-09-28T15:38:14Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260917T102546Z-pr-2933.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T150934Z-pr-3411.md"
  - type: "fixes"
    resource: "raw/fixes/20260928T151338Z-pr-3411.md"
  - type: "reviews"
    resource: "raw/reviews/20260928T153225Z-pr-3411.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T005731Z-pr-3419.md"
tags: []
confidence: high
---

# 同じ判定規則を別言語で二重実装するときは、同一 fixture で SoT 実装の実行結果と突合する parity assert を置く

## 概要

bash の SoT helper と同じ除外規則を Python 側にも持たせる変更では、Python 側の期待値を手書きせず、同じ fixture tree に対して SoT helper を実際に実行し、その出力集合と Python 側が「残す」と判定した集合の一致を assert する。規則本文の複製は文書で「同時更新」と宣言するだけでは守れず、実行結果の突合だけが drift を検出する。

## 詳細

**状況**: 未追跡ファイルの列挙から sandbox の書込防止マスク（キャラクタデバイス、および 0 バイトで書込ビットが全て落ちたスタブ）を除外する規則は、bash の helper が SoT として持っていた。別の Python helper が `git status` ではなく `git ls-files --others` で未追跡を列挙するため、同じ規則を Python 側にも実装する必要が生じた。

**なぜ手書きの期待値では足りないか**: 規則には言語ごとに落としやすい非対称がある。キャラクタデバイス判定は symlink を辿る（`test -c` と `os.stat`）が、スタブ判定は辿らない（`find -type f` と `os.lstat`）。stat 失敗は除外せず残す。この 3 点を Python 側のテストで「こう動くはず」と個別に書くと、書いた本人の理解が両実装に共通の誤りとして固定される。

**採った形**: 同じ fixture tree（`/dev/null` への symlink、0 バイト・0444 のスタブ、スタブへの symlink、書込可能な空ファイル、非空の読取専用ファイル、group 書込ビットだけ残る空ファイル）を作り、各ケースで Python 側の verify を走らせたあと、同じ tree に対して bash の SoT helper を実行し、その `??` 出力の集合が Python 側の「残す」集合と一致することを assert する。除外側（device / stub）は両方とも空集合、残す側（symlink / 書込可 / 非空）は両方とも同じ 1 要素になる。

**効いた点**: 4 名のレビュアー全員がこの parity 検証を評価し、mutation（書込ビット判定除去・サイズ判定除去・lstat→stat・device 分岐除去）はすべて suite が検出した。一方で parity では拾えない穴も残った — 新設した「stat 失敗は残す」分岐は到達 fixture（dangling symlink）が無く、除外側へ変異しても suite は green のままだった。parity assert は「両実装が同じ入力で同じ答えを出す」ことしか守らないので、到達しない分岐は別途 fixture で pin する。

**helper を fixture tree 内で実行するときの注意**: SoT helper が `mktemp` を使う場合、テストの `TMPDIR` が fixture tree 自体を指していると helper の一時ファイルが未追跡として現れ、parity が偽の差分で落ちる。helper 実行時だけ `TMPDIR` を除外済みディレクトリへ向ける。

**一般化**: 「同じ規則を A 言語と B 言語で持つ」変更は、文書に「規則を変えるときは両方を同時に更新する」と書くだけでは drift を検出できない。同一 fixture に対する SoT 実装の実行結果との突合を suite に置き、そのうえで各言語固有の分岐（例外経路・型判定）には到達 fixture を別途足す。


### 判定をテスト側に写すときは、ループの終了条件をすべて写す

テストの前提を確かめるために hook の判定（祖先を辿って目印を探す処理）をテスト側に写したとき、終了条件のうち `/` に着いたときの判定だけを写し、親へ進めなくなったとき（相対パスの最上位）の判定を落とした。相対パスの TMPDIR ではループが終わらず、テストは失敗を出さずに止まった。

- 写した判定は、元の実装と並べて終了条件・ガードを 1 つずつ突き合わせる。写し漏れた終了条件は、失敗ではなく無言の停止として現れるので気づきにくい。
- テスト側の判定の正しさは「hook がどこまで見るか」と一致していることで決まる。相対パスでは両者とも最上位の要素で止まり、見ない範囲が一致するので判定がずれない。hook より広く・狭く見る写しは、テストが hook の実際の挙動を予測できなくなる。
- 同じ判定を 2 か所に持つ以上、parity assert か、少なくとも両方を同じ入力で実行して結果を比べる確認を置く。

### 行の受理判定を正規表現と sed で並行して持つとき

行の受理判定を Python の正規表現と BRE の sed で並行して持つ場合も同じ形を取る。テスト側で helper の定義行を実ファイルから抜き出して実物の sed で評価し、Python 側の実物の正規表現と同じ入力行の集合で突き合わせる。BRE は否定先読みを持たないが、Python 側の `(?:(?!X).)*` は、X が自分自身と重ならない文字列なら、行の形を判定するアドレスと区切り記号の個数を判定するアドレスの組み合わせで同じ行集合を表せる。等価性が成り立つ文字の範囲（ASCII の空白など）は、テストのコメントに前提として書いておく。

## 関連ページ

- [sandbox 環境では raw な git status --porcelain が恒に非空になり clean 判定ガードが一度も発火しない](../anti-patterns/sandbox-bind-mount-makes-raw-git-status-always-dirty.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [レビュー結果](../../raw/reviews/20260917T102546Z-pr-2933.md)
- [レビュー結果（写した祖先探索の終了条件の漏れ）](../../raw/reviews/20260928T150934Z-pr-3411.md)
- [fix 結果（hook と同じ終了条件にそろえる）](../../raw/fixes/20260928T151338Z-pr-3411.md)
- [レビュー結果（見ない範囲が hook と一致することを確認）](../../raw/reviews/20260928T153225Z-pr-3411.md)
- [行の受理判定を Python と sed の実物同士で突き合わせたレビュー結果](../../raw/reviews/20260929T005731Z-pr-3419.md)
