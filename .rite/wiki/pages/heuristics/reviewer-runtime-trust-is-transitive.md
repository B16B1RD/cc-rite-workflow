---
title: "Reviewer の runtime trust は entrypoint ではなく推移的 execution graph で判定する"
description: "reviewer prompt が「自然な entrypoint を実行して検証する」と要求すると、未信頼 PR が変更したコードを reviewer 権限で実行する誘導経路になる。"
domain: "heuristics"
created: "2026-08-09T08:43:00+09:00"
updated: "2026-08-09T08:43:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260808T233606Z-pr-2187.md"
tags: ["reviewer", "security", "runtime", "trust-boundary", "sandbox"]
confidence: high
---

# Reviewer の runtime trust は entrypoint ではなく推移的 execution graph で判定する

## 概要

reviewer prompt が「自然な entrypoint を実行して検証する」と要求すると、未信頼 PR が変更したコードを reviewer 権限で実行する誘導経路になる。entrypoint 自体が base branch に存在しても、その先で PR-controlled な helper、設定、依存物を load すれば同じ危険が残る。runtime 実行を許す条件は、完全な execution graph が PR-controlled 要素を一切 load しないと静的に証明できる場合、または隔離境界が secrets・network・disposable tree 外への write を除去する場合に限定する。

## 詳細

### 失敗モード

1. reviewer の READ-ONLY 契約はファイル編集を禁じても、テストや CLI の実行までは許すことがある。
2. PR が変更可能な entrypoint を必須実行にすると、任意コード実行を reviewer 自身に指示できる。
3. 「base branch の entrypoint なら安全」という修正も不十分。通常の test runner や CLI は PR で変更された helper・設定・依存物へ推移的に到達する。
4. reviewer 環境が secrets、network、親 worktree への write を持つ場合、情報送信や状態改変が成立する。

### Canonical 対策

- 実測の既定は runtime 実行ではなく、real initial state からの static trace とする。
- runtime を許すなら entrypoint の由来ではなく、完全な execution graph が PR-controlled code・configuration・dependencies を load しないことを証明する。
- 上記を証明できない場合は、secrets と network を除去し、write を disposable tree 内へ限定した isolation boundary を必須にする。
- reviewer の Detection Process を増やしたら shared checklist に対応項目を置き、contract test で trust 条件と isolation 条件を別 assertion として pin する。

### 検証

起点 review では初回 security review が natural entrypoint の無条件実行を HIGH と判定した。cycle 2 で base-branch entrypoint 例外の推移的盲点を再検出し、cycle 3 で execution graph 全体と isolation の二択へ修正して 5 reviewer すべて 0 findings に収束した。

## 関連ページ

- [セキュリティ境界 hook の timeout は fail-open — 評価コストは入力サイズで O(1) 上限を設けて bound する](./security-hook-timeout-is-fail-open-bound-cost-by-input-size.md)
- [Reviewer rule 自身を編集する PR は self-application false positive を verify する](./self-applying-reviewer-rule-false-positive.md)
- [回帰防止テストは mutation で識別力を確認する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [PR #2187 review](../../raw/reviews/20260808T233606Z-pr-2187.md)
