---
title: "pathspec 不一致の git diff --quiet は exit 0 を返し「差分なし」ガードを無効化する"
domain: "anti-patterns"
description: "「差分なし → 安全」型ガードは pathspec 解決失敗 (cwd 相対 / 空 / quotePath C-quote) で「比較していないのに同一」に化け、破棄承認でデータ喪失する。過去のレビューで 3 回別形で実測。pathspec の実在解決を独立に保証する。"
created: "2026-07-13T09:15:00Z"
updated: "2026-07-13T09:15:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260713T000901Z-pr-1840.md"
tags: []
confidence: high
---

# pathspec 不一致の git diff --quiet は exit 0 を返し「差分なし」ガードを無効化する

## 概要

`git diff --quiet <rev> -- <pathspec>` は pathspec がどのファイルにも一致しないとき「比較対象なし = 差分なし = exit 0」を返す。「差分がないことを確認してから破棄する」型の安全ガードにこれを使うと、pathspec の解決失敗がそのまま「安全確認済み」に化け、破壊的操作が未検証の変更に対して承認される。「不一致なら安全側に落ちるだろう」という直感は真逆。

## 詳細

起点事例 (cleanup の discardable 判定) で同じ機序のデータ喪失経路を 3 回別形で作った:

1. **cwd 相対解決** — producer (`git diff --name-only HEAD`) は root 相対パスを出力するが、consumer の pathspec は cwd 相対に解決される。サブディレクトリ cwd では全 pathspec が不一致 → exit 0 → 相違変更が「diff 同一」扱い。修正: consumer を `git -C <root>` で固定。
2. **空 pathspec** — `xargs -r` は空入力で何も実行せず rc 0。「比較していない」が「差分なし」に化ける。修正: 非空 guard を独立に置く。
3. **quotePath C-quote** — 非 `-z` の `--name-only` は非 ASCII / 改行入りファイル名を `"\346..."` に C-quote する。quote 済みリテラルは pathspec として実ファイルに不一致 → exit 0。修正: `-z` 出力を xargs -0 に **pipe 直結** する (NUL は command substitution が落とすため変数を経由できない — この制約を改行 + tr で回避しようとしたことが quote 素通しを生んだ)。

## 検出のポイント

- 「差分なし (rc 0) → 安全」型の判定を見たら、「pathspec が実在ファイルに解決されたこと」が独立に保証されているかを確認する
- pathspec の producer と consumer の基準 (root 相対 / cwd 相対 / quote 形式) が一致しているかを、サブディレクトリ cwd・非 ASCII 名・空リストの 3 ケースで実測する
- 分類器が破壊的操作 (破棄・上書き) を authorize する場合、誤分類の方向が「安全側 (保護) に倒れるか」を縮退挙動込みで検証する

## 関連

- [[path-basis-change-observation-surface-sweep]] — 基準不一致の一般形
- [[classifier-destructive-action-same-tree-alignment]] — 同 PR の姉妹 heuristic
