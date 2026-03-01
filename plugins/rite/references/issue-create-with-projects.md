---
description: Issue 作成 + GitHub Projects 統合の共通シェルスクリプト呼び出しガイド
---

# Issue Creation with Projects Integration

Guide for using the common shell script that creates a GitHub Issue and registers it in GitHub Projects with field configuration (Status, Priority, Complexity, Iteration).

**Script location**: `{plugin_root}/scripts/create-issue-with-projects.sh`

Referenced from:
- `commands/pr/fix.md` Phase 4.3.4 Step 2
- `commands/pr/review.md` Phase 7.4.2
- `commands/issue/create.md` Phase 2.2
- `commands/pr/cleanup.md` Phase 1.7.3.2
- `commands/issue/parent-routing.md` Phase 1.5.4.5
- `commands/issue/start.md` Phase 5.2.0.1
- `commands/issue/create.md` Phase 0.9.1 (parent Issue creation in XL decomposition)
- `commands/issue/create.md` Phase 0.9.2 (Sub-Issue bulk creation in XL decomposition)

Related documents:
- [projects-integration.md](./projects-integration.md) - Existing Issue Status update / Iteration assignment (this document covers new Issue creation with Projects registration)

---

## Usage

### Step 1: Prepare Issue Body

Write the Issue body to a temporary file:

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{issue_body_markdown}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi
```

### Step 2: Invoke the Script

```bash
result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{title}" \
  --arg body_file "$tmpfile" \
  --argjson labels '["label1"]' \
  --argjson enabled true \
  --argjson project_number 2 \
  --arg owner "B16B1RD" \
  --arg status "Todo" \
  --arg priority "Medium" \
  --arg complexity "S" \
  --arg iter_mode "none" \
  --arg source "pr_review" \
  '{
    issue: { title: $title, body_file: $body_file, labels: $labels },
    projects: {
      enabled: $enabled,
      project_number: $project_number,
      owner: $owner,
      status: $status,
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: $source, non_blocking_projects: true }
  }'
)")
```

### Step 3: Parse the Result

**Note**: When the script exits with non-zero (`exit 1`), the `result=$(bash ...)` assignment still captures stdout, but `$?` will be non-zero. Always check the exit code or validate that `result` is non-empty before parsing.

```bash
# Check if the script succeeded (result may be empty if the script crashed)
if [ -z "$result" ]; then
  echo "ERROR: Script returned no output" >&2
  # handle error...
fi

issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "WARNING: $w"; done
```

---

## Input JSON Schema

```yaml
issue:
  title: string              # Issue title (required)
  body_file: string          # Path to tmpfile with body markdown (optional)
  labels: [string]           # Labels to apply (optional)
  assignees: [string]        # Assignees (optional)
projects:
  enabled: true|false        # From rite-config.yml github.projects.enabled
  project_number: number     # From rite-config.yml github.projects.project_number
  owner: string              # From rite-config.yml github.projects.owner
  status: "Todo"             # Default: "Todo"
  priority: "High|Medium|Low"  # Determined by caller
  complexity: "XS|S|M|L|XL"   # Determined by caller
  iteration:
    mode: "none|auto"        # Default: "none". "auto" assigns to current iteration
    field_name: "Sprint"     # Default: "Sprint"
options:
  source: string             # Caller identifier (pr_review|pr_fix|cleanup|lint|interactive|parent_routing|xl_decomposition)
  non_blocking_projects: true  # Default: true. Projects failure doesn't block Issue creation
```

---

## Output JSON Contract

```json
{
  "issue_url": "https://github.com/.../issues/123",
  "issue_number": 123,
  "project_id": "PVT_...",
  "item_id": "PVTI_...",
  "project_registration": "skipped|ok|partial|failed",
  "warnings": ["string"]
}
```

| `project_registration` | Description |
|------------------------|-------------|
| `ok` | All fields set successfully |
| `partial` | Issue added to Project but some fields failed |
| `skipped` | Projects disabled or not configured |
| `failed` | `gh project item-add` failed entirely |

---

## Caller-Specific Priority Mapping

Each caller determines Priority using its own logic before passing it to the script.

### fix.md (Phase 4.3.4): Skip Reason Keyword Matching

| Skip Reason Keyword | Issue Priority | Reason |
|---------------------|----------------|--------|
| `緊急`, `重大`, `urgent`, `critical` | High | Requires priority attention |
| All others | Medium | Normal priority (default) |

### review.md (Phase 7.4): Severity-Based Mapping

| Finding Severity | Issue Priority | Reason |
|-----------------|----------------|--------|
| CRITICAL | High | Requires immediate attention |
| HIGH | Medium | Normal priority |
| MEDIUM | Low | Lower priority |

### cleanup.md (Phase 1.7.3): Default Medium

| Context | Issue Priority | Reason |
|---------|----------------|--------|
| Incomplete tasks from merged PR | Medium | Default for remaining work |

### parent-routing.md (Phase 1.5.4): Inherited from Parent

| Context | Issue Priority | Reason |
|---------|----------------|--------|
| Child Issue creation | Inherited from parent | Use parent's Priority value |

### create.md (Phase 0.9): XL Decomposition

| Context | Issue Priority | Reason |
|---------|----------------|--------|
| Parent Issue creation (Phase 0.9.1) | Determined in Phase 1 | Use Priority value decided during Issue creation |
| Sub-Issue bulk creation (Phase 0.9.2) | Inherited from parent | Use parent Issue's Priority value |

### start.md (Phase 5.2.0.1): Lint Warnings

| Context | Issue Priority | Reason |
|---------|----------------|--------|
| Out-of-scope lint warnings | Medium | Default for lint findings |

---

## Error Handling

The script handles errors internally with the following behavior:

| Error Case | Response |
|------------|----------|
| `gh issue create` failure | Output JSON with `project_registration: "failed"` + `exit 1`. Caller's `result=$(bash ...)` captures stdout but gets non-zero exit code |
| `gh project item-add` failure | Output JSON with `project_registration: "failed"` + `exit 0` (non-blocking) or `exit 1` |
| `item_id` retrieval failure (after fallback to last: 20) | Output JSON with `project_registration: "partial"` + `exit 0` |
| Field setup failure | Retry once, then output JSON with `project_registration: "partial"` + `exit 0` |
| Projects not configured | Output JSON with `project_registration: "skipped"` + `exit 0` |

**Exit code convention:**
- `exit 0`: Success or non-blocking failure (Projects-related issues when `non_blocking_projects: true`)
- `exit 1`: Fatal error (Issue creation itself failed, or blocking failure when `non_blocking_projects: false`)

**Behavior on error:**
- All output (success and error) is written to **stdout** as JSON. The caller captures stdout via `result=$(bash ...)` and checks the exit code
- Projects registration failure does not block Issue creation when `non_blocking_projects: true` (default)
- Warnings are collected in the `warnings` array for caller to display
- If `result` is empty (script crashed), callers should check `$?` and handle gracefully

---

## Script Internal Details

The script automatically handles:
- Owner type detection (User vs Organization) for GraphQL queries
- Item ID retrieval with fallback (last: 10 → last: 20)
- Field ID and option ID resolution from project field metadata
- Iteration auto-assignment when `iteration.mode: "auto"`
- Single retry on field setup failures
