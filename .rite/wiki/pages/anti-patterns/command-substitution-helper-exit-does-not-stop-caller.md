---
type: "anti-patterns"
title: "`$( )` でコマンド置換したヘルパーの `exit` は呼び出し元を止めない"
domain: "anti-patterns"
description: "シェル関数の中に書いた `exit 1` は、その関数が `$( )` の中で呼ばれた場合、**コマンド置換のサブシェルを終了させるだけ**で呼び出し元スクリプトは走り続ける。"
created: "2026-07-30T01:20:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260729T150808Z-pr-2051-c2.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T151517Z-pr-2051-c2.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-30T01:20:00+09:00" }
---

# `$( )` でコマンド置換したヘルパーの `exit` は呼び出し元を止めない

## 概要

シェル関数の中に書いた `exit 1` は、その関数が `$( )` の中で呼ばれた場合、**コマンド置換のサブシェルを終了させるだけ**で呼び出し元スクリプトは走り続ける。呼び出し元が受け取るのは空文字列であり、その空文字が後続の `cd` や path 組み立てへ流れる。ヘルパーを fail-closed に書いたつもりが、呼び出し規約によって無効化される。

## 詳細

### 実測された経路

`_test-helpers.sh` の `make_plain_sandbox` は hard-fail として `exit 1` を持っていた。

```bash
make_plain_sandbox() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/rite-test-XXXXXX") || {
    echo "ERROR: mktemp -d failed" >&2
    exit 1                    # ← fail-closed のつもり
  }
  printf '%s' "$d"
}
```

呼び出し側:

```bash
SANDBOX="$(make_plain_sandbox)"   # ← subshell の中で exit 1 が起きる
cd "$SANDBOX" || exit 1           # ← SANDBOX="" なので cd "" は rc=0 の no-op
printf '...' > "fixture.md"       # ← 呼び出し元の CWD（リポジトリルート）に書かれる
rm -f "fixture.md"                # ← 同じくリポジトリルートで削除
```

`cd ""` が rc=0 を返すのが決定的で、`|| exit 1` ガードは発火しない。そのまま fixture の書き込みと `rm -f` が**リポジトリルート**に対して実行され、しかもテストは全 assertion 通過で PASS を報告する。汚染に気づく手がかりが出力に一切残らない。

`$( )` 内の `exit` が呼び出し元へ伝わらないのは POSIX シェルの仕様であり、`set -e` を付けても変わらない（コマンド置換の rc は代入の rc になるが、代入自体は `VAR=$(...)` 単体では `set -e` のトリガにならないケースがある）。

### 対処: 値が生まれる位置で検査する

**ヘルパー側の意図に頼らず、代入の直後に呼び出し側で検査する**のが唯一確実。

```bash
SANDBOX="$(make_plain_sandbox)" || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
[ -n "$SANDBOX" ] || { echo "ERROR: make_plain_sandbox returned an empty path, aborting" >&2; exit 1; }
cd "${SANDBOX:?sandbox path is empty}" || { echo "ERROR: cannot cd to sandbox" >&2; exit 1; }
```

3 段になるのは冗長に見えるが、それぞれ別の失敗を捕まえている。

| ガード | 捕まえる失敗 |
|---|---|
| `\|\| { ... exit 1; }` | ヘルパーが非 0 で終了した（`exit` が rc として伝わるケース） |
| `[ -n "$SANDBOX" ]` | rc は 0 だが空文字が返った（`exit` が subshell で消費されたケース） |
| `${SANDBOX:?...}` | 上 2 つをすり抜けた場合の最終防衛（パラメータ展開で fail） |

### ヘルパー側を直す場合

呼び出し規約を全 caller で揃えられるなら、ヘルパー側を `return 1` に変えて「値と rc の両方で失敗を伝える」形にするほうが構造的に強い。ただし `$( )` は `return` でも rc を代入文へ伝えるだけなので、**呼び出し側の `||` ガードは依然として必要**である。ヘルパーを直しても caller の検査は省略できない。

なお起点事例のリポジトリでは同ヘルパーの caller が 17 箇所あり、全 caller で同じ空文字経路が成立していた。ヘルパー 1 箇所の修正だけでは閉じず、caller 側の規約を揃える必要があるため、別 Issue として切り出された。

### 検出方法

```bash
# $( ) の中で呼ばれているヘルパーが exit を持っていないか grep で棚卸しする
grep -rn 'exit [0-9]' path/to/helpers.sh
grep -rn '\$(\s*helper_name' path/to/callers/
```

`exit` を持つ関数が `$( )` から呼ばれていたら、その caller は全数チェックの対象になる。

## 関連ページ

- [`if ! cmd; then rc=$?` は常に 0 を捕捉する](./bash-if-bang-rc-capture.md)
- [PIPESTATUS はコマンド置換 `$(...)` のサブシェル境界を越えない](../heuristics/pipestatus-subshell-scoping-command-substitution.md)
- [function 内 `local v=$(...)` と top-level `v=$(...)` の `set -e` 伝播差で writer/reader 非対称が偶然 mask される](./bash-local-vs-toplevel-pipefail-asymmetry.md)
- [`cmd=$(...) || cmd=""` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする](./command-substitution-fallback-discards-diagnostic-json.md)

## ソース

- [レビュー結果](../../raw/reviews/20260729T150808Z-pr-2051-c2.md)
- [fix 結果](../../raw/fixes/20260729T151517Z-pr-2051-c2.md)
