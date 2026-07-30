---
type: "heuristics"
title: "診断WARNINGの宛先（実行エージェント向けかユーザー向けか）を主語で明示する"
domain: "heuristics"
description: "sandbox 干渉等を明示的に名指しする WARNING 文言は、そのメッセージを読む実行エージェント自身が持つ別のルール（例: sandbox 起因の失敗を検知したら dangerouslyDisableSandbox で自動再試行する）の発火条件を意図せず満たしてしまうことがある。復旧コマンドの宛先（ユーザーが手動実行 / エージェントは再試行禁止）を主語で明示する。"
created: "2026-07-20T05:29:02+00:00"
updated: "2026-07-20T05:29:02+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260720T052902Z-pr-1924.md"
tags: []
confidence: medium
---

# 診断WARNINGの宛先（実行エージェント向けかユーザー向けか）を主語で明示する

## 概要

skill やスクリプトが出す診断 WARNING（例:「sandbox の read-only bind mount により git worktree remove が構造的に失敗します」）は、そのメッセージ自体が「失敗原因は sandbox 起因である」という、実行環境（Claude Code の harness）が持つ別の自動化ルールの発火条件を満たしてしまうことがある。WARNING を読む主体（人間のユーザーか、そのメッセージを出力させた実行エージェント自身か）を文中で明示しないと、意図しない自動再試行を誘発しうる。

## 詳細

worktree/branch 遅延回収の dead-lock を解消した PR で追加された busy(EBUSY) WARNING は、「Claude Code の sandbox が read-only bind mount を張っている環境では git worktree remove は構造的に失敗する」ことを明示的に述べ、手動復旧コマンドを提示していた。cycle 4 の prompt-engineer-reviewer が指摘したのは、この WARNING 自身が「sandbox 起因の失敗の明示的証拠」を含むため、この skill を実行している Claude Code エージェント自身が持つ harness レベルのルール（「sandbox 制約が失敗原因だと分かったら dangerouslyDisableSandbox で即座に再試行する」）を、意図せず起動しうるという点だった。

本来この busy 失敗は「non-blocking として遅延 reap（別プロセスである SessionStart hook 経由）へ委譲する」設計だったが、WARNING の文言だけでは「復旧コマンドは誰が実行すべきか」が曖昧で、実行エージェントがその場で dangerouslyDisableSandbox 付きで再試行してしまう余地があった（実害は軽微〔うまくいけば即時解決、失敗しても同じ busy で委譲に戻るだけ〕だが、設計意図とは異なる経路）。

**対応**: WARNING 文に「実行エージェントはこの場で sandbox を無効化して同コマンドを再試行しないこと」という一文を明示的に追加し、復旧コマンドの主語を「ユーザーが」に変更した。これにより、同一メッセージ内で「監査対象（実行エージェント）」と「復旧の実行者（ユーザー）」を主語で分離した。

**教訓（汎用化）**: 実行エージェント（LLM）が自らの判断で対応しうる環境下で診断メッセージを設計する際、メッセージの内容が別の自動化ルール（harness のガードレール、他 skill の判定条件等）の発火条件と重なっていないかを確認する。特に「原因を名指しし、復旧コマンドを提示する」形式の WARNING は、そのメッセージ自体が「次にすべきこと」の指示として実行エージェントに解釈されうるため、宛先（誰が読み、誰が行動すべきか）を主語で明示することがリスク低減になる。

## 関連ページ

- （関連ページなし）

## ソース

- [PR #1924 fix results (cycle 4)](../../raw/fixes/20260720T052902Z-pr-1924.md)
