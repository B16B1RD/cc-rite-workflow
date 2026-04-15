---
description: 親Issue判定・子Issue選択・分解提案ロジック
---

# Parent Issue Routing

This module handles parent Issue detection, child Issue selection, and decomposition proposals.

## Detection and Routing

### 1.5.1 Parent Issue Detection Criteria

> **Reference**: Context variables (`is_parent_issue`, `has_sub_issues`, `parent_issue_reason`) are defined in [Epic/Parent Issue Detection Reference](../../references/epic-detection.md#context-variables).

Determine routing based on detection results from Phase 0.3:

| Condition | Result |
|-----------|--------|
| `is_parent_issue: false` | **Normal Issue** -> Proceed to Phase 2 (branch exits, proceed to branch creation) |
| `is_parent_issue: true` and `has_sub_issues: true` | **Parent Issue (with children)** -> Proceed to Phase 1.5.2 (check child Issue states) |
| `is_parent_issue: true` and `has_sub_issues: false` | **Parent Issue (no children)** -> Proceed to Phase 1.5.4 (show decomposition proposal) |

### 1.5.2 Child Issue State Check

When child Issues exist (`has_sub_issues: true`), first check their states.

**Step 1: Basic classification using Phase 0.3 information**

Using child Issue information (state, labels) obtained in Phase 0.3, perform the following basic classification:

| State | Condition | Action |
|-------|-----------|--------|
| **Completed** | `state: CLOSED` | Count only |
| **Blocked** | `state: OPEN` and labels contain `blocked` | Exclude from selection candidates |
| **Candidate** | `state: OPEN` and not blocked | Detailed check in Step 2 |

**Step 2: Batch retrieval of Projects Status**

For candidate child Issues, Claude dynamically generates a GraphQL alias query (`issueN: issue(number: N) { ...IssueStatus }` pattern) based on the child Issue number list to batch-retrieve Projects Status (split execution for more than 10 items).

**Step 3: Final state classification**

| State | Condition | Action |
|-------|-----------|--------|
| **Completed** | `state: CLOSED` | Count only |
| **In Progress** | `state: OPEN` and Projects Status is "In Progress" | Exclude from selection candidates |
| **Not Started** | `state: OPEN` and Projects Status is "Todo" or unset | Selection candidate |
| **Blocked** | Labels contain `blocked` | Exclude from selection candidates |

### 1.5.3 Processing Flow When Child Issues Exist

Based on the state check results from 1.5.2, process with the following flow:

```
親 Issue 検出（has_sub_issues: true）
├─ すべて完了済み → 親 Issue を自動クローズ（Phase 1.5.5 参照）
├─ 着手可能な子 Issue がある → Phase 1.6 へ（子 Issue 選択）
├─ 子 Issue がすべて着手中 → ユーザーに確認（下記「すべて着手中の場合」参照）
└─ 子 Issue がすべてブロック状態 → ユーザーに確認（下記「すべてブロック状態の場合」参照）
```

**When all child Issues are in progress:**

Confirm with `AskUserQuestion` (display child Issue state list):
- Wait for work to complete -> Instruct to interrupt and re-run
- Work in parallel (beware of conflicts) -> Transition to 1.6.4 flow
- Work directly on parent Issue -> Proceed to Phase 2
- Cancel

**When all child Issues are blocked:**

Confirm with `AskUserQuestion` (display list with block reasons):
- Wait for unblock -> Instruct to interrupt and re-run
- Work directly on parent Issue -> Proceed to Phase 2
- Cancel

**Retrieving block reasons:** Extract from Issue body / latest comment using `Blocked by:` / `ブロック理由:` / `Depends on:` patterns. Display "blocked label applied" if not found.

### 1.5.4 When No Child Issues Exist: Decomposition Proposal

When a parent Issue has zero child Issues, **automatically determine whether to show or skip the decomposition proposal based on complexity**.

#### 1.5.4.1 Complexity Retrieval

Retrieve complexity from Issue body (default: `M`):

1. Search `## 複雑度` section: `/^## 複雑度\s*\n+\s*(XS|S|M|L|XL)/im`
2. Search `Complexity:` line: `/^Complexity:\s*(XS|S|M|L|XL)/im`
3. Use default `M` if not found

#### 1.5.4.2 Threshold Retrieval

Retrieve `issue.auto_decompose_threshold` from `rite-config.yml` (default: `M`).

#### 1.5.4.3 Automatic Decomposition Decision

Determine whether to show or skip the decomposition proposal based on the following criteria:

**Complexity ordering**: XS(1) < S(2) < M(3) < L(4) < XL(5)

**Decision rules:**

| Condition | Decision |
|-----------|----------|
| Complexity < threshold | Skip (start work without confirmation) |
| Complexity == threshold | Decide by Issue body analysis (Phase 1.5.4.3.1) |
| Complexity > threshold | Show decomposition proposal |

##### 1.5.4.3.1 Issue Body Analysis (when complexity equals threshold)

Search the Issue body for file paths (`/[\w\-\/]+\.(?:ts|tsx|js|jsx|py|go|rs|md|yml|yaml|json)/gm`) and "change target" sections to estimate the scope of changes:

| Detection Result | Decision |
|-----------------|----------|
| 1-2 files | Skip |
| 3+ files | Show decomposition proposal |
| No files detected | Show decomposition proposal |

#### 1.5.4.4 Customization via Configuration

The threshold can be customized via `issue.auto_decompose_threshold` in `rite-config.yml` (`XS` through `XL` or `none`). `none` always shows the decomposition proposal.

#### 1.5.4.5 Decomposition Proposal (default behavior)

When complexity exceeds the threshold, confirm with `AskUserQuestion`:
- Create child Issues for decomposition (recommended) -> Propose decomposition plan -> Create after approval -> Proceed to Phase 1.6
- Start work as-is -> Proceed to Phase 2
- Cancel

**When creating child Issues:**

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

**Pre-loop: Retrieve parent Issue's Priority** (executed once before the child Issue creation loop):

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $issueNumber: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $issueNumber) {
      projectItems(first: 10) {
        nodes {
          project {
            number
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field {
                  ... on ProjectV2SingleSelectField {
                    name
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F issueNumber={parent_issue_number}
```

Traverse `projectItems.nodes` then `fieldValues.nodes`, retrieve the `name` where `field.name` is `"Priority"`. Match `project.number` with `rite-config.yml`'s `github.projects.project_number`. **Fallback**: Use the option with `default: true` from `rite-config.yml`'s `github.projects.fields.priority.options` if not found.

**Note**: This `repository`-based query needs no `user`/`organization` switching.

**Child Issue creation loop** (create one at a time -> register via common script):

For each child Issue, execute the following in a **single Bash tool invocation**:

```bash
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
  --argjson labels '{parent_labels_json}' \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "{inherited_priority}" \
  --arg complexity "{estimated_complexity}" \
  --arg iter_mode "{iteration_mode}" \
  '{
    issue: { title: $title, body_file: $body_file, labels: $labels },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "parent_routing", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
sub_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
sub_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done

# Sub-issues API linkage (mandatory but non-blocking) — see references/graphql-helpers.md#addsubissue-helper
# Note: jq -r で field 欠落時は "null" 文字列が返るため、正規表現で数値であることを確認する
if [[ "$sub_issue_number" =~ ^[0-9]+$ ]] && [ "$sub_issue_number" != "0" ]; then
  link_result=$(bash {plugin_root}/scripts/link-sub-issue.sh \
    "{owner}" "{repo}" "{parent_issue_number}" "$sub_issue_number")
  link_status=$(printf '%s' "$link_result" | jq -r '.status')
  link_msg=$(printf '%s' "$link_result" | jq -r '.message')
  case "$link_status" in
    ok|already-linked)
      echo "✅ $link_msg"
      ;;
    failed)
      printf '%s' "$link_result" | jq -r '.warnings[]' \
        | while read -r w; do echo "⚠️ $w" >&2; done
      echo "⚠️ Sub-issues API linkage failed for #$sub_issue_number; body meta fallback in place" >&2
      ;;
    *)
      # 未知 status を silent 通過させない (Issue #514 MUST NOT)
      echo "⚠️ Unexpected link status '$link_status' for #$sub_issue_number (msg: $link_msg)" >&2
      ;;
  esac
else
  echo "⚠️ sub_issue_number が不正のため Sub-issues API linkage をスキップします: '$sub_issue_number'" >&2
fi
```

**Placeholder descriptions:**
- `{inherited_priority}`: Priority inherited from parent Issue (from pre-loop query above)
- `{estimated_complexity}`: Complexity estimated during decomposition proposal (XS-XL)
- `{iteration_mode}`: `"auto"` if `iteration.enabled` and `iteration.auto_assign` are `true`, otherwise `"none"`
- `{parent_labels_json}`: JSON array of parent Issue labels to inherit (e.g., `["enhancement"]`)
- `{parent_issue_number}`: The parent Issue number (the one currently being decomposed)
- `{owner}`, `{repo}`: Repository owner/name (from `gh repo view --json owner,name`)

After each child Issue is created:
1. Retain `sub_issue_url` and `sub_issue_number` for Tasklist update and Sub-issues API linkage
2. The script handles Projects registration + field setup + iteration assignment internally
3. The inline `link-sub-issue.sh` invocation establishes the GitHub `subIssues` API relation. **Failures are non-blocking**: warnings are surfaced to stderr, the body meta (`Parent Issue: #N`) acts as fallback, and processing continues.

After all child Issues are created and registered:
4. Add `## Sub-Issues` section (Tasklist) to parent Issue body
5. Decomposition content can be revised up to 3 times in a loop

**Complexity estimation during decomposition proposal**: When presenting decomposition proposals, estimate and specify each child Issue's Complexity (values from `rite-config.yml`'s `github.projects.fields.complexity.options`: XS/S/M/L/XL). Estimation criteria: 1-2 changed files and under 50 changed lines -> XS, 3-5 changed files or 50-200 changed lines -> S, 5-10 changed files or 200-500 changed lines -> M, more -> L/XL.

**Display registration results** after all child Issues are created:

```
子 Issue を GitHub Projects に登録しました。

| # | タイトル | Status | Priority | Complexity | Projects 状態 |
|---|---------|--------|----------|------------|--------------|
| #{sub_number_1} | {sub_title_1} | Todo | {priority} | {complexity_1} | {project_reg} |
| #{sub_number_2} | {sub_title_2} | Todo | {priority} | {complexity_2} | {project_reg} |
```

**Error handling:**

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` | Display warning, skip that child Issue. Continue with next |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Child Issue itself is created |
| Projects not configured | Script returns `project_registration: "skipped"` automatically |

**Note**: Projects registration failure does not block child Issue creation or parent Issue Tasklist updates.

### 1.5.5 Processing When All Child Issues Are Complete

When all child Issues are completed (`state: CLOSED`):

```
Issue #{number} のすべての子 Issue が完了しています。

| # | タイトル | 状態 |
|---|---------|------|
| #{sub_number} | {sub_title} | ✅ 完了 |
| ... | ... | ... |

親 Issue をクローズしますか？

オプション:
- 親 Issue をクローズする（推奨）
- 親 Issue を開いたまま終了
```

**When "Close parent Issue" is selected:**

```bash
gh issue close {issue_number} --comment "すべての子 Issue が完了したため、自動クローズします。"
```

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0).

Before returning control to the caller, update `.rite-flow-state` to the post-parent-routing phase. This ensures the stop-guard routes correctly even if the caller's 🚨 Mandatory After section is not executed immediately:

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands below.

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase1_5_post_parent" \
  --next "rite:issue:parent-routing completed. Proceed to Phase 1.6 (child issue selection) if applicable, then Phase 2 (work preparation). Do NOT stop." \
  --if-exists
```

After the flow-state update above, output the appropriate result pattern:

- **Parent detected (with children)**: `[parent-routing:parent:{count}]` (where `{count}` is the number of child Issues)
- **Not a parent Issue**: `[parent-routing:not-parent]`
- **Parent detected (no children, decomposition proposed)**: `[parent-routing:decomposed]`

This pattern is consumed by the orchestrator (`start.md`) to determine the next action.

---

## 🚨 Caller Return Protocol

When this sub-skill completes, control **MUST** return to the caller (`start.md`). The caller **MUST immediately** execute its 🚨 Mandatory After 1.5 section:

1. Proceed to Phase 1.6 (if child issues exist) or Phase 2

**→ Return to `start.md` and proceed to Phase 1.6 or Phase 2 now. Do NOT stop.**
