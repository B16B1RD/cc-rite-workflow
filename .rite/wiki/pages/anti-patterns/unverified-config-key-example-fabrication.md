---
type: "anti-patterns"
title: "ドキュメントに未検証の具体的設定キー例を書くと存在しないキー名を捏造してしまう"
domain: "anti-patterns"
promote: rite-plugin
description: "sandbox のような read/write で構造が異なる設定を説明する際、実機の構造を確認せず記憶や類推だけで具体的なキー名を書くと、read 側専用のキーを write 側の例として誤って挙げるなど存在しない設定キーを捏造しやすい。SoT が抽象的な表現に留めている場合はそれに倣うか、実機で構造を確認してから具体キーを書くべき。"
created: "2026-07-20T07:50:27Z"
updated: "2026-07-20T07:50:27Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260720T065752Z-pr-1925.md"
tags: ["documentation", "sandbox", "verification", "hallucination"]
confidence: medium
---

# ドキュメントに未検証の具体的設定キー例を書くと存在しないキー名を捏造してしまう

## 概要

sandbox の read/write 許可リストのように、似た形だが read 側と write 側で構造が異なる設定を説明するとき、実機の構造を確認せず記憶や類推だけで具体的なキー名を書くと、read 側専用のキーを write 側の例として誤って挙げるなど、実在しない設定キーを捏造してしまうことがある。

## 詳細

sandbox 有効環境かつ multi_session 環境向けの案内メッセージに、恒久対処の例として `sandbox.filesystem.write.allowWithinDeny` という設定キーを記載していた。しかし実際の sandbox 構造（本セッションの Bash tool 定義で実証）は以下のように read 側と write 側で異なるフィールド名を持つ:

- read 側: `{denyOnly, allowWithinDeny}`
- write 側: `{allowOnly, denyWithinAllow}`

`allowWithinDeny` は read 側専用のキーであり、write 側には存在しない。2 名の reviewer が独立に「本セッションの Bash tool 定義」という一次証拠を根拠にこの誤りを検出した。

一方、この案内が参照する Source of Truth（`git-worktree-patterns.md` の sandbox write 拒否への対処節）は、具体的なキー名を挙げず「`/sandbox` コマンド、または settings の sandbox 設定」という抽象的な表現に留めていた。本 PR のメッセージはこの抽象表現から逸脱し、`/sandbox` コマンドへの言及も落として誤った raw key を名指ししてしまっていた。

**教訓**: 設定値の具体例をドキュメントに書く際、SoT が抽象的な表現に留めている場合はそれに倣うべきである。あえて具体キーを書きたい場合は、記憶や類推に頼らず実機の構造（本ケースではエージェント自身が実行されているツール定義）を確認してから書く。read/write で対称に見えて非対称な構造を持つ設定は特に誤りやすい。

## 関連ページ

- [セッション worktree + sandbox 環境の 2 つの罠: cwd 相対 write-allowlist によるブロックと `.rite-plugin-root` のブランチ相違](../heuristics/worktree-cwd-write-allowlist-and-plugin-root-staleness.md)

## ソース

- [PR #1925 fix results (cycle 1)](../../raw/fixes/20260720T065752Z-pr-1925.md)
