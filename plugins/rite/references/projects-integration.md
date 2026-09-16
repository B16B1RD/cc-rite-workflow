---
description: GitHub Projects 連携ロジック（Status更新、Iteration割り当て）
---

# GitHub Projects Integration

This module handles GitHub Projects integration including Status updates and Iteration assignments.

## 2.4 GitHub Projects Status Update

Retrieve the Project item ID and move the Issue's board Status to the requested **role** (`in_progress` when work starts). The board column that role is displayed as comes from `rite-config.yml` (`github.projects.fields.status.options`, see §2.4.8) — no consumer names a column directly.
**Automatically add the Issue to the Project if it is not registered.**

> **Runtime execution**: Callers (`skills/open/SKILL.md` ステップ 2.4 / `skills/ready/SKILL.md` Phase 4 / `skills/issue-close/SKILL.md`) invoke `plugins/rite/scripts/projects-status-update.sh`, which is the single source of truth for Projects Status updates. The bash examples in §2.4.2 – §2.4.5 below document the underlying API calls for reference and debugging. Do NOT reproduce them inline in new commands — delegate to the script instead (inlining the API calls duplicates the single source of truth and invites drift).

**Helper contract:** Supply JSON with `issue_number`, `owner`, `repo`, `project_number`, and `status_role` (`todo`, `in_progress`, `in_review`, `done`, or `cancelled`), plus optional `auto_add` and `non_blocking`. `status_name` is invalid even when `status_role` is also present; missing or unknown roles are invalid input. Input errors exit 1 regardless of `non_blocking`.

`hooks/scripts/lib/projects-status-config.sh` maps roles to option names from `github.projects.fields.status.options`. No role keys means legacy mode with the five English names. Any role key enables explicit mode: `todo`, `in_progress`, `in_review`, and `done` are required once each; `cancelled` is optional. Use only single-line flow entries such as `{ role: todo, name: "未着手" }` (unquoted names are also supported). Mixed role/non-role entries, duplicate roles or names, unknown or missing required roles, empty names, and unsupported YAML syntax fail resolution. An explicit `fields.status.name` requires an exact field-name match; when omitted, field lookup tries `ステータス` then `Status`.

The JSON `.result` is `updated`, `skipped_not_in_project`, `skipped_terminal_conflict`, `skipped_role_unmapped`, or `failed`. `skipped_role_unmapped` means an optional `cancelled` role was omitted in explicit mode: exit 0, empty warnings, and no board write, including no auto-add. A configured role with no matching board option returns `failed`. Other handled failures retain the helper's `non_blocking` behavior and `.warnings[]` diagnostics.

### 2.4.1 Configuration Retrieval

Retrieve Projects configuration from `rite-config.yml`:

```yaml
github:
 projects:
 enabled: true
 project_number: 2
 owner: "username" # Project のオーナー（ユーザーまたは組織）
```

### 2.4.2 Check Issue Project Registration Status

```bash
# Issue のプロジェクトアイテム情報を取得
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
 repository(owner: $owner, name: $repo) {
 issue(number: $number) {
 url
 projectItems(first: 10) {
 nodes {
 id
 project {
 id
 number
 }
 }
 }
 }
 }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

Check `projectItems.nodes` from the result:
- `nodes` is an empty array `[]` -> **Not registered in Project**
- `nodes` has elements -> Check if the target `project.number` matches the configured value

### 2.4.3 When Not Registered in Project: Auto-Add

When not registered in a Project, add the Issue with `gh project item-add`:

```bash
# Issue を Project に追加
gh project item-add {project_number} --owner {owner} --url {issue_url}
```

After adding, re-execute the 2.4.2 query to retrieve the new item_id.

### 2.4.4 Retrieve Status Field Information

**Important**: Option IDs (`{in_progress_option_id}`) always need to be retrieved from the API. Only field IDs can be specified via `field_ids`; the IDs of each option (the columns the `done` / `in_progress` / … roles map to) are not included.

**Field ID retrieval:**

If `github.projects.field_ids.status` is set in `rite-config.yml`, it may be passed as `status_field_id_hint`. The helper still resolves the field by name and requires the hint to match that field's ID; a mismatch returns `failed` without `item-edit`:

Replace the configured value with your actual project's ID (see CONFIGURATION.md for how to obtain):

```yaml
github:
 projects:
 field_ids:
 status: "PVTSSF_your-status-field-id"
```

**Option ID retrieval (always required):**

```bash
gh project field-list {project_number} --owner {owner} --format json
```

From the resulting JSON, find the configured Status field by exact name (or `ステータス`, then `Status`, when no name is configured) and retrieve the following:
- `id`: Status field ID (`{status_field_id}`), also checked against `status_field_id_hint` when supplied
- From the `options` array, the `id` of the option whose `name` exactly matches the display name the `in_progress` role resolves to (`{in_progress_option_id}`; `In Progress` only when the config is in legacy mode)

**Retrieval logic:**
1. Execute API (always needed for option ID retrieval)
2. Resolve the Status field by its configured name or the default field-name candidates
3. Retrieve `{status_field_id}` from that field and verify any supplied `status_field_id_hint` matches
4. Option ID: resolve the role to its display name through `projects_status_name_for_role`, then take the matching option's `id` from the API result

### 2.4.5 Update Status to "In Progress"

The option id is the one resolved for the `in_progress` role in §2.4.4; the same command moves any other role once its option id is resolved:

```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {in_progress_option_id}
```

### 2.4.6 Result Confirmation

`{status_name}` is the display name the requested role resolves to on this board:

| Case | Action | Result Message |
|------|--------|----------------|
| Registered in Project | Status update only | `Status を "{status_name}" に更新しました` |
| Not registered in Project | Add -> Status update | `Project に追加し、Status を "{status_name}" に更新しました` |
| Projects disabled | Skip | `警告: GitHub Projects が設定されていません` |

### 2.4.7 Parent Issue Status Update (for child Issues)

**Execution condition**: Always execute 2.4.7.1 (parent detection). If a parent is found, proceed to 2.4.7.2–2.4.7.4. If no parent is found, emit the `[DEBUG] parent not detected` log (per 2.4.7.1 — silent skips are prohibited) and then skip 2.4.7.2–2.4.7.4 (this is the normal path for standalone Issues).

**Non-blocking**: All steps in 2.4.7 are non-blocking. Any failure displays a warning and continues the workflow.

#### 2.4.7.1 Parent Issue Detection

Detect the parent Issue of the current (child) Issue. **Three methods are tried in order (OR combination); the first successful result wins.** This ordering is critical: `## 親 Issue` body meta is placed PRIMARY because it is the most reliable source in repositories that use `/rite:issue-create` (Decompose Path, flat workflow; writes this section to every child), and it requires no dependency on GitHub's native Sub-Issues feature.

> **Consistency requirement**: The same 3-method OR detection **structure** MUST be used in `close.md` Phase 4.5.1 — i.e., the same three method ordering (body meta → Sub-Issues API → tasklist search), the same OR combination semantics, and the same `[DEBUG] parent not detected` emission on total failure. **Context-dependent parameters MAY differ** between the two sites where the surrounding workflow demands it; specifically, Method 3's `--state` filter is `open` here (start side — closed parents do not need In Progress promotion) and `all` in close.md Phase 4.5.1 (close side — the closing Issue's parent may itself already be closed). These differences are intentional and are not drift. **Method 3's validation loop body is also a sync target**: the self-match exclusion (`cand != {issue_number}`), the body re-validation regex (which confirms the candidate body actually contains the `- [ ] #{issue_number}` / `- [x] #{issue_number}` tasklist line), and `--limit 10` MUST stay identical across both sites — only the `--state` filter differs. If the detection method ordering, the OR semantics, or the Method 3 loop body (regex / `--limit`) diverge between start and close, the past silent-skip and false-positive regressions in parent-child sync reappear.

> `-R {owner_repo}` は [gh-cli-patterns.md の Owner/Repo Resolution](./gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）をリテラル置換する

**Method 1: `## 親 Issue` body meta (PRIMARY)**

Read the current (child) Issue body and search for the `## 親 Issue` section. This section is written by `/rite:issue-create` (Decompose Path, flat workflow) when child Issues are created from a parent. Format:

```
## 親 Issue

#{parent_number} - {parent_title}
```

```bash
child_body=$(gh issue view {issue_number} -R {owner_repo} --json body --jq '.body')
# SIGPIPE 防止: here-string で subprocess を排除
parent_number=$(grep -A2 '^## 親 Issue' <<< "$child_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
echo "method1_parent=${parent_number:-none}"
```

If `parent_number` is non-empty, extract it as `{parent_issue_number}` and proceed to 2.4.7.2.

**Method 2: Sub-Issues API (secondary)**

If Method 1 found no parent, query GitHub's native Sub-Issues feature:

```bash
gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
 repository(owner: $owner, name: $repo) {
 issue(number: $number) {
 parent { number }
 }
 }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

If `parent` is not null, extract `parent.number` as `{parent_issue_number}` and proceed to 2.4.7.2. (Only `number` is requested because 2.4.7.2 re-queries the parent by number for project data, so `title`/`state` are unused here and would only create drift with `close.md` Phase 4.5.1 Method 2.)

**Method 3: Tasklist search (last resort)**

If Methods 1 and 2 both failed:

```bash
# GitHub code search は `[`/`]` を無視する緩いマッチのため、複数候補を取得して検証する
candidates=$(gh issue list -R {owner_repo} --state open --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number --limit 10 --jq '.[].number')
parent_number=""
for cand in $candidates; do
  # 自己マッチ除外: standalone Issue が自分自身を親と誤検出するのを防ぐ
  [ "$cand" = "{issue_number}" ] && continue
  # 妥当性検証: 候補 body に当該 tasklist 行が実在するか確認（緩いマッチで拾った無関係 Issue を排除）
  cand_body=$(gh issue view "$cand" -R {owner_repo} --json body --jq '.body')
  if grep -qE "^[[:space:]]*-[[:space:]]\[[ xX]\][[:space:]]*#{issue_number}([^0-9]|$)" <<< "$cand_body"; then
    parent_number="$cand"
    break
  fi
done
echo "method3_parent=${parent_number:-none}"
```

**Note**: `--state open` is intentional — closed parent Issues do not need Status updates. The search matches both unchecked (`- [ ]`) and checked (`- [x]`) tasklist items to ensure checkbox state independence (consistent with [epic-detection.md](./epic-detection.md)). GitHub code search with `[`/`]` characters is known to be unreliable — it ignores the bracket literals and returns nearly every Issue — so Method 3 must **not** adopt a hit blindly. The self-match exclusion (`cand != {issue_number}`) plus the body re-validation (the candidate's body must actually contain the `- [ ] #{issue_number}` / `- [x] #{issue_number}` tasklist line) guard against the false positives this unreliability causes; without the body check, self-exclusion alone would simply promote the next unrelated Issue in the loose-match result set.

If `parent_number` is non-empty, extract it as `{parent_issue_number}` and proceed to 2.4.7.2.

**When all three methods failed (no parent found)**: This is the normal path for standalone Issues. Emit an explicit **debug log** (not a warning) so that the skip is visible in execution traces — silent skips are prohibited by the MUST requirement "同期失敗時は silent skip せず、明示的にログまたは warning を出力する" and the preceding incidents which all stemmed from silent skips in parent-child sync:

```bash
echo "[DEBUG] parent not detected for issue #{issue_number} — processing as standalone (methods tried: body_meta, sub_issues_api, tasklist_search)"
```

Then skip 2.4.7.2–2.4.7.4.

#### 2.4.7.2 Retrieve Parent Issue Project Item and Current Status

Retrieve the parent Issue's (identified in 2.4.7.1 as `{parent_issue_number}`) project membership and current Status in a single query:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
 repository(owner: $owner, name: $repo) {
 issue(number: $number) {
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
}' -f owner="{owner}" -f repo="{repo}" -F number={parent_issue_number}
```

From the result:

1. Find the node where `project.number` matches `{project_number}` from `rite-config.yml`
2. From `fieldValues.nodes`, take the entry whose `field.name` is one of the Status field candidates (`projects_status_field_candidates`: the configured `github.projects.fields.status.name`, or `ステータス` then `Status`) and extract its `name` as `{parent_status_name}`. If no such entry exists (Status field value unset), `{parent_status_name}` is empty
3. Map the column name to its role. The parent's Status is judged on the role, never on the column name, so a board that spells its columns differently is judged the same way:

```bash
source {plugin_root}/hooks/scripts/lib/projects-status-config.sh || { echo "ERROR: projects-status-config.sh を読み込めませんでした" >&2; exit 1; }
if ! parent_status_role=$(cd "$(git rev-parse --show-toplevel)" && projects_status_role_for_name "{parent_status_name}"); then
  echo "警告: rite-config.yml の Status 設定が不正なため、親 Issue の Status を判定できません。更新をスキップします" >&2
  parent_status_role="<invalid-config>"
fi
echo "[CONTEXT] PARENT_STATUS=role=${parent_status_role}; name={parent_status_name}"
```

The marker is the judgement input for 2.4.7.3 — the role lives only in this shell and the executor reads tool output, so a block that keeps it in a variable leaves the table with nothing to branch on. An empty `{parent_status_name}` maps to an empty role and is treated as `todo` in 2.4.7.3.

**When `projectItems.nodes` is empty** (parent Issue not registered in Project):

```
警告: 親 Issue #{parent_issue_number} は Project に登録されていません
親 Issue の Status 更新をスキップします
```

Display warning and skip 2.4.7.3–2.4.7.4 (non-blocking).

#### 2.4.7.3 Status Condition Check

Only update the parent Issue's Status if its role is `todo`. This prevents overwriting a more advanced Status (e.g. `in_progress` set by a sibling child Issue). The judgement reads the `role=` / `name=` fields of the `[CONTEXT] PARENT_STATUS=` marker emitted in 2.4.7.2:

| `role=` | Action |
|---|---|
| `<invalid-config>` | Skip — the Status configuration is invalid and the role cannot be judged (2.4.7.2 has already displayed the warning) |
| `todo` | Proceed to 2.4.7.4 (update to the `in_progress` role) |
| empty with empty `name=` (Status value unset) | Proceed to 2.4.7.4 — treated as `todo` (Status field value not yet selected) |
| `in_progress` | Skip — already at the target role. Display: `警告: 親 Issue #{parent_issue_number} は既に {parent_status_name} です` |
| `in_review` / `done` / `cancelled` | Skip — more advanced or terminal. Display: `警告: 親 Issue #{parent_issue_number} は既に {parent_status_name} です（更新スキップ）` |
| empty with non-empty `name=` (column maps to no role) | Skip — the operator placed the Issue in a column `rite-config.yml` does not map, and it is not overwritten. Display: `警告: 親 Issue #{parent_issue_number} の Status 列 "{parent_status_name}" は rite-config.yml の role に対応しません（更新スキップ）` |

#### 2.4.7.4 Update Parent Issue Status to the `in_progress` Role

The write goes through `scripts/projects-status-update.sh` with the role, exactly as 2.4.2–2.4.5 do for the Issue itself; the helper resolves the Status field by its candidate names and the option by the role's configured column name, so no field or option is named here. `auto_add` is `false` — 2.4.7.2 already confirmed the parent is on the board, and a parent that is not must not be added as a side effect of starting a child:

```bash
parent_status_args=$(jq -n \
  --argjson issue {parent_issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg role "in_progress" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_role:$role, auto_add:$auto_add, non_blocking:$non_blocking}')
parent_status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$parent_status_args")
parent_status_result=$(printf '%s' "$parent_status_json" | jq -r '.result // "failed"' 2>/dev/null)
[ -z "$parent_status_result" ] && parent_status_result=failed
case "$parent_status_result" in
  updated)
    echo "親 Issue #{parent_issue_number} の Status を in_progress 列に更新しました" ;;
  *)
    printf '%s' "$parent_status_json" | jq -r '.warnings[]?' 2>/dev/null | sed 's/^/  /' >&2
    echo "警告: 親 Issue #{parent_issue_number} の Status 更新に失敗しました (result: $parent_status_result)" >&2 ;;
esac
```

#### 2.4.7.5 Error Handling

Parent Issue Status update failure does **not** block the start of work. Each step handles errors independently:

| Step | Error Case | Response |
|------|-----------|----------|
| 2.4.7.1 | Sub-Issues API fails | Try Tasklist fallback. If both fail, emit `[DEBUG] parent not detected` and skip (per 2.4.7.1 — silent skips prohibited) |
| 2.4.7.1 | Tasklist search returns no results | Emit `[DEBUG] parent not detected` and skip (standalone Issue — per 2.4.7.1, not silent) |
| 2.4.7.2 | GraphQL query fails | Display `警告: 親 Issue の Projects 情報取得に失敗しました。Status 更新をスキップします` |
| 2.4.7.2 | Parent not registered in Project | Display warning and skip (see 2.4.7.2) |
| 2.4.7.2 | Status configuration invalid | Display warning and skip 2.4.7.3–2.4.7.4 (see 2.4.7.2) |
| 2.4.7.3 | Column maps to no role | Display warning naming the column and skip (see 2.4.7.3) |
| 2.4.7.4 | helper returns anything but `updated` | Display the helper's warnings and `警告: 親 Issue #{parent_issue_number} の Status 更新に失敗しました` and continue |

### 2.4.8 Terminal Status Set

**Single source of truth** for the meaning of the Status **roles**: which roles are terminal ("this Issue is finished and no reconciler may move it again"), how the progress roles are ordered, and which closure reason each terminal role answers to. Roles are fixed names inside rite; the column each role is displayed as on a given board is declared in `rite-config.yml` (`github.projects.fields.status.options[].role` / `.name`) and resolved at runtime by `hooks/scripts/lib/projects-status-config.sh`. No consumer reads a display name as a meaning — every judgement below is made on the role, and every write names a role. The consumers listed below cite this section when they rely on it; none of them define their own set.

| Role | Meaning | Closure reason it maps from (`stateReason`) |
|------|---------|----------------------------------------------|
| `done` | Work completed | `COMPLETED` |
| `cancelled` | Work abandoned — closed as not planned (wontfix, superseded) or as duplicate | `NOT_PLANNED`, `DUPLICATE` |

The three progress roles `todo` / `in_progress` / `in_review` are not terminal. The display name is whatever the operator's board calls the column (`Done`, `完了`, `Closed`, …); it carries none of the meaning above.

**Progress ordering.** `todo` < `in_progress` < `in_review` < `done` (`projects_status_rank`). A stage check asks "has the Issue reached this role", so a re-entry that observes a later role is not a missed transition. `cancelled` has no position in this order and must not be given one — an Issue that was abandoned has not "reached" any progress stage, and ranking it would let a stage check read a cancelled Issue as having advanced.

Two rules follow from the terminal set, and both are load-bearing:

1. **A row whose column maps to a terminal role is never drift.** The consumers below skip it entirely. An Issue deliberately parked on the `cancelled` column must not be dragged to `done`, and vice versa — the operator's choice between the two carries information that the automation cannot reconstruct.
2. **A CLOSED Issue on a non-terminal role is drift, and its destination role comes from `stateReason`.** `NOT_PLANNED` and `DUPLICATE` land on `cancelled`, `COMPLETED` on `done`. Every other value (a reason the API leaves unset, or any future enum GitHub may add) lands on `done` **with a WARNING**. Leaving such a row alone is not an option: a CLOSED Issue stranded on a `todo` or `in_review` column is exactly the stall this reconciliation exists to clear.

**Optional `cancelled` role.** A board with no column for abandoned Issues omits the `cancelled` row from `fields.status.options`. Then: a `cancelled` write returns `skipped_role_unmapped` (exit 0, no warning, no board write, no auto-add) and the caller treats it as a normal outcome; the drift check lists a CLOSED `NOT_PLANNED` / `DUPLICATE` row as informational and keeps it out of the findings count and the exit code; the `done` closure guard below still refuses to move such an Issue to `done`. **Unmapped column.** A column that maps to no role (for example an operator's `Blocked`) is never written or ranked — consumers leave it in place and emit a WARNING that names the column. A mapped role whose option is missing on the board follows the normal failure path (`failed` with the available option names).

Board provisioning is the operator's: `/rite:setup` adds the Status options only to a Project it creates itself and, for an existing Project, verifies that every configured display name exists on the board without adding any option.

**Consumers** (each references this section by name, never by line number):

| Consumer | How it uses the set |
|----------|---------------------|
| `hooks/scripts/projects-board-drift-check.sh` | Excludes rows whose column maps to a terminal role from drift detection; picks the reconcile destination role from `stateReason`; lists `NOT_PLANNED` / `DUPLICATE` rows as informational when `cancelled` is unmapped |
| `hooks/post-compact.sh` | Pulls only a `todo` / `in_progress` row forward to `in_review`; terminal roles and columns that map to no role are left untouched |
| `hooks/scripts/projects-status-gate.sh` | Compares the reached role against the expected role by rank; reports a column that resolves to `cancelled` as an abandoned Issue rather than a dropped transition, and an unmapped column as unverifiable |
| `skills/lint/references/plugin-checks-rationale.md` | Documents why the drift check consults the closure reason |
| `skills/issue-cancel/SKILL.md` | Requests the `cancelled` role as the destination for the `NOT_PLANNED` closure it performs — the deliberate-cancellation counterpart to the drift check's `--reconcile`; on a board without that role the Status is left unchanged |
| `scripts/projects-status-update.sh` | Read-before-write on roles: refuses `cancelled`→`done` and any `done` write to a CLOSED `NOT_PLANNED` / `DUPLICATE` Issue (`skipped_terminal_conflict`); same-terminal is a no-op `updated` |

**Helper write guard.** `projects-status-update.sh` reads the current Status via `fieldValues` before `item-edit`, maps the column to its role, and compares roles. A row on the `cancelled` column refuses a `done` write (`result=skipped_terminal_conflict`). A CLOSED Issue with `stateReason=NOT_PLANNED` or `DUPLICATE` also refuses `done`, even when `cancelled` is unmapped or its board Status is not terminal. This closure guard takes precedence over same-terminal no-op handling. Otherwise, same-terminal writes are idempotent (`updated`, no `item-edit`); `done`→`cancelled` still writes so `/rite:issue-cancel` can resync a `NOT_PLANNED` row. Progress-axis requests (`todo` / `in_progress` / `in_review`) resolve their column the same way and always write.

## 2.5 Iteration Assignment (Optional)

Execute only when `iteration.enabled` is `true` and `iteration.auto_assign` is `true` in `rite-config.yml`:

### 2.5.1 Retrieve Iteration Field Information

```bash
gh api graphql -f query='
query($projectId: ID!) {
 node(id: $projectId) {
 ... on ProjectV2 {
 fields(first: 20) {
 nodes {
 ... on ProjectV2IterationField {
 id
 name
 configuration {
 iterations {
 id
 title
 startDate
 duration
 }
 }
 }
 }
 }
 }
 }
}' -f projectId="{project_id}"
```

### 2.5.2 Current Iteration Determination

Identify the current iteration from the retrieved iteration list:

```
アルゴリズム:
1. 今日の日付を取得
2. 各イテレーションについて:
 - endDate = startDate + duration (days)
 - startDate <= 今日 < endDate なら「現在」
3. 該当なし → 次のイテレーション（開始日が最も近い未来のもの）を提案
```

### 2.5.3 Execute Iteration Assignment

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
}' -f projectId="{project_id}" -f itemId="{item_id}" -f fieldId="{iteration_field_id}" -f iterationId="{current_iteration_id}"
```

### 2.5.4 Result Display

```
Iteration: {iteration_title} ({start_date} - {end_date})
```

**Note**: Display a warning and skip if the Iteration field does not exist or the current iteration cannot be found:

```
警告: Iteration の割り当てをスキップしました
理由: {reason}
```
