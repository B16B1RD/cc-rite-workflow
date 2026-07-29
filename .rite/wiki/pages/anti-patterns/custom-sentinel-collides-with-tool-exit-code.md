---
type: "anti-patterns"
title: "自前 sentinel exit code は呼び出す外部コマンドの予約値を避けて選ぶ"
domain: "anti-patterns"
description: "スクリプト内部で意味を持たせる sentinel exit code に 2 を選ぶと、gawk / mawk / grep 等の外部コマンドが fatal error で返す 2 と衝突する。結果、ツールが異常終了したケースが「意図的に捨てた」扱いへ吸収され、そのために用意した失敗分岐が到達不能になる。自前 sentinel は 3 以降から選ぶ。"
created: "2026-07-30T01:20:00+09:00"
updated: "2026-07-30T01:20:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T142410Z-pr-2051.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T144345Z-pr-2051.md"
tags: []
confidence: high
---

# 自前 sentinel exit code は呼び出す外部コマンドの予約値を避けて選ぶ

## 概要

awk プログラムなどに「この状態を呼び出し側へ伝えたい」という独自の意味を持たせた exit code を割り当てるとき、値を 2 にすると gawk / mawk が fatal error で返す 2 と区別できなくなる。呼び出し側の `case` で sentinel を先に捕まえてしまい、ツール異常のために書いた分岐が実行されないまま残る。

## 詳細

### 実測された衝突

PR #2051 の `dollar-zero-check.sh` は、fence が閉じていないファイルを「解析できないので走査不能として数える」ために awk 側で `exit 2` を返していた。

```awk
END { if (in_fence) exit 2 }   # unbalanced fence sentinel
```

呼び出し側:

```bash
case "$awk_rc" in
  0) cat "$PART_FILE" >> "$FINDINGS_FILE" ;;
  2) SKIPPED=$((SKIPPED + 1)) ;;                    # ← 意図: unbalanced fence
  *) echo "WARNING: awk failed (rc=$awk_rc)" >&2    # ← 到達不能だった
     SKIPPED=$((SKIPPED + 1)) ;;
esac
```

gawk・mawk はいずれも**fatal error でも 2 を返す**（ファイルを開けない、正規表現がコンパイルできない等）。そのため「awk が異常終了した」ケースが `2)` の arm に吸収され、`*)` の WARNING は書かれてはいるが一度も実行されない。両者は「走査できなかった」点では同じ扱いになるものの、**原因の切り分けが構造的に不可能**になり、awk バイナリ側の問題を診断できない。

### 対処

sentinel は 3 以降を使う。

```awk
END { if (in_fence) exit 3 }
```

```bash
case "$awk_rc" in
  0) cat "$PART_FILE" >> "$FINDINGS_FILE" ;;
  3) SKIPPED=$((SKIPPED + 1)) ;;                      # unbalanced fence（意図的）
  *) echo "WARNING: awk failed on $file (rc=$awk_rc) — file not scanned" >&2
     SKIPPED=$((SKIPPED + 1)) ;;                      # ツール異常（rc=2 含む）
esac
```

### 主要ツールの予約 exit code

sentinel を選ぶ前に、呼び出すコマンドが何を返しうるかを確認する。

| コマンド | 予約している値 |
|---|---|
| gawk / mawk / nawk | 2 = fatal error |
| grep | 1 = no match、2 = error |
| diff | 1 = 差分あり、2 = error |
| sed (GNU) | 1 = usage error、4 = I/O error |
| jq | 1 = null/false 出力、2 = usage error、3 = compile error、5 = `-e` で null/false |
| find | 非 0 = 何らかのエラー（値は実装依存） |

シェル自身も 126（実行不能）/ 127（コマンド不在）/ 128+N（シグナル）を使う。**実質的に自由に使えるのは 3〜125 のうち、呼び出すツールが予約していない値**である。

### 検証方法

sentinel が本当に区別できているかは、**外部コマンドを意図的に fatal にして確かめる**。

```bash
# awk に開けないファイルを渡して rc を実測
chmod 000 /tmp/probe.md
awk '{ print }' /tmp/probe.md; echo "rc=$?"   # → rc=2 (gawk/mawk とも)
```

sentinel を 2 のままにしていると、この probe が sentinel の arm に落ちることが観測できる。

## 関連ページ

- [検出器が「走査できなかった」を「問題なし」に畳むと、ガードが黙って無検査になる](./checker-conflates-unscannable-with-clean.md)
- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](./bash-if-bang-rc-capture.md)
- [`cmd > file || true` は no-match (rc=1) と書き込み失敗 (rc>=2) を混同する](./cmd-redirect-or-true-conflates-nomatch-and-write-failure.md)

## ソース

- [PR #2051 review results](../../raw/reviews/20260729T142410Z-pr-2051.md)
- [PR #2051 fix results](../../raw/fixes/20260729T144345Z-pr-2051.md)
