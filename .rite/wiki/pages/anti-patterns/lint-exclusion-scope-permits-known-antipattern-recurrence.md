---
type: "anti-patterns"
title: "lint のスキャン除外スコープは既知アンチパターンの再発を検出しない盲点になる"
domain: "anti-patterns"
description: "機械的スイープで一括修正した anti-pattern（例: /tmp 直下ハードコード）を継続的に検出するはずの lint チェックが、コスト/ノイズ削減目的で特定ディレクトリ（例: */tests/*）をスキャン対象から除外していると、その除外スコープ内で同じ anti-pattern が新規コードに再導入されても検出されない。"
created: "2026-07-20T09:24:00Z"
updated: "2026-07-20T09:24:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260720T091826Z-pr-1927.md"
tags: ["lint-coverage", "tmp-hardcode", "sandbox", "test-file", "scan-scope"]
confidence: medium
---

# lint のスキャン除外スコープは既知アンチパターンの再発を検出しない盲点になる

## 概要

PR #1902 で `/tmp` 直下ハードコード（sandbox 環境で書込拒否される anti-pattern）を本番コード 21 ファイルで機械的に `${TMPDIR:-/tmp}/xxx` へ統一し、再発防止のため `tmp-hardcode-check.sh` という lint チェックが導入された。しかし `hooks/tests/worktree-git-nff-retry.test.sh` はこの lint のスキャン対象（`*/tests/*` を除外）から漏れており、同じ anti-pattern（`/tmp/wtg1.err` 等の直接ハードコード）が検出されないまま存在し続け、sandbox 環境で 9 assertion 中 7 件が失敗する形で顕在化した。

## 詳細

`tmp-hardcode-check.sh` は `*/tests/*) continue` という除外ルールを持つ。これはテストコード内の一時ファイル操作がノイズ/false-positive を生みやすいという意図的な設計判断だが、副作用として「まさにテストコードが `/tmp` を直接使いがちな箇所」を lint の保護対象外にしてしまう。

本件では、PR #1902 の機械的スイープが実施された時点で `worktree-git-nff-retry.test.sh` が対象範囲（本番コード）に含まれていなかったか、あるいはスイープ後に新規追加されたためスイープの恩恵を受けなかった。以降、この 1 ファイルだけが `/tmp` 直下ハードコードを残したまま、lint では継続的に不可視のまま存在し続けた。develop ブランチ上でも常時再現する「環境依存の既存失敗」として、テストスイートの signal を劣化させていた（実質的な回帰が埋もれるリスク）。

**教訓**:

- lint / 静的チェックがコスト・ノイズ削減のために特定ディレクトリやファイルパターンを除外している場合、その除外は「その領域では anti-pattern が発生し得ない」ことを意味しない。むしろテストコードのように、ハードコードされた一時パスや外部リソース参照が頻出する領域ほど、除外によって検出されない蓄積リスクが高い。
- 除外ルールを設計する際は、除外理由（false-positive 抑制）と副作用（既知 anti-pattern の再発が不可視化される）をセットで記録し、定期的な手動棚卸し（例: `run-tests.sh` 全体実行での signal 劣化検知）で補完する必要がある。
- 本件の場合、根本的な再発防止としては (a) `tmp-hardcode-check.sh` のスキャン対象を `*/tests/*` にも広げて false-positive を許容するか、(b) 除外を維持しつつ「新規テストファイル作成時は `${TMPDIR:-/tmp}` パターンを CLAUDE.md 等でガイドライン化する」かのトレードオフになる。本 Issue の対応では該当 1 ファイルの修正のみに留め、lint 除外ルール自体の見直しはスコープ外とした。

## 関連ページ

- [mktemp テンプレートは `${TMPDIR:-/tmp}` を使う — `/tmp` 直下ハードコードは sandbox で書き込み拒否される](../patterns/mktemp-tmpdir-prefix-for-sandbox-compat.md)

## ソース

- [PR #1927 review results](../../raw/reviews/20260720T091826Z-pr-1927.md)
