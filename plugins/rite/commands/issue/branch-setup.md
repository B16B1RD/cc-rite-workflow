---
description: ブランチの作成とベースブランチの設定
---

# Branch Setup Module

This module handles branch creation and base branch configuration.

## Phase 2.3: Branch Creation

Create a branch from `branch.base` in `rite-config.yml`.

### 2.3.1 Base Branch and Language Setting Retrieval

**Important**: Before creating a branch, **always** read `rite-config.yml` with the Read tool and check the following values:
- `branch.base`: Base branch for branch creation
- `language`: Language setting for commit messages and output (used in Phase 5.1.1)

**Retrieval flow:**

```
Read ツールで rite-config.yml を読み取る（**省略不可**）
├─ 成功
│   ├─ branch.base が設定済み（例: "develop"）→ その値を使用
│   ├─ branch.base が未設定 → "main" を使用
│   ├─ language が設定済み → その値を保持（Phase 5.1.1 で使用）
│   └─ language が未設定 → "auto" として扱う
└─ 失敗（ファイル不在）
    ├─ branch.base → "main" を使用
    └─ language → "auto" として扱う
```

**Definition of "not set":**
- `branch.base` key does not exist
- `branch.base` key value is `null` or empty string
- `branch` section itself does not exist

**Note**: Using `main` as the default is only for cases where the config file doesn't exist or `branch.base` is explicitly not set. If `branch.base` is specified in the config file, **always** use that value.

### 2.3.2 Branch Creation

Create a feature branch with the following steps:

**Step 1: Fetch latest remote information**
```bash
git fetch origin
```

**Step 2: Check out the base branch**

First check if the base branch exists locally; if not, create it from remote:

```bash
# ローカルブランチが存在する場合
git checkout {base_branch}

# ローカルブランチが存在しない場合（上記が失敗した場合）
git checkout -b {base_branch} origin/{base_branch}
```

**Step 3: Update base branch to latest**
```bash
git pull origin {base_branch}
```

**Step 4: Create feature branch**
```bash
git checkout -b {branch_name}
```

**When the base branch does not exist on remote:**

On Step 2 failure, process with the following flow:

1. **2.3.2.1**: Check remote existence with `git ls-remote --heads origin {base_branch}`
   - Remote exists -> Determine as network error etc., display error and abort
   - Remote absent -> Proceed to 2.3.2.2

2. **2.3.2.2**: Check local existence — check **output** (non-empty = exists), NOT exit code (always 0)

   > **DO NOT** use exit code (`&&`, `||`, `$?`) to determine branch existence. `git branch --list` always returns exit code 0 regardless of whether a match is found.

   ```bash
   local_match=$(git branch --list "{base_branch}")
   if [ -n "$local_match" ]; then
     echo "BRANCH_EXISTS"
   else
     echo "BRANCH_NOT_FOUND"
   fi
   ```

   - `local_match` non-empty (local exists) -> Confirm with `AskUserQuestion` (push and continue / use local as base / fix config / cancel)
   - `local_match` empty (local absent) -> Proceed to 2.3.2.3

### 2.3.2.3 When Not Found on Both Local and Remote

**Step 1: Determine fallback branch**

Search for a fallback in order: `main` -> default branch:
```bash
git ls-remote --heads origin main
# main がない場合:
gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
```

Abort with error if no fallback exists.

**Step 2: User confirmation**

`AskUserQuestion`: Create from `{fallback_branch}` (recommended) / Fix config / Cancel

**Step 3: Create base branch**

1. Check out and sync the fallback branch
2. Create base branch with `git checkout -b {base_branch}`
3. Push to remote with `git push -u origin {base_branch}`
4. Display error and abort on any step failure

After Step 3 completion, proceed to Step 4 of 2.3 (feature branch creation).

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0).

Before returning control to the caller, update `.rite-flow-state` to the post-branch phase. This ensures the stop-guard routes correctly even if the caller's 🚨 Mandatory After section is not executed immediately:

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands below.

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase2_post_branch" \
  --active true \
  --next "rite:issue:branch-setup completed. Proceed to Phase 2.4 (Projects Status update to In Progress). Do NOT stop." \
  --if-exists
```

After the flow-state update above, output the result pattern:

- **Branch created**: `[branch:created:{branch_name}]`

This pattern is consumed by the orchestrator (`start.md`) to determine the next action.

---

## 🚨 Caller Return Protocol

When this sub-skill completes, control **MUST** return to the caller (`start.md`). The caller **MUST immediately** execute its 🚨 Mandatory After 2.3 section:

1. Proceed to Phase 2.4 (Projects Status update to In Progress)

**→ Return to `start.md` and proceed to Phase 2.4 now. Do NOT stop.**
