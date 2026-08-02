---
title: "累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable"
domain: "heuristics"
created: "2026-05-17T13:40:00Z"
updated: "2026-08-02T22:05:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T000641Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T202243Z-pr-2070.md"
  - type: "reviews"
    ref: "raw/reviews/20260723T040300Z-pr-1974-cycle4-final.md"
  - type: "reviews"
    ref: "raw/reviews/20260521T083746Z-pr-1078.md"
  - type: "fixes"
    ref: "raw/fixes/20260521T073426Z-pr-1078.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T164439Z-pr-1064-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260518T165729Z-pr-1049-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T223309Z-pr-1032.md"
  - type: "retrospectives"
    ref: "raw/retrospectives/20260517T133937Z-pr-1011-retro.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T133901Z-pr-1011-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T133937Z-pr-1011-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T161411Z-pr-1151.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T160217Z-pr-1151.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T063747Z-pr-1969.md"
  - type: "fixes"
    ref: "raw/fixes/20260722T064426Z-pr-1969.md"
  - type: "reviews"
    ref: "raw/reviews/20260722T080039Z-pr-1969-mergeable.md"  - type: "reviews"
    ref: "raw/reviews/20260727T001018Z-pr-2035.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T014642Z-pr-2035.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T045143Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T094749Z-pr-2044.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T045549Z-pr-2044.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T155350Z-pr-2051-c4.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T153523Z-pr-2051-c3.md"
  - type: "reviews"
    ref: "raw/reviews/20260729T150808Z-pr-2051-c2.md"
  - type: "fixes"
    ref: "raw/fixes/20260729T153947Z-pr-2051-c3.md"
  - type: "reviews"
    ref: "raw/reviews/20260802T114732Z-pr-2052.md"
tags: []
confidence: high
---

# 累積対策 PR の 3 cycle 収束記録: cross-validation boost + cycle 2 minor drift + cycle 3 mergeable

## 概要

cycle 2 の LOW follow-up として起票された PR は、3 cycle で 0 findings に収束した実例。cycle 1 で code-quality MEDIUM + security LOW の 2 reviewer 独立指摘が Phase 5.2 cross-validation で HIGH に boost、cycle 1 fix 自体が新たな minor inaccuracy を導入 (Wiki 経験則「fix-induced regression」の再現)、cycle 2 で 2 階層構造に書き直し、cycle 3 で 3 reviewer マージ可。

## 詳細

### Cycle 1: cross-validation severity boost が正しく機能

- **対象**: `pre-tool-bash-guard.sh:315` のコメント論拠 (cycle 2 で追加した「(A)〜(G) deny case-glob は trailing space 必須」)
- **指摘**: code-quality MEDIUM + security LOW が同じ箇所のコメント論拠不整合を独立に指摘
- **boost**: Phase 5.2 cross-validation で 2 reviewer 合意 → MEDIUM の 1 段階上 HIGH に severity boost
- **意義**: 単独 reviewer なら LOW で informational に降格される finding が、複数 reviewer の独立検証で blocking 化される実例

### Cycle 2: fix-induced regression の典型

- **fix**: cycle 1 fix で (A)/(B)-(G) サブブロック別の説明に書き直した
- **新たな drift**: 「(B)-(G) は trailing space 省略」と一括説明したが、(G) branch は短形式 (`-D` 等は trailing space あり) と long-form (`--delete` は省略) の混在、(E) worktree は case-glob (省略) と token-loop precondition (必須) の混在 → 実装と乖離
- **検出**: code-quality reviewer が LOW finding として検出 (Likelihood-Evidence anchor で実装の line 569-575 + 576-582 直接照合、Python trace で false positive 検証)
- **Phase 5.3.0 Post-Reviewer Safety Net**: Likelihood-Evidence anchor 完備のため降格対象外、formal finding として残った

### Cycle 3: 2 階層構造で収束

- **fix**: 「主要因 (全サブブロック共通: path 由来トークンは ` git/<X>` 形となり前 boundary が崩れて連続 token `git <verb>` に到達しない) + 補強要因 (サブブロック別 trailing space)」の 2 階層構造に書き直し
- **検証**: 3 reviewer (prompt-engineer + code-quality + security) すべて 0 findings、マージ可判定
- **収束条件**: cycle 3 で初めて (A)/(B)/(C)/(D)/(E case-glob)/(E token-loop)/(G 短形式)/(G long-form) の 7 形式すべてを実装と意味的に整合させた

### Patterns Reinforced

1. **Cross-validation severity boost の威力**: 単独 LOW + 単独 MEDIUM が cross-validate で HIGH に昇格して blocking 化された (Phase 5.2 ルール)
2. **fix-induced regression の段階的詳細化**: cycle 1 → cycle 2 → cycle 3 で「一括説明 → サブブロック別 → 2 階層 (主要因/補強要因)」と段階的に正確化された (最初から 2 階層で書いていれば cycle 2 を skip できた可能性)
3. **Likelihood-Evidence anchor の重要性**: cycle 2 LOW finding は anchor 完備のため Phase 5.3.0 で降格されず blocking 維持された
4. **3 reviewer 並列レビューが accumulated PR で正しく機能**: prompt-engineer + code-quality + security の組み合わせが多角的に検証

### Anti-Patterns Avoided

- **silent skip**: Wiki ingest 経路の auto_ingest 判定で bash パース bug により silent skip が発生 (本セッションで後追い手動 ingest として記録)。本来は Phase 6.5.W / 4.6.W で自動 ingest されるべき経路

### bash semantics 版 3-cycle 連鎖収束の実証

当該 PR (`plugins/rite/commands/pr/fix.md` L797-L802 の `mktemp_failure_find_err` 経路 SoT 同期 refactor) は、前項の 3-cycle 収束パターンの **bash semantics 版** 連続再現事例。各 cycle で異なる drift class が surface し cycle 4 で 0 findings に到達:

- **Cycle 1 (CRITICAL — bash 言語仕様罠)**: format 同期目的の SoT-aligned refactor で `if ! cmd; then rc=$?` 形式を新規導入し bash `!` 演算子の boolean 反転による rc 常時 0 化 silent regression。reviewer 2 名 cross-validation 一致検出
- **Cycle 2 (MEDIUM + LOW — fix-introduced regression)**: cycle 1 fix が hardcoded line-number reference (`L1147-L1150`) を comment に埋め込み SoT 実位置 (L1122-L1156) と乖離 + L799 mktemp の `2>/dev/null` 欠落で 24/25 サイト対称化漏れ
- **Cycle 3 (MEDIUM — numeric counter drift の先回り対応)**: cycle 2 fix の semantic anchor 化宣言と同時に新規導入された numeric counter (`fix.md 内 24/25 site と pattern 一致`) を本 fix で先回りで相対 semantic 表現に置換 (cycle 4 で MEDIUM として再検出される経路を予測対応)
- **Cycle 4 (mergeable — 0 findings)**: 両 reviewer (prompt-engineer / code-quality) 独立 0 findings 評価、3-cycle 収束完了

**起点事例との対比による新観点**:

1. **drift class が cycle ごとに異なる shrinking pattern**: 起点事例は同一 class (cycle 1 / 2 とも「サブブロック別 trailing space 説明の精密化」) の段階的詳細化で収束したが、bash semantics 版は **cycle ごとに異なる drift class** (cycle 1: bash 言語仕様 → cycle 2: documentation pointer → cycle 3: numeric counter) が連続発火。それでも **shrinking cycle count (3 findings → 2 findings → 1 finding → 0 findings)** で 4 cycle で収束する empirical 規則が成立。
2. **3-cycle 連鎖は drift class 横断でも 4 cycle 内で完結する**: cycle ごとに drift class を semantic anchor に置換していくことで、各 cycle で発火する drift class が異なっても shrinking cycle で収束。「recursive recurrence in fix layer」の発火上限は **3 cycle 連鎖 + cycle 4 で 0 findings 期待** が 2 連続で再現された empirical evidence。
3. **format 同期 refactor の小規模 PR でも 3-cycle 連鎖が発火する**: 起点事例は 7 形式 (A/B/C/D/E case-glob/E token-loop/G 短形式/G long-form) の対称性を扱う中規模 PR だったが、bash semantics 版は **6 行の bash block を新 SoT 形式に refactor する小規模 PR** でも同型の 3-cycle 連鎖が発火することを示した。これは「PR の規模ではなく **新 SoT との対称化責務の層数** (本 PR では format token / bash structure / runtime semantics の 3 層) が 3-cycle 連鎖の発火条件である」観点を支持する。
4. **「累積対策 PR の 3-cycle 収束記録」pattern の reproducibility は 2 PR 連続で確立**: 起点事例 (heuristics 経験則の起点) → bash semantics 版 (連続再現事例) として、本 heuristics 経験則は 2 PR 連続で再現された。bash semantics layer まで含む drift class 横断の 3-cycle 連鎖でも 4 cycle で収束する empirical pattern が、`fix-induced-drift-in-cumulative-defense.md` と本ページの両方で観測されている。

### 1-cycle convergence の下限事例

1-cycle 下限事例 (`_test-helpers.sh` への新規 `assert_grep_in_section` helper 追加 + T-2/T-3/T-4 caller test 3 ファイルの API 移行) は、本ページが記録してきた 3-cycle 収束 pattern の **対比となる下限事例** として位置付けられる。cycle 1 で 3 reviewer 独立合意 HIGH を含む 3 finding 検出 → cycle 1 fix で structural resolution → cycle 2 で 0 finding mergeable に到達する **1-cycle convergence (cycle 0 を含めて 2 cycle で完結)** を実測:

- **Cycle 1 (HIGH × 1 cross-validated, MEDIUM × 1, LOW × 1)**: test / code-quality / error-handling の 3 reviewer 並列レビューで HIGH (helper file 内 test coverage 対称性欠落) を独立 grep evidence 付きで cross-validated detection。MEDIUM (awk silent swallow による 5 failure mode 混同) と LOW (docstring-実装 drift) も並行発火。
- **Cycle 1 fix (3 finding 全件 structural fix)**: TC-12 self-test 追加で sibling helper 群との対称性回復、`if !` awk wrap + stderr tempfile + `[ ! -s ]` 空 section guard の 3 点セットで 5 failure mode 区別、docstring を実装と byte 同期。
- **Cycle 2 re-review (0 finding mergeable)**: 同じ 3 reviewer 並列 re-review で全件 FIXED 判定、推奨事項 3 件 (boundary 2 + actionable 1) はすべて scope 外として user 取り下げ、cross-validated CRITICAL/HIGH/MEDIUM 0 件で 1 cycle 収束。

**起点事例 / bash semantics 版との対比による新観点**:

1. **shrinking cycle count の下限は 1 cycle convergence (cycle 0 含め 2 cycle)** — 累積対策 PR の 3-cycle 連鎖が「上限」だとすると、本事例は対極の「下限」として 1-cycle 収束を実測。**収束 cycle 数は (a) 問題の structural clarity、(b) cycle 1 fix の semantic 完全性、(c) reviewer cross-validation の depth の 3 因子で決まる** 観点を支持。本事例は (a) helper test coverage 対称性が grep evidence で 1 trigger で structurally clear に成立、(b) cycle 1 fix が 3 reviewer 全指摘を semantic anchor 化で一括解消、(c) 3 reviewer 並列レビューで cross-validation depth 最大 — の 3 因子がすべて揃った。
2. **「fix-induced regression が発火しない条件」の輪郭** — 起点事例 / bash semantics 版では cycle 1 fix が新規 drift を導入したが、本事例では cycle 1 fix が新規 drift を introduce せずに直接 mergeable に到達。違いは「fix が structural anchor (TC-12 self-test、3 点セット) を新規確立する形態」であることで、fix-induced regression は **「format 同期 / 列挙対称化 / hardcoded reference 書き換え」など precedent-following 形態** の fix で発火率が高く、**「新規 contract 確立」形態** の fix では発火率が低い、という pattern 仮説を提示。
3. **3 reviewer 並列レビュー × 1 cycle 収束の reproducibility 候補** — 累積 30 回目（4 reviewer 全員 0 finding・1 cycle merge）と本事例 (3 reviewer 並列で HIGH cross-validated → 1 cycle 構造的解消) が **「複数 reviewer 並列レビューが initial detection の完全性を上げ、fix の structural anchor 確立を促進する」** 共通 mechanism を示唆。3-cycle 連鎖の前提となる「cycle 1 fix の不完全性」が、reviewer cross-validation depth で抑制される経路を支持する empirical evidence。
4. **Reviewer 自身による FIXED verification の standard pattern** — error-handling reviewer が cycle 1 で MEDIUM (awk silent swallow) を指摘し、cycle 2 で同 reviewer 自身が「5 failure mode を診断レベルで区別可能化された」と FIXED verification するパターンは、`fix-verification-requires-natural-workflow-firing.md` の reviewer ownership pattern と整合。「指摘した reviewer が次サイクルで verify する」契約は、本事例のような 1-cycle 収束 PR でも standard pattern として再現されることを実測。

### 14 → 0/1-nit-noted への mass batch fix 1-cycle convergence

mass batch fix 事例 (`migrate-review-state-to-1.1.sh` + `review-schema-version-check.sh` + `scope-enum-check.test.sh` の 3 artifacts 追加 + `distributed-fix-drift-check.sh` への Pattern 6 統合) は、本ページが記録してきた 1-cycle convergence pattern の **mass batch fix 版**。cycle 1 で 4 reviewer 並列レビューにより 14 findings (CRITICAL × 2 / HIGH × 4 / MEDIUM × 6 / LOW × 2) が検出され、cycle 1 fix で 14 件全件を一括 structural fix → cycle 2 re-review で 1-nit-noted (LOW-MEDIUM、scope=`nit-noted` で non-blocking) + 2 recommendations のみという 1-cycle 収束を実測:

- **Cycle 1 (14 findings)**: code-quality / error-handling / test / security の 4 reviewer 並列レビュー。CRITICAL × 2 は spec-vs-spec 矛盾 (Issue body vs schema doc canonical の `pre_existing` フィールド取扱い) + `mktemp` failure 時の silent regression。HIGH × 4 は signal trap pattern (INT/TERM/HUP) の覆損 + `_helpers_resolve_repo_root` helper non-use + `set -e / set -uo pipefail` 不整合 + 3-emit DRY violation。MEDIUM × 6 は test-quality (mktemp safety / negative case / cleanup / helpers / stderr capture) と Single-invocation refactor (delegate を 2 回呼ぶ pattern)。
- **Cycle 1 fix (14 件全件 structural fix)**: spec-vs-spec は schema doc canonical 優先で `pre_existing` 削除 (参照: `[[spec-vs-spec-canonical-priority]]`)。Test-quality 6 件は一括 batch resolution。DRY refactor で 3-emit pattern を helper 1 つに集約。Signal trap は INT/TERM/HUP の 4 行 trap で orphan tempfile leak を防止。
- **Cycle 2 re-review (1-nit-noted + 2 recommendations)**: 同 4 reviewer マージ可判定。残った LOW-MEDIUM (1 件) は `_orphan_tmps` 空配列 expansion (cleanup guard で masked 済みのため non-blocking、scope=`nit-noted` の M5 受け流し経路で対応)。2 recommendations は design_confirmation + boundary (defense-in-depth pattern 助言、scope 外)。

**起点事例 / bash semantics 版 / 1-cycle 下限事例との対比による新観点**:

1. **mass batch fix における 1-cycle convergence の reproducibility**: 1-cycle 下限事例 (3 findings) が下限だったのに対し、本事例 (14 findings) は **mass batch fix でも 1-cycle 収束が成立する** 上限事例。14 件の独立 findings が単一 cycle で structural fix されたのは、各 finding が独立した structural anchor (test mktemp pattern / signal trap pattern / DRY helper / single-invocation pattern) で解消可能な分割可能性を持っていたため。
2. **4 reviewer 並列レビュー × cross-validation の cumulative effect**: code-quality / error-handling / test / security の 4 reviewer 並列構成は累積 30 回目 (4 reviewer 全員 0 finding 1-cycle merge) の構成と同じ。本 PR では initial detection で 14 finding を発掘 (大量) → fix の structural anchor 確立で 1-cycle 収束、という pattern を再現。**reviewer 数の増加は initial detection の completeness を向上させ、fix の structural anchor 化を促進する** という仮説を強化。
3. **scope=`nit-noted` の M5 受け流し経路が初めて real-world で発火**: cycle 2 で残った LOW-MEDIUM 1 件は `nit-noted` scope 割当て + `accept (認知のみ)` 選択で revocable に accept 永続化されることが期待される (Phase 2.1.A fingerprint suppression、本 Epic の M5 設計)。本 PR はこの経路が初めて real-world cycle で発火するエッジ事例。
4. **`spec-vs-spec-canonical-priority` heuristic との連動**: 本 PR cycle 1 の CRITICAL × 1 (Issue body vs schema doc canonical) は `[[spec-vs-spec-canonical-priority]]` の origin 事例。本ページは convergence pattern (cycle 数の reproducibility)、対称ページは canonical priority resolution の意思決定原則 — 同一 PR から相補的な 2 つの heuristic が抽出されたことは Wiki 経験則の coverage が深化している evidence。

### 5-cycle shrinking convergence with reviewer disagreement resolution

5-cycle 事例 (`start-execute.md` / `checklist-auto-check.md` / `cleanup.md` の 3 site に threshold=5 mass-residual warning + workflow_incident emit を導入) は、本ページが記録してきた 3-cycle / 1-cycle convergence pattern の **5-cycle 拡張版**。13 findings を **8 → 3 → 2 → 1 → 0** の完全 shrinking trajectory で 5 cycle 収束:

- **Cycle 1 (8 findings: 1 CRITICAL / 3 HIGH / 2 MEDIUM / 1 LOW / 1 follow-up)**: prompt-engineer + code-quality 2 reviewer。CRITICAL は Phase 5.4.4.1 detector 不在主張 prose の誤記、HIGH ×3 は Simplification Charter Issue #N 引用残存 (cross-validated)、printf vs echo 非対称、Step 0 → AskUserQuestion silent fall-through、MEDIUM ×2 は reminder 冗長性 + empty-body guard 欠落、LOW ×1 placeholder hint
- **Cycle 2 (3 LOW)**: cycle 1 fix が phase number 表記 drift (`Phase 5.2.1` vs `5.2.1.1`) と caller list 表記揺れを導入 (Wiki 経験則「recursive recurrence in fix layer」の発火)。3 sites L295/L309/L317 中 1 site のみ訂正で 2 sites 取り残し
- **Cycle 3 (2 LOW)**: cycle 2 fix が L309 のみ訂正、対称位置 L295/L317 を見落とし (`Asymmetric Fix Transcription` の発火)
- **Cycle 4 (1 LOW + reviewer disagreement, Quality Signal 3)**: cycle 3 fix で L295/L317 訂正後、code-quality は「L309 vs L317 の `5.2.1` (umbrella) vs `5.2.1.1` (sub-phase) は意図的使い分け」と承認、prompt-engineer は「L309/L317 一致性のため両方 5.2.1.1 にすべき」と主張。コミット者は後者採用
- **Cycle 5 (0 findings mergeable)**: 両 reviewer 独立承認、5-cycle で完全収束

**起点事例 / bash semantics 版 / 1-cycle 下限事例 / mass batch fix 事例との対比による新観点**:

1. **5-cycle convergence は 3-cycle 連鎖 + 2 cycle 拡張で成立する**: 起点事例 (3 cycle) / bash semantics 版 (4 cycle) が「上限」とされていたが、本 PR は drift class が cycle ごとに細粒度化する経路 (phase number umbrella vs sub-phase の 3 site 対称化が cycle 2/3/4 で順次 surface) で **5 cycle に拡張** された。`recursive recurrence in fix layer` の発火上限は drift class の **layer 数** (本 PR では 3 site × 2 layer = 6 sub-drift) で決まる empirical 観点を支持
2. **Reviewer disagreement (Quality Signal 3) が legitimate な合意形成 path として機能**: cycle 4 の reviewer disagreement は debate phase 未起動でコミット者判断による 1 reviewer 採用 → cycle 5 で両 reviewer 承認という解決経路を辿った。`umbrella vs sub-phase 使い分け` という設計レベルの argument は debate よりも実装による証明 (cycle 5 で両 reviewer 承認) のほうが効率的という観察
3. **Shrinking trajectory 8 → 3 → 2 → 1 → 0 は initial detection completeness の指標**: cycle 1 で 8 findings 検出は 2 reviewer 並列の最大検出力。各 cycle で半減未満 (8→3 で 5/8 削減、3→2 で 2/3 維持、2→1 で 1/2 削減) のシリアル shrinking は、各 cycle fix が partial structural anchor 化 (`Asymmetric Fix Transcription` の sub-pattern 段階解消) を意味する
4. **Wiki 経験則の自己実証**: 本 PR の review-fix loop 自体が `accumulated-pr-three-cycle-convergence` / `asymmetric-fix-transcription` / `fix-induced-drift-in-cumulative-defense` / `phase-number-structural-symmetry` の 4 既存 Wiki 経験則の **実測再現**。Wiki 経験則がワークフロー自身の品質改善に feed back する self-reinforcing loop が cycle 5 で完結

### 大規模 rename PR の 4-cycle 累積収束 + tail residue pattern

大規模 rename 事例 (`wiki/*` commands の `Phase N` → `ステップ N` heading rename、16 files / +484/-484) は、本ページが記録してきた累積収束 pattern の **大規模 rename PR 版**。18 findings を **18 → 3 → 2 → 0** の 4 cycle shrinking trajectory で収束:

- **Cycle 1 (18 findings: 14 HIGH / 4 MEDIUM)**: 3 reviewer (prompt-engineer / code-quality / tech-writer) 並列。Asymmetric Fix Transcription anti-pattern の自己違反 (cleanup-wiki-ingest-turn-boundary.md で 8 件中 1 件のみ rename)、callee → caller 片方向 over-translation (3 callers 参照 in SKILL.md + bash-cross-boundary 2 sites + ingest.md L9)、AC verification grep の盲点 (`Phase [0-9]+` で bare prose 13+ 件残留)、canonical regex silent coverage loss (backlink-format-check.sh:191) の 4 大 finding pattern
- **Cycle 2 (3 findings: 2 MEDIUM + 1 LOW-MEDIUM)**: cycle 1 fix の scan scope が non-systematic だったため `wiki/query.md` 9 sites + `wiki/lint.md:1406` 1 site の over-translation 取りこぼし。F-21 は archive doc front-matter declaration を尊重する逆方向 revert (cycle 1 F-14 fix を撤回)
- **Cycle 3 (2 HIGH: cross-validation で 1 件 MEDIUM→HIGH boost)**: cycle 2 で 6 件 revert したが、隣接行 2 件 (L26 `wiki/lint.md ステップ 9.2` + L35 `ingest.md ... ステップ 8`) の tail residue。L35 は同 doc L114 `Phase 8` と intra-document contradiction を形成
- **Cycle 4 (0 findings, mergeable)**: 3 reviewer 全員「評価: 可」「指摘事項なし」、4 cycle 完全収束

**起点事例 / bash semantics 版 / 1-cycle 下限事例 / mass batch fix 事例 / 5-cycle 事例との対比による新観点**:

1. **rename PR は drift class の分散度合いが特殊**: 通常の累積対策 PR は単一 SoT との対称化責務 (format token / bash structure 等) の層数で cycle 数が決まるが、rename PR は **同 file 内の類似 violation の分散度合い** で cycle 数が決まる。本 PR では archive doc 1 file 内に 8 件の同型 violation が散在し、cycle ごとに 1-2 件単位の tail residue が surface する `tail-end pattern` を実証
2. **AC verification grep の narrow pattern 盲点が cycle 数を伸ばす**: AC を `Phase [0-9]+(\.[0-9]+)?` で定義したことで、bare prose / 表ヘッダ / 命名規約 prose の 13+ 件残留が cycle 0 で検出できず cycle 1 で初めて発火。**AC を word boundary (`Phase\b`) で再定義すれば cycle 1 finding 数を 18 → 5 程度に圧縮できた可能性**（fix cycle 1 から導出された hint）
3. **archive doc の front-matter policy violation が cycle 1↔2 revert を発生させる**: cycle 1 fix で over-translation → cycle 2 で F-21 revert → cycle 3 で revert 漏れ tail residue という往復が発生。**reviewer 間で document classification (archive vs current) の認識を共有する仕組み** がないと、同一 file の同一行が cycle を往復する経路を生む (詳細は [Archive doc の front-matter で宣言した preservation policy を body 編集が無視して矛盾を生む](../anti-patterns/archive-doc-frontmatter-policy-violation.md) 参照)
4. **大規模 rename PR の収束式は `cycle_count ≈ 1 + ⌈log2(tail_residue_density)⌉`**: 本 PR では同 file 内に 8 件分散 → cycle 1 で 6 件 fix → 2 件 tail residue → cycle 2 で 1 件 → cycle 3 で残 1 件、と log2 オーダーで shrinking。経験則として、rename PR の cycle 1 完了時点で **同 file 内の全 `(Phase|ステップ) [0-9]` を pre-fix scan + audit** を導入すれば 4 cycle → 2 cycle に圧縮できる可能性

### CRITICAL 1 件の共有リソース契約違反から始まる 4-cycle 収束

共有リソース契約違反事例（sandbox 環境での worktree 削除失敗時の自動回収ギャップ解消）は、CRITICAL 1 件（既存共有リソースの type 名前空間を新機能で再利用し既存消費者の契約を見落とす回帰、[[shared-resource-type-reuse-without-consumer-contract-check]] 参照）を起点に、4 cycle で段階的に収束した事例:

- **Cycle 1 (CRITICAL × 1)**: error-handling reviewer の実機再現と prompt-engineer reviewer の文書整合性チェックという異なるアプローチが同一根本原因に収束し高確信度で確定。cycle 1 fix で専用 type 新設による安全な分離を実施
- **Cycle 2 (MEDIUM × 3)**: cycle 1 修正自体に対し、test / prompt-engineer reviewer が独立に「ドキュメント精度（3 ファイル複製コメントの虚偽記述）」と「producer 側テストカバレッジ欠如（[[mutation-testing-test-fidelity]] 適用 30）」という異なる観点で追加指摘。mutation test の継続適用が両指摘の実証に寄与
- **Cycle 3 (MEDIUM/HIGH 混在)**: application / error-handling reviewer が独立に、cycle 1-2 で新設したテストヘルパーの awk flip-flop レンジが start pattern の曖昧性で過検出することを発見（[[awk-flip-flop-range-start-pattern-anchoring]] 参照）。同時に prompt-engineer reviewer がテストコメント中の no_journal_comment 原則違反を検出
- **Cycle 4 (0 findings, mergeable)**: 5 reviewer（security / application / error-handling / test / prompt-engineer）全員が 0 findings で合意。boundary 分類の非ブロッキング推奨事項 6 件は「本 PR のスコープ外」「既存パターンとの一貫性」を理由に修正不要と判断され、Decision Log への記録に留めた

**他の累積収束事例との対比**: CRITICAL 1 件を起点に、各 cycle で異なる検出アプローチ（実機再現 / 文書整合性 / mutation testing）が異なる drift class（契約見落とし → ドキュメント精度・テストカバレッジ → テストヘルパー自体の過検出）を段階的に発掘する構造は、bash semantics 版の「drift class が cycle ごとに異なる shrinking pattern」と同型。加えて本 PR は、review-fix loop の中で新設したテストヘルパー自身の検証ロジック（awk flip-flop レンジ）にバグが混入し、そのバグを後続 cycle の reviewer が独立検出する **「対策コード自身が新たな精査対象になる」自己言及的パターン**を実証した。

### 5 cycle 収束の推移 (2026-07-27)

3 cycle で収束しない場合の推移パターンとして、データ契約を additive に追加した PR (Sub-A) の 5 cycle を記録する。findings 12 → 10 → 10 → 7 → 2（最後の 2 件は両方 nit-noted）:

| cycle | 件数 | 指摘の性質 |
|---|---|---|
| 1 | 12 (HIGH 3) | 実装の根拠記述が実態とずれている / 順序契約の pin 欠落 / 未配線を現在形で断定 |
| 2 | 10 (HIGH 3) | cycle 1 の修正が「対になる側」を取りこぼした（tempfile の cleanup 登録、限定句を入れる箇所、上流の Placement） |
| 3 | 10 (HIGH 0) | pin の片側性と positive control の欠如、rationale の事実誤認 |
| 4 | 7 (HIGH 0) | 既存構造の前提を確認せず要素を足した（fence 反転、未実測の実測手順） |
| 5 | 2 (すべて nit-noted) | 収束 |

**cycle 2 以降の指摘は実装バグではなく「記述の不整合」と「pin の精度」に移る**。cycle 1 の HIGH が実装の根拠記述、cycle 2 が対称性の取りこぼし、cycle 3 が pin 設計、cycle 4 が既存構造の前提確認と、階層が上がっていく。

**収束を早められたポイント（cycle 5 の振り返り）**:

1. **cycle 1 の時点で対称性チェックを明示的に回す** — P0/P2、write/read、実装/ドキュメントのように対になる構造では、片方に足したら必ずもう片方を見る。cycle 2 と cycle 3 の指摘の大半はこれで防げた
2. **pin を足したらその場で mutation を当てる** — Issue に明記されていたにもかかわらず、cycle ごとに「当てていない軸」が発見された（配置 → 上側境界 → 片側性 → positive control）
3. **段階分割 PR では時制が最大の落とし穴** — cycle 1〜3 の HIGH 指摘の半分がこの型で、「1 箇所直して他を放置」を 2 度繰り返した
4. **レンダリング結果を見ないと分からない欠陥は 4 cycle 生き残る** — fence 入れ子による code/prose 反転はテキストとして読む限り気付けない

## 関連ページ

- [Spec-vs-spec 矛盾は canonical SoT 表記のある側を優先する](../heuristics/spec-vs-spec-canonical-priority.md)
- [Fix verification requires natural workflow firing](../heuristics/fix-verification-requires-natural-workflow-firing.md)

## ソース

- [PR #1011 3-cycle convergence retrospective](../../raw/retrospectives/20260517T133937Z-pr-1011-retro.md)
- [PR #1011 cycle 1 review (1 HIGH cross-validated)](../../raw/reviews/20260517T133901Z-pr-1011-cycle-1.md)
- [PR #1011 cycle 2 review (1 LOW + 1 informational)](../../raw/reviews/20260517T133937Z-pr-1011-cycle-2.md)
- [PR #1032 cycle 4 review (mergeable — bash semantics 版 3-cycle 連鎖収束、cycle 4 で両 reviewer 0 findings 合意、drift class 横断 (bash 言語仕様 → documentation pointer → numeric counter) でも 4 cycle で収束する 2 連続再現事例)](../../raw/reviews/20260517T223309Z-pr-1032.md)
- [PR #1049 cycle 2 re-review (mergeable — 1-cycle convergence の下限事例、3 reviewer 並列レビューで HIGH cross-validated → cycle 1 fix で structural resolution → cycle 2 で 0 finding mergeable。3-cycle 連鎖の対極として 1-cycle 収束が成立する 3 条件 (structural clarity / cycle 1 fix semantic 完全性 / reviewer cross-validation depth) を実測)](../../raw/reviews/20260518T165729Z-pr-1049-cycle2.md)
- [PR #1064 cycle 2 re-review (mergeable — 14-finding mass batch fix の 1-cycle convergence 上限事例、4 reviewer 並列で 14 findings → cycle 1 一括 structural fix → cycle 2 で 1-nit-noted（M5 受け流し経路） + 2 recommendations のみ。`spec-vs-spec-canonical-priority` heuristic の origin 事例と連動)](../../raw/reviews/20260519T164439Z-pr-1064-cycle2.md)
- [PR #1078 cycle 5 mergeable (5-cycle shrinking convergence、13 findings を 8→3→2→1→0 で収束、cycle 4 reviewer disagreement (Quality Signal 3) を実装による合意形成で解消、Wiki 経験則 4 件の self-reinforcing 実測再現)](../../raw/reviews/20260521T083746Z-pr-1078.md)
- [PR #1078 cycle 1 fix patterns (累積 13 findings の 7 件 batch fix、cycle 1 で Simplification Charter cross-validated 違反検出、printf vs echo 同一 SoT 内 style consistency、Step 0 → AskUserQuestion silent fall-through 防止 MUST 句強化、Phase 5.4.4.1 detector 不在主張の prose 誤記訂正の 4 fix pattern)](../../raw/fixes/20260521T073426Z-pr-1078.md)
- [PR #1151 cycle 4 mergeable (大規模 rename PR の 4-cycle 累積収束、18→3→2→0 trajectory、archive doc tail residue pattern + intra-document contradiction の実測)](../../raw/reviews/20260526T161411Z-pr-1151.md)
- [PR #1151 cycle 3 fix (archive doc 2 箇所最終 revert、front-matter policy preservation 軸の cycle 1↔2↔3 往復解消)](../../raw/fixes/20260526T160217Z-pr-1151.md)
- [PR #1969 cycle 4 review (5-cycle 収束の中間、findings が実装ロジックからテスト scaffolding/文書精度へシフトする finding-cycling を観測)](../../raw/reviews/20260722T063747Z-pr-1969.md)
- [PR #1969 cycle 4 fix (pass-message narrowing + gitignore 保証の self-contained 化、収束後半典型の surgical fix 2 件)](../../raw/fixes/20260722T064426Z-pr-1969.md)
- [PR #1969 cycle 6/mergeable review (5-cycle shrinking 4→4→1→2→1→0 で 0 findings 到達、cycle 5 の brace group finding が正しく解消されたことを確認)](../../raw/reviews/20260722T080039Z-pr-1969-mergeable.md)
- [PR #1974 cycle 4 review (5 reviewer 全員 0 findings、CRITICAL 1 → MEDIUM/HIGH 7 の 4-cycle 収束、boundary 推奨事項 6 件は Decision Log 記録のみ)](../../raw/reviews/20260723T040300Z-pr-1974-cycle4-final.md)

## 補強: 収束は「件数」ではなく「指摘が移った層」で読む

層シフト事例では blocking 件数が cycle 1→2→3 で 2→3→3 と**減らなかった**が、指摘の性質は毎回 1 段ずつ浅くなっていた。

| cycle | 指摘の層 |
|---|---|
| 1 | marker の自己矛盾（実装の観測性） |
| 2 | 安全網の実挙動退行（実装の正しさ） |
| 3 | 散文の過大主張のみ（記述の精度、**コード指摘ゼロ**） |

> **教訓**: 収束の兆候は「指摘件数」より **「指摘がコード層から散文層へ移ったか」**で読むほうが早い。件数は増えていても層が上がっていれば収束している。

同じ PR の別レビュー系列では 3 cycle で blocking 7 → 0 へ収束し、cycle 2 の CRITICAL が「cycle 1 で直した箇所の数行下にある同型の欠陥（別記法のため grep で拾えなかった）」だった。**fix-introduced finding を attribution できると、収束していないのか掘り進んでいるのかを区別できる。**

## 補強: レビュアーの自己撤回は正常な収束の一形態

cycle 3 で 2 名のレビュアーが自分の前 cycle 指摘を**実測に基づき自ら撤回**した。error-handling reviewer は「`INC=failed` の帰結説明が実体とずれる」という cycle 2 の推奨を、書込不能環境での実測により「現行文面のほうが正確で、自分の言い換えの方が狭かった」と訂正。tech-writer も「3 経路と書くが実体 4 経路」を「第 4 の組は構造的に不能」と判明して撤回した。

> **教訓**: レビュアーが自分の過去の指摘を実測で覆せることは、**指摘の量が質を上回り始める drift への自己修正機構**として機能する。re-review で同一 reviewer に前 cycle の指摘を明示的に渡すと、この撤回が起きやすい。

## 補強: 実測必須ゲート下では severity と実測は直交する

実測必須ゲート（`Verification:` アンカーを持つ指摘のみ blocking）の運用が 3 系列・計 16 cycle で一貫して観測された。

- **HIGH かつ non-blocking は正常な組み合わせ**。ゲートは severity ではなく実測の有無で判定するため、HIGH 相当の事実誤りでも非実測なら降格される。
- ワークフロー定義 PR では「実行して観測できる欠陥」と「読解上の欠陥」が明確に分かれ、後者（retain 指示漏れ・コメント肥大・未解決の節参照）は構造的に non-blocking へ落ちる。
- 散文 PR でも実測は成立する。Markdown 内の fenced bash を `$TMPDIR` に切り出し、helper を成否切替可能な stub に差し替えて全経路を実走させる手法が複数レビュアーで再現された。**「doc の指摘は実測できない」は多くの場合思い込みで、条件を状態として再現できるかを先に問うべき**（cycle 1 で non-blocking だった指摘が、`chmod a-w` で書き込み失敗を再現したことで cycle 2 に HIGH blocking へ昇格した実例がある）。
- ただし stub は自分の理解のコピーなので、**API の default 挙動を主張の根拠にするときは stub ではなく実装を隔離環境で走らせる**。
- レビュアーが「実測を捏造して blocking にすることはしない」と明記して non-blocking に置いた例もあり、これがゲートの意図どおりの動作。ゲートが無ければその 2 件でさらに 1 cycle 回っていた。

なお **サーキットブレーカーの残 cycle は、修正の大きさを選ぶ制約条件として使える**。「直すべきか」だけでなく「今の残 cycle で検証しきれるか」で判断し、見送りは非実測記録コメントに残して追跡可能にする。

## ソース（追記分）

- [PR #2044 review results (cycle 3) — 収束は層で読む / cross-validation boost](../../raw/reviews/20260729T045143Z-pr-2044.md)
- [PR #2044 review results (cycle 3, mergeable 到達) — レビュアーの自己撤回](../../raw/reviews/20260729T094749Z-pr-2044.md)
- [PR #2044 fix results (cycle 3) — Convergence Signal](../../raw/fixes/20260729T045549Z-pr-2044.md)

## 補強: 4 cycle 収束と「0 件の質」

blocking 18 → 9 → 1 → 0 で 4 cycle 収束した記録。**収束を判定できた根拠は指摘が減ったことではなく、「0 件」の裏付けが変わったこと**だった。

cycle 4 の reviewer は揃って「これは Finding Quality Guardrail によるフィルタ結果のゼロではなく、実測に裏付けられた実質的なゼロである」と明記し、`Status: degraded` を出さなかった。同じ「指摘 0 件」でも、mutation を回したうえでの 0 件と、回さずに出した 0 件では意味が違う。**完了報告に「0 件の根拠」を書かせると、この区別が機械的に surface する**。

もう 1 つの特徴は、**cycle 2 の 9 件のうち 8 件が cycle 1 の修正によって新規に導入された**こと。累積対策 PR では「修正が新しい契約を導入し、その契約を読む側が追随していない」型が支配的になり、cycle ごとに指摘の性質が変わる。

| cycle | blocking | 指摘の性質 |
|---|---:|---|
| 1 | 18 | 元の defect class が修正コード側に再出現（検出器の rc 設計 / 恒真アサーション / 列挙の同期漏れ） |
| 2 | 9 | cycle 1 の修正が導入した新契約への追随漏れ（rc=2 の読み手 4 箇所 / mutation でのみ判明する空振り 2 件） |
| 3 | 1 | 修正の効果を固定するテストの不在（rc が同値のため rc assertion では pin できない） |
| 4 | 0 | 実測裏付きのゼロ。残ったのは実測アンカーなしの non-blocking 1 件と nit 1 件 |

**Finding Quality Guardrail を prompt で明示すると reviewer 側の自己抑制が働く**: cycle 3-4 では複数 reviewer が「新証拠なしの再掲は finding cycling にあたる」と明記して監査ログへ降格し、「防御の上に防御を積む要求」（Guardrail Category 2）に該当する候補も自ら filter した。レビュー prompt に (a) 収束状況（何 cycle 目 / 前 cycle の件数）、(b) その reviewer の前 cycle 指摘とその処置、(c) Guardrail を厳格に適用せよという指示、の 3 点を含めることが効いている。

## 補強: 収束は件数の単調減少ではなく「抽象度の階段」で起きる（5 cycle / のべ 30 レビュアー）

走査範囲を広げる helper 変更の PR が、5 サイクル・のべ 30 レビュアーで 0 件へ収束した記録。**指摘件数は単調減少しなかった（3 → 6 → 5 → 3 → 0）**が、指摘の抽象度は毎サイクル一段ずつ上がっていた。

| cycle | 件数 | 指摘が居た層 |
|---|---:|---|
| 1 | 3 | テストの厳密さ（cross-file 契約の片側 pin）+ 記述の正確さ |
| 2 | 6 | テストの厳密さ（dead assertion / 素朴 fixture）+ ドキュメントの自己矛盾 |
| 3 | 5 | ドキュメントの**正確さ**（誤った「要検証」注記）+ pin の片側性 |
| 4 | 3 | ドキュメントの**出典表記**（断定に出典・確認日が無い）+ 表の行単位 pin |
| 5 | 0 | 収束 |

**実装 → テストの厳密さ → ドキュメントの正確さ → ドキュメントの出典表記 → 0** という階段になっている。件数だけを見ると cycle 2 で悪化しているが、層はすでに上がっている。「補強: 収束は『件数』ではなく『指摘が移った層』で読む」で述べた読み方が、5 サイクルの長さでも成立した。

**特筆すべき点**:

1. **実装本体（helper のロジック）への指摘は 5 サイクルを通じて 1 件も出ていない**。指摘はすべて「実装は正しいが、その正しさを固定する仕組み（テスト・記述・出典）が片側だけ」という形だった。実装の正しさは毎サイクル、実データでの base 比較（develop 版と per-page hits がバイト一致）・契約経路の実測発火・敵対的入力・変異スイープで独立に再確認された。
2. **fix が新しい指摘を生む率は 4 サイクル連続で 20-33%**（1/4 → 1/5 → 1/3 → 0/0）。ただし **持ち込んだ欠陥の内訳は、1 件を除いてすべて「修正の中身」ではなく「修正の書き方」**だった — 常時緑の dead assertion（BRE と ERE の取り違え）/ 出典を伴わない断定 / 表の 1 行だけ pin。唯一「中身が誤り」だったのは cycle 2 の要検証注記（上流を読めば偽と分かる命題を未確認として提示した）。
3. **「修正した箇所を次サイクルの第一級レビュー対象に据える」運用が毎回機能した**。cycle 2 の最重要指摘（dead assertion）は、**前サイクルで 0 件だった reviewer が最初に見つけた**。「前回 0 件だったから今回は浅くてよい」は成立しない。
4. **最終サイクルでは掲載ゲートを厳密に適用させる**。5 名が「検討したが自問 #1（マージブロック基準）で落とした」と明記したうえで推奨事項へ降格させており、silent filter ではないことが各レポートから読み取れる。

## ソース（追記分 2）

- [PR #2051 review results (cycle 4, mergeable 到達) — 0 件の質と reviewer の自己抑制](../../raw/reviews/20260729T155350Z-pr-2051-c4.md)
- [PR #2051 review results (cycle 3) — 実測必須ゲートが記述の不整合と実行を壊す欠陥を分離した](../../raw/reviews/20260729T153523Z-pr-2051-c3.md)
- [PR #2051 review results (cycle 2) — cycle 1 の修正自体が持っていた検証の穴](../../raw/reviews/20260729T150808Z-pr-2051-c2.md)
- [PR #2051 fix results (cycle 3) — 修正が効いていることと効果が固定されていることは別](../../raw/fixes/20260729T153947Z-pr-2051-c3.md)

## ソース（追記分 3）

- [PR #2070 review results (cycle 5, mergeable) — 5 サイクル / のべ 30 レビュアーで 0 件へ収束、抽象度の階段](../../raw/reviews/20260802T000641Z-pr-2070.md)
- [PR #2070 review results (cycle 3) — fix が新指摘を生む率が 2 サイクル連続](../../raw/reviews/20260801T202243Z-pr-2070.md)

### 収束しない軌跡の記録 — blocking が 2 → 3 → 6 と増えた docs 是正 PR

これまでの事例はいずれも収束した軌跡だが、PR #2052（散文の形式反転）は **3 サイクル回して blocking が増え、ユーザー判断でループを離脱した**。収束しない構造を残す。

| cycle | blocking | 指摘の性質 |
|---|---|---|
| 1 | 2 | 実装欠陥（配布境界への内部参照流入 / cp fixture の pin 空洞化） |
| 2 | 3 | 実装欠陥 1 + scope 割れ 1 + 防御コードのコメント乖離 1 |
| 3 | 6 | **うち 4 件が「テスト / drift pin を足せ」** |

離脱の判断材料になったのは件数ではなく**内訳の性質の推移**だった。

1. **「pin が無い」系の指摘は、直すたびに新しい pin 対象を作る。** cycle 3 の 4 件の内訳は (a) cycle 2 で変更した bash ブロックにテストが無い、(b) cycle 1 で追加した fixture がテンプレートの末尾改行 1 バイトに依存する、(c)(d) 配布テンプレートと SKILL.md の二重定義に drift pin が無い。**(b) は cycle 1 の修正そのものが生んだ指摘**で、修正 → その修正への指摘 → さらに修正、という増殖形になっている。
2. **docs 是正 PR にテスト基盤を後付けし続けると、PR の主題から離れた作業が主になる。** テスト基盤の不足は一連の作業として別 Issue に括る方が、PR 単位でも作業単位でも健全。
3. **判定基準: 指摘の性質が「実装の誤り」から「検証資産の不足」へ移ったら、それは別 Issue のシグナル。** 件数の推移だけを見ていると「あと 1 サイクルで収束するかもしれない」と読めてしまう。内訳を並べると収束しないことが早期に判る。

なお、この PR は 3 サイクル離脱後にさらに別系統のレビューを 2 サイクル受けており（形式反転の伝播とマージ直前の CI 赤）、通算では 5 サイクルを超えている。**離脱の判断は「もう指摘が出ない」ではなく「この PR の主題で解ける指摘が出なくなった」で行う。**

## ソース（追記分 4）

- [PR #2052 review results (cycle 3, loop exit) — 収束しない軌跡と離脱判断](../../raw/reviews/20260802T114732Z-pr-2052.md)
