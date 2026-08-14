---
title: "Cleanup refactor は reasoning prose を保持し review-history journal のみ削除する"
domain: "heuristics"
description: "charter cleanup / simplification refactor で過去の review cycle 経緯記述や finding ID 引用を機械的に削除する際、reasoning prose (なぜそう実装したかの根拠) を残し、review-history journal (`cycle 10 C-1 対応`、`旧実装は X だった、本 cycle で Y を追加` 等) のみを除去するのが正しい削除単位。"
promote: rite-plugin
created: "2026-05-07T04:15:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260718T034912Z-pr-1893.md"
  - type: "fixes"
    resource: "raw/fixes/20260718T035229Z-pr-1893.md"
  - type: "reviews"
    resource: "raw/reviews/20260506T190517Z-pr-877.md"
  - type: "reviews"
    resource: "raw/reviews/20260506T195728Z-pr-878.md"
  - type: "reviews"
    resource: "raw/reviews/20260506T204827Z-pr-879.md"
  - type: "reviews"
    resource: "raw/reviews/20260507T014914Z-pr-880.md"
  - type: "reviews"
    resource: "raw/reviews/20260507T032241Z-pr-881.md"
  - type: "reviews"
    resource: "raw/reviews/20260507T040320Z-pr-882.md"
  - type: "reviews"
    resource: "raw/reviews/20260507T044332Z-pr-883.md"
  - type: "reviews"
    resource: "raw/reviews/20260507T163353Z-pr-889.md"
  - type: "reviews"
    resource: "raw/reviews/20260508T032656Z-pr-890.md"
  - type: "reviews"
    resource: "raw/reviews/20260508T034304Z-pr-890.md"
  - type: "fixes"
    resource: "raw/fixes/20260508T033003Z-pr-890.md"
  - type: "fixes"
    resource: "raw/fixes/20260508T033628Z-pr-890.md"
  - type: "reviews"
    resource: "raw/reviews/20260508T060713Z-pr-891.md"
  - type: "reviews"
    resource: "raw/reviews/20260508T141025Z-pr-894.md"
  - type: "reviews"
    resource: "raw/reviews/20260508T150042Z-pr-895.md"
  - type: "reviews"
    resource: "raw/reviews/20260510T113017Z-pr-921.md"
  - type: "reviews"
    resource: "raw/reviews/20260510T232242Z-pr-921.md"
  - type: "reviews"
    resource: "raw/reviews/20260520T011841Z-pr-1066.md"
  - type: "fixes"
    resource: "raw/fixes/20260520T022118Z-pr-1066-cycle1.md"
  - type: "reviews"
    resource: "raw/reviews/20260707T113610Z-pr-1780.md"
  - type: "fixes"
    resource: "raw/fixes/20260707T113953Z-pr-1780.md"
tags: [refactor, cleanup, charter, simplification, pre-commit-gate, new-pr-self-trap]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-18T15:20:00+09:00" }
---

# Cleanup refactor は reasoning prose を保持し review-history journal のみ削除する

## 概要

charter cleanup / simplification refactor で過去の review cycle 経緯記述や finding ID 引用を機械的に削除する際、reasoning prose (なぜそう実装したかの根拠) を残し、review-history journal (`cycle 10 C-1 対応`、`旧実装は X だった、本 cycle で Y を追加` 等) のみを除去するのが正しい削除単位。reasoning ごと消すと LLM runtime の判断材料が失われる。

## 詳細

### 削除単位の 3 分類（実測）

charter で禁止されている `cycle [0-9]+|verified-review cycle` パターンの引用は、以下 3 種に分類して削除する:

1. **inline parenthetical** (約 60% — table cell 末尾の `(cycle 8 H-5 対応)` 等)
   - phrase 単位で削除する
   - 削除後の文末が `されていない)` `**WARNING only**)` 等で自然に閉じることを確認する
   - 空括弧 `()` や末尾 `、)` のような artifact が残らないか grep で検証

2. **bash literal 内 historical comment 行** (約 40% — `# verified-review cycle 15 F-8 対応:` 等)
   - 行単位で削除可能 (bash 構文に影響なし)
   - 同一 `# A\n# B\ncode` から `# A\ncode` への変更は構造的閉じトークン (`}` / `fi` / `esac`) に影響しない

3. **prose blockquote 内 cycle 番号付き経緯記述** (残り)
   - 文節単位で書き換える
   - 例: `verified-review (cycle 8) M-9 対応: 旧実装は X だった。本 cycle で Y を追加` → `silent data loss 防止のため hard fail させる`
   - **WHY を残し、HOW IT GOT THERE を削除する**

### 「reasoning は残す」が中核原則

`旧実装は Y だった、本 cycle で Z を追加` のような構造の削除では、`本 cycle で Z を追加` 部分だけ消して `Y のため Z にする` 形に書き換える。これにより:

- LLM が runtime に reading するときの「なぜそう実装したか」の根拠が維持される
- review-history journal (charter 禁止対象) は除去される
- charter 5 自問の `[3] 説明か手順か` で「説明 (経緯) は削除、手順 (根拠) は維持」の境界が明確化する

### 削除パターンの非対称性は意図的

3 分類で削除単位が異なる (phrase / line / 文節) のは表面的な構文単位の違いではなく、各構造で「reasoning vs journal」の境界が異なる場所に出るため:

- table cell では reasoning は cell 本文、journal は parenthetical → phrase 削除
- bash literal comment では reasoning は次行の動作仕様、journal は単独行 → 行削除
- prose blockquote では reasoning と journal が文中に混在 → 文節書き換え

「全て同じ単位で削除」とすると、reasoning ごと消す経路 (case 1 で table 全行削除) や bash 動作説明ごと消す経路 (case 2 で `# explanation\n# cycle X` の前者まで巻き込む) が出るため、構造別の削除単位を意識する必要がある。

### Cross-validation で削除の安全性を担保

charter cleanup は機械的削除のため文意破壊や構造破壊のリスクがある。連続 1 件目 (`pr/review.md` から 41 件削除) では以下で安全性を担保:

- pre-commit baseline grep で develop HEAD の lint findings 数を記録 → 本 PR でリグレッションがゼロであることを実証 (drift 32 件 / comment-journal 22 件→7 件で 15 件削減確認)
- Reviewer 並列起動 (Prompt Engineer + Code Quality) で AC-1/2/3 + cross-file impact + 表構造整合性を独立検証
- AC-2 (`bash plugins/rite/hooks/tests/4-site-symmetry.test.sh`) で機能契約 non-regression を機械確認

これにより 0 件 finding で 1 cycle で承認に到達した。

### 連続 5 PR (sibling 検証) で 0 finding 1 cycle 着地が再現

連続 1 件目 (`pr/review.md` から 41 件削除)、2 件目 (`pr/fix.md` から 31 件削除)、3 件目 (`pr/cleanup.md` から 16 件削除)、4 件目 (`pr/references/bash-trap-patterns.md` から 11 件削除)、5 件目 (`pr/references/fact-check.md` から 2 件削除) は、親 Issue の Phase 0a の sibling PR として同型の cleanup pattern を独立適用した。5 PR とも:

- 同じ 3 分類 (inline parenthetical / bash literal comment / prose blockquote) で削除単位を決定
- pre-commit baseline grep + Reviewer 並列起動 + 機能契約 test PASS の 3 layer
- prompt-engineer / code-quality の 2 reviewer 共に 0 blocking findings で 1 cycle 着地

連続 5 PR の独立適用で同等の効率 (0 finding 1 cycle) が再現したことで、本経験則は「単一 PR の偶然的 success」ではなく「再現可能な canonical 手順」として実証された。5 PR の合計削除件数は 101 件で、ファイルあたりの引用密度に応じてスケール (`pr/review.md` 41 / `pr/fix.md` 31 / `pr/cleanup.md` 16 / `pr/references/bash-trap-patterns.md` 11 / `pr/references/fact-check.md` 2) する。**極小規模 PR (+2/-2) でも同パターンが成立する**ことが 5 件目で実証され、規模スケール下限が 2 件まで拡張された。

4 件目では prompt-engineer が file 内非対称 (PR description 削除分類と AC-1 strict regex の判定基準乖離による残存引用 2 件) を Important × 2 で検出したが、Phase 5.3.0 Observed Likelihood Gate で Likelihood-Evidence anchor 未提示のため推奨事項へ機械的降格 →「Scope 外指摘ハンドリングポリシー」の方針により対応見送り。本系列の cleanup PR は **strict regex マッチ件数で削除対象を確定** (PR description の説明的件数とは独立) する運用が高信頼であることを副次的に再確認した。

5 件目は `Issue #[0-9]+` 本文引用パターン (`Layer 4 (親 Issue #N の #M)` 形式) を「別 PR で対応」に一般化する極小 inline parenthetical 削除のみで構成され、reasoning prose (caller 同期が意図的 PR 分離である説明) は完全に保持された。これにより、本経験則の「reasoning は残す」中核原則は規模に関係なく成立することが追加実証された。

連続 6 件目の sibling (`pr/references/archive-procedures.md` から 4 件削除、+4/-4 行) は本経験則の reproducibility をさらに補強した。削除対象は `Issue #496 / PR #531` / `Issue #658 — observed on #593 stuck at "In Review" and #652 stuck at "In Progress"` / `(Issue #693)` × 2 / `— see Issue #658 for rationale` の 4 箇所で、いずれも parenthetical な過去 PR/Issue 番号引用に該当 (3 分類のうち inline parenthetical と bash literal 内 historical comment の混在)。reasoning prose (LLM attention loss / partial-failure paths による silent skip 説明、`current_body` 等のシェル変数喪失に関する Note for Claude、`same delegate pattern as Phase 3.2` の cross-reference) は完全に保持された。両 reviewer (prompt-engineer / code-quality) ともに 0 blocking findings で 1 cycle 着地。**references/ 配下の reference ファイルにも本パターンが適用可能であることが本 PR で実証**され、対象範囲が `pr/{review,fix,cleanup}.md` の主要 command ファイルから references/*.md にも拡張された。

連続 7 件目の sibling (`pr/references/internal-consistency.md` から 5 件削除、+5/-5 行) は references/ 配下への適用 2 例目を実証した。削除対象は `本 Issue #350 検証付きレビュー L-12 / L-16 / L-1 / M-12 / L-2 / C-3` の 5 行に渡る review round ID 引用で、いずれも `Issue #N で.*対応` charter pattern に該当する inline parenthetical (`(本 Issue #N 検証付きレビュー L-X で〜)`) および prose blockquote 内 cycle 番号付き経緯記述の混在。reasoning prose (`drift 監視 invariant の詳細は Drift Detection Invariants セクションに分離している` / `drift リスク` の現状記述 / `重複構造そのものは残っており、将来の更新時に再 drift する手動依存リスクは健在` の警告) は完全に保持され、line 382 の「取り戻している」→「維持している」のような state aspect の書き換えのみで意味の load-bearing claim は保持された。両 reviewer (prompt-engineer / code-quality) ともに 0 blocking findings で 1 cycle 着地、累計 105 件削除 / 7 PR 連続成功で本経験則の信頼性が high として一層強化された。**事前 Wiki query injection** (Phase 3.0.W) で本経験則ページが LLM に注入されたことが、実装計画段階での「reasoning prose 保持」原則の早期反映に寄与した実例として記録される。

連続 8 件目の sibling (`pr/references/fact-check.md` から 5 件削除、+5/-5 行で行数 438 不変) は references/ 配下への適用 3 例目を実証した。削除対象は (a) セクション見出し `Internal Likelihood Claims（検証必要・新規）` から `・新規` を削除、(b) 段落 `External Claim と直交する新カテゴリ` から `新` を削除、(c) blockquote 内の `歴史的経緯により` / `caller 側 (review.md / assessment-rules.md) の同期が必要なため別 PR で対応予定` 削除、(d) `新セクションは` を `### 外部仕様の検証結果 および ### 矛盾により除外された指摘 セクションは` に具体化、(e) blockquote 末尾の `caller 側の更新は別 PR で対応し、本ファイルと意図的に PR を分離している` を削除、の 5 種で、`歴史的経緯` / `別 PR で対応` / `意図的に PR を分離` / `新カテゴリ` / `新セクション` / `検証必要・新規` の 6 種 charter 違反パターンが含まれる混合ケース。**in-place edit 中心 (5 insertions + 5 deletions、行数 438 不変)** でも reviewer が「specificity 向上」(`新セクションは` → 具体的セクション名への置換) を改善方向の変更として認識した観察が追加され、本経験則の適用範囲は「-N 行の削除規模」だけでなく「行数不変の inline 置換」にも及ぶことが実証された。両 reviewer (prompt-engineer / code-quality、sole reviewer guard により co-reviewer 追加) ともに 0 blocking findings で 1 cycle 着地、累計 110 件削除 / 8 PR 連続成功で本経験則の信頼性は最高水準で再確認された。事前 Wiki query injection の効用は 7 件目に続き本 PR でも観察された。

### 連続 9 件目で発見された限界: slim refactor で識別子削除 / 構造ラベル変更を伴う場合は 3 cycle 構成になりうる (Phase C1 cleanup.md slim)

連続 9 件目の sibling (`pr/cleanup.md` の Sub-skill Return Protocol セクションを 96 行 → 26 行に slim、-70 行) は、**初めて 1 cycle 着地から外れた 3 cycle 構成** で収束した (cycle 1 で 4 件 broken refs 検出、cycle 2 で 1 件 Step 番号引用検出、cycle 3 で 0 blocking)。これは「reasoning prose 保持 / journal 削除」原則は維持されたが、**section heading や Item 番号体系を削除する slim refactor では同ファイル内の暗黙参照 (orphan dangling reference) が発生する** という限界を明らかにした。具体的な failure mode は 2 種:

1. **broken intra-file reference (cycle 1, CRITICAL × 4)**: 削除した識別子 (例: `Pre-check Item N` / `場面 (a)/(b)` / `Item 0 Routing dispatcher`) を、同ファイル内 4 箇所の散文・WARNING メッセージが name-by-name で参照したまま残置 → 削除済み識別子への dangling reference。両 reviewer (prompt-engineer / code-quality) が独立検出した cross-validation 高信頼度。
2. **literal 構造ラベル変更時の verbatim 引用 grep 不一致 (cycle 2, LOW × 1)**: `Step 1` ラベル → `inline (1)` 番号への構造的書き換えで、別の場所の verbatim 引用と grep 不一致。cycle 1 の broken reference (識別子削除) とは別 class (構造ラベル変更) の漏れ。

**canonical 対策の拡張**: 既存経験則の `pre-commit baseline grep` 段階で、削除予定の識別子だけでなく **「変更する構造ラベル」も grep の対象に含める** ことが必要。具体的には:

- 削除する識別子 (例: `Pre-check Item`、`場面 (a)/(b)`、`Routing dispatcher`) の同ファイル内全箇所を `grep -nE` で事前列挙
- 変更する構造ラベル (例: `Step [0-9]+`、`Phase [0-9]+\.[0-9]+`、heading hierarchy 変更) の同ファイル内全箇所を `grep -nE` で事前列挙
- 両 grep 結果を slim 後に再 grep し、**全 hit 件数が 0 になる** ことを pre-commit gate で確認

この 2 拡張を pre-commit gate に追加することで、broken intra-file reference / 構造ラベル grep 不一致の両 sub-pattern を構造的に予防できる。9 件目の 3 cycle 収束は事後的に修正コスト (+7/-7 + cycle 2 の最小差分) が低く済んだが、pre-commit gate に上記 2 拡張を入れていれば 0 cycle で landed していた可能性が高い。

**規模スケールへの拡張**: 9 件目は -70 行という大規模 slim でありながら charter 違反引用は cycle 番号引用ではなく **section 構造の identity 表現** (heading / Item 番号) が中心だった点で、既存 8 PR (charter 違反引用の機械的削除中心) とは failure mode が異なる。本経験則の `削除単位の 3 分類` (inline parenthetical / bash literal comment / prose blockquote) は **削除対象が引用 phrase / 行 / 文節の場合** に適用される canonical で、**削除対象が section heading / Item 番号体系の場合** は本ページの新 sub-pattern (broken intra-file reference + 構造ラベル変更時の verbatim 引用 grep 不一致) を併用する必要がある。累計 117 件 / 9 PR で 8 PR (1 cycle) + 1 PR (3 cycle) の sibling 比率が確立し、本経験則の信頼性は high 水準を維持したまま「適用範囲の境界」を実測した。

### 連続 10 件目で構造ラベル grep 拡張が canonical 化を達成 (Phase C2 cleanup.md slim)

連続 10 件目の sibling (`pr/cleanup.md` の Phase 1 / Phase 4.W から散文削除、-24 行) は、9 件目で発見された canonical 対策の拡張 (構造ラベル grep 対象拡張) を **Phase C1 からの学習として実適用した最初の事例**。結果として再び **0 finding 1 cycle 着地** に回復し、9 件目の 3 cycle 構成は「対策未適用時の限界」だったことが事後的に確認された。

具体的には:

- **構造ラベル grep の対象拡張を pre-commit gate に追加** — 削除する識別子だけでなく `Step [0-9]+` / `Phase [0-9]+\.[0-9]+` / heading hierarchy など変更する構造ラベルも `grep -nE` で事前列挙し、slim 後に再 grep して全 hit 件数 0 を確認する gate を実装
- **DRIFT-CHECK ANCHOR semantic 保全 / 4-site-symmetry test PASS / bang-backtick check 0 件** を maintaining しながら散文削除を完了
- **削減量 -24 行は SHOULD 目標 -100〜-150 を下回る** が、これは scope を Phase 1 / Phase 4.W に厳密限定した結果。reasoning prose と機能契約 (DRIFT-CHECK ANCHOR symmetry / Step 0/1 idempotent patch / Sub-skill Return Protocol routing dispatcher) を保持した上で削れる journal-only 散文の上限値を明示
- **AC-3 (cleanup.md ≤1500 行) は本 PR 後 1810 行で未達**、Phase D へ持ち越しの方針がユーザー承認済み — 単一 PR で大規模 slim を強行するより scope 限定 + sibling 反復で機能契約保全を優先する判断

**対策実装の効果実証**: 9 件目の 3 cycle 収束で発見された 2 sub-pattern (broken intra-file reference + 構造ラベル変更時の verbatim 引用 grep 不一致) が、対策実装後の 10 件目では cycle 1 で 0 件検出されたことで、canonical 対策の効果が実測された。これにより本経験則の sub-pattern 「9 件目で発見された限界」は **対策が canonical 化された段階で 1 cycle 着地に回復する** ことが確認され、累計 141 件 / 10 PR で **9 PR (1 cycle) + 1 PR (3 cycle)** の sibling 比率に更新。本経験則の信頼性は high 水準を維持したまま、適用範囲の境界が「対策未適用時のみ 3 cycle / 対策適用後は 1 cycle」として明確化された。

### 連続 11 件目で references/ 配下適用 4 例目 (Phase D 第 1 弾)

連続 11 件目の sibling (`pr/references/fact-check.md` の slim、-16 行) は references/ 配下への適用 4 例目を実証した。Phase D 第 1 弾として 1 PR / 1 ファイル方針で `fact-check.md` 単独に scope を限定し、両 reviewer (prompt-engineer + code-quality) 並列起動で 0 blocking findings 1 cycle 着地。削除対象は 8 種の散文・冗長補足・表サマリー文 ((a) 統合レポートでの扱い段落 (`Verification Execution` 冒頭との重複) (b) 両 Sub-Phase 判定組合せ表のサマリー文 (c) `Internal Likelihood Verification Rules` の 4→2 bullet 圧縮 (d) `max_claims Handling` 冒頭の重複説明 (e) 「セクション名について」blockquote の inline 統合 (f) `HYPOTHETICAL 降格 finding の 2 箇所記録` の 4→1 行圧縮 (g) caller 同期説明 (h) Note / Rationale 段落の冗長部分短縮) で、reasoning prose は完全に保持された。

本 PR で確認された追加観察:

- **fact-check.md は 8 件目 (5 件削除、行数 438 不変) に続く 2 度目の slim** (438→422、-16 行)。8 件目は inline 置換中心、11 件目は段落削除中心という異なる削除手法でも、両 reviewer 並列で 0 finding 1 cycle 着地が再現されたことが、本経験則の reproducibility を強化
- 親 Issue は **multi-PR 分割スコープ** (references/ 4 ファイルを 1 PR / 1 ファイル方針で順次 slim) で運用され、本 PR は連作の第 1 弾。Issue クローズは AC-2 達成の最終 PR で行う設計のため、cleanup 時は `Refs` trailer (not `Closes`) で Issue は OPEN 継続、Status を In Progress に戻すハンドリングが必要
- 累計 157 件削除 / 11 PR で **10 PR (1 cycle) + 1 PR (3 cycle)** の sibling 比率に更新。references/ 配下への適用は 4 例連続成功で、`pr/{review,fix,cleanup}.md` 主要 command ファイルから references/*.md への拡張が high confidence で確立した

### 連続 12 件目で references/ 配下適用 5 例目 (Phase D 第 2 弾)

連続 12 件目の sibling (`pr/references/internal-consistency.md` の slim、-58 行で 352→294 行) は references/ 配下への適用 5 例目を実証した。Phase D 第 2 弾として 1 PR / 1 ファイル方針で `internal-consistency.md` 単独に scope を限定し、両 reviewer (prompt-engineer + code-quality) 並列起動で 0 blocking findings 1 cycle 着地。charter §禁止パターン違反は事前確認時点で 0 件だったため、削除は冗長性整理 (重複説明・過度な例示・長い前置き) に limited で、runtime-effective 部分 (5 categories の Step 手順、regex literal、Severity Mapping 表、Failure signal 7 値テーブル、META 行 specification、Confidence Gate) はすべて保持された。

主な削減 12 ポイント: (1) 用語統一の経緯記述の簡素化 (2) Canonical names 前置き散文の literal-substring match 詳細を 1 行に圧縮 (3) 自明な「統一規則」段落の削除 (4) 「位置づけ」ASCII 図を 1 行説明に圧縮 (5) Single source of truth 4 bullet を 1 段落に統合 (6) Implementation Coverage 出力例の削除 (runtime 非該当) (7) 言語判定 fallback を Step 2 内に統合 (8) UX Flow Accuracy の検証対象ツールテーブル削除 (Step 2 と重複) (9) Screenshot Presence 出力例の削除 (runtime 非該当) (10) Inconclusive 例の 2 つ目削除 (11) 401/403 HTTP 仕様注の重複統合 (12) Cross-Reference リスト description 簡素化。

本 PR で確認された追加観察:

- **internal-consistency.md は 7 件目 (5 件削除、+5/-5 行) に続く 2 度目の slim** (352→294、-58 行)。7 件目は charter §禁止パターン違反引用の機械的削除中心、12 件目は冗長性整理 (前置き散文・出力例・段落構造再編) 中心という **削除対象 class が異なるケース** でも 0 finding 1 cycle 着地が再現された
- **AC-2 (`pr/references/` 4 ファイル合計 ≤1627 行) を本 PR で達成** (1676→1618、Phase D の hard target 完遂)。連作 11 PR の後 1 PR で AC 完遂に到達した規模感が記録される
- **code-quality reviewer が pre-existing dangling reference (`#drift-detection-invariants` from `tech-writer.md:25` / `review.md:580`、Phase C 系列の slim 由来)** を本 PR スコープ外の調査推奨として surface したが、「Scope 外指摘ハンドリングポリシー」の方針により対応見送り。連作 PR でも reviewer による既存 drift の surface は継続的に発生し、scope policy で意図的に分離する運用が canonical
- 累計 158 件削除 / 12 PR で **11 PR (1 cycle) + 1 PR (3 cycle)** の sibling 比率に更新。references/ 配下への適用は 5 例連続成功で、`pr/references/*.md` 拡張は very high confidence で確立した

### 連続 13 件目で test-pinned anchor string が削除対象除外サブクラス (3rd class) として追加 (Phase B 機械削除)

連続 13 件目の sibling (`commands/issue/start.md` の charter 違反パターン機械削除、2305→2303 行、-2 行) は Phase B として実施されたが、**初期サイクルで 1 CRITICAL の test breakage を踏み抜き**、本経験則の doctrine に **「test-pinned anchor string」という第三のサブクラスを除外要件として追加** することになった。最終的に 2 cycle で 0 finding 1 cycle 着地 (final review) を達成し、doctrine 拡張後の機械削除 PR は load-bearing reference (test pin / AC anchor / cross-file delegation claim) を確認するだけで通過可能であることが両 reviewer (prompt-engineer + error-handling) の 8 観点 pass 確認で実証された。

サブクラスの拡張内容:

- **旧 doctrine** (2 sub-class): reasoning prose は保持、review-history journal のみ削除
- **新 doctrine** (3 sub-class): reasoning prose は保持、review-history journal のみ削除、**ただし test-pinned anchor string (`grep -q "..."` で test が依存している literal phrase) は journal-like に見えても削除対象から除外する**

具体的に踏み抜いた事象: `parent-child-sync-static.test.sh:186` が依存していた `Issue #513` anchor string (test が literal として pin している文字列であり、番号自体が契約の一部) が「journal-like phrase」として `grep -E '(Issue|PR) #[0-9]+'` の機械削除対象に含まれてしまい test が red 化。pre-commit baseline grep の対象が「削除する識別子」のみで「test-pin 対象 anchor」を含めていなかったため silent regression として CI まで残った。

canonical 対策の拡張: pre-commit baseline grep に「**削除対象 phrase が `*.test.sh` / `*.test.bash` 等の test ファイル内で `grep -q` / `assert_contains` 等の pin assertion 経由で参照されていないか先行確認する**」を **9 件目で確立された「変更する構造ラベルも grep の対象に含める」拡張に続く 2 番目の拡張** として追加。test-pin grep を pre-commit baseline grep の必須項目に組み込むことで、test ファイル経由の dependency が機械削除候補に含まれる前に検出可能になる。

副次的観察 (1st review cycle で発覚した 1 MEDIUM):

- **Asymmetric Fix Transcription regex 取りこぼし**: charter test の `cycle [0-9]+` regex が **hyphen 形 `cycle-N`** (例: `cycle-1`, `prompt-engineer cycle-2`) を catch せず、4 箇所が silent 残存。space 形のみで pin した正規表現が hyphen 形を取りこぼした failure mode (本ページ scope 外、[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) ページ参照)

累計 159 件削除 / 13 PR (Phase B 開始) で **12 PR (1 cycle) + 1 PR (2 cycle for doctrine extension)** の sibling 比率に更新。`commands/*.md` への適用 (references/ 配下から本体 commands/ への scope 拡張) は本 PR が初 PR となり、本体 command file は test pin 密度が references/ より高いため doctrine 拡張が surface した。

### preventive direction 1 例目の逆方向 sub-pattern: 新規 PR comment writing が self-applying lint に self-trap

本経験則の主軸は「既存の journal narration を cleanup 削除する」(remediation direction) だが、preventive direction 1 例目で **逆方向の sub-pattern** が顕在化した: charter で禁止された journal phrase (`cycle N F-N で導入` 等) を、cleanup ではなく **新規 PR の本文や code comment に書いて project 自身の lint (`comment-journal-check.sh`) に self-apply で hit する self-trap** (preventive direction の missing application)。

#### 失敗の構造（実測）

preventive direction 1 例目では post-compact.sh:195 周辺に「`cycle 11 F-01 で導入された regex を gh CLI 実出力に対応`」のような journal narration を含むコメントを新規追加した。reviewer cross-validation で project の `comment-journal-check.sh` P4 regex (`cycle [0-9]+ F-[0-9]+ で(導入|確立|集約)`) にヒットすることが LOW 検出として surface した。

#### 中核原則の双方向適用

本ページの中核原則「**reasoning は残し journal は削除する**」は cleanup PR だけでなく、**新規 PR の comment 作成時にも preventive に適用する**:

1. **既存 journal の cleanup** (remediation): 過去 PR で書かれた `cycle N F-N 対応` を機械削除する (本ページ既存の主軸)
2. **新規 PR の自己抑制** (preventive): 新規 PR で書く comment / commit body / PR description に journal phrase を最初から書かない

両方向は **同じ regulator** (charter + `comment-journal-check.sh` lint) を介して接続される。新規 PR で書かれた journal は次の cleanup cycle で削除対象になる「将来の負債」であり、self-applying lint が PR 内で検出することで負債の発生を構造的に防止する。

#### Canonical 対策

1. **PR pre-commit gate で comment-journal-check.sh を必ず通す**: 既存経験則 + lint rule の組み合わせは self-apply 経路で検出可能だが、PR 作者が手動で gate を実行する習慣がなければ silent regression として merge される
2. **新規 comment の書き方範例**（fix で実装）:
   - **Before** (journal narration): `cycle 11 F-01 で導入された regex を gh CLI 実出力に対応` (cycle 番号 / finding ID を引用、charter 違反)
   - **After** (reasoning prose only): `gh CLI 実出力に対応するための regex` (reasoning prose のみ、cycle / finding ID 引用を削除)
3. **fix での書き換え技法**: `cycle N F-Y で導入された X を Y のため Z` → `Y のため Z にする` (HOW IT GOT THERE = cycle 引用 を削除し、WHY = reasoning prose を残す)

#### 経験則の自己強化ループ

本 sub-pattern は経験則の自己強化ループの正常動作: **既存経験則 → lint rule → 新規 PR への self-apply → 違反を機械検出 → fix で経験則準拠の wording に修正 → 経験則が新規 PR にも実効的に作用する**。この 1 例目では fix (cycle 1) で comment journal 整理を実施し、reasoning prose を保持しつつ journal narration のみ削除した。本 fix の体感は本ページの 3 分類 (inline parenthetical / bash literal comment / prose blockquote) と完全一致し、新規 PR への preventive application が cleanup PR と **同じ削除単位 doctrine** で動作することが追加実証された。

本 sub-pattern は本ページの累積 sibling PR (cleanup direction、13 PR) と並列に **preventive direction の累積実証 1 例目** として記録され、将来 preventive direction の sibling PR が複数蓄積した時点で「`comment-journal-check.sh` pre-commit gate 必須化」を canonical 化する根拠 evidence になる。

### preventive direction 2 例目: 新設 canonical SoT セクション自身が自身の禁則に自己矛盾

1 例目は「新規 PR の code comment / PR description」への journal narration 混入だったのに対し、2 例目は **新設する canonical reference セクション本文自体** (`common-error-handling.md` の「[CONTEXT] Emit: stdout / stderr 2 系統の使い分け (canonical)」) が journal narration を含む variant。導入段落に `PR #1774 review cycle 2 (error-handling reviewer, F-01) で fix.md 内のコメント転記時に規約の主張範囲が誤って拡大され` という番号付き経緯参照 (違反文の verbatim 引用) があり、`comment-best-practices.md` 原則2 `no_journal_comment` の禁止句リスト (`PR\s*#\d+` / `cycle\s*\d+` / `F-\d+` の三重一致) に抵触した。tech-writer レビュー (Doc-Heavy mode) が cycle 1 で HIGH 検出、fix で番号を削除し Why を散文で保持する書き換え (`過去にコメント転記時に規約の主張範囲が誤って拡大され、実際の stdout emit 箇所と矛盾する記述が生まれたことがあった`) を適用、cycle 2 で両レビュアー 0 findings に到達した。

**preventive direction 2 例目としての意義**: 「新規 PR で journal narration を書いてしまう self-trap」は 1 例目 (code comment) だけでなく、**「自身がまさに SoT 化・禁則明文化しようとしている当のセクション」でも起こりうる**ことが実証された — SoT 化 PR の作者は「経緯を明確に説明したい」という動機が強いため、むしろ journal narration を書き込みやすい構造的リスクがある。書き換え技法 (`cycle N F-Y で...` → `過去に...` の reasoning-only 化) は 1 例目と完全に同型で、本ページの 3 分類 doctrine が新設ドキュメント執筆時にも preventive に機能することを再確認した。

累計 preventive direction 2 例（code comment / 新設 reference doc 本文）となり、「SoT 化・規約明文化を目的とする PR ほど journal narration 混入リスクが高い」という追加観察が得られた。canonical 対策としては、新設 canonical セクションの draft 完了時点で `comment-best-practices.md` 禁止句リスト regex に対して self-grep することが特に重要 (通常の cleanup PR よりも新設 SoT PR の方が自己言及的リスクが高いため)。

### preventive direction 3 例目: lint regex が未カバーの「で廃止」形が LLM レビューのみで捕捉される

2 例目は「新設 canonical reference セクション本文」だったのに対し、3 例目は **決定的な機械判定を目的文へ書き換える refactor** (fingerprint 重複判定・debate 台本・skill-suggest スコアリング・issue-implement 決定木の 4 箇所) で、書き換えた本人が「`#1880 で廃止`」のような変更イベント語り (経緯ナラティブ) を永続文書 6 箇所に埋め込んだ。`comment-journal-check.sh` の既存 regex (`cycle\s*\d+` / `F-\d+` / `PR\s*#\d+` 等) は `旧 X は Y していた` 形の日本語 journal phrase を先行の累積対策 PR で拡張済みだったが、**「`#N で廃止`」という「番号 + で + 動詞」の複合形は本 lint regex がカバーしておらず、LLM レビュー (prompt-engineer) のみが検出した** (cycle 1 MEDIUM)。

fix (cycle 1) では番号・経緯を削除し、現在形の制約文 + WHY のみを残す標準の書き換え技法 (`旧実装は Y だった、本 cycle で Z を追加` → `Y のため Z にする` と同型) を適用、cycle 2 で 0 findings に到達した。

**preventive direction 3 例目としての意義**: 機械判定の削除・簡素化を目的とする refactor PR (「仕様を減らす」方向の変更) では、削除理由を Issue 番号付きで語りたくなる誘惑が特に強い — 2 例目の「SoT 化・規約明文化 PR ほど journal narration 混入リスクが高い」観察に加え、「**仕様削減・簡素化を目的とする PR も同様のリスクを持つ**」ことが本 PR で追加実証された。lint regex が既知の journal phrase 変種を汎化しても、「番号+で+動詞」のような新規複合形は後追いでしか拡張されないため、**lint はセーフティネットであり LLM レビューによる semantic 検出が一次防衛線である**ことを再確認する事例でもある。

累計 preventive direction 3 例（code comment / 新設 reference doc 本文 / 仕様削減 refactor の複合形 journal phrase）となった。

## 関連ページ

- [既存ページなし — 本ページが本テーマの初出](#)
- [Reviewer rule 自身を編集する PR は self-application false positive を verify する](./self-applying-reviewer-rule-false-positive.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)

## ソース

- [PR #1893 cycle 1 review (「#1880 で廃止」等の変更イベント語り 6 箇所を MEDIUM 検出、comment-journal-check.sh 未カバーの複合形)](../../raw/reviews/20260718T034912Z-pr-1893.md)
- [PR #1893 cycle 1 fix (経緯ナラティブを削除し現在形の制約文 + WHY のみ残す標準書き換え)](../../raw/fixes/20260718T035229Z-pr-1893.md)
- [PR #877 review results](../../raw/reviews/20260506T190517Z-pr-877.md)
- [PR #878 review results](../../raw/reviews/20260506T195728Z-pr-878.md)
- [PR #879 review results](../../raw/reviews/20260506T204827Z-pr-879.md)
- [PR #880 review results](../../raw/reviews/20260507T014914Z-pr-880.md)
- [PR #881 review results](../../raw/reviews/20260507T032241Z-pr-881.md)
- [PR #882 review results](../../raw/reviews/20260507T040320Z-pr-882.md)
- [PR #883 review results](../../raw/reviews/20260507T044332Z-pr-883.md)
- [PR #889 review results](../../raw/reviews/20260507T163353Z-pr-889.md)
- [PR #890 review cycle 1](../../raw/reviews/20260508T032656Z-pr-890.md)
- [PR #890 review cycle 3 (mergeable)](../../raw/reviews/20260508T034304Z-pr-890.md)
- [PR #890 fix cycle 1](../../raw/fixes/20260508T033003Z-pr-890.md)
- [PR #890 fix cycle 2](../../raw/fixes/20260508T033628Z-pr-890.md)
- [PR #891 review results](../../raw/reviews/20260508T060713Z-pr-891.md)
- [PR #894 review results](../../raw/reviews/20260508T141025Z-pr-894.md)
- [PR #921 cycle 1 review (1 CRITICAL test breakage + 2 MEDIUM、test-pinned anchor string sub-class の起点)](../../raw/reviews/20260510T113017Z-pr-921.md)
- [PR #921 final review (両 reviewer 0 findings、doctrine 拡張後の機械削除 PR 1 cycle 着地 + 推奨事項 2 件 scope 外)](../../raw/reviews/20260510T232242Z-pr-921.md)
- [PR #1066 review (preventive direction sub-pattern: 新規 PR comment が self-applying comment-journal-check.sh P4 regex に self-trap、LOW 検出)](../../raw/reviews/20260520T011841Z-pr-1066.md)
- [PR #1066 cycle 1 fix (reasoning prose を保持し journal narration `cycle N F-N で導入` のみ削除する 3 分類 doctrine を新規 PR comment に preventive 適用)](../../raw/fixes/20260520T022118Z-pr-1066-cycle1.md)
- [PR #1780 cycle 1 review (新設 canonical SoT セクション本文が no_journal_comment に自己矛盾、preventive direction 2 例目の起点)](../../raw/reviews/20260707T113610Z-pr-1780.md)
- [PR #1780 cycle 1 fix (番号付き経緯参照を削除し Why を散文で保持)](../../raw/fixes/20260707T113953Z-pr-1780.md)
