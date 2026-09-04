---
title: "Rename PR の callee → caller 片方向 over-translation で Out-of-Scope の broken cross-ref を生成する"
domain: "anti-patterns"
description: "大規模な heading rename PR (例: `Phase N` → `ステップ N`) で callee 側 prose に書かれた caller 参照を **片方向に翻訳した結果**、Phase 構造を維持している Out-of-Scope の caller (pr:*, issue:close 等) を「ステップ X.Y」と書き換えた箇所が、実在しない見出しを指す forward-reference drift を生む anti-pattern。"
promote: rite-plugin
created: "2026-05-27T01:30:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260526T151003Z-pr-1151.md"
  - type: "reviews"
    resource: "raw/reviews/20260526T153732Z-pr-1151.md"
  - type: "fixes"
    resource: "raw/fixes/20260526T152327Z-pr-1151.md"
tags: ["rename-pr", "cross-reference", "out-of-scope-boundary", "callee-caller-asymmetry", "forward-reference-drift"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-27T01:30:00Z" }
---

# Rename PR の callee → caller 片方向 over-translation で Out-of-Scope の broken cross-ref を生成する

## 概要

大規模な heading rename PR (例: `Phase N` → `ステップ N`) で callee 側 prose に書かれた caller 参照を **片方向に翻訳した結果**、Phase 構造を維持している Out-of-Scope の caller (pr:*, issue:close 等) を「ステップ X.Y」と書き換えた箇所が、実在しない見出しを指す forward-reference drift を生む anti-pattern。PR の Out-of-Scope 宣言を尊重したつもりが、callee 側だけ単方向に変換した結果として silent broken cross-ref が発生する。

## 詳細

### 発生条件

1. **PR scope が「callee 側のみ rename、caller 側は Out-of-Scope」と宣言されている**
2. **callee 側 prose に caller の見出し番号 (`pr/review.md Phase 6.5.W.2` 等) が書かれている**
3. **callee を rename する際、prose 内の caller 参照も「ステップ X.Y」式に書き換えてしまう**
4. **caller 側は Out-of-Scope 宣言を尊重して Phase 構造を維持する**

結果: callee 側 prose が「ステップ X.Y.W.2」と書く一方、caller 側はまだ「Phase X.Y.W.2」のため、cross-reference が解決できない silent broken link が landed する。

### 大規模 rename 事例での実測

cycle 1 で 3 reviewer (prompt-engineer / code-quality / tech-writer) が独立検出した HIGH 級 finding として 4 site で発火:

- `plugins/rite/skills/wiki/SKILL.md:112` — 3 callers (pr/review, pr/fix, issue/close) の Phase 表記を「ステップ」に over-translate
- `plugins/rite/commands/wiki/references/bash-cross-boundary-state-transfer.md:61,76` — `pr/review.md` 2 site を over-translate
- `plugins/rite/commands/wiki/ingest.md:9` — 3 callers (pr/review, pr/fix, issue/close) の Phase 参照を over-translate

cycle 2 でさらに `wiki/query.md` の 9 site + `wiki/lint.md:1406` の 1 site が同型 finding として検出 (cycle 1 の scan scope が systematic でなかったため tail residue が発生)。

### 構造的原因

「Out-of-Scope を尊重する」設計判断と「callee 内の caller 参照 prose を翻訳する」操作が **互いに矛盾する** ことに気づきにくい。rename PR の作業時、LLM は callee ファイル内の全ての `Phase` 文字列を機械的に置換しがちで、その中に Out-of-Scope caller の見出し参照が混在していると区別なく書き換えてしまう。

### Detection Heuristic

rename PR で「callee 側のみ修正、caller は Out-of-Scope」と宣言した場合:

```bash
# callee 内の caller 参照は元の表記 (Phase) を維持しているかを照合
grep -rn "{caller_path}.*ステップ" {callee_dirs}/
# (本来は "Phase" のはずなので、ヒットしたら over-translation 疑い)

# 逆方向: caller 側で実際に維持されている見出し番号と、callee 内の参照表記の cross-product 照合
for caller in {out_of_scope_callers}; do
  for callee in {scope_files}; do
    grep -n "$caller" "$callee" | grep -E "(Phase|ステップ) [0-9]"
  done
done
```

cycle N で 1 件の callee→caller drift を発見したら、同 PR 内の **全 callee × 全 Phase-maintaining caller の cross-product grep** を実行する。partial scan は同型 finding を残す経路を生む（cycle 1 → cycle 2 の tail residue で実測）。

### 派生的観察: canonical regex の silent coverage loss

本 anti-pattern と同 PR で発見された関連現象として、hooks scripts の lint 用 literal regex (`Downstream reference: [^ ]+ Phase [0-9]+...`) が rename PR で source-of-truth に追従しないと、新規導入された `Downstream reference: lint.md:ステップ 8.3` 形式が lint coverage から **silent に外れる** regression が発生する。SoT (drift-check-anchor-semantic-name.md) と implementer (backlink-format-check.sh:191) の同期契約が必要。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [18 findings](../../raw/reviews/20260526T151003Z-pr-1151.md)
