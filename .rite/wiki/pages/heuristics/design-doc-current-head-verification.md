---
title: "Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く"
domain: "heuristics"
created: "2026-04-26T09:20:00+00:00"
updated: "2026-05-05T03:53:38Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260504T232902Z-pr-829.md"
  - type: "reviews"
    ref: "raw/reviews/20260426T080650Z-pr-677.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T081122Z-pr-677-cycle-1.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T081939Z-pr-677-cycle-2.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T082521Z-pr-677-cycle-3.md"
  - type: "fixes"
    ref: "raw/fixes/20260426T084232Z-pr-677-cycle-4.md"
tags: ["design-doc", "sot-verification", "stale-reference", "hooks-json", "grep-evidence", "schema-inheritance"]
confidence: high
---

# Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く

## 概要

既存コンポーネントを参照する design doc は記憶ベースで書かず、現 develop HEAD の registration ファイル (hooks.json 等) や writer/reader を grep evidence として確認してから書く。記憶に頼った参照は「component が既に取り除かれている」「field が現 schema に存在しない」「hook list が drift している」といった stale code reference を生み、 multi-cycle review-fix loop の dominant 原因となる。PR #677 で stale code reference (4 HIGH on single root cause) と hooks.json SoT misalignment (cycle 4 で 5 finding 再 surface) として実測。

## 詳細

### 発生条件

design doc が「既存の hook / API / field を参照する」とき、以下の経路で容易に drift が混入する:

1. **著者の記憶が複数 PR 前の状態に固定**: design 中に記憶ベースで component name を書き、現 HEAD で該当 component が変更/取り除かれていることに気付かない
2. **「inherited from X」のような暗黙参照**: schema field を「現 schema から継承」として列挙するが、production code に writer/reader が存在しない field が混入する
3. **列挙系 (hook list / field list) の multi-location 重複**: 概要 (L6) と Implementation Detail と Test Plan の 3 箇所に同じ列挙を書くと、1 箇所修正時に他参照箇所が drift する

### PR #677 (Issue #672 = `.rite-flow-state` multi-state Decision Log) での実測

7 cycle の review-fix ループ収束軌跡: **9 → 5 → 3 → 5 → 1 → 1 → 0**。convergence ではなく cycle 4 で finding 数が **再 spike (3→5)** する非単調軌跡が観測された。

#### cycle 1: 9 findings の 44% (4 HIGH) が「stale code reference」単一 root cause

設計者が現 develop HEAD を grep せずに記憶ベースで component を参照した結果:

- 既に役割が変化した component (本 PR では stop-guard.sh 系) を「現役」として記述
- design doc が 4 HIGH finding すべてを「stale code reference」という単一 root cause cluster に traced できた
- **Lesson** (cycle 1 fix から): when writing design docs that reference existing components, **always grep the current codebase to confirm the component still exists**

#### cycle 2: SoT verification gap (3 HIGH + 2 MEDIUM)

cycle 1 fix が新たに `needs_clear field` を「optional field for compact recovery」と書いたが、cycle 2 reviewer が production code に writer/reader 不在を発見。schema field の "inheritance" claim を grep verify せずに書いた pattern。

加えて Multi-location enumeration drift も発生: 概要 (L6) は 5 hooks に updated したが他 4 箇所が 4 hooks のまま drift。**hook list 等の列挙は SPEC-OVERVIEW セクションで一度定義し、他は参照のみにする** のが drift 防止の canonical。

#### cycle 3: SoT grep evidence pattern の確立

cycle 3 reviewer が grep evidence に基づき `session-start.sh:243` の `.active` reader を発見。design doc の hook list 選定基準を「reset/startup path で `.active` を読む実コード」に明確化することで、reviewer の grep evidence に対応する SoT 基盤を確立。

#### cycle 4: hooks.json を SoT として再評価したことで cycle 1-3 の積み残しが大量 surface

cycle 4 reviewer が hooks.json registration を grep evidence として参照することで、cycle 1-3 で繰り返してきた hook 列挙の事実誤認 (`phase-transition-whitelist.sh` を hook として誤列挙、`session-end.sh` の漏れ) を検出。reviewer 単独 cycle scope では surface しない deeper SoT layer は、**複数 cycle の reviewer 累積で初めて顕現する**。

cycle 4 で確立された fix:
1. **SoT alignment**: hooks.json に基づく 6 hooks 列挙へ全 6 箇所を統一
2. **Library exclusion**: phase-transition-whitelist.sh は SOURCED library のため hook 列挙から除外、Note で library 性を明記
3. **Writer attribution accuracy**: loop_count を「writer 経路存在」から「production code writer 不在 (legacy field)」に修正

### Canonical 対策

1. **References 義務化**: design doc を書く前に、参照する component (hook/API/field) を grep で実在確認する。inline 注釈として `(grep evidence: hooks.json L42 / session-start.sh:243)` のように残す
2. **Registration ファイルを SoT に**: hook 列挙は `hooks.json`、command 列挙は `plugin.json`、field 列挙は `jq -n create` のような **registration ファイル / production code を単一 SoT** として選定する
3. **Field "inheritance" claim には grep verify**: 「inherited from current schema」のような claim には writer/reader を grep し、production code 経路の存在を inline evidence として残す。production code 経路が無い field は legacy/未実装として明示する
4. **Single SoT + reference の構造**: 同じ列挙を複数箇所に書く場合は SoT を 1 箇所に置き、他は参照のみとする (multi-location drift 防止)
5. **Library vs hook の区別を明示**: SOURCED library と registered hook は意味が異なる。hook 列挙では registration ファイル (hooks.json) の `hooks[]` array を SoT とし、library は除外する旨を Note 化する

### Cycle 4 spike pattern が示す cumulative-defense 教訓

PR #677 の収束軌跡 (9 → 5 → 3 → 5 → 1 → 1 → 0) で **cycle 4 で finding 数が再 spike** したのは、cycle 1-3 では reviewer も同じ「記憶ベース hook list」を信じていたため、cycle 4 で初めて hooks.json grep evidence による検証 layer が活性化したことが原因。これは [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md) の fractal pattern とは別系統 — fix-induced drift ではなく **「reviewer 自身の SoT layer が cycle 進行で深化する」現象**。design doc PR では reviewer scope の cycle-progressive deepening を前提に、初回 cycle から registration ファイル grep を mandatory 化することで cycle 4 spike を回避できる。

### 関連 anti-pattern との区別

| pattern | scope | timing |
|---------|-------|--------|
| **Design doc current HEAD verification** (本 page) | 既存 component の参照記述 | design 時 |
| [hallucinated-canonical-reference](../anti-patterns/hallucinated-canonical-reference.md) | 存在しない component の捏造参照 | fix 時 |
| [prose-design-without-backing-implementation](../anti-patterns/prose-design-without-backing-implementation.md) | 新規設計の prose のみで実装無し | design 時 |
| [asymmetric-fix-transcription](../anti-patterns/asymmetric-fix-transcription.md) | 同種パターンの multi-location drift | fix 時 |

本 page は「design 時に既に存在する component を memory-based で誤って書く」現象 — 捏造ではなく staleness。fix 時の hallucinated reference (`hallucinated-canonical-reference`) と区別される。

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](../anti-patterns/hallucinated-canonical-reference.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](../patterns/drift-check-anchor-semantic-name.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #677 cycle 1 review (9 findings: stale code reference cluster + schema inheritance + split-config + cross-doc)](raw/reviews/20260426T080650Z-pr-677.md)
- [PR #677 cycle 1 fix (44% findings traced to single root cause)](raw/fixes/20260426T081122Z-pr-677-cycle-1.md)
- [PR #677 cycle 2 fix (SoT verification gap + multi-location enumeration drift)](raw/fixes/20260426T081939Z-pr-677-cycle-2.md)
- [PR #677 cycle 3 fix (SoT grep evidence pattern 確立)](raw/fixes/20260426T082521Z-pr-677-cycle-3.md)
- [PR #677 cycle 4 fix (hooks.json SoT 大発見、cycle 4 spike の root cause)](raw/fixes/20260426T084232Z-pr-677-cycle-4.md)
- [PR #829 fix cycle 2 (design doc plan PR の 4 修正パターン: (1) 採用案 SoT 分裂を 4 箇所同期、(2) 検証 grep の syntax 不能 = markdown table cell 内 `\|` ERE alternation 不能 + BRE `+` literal 扱いで silent-pass、表内 grep を表外 fenced code block に分離、(3) 数値主張の grep 実測値乖離を再現コマンド明記で再計算、(4) scope rationale の事実誤認を表現緩和)](raw/fixes/20260504T232902Z-pr-829.md)
