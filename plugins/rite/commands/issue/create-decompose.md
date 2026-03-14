---
description: Issue の仕様書作成・分解・一括作成
---

# /rite:issue:create-decompose

Generate a specification document, decompose into sub-Issues, and create them in bulk. This sub-command is invoked from `create.md` when the user selects decomposition in Phase 0.6.

**Prerequisites**: Phase 0.1 and Phase 0.6 have completed in the parent `create.md` flow. Phases 0.3-0.5 may or may not have been executed depending on the flow path (Phase 0.1.5 early decomposition skips Phase 0.3-0.5). The following information is available in conversation context:
- Extracted elements (What/Why/Where/Scope/Constraints) from Phase 0.1 — **always available**
- Interview results from Phase 0.5 — available if conducted; `null` if skipped
- Tentative slug from Phase 0.1.3 — **always available**
- Decomposition decision from Phase 0.6 — **always available**

---

## Phase 0.7: Specification Document Generation

**Purpose**: Generate an independent design document based on the deep-dive interview results.

> **Relationship with `implementation-plan.md`**: This phase generates a **high-level design** (What/Why/Where) saved as `docs/designs/{slug}.md`. When the Issue is later started via `/rite:issue:start`, the [Implementation Plan module](./implementation-plan.md) generates a **detailed implementation plan** (How/Step-by-step) that builds on this specification. The specification document provides pre-validated requirements and architectural decisions — the implementation plan adds file-level changes, dependency graphs, and reference implementations.

### 0.7.1 Specification Document Structure

Generate a specification document with the following structure. Each section has a **Section ID** (e.g., `SPEC-REQ-FUNC`) that Phase 0.8 uses to directly reference content without re-analysis.

```markdown
# {Issue タイトル}

<!-- Section ID: SPEC-OVERVIEW -->
## 概要

{What: 何を作るか}

<!-- Section ID: SPEC-BACKGROUND -->
## 背景・目的

{Why: なぜ必要か}

## 要件

<!-- Section ID: SPEC-REQ-FUNC -->
### 機能要件

{Phase 0.5 のインタビュー結果から抽出}

<!-- Section ID: SPEC-REQ-NFR -->
### 非機能要件

{Phase 0.5 のインタビュー結果から抽出}

<!-- Section ID: SPEC-TECH-DECISIONS -->
## 技術的決定事項

{Phase 0.5 で確定した技術的な選択}

## アーキテクチャ

<!-- Section ID: SPEC-ARCH-COMPONENTS -->
### コンポーネント構成

{主要なコンポーネントとその役割}

<!-- Section ID: SPEC-ARCH-DATAFLOW -->
### データフロー

{データの流れの説明}

## 実装ガイドライン

<!-- Section ID: SPEC-IMPL-FILES -->
### 変更が必要なファイル/領域

{Where の詳細}

<!-- Section ID: SPEC-IMPL-CONSIDERATIONS -->
### 考慮事項

{エッジケース、セキュリティ、パフォーマンス等}

<!-- Section ID: SPEC-OUT-OF-SCOPE -->
## スコープ外

{今回の実装範囲に含めないもの}
```

**Note**: The "## Sub-Issue 候補" section is automatically appended after Phase 0.8 is complete. Do not include it at Phase 0.7.

#### Section ID Reference Guide (for Phase 0.8)

Phase 0.8 (Sub-Issue Decomposition) should reference specification sections by ID rather than re-analyzing the full document:

| Section ID | Used For | Phase 0.8 Usage |
|------------|----------|-----------------|
| `SPEC-REQ-FUNC` | Functional requirements | Primary source for feature-based decomposition |
| `SPEC-REQ-NFR` | Non-functional requirements | NFR constraints per Sub-Issue |
| `SPEC-ARCH-COMPONENTS` | Component structure | Layer-based decomposition |
| `SPEC-IMPL-FILES` | Target files | File assignment per Sub-Issue |
| `SPEC-IMPL-CONSIDERATIONS` | Edge cases, constraints | Risk allocation per Sub-Issue |
| `SPEC-OUT-OF-SCOPE` | Exclusions | Scope boundary per Sub-Issue |

**Note**: `SPEC-OVERVIEW`, `SPEC-BACKGROUND`, `SPEC-TECH-DECISIONS`, and `SPEC-ARCH-DATAFLOW` are defined in the template for document completeness but are not directly referenced by Phase 0.8 decomposition.

**How Phase 0.8 uses Section IDs**: Instead of re-reading and re-analyzing the entire specification, Phase 0.8 directly references specific sections by ID comment markers. For example, to determine feature boundaries for decomposition, read only `SPEC-REQ-FUNC` and `SPEC-ARCH-COMPONENTS` sections. This reduces redundant analysis and token consumption.

### 0.7.2 Saving the Specification Document

Save the generated specification document in the `docs/designs/` directory:

```bash
# ディレクトリが存在しない場合は作成
mkdir -p docs/designs

# ファイル名は Phase 0.1.3 で事前生成した {tentative_slug} を使用
# タイトルが変更された場合のみ再生成する
```

**Slug source**: Use `{tentative_slug}` from Phase 0.1.3. If the Issue title was modified after Phase 0.1 (e.g., through interview refinement), regenerate the slug using the rules defined in Phase 0.1.3 (single source of truth for slug generation rules).

**When `{tentative_slug}` is not available** (e.g., Phase 0.1.3 was skipped or context was compacted): Generate a new slug following the rules in Phase 0.1.3.

### 0.7.3 Specification Document Confirmation

> **Reference**: See [Termination Logic > Phase 0.7 Specification Document Termination](#phase-07-specification-document-termination) for the termination routing table.

Display the generated specification document and confirm with `AskUserQuestion`:

```
以下の仕様書を生成しました:

{仕様書の内容（要約）}

保存先: docs/designs/{slug}.md

オプション:
- 仕様書を承認: この内容で Sub-Issue の分解に進みます
- 仕様書を編集: 追加・修正したい点を教えてください
- キャンセル: 分解をキャンセルし、単一 Issue として作成します
```

**Context carryover when "キャンセル" is selected**:

Information collected through Phase 0.5 and Phase 0.7 is utilized in Phase 1 onwards as follows:

| Collected Information | Carryover Destination |
|----------------------|----------------------|
| What/Why/Where | Implementation Contract Section 1 (Goal), Section 2 (Scope) of the Issue body |
| Interview results (technical decisions, etc.) | Implementation Contract Sections 1-9 via interview-to-section mapping (see `create-register.md` Phase 2.2 Step 3) |
| Tentative complexity XL | Finalized in Phase 1.1. Recorded as XL even when decomposition is cancelled |
| Out-of-scope items | Implementation Contract Section 2 (Out of Scope), Section 1 (Non-goal) |
| Specification document content (Phase 0.7.1) | Referenced as design context in Implementation Contract Section 4 (Implementation Details) |

**Note**: The specification document generated in Phase 0.7.1 is NOT deleted on cancel. The generated `docs/designs/{slug}.md` file is **retained** and serves as a high-level design reference when the Issue is later started via `/rite:issue:start`. The [Implementation Plan module](./implementation-plan.md) can leverage this pre-validated specification to generate a more accurate detailed plan. Interview result reflection follows [EDGE-3: Interview Result Reflection Rules](./create.md#edge-3-interview-result-reflection-rules).

**When "キャンセル" is selected**: Invoke `skill: "rite:issue:create-register"` to create the Issue as a single Issue. Phase 1+ in `create-register.md` uses the context carryover described above.

**Context handoff to `create-register`**: When invoking the skill, include these in the prompt context to prevent information loss across skill boundaries. This table extends the base context from `create.md` Delegation Routing with decompose-specific items (Specification document, EDGE-3 applicable row):

| Context | Value |
|---------|-------|
| What/Why/Where | From Phase 0.1 extraction (always available) |
| Goal classification | From Phase 0.4 if executed; otherwise `null` (create-register infers from Phase 0.1) |
| Tentative complexity | XL (from Phase 0.1.5 detection); Phase 0.4.1 value (when Phase 0.6 triggered after normal flow) |
| Interview results | From Phase 0.5 if executed; otherwise `null` |
| Specification document | `docs/designs/{slug}.md` (retained on cancel) — referenced in Implementation Contract Section 4 |
| `phases_skipped` flag | `"0.3-0.5"` if Phase 0.1.5 triggered early decomposition; `null` if Phase 0.3-0.5 were executed normally |
| EDGE-3 applicable row | Determined by Phase 0.5 status (see [EDGE-3 condition table](./create.md#edge-3-interview-result-reflection-rules)). When Phase 0.3-0.5 all skipped, row 4 applies |

---

## Phase 0.8: Sub-Issue Decomposition

**Purpose**: Extract specific Sub-Issues from the specification document and formulate an implementation plan.

**Structured reuse**: Use Section IDs from Phase 0.7.1 to directly reference specification sections instead of re-analyzing the full document. See the "Section ID Reference Guide" table in Phase 0.7.1 for the mapping.

### 0.8.1 Decomposition Algorithm

Reference the specification document via Section IDs and extract Sub-Issues based on the following criteria:

| Decomposition Criteria | Description | Applicable Scenario |
|-----------------------|-------------|---------------------|
| **By feature** (preferred) | Split by independent features (e.g., authentication, data display, settings) | When multiple independent features exist (default) |
| **By layer** | Split by architecture layers (e.g., UI, logic, data layer) | When a single feature spans multiple layers |
| **By dependency order** | Split based on implementation dependencies (foundation -> application) | Applied when determining implementation order after splitting by the above criteria |

**Algorithm for selecting decomposition criteria**:

1. First consider whether splitting "by feature" is possible (are there multiple independent features?)
2. For a single feature, split "by layer" (can it be divided into UI/logic/data layers?)
3. After splitting, determine implementation order "by dependency order"
4. If none of the above apply, split by work timeline (initial setup -> implementation -> testing)

**Sub-Issue granularity**:
- Each Sub-Issue should be approximately **1 Issue = 1 PR** in size
- Estimated complexity: S to L (split so that none becomes XL)
- Can be completed independently (parallel work with other Sub-Issues is possible)

### 0.8.2 Dependency Analysis

Analyze dependencies between Sub-Issues:

```
例:
#1 データモデル定義 (依存なし)
#2 バックエンド API 実装 (依存: #1)
#3 フロントエンド UI 実装 (依存: #1)
#4 API 連携実装 (依存: #2, #3)
#5 テスト追加 (依存: #4)
```

### 0.8.3 Implementation Order Proposal

Propose implementation order based on dependencies:

```
## 実装順序（提案）

### フェーズ 1: 基盤構築
1. #{number} - データモデル定義 (複雑度: S)

### フェーズ 2: コア実装（並行可能）
2. #{number} - バックエンド API 実装 (複雑度: M)
3. #{number} - フロントエンド UI 実装 (複雑度: M)

### フェーズ 3: 統合
4. #{number} - API 連携実装 (複雑度: M)

### フェーズ 4: 品質保証
5. #{number} - テスト追加 (複雑度: S)
```

### 0.8.4 Decomposition Result Confirmation

> **Reference**: See [Termination Logic > Phase 0.8 Decomposition Result Termination](#phase-08-decomposition-result-termination) for the termination routing table.

Confirm the decomposition result with `AskUserQuestion`:

```
以下の Sub-Issue に分解しました:

| # | タイトル | 複雑度 | 依存 |
|---|---------|--------|------|
| 1 | {title} | {complexity} | - |
| 2 | {title} | {complexity} | #1 |
| ... | ... | ... | ... |

合計: {count} 件の Sub-Issue

オプション:
- この分解で作成する（推奨）
- Sub-Issue を追加
- Sub-Issue を統合
- 分解をやり直す
```

**Subsequent processing for each option**: See [Termination Logic > Phase 0.8 Decomposition Result Termination](#phase-08-decomposition-result-termination).

---

## Phase 0.9: Bulk Sub-Issue Creation

**Purpose**: Create the parent Issue and Sub-Issues in bulk and set up relationships.

### 0.9.1 Create the Parent Issue

First, create the parent Issue via the common script:

> **Note**: Each bash code block in Phase 0.9.x runs as an independent process. The `trap` registered within each block is scoped to that process only and does not affect other blocks.

```bash
# Generate body content from Phase 0.7 spec and the structure defined below (see "Parent Issue body structure")
# Note: Empty check is required because {parent_issue_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{parent_issue_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{original_title}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "{priority}" \
  --arg complexity "XL" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "xl_decomposition", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
parent_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
parent_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
parent_project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
# project_id/item_id は XL 分解パスでは後続フェーズで使用しないため省略
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Placeholder descriptions:**
- `{projects_enabled}`: `true` if `github.projects.enabled` is `true` in `rite-config.yml`, otherwise `false`
- `{project_number}`: From `github.projects.project_number` in `rite-config.yml`
- `{owner}`: From `github.projects.owner` in `rite-config.yml`
- `{priority}`: Priority value determined during Issue creation (Phase 1)

**Parent Issue body structure**:

```markdown
## 概要

{概要}

## 背景・目的

{背景・目的}

## 設計ドキュメント

詳細な仕様は [docs/designs/{slug}.md](docs/designs/{slug}.md) を参照してください。

## Sub-Issues

<!-- 自動更新: Sub-Issue 作成後にタスクリストを追加 -->

## 進捗

| フェーズ | 状態 |
|---------|------|
| 基盤構築 | [ ] 未着手 |
| コア実装 | [ ] 未着手 |
| 統合 | [ ] 未着手 |
| 品質保証 | [ ] 未着手 |

## 複雑度

XL（{count} 件の Sub-Issue に分解）
```

### 0.9.2 Bulk Creation of Sub-Issues

Execute the following script block **once per Sub-Issue** from the Phase 0.8 decomposition list, substituting `{sub_issue_title}`, `{sub_issue_body}`, and `{estimated_complexity}` for each entry. Collect each `sub_issue_url`, `sub_issue_number`, and `sub_project_reg` into lists for use in Phase 0.9.3 and 0.9.6.

```bash
# 各 Sub-Issue について（ループ内で実行）
# Generate body content from Phase 0.8 decomposition and the structure defined below (see "Sub-Issue body structure")
# Note: Empty check is required because {sub_issue_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{sub_issue_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{sub_issue_title}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "{priority}" \
  --arg complexity "{estimated_complexity}" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "xl_decomposition", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result for Sub-Issue '{sub_issue_title}'" >&2
  # Continue with remaining Sub-Issues instead of exiting
  continue
fi
sub_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
sub_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
sub_project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
# project_id/item_id は XL 分解パスでは後続フェーズで使用しないため省略
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Placeholder descriptions:**
- `{estimated_complexity}`: Complexity estimated during Phase 0.8 decomposition (XS/S/M/L/XL per Sub-Issue)
- `{priority}`: Inherited from parent Issue priority

**Error handling for partial failures:**
- If a Sub-Issue creation fails mid-loop, log the error and continue with remaining Sub-Issues
- After the loop completes, report which Sub-Issues succeeded and which failed in Phase 0.9.6
- The user can retry failed ones manually via `/rite:issue:create`

After each Sub-Issue is created:
1. Retain `sub_issue_url` and `sub_issue_number` for Tasklist update in Phase 0.9.3
2. The script handles Projects registration + field setup internally

**Sub-Issue body structure**:

```markdown
## 概要

{この Sub-Issue で実装する内容}

## 親 Issue

#{parent_issue_number} - {parent_issue_title}

## 設計ドキュメント

詳細な仕様は [docs/designs/{slug}.md](docs/designs/{slug}.md) を参照してください。

## 変更内容

{具体的な変更内容}

## 依存関係

{依存する Sub-Issue があれば記載}

## 複雑度

{complexity}

## チェックリスト

- [ ] 実装完了
- [ ] テスト追加/更新
- [ ] ドキュメント更新（必要な場合）
```

### 0.9.3 Add Tasklist to Parent Issue

After creating Sub-Issues, update the parent Issue body to add a Tasklist:

```bash
# 親 Issue の本文を更新
# Generate body content by merging existing body with new Tasklist (see "Tasklist format" below)
# Note: Empty check is required because {updated_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{updated_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Updated body is empty" >&2
  exit 1
fi

gh issue edit {parent_issue_number} --body-file "$tmpfile"
```

**Tasklist format**:

```markdown
## Sub-Issues

- [ ] #{sub_issue_1_number} - {title}
- [ ] #{sub_issue_2_number} - {title}
- [ ] #{sub_issue_3_number} - {title}
...
```

### 0.9.4 Use GitHub Sub-Issues API (Optional)

If GitHub Sub-Issues (beta) is available, set up parent-child relationships:

```bash
# Sub-Issues API の利用可能性を確認
gh api graphql -f query='
query {
  __type(name: "AddSubIssueInput") {
    name
  }
}'
```

If available:

```bash
# 親子関係を設定
gh api graphql -f query='
mutation($parentId: ID!, $childId: ID!) {
  addSubIssue(input: {
    issueId: $parentId
    subIssueId: $childId
  }) {
    issue {
      id
    }
  }
}' -f parentId="{parent_issue_node_id}" -f childId="{child_issue_node_id}"
```

**API availability evaluation and processing flow**:

```
1. `__type` クエリを実行
   ↓
2. 結果を確認
   ├─ `__type.name` が "AddSubIssueInput" → API 利用可能、親子関係を設定
   └─ `__type` が null または エラー → API 利用不可、スキップ
```

**Error handling**:

| Error Type | Detection Method | Response |
|-----------|-----------------|----------|
| API not supported | `__type` is `null` | Parent-child relationship already expressed via Tasklist in Phase 0.9.3 (fallback in place) |
| GraphQL error | `errors` field exists | Display warning and continue with Tasklist only |
| Timeout | No response | Retry once, then continue with Tasklist only |
| Permission error | `FORBIDDEN` or `UNAUTHORIZED` | Display warning and continue with Tasklist only |

**Note**: Even if the Sub-Issues API is unavailable, the parent-child relationship is visually represented via the Tasklist format set up in Phase 0.9.3.

### 0.9.5 Projects Registration

> **Note**: Projects registration (item-add + field setup) is handled internally by `create-issue-with-projects.sh` in Phase 0.9.1 and 0.9.2. This phase only verifies the results and handles any failures.

**Verification**: Check `parent_project_reg` and each `sub_project_reg` from Phase 0.9.1/0.9.2.

- All `"ok"` → Display success in 0.9.6
- Any `"partial"` or `"failed"` → Display warning: `⚠️ 一部の Projects 登録に失敗しました。手動で登録してください。`
- `"skipped"` → Projects integration is disabled, no action needed

### 0.9.6 Completion Report

Report the creation results:

```
Issue の分解が完了しました

親 Issue: #{parent_number} - {parent_title}
設計ドキュメント: docs/designs/{slug}.md

Sub-Issues:
| # | タイトル | 複雑度 | URL | Projects | 状態 |
|---|---------|--------|-----|----------|------|
| #{number} | {title} | {complexity} | {url} | {project_reg} | 成功 / 失敗 |
| ... | ... | ... | ... | ... | ... |

成功: {success_count} 件 / 失敗: {failure_count} 件
合計: {count} 件の Sub-Issue を作成しました

Projects 設定:
- Status: Todo
- Priority: {priority}
- Complexity: XL（親）/ {各 Sub-Issue の複雑度}

次のステップ:
1. `/rite:issue:start #{first_sub_issue}` で最初の Sub-Issue から作業開始
2. `/rite:issue:list` で Sub-Issue の一覧を確認
```

---

## Termination Logic

### Phase 0.7 Specification Document Termination

Phase 0.7 terminates based on the user's selection in the specification confirmation dialog (Phase 0.7.3):

| User Selection | Next Phase |
|----------------|------------|
| 仕様書を承認 | Phase 0.8 |
| 仕様書を編集 | Re-edit → return to Phase 0.7.3 |
| キャンセル | Invoke `skill: "rite:issue:create-register"` (cancel decomposition, create as single Issue). See context carryover section after Phase 0.7.3 for details |

### Phase 0.8 Decomposition Result Termination

Phase 0.8 terminates based on the user's selection in the decomposition result confirmation dialog (Phase 0.8.4):

| User Selection | Next Phase |
|----------------|------------|
| この分解で作成する（推奨） | Proceed to Phase 0.9 |
| Sub-Issue を追加 | Confirm the Sub-Issue content with the user, add to the list, then return to Phase 0.8.4 confirmation |
| Sub-Issue を統合 | Confirm which Sub-Issue numbers to merge, combine into one, then return to Phase 0.8.4 confirmation |
| 分解をやり直す | Return to Phase 0.8.1. Change decomposition criteria and re-decompose. Confirm with the user "which criteria to use for re-decomposition" |

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0).

Before returning control to the caller, update `.rite-flow-state` to the post-delegation phase. This ensures the stop-guard routes correctly even if the caller's 🚨 Mandatory After section is not executed immediately:

**Condition**: Execute only on the **Normal path** (sub-Issues created via Phase 0.9). On the **Delegation path** (cancelled and delegated to `create-register`), `create-register.md` handles its own Defense-in-Depth — do NOT execute this section.

```bash
if [ -f ".rite-flow-state" ]; then
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "create_post_delegation" \
    --next "rite:issue:create-decompose completed. Sub-Issues created. Caller should execute post-completion cleanup (flow-state deactivation). Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "create_post_delegation" --issue 0 --branch "" --loop 0 --pr 0 \
    --next "rite:issue:create-decompose completed. Sub-Issues created. Caller should execute post-completion cleanup (flow-state deactivation). Do NOT stop."
fi
```

After the flow-state update above, output the appropriate result pattern:

- **Decomposition completed**: `[decompose:completed:{count}]` (where `{count}` is the number of sub-Issues created)

This pattern is consumed by the orchestrator (`create.md`) to confirm sub-Issue creation and trigger post-completion cleanup.

---

## 🚨 Caller Return Protocol

When this sub-skill completes, the caller (`create.md`) should NOT take any additional action beyond flow-state deactivation. Completion occurs via one of the following paths:

- **Normal path** (sub-Issues created via Phase 0.9): The completion report has already been output by this sub-skill. The Defense-in-Depth section above has updated `.rite-flow-state` to `create_post_delegation`.
- **Delegation path** (cancelled and delegated to `create-register`): The completion report will be output by `create-register`. This sub-skill is NOT terminal in this path — `create-register` takes over and completes the workflow (including its own Defense-in-Depth).
