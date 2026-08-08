---
type: "anti-patterns"
title: "mktemp が作った名前から派生させたパスは O_CREAT|O_EXCL 保証を失う"
domain: "anti-patterns"
promote: rite-plugin
description: "`$(mktemp).part` のような派生パスは mktemp が atomic に作ったファイルではなく、名前が予測可能なうえ存在チェックも経ていない。攻撃者がその名前で symlink を置くと書き込みが追随して任意ファイルを truncate する。一時ファイルが 2 本必要なら mktemp を 2 回呼ぶ。"
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

# mktemp が作った名前から派生させたパスは O_CREAT|O_EXCL 保証を失う

## 概要

`mktemp` の安全性は「ランダムな名前を `O_CREAT|O_EXCL` で atomic に作る」ことに由来する。その戻り値に suffix を足した派生パス（`"$tmp.part"`、`"$tmp.bak"` 等）は mktemp が作ったファイルではなく、**元の名前が判明した時点で予測可能**になる。そこへリダイレクトすると、先回りして置かれた symlink に追随してリンク先を truncate しうる。

## 詳細

### 実測された経路

起点事例の `dollar-zero-check.sh` は、ファイルごとの中間結果を書くパスを次のように derive していた。

```bash
FINDINGS_FILE="$(mktemp)"
PART_FILE="$FINDINGS_FILE.part"     # ← 派生パス

# ...
awk '...' "$file" > "$PART_FILE"    # ← ここで symlink に追随しうる
```

`FINDINGS_FILE` の名前は `/proc` やディレクトリ列挙から観測でき、`.part` を足した名前を予測して symlink を置くことができる。security reviewer が隔離環境で、この経路から任意ファイルが truncate されることを実測した。

同ファイル内の兄弟スクリプト 2 本（`bang-backtick-check.sh` / `tmp-hardcode-check.sh`）は派生パスを作らない書き方をしており、**同じリポジトリ内で規約が非対称**になっていた点も指摘された。

### 対処: 2 本必要なら 2 回 mktemp する

```bash
FINDINGS_FILE="$(mktemp)"
PART_FILE="$(mktemp)"               # ← 独立に atomic 生成

_cleanup() { rm -f "${FINDINGS_FILE:-}" "${PART_FILE:-}"; }
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP
```

mktemp の呼び出しコストは無視できる程度で、派生パスを使う理由は「片方を消せばもう片方も特定できて掃除が楽」程度しかない。trap で両方を明示的に消せば同じことが達成できる。

### 適用範囲

以下はすべて同じ問題を持つ。

```bash
tmp=$(mktemp)
cp src "$tmp.orig"          # NG
sort "$tmp" > "$tmp.sorted" # NG
: > "${tmp%.tmp}.log"       # NG（prefix を削る派生も同様）
mkdir "$tmp.d"              # NG（ディレクトリでも同じ。mktemp -d を使う）
```

ディレクトリが必要な場合は `mktemp -d` を独立に呼ぶ。

### 例外: 派生が安全になる条件

親ディレクトリ自体を `mktemp -d` で作り（mode 0700）、その配下に固定名を置くのは安全である。ディレクトリの所有者と権限が保証されているため、他ユーザーがその中に symlink を置けない。

```bash
workdir=$(mktemp -d)        # mode 0700
: > "$workdir/findings"     # OK — 親が保護されている
: > "$workdir/part"         # OK
```

複数の一時ファイルを扱うなら、この形のほうが trap も 1 行（`rm -rf "$workdir"`）で済む。

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](../patterns/trap-register-before-mktemp.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](../patterns/mktemp-failure-surface-warning.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #2051 review results](../../raw/reviews/20260729T142410Z-pr-2051.md)
- [PR #2051 fix results](../../raw/fixes/20260729T144345Z-pr-2051.md)
