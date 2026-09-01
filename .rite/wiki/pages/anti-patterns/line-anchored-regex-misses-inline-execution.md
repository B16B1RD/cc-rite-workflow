---
type: "anti-patterns"
title: "静的検査 regex の行頭アンカーは `if` / `||` / 代入位置にある実行行を見落とす"
domain: "anti-patterns"
description: "`^[[:space:]]*git branch -d` のように行頭からアンカーした検査パターンは、`if cmd; then` / `|| cmd` / `elif x=$(cmd)` の位置にある実行行に一致しない。ゲートは通るが、検査したつもりの対象を最初から見ていない。"
created: "2026-09-01T20:28:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-01T20:28:00+09:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T053153Z-pr-2498.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T055639Z-pr-2498.md"
tags: []
confidence: high
---

# 静的検査 regex の行頭アンカーは `if` / `||` / 代入位置にある実行行を見落とす

## 概要

`^[[:space:]]*git branch -d` のように行頭からアンカーした検査パターンは、`if cmd; then` / `|| cmd` / `elif x=$(cmd)` の位置にある実行行に一致しない。ゲートは通るが、検査したつもりの対象を最初から見ていない。

## 詳細

抽出の完了ゲートや禁止イディオムの検出器を書くとき、対象コマンドが行頭に来る形だけを想定した regex を置きがちである。しかし実運用の bash で、そのコマンドが行頭に単独で現れることは少ない:

```bash
if LC_ALL=C git worktree remove "$WT"; then      # ← ^ アンカーに不一致
  :
fi
LC_ALL=C git branch -D -- "$BR" || echo "failed"  # ← 先頭は LC_ALL=C
elif del_err=$(LC_ALL=C git branch -d -- "$BR"); then  # ← 代入の右辺
```

**対処**: コマンド境界で照合する。

```bash
grep -nE '(^|[;&|[:space:]])git worktree remove' "$file"
```

**照合対象は絞る**: SKILL.md のような手順書では、散文に手動復旧コマンドが引用として現れる（「すぐに消したい場合: `git worktree remove --force ...`」）。検査対象を fenced bash ブロック内に限定しないと、直す必要のない引用が findings を埋める。

**検証手順**: 新しい検査 regex を書いたら、**抽出前（あるいは修正前）のコードに当てて一致件数を確認する**。本来なら N 件一致するはずの対象に 1 件しか当たらないなら、ゲートは対象を見ていない。PR #2498 では行頭アンカー版が実際に 1 件しか拾えず、この確認で発覚した。

**assert のチャネルも同じ問題を持つ**: `assert_not_contains` を stdout だけに当てても、対象の文字列が stderr にしか出ないなら構造的に常時 pass する false positive になる。「この assert はどの実装で落ちるか」を問うと同型の欠陥を検出できる。

## 関連ページ

- [テストヘルパーの awk flip-flop レンジは start pattern をコード行に一意なプレフィックスでアンカーする](../patterns/awk-flip-flop-range-start-pattern-anchoring.md)
- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](./locale-dependent-error-message-grep-assertion.md)
- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](../patterns/mutation-prove-new-pin.md)

## ソース

- [PR #2498 review results](../../raw/reviews/20260901T053153Z-pr-2498.md)
- [PR #2498 fix results](../../raw/fixes/20260901T055639Z-pr-2498.md)
