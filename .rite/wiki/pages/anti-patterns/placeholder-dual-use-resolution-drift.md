---
title: "同一 placeholder を識別子と resolution-target で再利用すると path-resolution drift を生む"
domain: "anti-patterns"
description: "同一 placeholder トークン (例: `{source_ref}`) を「frontmatter フィールドの識別子 (bare path、resolution 対象外)」と「Markdown link URL の path 値 (resolution 対象)」の 2 用途で再利用すると、後者の resolution 文脈で必要な prefix (例: `../../`) が抜けたまま実装されて silent broken_refs を量産する failure mode。"
promote: rite-plugin
created: "2026-05-13T00:00:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260512T235812Z-pr-939.md"
  - type: "reviews"
    resource: "raw/reviews/20260513T004127Z-pr-942.md"
  - type: "reviews"
    resource: "raw/reviews/20260513T030502Z-pr-943.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-13T11:55:00+00:00" }
---

# 同一 placeholder を識別子と resolution-target で再利用すると path-resolution drift を生む

## 概要

同一 placeholder トークン (例: `{source_ref}`) を「frontmatter フィールドの識別子 (bare path、resolution 対象外)」と「Markdown link URL の path 値 (resolution 対象)」の 2 用途で再利用すると、後者の resolution 文脈で必要な prefix (例: `../../`) が抜けたまま実装されて silent broken_refs を量産する failure mode。起点事例で wiki page-template.md の `{source_ref}` が同症状を示し broken_refs 218 件の根本原因となった実測。

## 詳細

### 観測された症状

`plugins/rite/templates/wiki/page-template.md` の `{source_ref}` placeholder が以下の 2 箇所で参照されていた:

| 箇所 | 用途 | 文脈 |
|------|------|------|
| line 8 (`sources[].ref:`) | frontmatter フィールド値 (識別子) | YAML / lint scope 外、解決対象ではない |
| line 29 (`[desc]({source_ref})`) | Markdown link URL | wiki page (`.rite/wiki/pages/{domain}/`) を起点に resolution される |

ingest.md の substitution logic は `{source_ref}` に bare path (例: `raw/reviews/20260413T...md`) を渡していたため、line 8 は意図通り動作するが line 29 は wiki root への 2 階層上昇を表す `../../` prefix が欠落し、`.rite/wiki/pages/{domain}/raw/reviews/20260413T...md` (存在しない) を指して `/rite:wiki:lint` が broken_refs として検出していた (40 pages × 平均 5.45 件 = 218 件)。

### 修正パターン

placeholder 値そのものを変更すると line 8 (識別子) の semantics が破壊されるため、**template リテラル側に prefix を hardcode** することで両用途の分離を保ったまま resolution を正しく行う:

```markdown
# Before (broken)
sources:
  - ref: "{source_ref}"          # ← line 8: 識別子、bare path で OK
- [{source_description}]({source_ref})  # ← line 29: URL、bare path だと broken

# After (fixed in PR #939)
sources:
  - ref: "{source_ref}"          # ← 不変、識別子のまま
- [{source_description}](../../{source_ref})  # ← prefix を template literal 側に追加
```

`{source_ref}` placeholder 自体は wiki-root 相対 bare path のまま維持され、URL prefix は template 側の責務として明示分離される。

### Canonical fix の文書化

起点事例の URL prefix 修正後、`plugins/rite/commands/wiki/ingest.md` L780 の F-15 fix 注釈は「両方とも **ファイル相対パス** を使用」と記述されたままで、読者が「placeholder 値そのものが `../../raw/...` を持つ」と誤読し本 anti-pattern を再導入する経路が残っていた。設計意図追記 PR で同 L780 直後に「設計意図」段落を追記し、「placeholder 値は wiki-root 相対 bare path / `../../` prefix は template リテラル側で hardcode (page-template.md L29 参照)」という設計分担を明文化した (2 行追記、0 findings 1 cycle 着地)。canonical fix の **コード修正** と **設計意図の文書化** が完了したことで、本 anti-pattern の再導入リスクは visual cue / implicit 推論レベルから明示宣言レベルへ縮小した。

### 周辺 placeholder への対称化と起点規約の明示

起点事例の review で tech-writer + code-quality reviewer が「他の placeholder (`{related_page_path}` 等) も同種問題を潜在している可能性」を LOW で指摘し別 Issue として登録された。逆引き調査 PR で `{related_page_path}` の実起点を逆引き調査した結果、本 anti-pattern とは **異なる解 (page-dir 起点)** で既に機能していることが実測確認された:

- 実 wiki page (`.rite/wiki/pages/anti-patterns/asymmetric-fix-transcription.md` 等多数) の `## 関連ページ` link は `./other.md` / `../{domain}/other.md` 形式の **page-dir 相対 path** で記述されており動作している
- `{source_ref}` (wiki-root 起点 + template 側 `../../` prefix hardcode) と起点が異なる
- broken_refs は現時点で発生していないため、page-template.md L25 の修正は不要

しかし起点規約自体が ingest.md / wiki-patterns.md に未明示だったため、将来の ingest 実装で wiki-root 起点 path を出力する drift 経路は残存していた。逆引き調査 PR で ingest.md Phase 5.3 に `{related_page_path}` 用の「設計意図」blockquote（前項と対称形式）を追加し、wiki-patterns.md L220 の placeholder 説明を「page-dir 相対パス」明示版に更新することで、両 placeholder の起点規約を明示分離して文書化した (3 行追加 / 1 行修正、両 reviewer 評価「可」で 0 findings 1 cycle 着地)。

### 累積知識構築パターン

`{source_ref}` 系列（修正 → 注釈）と `{related_page_path}` 系列（対称化）を通じ、本 anti-pattern への対策は以下の累積構造を持つ:

1. **本 anti-pattern 識別**: broken_refs 218 件の root cause として placeholder dual-use を特定
2. **コード修正**: template リテラル側に prefix を hardcode する canonical fix を適用
3. **設計意図の文書化**: canonical fix の根拠 (frontmatter 識別子 vs Markdown link URL の semantics 分離) を ingest.md に注釈追加
4. **周辺 placeholder への対称化**: 別 placeholder (`{related_page_path}`) の起点規約を逆引き調査し、異なる解 (page-dir 起点) の場合も含めて 2 つの起点規約を明示分離

「設計意図 (#XXX fix)」blockquote 形式を canonical として ingest.md Phase 5.3 に集約することで、将来の placeholder 追加時にも同型の起点規約明示を強制でき、本 anti-pattern の再導入リスクを構造的に縮小できる。

### Root Cause Analysis

`{source_ref}` という 1 つの placeholder トークンに 2 つの異なる semantics (識別子 vs resolution-target) を持たせると、片方の semantics 変更が他方に影響しないかを毎回確認する責務が implicit に発生する。レビュアー / 開発者は「placeholder 名が同じ」という visual cue から「同じ semantics」と誤推論しやすく、resolution 文脈の prefix 要件を見落とす。

### 検出シグナル

以下のパターンが diff に現れたら本 anti-pattern の警戒対象:

- 同一 placeholder トークン (`{X}` / `${X}` / `%X%` 等) が同一 template 内で **異なる文脈** で参照されている
  - frontmatter / YAML / config フィールドの値 (構造化データ、識別子)
  - Markdown link URL / HTML href / script src (resolution 対象、相対 path 計算が必要)
  - bash 変数展開 / コマンド引数 (シェル escaping が必要)
- placeholder 値そのものに resolution prefix を含めるか、template literal 側に prefix を hardcode するか、設計判断が明示されていない

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../../pages/anti-patterns/asymmetric-fix-transcription.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../../pages/anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #939 review results](../../raw/reviews/20260512T235812Z-pr-939.md)
- [PR #942 review results](../../raw/reviews/20260513T004127Z-pr-942.md)
