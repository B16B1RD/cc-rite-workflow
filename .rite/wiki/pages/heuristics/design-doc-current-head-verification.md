---
title: "Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く"
domain: "heuristics"
created: "2026-04-26T09:20:00+00:00"
updated: "2026-05-27T05:00:00Z"
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
  - type: "reviews"
    ref: "raw/reviews/20260519T195007Z-pr-1065.md"
  - type: "fixes"
    ref: "raw/fixes/20260519T195351Z-pr-1065.md"
  - type: "reviews"
    ref: "raw/reviews/20260523T174827Z-pr-1111.md"
  - type: "reviews"
    ref: "raw/reviews/20260526T182658Z-pr-1155-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T183041Z-pr-1155-cycle2-fix.md"
tags: ["design-doc", "sot-verification", "stale-reference", "hooks-json", "grep-evidence", "schema-inheritance", "orphan-marker-claim", "review-side-verification", "sot-inception-verification"]
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

### `.rite-flow-state` multi-state Decision Log での実測

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

### Doc mechanism scope claim の grep verify

「doc が記述するメカニズムの scope」が「実装の scope」より広い drift も本 heuristic の subset として捉える。PR #1065 で `auto_demote_low` の scope を doc が「LOW or MEDIUM」と曖昧表現していたが、実装は `severity == LOW` のみが降格対象で、reviewer 直接 assign 経路で MEDIUM が flag されるのは別系統という 2 経路混合だった。

| 観測 | doc 表記 | 実装事実 |
|------|---------|----------|
| `auto_demote_low` の対象 severity | "LOW or MEDIUM" (曖昧) | `severity == LOW` のみ |
| MEDIUM × current-pr の降格経路 | 同 doc に混合記述 | reviewer 直接 assign (別経路) |

#### 対策

mechanism scope を doc に記述する際は、**実装側の判定式を直接 grep して inline evidence で残す**:

```markdown
# Bad (scope 曖昧)
auto_demote_low は LOW or MEDIUM × current-pr の finding を nit-noted へ降格する。

# Good (実装 grep evidence で 2 経路を分離記述)
auto_demote_low は LOW × current-pr の finding を nit-noted へ降格する
(実装: fix.md Phase 1.2.0 Priority 2 で `severity == "LOW"` のみが対象。
 grep evidence: `commands/pr/fix.md:XXX` の `if [ "$severity" = "LOW" ]`)。

MEDIUM × current-pr は reviewer 直接 assign 経路 (本 mechanism と別系統)。
```

「LOW or MEDIUM」のような or 連結で scope を曖昧表現するのは、本 heuristic の「inheritance claim には grep verify」と同型の drift。実装の判定式を 1 行 grep で確認するコストは秒単位であり、doc 記述時に inline evidence として残せば後続 reviewer / 読者の誤読を decisive に防げる。

### Documentation の code-state claim は review 時にも grep verify する

本 heuristic は「design 時に書き手が verify する」だけでなく、**review 時に reviewer が文書の code-state claim を grep verify する** review-side mirror としても機能する。positive evidence を実測済み。

PR #1111 は `metrics-recording.md` の注記を強化し、3 marker (`phase5_post_metrics` / `phase5_post_status_in_review` / `phase5_5_2_metrics`) が **orphan (live writer/reader 不在・PHASE_ENUM_V3 に非在・pre-condition-gate.md で retired)** であり legacy `phase5_*` drift とは別語彙だと明示する doc-only PR。central factual claim が「これらの marker はコード上 orphan である」という code-state assertion であった。

| 観測 | 内容 |
|------|------|
| 文書が主張した code-state | 3 marker は live writer/reader を持たない orphan、`PHASE_ENUM_V3` に存在しない |
| reviewer の検証行動 | prompt-engineer / code-quality の 2 reviewer が **独立に grep-confirm** して orphan claim を裏取り |
| 結果 | 0 findings / 全 severity 0 で 1 cycle mergeable |

#### Lesson

documentation が「X は orphan / no live reader / retired」のような code-state fact を主張するとき、reviewer は承認前にその claim を grep で裏取りする。書き手側の grep verify (本 page の主旨) が抜けても review-side grep verify が safety net として機能し、両者が揃うと doc-only PR でも 0 findings 1 cycle に到達できる。これは [empirical-reproduction-over-invariant-reasoning](empirical-reproduction-over-invariant-reasoning.md) (「invariant は logic 上成立」を信頼せず実測する) の documentation review への適用形でもある。

### Cycle 4 spike pattern が示す cumulative-defense 教訓

PR #677 の収束軌跡 (9 → 5 → 3 → 5 → 1 → 1 → 0) で **cycle 4 で finding 数が再 spike** したのは、cycle 1-3 では reviewer も同じ「記憶ベース hook list」を信じていたため、cycle 4 で初めて hooks.json grep evidence による検証 layer が活性化したことが原因。これは [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md) の fractal pattern とは別系統 — fix-induced drift ではなく **「reviewer 自身の SoT layer が cycle 進行で深化する」現象**。design doc PR では reviewer scope の cycle-progressive deepening を前提に、初回 cycle から registration ファイル grep を mandatory 化することで cycle 4 spike を回避できる。

### SoT 新設時の verify 義務（cycle 1-2 の実測）

`wiki:* commands` を cleanup.md スタイルへ本格フラット化した PR で、本 page の grep verification 義務が **新規 SoT documentation 作成時** にも適用される事例を実測。cycle 1 で `wiki-patterns.md` に新規 SoT セクション (YAML パース helper の分散実装一覧) を documentation 化したが、3 reviewer (prompt-engineer / error-handling / code-quality) 全員が cycle 2 で同 cluster の指摘を出した:

#### Failure 1: 列挙 site の実在 grep を怠った

新規 SoT で「以下のファイルが YAML パースを実装している」と列挙したが、列挙対象の一部 site の実在を grep で 0/1 確認しなかった。reviewer の追検証で「列挙された site は実在するが、その site は YAML パースではなく別目的の処理」が判明。

#### Failure 2: 実装 case 文 verbatim verify を怠った

「strict 4 分岐 / fail-fast」と SoT 内に semantic 要約を記述したが、実装の case 文を読まずに推測で書いた。実装は実際には `*) wiki_enabled=true` の lenient 2-arm 経路で、SoT 記述と実装が乖離。

#### Failure 3: helper 関数名を別ファイルのローカル名から複製

canonical helper (`wiki-config.sh` の `parse_wiki_scalar`) ではなく、別ファイル (`wiki-query-inject.sh`) のローカル名 `_extract_yaml_value` から複製したまま SoT に書き込んだ。

#### Canonical 対策: SoT 新設時の grep 義務 3 種

「SoT 化」は「実装に対するリンク」と「実装の semantic 要約」の 2 役割を兼ねるが、後者は実装 verbatim verify を怠ると即座に「単独で誤った仕様書」になる。経験則:

1. **site 一覧の grep 0-hit check**: 列挙対象の各 site が実在し、claimed な役割を持つかを `grep -rn` で 0/1 verify
2. **case 文 verbatim diff**: semantic 要約 (`strict 4 分岐` / `lenient 2-arm` 等) は実装 case 文を Read して verbatim diff で確認
3. **helper 関数名の定義行 grep**: helper 名は実装ファイルの function 定義行 (`function_name()` / `function function_name`) を grep で取得し canonical name を確定

#### 「最低 2 reviewer 独立検証」契約

PR #1155 では 3 reviewer が独立に同 cluster を指摘した cycle 2 経緯から、**SoT 新設 PR では最低 2 reviewer の独立 grep-confirm を mandatory acceptance criteria に含める** ことを経験則化。本 page で既述の review-side grep verify を SoT 作成 PR へ一般化したもの。

「実装に対するリンク」と「実装の semantic 要約」の 2 役割分離が drift-free 経路: semantic 要約を SoT に書かず anchor link のみとし、実装側の case 文を一次 SoT とする ([[single-sot-on-references-extract]] 参照)。

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

- [PR #677 cycle 1 review (9 findings: stale code reference cluster + schema inheritance + split-config + cross-doc)](../../raw/reviews/20260426T080650Z-pr-677.md)
- [PR #677 cycle 1 fix (44% findings traced to single root cause)](../../raw/fixes/20260426T081122Z-pr-677-cycle-1.md)
- [PR #677 cycle 2 fix (SoT verification gap + multi-location enumeration drift)](../../raw/fixes/20260426T081939Z-pr-677-cycle-2.md)
- [PR #677 cycle 3 fix (SoT grep evidence pattern 確立)](../../raw/fixes/20260426T082521Z-pr-677-cycle-3.md)
- [PR #677 cycle 4 fix (hooks.json SoT 大発見、cycle 4 spike の root cause)](../../raw/fixes/20260426T084232Z-pr-677-cycle-4.md)
- [PR #829 fix cycle 2 (design doc plan PR の 4 修正パターン: (1) 採用案 SoT 分裂を 4 箇所同期、(2) 検証 grep の syntax 不能 = markdown table cell 内 `\|` ERE alternation 不能 + BRE `+` literal 扱いで silent-pass、表内 grep を表外 fenced code block に分離、(3) 数値主張の grep 実測値乖離を再現コマンド明記で再計算、(4) scope rationale の事実誤認を表現緩和)](../../raw/fixes/20260504T232902Z-pr-829.md)
- [PR #1065 review (doc mechanism scope claim 曖昧 = `auto_demote_low` の対象を「LOW or MEDIUM」と表記したが実装は LOW のみ + 別経路を混合記述)](../../raw/reviews/20260519T195007Z-pr-1065.md)
- [PR #1065 fix (2 経路 (auto_demote_low / reviewer 直接 assign) の分離記述で doc-impl scope drift を解消)](../../raw/fixes/20260519T195351Z-pr-1065.md)
- [PR #1111 review (doc-only PR の orphan marker code-state claim を 2 reviewer が独立 grep-confirm、0 findings / 1 cycle = review-side grep verify の positive evidence)](../../raw/reviews/20260523T174827Z-pr-1111.md)
- [PR #1155 cycle 2 review (新規 SoT documentation 作成時の 3 種 factual error: site 一覧の grep 実在検証なし / 実装 case 文 verbatim verify なし / helper 関数名取り違え、3 reviewer 独立合意の cluster 形成)](../../raw/reviews/20260526T182658Z-pr-1155-cycle2.md)
- [PR #1155 cycle 2 fix (SoT 新設時の grep 義務 3 種 = site 列挙 / case 文 verbatim / helper 定義行 grep、最低 2 reviewer 独立検証の経験則化)](../../raw/fixes/20260526T183041Z-pr-1155-cycle2-fix.md)
