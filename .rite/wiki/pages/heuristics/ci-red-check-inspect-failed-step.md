---
type: "heuristics"
title: "赤い CI check は失敗した step を見てから変更起因と判断する"
domain: "heuristics"
description: "CI の job が FAILURE でも、checkout やネットワーク解決の段階で落ちていればテストは 1 件も実行されておらず、変更の検証結果ではない。check 名と conclusion だけで変更起因の失敗と扱わず、job の steps から失敗した step を特定してから判断する。"
created: "2026-09-14T03:36:26Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-14T03:36:26Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260914T025734Z-pr-2798.md"
tags: ["ci", "flaky-infrastructure", "evidence"]
confidence: medium
---

# 赤い CI check は失敗した step を見てから変更起因と判断する

## 概要

CI の job が FAILURE でも、checkout やネットワーク解決の段階で落ちていればテストは 1 件も実行されておらず、変更の検証結果ではない。check 名と conclusion だけで変更起因の失敗と扱わず、job の steps から失敗した step を特定してから判断する。

## 詳細

### 起きたこと

テスト追加の PR で、`tests (macos-latest)` だけが FAILURE になった。レビュアーが job のログを確認すると、失敗は `Checkout repository` step の `Could not resolve host: github.com` だった。後続の依存インストールとテスト実行の step はすべて skipped で、macOS ではテストが走っていなかった。同じ commit の ubuntu のテストと shellcheck は成功しており、失敗した job を再実行するとそのまま成功した。

### 判断の手順

1. 赤い check の job について、`gh api repos/{owner}/{repo}/actions/runs/{run_id}/jobs` で steps と各 step の conclusion を取る。
2. 失敗した step がテスト実行より前（checkout、runner のセットアップ、依存のダウンロード）なら、変更の検証結果ではない。レビューの指摘に `failing_test` の実測アンカーとして使わない。
3. 変更起因でない失敗は再実行で確かめる。再実行でも同じ step で落ちるなら、変更とは別のインフラ要因として切り分ける。

### 自動判定との関係

runner が割り当てられ step が実行されている job は、「未実行」ではなく「実失敗」に分類される。このため、checkout で落ちた job でも merge ゲートは不健全として止まる。これは安全側の挙動で、ゲートを緩める理由にはならない。人が失敗 step を確認し、再実行で健全にしてから進める。

## 関連ページ

- [CI lint チェックを blocking gate に昇格するときはツール自身の exit code を gate にする](./ci-blocking-gate-tool-exit-code.md)

## ソース

- [macOS job の checkout 失敗を変更起因と扱わなかったレビュー結果](../../raw/reviews/20260914T025734Z-pr-2798.md)
