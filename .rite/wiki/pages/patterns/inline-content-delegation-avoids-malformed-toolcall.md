---
title: "インライン特殊文字 content (title/body) は Write tool・--body-file 委譲で malformed tool-call を構造的に除去する"
domain: "patterns"
description: "command spec (`.md`) 内で gh CLI に渡す title / body をインライン展開 (特殊文字 title の素埋め込み / heredoc body) すると、LLM が tool-call を組み立てる際に malformed tool-call を引き起こし workflow が停止する。"
promote: rite-plugin
created: "2026-06-09T00:00:00Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260608T145054Z-pr-1310.md"
  - type: "reviews"
    resource: "raw/reviews/20260608T144010Z-pr-1310.md"
  - type: "reviews"
    resource: "raw/reviews/20260608T154358Z-pr-1310.md"
tags: ["malformed-tool-call", "inline-delegation", "write-tool", "body-file", "three-stage-protocol", "cause-scoping"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-09T00:00:00Z" }
---

# インライン特殊文字 content (title/body) は Write tool・--body-file 委譲で malformed tool-call を構造的に除去する

## 概要

command spec (`.md`) 内で gh CLI に渡す title / body をインライン展開 (特殊文字 title の素埋め込み / heredoc body) すると、LLM が tool-call を組み立てる際に malformed tool-call を引き起こし workflow が停止する。content を Write tool でファイルへ raw 出力し、shell 変数・`--body-file` 経由で gh に渡す **3 段プロトコル (workdir mktemp -d → Write tool で title/body を raw 化 → 変数/`--body-file` で gh)** によって、インライン特殊文字に起因する停止経路 (Cause B) を構造的に除去できる。

## 詳細

`/rite:pr:create` が pr:open 経由で停止する問題を、原因を 2 系統に分けて対処した:

- **Cause B (構造的に除去可能)**: インライン特殊文字 title / heredoc body が LLM の tool-call 生成を malform させる経路。修正は 3 段プロトコル:
  1. `workdir=$(mktemp -d)` で作業ディレクトリを確保 (workdir は literal placeholder ではなく shell 変数 `pr_workdir` に束縛し、`[ -d "$pr_workdir" ]` guard 付き cleanup にすることで placeholder 置換漏れ時の `rm -rf` 誤動作も同時に防ぐ)。
  2. title / body を **Write tool でファイルへ raw 出力** する (インライン展開せず、特殊文字をそのままファイル内容として書く)。
  3. gh には `--title "$(cat ...)"` ではなく変数束縛 / `--body-file` で渡す。
- **Cause A (構造的除去は不可、honest に scope-out)**: transport ゆらぎ由来の停止。過剰約束を避け「本 PR では対処しない」と AC として明文化 (AC-5) することで reviewer の信頼を得た。「直せないものを直せると書かない」honest scoping が design の信頼性に寄与する。

3 段プロトコル分割には固有の落とし穴がある。**workdir が別プロセスを跨ぐと `trap ... EXIT` では救えない cross-process leak** が新たに発生するため、cleanup の責務境界を意識する必要がある。また inline → delegate refactor では旧 `trap ... EXIT` cleanup 契約を落とす退行が dominant failure mode として頻出する (本 PR cycle 1 で HIGH × 2、[[asymmetric-fix-transcription]] に詳細)。signal-specific trap (`EXIT`/`INT`/`TERM`/`HUP`) を再設置し inline `rm -rf` を撤去するのが canonical。

検出側 lint (`bash-heaviness-check.sh` の inline-gh-create-title signal) の awk 実装も、新規 signal 追加時の頻出カバレッジギャップを踏まえて設計する: (a) 検出 anchor (`create` 限定) を守る負例 TC、(b) backslash 行継続を含む複数行 form の取りこぼし防止 (block-level 継続トラッキング: `gh_create_active` を `\` 終端行で維持)、(c) 空 literal (`--title ""`) 誤検知の回避 (bracket expression を `[^$]` → `[^$"']` に拡張し空 title と `$var` を同時に除外)。body / title の error guard は対称化が原則 (片方だけ `[ ! -s ]` チェックがあると非対称な silent failure 経路になる)。awk state machine は実機 mutation testing (30+ targeted 入力) で「各 checklist 観点を正しい理由で検出する」ことを検証できる。

## 関連ページ

- [trap 登録 → mktemp の順序で tempfile lifecycle を守る](./trap-register-before-mktemp.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [日本語コーナーブラケットが inline code を破壊する](../anti-patterns/markdown-japanese-corner-brackets-break-inline-code.md)

## ソース

- [PR #1310 fix results (cycle 1)](../../raw/fixes/20260608T145054Z-pr-1310.md)
- [PR #1310 review results (cycle 1)](../../raw/reviews/20260608T144010Z-pr-1310.md)
- [PR #1310 review results (cycle 4)](../../raw/reviews/20260608T154358Z-pr-1310.md)
