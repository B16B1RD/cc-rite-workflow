---
type: "anti-patterns"
title: "rationale 転記圧縮時の主張スコープ量化拡大（この箇所→全体への過大一般化）"
domain: "anti-patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/anti-patterns/transcription-scope-quantifier-inflation.md"
description: "rationale を references へ退避するコンテキストダイエット型 refactor で、転記圧縮時に主張の量化スコープが「この箇所の規約」→「ファイル全体/各 bash block」へ過大一般化される系統的エラー。PR #1774 で本体 (F-01) と references 側 (F-02) の 2 回発生・3 cycle 収束を実測。転記文の量化表現（各/全体/すべて）を機械的に疑い、SKILL.md 本体と references の両側を検証する。"
created: "2026-07-07T03:56:13+00:00"
updated: "2026-07-07T03:56:13+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260707T005014Z-pr-1774.md"
  - type: "fixes"
    ref: "raw/fixes/20260707T005536Z-pr-1774.md"
  - type: "reviews"
    ref: "raw/reviews/20260707T011246Z-pr-1774.md"
  - type: "fixes"
    ref: "raw/fixes/20260707T011502Z-pr-1774.md"
  - type: "reviews"
    ref: "raw/reviews/20260707T012957Z-pr-1774.md"
tags: []
confidence: high
---

# rationale 転記圧縮時の主張スコープ量化拡大（この箇所→全体への過大一般化）

## 概要

rationale（設計理由・背景解説）を SKILL.md 本体から references/ へ退避するコンテキストダイエット型 refactor では、転記時の文章圧縮によって主張の量化スコープが改変される系統的エラーが発生する。「本 PR 内の特定 emit の規約」が「fix.md 全体の規約」へ、「inline 実行可能コードとして配置」が「各 bash block 冒頭に配置」へと過大一般化され、実態（stdout emit 10 箇所 / entry block 単一配置）と矛盾する記述が残る。転記忠実性の検証は「行の有無」だけでなく「主張の量化スコープ」も観点に含める必要がある。

## 詳細

### 観測

review/fix SKILL.md（各 4,040 行）の rationale を references へ退避するコンテキストダイエット PR で、同一クラスの指摘が場所を変えて 2 回発生した:

- **F-01 (cycle 1, SKILL.md 本体)**: `fix/SKILL.md:297` のコメント転記で「本 PR 内の特定 emit の規約」を「fix.md 全体の [CONTEXT] emit 規約」に一般化。実態の stdout emit 10 箇所と矛盾（MEDIUM）。
- **F-02 (cycle 2, references 側)**: `design-rationale.md:44` への転記で「inline 実行可能コードとして配置」→「**各 bash block 冒頭**に配置」とスコープ拡大。実際は entry block のみの単一配置と矛盾（MEDIUM、code-quality と error-handling が独立検出 = 高確度 cross-validation）。
- **cycle 3**: 全レビュアー指摘 0 件で mergeable 収束。同一クラスの指摘が場所を変えて出現したが発散はしなかった（cycle 1: 本体 1 件 → cycle 2: references 1 件 → cycle 3: 0 件）。

### 失敗 mode

1. rationale を退避先へ転記する際、文章を圧縮・言い換えする
2. 圧縮の過程で限定列挙（「この箇所」「entry block のみ」）が量化表現（「全体」「各箇所」「すべて」）へ滑り、書き手は矛盾に気づかない
3. SKILL.md 本体側の転記だけ検証し、references 側の転記文が同じ観点で未検証のまま残る（F-01 修正後に F-02 が同クラスで発生）

### 修正 canonical（fix 側で実証済み）

- **量化スコープの保存**: 過大一般化されたコメントを「限定列挙 + 例外系統の明示」に復元する（例: retained flag / 引数 parse 系は stderr、WT_ENSURE / ROOT_CAUSE_GATE / WIKI_INGEST_* 等の status emit は stdout で別系統）
- **量化表現の機械的疑義**: 転記文中の「各 / 全体 / すべて」を grep で洗い出し、実配置（単一 or 複数）と突合する
- **両側検証**: 退避後は SKILL.md 本体だけでなく references 側の転記文も同じ観点で検証する（F-02 の教訓）
- **AC-2 (bash 非コメント行不変) との両立**: 修正はコメント/散文 1 行のみで bash 実行内容不変を維持し、impact scan で同種パターンの他所出現・references への誤転記なしを確認してから適用する。伝播スキャン + references 側検証を fix 手順に含めたことで cycle 3 での新規発生ゼロにつながった

### 周辺観測（別 Issue 候補として記録）

- `[CONTEXT]` emit には stderr 系（retained failure flag）と stdout 系（後続 phase への値受け渡し: WIKI_INGEST_* / ROOT_CAUSE_GATE 等）の 2 系統が事実上存在するが規約として未文書化（pre-existing）
- コメント形式の `rationale: references/<file>.md#<anchor>` ポインタは drift-check Pattern 4（anchor drift）の機械検証対象外で、references 見出しリネームによる silent デッドポインタ化リスクがある

## 関連ページ

- 新設要約文の「N 個の~系統」的な断定は対象外の類似構造を見落としやすい (`Wiki provenance: ./unscoped-enumeration-claim-in-new-summary.md`)
- Scope drift fix での overclaim substitution (置換後に新たな過剰主張を持ち込む) (`Wiki provenance: ./scope-drift-fix-overclaim-substitution.md`)
- 圧縮 refactor の AC は protected 区域 + scope 制約から逆算して決める (`Wiki provenance: ../heuristics/compression-refactor-ac-vs-structural-constraint.md`)

## ソース

- PR #1774 review results (`Wiki provenance: ../../raw/reviews/20260707T005014Z-pr-1774.md`)
- PR #1774 fix results (`Wiki provenance: ../../raw/fixes/20260707T005536Z-pr-1774.md`)
- PR #1774 review results (cycle 2) (`Wiki provenance: ../../raw/reviews/20260707T011246Z-pr-1774.md`)
- PR #1774 fix results (cycle 2) (`Wiki provenance: ../../raw/fixes/20260707T011502Z-pr-1774.md`)
- PR #1774 review results (cycle 3 mergeable) (`Wiki provenance: ../../raw/reviews/20260707T012957Z-pr-1774.md`)
