---
description: 親 Issue から適切な子 Issue を自動選択
---

# Child Issue Selection Module

This module handles automatic selection of appropriate child Issues when starting work from a parent Issue.

## Phase 1.6: Child Issue Selection

### 1.6.1 Selection Logic Overview

When starting work from a parent Issue, automatically select an appropriate child Issue.

**Selection priority:**

| Priority | Condition | Reason |
|----------|-----------|--------|
| 1 | No dependencies and not started | Can start immediately |
| 2 | All dependencies completed | Unblocked |
| 3 | Oldest by creation date | FIFO principle |
| 4 | Lowest complexity (when set) | Prioritize early completion |

### 1.6.2 Fetch Child Issue List

> **Reference**: Use the [Extended Query](../../references/epic-detection.md#extended-query-with-body-and-projects) from the Epic Detection reference for dependency analysis.

Use information already obtained in Phase 0.3, or retrieve additional information using the Extended Query (includes `body` and `projectItems` fields).

**Note**: The `body` field is used for dependency checking in 1.6.3 (`depends on #XX` pattern search).

**When child Issues are not registered in Projects:**

There may be child Issues where `projectItems` returns an empty array (`nodes: []`) (manually created child Issues, Phase 1.5.4.6 registration failures, etc.). In this case, apply the following fallback:

| Field | Fallback Value |
|-------|---------------|
| Status | Treated as unset (not subject to "In Progress" exclusion) |
| Priority | `null` (placed last in priority-based sorting) |
| Complexity | `null` (placed last in complexity-based sorting) |

**Note**: Child Issues not registered in Projects are not excluded from selection candidates. Since Status is unknown, they are not judged as "being worked on elsewhere" and are retained as candidates.

**When child Issues exceed 20:**

See [Pagination and Limits](../../references/epic-detection.md#pagination-and-limits) in the Epic Detection reference for handling large child Issue lists.

### 1.6.3 AI-Based Child Issue Selection

Based on the retrieved child Issue information, AI selects the optimal child Issue:

**Selection criteria:**

1. **Dependency check**: Whether the child Issue body contains `depends on #XX` or `blocked by #XX`
2. **Status check**: Projects Status field
3. **Priority check**: Priority field (when set)
4. **Creation date**: Older is preferred
5. **Complexity**: Complexity field (when set, lower is preferred)

**Selection logic implementation:**

```
選択候補 = 子 Issue 一覧から state: OPEN のもの
候補をフィルタリング:
  - blocked ラベルがあるものを除外
  - Projects Status が "In Progress" のものを除外（他で作業中）
  - 注: projectItems が空の子 Issue は除外しない（Phase 1.6.2 のフォールバック参照）

候補が 1 件の場合:
  → その子 Issue を選択

候補が複数の場合:
  1. 依存関係を分析し、依存先がすべて完了しているものを抽出
  2. 抽出結果が 1 件 → その子 Issue を選択
  3. 抽出結果が複数 → 優先度・作成日時・複雑度で順位付け
  4. 順位付けで明確に決まる → 最上位を選択
  5. 順位付けで決まらない → ユーザーに選択を求める

候補が 0 件の場合:
  → Phase 1.5.5（全完了）または全ブロック状態を確認
```

**Fallback when Priority/Complexity is not set:**

When there are child Issues with unset (`null`) Priority or Complexity during ranking (Step 3), process in the following order:

| Field | Handling when unset | Reason |
|-------|-------------------|--------|
| Priority | Placed after child Issues with set values | Unknown priority, so process those with explicitly set priority first |
| Complexity | Placed after child Issues with set values | Unknown complexity, so process those with confirmed low complexity first |

**Example:**

```
子 Issue A: Priority=High, Complexity=S
子 Issue B: Priority=null, Complexity=null  ← Projects 未登録
子 Issue C: Priority=Medium, Complexity=M

順位: A → C → B（Priority 設定済みを優先、未設定は最後）
```

### 1.6.4 User Selection Confirmation

When AI auto-selects, or when selection from multiple candidates is needed:

**Auto-selection (confirmation only):**

```
子 Issue #{sub_number} を選択しました。

タイトル: {sub_title}
理由: {selection_reason}

この子 Issue で作業を開始しますか？

オプション:
- この子 Issue で開始する（推奨）
- 別の子 Issue を選択する
- 親 Issue で直接作業する
```

**Processing when "Select a different child Issue" is chosen:**

Transition to the "selection from multiple candidates" flow. Specifically:
1. Display the child Issue list (candidates only) obtained in 1.5.2
2. Ask the user to select (using the format below for "selection from multiple candidates")
3. Proceed to 1.6.5 "Post-selection processing" with the selected child Issue

**Selection from multiple candidates:**

```
複数の子 Issue が着手可能です。どれから作業を開始しますか？

| # | タイトル | 作成日 | 備考 |
|---|---------|--------|------|
| #{sub_number_1} | {sub_title_1} | {created_at_1} | {note_1} |
| #{sub_number_2} | {sub_title_2} | {created_at_2} | {note_2} |
| ... | ... | ... | ... |

オプション:
- #{sub_number_1}: {sub_title_1}（推奨）
- #{sub_number_2}: {sub_title_2}
- 親 Issue で直接作業する
```

### 1.6.5 Post-Selection Processing

After a child Issue is selected:

1. **Context switch**: Subsequent Phases are executed for the selected child Issue
2. **Retain parent Issue linkage**: Record parent Issue number for progress management
3. **Proceed to Phase 2**: Execute branch creation etc. for the selected child Issue

**Retaining parent Issue information:**

```json
{
  "parent_issue": {
    "number": {parent_number},
    "title": "{parent_title}"
  },
  "selected_sub_issue": {
    "number": {sub_number},
    "title": "{sub_title}"
  }
}
```

**Important**: Subsequent Phases are executed for the selected child Issue.

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0).

Before returning control to the caller, update flow state to the post-child-selection phase. This ensures the stop-guard routes correctly even if the caller's 🚨 Mandatory After section is not executed immediately:

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands below.

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase1_6_post_child" \
  --active true \
  --parent-issue {parent_issue_number} \
  --next "rite:issue:child-issue-selection completed. Proceed to Phase 2 (work preparation). Do NOT stop." \
  --if-exists
```

> **Note**: `{parent_issue_number}` is the parent Issue number (the Issue originally passed to `/rite:issue:start`). This persists the parent-child relationship in flow state so it survives context compaction (#497).

After the flow-state update above, output the appropriate result pattern:

- **Child selected**: `[child-selection:selected:{number}]` (where `{number}` is the selected child Issue number)
- **No children / skipped**: `[child-selection:skipped]`

This pattern is consumed by the orchestrator (`start.md`) to determine the next action.

---

## 🚨 Caller Return Protocol

When this sub-skill completes, control **MUST** return to the caller (`start.md`). The caller **MUST immediately** execute its 🚨 Mandatory After 1.6 section:

1. Proceed to Phase 2 (work preparation)

**→ Return to `start.md` and proceed to Phase 2 now. Do NOT stop.**
