---
title: "同一手順が複数 site に分散する場合は片方を canonical source と宣言する"
domain: "patterns"
description: "同一の placeholder 値生成手順 / 規約 / 設計判断が文書内の複数 site に書かれる場合、放置すると Asymmetric Fix Transcription を誘発する。"
promote: rite-plugin
created: "2026-05-13T06:43:41Z"
updated: "2026-05-13T08:55:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260513T063128Z-pr-946-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260513T060844Z-pr-946.md"
  - type: "reviews"
    ref: "raw/reviews/20260513T080326Z-pr-947.md"
  - type: "reviews"
    ref: "raw/reviews/20260513T081242Z-pr-947-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260513T082018Z-pr-947-cycle-3.md"
  - type: "fixes"
    ref: "raw/fixes/20260513T080706Z-pr-947-fix-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260513T081626Z-pr-947-fix-cycle-2.md"
tags: ["canonical-source", "drift-prevention", "asymmetric-fix-transcription", "precedence-rule", "review-fix-convergence", "multi-canonical-per-file", "citation-structuring"]
confidence: high
---

# 同一手順が複数 site に分散する場合は片方を canonical source と宣言する

## 概要

同一の placeholder 値生成手順 / 規約 / 設計判断が文書内の複数 site に書かれる場合、放置すると Asymmetric Fix Transcription を誘発する。canonical fix は「**片方を canonical source と明示宣言** し、他方は summary / cross-reference 位置付けに整理する」こと。precedence rule (矛盾発生時は canonical を優先) を本文に書くことで、reviewer 評価で severity 差 (PARTIAL vs FIXED) が出ても silent drift にならず合意に収束する。

## 詳細

### 観測

`commands/wiki/ingest.md` で `{related_page_title}` / `{related_page_path}` placeholder の値生成手順が以下の 3 site に分散していた:

1. 新規 `### 4.3 関連ページの特定` セクション (canonical fix のメイン site)
2. Phase 5.3 placeholder 表の `{related_page_title}` / `{related_page_path}` 行
3. Phase 5.3 直下の「設計意図 (#941 fix)」blockquote

cycle 1 review で「fallback 文字列が 2 箇所に literal で存在し drift 源を形成」(MEDIUM)・「循環参照ループ」(LOW) が指摘された。fix 適用時に「4.3 を canonical source」と明示宣言し、Phase 5.3 の placeholder 表と blockquote を summary / cross-reference に位置付け直すことで cycle 2 で 0 blocking findings に収束 (1 cycle convergence)。

### 適用パターン

```markdown
> **Canonical source 宣言**: 本セクション (X.Y) は `{placeholder}` の値決定手順の **canonical source** です。
> Phase A.B の placeholder 表と #NNN fix 設計意図 blockquote は要約・補足記述であり、
> 矛盾が発生した場合は本 X.Y を優先します。
```

各 site の **役割**:

| Site | 役割 | 内容詳細度 |
|------|------|----------|
| Canonical source | 値生成手順の唯一の真実源 | 完全な手順 + 規約 + 該当なし時の fallback |
| Summary site | placeholder 表 / 概要表 | placeholder 名 + 一言要旨 + canonical へのリンク |
| Cross-reference site | 設計意図 blockquote / forward reference | 「詳細は X.Y 参照」の 1 行 |

### Reviewer 評価への効果

precedence rule (canonical 優先) が明文化されていると、cycle 2 reviewer 評価で severity 差 (PARTIAL vs FIXED) が出ても **severity gap が 1 以下に収束し agreement に到達する**。理由: 矛盾発生時の解決手順が文書内で明示されているため、reviewer は「どちらが正か」ではなく「canonical が更新されたか」を確認するだけで済む。silent drift の余地が消える。

### 検出シグナル

- 同一 placeholder / 規約が複数 site に literal で存在する (`grep` で複数 hit)
- 一方を更新すると他方が stale 化するパターンが review で指摘される
- reviewer の severity 評価が site 間で異なる (一方は FIXED、他方は PARTIAL)

### 防御策

- canonical 宣言を blockquote で目立たせ、他 site から `[[canonical-source-declaration-for-multi-site-procedure]]` リンクで参照
- summary site / cross-reference site には「canonical: §X.Y 参照」を明記し、独自詳細を書かない
- 変更時は canonical を先に更新し、他 site の summary をそれに従わせる契約を本文 / DRIFT-CHECK ANCHOR に書く

### 3 cycle 事例の観測 (3 cycle convergence + multi-canonical-per-file scope distinction)

上記の 1 cycle convergence と対比して、後続 PR は同じ「canonical source 宣言」テーマで **3 cycle 要した**。差分原因と新たに導出された 3 つの sub-pattern を以下に記録する。

#### Sub-pattern 1: Multi-canonical per file (同一ファイル内に scope の異なる canonical が共存する)

`ingest.md` 1 ファイル内に **3 つの canonical 宣言が共存** していた:

- **Phase 4.3 (L530)**: `{related_page_title}` / `{related_page_path}` の **値決定手順** の canonical
- **Phase 5.3 (L821)**: F-14 fix **fallback 動作** (該当ページなし時の操作契約) の canonical
- **L569**: 上記 4.3 ↔ 5.3 が意図的 dual-site であることの宣言

外部 references から canonical を引用する際、「どの semantic 軸の canonical を指したいか」を明確にせずに引用すると誤参照する。本 pattern の防御策は同一ファイル内で複数 canonical が legitimate に共存しうることを受け入れ、引用時に **semantic 軸 + scope** を明示する:

| 引用パターン | 例 |
|------------|-----|
| 良い (semantic + scope 明示) | 「F-14 fix **fallback 動作** の canonical は `ingest.md` **Phase 5.3** placeholder 表」 |
| 悪い (scope 曖昧) | 「canonical source は `ingest.md` Phase 4.3」(値決定手順なのか動作契約なのか不明) |

#### Sub-pattern 2: Citation 3 段階分離 (宣言場所 / 実体行 / 概念階層)

3 cycle 事例の cycle 2 で「canonical **宣言場所**」と「canonical **実体行**」を混同した citation 誤りが新たに検出された (cycle 1 で書いた「ingest.md L559 / L569」が事実誤り — 実体行は L821)。cycle 2 fix は citation を **3 種に分離** する構造化解決を採用した:

| Citation 概念 | 説明 | 3 cycle 事例での例 |
|--------------|------|-----------|
| 宣言場所 | 「X が canonical である」と宣言されている行 | L530: Phase 4.3 = 値決定手順 canonical の宣言場所 |
| 概念階層宣言 | 同一ファイル内に複数 canonical が共存することを宣言する場所 | L559: Phase 4.3 内で Phase 5.3 を F-14 fix 動作契約 canonical と明示 |
| 実体行 | canonical X 自体が実際に存在する行 | L821: Phase 5.3 placeholder 表内の `{related_page_title}` / `{related_page_path}` 行 |

canonical 参照を 1 文に詰め込まず NOTE を意味的に分離することで、reviewer が誤読する経路を構造的に閉じる。

#### Sub-pattern 3: 3 cycle 着地パターンの収束条件

1 cycle 事例と 3 cycle 事例の差分から、**cycle 2 で「症状を治す」ではなく「構造で root cause を恒久的に消す」修正を入れる必要がある** ことを導出。

- **Cycle 1**: 元 root cause (canonical 参照方向) を修正 → 修正自体が引き起こす派生 factual error が cycle 2 で surface
- **Cycle 2**: cycle 1 で introduced された factual error (citation 行番号誤り) + 残存メタ議論を **構造化** (3 段 NOTE 分離 + 4 行 citation) で恒久解消
- **Cycle 3**: 構造化により reviewer の確信ある指摘なし → 0 findings 着地

1 cycle 事例が 1 cycle で済んだのは `ingest.md` L530 **単独** で canonical 宣言を完結させたため。3 cycle 事例は references → ingest.md の **cross-file 参照** に複数の canonical (Phase 4.3 値決定手順 / Phase 5.3 動作契約) を扱う必要があり、概念階層を NOTE 内で解きほぐすコストが余分にかかった。Cross-file + multi-canonical の組み合わせは収束 cycle 数が増えると認識する。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [References 抽出時は引用先 SoT の内容を Read tool で verify する](../heuristics/references-extraction-content-fidelity.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](../anti-patterns/hallucinated-canonical-reference.md)

## ソース

- [PR #946 cycle 2 re-review (1 cycle convergence + canonical source 宣言の効力実証)](../../raw/reviews/20260513T063128Z-pr-946-cycle2.md)
- [PR #946 fix (Canonical source 宣言の明示 fix pattern)](../../raw/fixes/20260513T060844Z-pr-946.md)
- [PR #947 review cycle 1 (canonical source mismatch cross-validate)](../../raw/reviews/20260513T080326Z-pr-947.md)
- [PR #947 review cycle 2 (citation 行番号誤り + 宣言場所/実体行 概念混同)](../../raw/reviews/20260513T081242Z-pr-947-cycle-2.md)
- [PR #947 review cycle 3 (0 findings 着地 + 3 cycle convergence pattern)](../../raw/reviews/20260513T082018Z-pr-947-cycle-3.md)
- [PR #947 fix cycle 1 (multi-canonical-per-file 認識)](../../raw/fixes/20260513T080706Z-pr-947-fix-cycle-1.md)
- [PR #947 fix cycle 2 (citation 3 段階分離による構造化解決)](../../raw/fixes/20260513T081626Z-pr-947-fix-cycle-2.md)
