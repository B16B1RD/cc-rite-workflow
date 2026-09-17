---
type: "patterns"
title: "同じ判定規則を別言語で二重実装するときは、同一 fixture で SoT 実装の実行結果と突合する parity assert を置く"
domain: "patterns"
description: "bash の SoT helper と同じ除外規則を Python 側にも持たせる変更では、Python 側の期待値を手書きせず、同じ fixture tree に対して SoT helper を実際に実行し、その出力集合と Python 側が「残す」と判定した集合の一致を assert する。規則本文の複製は文書で「同時更新」と宣言するだけでは守れず、実行結果の突合だけが drift を検出する。"
created: "2026-09-17T10:34:18Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-17T10:34:18Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260917T102546Z-pr-2933.md"
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

## 関連ページ

- [sandbox 環境では raw な git status --porcelain が恒に非空になり clean 判定ガードが一度も発火しない](../anti-patterns/sandbox-bind-mount-makes-raw-git-status-always-dirty.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [レビュー結果](../../raw/reviews/20260917T102546Z-pr-2933.md)
