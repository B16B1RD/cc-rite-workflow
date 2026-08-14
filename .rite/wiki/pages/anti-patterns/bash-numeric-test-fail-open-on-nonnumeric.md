---
type: "anti-patterns"
title: "bash の算術比較は非数値入力で rc=2 を返し、fail-closed の意図が else 側へ倒れる"
domain: "anti-patterns"
description: "`[ \"$x\" -eq 0 ]` は `$x` が非数値のとき「偽」ではなく **rc=2（エラー）** を返す。"
created: "2026-08-03T07:46:56Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260803T035738Z-pr-2094.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-03T07:46:56Z" }
---

# bash の算術比較は非数値入力で rc=2 を返し、fail-closed の意図が else 側へ倒れる

## 概要

`[ "$x" -eq 0 ]` は `$x` が非数値のとき「偽」ではなく **rc=2（エラー）** を返す。`if` は非ゼロをすべて偽として扱うため、制御は `else` 分岐へ落ちる。「読み戻し不能なら既定値へ」という **fail-closed の意図で書かれたガードが、入力が壊れているときにだけ逆向き（処理続行）に作用する** — つまり最も守りたい状況でだけ守らない。

## 詳細

### 再現

```bash
$ x="abc"
$ if [ "$x" -eq 0 ]; then echo "then"; else echo "else"; fi
bash: [: abc: integer expression expected
else
```

stderr にメッセージは出るが、`2>/dev/null` で捨てている経路や、そもそも stderr を見ない経路では**完全に沈黙する**。

### 何が問題か

このイディオムを「値が 0 かどうか」の判定に使う分には実害が出にくい。危険なのは **fail-closed のガードとして使ったとき**で、期待と実挙動が反転する。

| 入力 | 期待（fail-closed） | 実挙動 |
|---|---|---|
| `0` | then（既定値へ倒す） | then |
| `5` | else（処理続行） | else |
| `abc`（壊れた値） | **then（既定値へ倒す）** | **else（処理続行）** |

壊れた入力こそ「読み戻し不能」なのに、そこだけ処理が続行される。

### 対処

数値であることを先に確認する述語を前置する。

```bash
# ✗ 非数値で else へ倒れる
if [ "$x" -eq 0 ]; then use_default; else carry_forward "$x"; fi

# ✓ 非数値は明示的に fail-closed 側へ
if ! [[ "$x" =~ ^[0-9]+$ ]] || [ "$x" -eq 0 ]; then use_default; else carry_forward "$x"; fi
```

`[[ ... =~ ]]` は bash 拡張なので、POSIX sh 互換が要る場合は `case "$x" in ''|*[!0-9]*) use_default ;; esac` を使う。

### 関連する観測

この指摘が出た cycle の 3 件はいずれも「**防御機構を追加した diff の中に、その防御が効かない縮退経路が残る**」型だった。数値比較の fail-open のほかに、テストスイート自身の自己切断（`set -euo pipefail` 下でコマンド置換内の grep 非マッチが errexit でスイートをプロセスごと中断）と、兄弟 WARNING の片肺 hedge が同時に出ている。防御を足したら、その防御が効かない入力を 1 つ挙げてみる価値がある。

## 関連ページ

- [fail-closed ガードは「異常を検出したら止める」ではなく「正常を確認できなければ止める」で書く](../patterns/fail-closed-confirms-normal-not-detects-abnormal.md)
- [rc 変数を 0 で初期化すると、未起動の段を「起動して成功した」と断定する](../patterns/rc-variable-not-started-sentinel.md)
- [`set -o pipefail` 下の `... ¦ grep -q` は早期終了の SIGPIPE で偽の失敗になる](./pipefail-grep-q-sigpipe-false-failure.md)

## ソース

- [PR #2094 review results](../../raw/reviews/20260803T035738Z-pr-2094.md)
