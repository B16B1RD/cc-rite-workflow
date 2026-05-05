# `/rite:issue:create` ゼロベース再設計 — Phase E (charter 5 自問ベース)

<!-- Section ID: SPEC-OVERVIEW -->
## 1. 概要

本 design doc は `/rite:issue:create` ワークフローを [Simplification Charter](../../plugins/rite/skills/rite-workflow/references/simplification-charter.md) の 5 自問・禁止パターン・推奨パターンに基づき**構造的にゼロベース再設計** するための plan を定義する。

本 plan は **plan ドキュメントのみ** を deliverable とする (実コードの refactor は本 plan で合意取得後、段階的 PR 3〜5 本で実施する)。

> **Note (Section ID タクソノミー)**: 本 doc は Phase E 専用の独自 Section ID (`SPEC-CHARTER-APPLICATION` / `SPEC-NEW-STRUCTURE` / `SPEC-SUBSKILL-CONSOLIDATION` 等) を使用する。既存 sibling design doc (`improve-issue-create-skill-design.md` / `refactor-create-mds-body-slimdown.md`) の 10 種固定タクソノミー (`SPEC-OVERVIEW` / `SPEC-BACKGROUND` / `SPEC-REQ-FUNC` / `SPEC-REQ-NFR` 等) とは命名が異なる。これは Phase E が charter 適用 + 段階的 PR 分割という固有の構造を持つためであり、将来 sibling と統合する際は Section 8 (PR 分割案) で各 PR の Section ID を sibling 準拠に rename する option を提示する。

### 1.1 既存 design との関係

| Design Doc | Phase | 関係 |
|-----------|-------|------|
| [`improve-issue-create-skill-design.md`](./improve-issue-create-skill-design.md) | A-D | Phase A-D の SoT (FR-1〜FR-5、NFR-1〜NFR-7、AC-1〜AC-N)。**本 plan が破壊しない保護対象** (NFR-2/3/4 は本 plan も継承) |
| [`refactor-create-mds-body-slimdown.md`](./refactor-create-mds-body-slimdown.md) | B (slim-down 段階) | charter 適用後の段階的 slim-down の前例。本 plan の段階的 PR 戦略 (Section 8) の参考 |
| **本 doc** | E | 既存 Phase A-D で残存した **構造的肥大化** (Phase 番号体系 / sub-skill 分離 / AskUserQuestion 多発) を charter 5 自問で解消 |

### 1.2 用語

| 用語 | 定義 |
|------|------|
| **charter 5 自問** | [Simplification Charter](../../plugins/rite/skills/rite-workflow/references/simplification-charter.md) の 5 つの判定基準 (runtime / 代替可否 / 説明か手順か / 重複 / 人間向け長文) |
| **Phase 番号体系** | `Phase 0.1.5` / `Phase 0.4.1` / `Phase 0.9.6` 等の小数点・3 階層 phase 番号 |
| **sub-skill 分離** | `create.md` (orchestrator) + `create-interview.md` + `create-decompose.md` + `create-register.md` + `parent-routing.md` の 5 ファイル構造 |
| **機能契約** | `pre-tool-bash-guard.sh` Bypass block / Terminal Completion pattern / AC-3 grep 検証 4 phrase / 4-site-symmetry test / sentinel emit |

<!-- Section ID: SPEC-CURRENT-STATE -->
## 2. 現状把握 (S1 実測結果)

### 2.1 ファイル構成と行数

> **集計範囲の note**: `parent-routing.md` (357 行) は `start.md` 系 sub-skill の責務であり本 plan のスコープ外 (Section 4.1 末尾参照)。ただし下表の「本体合計」は `commands/issue/` 配下のファイル所属に基づく集計のため `parent-routing.md` を含めた値を示す。本 plan で touch するスコープに限定した行数は本体合計から 357 行を除いた **1794 行** となる。

| ファイル | 行数 | 役割 | 本 plan のスコープ |
|---------|------|------|-------------------|
| `commands/issue/create.md` | 344 | orchestrator (Phase 0.1-0.6 + Delegation) | ✅ in scope |
| `commands/issue/create-interview.md` | 329 | adaptive interview (Phase 0.4.1 + 0.5) | ✅ in scope |
| `commands/issue/create-decompose.md` | 506 | XL 分解 (Phase 0.7-1.0) | ✅ in scope |
| `commands/issue/create-register.md` | 615 | 単一 Issue 作成 (Phase 1.1-4.4) | ✅ in scope |
| `commands/issue/parent-routing.md` | 357 | parent Issue 検出/分解 (Phase 1.5.1-1.5.5) | ❌ out of scope (start.md / create-* 双方から共有 invoke。本 plan では parent Issue 検出ロジック自体の再設計は scope 外) |
| **本体合計 (ファイル所属)** | **2151** | — | — |
| **本 plan スコープ内合計** | **1794** | — | — |
| `commands/issue/references/` 配下 7 ファイル | 815 | bulk-create / complexity-gate / contract-mapping / edge-cases / pre-check / slug / sub-skill-handoff | ❌ out of scope (charter 適用範囲外) |
| **総計 (ファイル所属)** | **2966** | — | — |

### 2.2 Phase 番号体系 (小数点・3 階層、grep 実測結果)

> **実測コマンド** (再現可能): 各ファイルの phase 番号は `grep -oE '^### (Phase )?[0-9]+\\.[0-9]+(\\.[0-9]+)?' <file> | sort -u` で抽出した (`create-interview.md` のみ `## Phase` heading のため `^## (Phase )?` を使用)。

| ファイル | grep 実測値 | サブセクション数 |
|---------|------------|----------------|
| `create.md` | 0.1, 0.1.3, 0.1.5, 0.3, 0.4, 0.4.2, 0.6.1, 0.6.2 (+ Termination Logic 内の `Phase 0.4` / `Phase 0.6` の参照は集計外) | 8 |
| `create-interview.md` | 0.4.1, 0.5 | 2 |
| `create-decompose.md` | 0.7.1, 0.7.2, 0.7.3, 0.8.1, 0.8.2, 0.8.3, 0.8.4, 0.9.1, 0.9.2, 0.9.3, 0.9.4, 0.9.5, 0.9.6, 1.0.1, 1.0.2, 1.0.3 | 16 |
| `create-register.md` | 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 4.1, 4.2, 4.3, 4.4 | 11 |
| `parent-routing.md` | 1.5.1, 1.5.2, 1.5.3, 1.5.4, 1.5.5 (parent-routing は start.md と create-register/create-decompose 双方から共有 invoke される。本 plan では parent Issue 検出ロジック自体の再設計は scope 外) | 5 |
| **本 plan スコープ内合計 (parent-routing 除く)** | — | **37** |
| **総計 (parent-routing 含む)** | — | **42** |

**AC-2 違反観測点**:

- 3 階層番号 (`0.1.3`, `0.1.5`, `0.4.2`, `0.6.1`, `0.6.2`, `0.7.1-3`, `0.8.1-4`, `0.9.1-6`, `1.0.1-3`, `1.5.1-5`) が **26/42** サブセクションに存在 (本 plan スコープ内では **21/37**、parent-routing 1.5.1-5 の 5 件除く)。AC-2 が許容するのは整数 + 0.x の 1 階層のみのため、**26 サブセクション (本 plan スコープ内 21 件)** が番号体系の整理対象。実測コマンド: `grep -cE '^### [0-9]+\.[0-9]+\.[0-9]+' commands/issue/create*.md commands/issue/parent-routing.md` の合計。

### 2.3 AskUserQuestion 出現箇所

| ファイル | grep -c | 主な箇所 |
|---------|---------|----------|
| `create.md` | 8 | Phase 0.1.5 (parent pre-detect) / 0.3 (similar) / 0.4 (gap fill) / 0.4 (goal class) / 0.6.2 (decompose) ほか |
| `create-interview.md` | 4 | Phase 0.5 batch B1 / B2 / follow-up / end confirmation |
| `create-decompose.md` | 2 | 分解案 review / Sub-Issue 作成確認 |
| `create-register.md` | 3 | 重複検出 / 親候補 / Issue 作成最終確認 |
| `parent-routing.md` | 3 | 子状態確認 / 分解確認 / 自動 close 確認 |
| **合計** | **20 sites** | — |

**preset 別の通過想定数** (現状):

| preset | 通過 AskUserQuestion 想定数 |
|--------|---------------------------|
| Bug Fix (短入力 + 既存 Issue 候補なし) | 4 (0.1.5 / 0.3 / 0.4 gap / 0.4 goal) |
| Bug Fix (既存候補あり) | 5 (上記 4 + Phase 0.3 候補存在時の AskUserQuestion) |
| Chore (短入力) | 4 (Bug Fix と同じ) |
| Feature M (full interview) | 6-8 (Bug Fix 4 + 0.6.2 decompose + 0.5 batch + follow-up + end-confirm) |
| Refactor M | 5-7 (Feature M とほぼ同等) |
| XL decompose | 7-10 (Feature M + create-decompose 内 2 + parent confirm) |

**AC-3 違反観測点**: AC-3 は Bug Fix/Chore で 0-1 回 / Feature/Refactor M で 2-3 回以下を要求。現状はすべての preset で AC-3 上限を超えている。

### 2.4 flow-state-update.sh 呼び出し sites

| ファイル | grep -c | 役割 |
|---------|---------|------|
| `create.md` | 8 | Delegation Pre-write / Mandatory After Step 0 / Step 1 / Mandatory After Delegation Step 1 / Step 2 ほか |
| `create-interview.md` | 6 | Pre-flight (create + patch 両 branch) / Return Output re-patch (patch のみ) ほか |
| `create-decompose.md` | 1 | Terminal Completion |
| `create-register.md` | 1 | Terminal Completion |
| `parent-routing.md` | 1 | Defense-in-depth post-parent |
| **合計** | **17 sites** | — |

**4-site 対称契約**: `create.md` Step 0 / Step 1 + `create-interview.md` Pre-flight + `create-interview.md` Return Output re-patch の **4 site** で 4 引数 symmetry (`--phase` / `--active` / `--next` / `--preserve-error-count`) を維持。test 担保は `hooks/tests/4-site-symmetry.test.sh` (本 plan の Section 7 機能契約 C-4 参照)。

### 2.5 sub-skill handoff 契約と重複 confirmation

| 契約 | 現状の散文/test 担保 | 出現箇所 |
|------|--------------------|---------|
| 4 引数 symmetry (`--phase` / `--active` / `--next` / `--preserve-error-count`) | test (`4-site-symmetry.test.sh`) + 散文 (`sub-skill-handoff-contract.md` + `create.md` + `create-interview.md` 内 blockquote) | 4 sites + test 1 |
| HTML comment sentinel (`<!-- [interview:*] -->`, `<!-- [create:completed:N] -->`) | 散文 (`create.md` Anti/Correct-pattern + `create-interview.md` Return Output Format + `create-decompose.md` / `create-register.md` Phase 1.0.x / 4.x) | 4-5 sites |
| Bypass prohibition (`pre-tool-bash-guard.sh` block) | 散文 (`create.md` `## Phase 0` 冒頭 🚫 MUST NOT) + hook 自身 | 1 散文 + hook 1 |
| AC-3 grep 検証 4 phrase (`anti-pattern` / `correct-pattern` / `same response turn` / `DO NOT stop`) | 散文 (`create.md` Anti/Correct-pattern + AC-3 grep verification blockquote) + manual grep | 1 散文 |
| Terminal Completion (`create_completed` / `active: false` / `[create:completed:N]`) | 散文 (`create.md` Mandatory After Delegation + `create-decompose.md` / `create-register.md` 各 Phase 1.0.x / 4.x) | 3 散文 + sub-skill 内製 |

**重複 confirmation 観測**:

- Phase 0.4 (goal classification) と Phase 0.4.1 (complexity-based scope) が連続 AskUserQuestion (charter 推奨パターン違反: 重複 confirmation)
- create.md Mandatory After Interview Step 0 / Step 1 が `create_post_interview` への 2 回 patch (idempotent だが charter 推奨パターン「重複 flow-state patch を排除」観点で再評価候補)

<!-- Section ID: SPEC-CHARTER-APPLICATION -->
## 3. Charter 5 自問の適用 (S2)

| # | 現状の構造 | charter 5 自問判定 | 結論 |
|---|------------|------------------|------|
| 1 | Phase 0.1.5 (parent issue pre-detection) | 自問 4 (重複): start.md Phase 0.3 にも parent detection あり。責務重複 | **統合候補** (Phase 1 = 入力分析 + parent hint 取得に統合) |
| 2 | Phase 0.4 (gap fill) + Phase 0.4 (goal classification) + Phase 0.4.1 (complexity-based scope) + Phase 0.4.2 (Skip Semantics) | 自問 4 (重複): 同一 phase 内 2-3 回連続 AskUserQuestion + skip semantics defense | **統合候補** (Phase 1 = 単一 AskUserQuestion で What/Why/Where/goal/complexity を一括取得、skip defense は Phase 1 内 invariant として記述) |
| 3 | 4-site 対称契約の散文記述 (`create.md` Step 0/1 + `create-interview.md` Pre-flight + Return Output re-patch) | 自問 1 (runtime に効かない散文) + 禁止パターン (対称化契約の散文記述) | **削除候補** (test 担保のみ、散文は 1 箇所 SoT に集約) |
| 4 | Anti-pattern / Correct-pattern 散文 (`create.md`) | 自問 5 (人間向け長文): bug 説明 + 正しい挙動説明 | **保持** (4 phrase grep 検証は AC-3 機能契約なので test 担保化を検討) |
| 5 | Bypass prohibition (`🚫 MUST NOT`) 散文 | 自問 1 (runtime に効くが hook が機能本体): 散文は LLM 向け補足 | **保持** (散文 1 箇所、hook が runtime 担保) |
| 6 | sub-skill 3 分離 (`interview` / `decompose` / `register`) | 自問 4 (重複) + 推奨パターン (sub-skill 分離は最小限): Bug Fix/Chore preset で interview を skip してそのまま register へ行くだけの場合、interview の delegate コストに見合わない | **統合候補** (interview を本体内ヘルパー化、decompose のみ別 sub-skill 維持) |
| 7 | Phase 番号 0.6.1 / 0.6.2 / 0.7.1-3 / 0.8.1-4 / 0.9.1-6 / 1.0.1-3 / 1.5.1-5 (3 階層) | 自問 5 (人間向け長文 = 詳細記述ノイズ): runtime に効くが LLM への階層的指示としては 1 階層で十分 | **整理候補** (整数 Phase + 0.x 1 階層に collapse、3 階層 → 1 階層 collapse) |
| 8 | references/ 配下 7 ファイル 815 行 | 自問 1/3 (runtime decision tree か説明か) | **保持 (charter 適用範囲外)** decision tree 系 reference は適用範囲外 (charter §「適用範囲外」) |
| 9 | 経緯記述 (Issue #444-#660 防御層導入経緯、cycle 番号付き review 記録、PR # 本文引用) が `create*.md` 本文に散在 | 自問 2 (git log で代替可) + 自問 5 (人間向け長文) + charter 禁止パターン (`Issue #N` / `PR #N` / `cycle N` 本文引用、対称化契約の散文記述) | **削除候補** (commit message + close 済み Issue で代替、本文からは grep で機械的に削除可能) |
| 10 | EDGE-3 / EDGE-4 / EDGE-5 (edge-cases-create.md) | 自問 1 (runtime decision tree) | **保持 (適用範囲外)** |

### 3.1 charter MUST NOT (適用範囲外) の確認

本 plan は以下の charter §「適用範囲外」を破壊しない:

- `plugins/rite/scripts/` 配下の .sh (`projects-status-update.sh`, `create-issue-with-projects.sh` 等) — touch しない
- `plugins/rite/hooks/` の hook 自体 — touch しない
- decision tree reference (`commands/issue/references/` 配下 **7 ファイル**: `bulk-create-pattern.md`, `complexity-gate.md`, `contract-section-mapping.md`, `edge-cases-create.md`, `pre-check-routing.md`, `slug-generation.md`, `sub-skill-handoff-contract.md`) — 全 7 ファイルを保持

ただし、**ファイル内の歴史記述ノイズの整理は対象** (charter 末尾「適用範囲外とは『ファイル丸ごと削除しない』の意味であり、ファイル内の歴史記述ノイズの整理は対象」)。

<!-- Section ID: SPEC-NEW-STRUCTURE -->
## 4. 新構造 (Phase 番号整数化)

### 4.1 Phase 番号 mapping (現状 → 新構造)

| 現状 Phase | 新 Phase | 移行戦略 |
|-----------|---------|----------|
| 0.1 (Extract) + 0.1.3 (Slug) + 0.1.5 (Parent pre-detect) + 0.3 (Similar search) | **Phase 0 (Preconditions)** | 静的処理 (Extract/Slug/Similar search) を Phase 0 に統合。Parent pre-detect は start.md 側に責務移管 (重複解消) |
| 0.4 (Quick confirm) + 0.4.1 (Complexity-based scope) + 0.4.2 (Skip semantics) | **Phase 1 (Interview)** | 単一 AskUserQuestion で What/Why/Where + goal classification + complexity を一括取得。skip semantics defense は Phase 1 内 invariant として subsection 1.0 に記述 |
| 0.5 (Deep-dive) | **Phase 1.1 (Deep-Dive subsection)** | Phase 1 の subsection。Bug Fix/Chore preset では Phase 1.1 自体を skip (現状 0.4.1 scope 制御を継承) |
| 0.6 + 0.6.1 + 0.6.2 (Decomposition decision) | **Phase 2 (Decision)** | 整数 Phase 2 に collapse。trigger 評価 (現 0.6.1) と confirmation (現 0.6.2) は subsection 2.1 / 2.2 ではなく単一 phase 内連続処理 |
| 0.7.1 / 0.7.2 / 0.7.3 / 0.8.1-4 / 0.9.1-6 / 1.0.1-3 (decompose) | **Phase 3 (Execution: Decompose path)** | 整数 Phase 3 に collapse。spec generation / Sub-Issue creation / link / Tasklist update は Phase 3 内連続処理 (subsection なし) |
| 1.1 / 1.2 / 1.3 / 2.x / 4.x (register) | **Phase 3 (Execution: Single Issue path)** | 整数 Phase 3 に collapse。classify / confirm / create / register / output は Phase 3 内連続処理 |
| 1.5.1-5 (parent-routing) | **(no change)** | parent-routing は start.md と create-register.md / create-decompose.md の双方から共有 invoke される (純粋な start.md 系ではない) が、本 plan では parent Issue 検出ロジック自体の再設計は scope 外として扱う (charter 適用は両系統横断 PR で別途) |

### 4.2 新 Phase 構造のサマリー

```
Phase 0 (Preconditions)
  - Input extraction (What/Why/Where/Scope/Constraints)
  - Slug pre-generation
  - Similar Issue search

Phase 1 (Interview)
  - Single batched AskUserQuestion (gap fill + goal + complexity)
  - Phase 1.1 Deep-Dive (only when scope >= S, batched per scope)

Phase 2 (Decision)
  - Decomposition trigger evaluation (XL + comprehensive expressions)
  - Optional confirmation (skipped for force_decompose path)

Phase 3 (Execution)
  - Single Issue path: classify + confirm + gh issue create + Projects register + output
  - Decompose path: spec generation + Sub-Issue creation + link + Tasklist + output
```

**サブセクション数**: 37 → 約 5-6 (Phase 0 / 1 / 1.1 / 2 / 3 single / 3 decompose) で **>85% 削減** (本 plan スコープ内 全 subsection 37 件 → 5-6 件、うち 21 件が AC-2 違反 (3 階層番号) で削減対象。Section 2.2 の AC-2 violation count 21 件を SoT として参照)。

### 4.3 NFR-4 (Phase 名 rename 禁止) との整合性

NFR-4 ([improve-issue-create-skill-design.md](./improve-issue-create-skill-design.md) §「非機能要件」NFR-4) は **Phase ナンバリング契約 (`Phase 0.1` / `0.4.1` / `0.6.2` 等) は hook test や stop-guard との接続点であり rename しない** と規定。

**整合性確保戦略**:

- hook test (`hooks/tests/`) と `phase-transition-whitelist.sh` 内の phase 名 (例: `create_interview` / `create_post_interview` / `create_delegation` / `create_completed`) は **flow-state レベルの phase 名** であり、本 plan の **散文上の Phase 番号 (Phase 0/1/2/3)** とは別レイヤー
- flow-state phase 名は本 plan で **rename しない** (NFR-4 遵守)
- 散文 Phase 番号 (`Phase 0.1.5` 等) を Phase 0/1/2/3 に整理しても、hook 側の `create_interview` 等は無変更

| Layer | 現状 | 新構造 | NFR-4 適用 |
|-------|------|--------|-----------|
| 散文 Phase 番号 (Markdown) | `Phase 0.1.5` 等 | `Phase 0` 等 | **rename 可** (NFR-4 適用範囲外) |
| flow-state phase 名 (`flow-state-update.sh --phase`) | `create_interview` 等 | 不変 | **rename 不可** (NFR-4 遵守) |
| `phase-transition-whitelist.sh` 内 phase token | `create_interview` 等 | 不変 | **rename 不可** (NFR-4 遵守) |

<!-- Section ID: SPEC-SUBSKILL-CONSOLIDATION -->
## 5. Sub-skill 統合検討 (S5)

| Sub-skill | 現状役割 | 統合/維持 | 根拠 |
|-----------|----------|----------|------|
| `create-interview.md` (329 行) | Phase 0.4.1 + 0.5 (interview scope + deep-dive) | **統合候補** (本体内ヘルパー化) | charter 推奨「sub-skill 分離は最小限」+ Bug Fix/Chore preset では interview を skip するだけで delegate コストに見合わない。Phase 1 (Interview) 本体内処理化で `create_interview` flow-state phase は本体内 subsection 移行で保持 |
| `create-decompose.md` (506 行) | Phase 0.7-1.0 (XL 分解) | **維持** | XL 分解は単一 Issue 作成と独立した処理経路。bulk-create-pattern.md (`references/`) の 274 行 bash literal は decompose 専用で、本体に inline すると create.md が肥大化。sub-skill 分離が複雑性管理に有効 |
| `create-register.md` (615 行) | Phase 1.1-4.4 (単一 Issue 作成) | **維持** (案 A 採用) | 単一 Issue 作成は create.md の default path であり統合候補だったが、本体に inline すると create.md が 800-900 行になり NFR-6 違反 (≤250 行) が悪化するため、**Section 5.2 案 A** に従い維持。Heuristics Scoring (Phase 1.1) の SoT は `references/complexity-gate.md` に既に集約されており、orchestrator → register sub-skill の delegate コストは現状許容範囲 |
| `parent-routing.md` (357 行) | Phase 1.5 (parent Issue handling) | **維持 (本 plan のスコープ外)** | `start.md` 系 sub-skill (Issue 開始フローの一部)、create.md の責務外 |

### 5.1 統合後の構造 (案)

```
commands/issue/
├── create.md            (orchestrator + Phase 0/1/2/3 single Issue path、推定 600-700 行 — 案 A)
├── create-decompose.md  (Phase 3 decompose path、現状維持または若干スリム化)
├── create-register.md   (Phase 3 single Issue path、現状維持 — 案 A、NFR-6 違反悪化を避けるため delegate 保持)
├── parent-routing.md    (start.md / create.md 双方から共有 invoke、本 plan スコープ外)
└── references/          (7 ファイル現状維持、charter 適用範囲外)
```

**ファイル数**: 合計 5 ファイル → **4 ファイル** (-20%、案 A 採用に伴う `create-interview.md` のみ削除)。**本 plan スコープ内行数**: 1794 → 約 1665〜1765 (-7.2%〜-1.6%、本体 +200〜+300 行 + interview 329 行削除 = ネット -29〜-129 行)。`create.md` 単体は **NFR-6 違反となる**ため、5.2 で代替案とともに明示する。

### 5.2 統合後の `create.md` 単体行数と NFR-6 違反の明示

NFR-6 ([improve-issue-create-skill-design.md](./improve-issue-create-skill-design.md):81 「`create.md` 本体 ≤250 行を目標とする」) との関係を明確化する:

- 現状 `create.md`: 344 行 (NFR-6 目標値の 1.4 倍)
- 統合後 `create.md` 推定: 600-900 行 (NFR-6 目標値の 2.4-3.6 倍)
- 比率: 1.4x → 2.4-3.6x の悪化

これは「緊張関係」ではなく **明確な NFR-6 違反** であり、本 plan は以下の代替案も含めて Section 8 段階的 PR で評価する:

| 代替案 | 説明 | trade-off |
|-------|------|-----------|
| **案 A (採用)**: `create-interview.md` のみ統合 | `create-register.md` は維持。本体は約 544-644 行 (Section 5.1 ledger SoT、本体 344 + 200〜300 行) | NFR-6 違反は維持されるが軽減 (1.4x → 2.2-2.6x)、interview の delegate コスト削減 |
| **案 B**: `create-interview.md` + `create-register.md` 両方統合 | 本体は約 800-900 行 | NFR-6 違反が悪化 (3.2-3.6x)、ただし sub-skill 数最小 (3 ファイル) |
| **案 C**: 統合せず散文削減のみ | sub-skill 構成は現状維持、散文 charter 5 自問削減のみ実施 | NFR-6 達成は不可能 (本体 344 行のうち散文削減で目標 250 行は構造的に困難)、AC-1 の「本体 1〜2 ファイル」要件未達 |

**判断**: 案 A を default 採用とし、PR-E4 着手時に 544-644 行が NFR-6 violation として許容範囲か再評価する。NFR-6 が「目標 (target)」か「上限 (cap)」かは sibling design doc に明記されておらず、本 plan の段階的 PR で SoT 化候補となる。

<!-- Section ID: SPEC-ASKUSERQUESTION-REDUCTION -->
## 6. AskUserQuestion 削減戦略 (S6)

### 6.1 preset 別 AskUserQuestion 通過数 (現状 → 統合後)

| preset | 現状通過数 | 統合後通過数 | AC-3 閾値 | 適合 |
|--------|----------|-------------|----------|------|
| Bug Fix (短入力 + 既存 Issue 候補なし) | 4 | **1** (Phase 1 単一 batch、What/Why/Where/goal 一括) | 0-1 | ✅ |
| Bug Fix (既存候補あり) | 5 | **1-2** (Phase 0 similar search を skip 可能化 + Phase 1) | 0-1 | ✅ (similar search の skip 設計に依存) |
| Chore (短入力) | 4 | **1** (同 Bug Fix) | 0-1 | ✅ |
| Feature M (full interview) | 6-8 | **2-3** (Phase 1 batch + Phase 1.1 Deep-Dive batch + 任意 follow-up) | 2-3 | ✅ |
| Refactor M | 5-7 | **2-3** (同 Feature M) | 2-3 | ✅ |
| XL decompose | 7-10 | **3-4** (Phase 1 batch + Phase 1.1 + Phase 2 confirm + decompose review) | (AC-3 対象外) | — |

### 6.2 削減メカニズム

| メカニズム | 削減対象 | 効果 |
|-----------|---------|------|
| **Phase 1 単一 batch** | Phase 0.4 gap fill + Phase 0.4 goal classification + Phase 0.4.1 complexity scope + Phase 0.4.2 skip semantics defense | 連続 3-4 段階処理 → 1 回 (skip semantics は invariant 化) |
| **Parent pre-detection 削除** | Phase 0.1.5 (start.md 側に責務移管) | 1 回削減 |
| **Similar Issue search 条件付き skip** | Phase 0.3 (候補なし時 skip 既存、候補あり時のみ ask) | 0-1 回 |
| **Phase 1.1 Deep-Dive batch 維持** | Phase 0.5 batch B1/B2 既存 batching を継承 | 既存削減幅維持 |
| **End confirmation dialog 既存維持** | Phase 0.5 end confirmation | 既存削減幅維持 (UX-2: AI auto-termination 禁止のため削除不可) |

### 6.3 制約

- **AskUserQuestion 削減は user judgment escape hatch を破壊しない**: charter 推奨パターン「**user judgment** を仰ぐ場面の維持」と「**AI による暗黙判断** の排除」を両立。Phase 1.1 Deep-Dive end confirmation (UX-2) は維持
- **EDGE-2 / EDGE-3 / EDGE-4 / EDGE-5 のロジック** (`edge-cases-create.md` の現状記述) は AskUserQuestion 削減後も保持。各 EDGE は AskUserQuestion 1 件以上を含むため、合計通過数の見積もりに含める必要あり

<!-- Section ID: SPEC-FUNCTIONAL-CONTRACT -->
## 7. 機能契約保持マッピング (S7)

| # | 機能契約 | 現状参照箇所 | 再設計後の保持戦略 | grep 検証式 |
|---|---------|-------------|-----------------|------------|
| C-1 | `pre-tool-bash-guard.sh` Bypass block | `create.md` `## Phase 0` 冒頭 🚫 MUST NOT | 新 Phase 0 冒頭の `🚫 MUST NOT` block を維持 (散文 1 箇所) + hook 自身 (runtime 担保) | `grep -c '🚫 MUST NOT' commands/issue/create.md` >= 1 |
| C-2 | Terminal Completion pattern (`create_completed` / `active: false` / `[create:completed:N]`) | `create.md` Mandatory After Delegation + `create-decompose.md` / `create-register.md` 各 Phase 1.0.x / 4.x | 新 Phase 3 (single Issue / decompose 両 path) の末尾に Terminal Completion を保持。散文 SoT は 1 箇所、各 path は手順記述のみ | `grep -c 'create_completed\|\[create:completed:' commands/issue/create.md` >= 2 |
| C-3 | AC-3 grep 検証 4 phrase | `create.md` Anti/Correct-pattern + AC-3 blockquote | 散文 Anti/Correct-pattern を Phase 1 (interview return 直前) に integrate。4 phrase は **本体に保持** (AC-4 grep verification 用) | `for p in "anti-pattern" "correct-pattern" "same response turn" "DO NOT stop"; do grep -c "$p" commands/issue/create.md; done` 全 1 以上 |
| C-4 | 4-site-symmetry test (`hooks/tests/4-site-symmetry.test.sh`) | `create.md` Step 0/1 + `create-interview.md` Pre-flight / Return Output (4 sites + test) | sub-skill 統合 (S5) で `create-interview.md` を本体内化する場合、4 site が 2 site (本体内) に collapse 可能 → test 側 scope 縮小 (or 廃止) を S8 で検討。hook test 側の cli 引数 symmetry 検証は **--phase / --active / --next / --preserve-error-count** の 4 引数を継続検証 | `bash plugins/rite/hooks/tests/4-site-symmetry.test.sh` exit 0 |
| C-5 | sentinel emit (`<!-- [interview:*] -->`, `<!-- [create:completed:N] -->`) | sub-skill return 時 / Terminal Completion 時 | sub-skill 統合 (S5) で `[interview:*]` sentinel は本体内 phase transition (`create_post_interview` flow-state patch) に置換可能。`[create:completed:N]` は Terminal Completion 必須として維持 | `grep -c '\[create:completed:' commands/issue/create.md` >= 2 |

### 7.1 4-site-symmetry test スコープ縮小可能性 (R15)

`hooks/tests/4-site-symmetry.test.sh` は現状 `create.md` (2 occurrence: Step 0 + Step 1) と `create-interview.md` (2 occurrence: Pre-flight + Return Output) の **4 occurrence** を grep 検証。

S5 で `create-interview.md` を本体内化する場合:

- **option A**: `create.md` 本体内に Pre-flight + Return Output の 2 site を保持 → test scope 4 site (現状維持) で OK
- **option B**: 本体内化により Pre-flight が不要に。Step 0/Step 1 のみ残存 → test scope 2 site に縮小、test 自体は単純化
- **option C**: 本体内化により Step 0/Step 1 + Return Output 全部不要 (本体内処理は flow-state patch を 1 回で完結) → test 廃止可能

S8 段階的 PR で option を選択。**廃止判断は flow-state phase transition の defense-in-depth 喪失リスク** (sub-skill が turn を閉じる現象起因の防御層) と引き換えなので、慎重に評価。

<!-- Section ID: SPEC-PR-DECOMPOSITION -->
## 8. 段階的リファクタ PR 分割案 (S8)

### 8.1 PR 分割案 (4 本構成、charter 5 自問 pass 戦略付き)

| PR # | scope | 主な AC | 検証手順 | 想定行数変動 |
|------|-------|---------|---------|-------------|
| **PR-E1** | charter 5 自問適用による散文削除 (本文中の経緯記述 / 4-site 対称契約散文 / 重複 confirmation 散文) | charter 5 自問 1/2/3 pass; AC-4 機能契約 (C-1〜C-5) grep 全 pass; 既存 e2e test 3 経路 pass | (a) 本文引用件数を測定 (検証コマンドは下記 §8.1.1)、(b) AC-4 grep 検証式実行 (Section 7 の C-1〜C-5 全 pass)、(c) e2e test (Bug Fix preset / single Issue M / XL decompose) 各 1 回手動実行 | 本体 -150〜-300 行 |
| **PR-E2** | Phase 番号整数化 (現状 37 サブセクション (本 plan スコープ内、Section 2.2) → 5-6 サブセクション (Section 4.2)、うち 21 件が AC-2 違反 (3 階層番号) で削減対象。Section 4 mapping 表に従う) | AC-2 (整数 + 0.x の 1 階層、AC-2 違反 21 件 → 0 件) ; flow-state phase 名 NFR-4 (rename 禁止) 遵守 | (a) 3 階層 0 件確認 (検証コマンドは下記 §8.1.1)、(b) hook test (`phase-transition-whitelist.sh` source check) pass、(c) e2e test 3 経路 pass | 散文行数 +50〜100 (Phase 番号統合に伴う mapping 表追加)、構造的圧縮で本体は -100〜-200 行 |
| **PR-E3** | AskUserQuestion 統合 (Phase 0.4 / 0.4.1 / 0.4.2 を Phase 1 単一 batch に統合、Phase 0.1.5 parent pre-detection 削除) | AC-3 (Bug Fix/Chore で 0-1 回 / Feature M で 2-3 回以下); EDGE-2/3/4/5 ロジック保持 | (a) `[interview:*]` / `[create:*]` sentinel emit を grep して各 preset で発火 sentinel 数を測定、(b) 各 preset を実機実行して `AskUserQuestion` tool 呼び出し回数を手動カウント (transcript ベース) し PR description に記録、(c) e2e test 3 経路 pass | 本体 -50〜-100 行 |
| **PR-E4** | sub-skill 統合 (`create-interview.md` を本体内ヘルパー化、案 A 採用) + 4-site-symmetry test scope 調整 + NFR-6 違反評価 | AC-1 (新規 contributor が本体 1〜2 ファイル把握); AC-4 機能契約 grep 全 pass; 4-site-symmetry test 縮小後も pass; NFR-6 違反の許容範囲を SoT 化 | (a) `wc -l commands/issue/*.md` でファイル数縮小確認 (5 → **4 ファイル**想定、案 A)、(b) 4-site-symmetry test exit 0 (option 選択次第で test スコープ縮小)、(c) e2e test 3 経路 pass、(d) `create.md` 単体行数を NFR-6 目標値 250 と比較し、許容判断を PR description に明記 | 本体 +200〜+300 (interview 統合) / 全体 -329 行 (interview ファイル削除) → ネット **-29〜-129 行** (Section 5.1 の本 plan スコープ内 1665〜1765 行推定と整合 — Section 5.1 の ledger を SoT として参照。PR-E1〜E3 の散文削減 (-300〜-600 行) は別系統で本数値には含まない) |

### 8.1.1 検証コマンド集

各 PR の検証手順 (a) で参照する grep コマンドは raw markdown source からそのまま copy して動作するよう、表外の fenced code block にて記述する (markdown table cell 内の `|` escape による silent fail を回避):

```bash
# PR-E1: 全 sub-skill ファイル横断の本文引用件数測定 (charter 禁止パターンの 3 種を ERE alternation で検出)
# PR 着手前後で件数が減少していることを確認する
grep -rcE 'Issue #[0-9]+|PR #[0-9]+|cycle [0-9]+' \
  plugins/rite/commands/issue/create.md \
  plugins/rite/commands/issue/create-interview.md \
  plugins/rite/commands/issue/create-decompose.md \
  plugins/rite/commands/issue/create-register.md \
  plugins/rite/commands/issue/parent-routing.md
```

```bash
# PR-E2: 3 階層 phase 番号 (0.x.y) が 0 件であることを確認 (ERE で `+` 量指定子を有効化)
# `-cE` 必須 — `-c` (BRE) では `+` がリテラル扱いとなり常に 0 件で silent-pass する
grep -cE '^### [0-9]+\.[0-9]+\.[0-9]+' \
  plugins/rite/commands/issue/create.md \
  plugins/rite/commands/issue/create-interview.md \
  plugins/rite/commands/issue/create-decompose.md \
  plugins/rite/commands/issue/create-register.md
```

### 8.2 各 PR の charter 5 自問 pass 戦略

各 PR description に以下のフォーマットで charter 5 自問の判定結果を明記する:

```markdown
## charter 5 自問 pass 判定

| 自問 | 判定 | 根拠 |
|------|------|------|
| 1. runtime に効くか? | ✅ | 削除した行は (a) 経緯記述 / (b) 重複 patch / (c) 散文契約 のみ |
| 2. git log で代替可? | ✅ | 削除した経緯記述は commit message #N に保持 |
| 3. 説明か手順か? | ✅ | 削除は説明のみ、手順は維持 |
| 4. 重複 confirmation? | ✅ | Phase X の 重複 patch を統合 |
| 5. LLM 向けか人間向けか? | ✅ | LLM 向け SoT を 1 箇所に集約、人間向け経緯は git log に逃した |
```

### 8.3 e2e test 3 経路の前提

| 経路 | 現状の test 環境 | 本 plan での対応 |
|------|----------------|----------------|
| Bug Fix preset (`/rite:issue:create "Fix typo in README"`) | ad-hoc 手動実行 | 各 PR で手動実行、結果は PR description に記録 |
| Single Issue M (`/rite:issue:create "Add user logout endpoint"`) | ad-hoc 手動実行 | 各 PR で手動実行、結果は PR description に記録 |
| XL decompose (`/rite:issue:create "Build user management system"`) | ad-hoc 手動実行 | 各 PR で手動実行、結果は PR description に記録 |

**test 整備の先行 PR 検討**: 上記 3 経路を自動化する e2e test がない場合、PR-E1 の前に test 整備 PR (PR-E0) を入れる選択肢もあり。本 plan では PR-E0 を **必要時 option** とし、最終判断は PR-E1 着手時に行う。

### 8.4 Wiki 経験則の反映 (R16-R18)

| 経験則 | 本 plan での反映 |
|--------|----------------|
| **Asymmetric Fix Transcription** (sibling site への伝播漏れ) | PR-E2/E3/E4 で散文修正時、sub-skill 跨ぎの sibling site (例: `create-interview.md` Pre-flight / Return Output / `create.md` Step 0/1) の 4 引数 symmetry を **PR ごとに 4-site-symmetry test 自動実行** で担保 |
| **圧縮 refactor の AC は protected 区域 + scope 制約から逆算** | PR-E2 の Phase 番号整数化で行数 AC を野心目標で決め打ちしない。protected 区域 (機能契約 C-1〜C-5 の散文必須行) と SPEC-OUT-OF-SCOPE 制約 (`references/` 不変) を実測してから AC を逆算。NFR-6 (≤250 行) 違反の許容判断は PR-E4 の SoT 化で確定 |
| **Markdown 大規模圧縮時の heading hierarchy skip 防止** | PR-E1〜E4 で全 PR で `grep -cE '^####+ ' file.md` を実行し h2→h4 skip の有無を確認 (h2 直後に h4 が出現していないか) |

<!-- Section ID: SPEC-VALIDATION -->
## 9. Validation Plan

### 9.1 各 PR の merge 条件

各 PR を `develop` に merge する前に以下を全て pass:

1. **charter 5 自問 pass 判定** が PR description に明記
2. **AC-1 〜 AC-5** のうち本 PR の scope 該当 AC を grep + manual 検証で pass
3. **既存 hook test** (`hooks/tests/`) 全件 pass (`bash plugins/rite/hooks/tests/run-tests.sh` 等)
4. **`/rite:lint`** で blocking issue なし
5. **e2e test 3 経路** (Bug Fix / single Issue / XL decompose) を手動実行し、PR description に結果記録

### 9.2 Rollback 戦略

各 PR は独立 commit + revert 可能な単位として作成。回帰検出時は該当 PR を revert することで段階的 rollback。NFR-5 (可逆性) を継承。

<!-- Section ID: SPEC-DECISION-LOG -->
## 10. Decision Log

| 日付 | 決定事項 | 根拠 |
|------|---------|------|
| 2026-05-05 | 本 plan は plan ドキュメントのみを deliverable とし、実コード refactor は段階的 PR 4 本で実施 | Issue #823 DoD 第 1 項「plan ドキュメント作成 → user 合意」、Operational Context「まず plan 作成 → user 合意 → 段階的リファクタの方針」 |
| 2026-05-05 | sub-skill 統合は `create-interview.md` のみ (案 A 採用)。`create-decompose.md` / `create-register.md` は維持 | charter 推奨パターン「sub-skill 分離は最小限」+ bulk-create-pattern.md (274 行 bash literal) を本体に inline すると create.md が肥大化し NFR-6 違反が悪化するため |
| 2026-05-05 | 4-site-symmetry test の廃止判断は PR-E4 内で 3 option (A/B/C) のいずれを選択するかと連動 | flow-state phase transition の defense-in-depth 喪失リスクとの trade-off |
| 2026-05-05 | flow-state phase 名 (`create_interview` 等) は本 plan で rename しない | NFR-4 (Phase ナンバリング契約は hook test や stop-guard との接続点) 遵守 |
| 2026-05-05 | references/ 配下 7 ファイル (`bulk-create-pattern.md`, `complexity-gate.md`, `contract-section-mapping.md`, `edge-cases-create.md`, `pre-check-routing.md`, `slug-generation.md`, `sub-skill-handoff-contract.md`) は本 plan で touch しない | charter §「適用範囲外」(decision tree 系 reference は適用範囲外) 遵守 |
| 2026-05-05 | NFR-6 (`create.md` ≤250 行) との関係を「明確な NFR-6 違反」と認識 (Section 5.2)。許容範囲の SoT 化は PR-E4 内で確定 | 統合後 600-900 行は NFR-6 目標値の 2.4-3.6 倍であり、「緊張関係」表現では問題の重大性が伝わらないため |
| 2026-05-05 | Section ID タクソノミーは Phase E doc 専用の独自命名を採用 (Section 1 冒頭 Note 参照) | sibling design doc 2 件の固定タクソノミーは Phase A-D 用に最適化されており、Phase E (charter 適用 + 段階的 PR 分割) の固有構造を表現するには不十分 |
| 2026-05-05 | `bulk-create-pattern.md` の Pre-amble + Per-Sub-Issue body 連結契約は実装契約として保持 | Issue #823 § 2 Out of Scope で MUST 保持と明記、charter §「適用範囲外」の bash literal 該当 |

---

> 本 design doc は Issue #823 の DoD 第 1 項「plan ドキュメント作成 → user 合意」のための plan deliverable。後続の段階的 refactor PR (PR-E1 〜 PR-E4) は本 plan で合意取得後に着手する。
