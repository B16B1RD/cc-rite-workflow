---
type: "heuristics"
title: "PIPESTATUS はコマンド置換 `$(...)` のサブシェル境界を越えない"
domain: "heuristics"
description: "bash の `$(...)` コマンド置換は内部でサブシェルを生成して実行される。"
created: "2026-07-21T12:40:00+09:00"
updated: "2026-07-21T12:40:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260721T005522Z-pr-1937.md"
tags: ["bash", "pipestatus", "subshell", "command-substitution", "exit-code"]
confidence: high
---

# PIPESTATUS はコマンド置換 `$(...)` のサブシェル境界を越えない

## 概要

bash の `$(...)` コマンド置換は内部でサブシェルを生成して実行される。そのサブシェル内でパイプライン (`cmd1 | cmd2`) を実行しても、`PIPESTATUS` 配列はサブシェルにスコープされたまま親シェルには伝播しない。`var=$(cmd1 | cmd2 | head -1); [ "${PIPESTATUS[0]}" -eq 0 ]` は cmd1/cmd2 の失敗を検出できず、常に直前に実行した `[` コマンド自身の exit code（正常なら 0）を見てしまう。

## 詳細

### 壊れるパターン

```bash
# ❌ NG: PIPESTATUS はサブシェル境界を越えないため機能しない
git_has_uncommitted=$(bash lib/git-status-filtered.sh | head -1)
if [ "${PIPESTATUS[0]}" -eq 0 ]; then
  : # helper 成功のつもり
else
  git_has_uncommitted="?? (dirty-check failed — assume uncommitted for safety)"
fi
```

この `PIPESTATUS[0]` は `bash lib/git-status-filtered.sh | head -1` パイプラインの中の `bash ...` の exit code ではなく、`$(...)` 全体を 1 つのコマンドとして実行したあとに続く `if` 文自身の直前コマンド（この場合は代入文そのもの、実質的に常に成功扱い）の exit code を見てしまう。**`$(...)` はそれ自体が 1 つのサブシェル実行であり、内部のパイプラインの `PIPESTATUS` は外側に持ち出せない**。

この不具合は "動いているように見えて実は検出していない" 典型例で、helper が意図的に失敗するテストケースを書いて初めて顕在化した。同一の fail-safe パターンを 2 箇所に適用したとき、パイプを含まない箇所（`dirty=$(bash helper.sh) || dirty="..."` 形式）は正しくフォールバックしたが、`| head -1` を含む箇所は helper が失敗してもフォールバックが発火しなかった。

### 修正パターン

パイプを含む場合は、コマンド置換自身の exit code を直接 `||` でチェックしてから、パイプ（`| head -1`）の代わりにパラメータ展開で先頭行を取り出す:

```bash
# ✅ OK: コマンド置換の exit code を直接チェックし、head -1 の代わりにパラメータ展開で切り出す
git_has_uncommitted=$(bash lib/git-status-filtered.sh) || git_has_uncommitted="?? (dirty-check failed — assume uncommitted for safety)"
git_has_uncommitted="${git_has_uncommitted%%$'\n'*}"  # 先頭行のみ使う場合
```

`var=$(cmd)` の直後の `||` は `cmd` 自身（コマンド置換全体）の exit code を正しく参照できる（サブシェル境界を越える必要がない — コマンド置換自体の exit code はサブシェルの終了時に親シェルへ返される）。複数行出力から先頭行だけ使いたい場合は `head -1` へパイプせず、`"${var%%$'\n'*}"` のようなパラメータ展開で切り出せば、exit code チェックとパイプを同時に使わずに済む。

### 一般化した教訓

**コマンド置換 `$(...)` の内側で終了コードを見たいパイプラインを組んではならない**。パイプの exit code (`PIPESTATUS`) が必要な処理と、コマンド置換で出力を capture したい処理は分離する:

- 出力の capture だけが目的なら `var=$(cmd1 | cmd2)` で構わない（内部パイプの中間失敗を検出する必要がない場合）
- 最終コマンドの exit code を検査する必要があるなら、コマンド置換全体を単一コマンドの実行に留め（パイプを含めない）、`|| fallback` で直接チェックする
- 複数行から特定行だけを取り出す後処理は、パイプ（`head` / `tail`）ではなくパラメータ展開・`read` などシェル組み込みの機能で行う

## 関連ページ

- [`mapfile -t < <(...)` で pipefail safe な iteration を書く](../patterns/mapfile-process-substitution-pipefail-safe.md)

## ソース

- [PR #1937 fix cycle 1 (PIPESTATUS がサブシェル境界を越えないバグを実測発見・修正)](../../raw/fixes/20260721T005522Z-pr-1937.md)
