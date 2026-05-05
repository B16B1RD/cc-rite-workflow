---
description: |
  Issue 作成 / new issue / 起票 / Issue 化 — 新規 Issue を作成し、GitHub Projects に登録する。
  重複検出・親 Issue 候補検出・XL 自動分解（Sub-Issue 作成 + 設計仕様書生成）を含む。
  Use when 「Issue 作って」「タスクを起票」「create issue」「新規 Issue」など。
---

# /rite:issue:create

Create a new Issue and add it to GitHub Projects.

> 生成する Issue body / commit message は [Simplification Charter](../../skills/rite-workflow/references/simplification-charter.md) に従う（過去 PR / cycle 番号の本文引用を避け、経緯は git log に任せる）。

## Happy Path & Architecture

1. **Phase 0**: ユーザ入力から What/Why/Where を抽出 + 静的処理 (slug 生成 / 類似 Issue 検索 / quick confirmation)
2. **Phase 1 (`rite:issue:create-interview`)**: 適応的インタビュー (Bug Fix/Chore は skip)
3. **Phase 2**: XL 判定 (大規模なら自動分解)
4. **Phase 3 (`rite:issue:create-register` または `rite:issue:create-decompose`)**: Issue 作成
5. ✅ Issue #N 作成完了

```
create.md (orchestrator)
├── create-interview.md   ← Phase 1 + 1.1 (Adaptive Interview + Deep-Dive)
├── create-decompose.md   ← Phase 3 (Decompose path: Spec + Decompose + Bulk Create + Terminal Completion)
└── create-register.md    ← Phase 3 (Single Issue path: Classify + Confirm + Create + Terminal Completion)
```

**Responsibility split**: `create.md` = Issue specification + duplicate detection + Issue creation + Projects registration (Phase 0-3)。`start.md` = Issue quality validation + parent Issue detection + branch creation + work start (Phase 0-5)。`implementation-plan.md` = detailed step-by-step plan (Phase 3)。`create.md` Phase 0.4 = Similar Issue Search、`start.md` Phase 0.3 = Parent Issue Auto-Detection (異なる責務)。

**CRITICAL**: After every sub-skill returns, **immediately** proceed to the next phase. Do NOT stop until the Issue is created and `<!-- [create:completed:{N}] -->` is emitted.

## Sub-skill Return Protocol

> sub-skill 戻り値の判定は [`references/pre-check-routing.md`](./references/pre-check-routing.md) を参照。場面 (b) (turn 終了直前) では Item 1-3 すべて `YES` が必要。`Has [create:completed:{N}] been output?` の self-check alias を含む詳細は同 reference 参照。

### Anti-pattern (what NOT to do)

`rite:issue:create-interview` が `<!-- [interview:skipped] -->` / `<!-- [interview:completed] -->` (HTML comment 形式) を返した時:

```
[WRONG]
<Skill rite:issue:create-interview returns>
<LLM output: "<!-- [interview:skipped] -->">
<LLM ends turn. User sees "Cooked for 2m 0s" and must type `continue` manually.>
```

これは **bug**。return tag は turn 境界ではなく hand-off signal。HTML コメント wrapping でも LLM の turn-boundary heuristic が誤発火し得るため、Mandatory After を即時実行しないと workflow が abandoned になる。

### Correct-pattern (what to do)

```
[CORRECT]
<Skill rite:issue:create-interview returns>
<LLM output: "<!-- [interview:skipped] -->">
<In the same response turn, LLM IMMEDIATELY:>
  1. Runs the Pre-write bash for Phase 2 / Delegation Routing
  2. Evaluates Phase 2 triggers
  3. Runs the Delegation Routing Pre-write bash
  4. Invokes skill: "rite:issue:create-register" (or create-decompose)
  5. Waits for <!-- [create:completed:{N}] --> (HTML comment form)
  6. Runs Mandatory After Delegation self-check
```

**Rule**: Treat `[interview:skipped]` / `[interview:completed]` as **continuation triggers**, not stopping points. Both terminal sub-skills emit `<!-- [create:completed:{N}] -->` as the unified completion marker. The only valid stop is after the user-visible `✅` completion message + next-steps block AND `<!-- [create:completed:{N}] -->` (terminal sub-skill が `create-register.md` Phase 3.4 / `create-decompose.md` Phase 3.4 で順序通り emit) が出力された後のみ。

> **Contract phrases (AC-3)**: anti-pattern / correct-pattern 契約は以下 4 phrase を grep-verified で必ず含む: `anti-pattern`, `correct-pattern`, `same response turn`, `DO NOT stop`。書換禁止。manual verification: `for p in "anti-pattern" "correct-pattern" "same response turn" "DO NOT stop"; do grep -c "$p" plugins/rite/commands/issue/create.md; done` で全て ≥1。

> Terminal sub-skills は flow-state deactivation + `✅` 完了メッセージ + `<!-- [create:completed:{N}] -->` を内製する。`create-interview.md` は post-phase (`create_post_interview`) に進めて return する (Defense-in-Depth)。

## Arguments

| Argument | Description |
|----------|-------------|
| `<title or description>` | Issue title or description (required) |

## Preparation: Retrieve Project Settings

**Repository**: `gh repo view --json owner,name`

### Language-Aware Template Selection

`rite-config.yml` の `language` (`ja` / `en` / `auto`、未設定 `auto`) を Phase 0.3 / 0.4 / 0.5 / 2.2 の AskUserQuestion テンプレート言語選択に使用 (Phase 1.1 Deep-Dive Interview は Japanese-only)。

`auto` は CJK 文字を検出して Japanese を選択 (default Japanese)。

単一 AskUserQuestion 内で言語混在禁止。

**Project**: `rite-config.yml` の `github.projects.project_number` を最優先。未設定なら `gh api graphql` で `repository.projectsV2(first:10){ nodes{ id number title } }` を取得し、リポジトリ名と一致するもの / 最も関連するものを選択。Project が見つからない場合は警告し Projects 追加を skip。

## Phase 0: Preconditions

> **🚫 MUST NOT (Bypass prohibition)**: 本セクションから `[create:completed:{N}]` までの間、orchestrator は (1) `gh issue create` を直接呼ぶ (2) `rite:issue:create-interview` 起動を skip する (3) Phase 1 / Phase 2 / Phase 3 を 1 ステップに collapse する のいずれも禁止 (`pre-tool-bash-guard.sh` hook で実行時 block)。

### 0.1 Extract Information from User Input

#### EDGE-4: Short Input Handling

詳細は [`references/edge-cases-create.md#edge-4-short-input-handling`](./references/edge-cases-create.md#edge-4-short-input-handling) を参照。Phase 0.1 開始前に short input (Unicode < 10 chars) を検出し、AskUserQuestion で詳細を要求するか既存 Issue を参照するかを分岐させるロジックを定義する。

ユーザ入力から以下を抽出: **What** (何をするか) / **Why** (なぜ必要か) / **Where** (変更対象) / **Scope** (影響範囲) / **Constraints** (制約)。例: "Add login feature" / "For user authentication" / "Under src/auth/" / "Frontend and backend" / "Maintain compatibility with existing API"。

### 0.2 Slug Pre-generation

詳細は [`references/slug-generation.md`](./references/slug-generation.md) を参照 ([Slug Generation Rules](./references/slug-generation.md#slug-generation-rules) / [Translation Guidelines](./references/slug-generation.md#translation-guidelines) / [Context Retention](./references/slug-generation.md#context-retention))。生成した slug は `{tentative_slug}` として context に保持し Phase 3 (decompose path) で再利用する。

### 0.3 Parent Issue Pre-detection

**Purpose**: 大型タスク (sub-Issue 分解候補) を Phase 2 より前に検出。単一焦点の小規模変更明示時は skip → Phase 0.4 へ direct。

**Detection heuristics** (any → confirmation): 複数の distinct change ("Add auth, logging, and caching" 等) / scope keywords ("全体的に" / "across all" / "multiple files" / "一括") / rough complexity ≥ L / umbrella-epic language ("プロジェクト" / "epic" / "umbrella" / "phase")。

**Confirmation** (`AskUserQuestion`、language-aware): 「Sub-Issue に分解すべき大型タスクですか? / Is this a large task that should be decomposed?」

| Selection | Action |
|-----------|--------|
| はい、分解 / Yes, decompose | Phase 0.4-0.5 を skip、Phase 2 へ direct (`force_decompose: true`、Phase 2.1/2.2 confirmation も skip し Phase 3 (decompose path) へ) |
| いいえ、単一 / No, single | Phase 0.4 へ通常進行 |

**⚠️ Phase 0.4 skip notice**: 「はい、分解」時は Phase 0.4 (重複検出) を skip — 大型タスクは exact duplicate が稀で、Phase 3 の sub-Issue 個別作成時に重複検出される。重複懸念があれば「いいえ」を選択。

### 0.4 Search for Similar Issues

**Purpose**: 重複検出 / context gathering / extension 候補検出 (parent Issue 検出は `start.md` 担当)。

```bash
# Extract 2-3 keywords from user input (stop word 除去, Japanese は as-is)
result=$(gh issue list --search "is:open {keywords}" --limit 10 --json number,title,labels)
[ "$(echo "$result" | jq 'length')" -eq 0 ] && \
  result=$(gh issue list --state all --limit 10 --json number,title,labels)
echo "$result"
```

**Relevance scoring** (top 5): title 類似度 (high) → label 一致 (medium) → 更新日時 (low) → state OPEN > CLOSED (low)。

**Branching** (language-aware AskUserQuestion):

| 候補数 | Options |
|--------|---------|
| 0 件 | Phase 0.5 へ direct |
| 1 件 | (a) #{number} の拡張 → Phase 0.5 + body に `Extends: #{number}` 追記 / (b) 既存 Issue を使用 → terminate + `/rite:issue:start {number}` 提案 / (c) 関連なし → Phase 0.5 |
| 2+ 件 | (a) #{number_1} の拡張 / (b) 別 Issue 番号入力 (follow-up: "start" or "extension") / (c) 関連なし → Phase 0.5 |

### 0.5 Quick Confirmation

**Purpose**: Phase 0.1 で得た What/Why/Where のうち欠落分のみ補完 (再確認は不要)。

| Phase 0.1 Result | Phase 0.5 Action |
|------------------|------------------|
| What/Why/Where 全て明確 | Skip → Goal classification へ |
| What 明確、Why or Where 不足 | 不足要素のみ単一 AskUserQuestion で確認 |
| What 不足 | Goal clarification を full asking |

**Goal classification** (常に決定、Phase 1 adaptive interview depth 決定用): AskUserQuestion (language-aware) で 新機能 / バグ修正 / ドキュメント / リファクタリング / その他。Phase 0.1 から推定可能なら ask 不要。完了条件は [Termination Logic > Phase 0.5 Completion Criteria](#phase-05-completion-criteria) を参照。

### 0.6 Skip Semantics (Mode B Defense)

> **READ THIS EVERY TIME Phase 0.5 is skipped.** Phase 0.5 confirmation の skip は **user-facing dialog の skip のみ**。以下は MUST execute:

| # | MUST execute | Why |
|---|--------------|-----|
| 1 | Phase 1 goal classification (Phase 0.1 から推定) | Phase 1.1 interview scope 決定で必要 |
| 2 | Phase 1 Delegation to Interview (Pre-write + Skill 起動) | `create_interview` write がないと `phase-transition-whitelist.sh` の case arm が enforce できない (`pre-tool-bash-guard.sh` / `session-end.sh` が source) |
| 3 | Mandatory After Interview | flow state を `create_post_interview` に進める |
| 4 | Phase 2 | `create-register` vs `create-decompose` 選択 |
| 5 | Phase 3 Delegation Routing (Pre-write + terminal sub-skill) | `create_delegation` を書き whitelist を進める |
| 6 | Mandatory After Delegation | terminal `create_completed` の defense-in-depth |

**唯一の合法 path**: `rite:issue:create-register` または `rite:issue:create-decompose` Skill 起動経由でのみ Issue を作成する。`gh issue create` 直接呼出しは `pre-tool-bash-guard.sh` で block される。本 skip semantics は [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md) の `no_step_omission` / `no_context_introspection` の具体化 — 時間的制約や context 残量を理由にした step 省略は禁止。

## Phase 1: Delegation to Interview

> Phase 0 の Bypass prohibition は本セクション以降も継続適用。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決。

**Pre-write** (before invoking interview sub-skill):

```bash
# state file path を解決 (schema_version=2: per-session、legacy: single-file)。
# helper が空文字列なら create branch へ。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  # Preserve existing fields (issue_number, branch, etc.) from caller (e.g., start.md)
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_interview" \
    --active true \
    --next "After rite:issue:create-interview returns: proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "create_interview" --issue 0 --branch "" --pr 0 \
    --next "After rite:issue:create-interview returns: proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop."
fi
```

Invoke `skill: "rite:issue:create-interview"`.

**🚨 Immediate after interview returns**: result pattern (`[interview:completed]` / `[interview:skipped]` / `[CONTEXT] INTERVIEW_DONE=1`) を観測したら、応答を終了せず Mandatory After Interview の Step 0 を **同 turn 内連続実行する**。

### 🚨 Mandatory After Interview

> **⚠️ 同 turn 内連続実行する (MUST execute in the SAME response turn)**: `[interview:*]` return tag は turn 境界ではなく継続トリガ — turn を閉じると workflow が停止し Issue は作成されない。No GitHub Issue has been created yet。flow state の `.phase = create_post_interview` (sub-skill 内製)。`phase-transition-whitelist.sh` の whitelist transition graph により、active の間は `create_delegation` (Phase 3 Delegation Routing Pre-write) または `create_completed` (terminal sub-skill) への transition のみが許可される — `pre-tool-bash-guard.sh` / `session-end.sh` が enforce 経路。

**Step 0: Immediate Bash Action**: sub-skill return 直後の **very first tool call** として実行し turn-boundary 感を bash invocation に置換。失敗時は stderr に `[CONTEXT] STEP_0_PATCH_FAILED=1` retained flag を emit (非 blocking、Step 1 が idempotent patch として再試行):

```bash
# Re-affirm phase + refresh timestamp (idempotent with Step 1)。--if-exists は file 不在 skip
# と patch 成功を両方 exit 0 で返すため STEP_0_PATCH_FAILED は真の失敗のみを区別する非 blocking flag。
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_post_interview" \
    --active true \
    --next "Step 0 Immediate Bash Action fired; proceeding to Phase 2. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_0_PATCH_FAILED=1" >&2
fi
```

**Step 1**: post-interview phase patch (atomic、idempotent with Step 0):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_post_interview" \
    --active true \
    --next "rite:issue:create-interview completed. Proceed to Phase 2 (Task Decomposition Decision). Issue has NOT been created yet. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_1_PATCH_FAILED=1" >&2
fi
```

**Step 2**: Pre-check list を [`references/pre-check-routing.md`](./references/pre-check-routing.md) に従い実行。`NO` 項目があれば turn を閉じず Phase 2 へ継続。

**Step 3**: **→ Proceed to Phase 2 (Task Decomposition Decision) now. Do NOT stop.**

> **Continuation trigger reminder**: `[interview:*]` return tag は continuation trigger であり turn 境界ではない。implicit stop は protocol violation で `hooks/workflow-incident-emit.sh` ヘルパー経由で `workflow_incident` (`type=manual_fallback_adopted`) を emit する。

## Phase 2: Task Decomposition Decision

**Purpose**: 粗粒度 Issue を検出し分解要否を決定。

### 2.1 Decomposition Trigger Evaluation

**Fast path**: Phase 0.3 で `force_decompose: true` なら trigger 評価と 2.2 confirmation を skip し直接 `rite:issue:create-decompose` へ。

**通常 path** — 以下 **全条件** で decomposition: (1) tentative complexity = XL (Phase 1 で確定) AND (2) comprehensive expressions 含有 ("system / platform / app 開発 / 全面 renewal / 基盤構築" 等 broad scope。"~kinou tsuika / ~gamen jissou / ~shuusei" 等 limited scope は除外)。曖昧な "wo tsukuru" 単独は除外、deliverable type 明示時のみ。複数 domain (auth + payment + notification 等) を跨ぐ場合は patterns に関わらず検討。XL でも scope 明確で単一 PR 完結なら不要。

### 2.2 Decomposition Confirmation

`AskUserQuestion` で「Sub-Issue に分解する（推奨） / 単一 Issue として作成」を確認 (language-aware)。詳細 routing は [Termination Logic > Phase 2 Decomposition Decision Termination](#phase-2-decomposition-decision-termination) を参照。

**「単一 Issue として作成」時の context carryover**: Phase 1.1 interview 結果は [`references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping`](./references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping) 経由で Implementation Contract Section 1-9 に mapping。What/Why/Where → Section 1/2、tentative complexity XL → Phase 3 (Single Issue path) で最終確定 (cancel 時も XL 記録)、Out-of-scope → Section 2 (Out of Scope) / Section 1 (Non-goal)。

#### EDGE-3: Interview Result Reflection Rules

詳細は [`references/edge-cases-create.md#edge-3-interview-result-reflection-rules`](./references/edge-cases-create.md#edge-3-interview-result-reflection-rules) を参照。Phase 1.1 status と Phase 0.3 早期分解 cancel パスの組み合わせに応じて Implementation Contract sections に何を populate すべきかを規定する (Complexity Gate compliance / `（推定）` marking / `<!-- 情報未収集 -->` placeholder)。

## Phase 3: Delegation Routing

Phase 2 結果に基づき適切な sub-command に delegation。

**Pre-write** (before invoking delegation sub-skill):

```bash
# state file path を解決 (schema_version=2: per-session、legacy: single-file)。
# helper が空文字列なら create branch へ。
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
state_file=$(bash {plugin_root}/hooks/_resolve-flow-state-path.sh "$state_root" 2>/dev/null) || state_file=""
if [ -n "$state_file" ] && [ -f "$state_file" ]; then
  # Preserve existing fields (issue_number, branch, etc.) from caller
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_delegation" \
    --active true \
    --next "Wait for sub-skill (create-register or create-decompose) to output completion report (Issue URL). Issue has NOT been created yet. Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "create_delegation" --issue 0 --branch "" --pr 0 \
    --next "Wait for sub-skill (create-register or create-decompose) to output completion report (Issue URL). Issue has NOT been created yet. Do NOT stop."
fi
```

| Phase 2 Selection | Sub-skill |
|---------------------|-----------|
| 分解 | `skill: "rite:issue:create-decompose"` |
| 単一 (or trigger 非該当) | `skill: "rite:issue:create-register"` |

**Context handoff to `create-register`** (Phase 0.3 path で Phase 0.4-0.5 skip 時):

| Context | Source | Phase 0.3 path 時 |
|---------|--------|---------------------|
| What/Why/Where | Phase 0.1 | 常に available |
| Goal classification | Phase 0.5 | **N/A** — `create-register` Phase 3 が Phase 0.1 から推定 |
| Tentative complexity | Phase 1 | **N/A** — `create-register` Phase 3 が XL baseline + Heuristics Scoring で finalize |
| Interview results | Phase 1.1 | **N/A** — EDGE-3 row 4 適用 (MUST sections に placeholder) |
| Tentative slug | [Phase 0.2](./references/slug-generation.md) | 常に available |
| `phases_skipped` flag | Phase 0.3 | `"0.4-0.5"` (Phase 0.3 早期分解時) または `null` |

**🚨 Immediate after delegation returns**: sub-skill が `[create:completed:{N}]` を出力したら同 turn 内で Mandatory After Delegation を実行。

### 🚨 Mandatory After Delegation (Defense-in-Depth)

> **⚠️ 同 turn 内連続実行する (MUST execute in the SAME response turn)**: terminal sub-skill (`create-register.md`, `create-decompose.md`) は通常 `[create:completed:{N}]` + `create_completed` / `active: false` を内製出力する (Terminal Completion pattern)。本セクションは欠落時の defense-in-depth recovery path。

**Self-check**: `[create:completed:{N}]` が出力済みか? **Yes** (Normal path) → terminal state 既達、Steps 1-3 は **no-op で skip** (Step 1 は retrograde transition になる)。**No** (異常経路) → Steps 1-3 が critical、terminal state に強制遷移。

**Step 1** (異常経路のみ):

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_post_delegation" \
  --active true \
  --next "Sub-skill completed. Deactivate flow state and output next steps. Do NOT stop."
```

**Step 2** (異常経路のみ、idempotent):

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_completed" \
  --next "none" --active false
```

**Step 3** (異常経路のみ、defense-in-depth fallback): sub-skill 完了メッセージ欠落時に出力:

- **Register**: `✅ Issue #{number} を作成しました` + 次ステップ (`/rite:issue:start {number}` / `/rite:pr:create`) + `<!-- [create:completed:{number}] -->`
- **Decompose**: `✅ Issue #{parent_number} を分解して {count} 件の Sub-Issue を作成しました` + 次ステップ (`/rite:issue:start #{first_sub_issue}` / `/rite:issue:list`) + `<!-- [create:completed:{first_sub_issue}] -->`

Concrete output 例は `create-register.md` Phase 3.4 / `create-decompose.md` Phase 3.4。HTML コメント sentinel は grep-matchable を維持しつつ user-visible 末尾を `✅` メッセージに固定。

**Step 4 (terminal gate)**: Pre-check list を場面 (b) mode で再実行 — Item 1-3 全 `YES` なら停止可、`NO` 残存時は manual 停止して `hooks/workflow-incident-emit.sh` ヘルパー経由で `workflow_incident` を emit。

## Termination Logic

### Phase 0.5 Completion Criteria

What / Why / Where がすべて clear なら完了。不足があれば clarifying questions を発行 (Phase 0.5 templates 参照)。

### Phase 2 Decomposition Decision Termination

| User Selection | Next Phase |
|----------------|------------|
| Sub-Issue に分解する（推奨） | `skill: "rite:issue:create-decompose"` |
| 単一 Issue として作成 | `skill: "rite:issue:create-register"` (interview 結果 → Implementation Contract sections は [`references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping`](./references/contract-section-mapping.md#step-3-interview-perspective--target-sections-mapping) で mapping) |
