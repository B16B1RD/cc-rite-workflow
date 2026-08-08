---
type: "anti-patterns"
title: "awk の exit は END 規則を実行する — 早期終了と END フォールバックの併用は二重出力になる"
domain: "anti-patterns"
description: "`f && /^#/ { print h; exit }` と `END { if (f) print h }` を併用すると、exit が END を走らせるため正常系で 2 行が出る。呼び出し側の数値 guard が改行込みの値を非数値として飲み込み、修正したはずの正常系で診断が丸ごと消える（gawk / mawk 両実装で再現）。併用するなら print する全規則が「出力済み」フラグを立てる規律が要るが、本体規則を記録だけにして print 点を END の 1 箇所へ集約すれば二重出力が構造的に起こりえなくなる。"
created: "2026-08-08T14:00:41+09:00"
updated: "2026-08-08T14:00:41+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260808T022209Z-pr-2142.md"
  - type: "fixes"
    ref: "raw/fixes/20260808T024257Z-pr-2142.md"
  - type: "fixes"
    ref: "raw/fixes/20260808T032734Z-pr-2142.md"
tags: ["awk", "bash", "double-output", "diagnostics", "simplification"]
confidence: high
---

# awk の exit は END 規則を実行する — 早期終了と END フォールバックの併用は二重出力になる

## 概要

POSIX awk の `exit` は**プログラムを即座に終えるのではなく END 規則へ飛ぶ**。そのため本体規則で `print` してから `exit` し、END でも同じ値をフォールバック出力する形にすると、正常系で 2 行が出る。

```awk
f && /^#/ { print h; exit }     # 早期終了しつつ print
END       { if (f) print h }    # フォールバックでも print
```

実測では正常系の出力が `3\n1` になった。呼び出し側が `case "$v" in ''|*[!0-9]*) : ;;` のような数値 guard を持っていると、**改行込みの値が非数値として飲み込まれ、修正したはずの正常系で診断が丸ごと消える**。gawk / mawk の両実装で再現する。

## 詳細

### 発覚経路

この形は cycle 4 で reviewer が提案したパッチとして持ち込まれた。指摘本体には実測アンカーがあったが、**suggestion 欄のパッチは誰も実測していなかった**。7 ケースの実測比較で初めて、提案どおり適用すると正常系が壊れることが分かった。

### 2 つの解き方と、どちらが安いか

| 解き方 | コスト |
|---|---|
| 規律で守る: print する**全**規則が「出力済み」フラグを立てる | (a) 説明コメントを要求し、(b) 腕ごとの pin を要求し、(c) 腕が増えるたび両方が増える |
| 構造で不可能にする: 本体規則は行番号を変数へ記録するだけにし、print を END の 1 箇所へ集約する | 二重出力が構造的に起こりえない。規律・コメント・腕ごとの pin という 3 つの問いが同時に消える |

PR #2142 では cycle 6 で後者へ転換した。前 cycle の指摘「3 腕中 1 腕が未 pin」は、pin を足すのではなく**規律そのものを不要にして**解いた。次 cycle の reviewer は「新規律は 3 本体規則すべてが構造的に pin 済み」と評価し、さらに**失敗モードの重さも縮んだ** — 同じ `exit` 削除変異が、旧形では「二重 print → WARNING 消滅」だったのが新形では「報告行の選択が変わるだけ」になった。

### 副作用: 単純化でガードが到達不能になる

print 点の一本化により awk の stdout が「空か 1 行の数値」だけになり、非数値を弾く `case` の腕が**構造的に到達不能**になった。単純化のたびに「この防御は今も到達可能か」を問い直す。到達不能なガードは、将来の regression を loud に落とさず沈黙させる退路として残り続ける。

## 関連ページ

- [awk bash block termination tracking](../patterns/awk-bash-block-termination-tracking.md)
- [awk のデフォルト FS は `\r` を含まない — CRLF 入力で「空行」判定が壊れる](./awk-default-fs-excludes-cr-breaks-empty-line-test.md)
- [Legacy field の「deprecate + 残置」よりも「完全削除」が構造的閉塞を実現する](../heuristics/complete-deletion-over-deprecation-for-structural-closure.md)

## ソース

- [PR #2142 review results (cycle 4)](../../raw/reviews/20260808T022209Z-pr-2142.md)
- [PR #2142 fix results (cycle 4)](../../raw/fixes/20260808T024257Z-pr-2142.md)
- [PR #2142 fix results (cycle 6)](../../raw/fixes/20260808T032734Z-pr-2142.md)
