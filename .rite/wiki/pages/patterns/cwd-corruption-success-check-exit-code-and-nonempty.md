---
type: "patterns"
title: "cwd破損下の成否検証は非空性とexit codeの両方をチェックする（文字列等値比較だけでは偽陽性を防げない）"
domain: "patterns"
promote: rite-plugin
description: "`[ \"$(cmd_a)\" = \"$(cmd_b)\" ]` のような command substitution の等値比較は、両コマンドが cwd 破損等で失敗し共に空文字列を返した場合でも `true` と評価される。"
created: "2026-07-17T09:50:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260717T094246Z-pr-1888.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-17T09:50:00+00:00" }
---

# cwd破損下の成否検証は非空性とexit codeの両方をチェックする（文字列等値比較だけでは偽陽性を防げない）

## 概要

`[ "$(cmd_a)" = "$(cmd_b)" ]` のような command substitution の等値比較は、両コマンドが cwd 破損等で失敗し共に空文字列を返した場合でも `true` と評価される。この落とし穴により、`/rite:cleanup` の base ブランチ更新ステップで `git rev-parse HEAD` / `git rev-parse origin/{base}` が cwd 破損下で共に空文字列を返し、偽の `BASE_UPDATE=ok` を報告する CRITICAL 欠陥が実発生した。

## 詳細

**根本原因**: worktree 自己削除後、Bash 永続シェルの cwd が削除済みディレクトリを指したまま git コマンドが実行されると、`git rev-parse` は stdout に何も出力せず（空文字列）、多くの場合非ゼロ終了する。しかし成否検証が `[ "$(git rev-parse HEAD 2>/dev/null)" = "$(git rev-parse origin/{base} 2>/dev/null)" ]` という単純な文字列等値比較だった場合、両辺が空文字列で一致してしまい `ok` と誤判定される。

**修正パターン（導入時に実機検証済み）**:

1. 各コマンドの exit code を明示的に capture する（`local var=$(cmd)` は `$?` を汚染するため避け、素の代入 + 直後の `$?` 参照を使う）
2. 非空性チェック (`-n`) を追加する
3. exit code と非空性の両方が成立した場合のみ値の等値比較を行う

```bash
_head_rev=$(git rev-parse HEAD 2>/dev/null); _head_rc=$?
_base_rev=$(git rev-parse "origin/{base_branch}" 2>/dev/null); _base_rc=$?
if [ "$_head_rc" -eq 0 ] && [ "$_base_rc" -eq 0 ] && [ -n "$_head_rev" ] && [ "$_head_rev" = "$_base_rev" ]; then
  echo "[CONTEXT] BASE_UPDATE=ok"
else
  # 失敗系 marker へ routing（偽の ok を出さない）
fi
```

**根本原因側の対策との併用**: 本パターンは「cwd が壊れていても誤った成功を報告しない」ための**検証層**の防御。起点事例ではさらに**根本原因層**として、worktree 削除前に main checkout の絶対パスを確保しておき、後続ステップの冒頭で明示的に `cd` することで cwd 破損自体を回避する対策も併用した。検証層のみでは「正しく失敗を検出できる」だけで cwd 破損自体は解消しない点に注意（両層を組み合わせるのが最も堅牢）。

**適用範囲**: この落とし穴は `git rev-parse` に限らず、失敗時に空文字列を返しうる任意のコマンド（`cat`、`jq -r` の存在しないキー、環境変数未設定時の展開等）を command substitution で比較する箇所すべてに一般化できる。

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](../patterns/exit-code-semantic-preservation.md)

## ソース

- [レビュー結果](../../raw/reviews/20260717T094246Z-pr-1888.md)
