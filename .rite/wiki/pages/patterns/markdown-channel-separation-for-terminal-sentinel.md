---
title: "Markdown channel separation で HTML sentinel の終端性と bash tool 実行を両立させる"
domain: "patterns"
created: "2026-04-24T14:55:00+00:00"
updated: "2026-04-24T14:55:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260424T095915Z-pr-655-cycle6.md"
  - type: "reviews"
    ref: "raw/reviews/20260424T085837Z-pr-655.md"
  - type: "reviews"
    ref: "raw/reviews/20260424T080338Z-pr-655.md"
  - type: "fixes"
    ref: "raw/fixes/20260424T081225Z-pr-655.md"
  - type: "fixes"
    ref: "raw/fixes/20260424T090428Z-pr-655.md"
tags: [markdown, commonmark, html-block, sentinel, bash-tool, terminal-workflow]
confidence: high
---

# Markdown channel separation で HTML sentinel の終端性と bash tool 実行を両立させる

## 概要

CommonMark HTML block (type 2) は前後に空行を要求するため、workflow 完了 sentinel (`<!-- [xxx:completed] -->`) を独立行で emit すると rendered view に余計な空行が可視化される。`bash tool stdout/stderr` は assistant response の markdown text channel と **別チャンネル**であるため、sentinel 出力後の bash 実行は markdown 最終行性を壊さない。inline HTML として list item 末尾に埋め込むことで前方空行要求を回避し、sentinel 後に bash tool で terminal state patch を実行できる設計。

## 詳細

### Root Cause: CommonMark HTML block type 2 の空行要求

CommonMark 仕様 (HTML block type 2, `<!--` で始まる comment) は HTML block を確定させるために **前後の空行** を要求する。renderer は独立行で `<!-- ... -->` を見つけると前後に空行を補う。これが以下の可視化につながる (Issue #652 Root Cause):

```markdown
1. /rite:issue:list で次の Issue を確認
2. /rite:issue:start <issue_number> で新しい作業を開始

<!-- [cleanup:completed] -->
```

↓ rendered view

```
1. /rite:issue:list で次の Issue を確認
2. /rite:issue:start <issue_number> で新しい作業を開始

                                                    ← 空行 (前方)
(HTML コメント、rendered 不可視)

                                                    ← 空行 (後方)
```

rendered で上に `Ran 1 shell command` UI が表示されると「list 末尾 → 空行 → `Ran 1 shell command` → 空行 → recap」の順で**前方・後方両方の空行**が合流し、意図しない余白としてユーザーに見える。

### Fix: Inline HTML sentinel で前方空行要求を回避

最終 list item の末尾に半角スペース区切りで inline 付加:

```markdown
1. /rite:issue:list で次の Issue を確認
2. /rite:issue:start <issue_number> で新しい作業を開始 <!-- [cleanup:completed] -->
```

inline 配置では前方に space separator だけが必要なため、HTML block type 2 ではなく **inline HTML** として処理される。前後空行要求は発動せず、rendered view での余計な空行が消える。かつ sentinel 文字列は `grep -F '[cleanup:completed]'` で fixed-string match 可能で、hook / lint script からの検出性を失わない。

### Bash tool 実行と markdown 最終行性の分離

Claude Code の実行モデル上、**bash tool stdout/stderr は assistant response の markdown text channel とは別のチャンネル** に出力される (Bash tool result として conversation 上に別枠表示)。したがって:

- Step 2 で sentinel (markdown response の absolute last line) を出力した **後** に
- Step 3 で bash tool を呼び出して `flow-state-update.sh patch` を実行しても

response text の absolute last line は sentinel のまま保たれる。bash output は response text の一部ではないため。これにより ingest.md Phase 9.1 のような「sentinel 出力 → terminal state patch」の document order と実行 order が一致し、terminal state 保証のタイミング contract を崩さずに済む (Issue #618 PR #624 で明文化)。

### 前方空行要求と後方空行要求の双対

markdown channel separation モデルが扱う範囲は「後方空行要求の吸収」だけでは不十分で、以下の **双対** を両方論じる必要がある (PR #655 cycle 6 F-C6-15 SUGGESTION):

| 方向 | 要求源 | 可視化経路 | 対処 |
|------|--------|-----------|------|
| **前方空行要求** | list item → HTML block 境界 (HTML block 開始前) | 最終 list item 直後の独立 HTML コメントで発動 | inline HTML sentinel で回避 (本 pattern) |
| **後方空行要求** | markdown 文書末尾 → 後続 content 境界 | sentinel 後に bash UI が続く場合に発動 | bash tool が別チャンネル (markdown 最終行を壊さない) で吸収 |

cleanup.md (Issue #652) と ingest.md (Issue #618) はこの双対に対して **意図的に異なる構造** (cleanup: inline sentinel + 2 ブロック構造 / ingest: independent sentinel + 3 ブロック構造 = 三点セット規約) を採用しており、両者の **意図的 divergence** を silent unification regression から守るため `stop-guard-cleanup.test.sh` / `stop-guard-ingest.test.sh` の canonical phrase pin で cross-arm lexical consistency を pin している。

### 適用 scope

- 本 pattern は「workflow 完了 sentinel を markdown 応答で emit する」全 skill に適用可能
- 単独 sentinel (lint / ingest / cleanup / create-interview / close / etc.) の placement 設計時に、前方空行要求が発動する文脈 (list 末尾 / blockquote / code fence 境界) では inline 配置、そうでない文脈 (独立セクション) では independent-line 配置を選択する
- 選択基準は「rendered view での可視空行が workflow 体験を阻害するか」で判定する。阻害する場合は inline 必須

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](prose-design-without-backing-implementation.md)
- [同 file 内 MUST NOT vs MUST 衝突: bare form 禁止規約と bare form 出力義務の自己矛盾](../anti-patterns/same-file-must-not-vs-must-conflict.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](drift-check-anchor-semantic-name.md)

## ソース

- [PR #655 cycle 6 review — markdown channel separation E-4 経験則](../../raw/reviews/20260424T095915Z-pr-655-cycle6.md)
- [PR #655 cycle 4 review — markdown channel separation factual model 初提示](../../raw/reviews/20260424T085837Z-pr-655.md)
- [PR #655 cycle 3 review — #652 Root Cause 散文モデル](../../raw/reviews/20260424T080338Z-pr-655.md)
- [PR #655 cycle 3 fix — inline HTML sentinel 適用実装](../../raw/fixes/20260424T081225Z-pr-655.md)
- [PR #655 cycle 5 fix — factual correction と anti-pattern doc 整合](../../raw/fixes/20260424T090428Z-pr-655.md)
