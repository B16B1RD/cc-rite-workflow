---
title: "累積対策 PR の review-fix loop で fix 自体が drift を導入する"
domain: "anti-patterns"
promote: rite-plugin
description: "同種 regression への N 回目の累積対策 PR では、review-fix loop の各 cycle で適用した fix 自体が次 cycle の新規 drift を生む fractal pattern が顕在化する。"
created: "2026-04-21T10:35:00+00:00"
updated: "2026-08-07T08:00:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260806T173922Z-pr-2126-c4.md"
  - type: "fixes"
    ref: "raw/fixes/20260806T002741Z-pr-2120.md"
  - type: "reviews"
    ref: "raw/reviews/20260804T060209Z-pr-2099.md"
  - type: "fixes"
    ref: "raw/fixes/20260804T060834Z-pr-2099.md"
  - type: "reviews"
    ref: "raw/reviews/20260518T084056Z-pr-1043-cycle4-mergeable.md"
  - type: "reviews"
    ref: "raw/reviews/20260518T075850Z-pr-1043.md"
  - type: "reviews"
    ref: "raw/reviews/20260516T055016Z-pr-992.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T024947Z-pr-636.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T030627Z-pr-636-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T005759Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260429T092812Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T032048Z-pr-636-cycle-3.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T033906Z-pr-636-cycle-4.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T045816Z-pr-636.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T095348Z-pr-636.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T025621Z-pr-636.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T031214Z-pr-636-cycle-2.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T033138Z-pr-636-cycle-3.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T050914Z-pr-636.md"
  - type: "reviews"
    ref: "raw/reviews/20260424T045427Z-pr-653.md"
  - type: "fixes"
    ref: "raw/fixes/20260424T060618Z-pr-654.md"
  - type: "fixes"
    ref: "raw/fixes/20260424T061400Z-pr-654.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T133145Z-pr-661.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T153740Z-pr-661.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T161137Z-pr-661.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T165246Z-pr-661.md"
  - type: "reviews"
    ref: "raw/reviews/20260425T171440Z-pr-661-cycle-4.md"
  - type: "fixes"
    ref: "raw/fixes/20260425T154517Z-pr-661-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260425T161635Z-pr-661.md"
  - type: "fixes"
    ref: "raw/fixes/20260425T165546Z-pr-661.md"
  - type: "reviews"
    ref: "raw/reviews/20260427T021251Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260427T155947Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T105854Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T122927Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T151033Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T111028Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T123811Z-pr-688.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T153020Z-pr-688.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T123230Z-pr-753.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T125141Z-pr-753.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T130829Z-pr-753-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260430T123646Z-pr-753.md"
  - type: "fixes"
    ref: "raw/fixes/20260430T125524Z-pr-753.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T141522Z-pr-754.md"
  - type: "reviews"
    ref: "raw/reviews/20260430T192119Z-pr-754.md"
  - type: "fixes"
    ref: "raw/fixes/20260430T141940Z-pr-754.md"
  - type: "fixes"
    ref: "raw/fixes/20260430T143329Z-pr-754.md"
  - type: "fixes"
    ref: "raw/fixes/20260430T191751Z-pr-754.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T095733Z-pr-765.md"
  - type: "fixes"
    ref: "raw/fixes/20260502T101035Z-pr-765.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T103134Z-pr-765-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260514T160500Z-pr-961.md"
  - type: "reviews"
    ref: "raw/reviews/20260515T001207Z-pr-968.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T000446Z-pr-1004.md"
  - type: "reviews"
    ref: "raw/reviews/20260517T004634Z-pr-1004.md"
  - type: "fixes"
    ref: "raw/fixes/20260517T020335Z-pr-1004.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T041118Z-pr-1146.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T034356Z-pr-1146.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T032658Z-pr-1146.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T033648Z-pr-1146.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T021038Z-pr-1146.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T114956Z-pr-1149-cycle5.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T121902Z-pr-1149-cycle6.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T131113Z-pr-1149-cycle7-converged.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T131927Z-pr-1149-cycle8-final-converged.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T120733Z-pr-1149-cycle5.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T125406Z-pr-1149-cycle6.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T131458Z-pr-1149-cycle7-converged.md"
  - type: "reviews"
    ref: "raw/reviews/20260528T055956Z-pr-1166.md"
  - type: "reviews"
    ref: "raw/reviews/20260528T060938Z-pr-1166.md"
  - type: "fixes"
    ref: "raw/fixes/20260528T061125Z-pr-1166.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T012055Z-pr-2078.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T013839Z-pr-2078.md"
  - type: "reviews"
    ref: "raw/reviews/20260801T040325Z-pr-2078.md"
  - type: "fixes"
    ref: "raw/fixes/20260801T041229Z-pr-2078.md"
  - type: "reviews"
    ref: "raw/reviews/20260802T062240Z-pr-2052.md"
  - type: "reviews"
    ref: "raw/reviews/20260802T073519Z-pr-2052.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T063409Z-pr-2052.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T070715Z-pr-2052.md"
  - type: "reviews"
    ref: "raw/reviews/20260804T092934Z-pr-2102.md"
tags: ["review-loop", "cumulative-defense", "convergence", "quality-signal", "architectural-surface", "literal-syntax-validity", "anchor-prose-propagation", "self-meta-drift", "propagation-scan-pattern", "self-referential-learned-section", "cycle-14-15-chain", "review-attention-bias-blind-spot", "anchor-specificity-retreat", "doc-precision-regression-cascade", "self-referential-prevention-violation", "section-relative-prevention-success", "successive-prevention-replication", "doc-heavy-fractal-pattern", "systemic-mass-fix", "auto-demote-low-override", "fix-over-correction", "enforcement-locus-misattribution"]
confidence: high
---

# 累積対策 PR の review-fix loop で fix 自体が drift を導入する

## 概要

同種 regression への N 回目の累積対策 PR では、review-fix loop の各 cycle で適用した fix 自体が次 cycle の新規 drift を生む fractal pattern が顕在化する。implicit stop regression の 8 回目対策 PR は 13 cycle 回って収束し、cycle 2 findings の 60% が cycle 1 fix 起因、cycle 3 で cycle 1-2 review では見えなかった architectural HIGH finding (`--preserve-error-count`) が初めて surface した。cycle 数による hard limit ではなく、quality signal (同一パターン反復 / dead marker 追加 / description-impl drift / architectural bug surface) による escalate 判断が canonical。sentinel rename PR でも `cycle-14-15-chain` の典型例が再発: cycle 14 で CHANGELOG の「hook が旧 literal を reject」という stale 文言を「正確に」修正する過程で、検出主体を誤って meta-test に帰属させる新たな事実誤認を導入し、cycle 15 で再訂正した。教訓: finding を「正確に」直す際、修正文が新たに導入する事実主張 (どの機構が何を検出するか) も実体 grep で検証する。とくに enforcement 機構の所在は (runtime hook / 自動 meta-test / 手動 smoke 手順) の 3 層を厳密に区別し、粒度の粗い「test レベル」訂正で test の具体的責務 (新 sentinel assert vs 旧 literal residual grep) を取り違えない。

## 詳細

### 事象 — 8 回目対策での 13 cycle 収束軌跡 (findings 数)

```
cycle 1 (13) → cycle 2 (10) → cycle 3 (8) → cycle 4 (8) → cycle 5 (4)
  → cycle 6-12 (14→5→7→2→5→5→2) → cycle 13 (0) mergeable
```

- **cycle 2 の 10 findings のうち 6 件が cycle 1 fix 起因** (path prefix drift / bash syntax 破綻 / dead marker 追加 / description-impl drift)
- **cycle 3 で architectural HIGH 初 surface**: `flow-state-update.sh patch` の `.error_count = 0` 無条件リセットが同一 phase self-patch で RE-ENTRY 検出層を永久 unreachable にしていた設計前提の覆し。cycle 1-2 の review では実装読解を伴わない局所的 drift 検出に留まり surface しなかった
- **cycle 9 以降は comment/doc drift に収斂**: implementation bug は cycle 3 で出尽くし、後半は DRIFT-CHECK ANCHOR / tech-writer 指摘 / sibling symmetry 中心

### fractal drift の 3 典型パターン (cycle 1 → 2 → 3 で実測)

1. **Path prefix / literal 短縮 drift**: cycle 1 で HINT bash 例を書き換えた際に path prefix を短縮して sibling site (L310 / L325 / L331) と drift。cycle 2 で HIGH 指摘として再検出
2. **`; then proceed` bash 構文破綻**: cycle 1 で `--next` 値を延長した際に接続詞として `; then proceed` を残し literal copy-paste safe でない。cycle 2 で HIGH 指摘
3. **Dead marker 追加の同型再発**: cycle 1 で削除した dead marker (`MANDATORY_AFTER_INTERVIEW_STEP_0`) と同型の新 marker (`STEP_0_PATCH_FAILED`) を cycle 1 fix で追加したが consumer 0 件で cycle 2 再検出

### canonical 対策 — cycle escalate の quality signal

**cycle 数ベースの hard limit は撤廃済み** (rite-config.yml v1.0.0 で review-fix ループの hard limit キー廃止)。escalate 判断は以下 4 quality signal で行う:

| signal | 観測 | escalate 先 |
|--------|------|------------|
| 同一パターン反復 | cycle N+1 の finding が cycle N fix 起因 drift が > 50% | 外部 reviewer / human review |
| Dead marker 追加 | `[CONTEXT]` flag emit したが consumer 0 件 (grep で確認) | 3 点セット (emit / consume / test) 契約違反 → marker 削除 or wiring 追加 |
| Description-impl drift | prose description が実装と乖離 | doc drift として個別修正 |
| Architectural bug surface | cycle N+1 で cycle N では見えなかった設計前提の覆し | design review (PR 全体の architectural correctness 再評価) |

### Fix 側の予防契約 — 3 点セット / twin site / sibling symmetry

1. **[CONTEXT] retained flag の 3 点セット契約**: 新 marker 追加時は (a) emit site、(b) consume site (stop-guard.sh / Pre-check list の grep 参照)、(c) test assertion の 3 点を **同一 PR で** 揃える。欠けた marker は dead signal として次 cycle で削除推奨
2. **Twin site contract verification**: HINT emit 側 (stop-guard.sh) と grep 参照側 (create.md retained flag emit) が対応する marker は、片側だけ test で verify する pattern が silent regression を許す。TC-634-E のような twin site 両方を同 test で check する canonical template を採用
3. **Sibling symmetry は fix 前に grep で全列挙**: 3-site 対称セット (TC-634-A/B/C、HINT L310/L325/L331 等) は 1 箇所修正時に必ず grep で他 2 箇所を列挙し **atomic に修正**。cycle 1 F-07 → cycle 2 F-06、cycle 1 F-12 → cycle 2 F-01 はこの原則違反で再検出
4. **Self-aware コメントで同 cycle horizontal propagation を明示**: 同 cycle 内で過去 fix が false-positive を修正した場合、新規 fix にも `(line-number 参照を避ける理由は cycle 8 F-05 参照)` のような self-aware コメントを残す (semantic anchor + trailer convention)

### 累積対策 PR 特有の pitfall

- **self-review のみでは収束しない可能性が高い**: 累積対策 N 回目は既存 convention の drift が溜まりやすく、self-review だけで catch できるのは local consistency 中心。architectural design の spread (3-site symmetry 等) は fresh reviewer / human 目でしか proactive に防げない
- **Step 追加時の preamble / range 記述は手動 sync 対象**: "Step X-Y を実行" / "N-line block" のような数値記述は Step 追加のたびに手動更新が必要で自動 lint 対象外。review checklist に mandatory 化するか lint rule 追加を検討
- **Drift 除去 ≠ architectural correctness**: cycle 2 fix で drift 6 件除去しても cycle 3 で HIGH architectural finding が追加検出される。「drift 除去」と「設計の正しさ」は直交軸で、前者の達成は後者を保証しない

### 9 回目対策の 3 cycle 収束軌跡 (2026-04-24)

8 件目と同型の累積対策 9 件目 PR で **本ページ自身を裏付ける self-exemplar** が再発した:

```
cycle 1 (10 findings: 1 CRIT + 1 HIGH + 4 MED + 4 LOW)
  → cycle 2 (3 LOW)
    → cycle 3 (0) mergeable
```

#### Cycle 1 の CRITICAL: literal として LLM に渡す bash の構文有効性 test 漏れ

declarative 9 件目で `caller HTML コメント内` に追加した bash literal `bash ... --preserve-error-count ; then continue with Phase 0.6 ...` が **bash 構文として無効** (`; then` は `if cmd; then ... fi` の文法トークンであり、if 句なしで使うと syntax error rc=2)。LLM が caller HTML コメント冒頭の指示「IMMEDIATELY run as your next tool call」に従い literal copy → Bash tool 実行すると Step 0 自体が syntax error で abort し、Step 1 idempotent retry に依存することになる経路だった。

これは 8 件目 cycle 1 F-12 (`; then proceed` bash 構文破綻) の **再発** であり、累積対策追加 PR で literal 文字列を散文と混在させる際に shell 文法トークン (`; then`) を散文と隣接配置すると LLM が if 構文の一部と誤解釈する経路は構造的に発生する。

**declarative 文書追加 PR の 5 つの品質保証ポイント**（9 回目対策で確立）:
1. **literal として LLM に渡すコードは構文有効性を test で検証**: `bash -n` 相当の static check が困難な場合は invalid pattern を含まないかの NOT-contain grep で代替可能（9 回目対策では `--preserve-error-count[[:space:]]*;[[:space:]]*then[[:space:]]+continue` を NOT-contain で grep）
2. **literal 文字列を散文と混在させる場合、構文区切り (backtick / 括弧) で明示的に分離**
3. **DRIFT-CHECK ANCHOR は対称化対象の全 site で同一文言で記載**（create-interview.md に新規 4-site anchor を追加したが、対称位置の create.md / stop-guard.sh の既存 3-site anchor は更新されておらず drift detector が機能しなかった）
4. **2-site 内 duplication (同一ファイル内 N 箇所) には `grep -cF` で count check を入れる** (1 箇所のみの match で pass する grep は片肺欠落 silent regression を許容)
5. **escalation path の test (error_count=1+) も初回 entry path と同等の sentinel 4 句 grep で覆う** (TC-651-A2 で initial entry のみ verify していた問題を補完)

#### Cycle 2 の波及範囲不足 — DRIFT-CHECK ANCHOR fix の隣接 prose drift

cycle 2 で発見された 3 LOW (F-11/F-12/F-13) は cycle 1 F-03 修正の波及範囲不足が原因。DRIFT-CHECK ANCHOR section の strict scope だけを更新したが、隣接 prose paragraph 内の同 terminology (`3-site`/`3 site`) は対象外として silent skip された (3 reviewer すべて同 root cause を別 location で指摘し High Confidence cross-validation で確定)。

これは「Asymmetric Fix Transcription」の **派生形**:
- 元の Asymmetric Fix Transcription: 同一 invariant の対称位置 (異なる file/section) への伝播漏れ
- 本 PR で観察: 同一 file 内・**同一 blockquote 内** の隣接 paragraph への波及漏れ

**scope 拡張規則**: anchor 修正は anchor 内 strict text だけでなく、anchor が説明する terminology を使う隣接 prose も sweep 対象。

**mitigation**: anchor 系統を更新する際は (a) `git diff` で blockquote 全体を見直す + (b) grep で旧 terminology の残存有無を全 file 検索する、の 2 step を必須化。

#### Self-exemplar 構造の累積メタパターン

8 件目 → 本ページを起こした観測 PR → 9 件目 と 3 連続で「累積対策追加 PR が新たな drift / bug を生む」self-exemplar が発生。これは **declarative 強化路線そのものの構造的限界** を示唆:
- declarative 規約は LLM の挙動を「説明」するが「強制」しない (規約違反時の machine-enforced gate がない)
- 規約の追加自体が新たな攻撃面 (literal の構文有効性 / 隣接 prose drift / dead marker) を生む
- self-review / 単一 reviewer では catch できない構造的 drift は cross-validation High Confidence でしか surface しない

長期的にはメタレイヤー対策 (PostToolUse hook で LLM 挙動を強制注入する等) を別 Issue で検討すべきだが、現状は本ページの 4 quality signals + 5 品質保証ポイント + 隣接 prose sweep 規則 を組み合わせた declarative 強化が pragmatic optimum。

### opt-in backward-compatible flag の設計教訓

8 件目 cycle 3 で追加された `--preserve-error-count` flag は、`.error_count = 0` 無条件リセットという従来契約を破壊せずに新 usage pattern (同一 phase への self-patch) を許容する canonical design:

- **既存 caller (phase transition) は flag なしで reset 継続** — 後方互換保証
- **新規 self-patch caller は明示的に保持を選択** — opt-in で意図を明示
- **docstring に各 mode での挙動を明示**: patch mode のみ有効、create/increment mode では silent no-op が意図的

semantics 変更を伴う修正では「新 flag + opt-in + 既存挙動保持」が最もリスクが少ない (PR 全体を書き換えるより diff scope が絞れて review しやすい)。

### 累積対策 11 回目で観測された self-meta drift convergence

silent precondition omit の root cause 修正は cycle 1 → 4 で findings 数が **7 → 2 → 1 → 0** と明確 convergence（8 回目対策の 13 cycle と比較して 4 cycle で収束）。各 cycle で見つかる finding の大半は前 cycle fix が導入した self-meta drift だった:

```
cycle 1 (7) → cycle 2 (2) → cycle 3 (1) → cycle 4 (0) mergeable
```

| Cycle | findings | 内容 |
|-------|----------|------|
| 1     | 7 (HIGH 4 + MEDIUM 3) | DRIFT-CHECK ANCHOR の bash 引数 enumeration 同期漏れ × 3 / AC-1 test 永続化欠落 / Inverse TC 不在 / TC 命名 convention drift / dead variable |
| 2     | 2 (MEDIUM × 2)        | cycle 1 fix で `--active true` を 4-arg に拡張した際、ANCHOR comment の prose 側 1 site が旧 3-arg 表記のまま残留 (`create-interview.md:601`) + cycle 1 で新規追加した ANCHOR comment 内に `(line N, M)` hardcoded reference を導入 (cleanup.md:1674) |
| 3     | 1 (MEDIUM, High Confidence boost) | cycle 2 fix で cleanup.md:1674 の `(line N, M)` を structural reference 化したが、cycle 1 で同時導入された create-interview.md:605 の散文形式 `本セクション直前の line 588 / 597` を見落とし、prompt-engineer + code-quality の cross-validation で発見 |
| 4     | 0 (5 reviewer 全員 mergeable) | AC-1 mechanical scan / 4-site DRIFT-CHECK ANCHOR semantic / TC-660-A〜E / Hook test infrastructure / Production diag log 実機検証 すべて clean |

**root cause として観測された self-meta 構造**: 本 PR が解決しようとしている root cause (silent 単一障害点) と、cycle 2 / cycle 3 で発見された finding は、共に「文書間 / 文書内の reference drift」という同型構造。**累積対策 PR の root cause 自体が「drift detection の不完全性」である場合、fix loop の各 cycle が新しい drift detection coverage の不完全さを暴露する fractal pattern**。

**Propagation scan pattern coverage の限界**: cycle 2 の propagation scan は `(line N, M)` 形式 (cleanup.md:1674 の表記) を grep していたが、create-interview.md:605 は散文形式 (`本セクション直前の line 588 / 597`) を含み、scan logic の表記差で検出漏れになった。これは「Asymmetric Fix Transcription」の表記揺れ次元への拡張で、`drift-check-anchor` lint pattern を以下の表記すべてに対応させる必要がある (別 Issue 候補):
- `(line N, M)` parenthesized form
- `(L<num>)` short form
- `<file>:<num>` colon form
- `本セクション直前の line N` 散文形式
- `Line <num>` capitalized form

**cycle 4 mergeable 確定の cross-validation 構造**: 5 reviewer (prompt-engineer / code-quality / test / error-handling / devops) 全員が独立に「評価: 可」(0 findings) を出した時点で「累積対策 fractal pattern が収束した」と判定する canonical signal。cycle 4 で **6 件の REC (recommendation Issue 候補)** も同時抽出され、cycle 数を hard limit せず quality signal で判断する原則の追加実証。

### multi-state-aware flow-state read helper — 累積 14 回目 38+ cycle 観測

累積 14 回目の対策 PR は 38+ cycle にわたり review-fix loop を継続。本ページの fractal pattern が **新たな 2 つの failure mode を加える** 自己累積実例として記録:

#### Failure mode 1: `cycle 6→7→8→9→10→11→12→13→14` chain での fix-introduced regression 6 連続

| cycle | 修正 | 次 cycle で検出された regression |
|-------|------|--------------------------------|
| 6 fix | pipeline 化 | pipeline exit code masking (CRITICAL, 3 reviewer 独立検出) |
| 8 fix | stderr tmpfile 退避 | fresh-resume hard-abort + silent suppression |
| 10 fix | AC-4 caller migration | partial migration (line 72 取り残し) + prose drift |
| 12 fix | prose conjunctive 修正 | 同 file 同 block 隣接行に新規 prose drift 導入 + caller test 不在 |
| 14 fix | prose + caller test 新規 | TC-1.2 dead code (3 reviewer cross-validated) |
| 16 fix | dead code 削除 + chain 終止 | 完了 |

→ 各 fix が **immediate symptom focus** から **adjacent area scan** に格上げされる規範。「修正対象行の周辺 ±10 行」「同一ファイル内の同型 prose」「caller 側の test の存在」を必ず確認する discipline。「prose 修正で prose drift を解消するアプローチは constructive ではなく self-introducing パターンを生む」という反省 — **reference を作るのではなく reference を消して self-contained にする** ことで chain を断つ canonical fix 方針が cycle 16 で確立。

#### Failure mode 2: Self-referential learned 節 chain (累積 35+ cycle 越えで初観測)

cycle 35 commit message が learned 節で「累積 12 回目の Asymmetric Fix Transcription」を **明記しながら**、同じ commit 内の F-07 修正で同型 `if !` anti-pattern を新規 4 site (`state-read.sh:139-145, 155-161` / `flow-state-update.sh:170-176, 185-191`) に同時播種した self-referential failure mode を cycle 36 で完全修復。13 回目の累積パターン (詳細は [`if ! cmd; then rc=$?` は常に 0 を捕捉する](./bash-if-bang-rc-capture.md))。実機検証:

```bash
$ set -euo pipefail; if ! bash -c 'exit 7'; then emit_rc=$?; echo $emit_rc; fi
0  # 期待 7
```

これは「**learned 節で言及した直後の同 commit で再演する**」特殊な self-referential pattern で、**認知バイアスとレビュー疲労の交差点で発生** する failure mode。今後の bash 系 PR では cycle commit message に書いた learned 節の対象パターンが「**同 commit 内の他箇所**」で再演されていないかを self-verify する step を追加検討する canonical 規範を追加。

#### Failure mode 3: 大規模 scope 拡張時の bug 埋め込みリスク (cycle 5 で実測)

cycle 5 で「軽微 (URL fix / typo) + 中規模 (edge case) + 大規模 (write 経路 migration)」3 層対応をユーザ judgment で本 PR scope に取り込み、9/10 を 1 commit で解消した結果、大規模 (resume.md write 経路 migration) で flow-state-update.sh patch mode の必須引数 (--phase/--next) を欠落する **CRITICAL bug を導入**。5 reviewer (code-quality / prompt-engineer / error-handling / security / test) が独立に sandbox で実機再現して同一根本原因を検出 (最高信頼度 reviewer 合意)。

→ scope 拡張時は cycle を細分化して各変更を独立に verify する方が safer。caller migration では hook の API contract (必須/optional 引数) を sandbox eval で verify する step が必要。

#### 38 cycle 観測の累積 quality signal 拡張

累積 14 回目の 38+ cycle 経過で本ページの 4 quality signal に追加:

| 追加 signal | 観測 | escalate 先 |
|-----------|------|------------|
| Self-referential learned 節 | commit message の learned 節と同 commit 内の他箇所が同型 anti-pattern を再演 | commit 直前に learned 節対象パターンの全 site grep + sandbox 実機 verify を mandatory 化 |
| Cross-validated CRITICAL の reviewer 合意数 | 5+ reviewer 独立 sandbox reproduction で同一根本原因を検出 | 単独 reviewer の reasoning に頼らず empirical reproduction を gate にする (cf. [`empirical-reproduction-over-invariant-reasoning.md`](../heuristics/empirical-reproduction-over-invariant-reasoning.md)) |
| `2>&1` self-defeating sentinel | 「sentinel observability」を deliverable とする PR が、その deliverable 自身を `2>&1` で silent suppress | helper output contract を docstring で明示 + caller test で sentinel emit と exit code の両方を assert (cf. [`stderr-merge-silent-sentinel-suppression.md`](./stderr-merge-silent-sentinel-suppression.md)) |
| `rejected(scope-creep)` の empirical gate | author の主観判断で reject した懸念事項が cycle N+1 reviewer の empirical revert test で CRITICAL 認定 | reject 判断は cross-validation + empirical revert test で gate (cf. [`scope-creep-rejection-empirical-gate.md`](../heuristics/scope-creep-rejection-empirical-gate.md)) |

#### 累積 14 回目 cycle 12 → 14 → 15 chain で実証された self-referential learned 節 chain HIGH 観測

累積 14 回目の最終収束過程 (cycle 12-15) で「**learned 節で言及した直後の同 commit で再演する**」累積 14 回目 self-referential pattern が **HIGH 級として 2 件** cross-validated で実証された:

| cycle | learned 節で警告 | 同 commit で再演 (HIGH 検出) |
|-------|----------------|---------------------------|
| 14 fix (`c0fae09 fix(review): #688 cycle 14`) | Self-referential learned 節 chain を防ぐ目的で `[CONTEXT] METRICS_SKIPPED=1` sentinel と Claude 指示を導入 | その指示自体に「Phase 5.5.3 へ進む」(存在しない phase) を埋め込んでいた → cycle 15 F-01 (HIGH) として検出 |
| 14 fix | bash-trap-patterns.md の対象ファイルリストを 5 ファイルに拡張する fix を実施 | 同 doctrine 内 line 374 の「対象 3 ファイル」古い列挙 (`fix.md + review.md + start.md` の旧 3-file 列挙) を見落としたまま残存 → cycle 15 F-02 (HIGH, Asymmetric Fix Transcription 再演) として検出 |

これらの 2 件は本ページの「Failure mode 2: Self-referential learned 節 chain」(累積 35+ cycle 越えで初観測) を **HIGH 級で再実証** し、「**累積対策追加 PR が新たな drift / bug を生む self-exemplar**」が 4 PR 連続で観測された。

#### 累積 14 回目 cycle 12 で観測した DRY 集約助手の overstate (新 sub-pattern)

累積 14 回目 cycle 12 review で MEDIUM × 2 として、累積対策 PR の新 failure mode が surface した:

1. **集約 helper のコメント overstate**: `_validate-helpers.sh` で集約したのは validation logic のみだが、コメントは「helper 追加時の 2 箇所更新が不要になり」と書いており、実際には helper 名 list (両ファイルにハードコード重複 7 entry × 2 箇所) が依然 2 箇所同期更新を要する → この helper 集約が解こうとした root cause (drift 防止) と同型の drift 再発許容経路を文書レベルで作成
2. **Migration 取り残し**: 新規 helper を 3 caller のうち 2 つだけが使用し、`resume-active-flag-restore.sh` 1 つは旧 inline pattern を残存 → 3 caller 中 2/1 の不均一更新 = DRY 化導入の核心理由 (drift 防止) が部分的にしか達成されない

詳細は [DRY 集約助手の効果記述は『何が集約され、何が依然分散しているか』を明示する](./dry-helper-aggregation-effect-overstate.md) に切り出した。

#### 累積対策 14 回目 38+ cycle 観測の収束信号

累積 14 回目 cycle 12-15 の追加観測で、本ページの「累積対策 PR の review-fix loop は cycle 数 hard limit ではなく quality signal で escalate する」原則の追加実証が完了:

```
cycle 12 (7 findings) → cycle 14 (7) → cycle 15 (9) → cycle 16 (collapse)
```

- cycle 12 → 14: cycle 12 fix が cycle 14 で 7 件再検出 (うち 2 件 HIGH cross-validated)
- cycle 14 → 15: cycle 14 fix が cycle 15 で 9 件再検出 (うち 2 件 HIGH cross-validated, 上表参照)
- cycle 15 → 16: cycle 15 で全 9 finding が code 修正で対応、self-referential learned 節 chain が collapse

これは「累積対策 N+1 回目 PR は learned 節の対象パターンを **同 commit 内で再演** する確率が PR の cycle 経過 (38+) と learned 節の数 (累積 14 回分) に比例して上昇する」観察を実証。learned 節を commit message に書く際は **対象パターンの全 site grep + sandbox 実機 verify** を mandatory step として組み込むのが canonical (本ページ「Cross-validated CRITICAL の reviewer 合意数」signal の延長線)。

#### Failure mode 4: Self-defeating defense (cycle 49 H-1) — 防衛機構導入 fix 自体が drift を含み防衛対象が再開する

累積 14 回目 cycle 49 review で 1 CRITICAL + 2 HIGH + 7 MEDIUM + 6 LOW を検出した中、**H-1 CRITICAL** は cycle 49 で導入した METRICS_SKIPPED sentinel が、Phase 5.5.2 の Step 番号 off-by-one drift により無効化される self-defeating defense として記録された。Self-referential learned 節 chain anti-pattern の典型例 — **防衛機構を導入する fix 自体が drift を含み、防衛対象だった partial corruption が再開する経路**。

**学習 (canonical 対策)**:

1. **防衛機構導入 cycle に Step 番号 absolute 化を mandatory step**: 防衛機構を導入する fix で「Step N + 1 を skip」「次の Step」のような relative 参照を書いた瞬間、後続 reorder で actual heading 構造とのずれが silent regression を生む。Step 番号は heading title 名 + Step 番号の absolute form (例: `Phase 5.5.2 Step 1: METRICS_SKIPPED emit`) で書く規約を防衛機構導入 cycle に必須適用 (詳細: [Step 番号参照は relative ではなく absolute (heading title 名 + Step 番号) で書く](../patterns/step-reference-absolute-heading-over-relative.md))
2. **Self-defeating defense 検出のための cross-validation revert test**: 「防衛機構を導入した fix」を merge する前に、**(a) 防衛機構が無いコードで attack scenario を再現** + **(b) 防衛機構を導入した後に同 attack scenario を再実行** + **(c) 防衛機構が actual に block するか empirical に直接観測**。reasoning ベースで「invariant は成立する」判定する経路は accumulated 49 cycle 後にも silent regression を見逃す
3. **CRITICAL self-defeating defense + HIGH 片肺 drift + MEDIUM mutation kill power gap の組み合わせは累積 escalation 信号**: 1 cycle で同型 anti-pattern が 3 severity に渡って同時 surface する場合、累積対策 PR の防衛文言固化 (cycle 41/43/49 系列で追加された防衛文言が膨張) を意味する。canonical 対策は SoT 集約 (state-read-evolution.md 等) と短い semantic anchor のみへの圧縮

#### 累積 14 回目の最終 cycle (47+) 観測の追加 lesson

累積 14 回目の最終フルレビュー (6 reviewer 21 findings) 後の lesson 追加:

1. **「累積対策 PR の防衛文言は数 cycle で意味を失う」**: cycle 41/43/49 系列で追加された防衛文言が膨張し、第三者読者が 1 行で意味を取れなくなる経路。1 cell に複数 cycle 番号 + 5 件の cross-reference を混在させると Self-referential learned 節 chain が顕在化。SoT 集約 (state-read-evolution.md) と短い semantic anchor のみへの圧縮が必要
2. **「Mutation testing の vector は production の正規化処理 (tr / sed) との相互作用を empirical 検証する」**: `tr -d '[:space:]'` で改変される vector は SID resolve 結果と per-session file 名が非同期化され mutation kill power が 0 になる経路を持つ。test 設計時に production の正規化処理を前提として vector を選定する必要がある (詳細: [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md))
3. **「scope-creep の cross-validation gate を `rejected(scope-creep)` action lines として commit message に明記する」**: 累積 14 回目 38+ cycle PR では F-03/F-04/F-05/F-06 の MEDIUM 4 件 (helper 抽出 / caller boilerplate 集約 / cleanup 関数命名統一) が scope 大として別 Issue 化された。`rejected(scope-creep)` action line を commit message に明記し、後続 reviewer が cross-validation で gate する canonical flow (詳細: [`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する](../heuristics/scope-creep-rejection-empirical-gate.md))

### 累積 14 回目の followup — 累積 15 回目 5 cycle 完全収束 + 新 sub-pattern: review-attention-bias × test file blind spot

累積 14 回目の verified-review cycle 10 で `rejected(scope-creep)` により延期された 3 件 (F-09/F-12/F-15) の followup は **累積 15 回目** で 5 cycle 完全収束:

```
cycle 1 (12 findings: 3 HIGH + 4 MEDIUM + 5 LOW)
  → cycle 2 (15: 1 HIGH + 4 MEDIUM + 10 LOW) — fix 自体が drift 導入 (累積 fractal pattern 再演)
    → cycle 3 (3 HIGH all comment-quality) — cycle 1+2 fix が SoT 違反 drift 導入
      → cycle 4 (1 HIGH + 1 MEDIUM, **test file blind spot**) — 新 sub-pattern surface
        → cycle 5 (0, mergeable) — 4 reviewer 全員 healthy self-assessment
```

#### 新 sub-pattern: review-attention-bias × fix-scope-narrowing が test file blind spot を温存する

cycle 4 で初検出された 2 件 (1 HIGH F-01: `flow-state-update-trap-isolation.test.sh:56` の hardcoded line ref / 1 MEDIUM F-02: 同 file:96 の dead `local _run_cleanup` 宣言) は **cycle 1-3 で test ファイルがレビュー対象に含まれていたにも関わらず連続スルー** された blind spot。Quality Signal 1 (Fingerprint cycling) として cycle 3 F-03 (`flow-state-update.sh:244` line ref) と cycle 4 F-01 (`test.sh:56` line ref) は **同じ SoT 原則 3 (no_literal_line_reference) 違反パターン** だが、cycle 3 fix scope を「flow-state-update.sh 単独」に絞ったため propagation scan が test ファイルに到達しなかった。

**2 つの failure mode の交互作用**:

1. **Reviewer attention bias**: cycle 1-3 で reviewer の attention が flow-state-update.sh の comment quality 違反 (journal comment / line number reference) に集中。test ファイルは「supporting fixture」として scan が浅くなり、同型 drift が見落とされた
2. **Fix-scope narrowing**: 累積対策 PR では「最小 diff で merge する」圧力で fix scope を該当ファイル単独に絞る傾向があり、propagation scan (同 SoT 原則違反の他 site 検索) が省略される

両者が交互作用すると、SoT 原則違反 drift が **review attention の影に隠れた fixture 系 (test / mock / helper ファイル)** に温存される経路が成立する。

**canonical 対策**（cycle 5 fix で確立）:

| 対策 | 実装 |
|------|------|
| **propagation scan の必須化** | SoT 原則違反 (no_journal_comment / no_literal_line_reference 等) 修正時は、修正対象の 1 file だけでなく、同 PR で touch した全 file に対して同型 violation を grep で検索する必須 step を追加 |
| **Test ファイル full rescan の独立 step**: | code-quality reviewer が cycle 4 で初めて test ファイル全体を rescan して 2 件発見した経緯を canonical 化。test ファイルは「fixture」ではなく「production code」として同等の review depth を適用する |
| **Cycle trajectory の「test scope 到達」を可視化** | 累積対策 PR の review checklist に「propagation scan が test ファイルまで到達したか」のフラグを追加 (本 PR では cycle 4 が最初の到達 cycle) |

#### 累積 15 回目で観測された review-fix loop quality signal の強化

本ページの 4 quality signal に加え、累積 15 回目から **「test/fixture ファイルへの propagation scan 到達 cycle」を escalate signal として追加**:

| 追加 signal | 観測 | escalate 先 |
|-----------|------|------------|
| Test/fixture file propagation gap | 累積対策 PR で同型 SoT 違反が production file → test file に N cycle 遅れて surface する | propagation scan の対象 file pattern を初回 cycle から「全 PR diff file」に拡大、reviewer に test ファイル full rescan を mandate |

#### Cycle 5 mergeable convergence の cross-validation 構造（累積 14 回目 cycle 4 と同型）

4 reviewer (code-quality / test / error-handling / security) 全員が独立に「評価: 可」(mandatory findings 0) + healthy self-assessment を出した時点で「累積対策 fractal pattern が収束した」と判定。本 PR では code-quality reviewer の判定文に `Cycle trajectory: 12 → 15 → 3 → 2 → **0** で完全収束を確認` と明記され、empirical reproduction による convergence 確認が成立した (cf. [`empirical-reproduction-over-invariant-reasoning.md`](../heuristics/empirical-reproduction-over-invariant-reasoning.md))。

### PR #2120 — fix 由来の drift が genuine な穴を件数で上回った（5 cycle 定量）

本ページの中心主張に **定量的な裏付け**が取れた事例。5 cycle 収束の指摘を由来別に分類すると次のようになった。

| 由来 | 件数 | 内容 |
|---|---|---|
| cycle 0 の実装・テストの genuine な穴 | 6 | `.gitignore` guard の silent 化 / 順序契約の未 pin / JSON 型の未 pin / ISO 8601 の未 pin / mkdir 分岐の未 pin / AC-2 の移植性ギャップ |
| **前 cycle の fix が導入した drift** | **7** | うち 6 件はコメント・assert の記述誤り、1 件は「防御を足したが pin を忘れた」 |
| pre-existing（follow-up へ） | 5+ | `.gitignore` idiom の 4 コピー分岐ほか |

blocking 件数の推移は **4 → 3 → 4 → 1 → 0**。cycle 3 で増えたのは、cycle 2 の修正が新たな指摘面（コメント）を作ったことと、cycle 3 で初めて mutation が到達した領域が surface したためである。

**「直す量」より「直し方が生む新しい面」が支配的になりうる**という本ページの主張が、件数で確認された最初の事例である。

#### cycle 1 fix が導入した 2 件の drift — いずれも「機構を直して記述を直さなかった」型

1. **列挙への項目追加時に述語の適合を確認しなかった**: 仕様書の「A / B / C はいずれも WARNING を出して `return 0`」という列挙へ、fix が新しい経路 D を差し込んだ。ところが D だけは `return` せず処理を続行する。しかも**同一コミットが追加したコード内コメント自身が** "the append runs either way" と逆のことを書いており、doc とコードが 1 コミット内で自己矛盾した。

   **列挙は「関連する項目の集合」ではなく「同じ述語を共有する集合」である。** 項目を足すときは共有述語が新項目にも成立するかを個別に検証し、成立しないなら列挙から外して別文にする。この検査は grep では出ず、列挙の述語を読んで新項目の実装と突き合わせる以外にない。レビュー側からは「列挙 + 新規追加行」という diff 形状で検出できる。

2. **fail-loud 化の増分価値が、その出力を通す既存フィルタで消えていた**: 無音だった失敗経路を「WARNING + 原因の併記」へ格上げしたが、原因を通す中和フィルタがバイト単位で 0x80-0x9f を潰すため、ロケール依存の errno（日本語）が判読不能になった。primary WARNING は純 ASCII だったため無傷で、**静的レビューでは「原因を出している」ようにしか見えなかった**。

   **fail-loud 化の価値は「何が起きたか」の情報量にあるので、その情報が出力経路の全段（中和・整形・字下げ・端末）を通過できるかを実測する。** 同じ経路に ASCII と非 ASCII が混在すると、ASCII 側だけを見て「動いている」と誤認する。

#### 修正の方向 — 上流を制約する方が下流を緩めるより安全

上記 2 の修正では、中和フィルタを弱める（`--c0-only` 等）選択肢もあったが、それは中和の目的そのものを削る。採ったのは失敗するコマンドに `LC_ALL=C` を前置して**上流メッセージを ASCII 化する**方法で、中和フィルタは何も変わらず、その行に対して no-op になるだけである。

**「安全機構が邪魔をする」と感じたときは、安全機構を緩める前に、その機構に渡る入力を安全機構が問題視しない形へ変えられないかを探す。**

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [コメントの「正確化」は主張を強めがち — 実態へ合わせるより強度を下げる方が安全](../heuristics/comment-correction-prefers-weakening-over-restatement.md)
- [同一箇所への指摘が N cycle 連続したら、その箇所が何番目のコピーかを数える](../heuristics/idiom-copy-count-decides-patch-vs-extract.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [Test が early exit 経路で silent pass する false-positive](./test-false-positive-early-exit.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](../heuristics/canonical-list-count-claim-drift-anchor.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)
- [DRY 集約助手の効果記述は『何が集約され、何が依然分散しているか』を明示する](./dry-helper-aggregation-effect-overstate.md)
- [Embedded markdown bash block の observability 三要素 (pipefail 宣言 + stderr stage 分離 + cd 失敗可視化)](../patterns/embedded-bash-block-observability-trio.md)

## ソース

- [PR #636 cycle 1 review (13 findings, 7 pattern categories)](../../raw/reviews/20260421T024947Z-pr-636.md)
- [PR #636 cycle 1 fix (13 findings resolved)](../../raw/fixes/20260421T025621Z-pr-636.md)
- [PR #636 cycle 2 review (10 findings, 60% fix-induced drift)](../../raw/reviews/20260421T030627Z-pr-636-cycle-2.md)
- [PR #636 cycle 2 fix (10 findings, 6 drift removed)](../../raw/fixes/20260421T031214Z-pr-636-cycle-2.md)
- [PR #636 cycle 3 review (architectural HIGH surface)](../../raw/reviews/20260421T032048Z-pr-636-cycle-3.md)
- [PR #636 cycle 3 fix (--preserve-error-count + twin site contract)](../../raw/fixes/20260421T033138Z-pr-636-cycle-3.md)
- [PR #636 cycle 4 review (incomplete architectural fix detection)](../../raw/reviews/20260421T033906Z-pr-636-cycle-4.md)
- [PR #636 cycle 5 review (silent-false-pass + line-number reference)](../../raw/reviews/20260421T045816Z-pr-636.md)
- [PR #636 cycle 5 fix (silent-false-pass via PATH fault injection)](../../raw/fixes/20260421T050914Z-pr-636.md)
- [PR #636 cycle 13 review (0 findings, mergeable convergence)](../../raw/reviews/20260421T095348Z-pr-636.md)
- [PR #653 review (累積対策 fractal pattern 観測 / Issue #650)](../../raw/reviews/20260424T045427Z-pr-653.md)
- [PR #654 cycle 1 fix — 9 件目 / literal bash syntax error self-exemplar](../../raw/fixes/20260424T060618Z-pr-654.md)
- [PR #654 cycle 2 fix (隣接 prose 波及漏れ / DRIFT-CHECK ANCHOR scope 拡張)](../../raw/fixes/20260424T061400Z-pr-654.md)
- [PR #661 cycle 1 review (累積 11 回目 / 7 findings)](../../raw/reviews/20260425T133145Z-pr-661.md)
- [PR #661 cycle 1 review (expanded — DRIFT-CHECK ANCHOR pair sync drift)](../../raw/reviews/20260425T153740Z-pr-661.md)
- [PR #661 cycle 1 fix (4-arg ANCHOR 拡張 + AC-1 test 永続化 + Inverse TC)](../../raw/fixes/20260425T154517Z-pr-661-cycle-1.md)
- [PR #661 cycle 2 review (DRIFT-CHECK ANCHOR の prose 内引数 enumeration 同期漏れ)](../../raw/reviews/20260425T161137Z-pr-661.md)
- [PR #661 cycle 2 fix (cleanup.md drift fix + line-number 違反修正)](../../raw/fixes/20260425T161635Z-pr-661.md)
- [PR #661 cycle 3 review (create-interview.md:605 横展開漏れの cross-validation 検出)](../../raw/reviews/20260425T165246Z-pr-661.md)
- [PR #661 cycle 3 fix (propagation scan pattern coverage 不足の修正)](../../raw/fixes/20260425T165546Z-pr-661.md)
- [PR #661 Cycle 4 Review (mergeable, 0 findings, 6 REC 抽出)](../../raw/reviews/20260425T171440Z-pr-661-cycle-4.md)
- [PR #688 cycle 5 review (5 reviewer 独立検出 CRITICAL / 大規模 scope 拡張で必須引数欠落)](../../raw/reviews/20260427T021251Z-pr-688.md)
- [PR #688 cycle 36 fix (self-referential learned 節 chain 完全修復 + 累積 14 回目 38+ cycle)](../../raw/fixes/20260427T155947Z-pr-688.md)
- [PR #688 cycle 12 review (DRY 集約 overstate / migration 取り残し HIGH × 1 + MEDIUM × 3)](../../raw/reviews/20260428T105854Z-pr-688.md)
- [PR #688 cycle 14 review (prose ↔ code 不整合 / Form A 非対称 / sanitize 非対称)](../../raw/reviews/20260428T122927Z-pr-688.md)
- [PR #688 cycle 14 review re-iteration (Self-referential learned 節 chain HIGH × 2)](../../raw/reviews/20260428T151033Z-pr-688.md)
- [PR #688 cycle 12 fix (HIGH 1 + MEDIUM 3 + LOW 3 を全修正)](../../raw/fixes/20260428T111028Z-pr-688.md)
- [PR #688 cycle 14 fix (prose-code 整合 + DRY claim 訂正 + Form A 統一 + sanitize 対称化)](../../raw/fixes/20260428T123811Z-pr-688.md)
- [PR #688 cycle 15 fix (cycle 14 → 15 self-referential drift chain 完全修復)](../../raw/fixes/20260428T153020Z-pr-688.md)
- [PR #688 cycle 49 review (1 CRITICAL Self-defeating defense + 2 HIGH 片肺 + 7 MEDIUM)](../../raw/reviews/20260430T005759Z-pr-688.md)
- [PR #688 cycle 14 review (8 finding patterns / DRY claim file 自身の partial DRY)](../../raw/reviews/20260429T092812Z-pr-688.md)
- [PR #753 cycle 3 review (3 HIGH all comment-quality fix-introduced drift)](../../raw/reviews/20260430T123230Z-pr-753.md)
- [PR #753 cycle 4 review (1 HIGH + 1 MEDIUM, test file blind spot 初検出)](../../raw/reviews/20260430T125141Z-pr-753.md)
- [PR #753 cycle 5 review (mergeable, 0 findings — full convergence 確認)](../../raw/reviews/20260430T130829Z-pr-753-cycle5.md)
- [PR #753 cycle 3 fix (3 HIGH comment-quality SoT 原則 2/3 違反修正)](../../raw/fixes/20260430T123646Z-pr-753.md)
- [PR #753 cycle 4 fix (test file blind spot 修正: line ref → semantic anchor + dead local 削除)](../../raw/fixes/20260430T125524Z-pr-753.md)
- [PR #754 cycle 1 review (state-read.test.sh retrofit / Comment Rot CRITICAL + anchor specificity HIGH×2)](../../raw/reviews/20260430T141522Z-pr-754.md)
- [PR #754 cycle 4 review (mergeable, 0 findings — fractal drift 収束宣言)](../../raw/reviews/20260430T192119Z-pr-754.md)
- [PR #754 cycle 1-3 fix (anchor specificity retreat doctrine 採用で literal anchor existence 問題を構造的解消)](../../raw/fixes/20260430T141940Z-pr-754.md)
- [PR #754 cycle 2 fix (broken cross-reference を `(Cycle 別の主要な修正)` 総称形に retreat)](../../raw/fixes/20260430T143329Z-pr-754.md)
- [PR #754 cycle 3 fix (`Form A vs Form B` 矛盾 + `cleanup helper 集約` literal 不在を Doctrines / Principles 総称形に retreat、4 cycle 収束)](../../raw/fixes/20260430T191751Z-pr-754.md)
- [PR #765 cycle 1 review (累積 / 3-site bang-backtick adjacency CRITICAL × 3 + Doc precision regression initial seeding)](../../raw/reviews/20260502T095733Z-pr-765.md)
- [PR #765 cycle 1 fix (b299899: backtick → single-quote 3 site 同期、cycle 2 で fix 自身が 6 件導入)](../../raw/fixes/20260502T101035Z-pr-765.md)
- [PR #765 cycle 2 review (cycle 1 fix が新規 4 MEDIUM + 2 LOW を導入する fractal pattern 実測)](../../raw/reviews/20260502T103134Z-pr-765-cycle2.md)
- [PR #1004 cycle 2 review (累積 32 回目 / CRITICAL 2 + HIGH 7 / F-01 fix syntax error self-application)](../../raw/reviews/20260517T000446Z-pr-1004.md)
- [PR #1004 cycle 3 review (4 軸混在 anti-pattern / Self-violation × N-site × observability × no_journal_comment)](../../raw/reviews/20260517T004634Z-pr-1004.md)
- [PR #1004 cycle 3 fix (8 件本 PR fix + 3 件別 Issue 化 scope-creep gate)](../../raw/fixes/20260517T020335Z-pr-1004.md)
- [PR #1166 cycle 14 review (CHANGELOG enforcement-locus stale → 修正で新誤認導入)](../../raw/reviews/20260528T055956Z-pr-1166.md)
- [PR #1166 cycle 15 review (fix-over-correction: enforcement 主体取り違え)](../../raw/reviews/20260528T060938Z-pr-1166.md)
- [PR #1166 cycle 15 fix (over-correction 再訂正 / 3 層 enforcement locus 区別)](../../raw/fixes/20260528T061125Z-pr-1166.md)

## 累積 17 回目の state-read.test.sh retrofit (4 cycle 収束) で観測した sub-pattern: anchor specificity retreat doctrine

state-read.test.sh の journal-style コメント retrofit で 4 サイクル要した anchor 関連 finding chain。cycle 1 で `Form A vs Form B` Comment Rot CRITICAL + bare anchor specificity 不足 HIGH × 2 を fix → cycle 2 で fix 自身が `L46` self-line reference drift を導入 + descriptions が evolution.md に literal 0 件 (broken cross-reference) → cycle 3 で fix が `Form A cleanup minimal contract` 参照 (Form B 実装と矛盾) と `cleanup helper 集約` (literal 不在) を導入 → cycle 4 で「総称形 retreat」doctrine 採用により 0 findings 収束 (`(Cycle 別の主要な修正)` / `(Doctrines / Principles)`)。

**収束のキー**: anchor description は **section 総称形まで** retreat する。fine-grained descriptions は参照先 literal の存在検証が漏れるたびに silent drift 源となる。当該 Issue の Non-goal で evolution.md 改修禁止だったため retreat 方向のみが安全。本事例は cycle 17 累積対策 PR で observed Wiki 経験則「Test pin protection theater」「Mutation testing で test の真正性 empirical 検証」と接続し、test ファイル retrofit 系 PR の **anchor 設計指針** として記録。

## bang-backtick-check 二段ガード昇格で観測した sub-pattern: Self-violation cascade と Doc precision regression の chain (2 cycle, 20 → 20 open)

bang-backtick 二段ガード昇格 PR (`/rite:lint` 経由のみで発火する bang-backtick 検出を PostToolUse hook + PR/Ready 前段 hard gate の二段ガードへ昇格する累積対策) の review-fix loop で、**cycle 1 fix 自身が予防対象パターンを self-violation する meta-self-inconsistency** が顕在化した実測例:

### Cycle trajectory (findings 数)

| cycle | open | 内訳 |
|-------|------|------|
| 1 | 20 | CRITICAL 3 + HIGH 6 + MEDIUM 6 + LOW-MEDIUM 4 + LOW 1 |
| 2 | 20 | HIGH 3 (cycle 1 carry-over) + MEDIUM 11 (carry-over 7 + NEW 4) + LOW-MEDIUM 4 + LOW 2 (carry-over 1 + NEW 1) |

cycle 1 で CRITICAL 3 + HIGH 6 = 9 件解消したが、cycle 1 fix commit `b299899` 自身が新規 4 MEDIUM + 2 LOW = 6 件の **fix-induced drift** を導入し、cycle 2 で MEDIUM 11 / LOW 2 として initial detection された。

### CRITICAL × 3 site Self-violation pattern (3 reviewer 独立検出)

本 PR の予防対象は「bash の double-quoted string 内に literal `` `!` `` 隣接 backtick が混入することで parser が command substitution として subshell 実行を試み silent regression を起こすパターン」。ところが対策コード自身 (3 site = `commands/pr/create.md` Phase 1.0 + `commands/pr/ready.md` Phase 1.0 + `hooks/scripts/bang-backtick-edit-hook.sh`) が同形 defect を初期 commit に含んでいた。**5 reviewer 並列レビュー (prompt-engineer / code-quality / devops / test / error-handling) でも初期 commit を通過した**。詳細は [asymmetric-fix-transcription.md](./asymmetric-fix-transcription.md#inverse-failure-defect-transcription--drift-check-anchor-射程外への同形混入-pr-765-累積-17-回目での-evidence) Inverse failure 節を参照。

### Doc precision regression cascade (新 sub-pattern)

cycle 1 fix で訂正した「`BANG_BACKTICK_CHECK_INVOCATION_FAILED=1` sentinel が Phase 5.4.4.1 grep canonical token と format 乖離している」HIGH F-04/F-05 doc drift について、**cycle 2 で再び新規 precision regression を導入**:

- cycle 1 fix doc: 「format mismatch を明記し option A (doc 訂正で実装と整合) を採用」
- cycle 2 reviewer 検出 F-21 (MEDIUM): cycle 1 訂正の prose は「Phase 5.4.4.1 で no-pattern emit」を主張するが、実装に no-pattern 具象 codepath が**存在しない** (start.md に該当 code path なし)

cycle 1 で正しく整合させた doc が、訂正過程の prose で**新たな precision regression を導入する fractal pattern**。これは [prose-design-without-backing-implementation.md](./prose-design-without-backing-implementation.md) の sub-pattern としても投影でき、累積対策 PR の review-fix loop における「fix doc が新たな drift 源になる」連鎖の定型として観測された。

### Cycle 2 NEW finding 4 件の根本原因分類

| ID | severity | 分類 | 根本原因 |
|----|----------|------|----------|
| F-21 | MEDIUM | Doc precision regression | cycle 1 訂正 prose が新たな specificity drift を導入 |
| F-22 | MEDIUM | Style B literal 3 site 不整合 | DRIFT-CHECK ANCHOR 射程外 hook の literal が canonical (`bang-backtick-check.sh:69`) から逸脱 |
| F-23 | MEDIUM | 散文長文構造 drift | 4 em-dash + 168-word sentence、sibling pattern (3-4 sentence 分割) と divergence |
| F-24 | MEDIUM | Scope filter glob asymmetric | `agents/` depth 2 vs 他 depth 3 の intent 表現 drift (実害なし) |

**学習**: 累積対策 PR で 1 cycle に 6+ files の cross-cutting fix を行うと、各 site での micro-pattern (literal 文字列・散文構造・glob depth) drift を cycle 1 単独ではすべて検出できない。cycle 2 reviewer で fact-check rerun ([Anti-Degradation Guardrail](../heuristics/reviewer-scope-antidegradation.md)) を必須化することで NEW finding を初検出する canonical 経路。

### Canonical 対策の追加

1. **Self-application gate を fix commit 前に必須化**: 本 PR の場合 `bang-backtick-check.sh --all` を fix commit 前に self-grep し、対策コードが予防対象を踏んでいないか mechanical 検証。新 lint rule 追加 PR の self-violation gate と同型 ([fix-comment-self-drift.md](./fix-comment-self-drift.md) と相補)
2. **Doc 訂正は prose precision を再 grep verify**: cycle 内で doc を訂正する fix では訂正後の prose に対して再度 sentinel format / code path existence の grep verify を必須化 (precision regression cascade 防止)
3. **DRY 集約助手による 3 site 重複の構造的廃止**: bang-backtick 二段ガード昇格 PR の lessons learned にある `bang-backtick-check.sh --print-action-hint` 提案 (3 site Style A/B literal を 1 source of truth に集約) を follow-up Issue として継承

## 累積 27 回目（1 cycle 0 findings 収束）— 構造的予防 PR の successful application 実例

直前 PR の cycle 2 で deferred された MEDIUM 2 + LOW 2 = 4 件の対称化整理 follow-up は **canonical 予防策の successful application 実例として 1 cycle 0 findings で収束**。これまでの累積エントリは「fix 自体が drift を導入する failure mode」を記録してきたが、本 PR は対照的に「**構造的予防 fix が drift 経路を構造的に閉塞する success case**」を記録する。

### Cycle trajectory

```
cycle 1 (0 findings, 3 reviewer 全員「マージ可」合意) → mergeable
```

3 reviewer (prompt-engineer / test / code-quality) の独立並列レビューで全員「評価: 可 / 指摘事項: 0 件」、推奨事項 6 件はすべて scope-out（follow-up Issue として切り出し）。

### 直接の予防対象 — RESUME_HINT SoT 化 PR の cycle 1 fix が生成した drift

RESUME_HINT SoT 化の cycle 1 fix で `### Branch I/II` 見出しを追加した結果、後続行が 6 行 shift し、`caller-markdown-block.test.sh` 内 6 箇所と `pre-condition-gate.md:150` 1 箇所の合計 7 箇所の `line 114` hardcoded reference が silent stale 化した。これは本ページの「累積対策 PR の review-fix loop で fix 自体が drift を導入する」の典型例。cycle 2 で reviewer 全員 mergeable 合意した上で MEDIUM 2 + LOW 2 として deferred され、follow-up Issue へ切り出された。

### 新 sub-pattern: section-relative reference replacement = 構造的予防の canonical pattern

本 PR の MEDIUM-1 対応は hardcoded 行番号 (`line 114` / `line 55` / `line 69`) を section-relative 参照 (`§Enforcement note Branch II 項目 3 prose backtick`) に置換したもの。これは [`drift-check-anchor-semantic-name.md`](../patterns/drift-check-anchor-semantic-name.md) の「DRIFT-CHECK ANCHOR は semantic name 参照で記述する」原則を test ファイル内コメントへ拡張適用した実例で、**「test ファイルのコメント自身の drift」を構造的に予防する** 正しい方向性として確立。

加えて Wiki 経験則 [Asymmetric Fix Transcription](./asymmetric-fix-transcription.md) に従い、Issue 記載 6 箇所に加えて grep で発見した line 283 (Issue で undercount) と line 286 内の他 line number 参照 (line 55 / 69) も同時に section-relative 化することで、対称性を担保した。

### MEDIUM-2 contract addition による future failure mode の予防

本 PR の MEDIUM-2 対応は `pre-condition-gate.md` "Branch I / II 共通の不変条件" セクションに「RESUME_HINT 本文に literal backtick / double-quote を含めない」契約を追加。これは `extract_resume_hint_body` の `[^"\`]*` 否定文字クラスが本文の途中で切れて drift 検出が誤判定する future failure mode を future-proof 化する **predictive prevention**。具体的な incident は未発生だが、正規表現の構造から導かれる潜在的 failure mode を contract として明示化することで、将来の変更時に reviewer / 著者が衝突を検出可能にする。

### 累積 27 回目の successful prevention case が示す convergence 信号

累積 26 回目 cycle 1 で `cycle [0-9]+` space-only regex の hyphen 形 `prompt-engineer cycle-N` 取りこぼしが MEDIUM finding として surface した直近実例があるが、**累積 27 回目はそれと対照的に「予防策が機能した successful case」**。累積対策 PR が必ずしも「fix 自体が drift を導入する」failure mode に陥るわけではなく、構造的予防 (section-relative / contract addition) が適切に適用された場合は **1 cycle 0 findings で収束する** ことを示す empirical evidence。

### Canonical 観察への追加

本ページの 4 quality signal に加え、累積 27 回目から **「successful prevention case の signal」** を追加:

| 追加 signal | 観測 | 解釈 |
|-----------|------|------|
| 1 cycle 0 findings 収束 + 推奨事項 N 件 scope-out | 累積対策 PR で全 reviewer 即時 mergeable 合意 + scope-out 推奨事項のみ | 構造的予防策が機能している indicator。「fix 自体が drift を導入する」failure mode から離脱した signal として記録し、収束した予防パターンの canonical 化を進める |

**本ページに記録する意義**: 累積対策 PR の failure mode を観察するだけでなく、success case も同じページに記録することで「**予防策が機能した実例の累積**」を蓄積し、将来の累積対策 PR で参照可能な canonical pattern として活用する。

### 累積 28 回目（1 cycle 0 findings 収束）— successful prevention pattern の連続再現

累積 27 回目の review で 3 reviewer が独立指摘した 4 件の LOW recommendation 対称化 follow-up は **累積 27 回目の successful prevention pattern を連続再現** し、1 cycle 0 findings で収束。2 reviewer (prompt-engineer / test) の独立並列レビューで両者「マージ可 / 指摘事項: 0 件」、推奨事項 2 件は scope-irrelevant (bullet 分割提案 / 集約 declare 変数数の将来監視) として scope-out。

#### Cycle trajectory

```
cycle 1 (0 findings, 2 reviewer 全員「マージ可」合意) → mergeable
```

#### 連続再現が示す convergence robustness

累積 27 回目が「構造的予防 PR の successful application 実例」を初めて記録したのに対し、累積 28 回目はその直接の follow-up として「**deferred LOW 対称化 follow-up でも同じ 1 cycle 0 findings 収束を再現する**」ことを実証。「構造的予防 PR の successful prevention pattern」が以下の 2 ケースで連続再現したことから、convergence signal の robustness が増した:

| 累積回数 | 対象 | findings | reviewer 合意 |
|---------|------|---------|-------------|
| 27 回目 | RESUME_HINT SoT 化 PR の cycle 2 で deferred された MEDIUM 2 + LOW 2 = 4 件 | 0 | 3 reviewer 全員 mergeable |
| 28 回目 | 27 回目の review で 3 reviewer 独立指摘の LOW 4 件 | 0 | 2 reviewer 全員 mergeable |
| 29 回目 | 4-site scope drift (Issue 本文 line 番号明示 + 機械検証 step) | 0 | 1 cycle 0 findings |
| 30 回目 | Strict-mode caller variant subsection + test pin (3 assertion) | 0 | 4 reviewer 全員 mergeable |
| 31 回目 | TC-11 truthy variant matrix 追加 (cycle 1 で 4 findings → cycle 2 で 0 findings) | 0 (cycle 2) | 2 reviewer 全員 mergeable |

#### Pattern doctrine の連続再現データ

「構造的予防 PR の successful prevention pattern」が **累積 27 回目以降の 5 PR 連続で empirical 確認**。これは bang-backtick 二段ガード昇格 PR で観測された「Self-violation cascade と Doc precision regression chain」(2 cycle 20→20 open) と対照的で、**section-relative reference replacement / contract addition / minimal-scope assertion 統合 declare / Issue 本文 line 番号明示 + 機械検証 step / 新規 subsection + test pin / 兄弟 test 対称化 (TC-7 ↔ TC-11)** といった構造的予防策が累積対策 PR の review-fix loop fractal pattern から構造的に離脱する条件を示唆。

#### Successful prevention case の signal 拡張

累積 27 回目で追加した「1 cycle 0 findings 収束 + 推奨事項 N 件 scope-out」signal、累積 28 回目で拡張した「直前 PR で deferred された scope-out 推奨事項を follow-up PR で対称化整理した case で連続再現する」signal、累積 29 回目 → 30 回目の「Issue 本文 line 番号明示 + 機械検証 step」design の連続 reproducibility に加え、**累積 31 回目から「self-application 経路でも 2 cycle で収束する」** signal を追加。Wiki 経験則を蓄積した repository で test 追加 PR がまさに本 anti-pattern (Asymmetric Fix Transcription の片肺 5 variants) を踏んだが、cycle 1 review で 2 reviewer が独立検出 → cycle 1 fix で 7 variants 完全対称化 → cycle 2 で reviewer 独立 verify による 0 finding 収束、と review-fix loop が **適用された経験則の independent verification として機能** した。これは「累積対策で蓄積した経験則は wiki 内記述だけでなく review-fix loop の自動運用ガード機構として機能している」ことを示す empirical evidence。

### Projects Status In Review 遷移漏れの多層観測防御（累積 32 回目、3 cycle 収束）— Self-violation cascade × DRY 4-site × observability gap × no_journal_comment self-violation の 4 軸混在

累積 32 回目の対策 PR (PR Ready 後の Projects Status In Review 遷移漏れ — compaction / session 分断時 — への対策) は、cycle 1 (7) → cycle 2 (15) → cycle 3 (11) → cycle 4 (0) の縮小収束。本ページの「fix 自体が drift を導入する」failure mode が **4 軸混在の高密度** で同時 surface した実例として記録:

```
cycle 1 (7) → cycle 2 (15: CRITICAL 2 + HIGH 7 + MEDIUM 4 + LOW 2) → cycle 3 (11: HIGH 3 + MEDIUM 2 + LOW-MEDIUM 5 + LOW 1) → cycle 4 (0 mergeable)
```

#### Cycle 2 で 3 reviewer 独立検出された CRITICAL self-application

cycle 1 で F-01 として「`if grep ... || true` dead control flow 削除」を実施したが、外側 `if` を簡素化する際に **内側のネスト構造を見直さず余剰 `fi` を残した**。`bash -n` で exit 2 となり全 block 実行不能。prompt-engineer / code-quality / error-handling の 3 reviewer が独立に CRITICAL 検出。これは Failure mode 1 (fix-introduced regression 6 連続) の 32 回目再演で、「F-01 fix 自身がレビュー指摘を導入する」self-application パターン。

#### Cycle 3 で観測された 4 軸混在 anti-pattern

cycle 3 で 11 findings 検出された内訳:

| F-ID | severity | 軸 | 内容 |
|------|----------|----|------|
| F-01 | HIGH | Self-violation × silent skip | start.md/start-finalize.md の `{owner}/{repo}` retrieval phase 不在 → AC-8 core 検知が silent skip と機能等価 (本 PR が予防対象とする pattern を本 PR 自身が踏む) |
| F-02 | HIGH (2 reviewer 独立検出) | Canonical list drift | workflow-incident-emit.sh header docstring が新規 2 type 未同期 (canonical 一覧 line 80 case allowlist と line 82 error message と drift) |
| F-03 | HIGH | Self-violation × N-site contract | watchdog-status-mismatch.sh が他 3-site (post-compact.sh / start.md / start-finalize.md) に厳格適用している `mktemp + 4-signal trap (EXIT/INT/TERM/HUP)` 契約を遵守せず |
| F-04 | MEDIUM | no_journal_comment self-violation | start-finalize.md Step 0 bash コメントに F-NN journal comment 5 箇所残留 → 7f53366c で確立した no_journal_comment 違反 |
| F-05 | MEDIUM | DRY twin/N-site | GraphQL query + jq filter が 4 site 22 行ずつ複製 |
| F-08〜F-10 | LOW-MEDIUM × 3 | Observability gap | stderr suppress / pipefail dominant exit / cd failure silent (詳細: [Embedded markdown bash block の observability 三要素](../patterns/embedded-bash-block-observability-trio.md)) |

#### 4 軸混在の構造的意味

「Self-violation cascade」「N-site canonical sync 不全」「stderr root cause attribution gap」「no_journal_comment self-violation」が **1 cycle で同時 surface** したのは累積 32 回目で初。これは本ページ「累積対策 PR の防衛文言は数 cycle で意味を失う」signal（累積 14 回目の最終 cycle で記録）と接続: 31 回目までの累積で蓄積した予防文言が膨張し、新 PR を書く際の review attention が分散して**個別の予防パターンを self-application 経路で踏みやすくなる**。

**Cycle 3 fix で確立した 3 件別 Issue 化 (scope-creep gate)**:

cycle 3 fix で 11 件中 8 件を本 PR で fix、refactor scope の 3 件 (`#1005` / `#1006` / `#1007`) を別 Issue 化。これは [`rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する](../heuristics/scope-creep-rejection-empirical-gate.md) を適用した実例で、4 軸混在の高密度修正でも scope-creep gate が機能した。

#### Failure mode 5 (新規記録): Self-violation cascade × N-site × observability の 4 軸高密度混在

累積 32 回目の観察から、本ページの failure mode 群に追加:

| 追加 failure mode | 観測 | 累積回数で初観測 | escalate 先 |
|-----------------|------|-----------------|------------|
| 4 軸高密度混在 (Self-violation × N-site sync × observability × no_journal_comment) | 1 cycle で 4 軸の anti-pattern が同時 surface | 32 回目 (cycle 3) | (a) 累積予防文言の SoT 集約による attention focus 回復、(b) 累積 N 回目 PR では cycle 1 review で 4 軸チェックリストを mandatory step として組み込む、(c) `bash -n` self-application gate を fix commit 前に必須化 ([fix-comment-self-drift.md](./fix-comment-self-drift.md) と相補) |

#### 累積 32 回目 cycle 3 fix で確立した stderr root cause attribution パターン

cycle 3 fix で start.md Step 1.5 / start-finalize.md Step 0 が `gh` と `jq` の stderr を独立 tempfile に分離し pipeline 失敗時の details に `gh_stderr=` と `jq_stderr=` を併記する canonical 実装を導入。これは observability gap (F-08/F-09/F-10) の 3 件を構造的に解消する正しい方向性で、[Embedded markdown bash block の observability 三要素](../patterns/embedded-bash-block-observability-trio.md) として独立ページに切り出した。

### 累積 35 回目相当 — Self-violation cascade 連続 3 回再発 と「完全削除」戦略への転換

当該 PR は aggregate-recommendation-label-evasion anti-pattern を解消する meta-PR でありながら、対策コード自身が Self-violation cascade を **連続 3 回再発** させた 4 cycle 構造的収束事例。本ページの bang-backtick 二段ガード昇格 PR における Self-violation cascade 観察の延長線上で「累積対策 PR が解決対象の anti-pattern を fix 自身で再現する」cascade chain の最長記録更新。

#### Convergence pattern (shrinking-cycle)

全 findings 集計では `18 → 14 → 4 → 0`、CRITICAL+HIGH のみで `7 → 3 → 2 → 0` の 4 cycle 収束。cycle 1-3 では各 cycle の fix が次 cycle で同型 anti-pattern として再検出される [Recursive Recurrence in Fix Layer](./asymmetric-fix-transcription.md) が連続発火、cycle 4 で構造的解消戦略への転換により即座に 0 finding 収束。

| Cycle | Strategy | Reviewer 検出 | Failure mode |
|-------|----------|---------------|------------|
| 1 → 2 | 「混同回避規約」を立てた同 commit が同章内で 4 ヶ所違反 | Asymmetric Fix Transcription 8 箇所 drift / Sentinel Visibility Rule violation (CRITICAL: `${candidate_count}` 未定義 + sentinel iteration_id 欠落) | Strategy A 採用直後 self-violation |
| 2 → 3 | F-15 factually false claim 修正 + F-02 二重定義「部分解消」 | さらに新規 false claim 導入 + 二重定義の subset 解消にとどまる | Partial fix 再帰再発 |
| 3 → 4 | Legacy field 完全削除 + disambiguation note 簡素化への**構造的解消戦略**転換 | 0 findings | Structural closure achieved |

#### Failure mode 6 (新規記録): Self-violation cascade × Recursive Recurrence × Self-meta drift 4 軸並行発火

累積 35 回目相当の観察から、本ページの failure mode 群に追加:

| 追加 failure mode | 観測 | 累積回数で初観測 | escalate 先 |
|-----------------|------|-----------------|------------|
| Self-violation cascade 連続 3 回再発 + 「deprecate + 残置」戦略の限界 | 1 PR 内で Self-violation cascade × Recursive Recurrence in Fix Layer × Sentinel Visibility Rule violation × Self-meta drift (legacy field vs 新 field の semantic 不一致) の 4 軸が並行発火、cycle 1-3 で連続再発、cycle 4 で「legacy 完全削除 + disambiguation note 簡素化」の構造的閉塞戦略への転換が必要 | 累積 35 回目相当 (cycle 1-4) | (a) cycle 3 で同型 finding 再発時に「deprecate → delete」への戦略転換を AskUserQuestion で提案、(b) Legacy field 温存戦略採用時の移行計画 (deletion target cycle / deletion PR Issue 番号) を本文に明記、(c) 詳細は [Legacy field の「deprecate + 残置」よりも「完全削除」が構造的閉塞を実現する](../heuristics/complete-deletion-over-deprecation-for-structural-closure.md) を参照 |

#### Dogfooding evidence — Mechanical gate の必要性を逆説的に実証

累積 35 回目相当の PR は `/rite:pr:review` Phase 7 の AskUserQuestion 起動を **prose enforcement only から mechanical gate に強化** する meta-PR でもあった。cycle 1-3 で「deprecate + 残置」戦略により self-violation cascade を 3 回連続で踏んだ実測は、本 PR の前提仮定 ("prose enforcement only では silent skip が必ず発生する") を逆説的に裏付ける dogfooding 観察となった。**累積対策 PR が解決対象の anti-pattern を fix 自身で再現する経験は、その mechanical gate の必要性の最も強い証拠** である。本観察は本ページの canonical 対策 4 施策 (3 点セット / twin site / sibling symmetry / opt-in flag) に「**5. 構造的閉塞戦略 (= 対称化対象そのものを消滅させる)**」を 5 つ目の canonical mitigation として追加する根拠を提供する。

### Doc-Heavy investigation PR（8 cycle 完全収束）— fractal pattern の Doc-Heavy 系での再現と「systemic 一斉対応」収束

調査レポート 1 ファイル +238/-0 の Doc-Heavy PR は累積 44 回目相当の Doc-Heavy 軸で **8 cycle 完全収束 (累計 11 件 → 0)** を達成。本ページの fractal pattern が code PR ではなく **documentation 系 PR でも同型再現** することと、cycle 5 の **systemic 一斉対応** が収束を加速する canonical 戦略を実証。

#### Convergence trajectory (shrinking + spike + decay)

```
cycle 1 (5: HIGH×1 + MEDIUM×1 + LOW×3 auto-demoted)
  → cycle 2 (1 fix-introduced regression、auto_demote_low override で fix 決定)
    → cycle 3 (2: MEDIUM×1 + LOW-MEDIUM×1、再 review 深掘りで past LOW 復活)
      → cycle 4 (3: MEDIUM×1 + LOW-MEDIUM×1 + LOW×1、L62-70 line ref 4 件が systemic 化)
        → cycle 5 (7 件 mass fix: line ref 統一・行数実値化・セクション補完・symmetric qualifier)
          → cycle 6 (1: LOW-MEDIUM 末端 nit 1 件、commit date drift)
            → cycle 7 (1 件 fix、1 文字修正のみ)
              → cycle 8 (0 件、両 reviewer mergeable)
```

#### Failure mode 7 (新規記録): Parent vs sub-section SoT 同期見落とし (Doc-Heavy 軸)

cycle 2 で検出された fix-introduced regression は、cycle 1 fix で Markdown table の cell 値を SoT と同期させる修正中、SoT 表 (`default.md:33-47`) を「sub-section 行のみ」で完結させ **parent 行 (line 37) を読み飛ばした** ことで発生。Parent 行は全 Complexity で M 固定だが、sub-section 4.1-4.5 で初めて S/O が分岐する 2 段構造。memory ベースで sub-section 値を集約推測した結果の precision drift。

**canonical 対策**: Markdown table の cell 値を SoT と同期させる修正では、**SoT の全 row を Read で表全体として scan** する義務がある。parent vs sub-section の意味論を SoT の structure (どの行が parent でどの行が children か) で確認する。[Asymmetric Fix Transcription](./asymmetric-fix-transcription.md) の発展形 — 「fix した部分のみで判断せず、SoT 表全体の構造的関係を Read で視野に入れる」。

#### Failure mode 8: 「孤立 nit」の systemic 化 (cycle 3 → cycle 4 → cycle 5 一斉対応)

cycle 3 で R-3 (L70 :277-284 → 実 278) **単独 nit** として nit-noted 扱いだった issue が、cycle 4 で reviewer が L62-70 範囲を再 scan した結果 **4 件の同型 drift** に拡張 → cycle 5 で全 10 件を heading line に統一する **mass fix** で systemic 化を構造的解消。「孤立 nit」が cycle 跨ぎで systemic finding に格上げされる pattern が Doc-Heavy 軸で実測。

**canonical 対策**: 「孤立 nit」を cycle N で nit-noted にする際、reviewer が cycle N+1 で同型 pattern を grep verify する step を inline する。systemic 化が確認されたら **一斉修正 (mass fix)** で cycle 内 ad-hoc 修正の累積を避ける。

#### Failure mode 9: auto_demote_low policy override 判断基準の明示化

`rite-config.yml` の `review.scope_assignment.auto_demote_low: true` 設定下では LOW × current-pr は機械的に nit-noted へ降格されるが、累積 44 回目相当 cycle 2 で以下 **2 条件のいずれかに該当する場合は policy override で proper fix を選ぶ** 正当な経路が canonical 化された:

| Override 条件 | 根拠 |
|--------------|------|
| **cycle N で自分が混入させた precision drift** | reply-only で受け流すと PR レポートの信頼性が失われ調査結果が価値を失う |
| **PR の主要成果物 (本件は AC-2 差分表) の正確性に直接影響** | informational nature の PR で deliverable の正確性は mergeability 以上の優先度を持つ |

cycle 1 で auto_demote_low が dogfooding の現実的な blocking 件数を **5 → 2 に削減** した観測値も併せて記録。

#### 「systemic 一斉対応」収束戦略 (cycle 5)

cycle 5 fix では以下 4 軸の一斉対応で 7 件を 1 commit で landing:

1. **line ref 統一**: 10 件の line 番号引用を heading line に統一 (off-by-1 drift を mass fix で解消)
2. **行数実値化**: factual claim (700 行 → 実 576 行 22% drift) を `wc -l` 実測で訂正
3. **セクション補完**: AC-1 集計表で hedged label による表記揺れ吸収 (集計の意味論を破壊せず情報量を維持)
4. **symmetric qualifier 統一**: cycle 3 で「6 セクション inline 形式」列のみに qualifier 追加 → cycle 4 で IC 形式列の symmetric drift 指摘 → cycle 5 で両列に symmetric qualifier 統一 (asymmetric fix transcription pattern の累積対策完了)

**Lesson**: 累積対策 PR で fractal pattern が systemic 化したら、ad-hoc 単発修正ではなく **同型 pattern を 1 commit で mass fix** することで cycle 数を短縮できる。本 PR では cycle 4 → cycle 5 の transition でこの戦略を採用し、cycle 6-8 の収束相に到達。

#### Doc-Heavy mode 5 カテゴリ verification protocol の有効性

累積 44 回目相当の PR は tech-writer reviewer の Doc-Heavy mode (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) と code-quality reviewer の fenced block detection の **2 reviewer 体制** で cross-validation が機能。F-A2 (L62-70 line ref) を tech-writer (recommendation 1) と code-quality (LOW-MEDIUM finding) が独立検出した実例が、Doc-Heavy + fenced block の 2 reviewer 体制の effectiveness を実証 ([`docs-review-implementation-grep-verification.md`](../heuristics/docs-review-implementation-grep-verification.md) と相補)。

cycle 8 の完全収束時には reviewer が **「真に finding がないときに何か挙げないと bias」を抑制し、0 件 = 正常終了を恐れない姿勢が loop 永久化を回避** と明言。詳細は [0 件 finding = 正常終了として受容する (false-positive 回避義務)](../heuristics/reviewer-zero-finding-as-legitimate-convergence.md) を参照。

## marker ライフサイクル gate 新設 (PR #2078, 5 cycle) — 「防御を足す修正が次の指摘面になる」を 2 度の方針転換で抜けた事例

### Cycle trajectory (blocking findings 数)

| cycle | blocking | 主な指摘の型 | fix 側の方針 |
|---|---|---|---|
| 1 | 13 | caller 由来 path が検証なしで複数用途へ流れる (sentinel 偽造 / traversal / errno) | guard を 3 枚重ねる → 受理判定を 1 箇所へ集約 |
| 2 | 14 | cycle 1 の guard 自体が CRITICAL 退行 (値域 wedge) | **方針転換 1**: guard 追加 → インタフェース差し替え |
| 3 | 10 | 差し替え後の dangling reference (診断文 / test pin / rationale) | シンボル削除の散文 grep を完了条件化 |
| 4 | — | 防御追加がまた指摘面に (consumer ゼロ marker / 閉じた列挙) | **方針転換 2**: 追加ではなく削除へ |
| 5 | 3 | 判定は直したが下流を辿っていない / 防御が測られていない | 述語の consumer を全数辿る + mutation 実測 |

### 本 PR に固有の型

**1. 「防御を足す」対応が 3 サイクル連続で新しい退行を生んだ。** cycle 1 の guard が cycle 2 の CRITICAL に、cycle 2 の対応が cycle 3 の dangling reference に、cycle 3 の対応が cycle 4 の consumer ゼロ marker になった。指摘への反射的な「層を足す」対応が drift の主要な供給源になっている。

**2. 同一箇所に複数サイクル指摘が出続けるときは、パッチではなくインタフェースを疑う。** 2 サイクルで出た 8 件はすべて「caller から full path を受け取る」という 1 つの選択に由来していた。sibling helper は同じ処理を「path を内部で導出する」形で解いており、その形に揃えた結果 guard 群ごと消えて net マイナスになった。詳細は [消費側だけに足した allowlist は生成側の値域と食い違い「成功しているのに永久に失敗」の非収束を作る](./consumer-allowlist-wedges-producer-value-range.md)。

**3. cycle 4 で自覚的に「追加ではなく削除」へ振ったが、cycle 5 でも同じ型が 3 件出た。** ただし型が変わっており、cycle 5 のものは「直したの範囲を実装の 1 点に限定し、その判定を読む側・測る側まで辿っていない」に収束していた。方針転換は drift の**種類**を変えるが、辿る範囲の不足という上位の型は残る。

**4. Simplification-First の実用的な読み替え。** 「追加を我慢する」ではなく「**原因の粒度で束ねる**」。同一ブロック由来の 3 指摘に個別 guard を足すと分岐が 3 本増えるが、受理判定を引数確定時の単一ゲートへ出すと分岐は 1 本で済む。

### 有効だった手続き

- **reviewer に mutation 実測を明示的に依頼する。** 静的 pin の抜け（assertion が届いていない防御）が定量的に出る。本 PR では `--pending-id` の allowlist と制御文字中和が、どちらを削除しても全 assertion green のままだった（既存 arm が case の brace 節で先に捕捉するため、allowlist 本体に assertion が 1 本も届いていなかった）。「N pass / 0 fail」は防御が測られている証拠にならない。
- **削除と追加が同居する diff は lint clean を完了の証明にしない。** 説明的 Issue 番号参照を一方のファイルから削除しながら、同じ diff で別ファイルに 2 件追加していた。pre-existing hit が多いファイルでは新規追加分が埋もれる。

### docs 是正 PR での 5 cycle 観測 — 書き換え単位・カウンタ・marker の 3 型

PR #2052（散文の形式反転）で、fix-induced drift が実装 PR とは異なる 3 つの型で反復した。いずれも「直した箇所の**隣**が旧契約のまま残る」構造を共有する。

**1. 書き換える単位は「文」ではなく「その主張が閉じる範囲」。** bullet の前半だけを新契約へ移し、直後の 2 文が旧契約のまま残る誤りが 4 レビュアーから独立に指摘された。しかもそれが operator 向けの remediation 文だったため、「永続する手当て」を明示的に否定して「非永続な手当て」を勧める状態になっていた。段落・bullet 単位で読み直してから書き換える。

**2. カウンタの配線は「定義・実行地点・表示・等式」の 4 点セット。** 3 点（カウンタ表・内訳・等式）に配線したサイクルの次で、**実行地点（中止時の報告手順）への加算指示が漏れていた**ことが判明した。しかもその手順は加算対象を明示列挙していたため、列挙が網羅的に読めて新カウンタは加算されない解釈になる。等式直後の説明文も未追随で、記述どおり自己検算すると新カウンタ分を「訂正」して落とす。総数 1 に対し内訳合計 0 という自己矛盾した出力が出る。

**3. 成功経路に marker が無いと「成功」と「未実行」が区別できない。** 中止経路にだけ marker を出す設計は marker 不在を両義にする。同じ表の別 marker が既に 3 値設計（`ok` / `failed` / 不在 = 未確認）だったため、非対称として検出された。さらに `=ok` marker の emit 点は「計算成功」ではなく **「副作用の完了」を attest させる**位置に置く必要がある — bash ブロック末尾で emit すると、その後に LLM が行う Edit を落としても「失敗なし」と報告される。移設するときは**副作用が no-op になる経路**（値が既に一致していて Edit が空振り）も同時に規定しないと、健全なサイクルが「未確認」に落ちる。

**4. 「なし」行の条件は marker 値で書き切る。** 「かつ統計中止なし」のような自然文の否定は marker **不在**のときも真になり、3 値設計が塞ごうとした「未確認を失敗なしと断定する」経路を復活させる。既定行の条件は `A=ok` / `A=skipped` **かつ** `B=ok` / `B=skipped` のように取りうる値を列挙する。

**5. 過剰反応を避けた対処。** 前サイクルの fix が導入した箇所への指摘 6 件を、分岐・条項の**追加**ではなく emit 点の移設 / gate の削除 / 述語の置換 / 到達不能分岐の畳み込みで解いた。追加パッチを重ねると、その追加自体が次サイクルの新たなレビュー対象面になり指摘を再生産する（本ページ「Simplification-First の実用的な読み替え」の docs 版）。


### N 回目のパッチは述語が proxy である信号（PR #2099 / Issue #2088）

5 サイクル回して blocking が `6 → 8 → 7 → 5 → 5` と横ばいのまま `max_review_cycles` の backstop で停止した PR。cycle 5 の blocking 5 件のうち 2 件は **cycle 4 の fix が直接生んだもの**、1 件は **cycle 4 が半分だけ塞いだ穴**だった。

cycle 4 は「pin 書込失敗時に stale pin を残さない」ために `rm -f` + WARNING + marker を追加した。cycle 5 はそこへ (a) `rm -f` 自体の失敗サブ経路で WARNING が矛盾する、(b) 構造的に同型の「counter reset 失敗 → pin 更新ゲートを通らない」経路が未処理、を返した。

ここで reset 失敗分岐に `rm -f` を複製するのが自然な反応だが、実際に効いたのは **ゲートの述語そのものの是正**だった。`cur_cc == 0` は「新しい run か」の proxy にすぎず、reset 失敗時に相関が切れる。`fresh || cur_cc == 0` の選言へ替えると経路 (b) はパッチ 1 行も足さずに消えた。詳細と判定手順は [同じ機構への N 回目のパッチは、その機構が依拠する述語が proxy である信号](../heuristics/nth-patch-signals-proxy-predicate.md) を参照。

**あわせて観測された「収束しているのに閉じない」構造**:

- 5 サイクルの blocking のうち、fix が直接生んだ指摘と伝播漏れ（語彙 4 種目）が毎サイクル一定数を占め、実質的な残件は減っているのに総数が横ばいに見えた
- 収束トレンド判定は最後まで `converging_or_descending`（発散していない）を返した。**止めたのは cycle 数の backstop であり、判定式ではない**
- 強いテストスイート（124 assertion / 実 fixture 回帰つき）でも、判定式の「窓の範囲」項・環境要因 guard・判定成立側の reason 2 値が未 pin だった。いずれも **mutation で実装を壊しても緑のまま**であることを実測して初めて発覚。assertion 数もカバー範囲の見た目も識別力の代理指標にならない

### 散文 PR に固有の伝播漏れ

- **同一ファイル内でも漏れる。** 形式反転の追随を 5 ファイルで行った次のサイクルで、(a) 同じファイルの別節、(b) 同じファイルの冒頭 Design notes、(c) 同じファイルの別テストケースのコメント が取り残された。**変更箇所から離れた場所は別ファイルと同じ確率で漏れる。** 伝播スキャンは旧形式の語による横断 grep だけでは足りず、(1) 語彙を複数用意する（日本語・英語・枠組み語）、(2) 触ったファイル自体を全文再読する、の 2 段が要る。
- **枠組み語の割れ。** 「未達（達成すべき目標に未到達）」と「意図的な逸脱（declared deviation）」は正反対の含意を持つ。参照元だけ書き換えると参照先が逆を言う。同義の枠組み語は先に 1 つ決めて全箇所へ機械適用する。
- **「A より前」の時間限定は A が初出のときにしか成立しない。** 形式を「復元」する変更で「A 化より前に初期化されたものは B のまま」と書くと、A が過去にも存在した窓を含んで偽になる。時間限定は「対象が実在した区間」で切る。自分が導入する限定句の真偽は、その限定が指す期間の git 履歴で裏取りする。
- **限定句はスコープと対で書く。** 冪等化のための限定を「両経路共通」の位置に書いたため、掛かるべきでない frontmatter 由来の値にも掛かり、前サイクルでは列崩れとして loud に露見していた壊れ方が silent 化した。
- **変換を新しい入力へ広げるときは冪等性を検査する。** エスケープ規約の適用対象に「既存行から保持した値」を足したが、保持値は前サイクルで既に変換済みだった。「値に X が含まれるなら Y にする」型の規約は、Y を含む値を再入力したときの挙動を明示しないと非冪等になり、サイクルごとにエスケープ文字が 1 つずつ増える。
- **サイクル単位のセマンティクスを per-item ループに置かない。** 全体の状態を前提にする手順を item ごとのループ本体に置くと、guard が評価不能・カウンタが N 倍・レポート行が N 行並ぶ。数え上げ不能な述語（「最後の N を処理したとき」）は既存カウンタとの照合（「処理済み件数が `n_raw_sources` に達したとき」）へ置換する。
- **同一の literal を 2 箇所に書かない。** 完了レポート行の literal を手順側と表側の両方に書くと、片方だけ直して drift する。表を SoT にして手順側はポインタにする。

### 機構の「配線状況」を散文で説明すると、説明を足すたびに誤りが入れ替わる（4 cycle 観測）

同一 invariant の実装が複数ファイルに散り、そのうち一部だけが条件付き gate を持つ構造では、「どこで誰が強制するか」を散文コメントに書こうとするたびに別の誤りが入る。実測は 3 サイクル連続:

- cycle 1: 「本述語の母集団に非実測 finding は入らない」→ 偽。gate 対象外の scope を持つ finding は降格されず配列に残る
- cycle 2: 「invariant #4 が write 側で禁止する」→ 偽。write 側の検査は schema 版 gate 配下にあり、実際に書かれる版では発火しない
- cycle 3: 「機械的阻止は新 schema 限定」→ 偽。read 側の 3 実装は schema 非依存で発火する（うち 1 つは当のコメントの 8 行下）

各サイクルの指摘はいずれも正しく、実測アンカー付きで再現も取れていた。誤りは「前回の訂正が触れなかった側」へ移動しただけで、精度は上がっていない。

**収束したのは、配線に関する主張自体を削除したとき。** 判定の可否に必要な事実（残る対象は 1 種類だけ / その組合せは invariant が禁じている / ゆえに本述語の判定対象に現れない）だけを残し、強制主体・強制箇所・違反時の捕捉経路をすべて落とした。

- **判定の可否に無関係な配線情報は書かない。** どこで誰が強制するかは、そのコードブロックの分岐に影響しない。書けば実装の版差・gate 条件・評価順序に依存する主張になり、それらが動くたびに陳腐化する
- **「後段の X が守る」型の根拠は評価順序に依存する。** 本件では参照先の elif が当該述語より後段にあり、違反入力は先に当該述語が捕らえていた。順序を根拠にすると、分岐を 1 つ挿入しただけで偽になる
- **訂正が 3 回続いたら、訂正の方向ではなく主張の粒度を疑う。** 「もっと正確に書く」ではなく「その主張は必要か」を先に問う。cycle 1-3 はすべて前者を試みて失敗した
- **副次: 逐語引用は書き換えで宙吊りになる。** 別ファイルが当該文言を逐語引用していたため、書き換えで存在しない文言への参照が残った。文言を引用する側は「同じ前提で書かれている」と述べる形にすると、引用元の表現変更で壊れない
- **副次: Issue 番号を追跡先として名指しした記述は、その Issue のスコープが名指し内容を含まないまま close されると宙吊りになる。** close 前に `#<番号>` の in-repo 参照を grep し、スコープ外の追跡先は別 Issue へ付け替える

### 実測アンカーの無い散文指摘は、修正の複製率が 1 を超えることがある（PR #2126, cycle 3→4）

上記は「同一主張の訂正が 3 サイクル続く」形だったが、PR #2126 では**別々の散文指摘を素直に直した結果、その修正自身が次サイクルの HIGH を 4 件生む**形が観測された。cycle 4 の reviewer の言葉がそのまま因果を示している — 「cycle 3 が追加した mandate 5 が…」「F-07 の修正で追加された例外が…」「Execution condition を拡張した一方で…」。

**なぜ散文で起きやすいか**: 手順書・仕様書は相互参照の網であり、1 箇所の条件を変えると、それを参照している側の条件・retry 手順・表示条件・テンプレート選択がすべて追随対象になる。そのどれかを漏らすと次サイクルの指摘になる。実測アンカーのある指摘は「壊れた成果物が観測できる」ので直せば終わるが、散文指摘は「2 つの記述が食い違う」ので直すと 3 つ目が食い違う。

具体例（cycle 3 の修正が cycle 4 に生んだもの）:

- 非実測の懸念（1 つの prompt に 2 つの diff baseline が届く）に対して mandate を 1 項追加 → その mandate が別の mandate（前回指摘の再掲）を revert test で機械的に破棄させる上位の欠陥を生んだ。cycle 4 では**パッチせず mandate ごと削除**して解決した（行数は減った）
- post-condition の実行条件を拡張 → その節の retry 手順・表示条件・retained flags 定義の 3 箇所が旧条件のまま残り、拡張した先に到達不能な手順が置かれた
- placeholder に例外を 1 つ追加 → 同じ状態に至る他 2 経路を救えず、例外の適格条件が不完全なまま残った

**どのレーンが blocking を生むかを測ってから労力を配る**: 同 PR の cycle 2〜4 を通じて、prompt-engineer / tech-writer レーンは実測 blocking を**ゼロ件**しか生んでいない（両者自身が「決定論的に観測不能」と申告）。一方 blocking はすべて実装コードとテストスイートから出た。散文レーンの指摘に価値が無いという意味ではなく、「mergeable への到達」という目的関数に対しては寄与しないということ。

**対処**:

1. 非実測（字面整合クラス）の散文指摘は、**実行時に主機能を打ち消すものだけを例外的に直す**（前文の identity 宣言、他 skill の handoff 実行時文字列など、記述どおり実行すると新機能が無効化されるもの）
2. 残りは Decision Log に**明示的に後続 Issue へ切り出す**と書く。「安いから直しておく」は収束を遠ざける
3. 直すと決めた散文修正は、**それが生む新しい参照面を同時に洗う**（変更した条件を参照している箇所を grep で数え上げる）
4. サイクルをまたいで同じ修正が指摘を生み続けるなら、パッチではなく**その機構ごと削除できないか**を先に問う
