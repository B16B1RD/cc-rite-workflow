---
title: "末尾の && 短絡文が非ブロッキング script の exit code を leak する (末尾 exit 0 を明示する)"
domain: "anti-patterns"
description: "`set -e` を使わない (`set -uo pipefail` のみの) helper script で、`[ -n \"$var\" ] && cmd` のような `A && B` 短絡が **script の最終実行文**になると、`$var` が空のとき `[ -n \"\" ]` が rc=1 を返し、`&&` 短絡で compound 文全体が rc=1 を返す。"
created: "2026-06-02T07:42:13Z"
updated: "2026-06-02T07:42:13Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260602T064758Z-pr-1246.md"
  - type: "fixes"
    ref: "raw/fixes/20260602T065355Z-pr-1246.md"
tags: ["bash", "exit-code", "non-blocking-contract", "short-circuit", "trailing-statement", "silent-regression"]
confidence: high
---

# 末尾の && 短絡文が非ブロッキング script の exit code を leak する (末尾 exit 0 を明示する)

## 概要

`set -e` を使わない (`set -uo pipefail` のみの) helper script で、`[ -n "$var" ] && cmd` のような `A && B` 短絡が **script の最終実行文**になると、`$var` が空のとき `[ -n "" ]` が rc=1 を返し、`&&` 短絡で compound 文全体が rc=1 を返す。末尾に `exit 0` がないと、その rc がそのまま script の exit code に leak し、「Exit codes: 0 always」のような **非ブロッキング契約を文書化している helper でも exit 1 を返す** silent regression を生む。canonical fix は **末尾に `exit 0` を明示**すること (sibling helper 全てが従う規約)。

## 詳細

### 失敗の構造

`set -e` なしの helper は、最終コマンドの rc がそのまま script の exit code になる。error-surfacing や cleanup の目的で `[ -n "$x" ] && rm -f "$x"` のような短絡文を末尾に追加すると、それまで末尾が `echo` (常に rc=0) で偶然守られていた暗黙の exit 0 契約が崩れる。

起点事例で実測した経路:

```bash
# settings-local-rite-hook-cleanup.sh (set -uo pipefail のみ、-e なし)
# CLEANED 経路の末尾に追加された cleanup 行
mv_err=$(mktemp) || mv_err=""   # disk pressure 等で mktemp 失敗 → mv_err=""
# ... mv 成功 (CLEANED) ...
[ -n "$mv_err" ] && rm -f "$mv_err"   # ← script 最終文
# mv_err="" のとき [ -n "" ]=false → rc=1 → script 全体が exit 1 を leak
```

`mv_err` が空 (mktemp 失敗時) のとき、`[ -n "" ]` が false (rc=1) を返し、`&&` 短絡で `rm` は実行されず compound 文の rc=1 が末尾文の rc としてそのまま script exit code に伝播する。ファイルは正しく書き換え済み (CLEANED) でも script は exit 1 を返し、「Exit codes: 0 always」という自身の文書と非ブロッキング契約に違反する。

### 既存の bash exit-code gotcha 族との区別

本 anti-pattern は exit-code を巡る既存 2 族とは **別機構**:

| 機構 | 壊れ方 | 関連ページ |
|------|--------|-----------|
| `if ! cmd; then rc=$?` | `!` の binary 反転で `$?` が常に 0 (到達するが誤値) | [[bash-if-bang-rc-capture]] |
| `set -e` 下の bare statement | 非ゼロで script abort、後続 rc 分岐が dead code 化 (到達不能) | [[bare-statement-under-set-e-dead-code-rc-branch]] |
| **末尾 `A && B` 短絡 (本ページ)** | `set -e` **なし**で `A` が false のとき compound rc=1 が末尾文として exit code に leak | — |

3 族とも root cause が異なるため検出・対策も独立。本族は `set -e` を使わない helper 特有で、`set -e` 下では `&&` 短絡内の rc=1 は条件式扱いで abort しないが、script 末尾文では exit code に直結する。

### canonical fix: 末尾 exit 0 を明示する

```bash
# ... 全処理 ...
[ -n "$mv_err" ] && rm -f "$mv_err"
exit 0   # ← 最終文の rc に依存せず非ブロッキング契約を保証
```

- **最小・最低リスク**: 既存ロジックを一切変えず 1 行追加するだけ。`if [ -n "$mv_err" ]; then rm -f "$mv_err"; fi` 形式でも rc は守れるが、末尾 `exit 0` の方が将来の行追加に対して頑健 (新たな末尾文を追加しても契約が崩れない)。
- **sibling 規約への統一**: 同 hooks/ の sibling helper は全て末尾 `exit 0` を持つ。本 helper のみ `fi` 終端の outlier だった。「Exit codes: 0 always」「非ブロッキング」を文書化する helper は末尾 `exit 0` を明示すべき。
- **非ブロッキング契約 (exit 0 always) は最終文の rc に依存させない**: `set -uo pipefail` のみで `-e` なしの helper は、末尾 `exit 0` がないと最終コマンドの rc がそのまま script exit code になる。契約を rc 偶然依存から構造的保証へ移す。

### 回帰防止 test の pin 方法

CLEANED 経路 + 内側 mktemp 失敗の exit 0 を pin する test (S-7) を追加する際は、PATH-shim した mktemp で **引数で分岐**させて再現する: `[ $# -eq 0 ]` (no-arg call) のときのみ exit 1、テンプレート付き呼び出し (atomic temp) は real mktemp へ delegate する。これは S-5/S-6 の mv-shim 技法の拡張。実装末尾の `exit 0` を削除する mutation で S-7 が `expected=0 actual=1` で FAIL することを確認し、false-positive test でないことを実証する (詳細は [[mutation-testing-test-fidelity]])。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](./bash-if-bang-rc-capture.md)
- [set -euo pipefail 下の外部コマンド単独文は後続 rc 分岐を dead code 化する](./bare-statement-under-set-e-dead-code-rc-branch.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #1246 review results (cycle 1) — A && B 短絡が script 末尾文で exit code を leak する HIGH finding](../../raw/reviews/20260602T064758Z-pr-1246.md)
- [PR #1246 fix results — 末尾 exit 0 明示で非ブロッキング契約を構造的保証 + S-7 mutation test](../../raw/fixes/20260602T065355Z-pr-1246.md)
