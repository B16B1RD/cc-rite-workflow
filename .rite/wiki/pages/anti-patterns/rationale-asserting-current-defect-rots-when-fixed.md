---
type: "anti-patterns"
title: "恒久規範の理由付けを「今は動かない」という現時点の欠陥への断定に置くと、欠陥が直った時点で規範が静かに誤りになる"
domain: "anti-patterns"
description: "原則ファイルに「運用環境は `CLAUDE.md` に宣言する — **Wiki は reviewer が読まないため** — なぜなら reviewer 側の Guardrail がこの宣言を参照するから」と書いた。"
created: "2026-08-03T00:55:00+09:00"
updated: "2026-08-03T00:55:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T143430Z-pr-2092.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T143712Z-pr-2092.md"
tags: ["documentation-drift", "stale-assertion", "prompt-engineering", "cross-file-consistency"]
confidence: high
---

# 恒久規範の理由付けを「今は動かない」という現時点の欠陥への断定に置くと、欠陥が直った時点で規範が静かに誤りになる

## 概要

原則ファイルに「運用環境は `CLAUDE.md` に宣言する — **Wiki は reviewer が読まないため** — なぜなら reviewer 側の Guardrail がこの宣言を参照するから」と書いた。宣言先を 1 つに絞る判断は妥当だったが、その理由として添えた「reviewer は Wiki を読まない」という断定が 2 つの問題を持っていた:

1. **事実として偽**: Wiki を reviewer prompt へ注入する経路は実在し、config でも有効だった（現状 0 件を返すのは index 形式を parse できない**別の欠陥**であり、経路の不在ではない）
2. **同一コーパス内の現行 MUST と矛盾**: 同じ reviewer 契約ファイルが「fallback を throw に変える前に Wiki を参照せよ」を MUST として課し、別の節で Wiki entry を引用可能な convention として列挙していた

## 詳細

**なぜ危険か**

理由が追跡中の欠陥（この場合は index 形式の parse 未対応、別 Issue で修正予定）に依存していると、**欠陥が修正された瞬間に規範側の記述が偽になる**。しかも規範ファイルと欠陥 Issue の間に依存の記録がないため、修正時に規範を直す動機も検出手段も存在しない。

**実害の向き**

「Wiki は届かない」と読んだ reviewer が、同一ファイル内の「Wiki を consult せよ」という必須ゲートを無意味と判断して skip すると、プロジェクトが Wiki で明示的に許容している fallback に対して誤って `throw` を要求する。false positive を生む方向へ倒れる。

**対処**

理由付けの従属節だけを**削除**する。判断（宣言先を `CLAUDE.md` に絞る）は残る。文の機能は後半の因果説明（「reviewer 側の Guardrail がこの宣言を参照するから」）が単独で果たしており、「Wiki は届かない」は文の成立に不要だった。

書き換え案（「Wiki は条件付き注入のため確実には届かない」等の正確な記述への置換）を採らないのは、注入条件を正確に書くと同一ファイル内の Wiki 参照 MUST との関係を別途整理する必要が生じ、当該 Issue のスコープを超えるため。

**一般化**

恒久規範に理由を書くときは「その理由が真であり続ける条件」を自問する。条件が「別 Issue が未修正であること」なら、その理由は書かない。書くなら backlink（`#NNNN の修正までの暫定`）を添えて、修正時に規範側も直る導線を残す。

## 関連ページ

- [規約の強制度が矛盾したら、緩い側を強めるより強い側の適用範囲を絞る](../heuristics/resolve-strength-conflict-by-narrowing-the-strong-side.md)
- [記録義務を規約に書く前に、その記録先を読む consumer が実在するかを grep で確かめる](../patterns/obligation-requires-existing-consumer-before-writing.md)

## ソース

- [PR #2092 review results (cycle 2)](../../raw/reviews/20260802T143430Z-pr-2092.md)
- [PR #2092 fix results (cycle 2)](../../raw/fixes/20260802T143712Z-pr-2092.md)
