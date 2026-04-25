---
title: "累積対策 PR の review-fix loop で fix 自体が drift を導入する"
domain: "anti-patterns"
created: "2026-04-21T10:35:00+00:00"
updated: "2026-04-25T17:50:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260421T024947Z-pr-636.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T030627Z-pr-636-cycle-2.md"
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
tags: ["review-loop", "cumulative-defense", "convergence", "quality-signal", "architectural-surface", "literal-syntax-validity", "anchor-prose-propagation", "self-meta-drift", "propagation-scan-pattern"]
confidence: high
---

# 累積対策 PR の review-fix loop で fix 自体が drift を導入する

## 概要

同種 regression への N 回目の累積対策 PR では、review-fix loop の各 cycle で適用した fix 自体が次 cycle の新規 drift を生む fractal pattern が顕在化する。PR #636 (Issue #634 = implicit stop regression の 8 回目対策) は 13 cycle 回って収束し、cycle 2 findings の 60% が cycle 1 fix 起因、cycle 3 で cycle 1-2 review では見えなかった architectural HIGH finding (`--preserve-error-count`) が初めて surface した。cycle 数による hard limit ではなく、quality signal (同一パターン反復 / dead marker 追加 / description-impl drift / architectural bug surface) による escalate 判断が canonical。

## 詳細

### 事象 — PR #636 での 13 cycle 収束軌跡 (findings 数)

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

### PR #654 (Issue #651) — 9 回目対策の 3 cycle 収束軌跡 (2026-04-24)

PR #636 (8 件目) と同型の累積対策 9 件目 PR で **本ページ自身を裏付ける self-exemplar** が再発した:

```
cycle 1 (10 findings: 1 CRIT + 1 HIGH + 4 MED + 4 LOW)
  → cycle 2 (3 LOW)
    → cycle 3 (0) mergeable
```

#### Cycle 1 の CRITICAL: literal として LLM に渡す bash の構文有効性 test 漏れ

declarative 9 件目で `caller HTML コメント内` に追加した bash literal `bash ... --preserve-error-count ; then continue with Phase 0.6 ...` が **bash 構文として無効** (`; then` は `if cmd; then ... fi` の文法トークンであり、if 句なしで使うと syntax error rc=2)。LLM が caller HTML コメント冒頭の指示「IMMEDIATELY run as your next tool call」に従い literal copy → Bash tool 実行すると Step 0 自体が syntax error で abort し、Step 1 idempotent retry に依存することになる経路だった。

これは PR #636 cycle 1 F-12 (`; then proceed` bash 構文破綻) の **再発** であり、累積対策追加 PR で literal 文字列を散文と混在させる際に shell 文法トークン (`; then`) を散文と隣接配置すると LLM が if 構文の一部と誤解釈する経路は構造的に発生する。

**declarative 文書追加 PR の 5 つの品質保証ポイント** (PR #654 で確立):
1. **literal として LLM に渡すコードは構文有効性を test で検証**: `bash -n` 相当の static check が困難な場合は invalid pattern を含まないかの NOT-contain grep で代替可能 (PR #654 では `--preserve-error-count[[:space:]]*;[[:space:]]*then[[:space:]]+continue` を NOT-contain で grep)
2. **literal 文字列を散文と混在させる場合、構文区切り (backtick / 括弧) で明示的に分離**
3. **DRIFT-CHECK ANCHOR は対称化対象の全 site で同一文言で記載** (PR #654 で create-interview.md に新規 4-site anchor を追加したが、対称位置の create.md / stop-guard.sh の既存 3-site anchor は更新されておらず drift detector が機能しなかった)
4. **2-site 内 duplication (同一ファイル内 N 箇所) には `grep -cF` で count check を入れる** (1 箇所のみの match で pass する grep は片肺欠落 silent regression を許容)
5. **escalation path の test (error_count=1+) も初回 entry path と同等の sentinel 4 句 grep で覆う** (TC-651-A2 で initial entry のみ verify していた問題を補完)

#### Cycle 2 の波及範囲不足 — DRIFT-CHECK ANCHOR fix の隣接 prose drift

cycle 2 で発見された 3 LOW (F-11/F-12/F-13) は cycle 1 F-03 修正の波及範囲不足が原因。DRIFT-CHECK ANCHOR section の strict scope だけを更新したが、隣接 prose paragraph 内の同 terminology (`3-site`/`3 site`) は対象外として silent skip された (3 reviewer すべて同 root cause を別 location で指摘し High Confidence cross-validation で確定)。

これは「Asymmetric Fix Transcription (PR #548)」の **派生形**:
- 元の Asymmetric Fix Transcription: 同一 invariant の対称位置 (異なる file/section) への伝播漏れ
- 本 PR で観察: 同一 file 内・**同一 blockquote 内** の隣接 paragraph への波及漏れ

**scope 拡張規則**: anchor 修正は anchor 内 strict text だけでなく、anchor が説明する terminology を使う隣接 prose も sweep 対象。

**mitigation**: anchor 系統を更新する際は (a) `git diff` で blockquote 全体を見直す + (b) grep で旧 terminology の残存有無を全 file 検索する、の 2 step を必須化。

#### Self-exemplar 構造の累積メタパターン

PR #636 (8 件目) → PR #653 (本ページに記録) → PR #654 (9 件目) と 3 連続で「累積対策追加 PR が新たな drift / bug を生む」self-exemplar が発生。これは **declarative 強化路線そのものの構造的限界** を示唆:
- declarative 規約は LLM の挙動を「説明」するが「強制」しない (規約違反時の machine-enforced gate がない)
- 規約の追加自体が新たな攻撃面 (literal の構文有効性 / 隣接 prose drift / dead marker) を生む
- self-review / 単一 reviewer では catch できない構造的 drift は cross-validation High Confidence でしか surface しない

長期的にはメタレイヤー対策 (PostToolUse hook で LLM 挙動を強制注入する等) を別 Issue で検討すべきだが、現状は本ページの 4 quality signals + 5 品質保証ポイント + 隣接 prose sweep 規則 を組み合わせた declarative 強化が pragmatic optimum。

### opt-in backward-compatible flag の設計教訓

PR #636 cycle 3 で追加された `--preserve-error-count` flag は、`.error_count = 0` 無条件リセットという従来契約を破壊せずに新 usage pattern (同一 phase への self-patch) を許容する canonical design:

- **既存 caller (phase transition) は flag なしで reset 継続** — 後方互換保証
- **新規 self-patch caller は明示的に保持を選択** — opt-in で意図を明示
- **docstring に各 mode での挙動を明示**: patch mode のみ有効、create/increment mode では silent no-op が意図的

semantics 変更を伴う修正では「新 flag + opt-in + 既存挙動保持」が最もリスクが少ない (PR 全体を書き換えるより diff scope が絞れて review しやすい)。

### PR #661 (Issue #660 = 累積対策 11 回目) で観測された self-meta drift convergence

PR #661 (Issue #660 = silent precondition omit の root cause 修正) は cycle 1 → 4 で findings 数が **7 → 2 → 1 → 0** と明確 convergence (PR #636 の 13 cycle と比較して 4 cycle で収束)。各 cycle で見つかる finding の大半は前 cycle fix が導入した self-meta drift だった:

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

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [Test が early exit 経路で silent pass する false-positive](./test-false-positive-early-exit.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](../heuristics/canonical-list-count-claim-drift-anchor.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)

## ソース

- [PR #636 cycle 1 review (13 findings, 7 pattern categories)](raw/reviews/20260421T024947Z-pr-636.md)
- [PR #636 cycle 1 fix (13 findings resolved)](raw/fixes/20260421T025621Z-pr-636.md)
- [PR #636 cycle 2 review (10 findings, 60% fix-induced drift)](raw/reviews/20260421T030627Z-pr-636-cycle-2.md)
- [PR #636 cycle 2 fix (10 findings, 6 drift removed)](raw/fixes/20260421T031214Z-pr-636-cycle-2.md)
- [PR #636 cycle 3 review (architectural HIGH surface)](raw/reviews/20260421T032048Z-pr-636-cycle-3.md)
- [PR #636 cycle 3 fix (--preserve-error-count + twin site contract)](raw/fixes/20260421T033138Z-pr-636-cycle-3.md)
- [PR #636 cycle 4 review (incomplete architectural fix detection)](raw/reviews/20260421T033906Z-pr-636-cycle-4.md)
- [PR #636 cycle 5 review (silent-false-pass + line-number reference)](raw/reviews/20260421T045816Z-pr-636.md)
- [PR #636 cycle 5 fix (silent-false-pass via PATH fault injection)](raw/fixes/20260421T050914Z-pr-636.md)
- [PR #636 cycle 13 review (0 findings, mergeable convergence)](raw/reviews/20260421T095348Z-pr-636.md)
- [PR #653 review (累積対策 fractal pattern 観測 / Issue #650)](raw/reviews/20260424T045427Z-pr-653.md)
- [PR #654 cycle 1 fix (Issue #651 / 9 件目 / literal bash syntax error self-exemplar)](raw/fixes/20260424T060618Z-pr-654.md)
- [PR #654 cycle 2 fix (隣接 prose 波及漏れ / DRIFT-CHECK ANCHOR scope 拡張)](raw/fixes/20260424T061400Z-pr-654.md)
- [PR #661 cycle 1 review (累積 11 回目 / 7 findings)](../../raw/reviews/20260425T133145Z-pr-661.md)
- [PR #661 cycle 1 review (expanded — DRIFT-CHECK ANCHOR pair sync drift)](../../raw/reviews/20260425T153740Z-pr-661.md)
- [PR #661 cycle 1 fix (4-arg ANCHOR 拡張 + AC-1 test 永続化 + Inverse TC)](../../raw/fixes/20260425T154517Z-pr-661-cycle-1.md)
- [PR #661 cycle 2 review (DRIFT-CHECK ANCHOR の prose 内引数 enumeration 同期漏れ)](../../raw/reviews/20260425T161137Z-pr-661.md)
- [PR #661 cycle 2 fix (cleanup.md drift fix + line-number 違反修正)](../../raw/fixes/20260425T161635Z-pr-661.md)
- [PR #661 cycle 3 review (create-interview.md:605 横展開漏れの cross-validation 検出)](../../raw/reviews/20260425T165246Z-pr-661.md)
- [PR #661 cycle 3 fix (propagation scan pattern coverage 不足の修正)](../../raw/fixes/20260425T165546Z-pr-661.md)
- [PR #661 Cycle 4 Review (mergeable, 0 findings, 6 REC 抽出)](../../raw/reviews/20260425T171440Z-pr-661-cycle-4.md)
