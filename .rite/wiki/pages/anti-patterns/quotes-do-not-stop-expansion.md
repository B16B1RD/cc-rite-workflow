---
type: "anti-patterns"
title: "二重引用符と -- は argv 分割にしか効かず、展開はパース時に終わっている"
domain: "anti-patterns"
description: "テンプレートへ値を埋める設計では、二重引用符は単語分割とグロブを止めるだけで、コマンド置換とバッククォートはその内側でも展開される。`--` も argv 分割にしか効かない。git check-ref-format はシェルメタ文字を弾かないため、上流バリデータを防波堤と見なせない。"
created: "2026-09-02T00:50:00Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T00:50:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T180132Z-pr-2500.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T140807Z-pr-2500.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T180942Z-pr-2500.md"
tags: []
confidence: high
---

# 二重引用符と -- は argv 分割にしか効かず、展開はパース時に終わっている

## 概要

テンプレートへ値を埋める設計では、二重引用符は単語分割とグロブを止めるだけで、コマンド置換とバッククォートはその内側でも展開される。`--` も argv 分割にしか効かない。git check-ref-format はシェルメタ文字を弾かないため、上流バリデータを防波堤と見なせない。

## 詳細

`--branch "{branch_name}"` の形で、第三者が制御する `headRefName` を literal substitute する経路が観測された。二重引用符は「単語分割とグロブを止める」だけで、`$(...)` / バッククォートはその内側でも展開される。helper 側のデリミタ検査・値の妥当性検査は**展開後の値**にしか走らないため、防御線として機能しない。

同じ問いを反対方向に間違える形も同時に出た。`{reason_file}` を `${TMPDIR:-/tmp}/...` と定義して Write の書き出し先に渡すと、Write は bash を通さないので展開されない。skill に新しくパスや値を書くたび、「Bash が展開するのか、Write が literal に消費するのか」を 1 問通す。

上流バリデータを防波堤と見なす前に実測する。`git check-ref-format 'refs/heads/feat/issue-2493-$(id)'` は **rc=0**。バッククォート形も `$IFS` も rc=0 で、rc=1 になるのは空白を含む場合など ref 名として不正なときだけ。「git 側が名前を検証しているから安全な文字しか来ない」は誤り。防御は charset 束縛（`^[A-Za-z0-9._/-]+$`）を自分で書くか、シェル変数へ受けてから渡すか。防御線は**値がテンプレートへ入る前**（昇格の側）にしか置けない。

連言で成り立つ CRITICAL（部分一致条件を満たす head 名を第三者が作れる ∧ その値がテンプレート内で展開される）は、両方を独立に実測してから受理する。片方が偽なら全体が偽になる。

## 関連ページ

- [LLM substitute placeholder は bash residue gate で fail-fast 化する](../patterns/placeholder-residue-gate-bash-fail-fast.md)
- [シェル層で閉じられない注入防御は値を substitute する側（LLM）の実行前ゲートとして書く](../heuristics/shell-unclosable-defense-goes-to-substituting-side.md)

## ソース

- [レビュー結果](../../raw/reviews/20260901T180132Z-pr-2500.md)
- [レビュー結果](../../raw/reviews/20260901T140807Z-pr-2500.md)
- [fix 結果](../../raw/fixes/20260901T180942Z-pr-2500.md)
