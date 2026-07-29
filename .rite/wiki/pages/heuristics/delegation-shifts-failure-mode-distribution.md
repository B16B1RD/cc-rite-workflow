---
type: "heuristics"
title: "inline 実装を helper へ委譲したら、診断メッセージを新しい失敗分布へ揃える"
domain: "heuristics"
description: "inline awk を helper 呼び出しへ置換すると、最も起こりやすい失敗が「awk の IO エラー」から「helper 解決不能 = rc=127」へ移る。診断メッセージが旧い分布のままだと運用者は起きていない原因へ誘導される。同じ委譲を複数サイトで行うと片方だけ更新して非対称が残りやすく、PR #2051 では 3 サイクルにわたって同じ非対称が指摘され続けた。"
created: "2026-07-30T01:20:00+09:00"
updated: "2026-07-30T01:20:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260729T153523Z-pr-2051-c3.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T153947Z-pr-2051-c3.md"
tags: []
confidence: high
---

# inline 実装を helper へ委譲したら、診断メッセージを新しい失敗分布へ揃える

## 概要

コードを inline から helper スクリプトへ切り出すと、**何が最も起こりやすい失敗か**が変わる。inline awk なら IO エラーやパターン不一致が主だったが、helper 化した後の支配的な失敗は「helper を解決できない（rc=127）」になる。診断メッセージと reason 表が旧い分布のまま残ると、運用者は実際には起きていない原因を調べることになる。

## 詳細

### 失敗分布の変化

| 実装形態 | 支配的な失敗 | rc |
|---|---|---|
| inline awk | ファイルが読めない / awk バイナリ異常 | awk 依存（2 等） |
| helper 委譲 | **helper のパスが解決できない / plugin 未配置** | **127** |
| helper 委譲 | helper 内部の引数・ファイル不正 | helper が定義した値（2 等） |
| helper 委譲 | helper 内部の awk 異常 | helper が伝播した値 |

`{plugin_root}` のような placeholder を持つ skill 本文では、置換が行われないまま `bash {plugin_root}/hooks/scripts/foo.sh` が実行されると 127 になる。これは helper 化して初めて生まれた失敗経路であり、委譲前の診断には存在しない。

### 対処: rc を捕捉して原因候補を列挙する

```bash
helper_err=$(mktemp "${TMPDIR:-/tmp}/rite-helper-err-XXXXXX" 2>/dev/null) || helper_err=""
if raw=$(bash {plugin_root}/hooks/scripts/read-config.sh "$repo_root/rite-config.yml" 2>"${helper_err:-/dev/null}"); then
  config_value="$raw"
else
  helper_rc=$?
  echo "WARNING: rite-config.yml の読取 helper が失敗しました (rc=$helper_rc)" >&2
  echo "  原因候補: helper 解決不能 (rc=127、plugin path の解決失敗 / plugin 未配置) / 引数・ファイル不正 (rc=2) / awk バイナリ異常 / IO エラー" >&2
  [ -n "$helper_err" ] && [ -s "$helper_err" ] && head -3 "$helper_err" | sed 's/^/  /' >&2
  [ -z "$helper_err" ] && echo "  (stderr 退避用 tempfile の mktemp に失敗したため helper の stderr は失われています)" >&2
  config_value=""
fi
```

`if cmd; then ... else helper_rc=$?` の else 節先頭では、bash の仕様上 `$?` は条件コマンドの rc を保持する（実測で rc=42 / rc=127 の伝播を確認済み）。

### 診断文に置換対象の placeholder を書かない

上の例で `原因候補: ... ({plugin_root} 未置換 ...)` と書くと、skill loader が本文の `{plugin_root}` を絶対パスへ置換するため、実行時には「`/abs/path/plugins/rite` 未置換」という**それ自体が矛盾した文言**が表示される。置換されても意味が壊れない表現（「plugin path の解決失敗」）を使う。

### 複数サイトへの委譲は非対称が残りやすい

PR #2051 では 4 つの skill が同じ helper へ委譲したが、診断メッセージの更新が 1 サイトだけ遅れ、**3 サイクル連続で同じ非対称が指摘された**。委譲を複数箇所で行うときは、以下を同時にスイープする。

1. 各 caller の WARNING 文言（原因候補の列挙）
2. reason 表 / exit code 契約表の説明文
3. helper 側 header の caller 列挙
4. 設計判断ドキュメントの「なぜ inline なのか」記述（委譲後は前提が変わる）

削除した inline シンボル名で全文 grep するのが唯一の確実な検出手段になる。

### 委譲で変わらないもの

helper 化しても、**失敗時の既定値（fallback）の意味は変えてはならない**。委譲前に「読取失敗 → `false` へ倒す」だった箇所を、委譲後に「読取失敗 → 空文字」に変えると、下流の分岐が別経路へ落ちる。診断だけを新分布に揃え、既定動作は不変に保つ。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [全域で成功する resolver への委譲が既存 fail-fast ガードを silent success 化する](../anti-patterns/total-resolver-delegation-defeats-fail-fast-gate.md)
- [陳腐化した相互参照には「ただ古い」ものと「修正した欠陥へ戻す誘導」がある](./stale-cross-reference-that-guides-back-to-the-defect.md)
- [stderr ノイズ削減: truncate ではなく selective surface で解く](./stderr-selective-surface-over-truncate.md)

## ソース

- [PR #2051 review results (cycle 3)](../../raw/reviews/20260729T153523Z-pr-2051-c3.md)
- [PR #2051 fix results (cycle 3)](../../raw/fixes/20260729T153947Z-pr-2051-c3.md)
