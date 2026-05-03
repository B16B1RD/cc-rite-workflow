---
description: |
  (Internal sub-skill — invoked by /rite:issue:create only. Do NOT invoke directly.)
  単一 Issue の分類・確認・作成・Projects 登録を行う sub-skill。
  Phase 1 分類 + Phase 2-4 作成・登録を担当（分解しない単一 Issue 経路）。
---

# /rite:issue:create-register

Classify, confirm, create, and register a single Issue. This sub-command is invoked from `create.md` when a single Issue is created (no decomposition), or from `create-decompose.md` when decomposition is cancelled.

**Prerequisites**: Phase 0.1 and Phase 0.6 have completed in the parent `create.md` flow. Phases 0.3-0.5 may or may not have been executed depending on the flow path. The following information is available in conversation context:
- Extracted elements (What/Why/Where/Scope/Constraints) from Phase 0.1 — **always available**
- Interview results from Phase 0.5 — available if conducted; `null` if skipped
- Tentative slug from Phase 0.1.3 — **always available**
- Goal classification from Phase 0.4 — available if conducted; `null` if skipped (Phase 0.1.5 early decomposition path)
- Language setting from Preparation phase — **always available**
- `phases_skipped` flag — `"0.3-0.5"` when Phase 0.1.5 triggered early decomposition; `null` otherwise
- Specification document path — available when invoked from `create-decompose.md` cancel (Phase 0.7.3)

**Fallback rules for missing prerequisites**:

| Missing Prerequisite | Fallback |
|----------------------|----------|
| Goal classification (Phase 0.4) | Infer from Phase 0.1 extraction: keywords in title/What → Type mapping (see Phase 1.2 Work Type Classification) |
| Tentative complexity (Phase 0.4.1) | Use XL as baseline when `phases_skipped` is `"0.3-0.5"` (from Phase 0.1.5 detection); finalize via Heuristics Scoring (Phase 1.1) which takes precedence |
| Interview results (Phase 0.5) | Apply [EDGE-3 row 4](./references/edge-cases-create.md#edge-3-interview-result-reflection-rules): MUST sections per Complexity Gate with `<!-- 情報未収集 -->` placeholders |

---

## Phase 1: Classification and Estimation

### 1.1 Complexity Estimation

Finalize the complexity using the tentative estimation from Phase 0.4.1 as a baseline. Refer to the Tentative Complexity Estimation table in `create-interview.md` Phase 0.4.1 for the base criteria (XS through XL).

**When Phase 0.4.1 was not executed** (Phase 0.1.5 early decomposition path): Use XL as the tentative baseline (the task was detected as large-scope in Phase 0.1.5). Heuristics Scoring below takes precedence and may adjust the final complexity downward if the scoring conditions indicate a lower complexity.

#### Complexity Heuristics Scoring

Use the Heuristics Scoring as the primary method. The Tentative Complexity Estimation table serves as a quick reference for intuitive estimation; when the two disagree, the Heuristics Score takes precedence.

Score +1 for each matching condition:

| Condition | Score |
|-----------|-------|
| Changed files > 3 | +1 |
| Spans multiple modules/services | +1 |
| Public API/interface changes | +1 |
| Migration/backward compatibility needed | +1 |
| Strict non-functional requirements | +1 |
| 2+ unresolved design decisions | +1 |

Score to complexity: 0-1 = XS, 2 = S, 3-4 = M, 5 = L, 6+ = XL

Use information from Phase 0.1-0.5 to evaluate each condition. The final complexity is recorded in the Issue Meta section.

### 1.2 Work Type Classification

| Type | Criteria | Heuristics |
|------|----------|------------|
| **Feature** | Addition of new functionality or capability | New user-facing functionality or workflow |
| **BugFix** | Fix of defect in existing functionality | Symptom + repro steps + incorrect current behavior |
| **Refactor** | Code improvement without functionality change | Internal structure improvement, compatibility considerations |
| **Chore** | Build, dependency, or configuration update | Maintenance/tooling/dependency update, no behavior change |
| **Docs** | Addition or update of documentation | Documentation addition/update is the primary deliverable |

**Type determination priority**: Labels > title keywords > body content analysis.

The type determines which Type Core Section (Section 3) is used in the Issue body. See the [Issue template structure](../../templates/issue/template-structure.md) for type-specific section templates, and [default.md](../../templates/issue/default.md) for type definitions and complexity gate.

### 1.3 Priority Estimation

| Priority | Criteria |
|----------|----------|
| **High** | Blocker, security issue, production incident |
| **Medium** | Normal feature addition or improvement (default) |
| **Low** | Nice-to-have, future improvement |

---

## Phase 2: Confirmation and Creation

### 2.1 Issue Content Confirmation

#### Title Language Unification Rules

Determine the language for Issue title and body based on the `language` setting in `rite-config.yml` retrieved during **Preparation**:

| Setting Value | Behavior |
|--------------|----------|
| `auto` | Detect the user's input language and generate in the same language |
| `ja` | Generate title and body in Japanese |
| `en` | Generate title and body in English |

**Important**: The Issue title and body must always be in the same language. Do not mix languages.

**Language detection priority** (when `auto` setting):
1. Language used by the user when executing the command
2. Language of similar Issues retrieved in Phase 0.3 (if similar Issues exist)
3. Default: Japanese

| Overview Section Example | Detection | Title Example |
|-------------------------|-----------|---------------|
| "API エンドポイントを追加する" | Japanese (contains "エ", "追加") | "API エンドポイントの追加" |
| "Add new API endpoint" | English (no Japanese characters) | "Add new API endpoint" |

#### Confirmation Dialog

Confirm with AskUserQuestion before creation:

```
以下の内容で Issue を作成します:

タイトル: {generated-title}
種別: {work-type}
複雑度: {complexity}
優先度: {priority}

説明:
{generated-body}

よろしいですか？
オプション:
- はい、作成する
- タイトルを変更
- 説明を編集
- キャンセル
```

### 2.2 Issue Body Generation and Creation

> **⚠️ Execution order**: First generate the Issue body using the Implementation Contract format (Section "Issue Body Generation" below the script block), then show the Phase 2.1 Confirmation Dialog with `{generated-body}`, and finally run the creation script.
>
> **Important**: When generating the Issue body, apply the display rules defined in [EDGE-3: Interview Result Reflection Rules](./references/edge-cases-create.md#edge-3-interview-result-reflection-rules) for Implementation Contract sections.

#### Create Issue via Common Script

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

```bash
# Note: Empty check is required because {body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{title}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "{priority}" \
  --arg complexity "{complexity}" \
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
    options: { source: "interactive", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_id=$(printf '%s' "$result" | jq -r '.project_id')
item_id=$(printf '%s' "$result" | jq -r '.item_id')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Note — Iteration coordination pattern**: `iteration.mode` is intentionally set to `"none"` here. The `create-issue-with-projects.sh` script handles **creation + basic Projects registration** (Status, Priority, Complexity), while `create-register.md` handles **interactive Iteration assignment** separately in Phase 2.5 after user confirmation. This two-phase approach avoids assigning an Iteration the user hasn't confirmed. The `project_id` and `item_id` from the script result are reused for Phase 2.3 (custom fields) and Phase 2.5 (Iteration), eliminating redundant API calls.

> **Contrast with `start.md`**: When `start.md`'s child modules call `create-issue-with-projects.sh`, iteration handling varies by call site: `start.md` Phase 5.2.0.1 (lint warning Issues) uses `iteration.mode: "none"` directly, while `parent-routing.md` (invoked from `start.md` Phase 1.5 for child Issue creation) uses `"auto"` or `"none"` based on `rite-config.yml`'s `iteration.enabled` and `iteration.auto_assign` settings. Neither flow includes interactive Iteration confirmation.

#### Issue Body Generation (Implementation Contract Format)

> **Template reference**:
> 1. Read `{plugin_root}/templates/issue/default.md` — complexity gate, type definitions, section overview
> 2. Read `{plugin_root}/templates/issue/template-structure.md` — full section-by-section template structure, type-specific sections

Generate the Issue body using the Implementation Contract format. The body structure is determined by Type (Phase 1.2) and Complexity (Phase 1.1).

**Step 1: Apply Complexity Gate**

Read the Complexity Gate table from the template. For the determined complexity, include sections marked `M` (MUST) and `S` (SHOULD, if information available). Omit sections marked `O`.

**Step 2: Select Type Core Section**

Based on the Type from Phase 1.2, include the corresponding Type Core Section (Section 3):

| Type | Section 3 Content |
|------|------------------|
| Feature | User Scenarios |
| BugFix | Bug Details (Reproduction, Root Cause) |
| Refactor | Before/After Contract, Compatibility Policy |
| Chore | Operational Context |
| Docs | Documentation Target |

**Step 3: Map Interview Results to Sections**

Apply the interview-to-template mapping from the template:

| Interview Perspective | Target Sections |
|----------------------|----------------|
| Technical Implementation | 4.1 Target Files, 4.3 Interface/Data Contract, 4.4 Behavioral Requirements |
| User Experience | 1 Goal, 3 Type Core (Feature scenarios), 5 AC (Happy Path) |
| Edge Cases | 5 AC (Boundary/Error), 6 Test Specification |
| Existing Feature Impact | 2 Scope (Out), 4.2 Non-Target, 4.4 MUST NOT |
| Non-Functional Requirements | 4.5 Error/Constraints, 5 AC (NFR outcome), 6 Test Specification |
| Tradeoffs | 1 Non-goal, 4.4 SHOULD/MAY, 9 Decision Log |

**Section inclusion rules**:

| Condition | Behavior |
|-----------|----------|
| Interview not conducted for a perspective | Omit target sections (unless MUST by Complexity Gate) |
| Interview conducted for a perspective | Populate target sections with interview results |
| Section is MUST but no interview data | Include section with placeholder comment (`<!-- 情報未収集 -->`) |
| Phase 0.7 cancel path with specification document | Include `docs/designs/{slug}.md` content as design context in Section 4 (Implementation Details). The pre-validated specification supplements interview results for Section 4.1-4.5 |
| Phase 0.3-0.5 all skipped (`phases_skipped: "0.3-0.5"`) | Apply [EDGE-3 row 4](./references/edge-cases-create.md#edge-3-interview-result-reflection-rules): populate all MUST sections per Complexity Gate using Phase 0.1 context (What/Why/Where). For MUST sections where no data is available from Phase 0.1, include `<!-- 情報未収集 -->` placeholder. AI-inferred content is marked with `（推定）`. SHOULD/OMIT sections follow normal Gate rules |

**Step 4: Generate Acceptance Criteria**

Generate ACs in Given/When/Then format following the template's AC generation order:
1. Happy path: from UX/purpose
2. Error path: from edge cases + constraints
3. Boundary: from min/max/empty/null/duplicate/timeout
4. Non-regression: when existing feature impact exists
5. Compatibility: when interface/public contract changes

AC count must match the complexity guideline (XS: 2-3, S: 3-5, M: 5-8, L: 8-12, XL: 12+ split recommended).

**AC writing rules**:
- Given: Explicit preconditions (state/data/flag/role)
- When: One specific action
- Then: Observable outcomes only (status code, UI text, DB state, event, log)
- 1 AC = 1 verification purpose
- Forbidden vague verbs: "appropriately", "correctly", "optimally"

**Step 5: Generate Test Specification Table**

Generate test cases that map to ACs:
- Every AC maps to at least 1 T-xx row
- BugFix/Refactor: add Non-regression rows
- Non-functional requirements: add NFR test rows
- Minimum rows per complexity (XS: 2, S: 3, M: 5, L: 8, XL: 12)

**Step 5.5: Append Extension Metadata**

If `Extends: #{number}` was set in Phase 0.3 (when the user selected "拡張として作成する" / "Create as an extension"), add the extension reference to the Issue body:

**Case 1: `## 関連` section already exists** in the generated body — append `Extends: #{number}` to the existing section:

```markdown
## 関連

{existing content}
Extends: #{number}
```

**Case 2: No `## 関連` section exists** — create a new section after `## 概要`:

```markdown
## 関連

Extends: #{number}
```

**Cross-reference comment** (post-creation): After the Issue is created in Phase 2.2 and `issue_number` is available, post a cross-reference comment on the extended Issue. This must execute **after** the `create-issue-with-projects.sh` script returns, not during body generation:

```bash
gh issue comment {extended_issue_number} --body "Related: This Issue has been extended by #{new_issue_number}"
```

If no `Extends` metadata was set in Phase 0.3, skip this step entirely.

**Step 6: Output Validation**

Before finalizing the body, verify all items from the template's Output Validation Checklist:
- [ ] Type and Complexity set in Meta
- [ ] All MUST sections for the complexity level present
- [ ] AC count matches complexity guideline
- [ ] Each AC has a corresponding Test Case ID (T-xx)
- [ ] Target Files list exists with file paths
- [ ] All MUST requirements are testable (no vague verbs)
- [ ] No empty headings

If validation fails, fix the Issue body before proceeding to creation.

**Example Issue body**: See `{plugin_root}/templates/issue/template-structure.md` for the full section-by-section template with type-specific Section 3 definitions. AC count and test row count MUST follow the complexity guidelines in Step 4 and Step 5.

**Backward compatibility**: The old format (概要/背景・目的/仕様詳細/変更内容/チェックリスト) is no longer generated in the normal flow. Phase 0.9 (XL decomposition) retains the simplified format. Existing Issues retain their format.

### 2.3 Custom Field Configuration

**Note**: Standard fields (Status, Priority, Complexity) are already set by the common script in Phase 2.2. This section handles additional custom fields only.

**Prerequisites**: `project_id` and `item_id` are obtained from the Phase 2.2 script result. If `project_reg` is `"skipped"`, skip this section. If `project_reg` is `"failed"`, offer recovery options (see below). If `project_reg` is `"partial"`, proceed directly to Phase 2.3 with existing IDs (see below).

#### Projects Registration Failure Recovery

**Branching by `project_reg` value:**

| `project_reg` | Meaning | Action |
|----------------|---------|--------|
| `"failed"` | `item-add` itself failed; no `project_id`/`item_id` available | Present recovery options (retry/skip/cancel) |
| `"partial"` | `item-add` succeeded but some field settings failed; `project_id` and `item_id` are available in the script result | Proceed directly to Phase 2.3 with existing `project_id`/`item_id` (field settings will be retried there) |

**When `project_reg` is `"failed"`**, present recovery options via `AskUserQuestion`:

```
Projects 登録が失敗しました。

失敗理由: {warnings_from_script}

オプション:
- リトライする（推奨）
- スキップして続行（手動で登録）
- キャンセル
```

**Retry**: Re-register the already-created Issue to Projects using `gh project item-add`. The Issue itself was already created successfully in Phase 2.2, so only Projects registration is retried:

```bash
gh project item-add {project_number} --owner {owner} --url {issue_url} --format json
```

On success, retrieve the `item_id` from the result and continue to Phase 2.3 (custom fields) and Phase 2.5 (Iteration). On second failure, skip with warning.

**Skip**: Proceed without Projects registration. Display: `⚠️ Projects 登録をスキップしました。手動で登録してください: gh project item-add {project_number} --owner {owner} --url {issue_url}`

**Cancel**: Issue is already created (Phase 2.2) and is not deleted. Skip Projects registration and all subsequent phases (Phase 2.3 custom fields, Phase 2.5 Iteration). Display the created Issue URL: `Issue #{issue_number} は作成済みです: {issue_url}。Projects 登録は手動で行ってください。`

**When `project_reg` is `"partial"`**, display a warning and proceed directly to Phase 2.3:

```
⚠️ Projects フィールド設定が一部失敗しました。

失敗箇所: {warnings_from_script}

Projects への登録自体は成功しています。Phase 2.3 でカスタムフィールドの設定を試みます。
```

Use the `project_id` and `item_id` from the script result (already available) and continue to Phase 2.3. No retry or user confirmation is needed.

To retrieve field IDs for custom fields, query the project fields:

```bash
gh api graphql -f query='
query($owner: String!, $projectNumber: Int!) {
  user(login: $owner) {
    projectV2(number: $projectNumber) {
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -F projectNumber={project-number}
```

**Note**: If the owner is an Organization, change `user` to `organization`.

Set custom fields defined in `github.projects.fields` of `rite-config.yml`.

**Processing flow:**

1. Read `github.projects.fields` from `rite-config.yml`
2. Extract fields other than standard fields (status, priority, complexity)
3. For each custom field:
   - Retrieve the field ID with the same name from GitHub Projects (using the query below)
   - If an option with `default: true` exists, set it
   - If `default` is not specified, ask the user to select using `AskUserQuestion`

**How to retrieve field IDs:**

From the field list retrieved in Phase 2.3, search for a field matching the custom field name (case-insensitive):

```bash
# Phase 2.3 のクエリ結果から、フィールド名で検索
# 例: rite-config.yml に "category" がある場合、
# fields.nodes から name が "category" (case-insensitive) のフィールドを探す
```

**Field name matching rules:**
- Convert both strings to lowercase for comparison (case-insensitive)
- Example: `Category` in rite-config.yml and `category` in GitHub Projects are considered a match
- Exact match only (partial match not allowed)

**Custom field configuration example:**

```yaml
# rite-config.yml
github:
  projects:
    fields:
      category:
        enabled: true
        options:
          - { name: "BLOCKS" }
          - { name: "Autonomous", default: true }
          - { name: "ComPath" }
          - { name: "Other" }
```

With the above configuration, set the `category` field to "Autonomous" (default):

```bash
# カスタムフィールドを設定
gh project item-edit --project-id {project-id} --id {item-id} --field-id {category-field-id} --single-select-option-id {autonomous-option-id}
```

**Fallback behavior on error:**

If an error occurs during custom field configuration, continue with Issue creation and skip only the affected field's configuration.

| Error Type | Behavior | Message |
|-----------|----------|---------|
| Field does not exist | Skip and continue | See below |
| Option does not match | Skip and continue | See below |
| API error | Skip and continue | "API エラーが発生しました。手動で設定してください。" |

**When a custom field does not exist in Projects:**

```
警告: カスタムフィールド "{field_name}" が GitHub Projects に見つかりません。
このフィールドの設定をスキップします。
GitHub Projects でフィールド名を確認し、rite-config.yml を更新してください。
```

**When a custom field option does not match:**

```
警告: カスタムフィールド "{field_name}" のオプション "{option_name}" が GitHub Projects に見つかりません。
利用可能なオプション: {available_options}
このフィールドの設定をスキップします。
```

### 2.4 Iteration Assignment (Optional)

**Prerequisites**: `project_id` and `item_id` are obtained from the Phase 2.2 script result.

If `iteration.enabled` is `true` in `rite-config.yml`, confirm Iteration assignment:

```
この Issue を Iteration に割り当てますか？

オプション:
- 現在のスプリント: Sprint 3 (2025-01-06 - 2025-01-19)
- 次のスプリント: Sprint 4 (2025-01-20 - 2025-02-02)
- バックログ（割り当てない）（推奨）
```

**Default**: "バックログ（割り当てない）"
- New Issues are typically added to the backlog and assigned during sprint planning
- However, urgent Issues can be assigned to the current sprint

When an assignment is selected:

```bash
gh api graphql -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { iterationId: $iterationId }
    }
  ) {
    projectV2Item { id }
  }
}' -f projectId="{project_id}" -f itemId="{item_id}" -f fieldId="{iteration_field_id}" -f iterationId="{selected_iteration_id}"
```

---

## Phase 3: Completion Report

Report the creation results:

```
Issue #{number} を作成しました

タイトル: {title}
URL: {issue-url}

Projects 設定:
- Status: Todo
- Priority: {priority}
- Complexity: {complexity}
- Iteration: {iteration_name または "バックログ"}  <!-- Iteration 有効時のみ表示 -->
```

---

## Configuration File Reference

The following settings are referenced from `rite-config.yml`:

```yaml
github:
  projects:
    enabled: true
    project_number: {number}  # 使用する Project の番号（必須）
    owner: "{owner}"          # Project の owner（省略時はリポジトリ owner）
    fields:
      status:
        options:
          - { name: "Todo", default: true }
      priority:
        options:
          - { name: "Medium", default: true }
      complexity:
        options:
          - { name: "M", default: true }
```

### Configuration Value Priority

1. If `github.projects.project_number` is set in `rite-config.yml` -> Use that Project
2. If not set -> Auto-detect Projects linked to the repository
3. If no Project is found -> Skip adding to Projects

---

## Error Handling

### On API Errors

When a GraphQL API call fails:

1. **Retry**: Retry up to 3 times on network errors (exponential backoff)
2. **Fallback**: If the API is unavailable, continue with Issue creation and skip Projects operations
3. **Error reporting**: Display specific error messages and remediation steps

See [GraphQL Helpers](../../references/graphql-helpers.md#error-handling) for details.

---

## Phase 4: Terminal Completion

<!-- caller: this sub-skill is terminal. Phase 4 deactivates flow state and outputs the user-visible completion message (✅) + next steps as the last user-visible content, with [create:completed:{N}] embedded in a trailing HTML comment (grep-matchable but not user-visible). The orchestrator's 🚨 Mandatory After Delegation section MUST run in the SAME response turn as a defense-in-depth no-op (Step 1/2 skipped when marker present). DO NOT stop before the orchestrator's self-check completes. -->

> **Design decision** (Issue #444, D-01): This sub-skill is a terminal sub-skill — it handles flow-state deactivation, next-step output, and completion marker internally. The caller (`create.md`) retains the same steps as defense-in-depth but is no longer the primary path for these actions. This prevents the workflow from stalling when the orchestrator fails to continue after sub-skill return.
>
> **Design decision** (Issue #561, D-01): The `[create:completed:{N}]` sentinel is now emitted as an HTML comment (`<!-- [create:completed:{N}] -->`) so that the user-visible final line is the `✅` completion message + next steps, not the sentinel token. The string `[create:completed:N]` inside the HTML comment is still grep-matchable (`grep -F` / `grep -E '\[create:completed:[0-9]+\]'`) so existing hook/test contracts (AC-3) remain intact. The HTML comment is invisible in rendered Markdown views, which also weakens the LLM's turn-boundary heuristic that previously treated a bare `[create:completed:N]` line as a natural stopping point (root cause of the #561 regression).

### 4.1 Flow State Deactivation

After Phase 3 (Completion Report), deactivate the flow state:

```bash
# --if-exists で flow state file 不在時は silent skip。
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "create_completed" \
  --next "none" --active false \
  --if-exists
```

### 4.2 Completion Message (User-facing, Issue #552 / #561)

> **Design decision** (Issue #552 Bug2 + Issue #561 UX fix): The `[create:completed:{N}]` sentinel marker is primarily for hooks/scripts (grep-verified by AC-4 of #552 / AC-3 of #561). Emit an explicit user-visible completion message followed by the next-steps block; place the sentinel as a trailing HTML comment so the user's visible final content is the `✅` message + next steps (AC-2 of #561).

Output the user-facing completion message as the first deliverable line of Phase 4's output:

```
✅ Issue #{issue_number} を作成しました: {issue_url}
```

Where `{issue_number}` and `{issue_url}` are from the Phase 2.2 script result.

### 4.3 Next Steps Output

Output the next steps after the completion message:

```
次のステップ:
1. `/rite:issue:start {issue_number}` で作業を開始
2. 作業完了後 `/rite:pr:create` で PR 作成
```

Where `{issue_number}` is the Issue number from Phase 2.2.

### 4.4 Completion Marker (HTML comment form)

Output the completion marker as an **HTML comment on the final line** — invisible to the user in rendered views, but matchable by `grep -F '[create:completed:'` / `grep -E '\[create:completed:[0-9]+\]'`:

- **Issue created**: `<!-- [create:completed:{issue_number}] -->`

This marker signals to both the orchestrator (`create.md`) and any hook/grep consumer that the workflow is fully complete (Issue created, Projects registered, flow-state deactivated, next steps displayed). The HTML comment form ensures the user-visible final line is the next-steps block, not the sentinel token.

**Output rules**:
1. `<!-- [create:completed:{N}] -->` is the **absolute last line** of Phase 4's output — no plain text after it
2. The user-visible final content (last non-comment line) MUST be the next-steps block (`次のステップ: ...`) immediately preceded by the `✅` completion message
3. Do **NOT** output narrative text like `→ create.md に戻ります` — it is not actionable and creates a natural stopping point for the LLM
4. Do **NOT** emit the sentinel as a bare `[create:completed:{N}]` line (without HTML comment wrapping) — the bare form regressed in Issue #561 as the user-visible terminal token
5. The orchestrator's 🚨 Mandatory After Delegation section serves as defense-in-depth only

**Concrete output example**:

```
✅ Issue #1234 を作成しました: https://github.com/.../issues/1234

次のステップ:
1. `/rite:issue:start 1234` で作業を開始
2. 作業完了後 `/rite:pr:create` で PR 作成

<!-- [create:completed:1234] -->
```

---

## 🚨 Caller Return Protocol

When this sub-skill completes (Phase 4 terminal completion), the Issue creation workflow is **fully complete**:
- Issue created and registered to GitHub Projects ✅
- flow state deactivated (`active: false`) ✅
- User-visible completion message + next steps displayed ✅
- Completion marker emitted as HTML comment (`<!-- [create:completed:{N}] -->`) ✅

The caller (`create.md`) MAY execute its 🚨 Mandatory After Delegation section as defense-in-depth (idempotent — re-deactivating an already-deactivated flow state and re-outputting next steps is harmless).
