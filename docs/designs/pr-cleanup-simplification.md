# `/rite:pr:cleanup` Simplification — Phase 0-C (charter 適用)

<!-- Section ID: SPEC-OVERVIEW -->
## 1. 概要

本 design doc は `/rite:pr:cleanup` ワークフローを [Simplification Charter](../../plugins/rite/skills/rite-workflow/references/simplification-charter.md) に従って整理するための plan を定義する。先行 simplification 系列（`/rite:issue:create` 配下、§1.1 参照）の retrospective を反映した構造で組む。

本 plan は **plan ドキュメントのみ** を deliverable とする。実コード変更は本 plan 合意後、段階的 PR で実施する。

### 1.1 既存 design との関係

| Design Doc | 役割 | 本 plan との関係 |
|-----------|------|----------------|
| [`simplification-charter.md`](../../plugins/rite/skills/rite-workflow/references/simplification-charter.md) | 5 自問・禁止パターン・推奨パターンの SoT | 本 plan が依拠する判断基準 |
| [`improve-issue-create-skill-design.md`](./improve-issue-create-skill-design.md) | issue:create simplification (Phase A-D) | 本 plan の retrospective 元 |
| [`issue-create-zerobase-redesign.md`](./issue-create-zerobase-redesign.md) | issue:create ゼロベース再設計 (Phase E) | scope 切り方の前例 |

### 1.2 用語

| 用語 | 定義 |
|------|------|
| **charter 5 自問** | runtime / 代替可否 / 説明か手順か / 重複 / 人間向け長文 の 5 判定基準 |
| **charter 禁止パターン** | `Issue #N` 本文引用 / `cycle N` 記録 / 散文対称化契約 / `🚨` 濫用 等 |
| **Sub-skill Return Protocol** | sub-skill 終了後の caller 側継続義務を定義する protocol セクション。`start.md` / `create.md` / `cleanup.md` / `wiki/ingest.md` の 4 site に散文として存在 |

---

<!-- Section ID: SPEC-CURRENT-STATE -->
## 2. 現状把握 (実測)

### 2.1 ファイル構成と行数

| ファイル | 行数 | 役割 |
|---------|------|------|
| `commands/pr/cleanup.md` | 1902 | orchestrator (Phase 1.0/1/1.7/2/3/4.W/5 + Sub-skill Return Protocol + Issue 本文テンプレ) |
| `commands/pr/references/archive-procedures.md` | 621 | Phase 3-4 (Projects Status Update, Issue close) extract |
| `commands/pr/references/internal-consistency.md` | 396 | review reference |
| `commands/pr/references/fact-check.md` | 436 | review reference |
| `commands/pr/references/bash-trap-patterns.md` | 374 | bash trap pattern SoT (cleanup/fix/review/wiki/lint/wiki/ingest 5 site から参照) |
| `commands/pr/references/assessment-rules.md` | 157 | review assessment rules |
| `commands/pr/references/review-context-optimization.md` | 108 | review context |
| `commands/pr/references/reviewer-fallbacks.md` | 106 | reviewer fallback |
| `commands/pr/references/change-intelligence.md` | 93 | change classification |
| `commands/pr/references/fix-relaxation-rules.md` | 57 | fix relaxation rules |
| **本体合計** | **4250** | — |

### 2.2 charter 違反引用箇所 (grep 実測)

実測コマンド (再現可能):

```bash
grep -cE "Issue #[0-9]+|PR #[0-9]+|cycle [0-9]+|Drift guard|DRIFT-CHECK|4-site" \
  commands/pr/cleanup.md commands/pr/references/*.md \
  commands/pr/fix.md commands/pr/review.md commands/pr/create.md commands/pr/ready.md
```

| ファイル | 違反件数 | 主因 |
|---------|---------|------|
| `pr/review.md` | **63** | cycle N 引用が大量 (review SoT) |
| `pr/fix.md` | **48** | cycle N 引用 + `verified-review cycle N` 公式定義 (line 17) |
| `pr/cleanup.md` | **43** | Issue # / cycle # / DRIFT-CHECK ANCHOR の歴史記述 |
| `pr/references/bash-trap-patterns.md` | 19 | verified-review cycle N の経緯 |
| `pr/references/internal-consistency.md` | 9 | review reference 内の経緯 |
| `pr/references/fact-check.md` | 2 | 〃 |
| `pr/references/archive-procedures.md` | 4 | 〃 |
| `pr/create.md` | 4 | 軽微 |
| `pr/ready.md` | 3 | 軽微 |
| その他 reference (4 ファイル) | 0 | 違反なし |

### 2.3 Sub-skill Return Protocol の重複 (4 site 散文)

実測:

```bash
grep -l "Sub-skill Return Protocol" plugins/rite/commands/**/*.md
```

| Site | ファイル | 占有行数の目安 |
|------|---------|---------------|
| 1 | `issue/start.md` | 〜80 行 |
| 2 | `issue/create.md` | 〜30 行 (canonical 化済み) |
| 3 | `pr/cleanup.md` | **〜100 行** (lines 25-122) |
| 4 | `wiki/ingest.md` | 〜60 行 |

**観測**: `pr/cleanup.md` の Sub-skill Return Protocol が最も肥大 (Item 0 の routing dispatcher、4 種 marker、HTML コメント形式の指示で長大化)。

### 2.4 cycle N 用語の SoT 経路

`pr/fix.md:17`:

```
- `verified-review cycle N` — N 回目のレビュー・修正サイクル
```

→ **charter 禁止パターンが SoT として公式定義されている**。LLM はこの定義に従って commit message / 本体記述に `cycle N` を書く。これを撤廃しない限り charter 違反は連鎖し続ける。

### 2.5 cleanup.md 本体の Phase 構造

| Phase | 行範囲 | 行数 | 主な責務 |
|-------|-------|------|---------|
| 冒頭 (Contract / Args / Sub-skill Return Protocol) | 1-122 | 122 | **Sub-skill Return Protocol が 100 行** |
| Phase 1.0 (Activate Flow State) | 122-175 | 53 | 単純な flow-state activate |
| Phase 1 (State Verification) | 175-617 | **442** | branch detect / PR fetch / Issue 識別 / state validation |
| Phase 1.7 (Incomplete Tasks Auto-Assessment) | 617-865 | 248 | 未完 task の自動判定 |
| Issue/PR 本文テンプレ | 865-1083 | 218 | 概要/背景/関連Issue/変更内容/複雑度/チェックリスト |
| Phase 2 (Cleanup Execution) | 1083-1410 | 327 | branch delete / Status update |
| Phase 3 (Projects Status Update) | 1410-1416 | 6 | **archive-procedures.md に extract 済 (stub)** |
| Phase 4.W (Wiki Auto-Ingest) | 1416-1704 | 288 | conditional wiki ingest |
| Phase 5 (Completion Report) | 1704-1891 | 187 | 完了報告 + flow-state deactivate |
| Error Handling | 1891-1902 | 11 | — |

**観測**: 上位 3 セクション (Sub-skill Return Protocol / Phase 1 / Phase 4.W) で計 830 行 (44%) を占める。この 3 つが整理の主戦場。

---

<!-- Section ID: SPEC-RETROSPECTIVE -->
## 3. 先行 simplification 系列の retrospective

### 3.1 想定通りに進んだこと（生かす）

- charter を独立 PR (Phase A) で先に成立させる戦略 → 以降の判断基準が安定
- 機械的削除 (grep ベース) は規模が大きくても review しやすい
- 1 PR 1 焦点に分けると review 負荷が低い

### 3.2 想定外（構造を見直す）

- 「1 PR 1 Phase」が実態として「1 PR 1 ファイル / 1 焦点」に細分化された
  - → 本 plan では **最初から「1 PR 1 ファイル / 1 焦点」を前提に Phase を切る**
- 「scope 外」と書いた Phase E が直後に着手された
  - → 本 plan では **Phase D 以降を事前に書かない**。Phase A-C 完了後に再評価
- ゼロベース再設計で sub-skill 統合は実装段階で見送り判断
  - → 本 plan では **構造変更を plan で決め切らない**。ファイル単位削減に絞る

### 3.3 反省点（仕組みで防ぐ）

- charter で禁止した `cycle N` が commit message に残り続けた
  - → 本 plan の **Phase 0** で SoT 撤廃 + 違反検出 hook を導入
- plan ファイルが `~/.claude/plans/` で git 管理外
  - → 本 plan は最初から `docs/designs/` に commit

---

<!-- Section ID: SPEC-CHARTER-APPLICATION -->
## 4. Charter 5 自問の適用

### 4.1 cleanup.md 本体への適用

| セクション | Q1 runtime? | Q2 git log で代替? | Q3 説明か手順か | Q4 重複? | Q5 LLM 向けか | 判定 |
|-----------|------------|-------------------|----------------|---------|--------------|------|
| Sub-skill Return Protocol Item 0 (routing dispatcher 100 行) | 一部 runtime (HTML evidence 出力義務) | 経緯記述部分は git log で代替可 | 大半が「なぜこの 4 種 marker か」の説明 | **4 site で散文重複** | 一部メンテナ向け長文 | **slim 化必須** (現 100 行 → 〜30 行) |
| Phase 1 State Verification の Issue # / cycle N 引用 | 否 | 可 | 説明 | — | 人間向け | **削除** |
| Phase 4.W DRIFT-CHECK ANCHOR 散文 | 否 (test で担保すべき) | 可 | 説明 | — | 人間向け | **削除 + test 化** |
| Issue/PR 本文テンプレ (lines 865-1083) | runtime | 否 | 手順 | 否 | LLM 向け | **保持** |
| bash literal (各 Phase) | runtime | 否 | 手順 | 否 | LLM 向け | **保持** |
| MUST / MUST NOT 条文 | runtime | 否 | 手順 | 否 | LLM 向け | **保持** |

### 4.2 references/ への適用

| ファイル | 違反件数 | 判定 |
|---------|---------|------|
| `archive-procedures.md` (621) | 4 | **slim 化** (経緯削除のみ。逆統合は cleanup.md 肥大化を招くため見送り) |
| `bash-trap-patterns.md` (374) | 19 | **slim 化** (rationale を保持し、verified-review cycle N の経緯を削除) |
| `internal-consistency.md` (396) | 9 | **slim 化** (review 系 reference として残し、経緯のみ削除) |
| `fact-check.md` (436) | 2 | 軽微 (経緯 2 件削除のみ) |
| `assessment-rules.md` / `change-intelligence.md` / `fix-relaxation-rules.md` / `review-context-optimization.md` / `reviewer-fallbacks.md` | 0-1 | **現状維持** (charter 違反なし) |

### 4.3 cycle N 用語

`pr/fix.md:17` の `verified-review cycle N` 公式定義は **削除**。代わりに用語を導入しない（「N 回目のレビュー」と言う必要があれば散文で書ける）。既存引用 (review.md 63 / fix.md 48 / cleanup.md 43 / bash-trap-patterns.md 19) は **grep ベースで機械的に削除**。

---

<!-- Section ID: SPEC-PHASE-DESIGN -->
## 5. Phase 設計

### Phase 0 — rite 全体の charter 違反防止 (cleanup リファクタの prerequisite)

cleanup.md だけでなく review.md / fix.md / bash-trap-patterns.md にも cycle N が散在しているため、**Phase 0 は rite 全体に効く独立 Issue として起票**する。

#### Phase 0a — `cycle N` SoT 撤廃と既存引用削除

**対象**:
- `pr/fix.md:17` の `verified-review cycle N` 公式定義を削除
- `pr/review.md` (63 件) / `pr/fix.md` (48 件) / `pr/cleanup.md` (43 件) / `pr/references/bash-trap-patterns.md` (19 件) / `pr/references/internal-consistency.md` (9 件) / `pr/references/fact-check.md` / `pr/references/archive-procedures.md` の cycle N 引用を grep ベースで削除
- `Issue #[0-9]+ で.*対応` のような経緯引用も同時に整理

**作業単位**: 1 PR 1 ファイル（最大規模 review.md / fix.md は単独 PR、他はまとめても可）

**検証**:
```bash
grep -cE "cycle [0-9]+|verified-review cycle" plugins/rite/commands/pr/*.md plugins/rite/commands/pr/references/*.md
```
→ 全件 0 になること

#### Phase 0b — commit-msg 違反検出 hook

**対象**: `plugins/rite/hooks/pre-tool-bash-guard.sh` を拡張し、`git commit -m`（および `git commit -F`）の message を charter pattern で検査する。

**検出 pattern**:
- `cycle [0-9]+`
- `verified-review cycle`
- `Issue #[0-9]+ で[^\n]{1,40}(対応|修正|fix|review)` (経緯記述)

**動作**:
- デフォルト: warn（stderr に警告メッセージ、commit は通す）
- `RITE_COMMIT_LINT_STRICT=true` 環境変数で block (exit 非 0)

**検証**:
- `plugins/rite/hooks/tests/` に新規 test を追加
- charter pattern を含む commit が warn / block されること
- 含まない通常 commit が通ること

### Phase A — charter の cleanup 系適用宣言

**対象**:
- `plugins/rite/skills/rite-workflow/SKILL.md` の charter 参照ブロックに「pr/cleanup 系も charter 対象」と明記
- `commands/pr/cleanup.md` 冒頭に charter 参照を 1 行追加（既に runtime に効いている既存 SKILL.md 経由の参照と整合確認）
- `commands/pr/references/` 各ファイル冒頭に SoT 参照行を追加（既存のものは流用）

**作業単位**: 1 PR、本体修正なし

### Phase B — references/ の 1 ファイル 1 PR で評価

violation 件数の多い順に処理。

| PR | 対象 | 想定 diff |
|----|------|----------|
| B1 | `bash-trap-patterns.md` (374, 違反 19) | rationale 保持、verified-review cycle N の経緯削除。-100〜-150 行想定 |
| B2 | `internal-consistency.md` (396, 違反 9) | 経緯削除。-50〜-80 行想定 |
| B3 | `archive-procedures.md` (621, 違反 4) | 軽い経緯削除。-30〜-50 行想定 (大幅 slim は構造変更を伴うため見送り) |
| B4 | `fact-check.md` (436, 違反 2) | 軽微整理。-10〜-30 行想定 |

**作業単位**: B1 / B2 / B3 / B4 の各 PR、1 PR 1 ファイル

### Phase C — cleanup.md 本体 slim 化

**対象**: 4.1 で「slim 化必須」「削除」と判定したセクション。

| PR | 対象 | 想定 diff |
|----|------|----------|
| C1 | Sub-skill Return Protocol slim (100 → 〜30 行) | -70 行。Item 0 routing dispatcher の経緯記述削除。**4 site 横断はせず cleanup.md 内のみ** (他 site は別 Issue) |
| C2 | Phase 1 / Phase 4.W の Issue # / cycle # / DRIFT-CHECK 散文削除 | -100〜-150 行 |
| C3 | （余地があれば）Phase 4.W の sentinel emit 経路を test 化して散文削除 | 別 Issue 推奨 |

**作業単位**: C1 / C2 を独立 PR

### Phase D 以降は事前に書かない

先行 simplification 系列の retrospective より、Phase A-C 完了後に再評価する。事前に書くと着手を誘発するだけ。

候補（参考、本 plan のスコープ外）:
- Sub-skill Return Protocol の 4 site 共通 SoT 化（`start.md` / `create.md` / `cleanup.md` / `wiki/ingest.md`）
- pr/review.md / pr/fix.md の slim 化（cleanup と同型の症状あり）
- archive-procedures.md の構造変更（cleanup.md への逆統合 or 完全 SoT 化）

---

<!-- Section ID: SPEC-CONTRACTS -->
## 6. 機能契約 (壊さないもの)

slim 化作業中、以下は **runtime に効くため絶対に壊さない**:

| C-N | 契約 | 担保方法 |
|-----|-----|---------|
| C-1 | `git symbolic-ref` による base branch 検出と fail-fast (lines 195-220 付近) | bash literal 保持 |
| C-2 | `bash plugins/rite/hooks/flow-state-update.sh patch --phase ... --active ... --next ... --preserve-error-count` の 4 引数 symmetry | `hooks/tests/4-site-symmetry.test.sh` |
| C-3 | Phase 5 terminal `<!-- [cleanup:completed] -->` inline sentinel | bash literal + 既存 grep test |
| C-4 | `archive-procedures.md` への Phase 3.2 delegation | bash literal 保持 |
| C-5 | `wiki-ingest-trigger.sh` Phase 4.W gate | hook script 保持 |
| C-6 | Sub-skill Return Protocol の **routing dispatcher の HTML evidence 出力義務** (Item 0) | runtime に効くため slim 化対象から除外 |
| C-7 | `pre-tool-bash-guard.sh` の既存 Bash 検査ロジック | Phase 0b で **追加のみ**、既存削除なし |

---

<!-- Section ID: SPEC-PR-PLAN -->
## 7. PR 分割案と Issue 構造

### 7.1 Issue 構造（2 Issue）

| Issue | タイトル | スコープ | PR 数 |
|-------|---------|---------|------|
| **Issue X** | rite charter 違反検出と cycle N SoT 撤廃 | Phase 0a + 0b | 3-5 PR |
| **Issue Y** | /rite:pr:cleanup の charter 適用と slim down | Phase A + B + C | 5-7 PR |

**依存関係**: Issue Y は Issue X の Phase 0a 完了に blocked （0a 未完だと cleanup.md 内の cycle N が新規追加される race を防ぐ）。Phase 0b は並行可能。

### 7.2 PR 順序

```
Issue X (Phase 0):
  PR 0a-1: pr/fix.md cycle N SoT 撤廃 + 既存引用削除
  PR 0a-2: pr/review.md cycle N 引用削除
  PR 0a-3: pr/cleanup.md + pr/references/ の cycle N 引用削除
  PR 0b-1: pre-tool-bash-guard.sh 拡張 + テスト

Issue Y (Phase A-C):  ← Issue X の 0a 完了後
  PR A:  charter の cleanup 系適用宣言 (本体修正なし)
  PR B1: bash-trap-patterns.md slim
  PR B2: internal-consistency.md slim
  PR B3: archive-procedures.md slim
  PR B4: fact-check.md slim
  PR C1: cleanup.md Sub-skill Return Protocol slim
  PR C2: cleanup.md Phase 1 / 4.W 散文削除
```

各 PR は independent reviewable。1 PR 1 ファイル / 1 焦点を厳守。

---

<!-- Section ID: SPEC-VALIDATION -->
## 8. 検証計画

### 8.1 Phase 0 完了時

```bash
# cycle N が一切残らない
grep -rE "cycle [0-9]+|verified-review cycle" plugins/rite/commands/pr/ | grep -v "/tests/"
# → 0 件

# hook が動作する
echo "fix(review): #999 cycle 3 の指摘対応" | bash plugins/rite/hooks/pre-tool-bash-guard.sh ...
# → warn メッセージが stderr に出力される
RITE_COMMIT_LINT_STRICT=true ... 
# → exit 1
```

### 8.2 Phase A-C 完了時

```bash
# cleanup.md が 1902 → 1500 行以下
wc -l plugins/rite/commands/pr/cleanup.md

# references/ 4 ファイルが計 -200 行以上
wc -l plugins/rite/commands/pr/references/{bash-trap-patterns,internal-consistency,archive-procedures,fact-check}.md

# 既存テストが pass
bash plugins/rite/hooks/tests/4-site-symmetry.test.sh
```

### 8.3 動作確認

Phase A-C 完了後、以下を順次実行:
1. 任意の merged PR で `/rite:pr:cleanup` を実行 → branch delete / Status update / Issue close が正常動作
2. wiki ingest gate が機能する PR で `/rite:pr:cleanup` → Phase 4.W が起動する
3. Phase 5 の `[cleanup:completed]` sentinel が正しく出力される

---

<!-- Section ID: SPEC-RISKS -->
## 9. リスクと緩和

| リスク | 影響 | 緩和 |
|-------|-----|------|
| Phase 0a の機械削除で runtime 必須の `Issue #N` 引用を誤削除 | runtime 動作劣化 | grep pattern を保守的に絞る (`cycle [0-9]+` を最優先、`Issue #N` は手作業確認) |
| Phase 0b の hook が誤検知で正常 commit を block | 開発体験劣化 | デフォルト warn のみ、`RITE_COMMIT_LINT_STRICT=true` で opt-in block |
| C1 の Sub-skill Return Protocol slim で routing dispatcher (C-6) を壊す | turn 終了制御の regression | C-6 の HTML evidence 出力義務は slim 対象外と明記、レビュー時に必ず確認 |
| archive-procedures.md slim で逆統合誘惑 | cleanup.md の再肥大 | Phase B3 では「経緯削除のみ」を明示、構造変更は別 Issue |
| Phase 0a 中に並行 PR が新規 cycle N を導入する race | 終わらない掃除 | Issue X PR 0a-1 で Phase 0b の hook を**先行**マージし、以降の commit を warn ベースで抑止する選択肢も検討 (PR 順序を 0b-1 → 0a-* に入れ替える) |

---

## 10. 自己観察

本 plan 自身も charter の対象。`Issue #N` の本文引用は metavariable / regex 用途以外では入れない。実装開始後、レビュー指摘 fix の commit message にも `cycle N` を書かない。本 plan が肥大化したら 5 自問を再適用する。
