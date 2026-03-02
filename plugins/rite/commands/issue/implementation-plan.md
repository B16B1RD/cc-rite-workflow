---
description: Issue 内容を分析して実装計画を生成
---

# Implementation Plan Generation Module

This module handles Issue content analysis and implementation plan generation.

## Phase 3: Implementation Plan Generation

> **Reference**: Apply the Phase 3 checklist from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).
> In particular, check `assumption_surfacing`, `confusion_management`, and `inline_planning`.

> **Relationship with `create.md` Phase 0.7**: If the Issue was created via `/rite:issue:create`, a specification document (high-level design: What/Why/Where) may exist in `docs/designs/`. This module generates the **detailed implementation plan** (How/Step-by-step) that builds on that specification. Check for a linked design doc in the Issue body before starting analysis — it provides pre-validated requirements and architectural decisions that reduce redundant exploration.

### 3.1 Issue Content Analysis

Leverage the quality score and extracted information validated in Phase 1 to perform analysis for implementation plan generation:

| Element | Extracted Content | Relationship with Phase 1 |
|---------|-------------------|---------------------------|
| **What** | What to do (from title/summary) | Validated in Phase 1.2 |
| **Why** | Why it's needed (from background/purpose) | Validated in Phase 1.2 |
| **Where** | Where to change (from change content/impact scope) | Validated in Phase 1.2, refined here |
| **Scope** | Impact scope (from impact scope/checklist) | Validated in Phase 1.2, refined here |

**Note**: Also include information supplemented as quality score C/D in Phase 1 in the analysis.

### 3.2 Identify Files to Change

Identify files that need changes based on Issue content:

1. File paths explicitly mentioned in Issue body
2. Related file detection through codebase exploration
3. File count estimation based on complexity

**Exploration methods** (using Claude Code tools):

| Tool | Usage | Example |
|------|-------|---------|
| Glob | File pattern search | `**/*.md`, `commands/**/*.md` |
| Grep | Keyword search | Related function names, class names, config keys |
| Read | File content review | Detailed review of candidate files |

**Note**: Use Claude Code's dedicated tools, not bash commands, to explore the codebase.

### 3.2.1 Reference Implementation Discovery

> **Reference**: Apply `reference_discovery` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).

After identifying files to change in 3.2, automatically discover reference implementations by searching for existing files with similar patterns. This follows the Oracle pattern: using existing correct implementations as guides for consistency.

**Discovery steps**:

1. **Same directory, same extension**: For each target file, search for other files in the same directory with the same extension
   - Tool: `Glob` with pattern `{target_directory}/*.{ext}`
   - Example: Target `commands/issue/implementation-plan.md` → search `commands/issue/*.md`

2. **Name pattern matching**: Identify naming patterns and search for similar files (execute when applicable — skip if Step 1 already found 3+ candidates)
   - Extract suffix patterns (e.g., `*-handler.ts`, `*-service.ts`, `*-plan.md`)
   - Tool: `Glob` with pattern `**/*-{suffix}.{ext}`
   - Example: Target `user-handler.ts` → search `**/*-handler.ts`

3. **Test-implementation correspondence**: Check for matching test/implementation file pairs (execute when applicable — skip for non-test projects or if 3+ candidates already found)
   - Pattern: `{name}.ts` ↔ `{name}.test.ts`, `{name}.spec.ts`
   - Pattern: `{name}.md` ↔ `docs/tests/{name}.test.md`

4. **Read reference files**: Use `Read` tool to examine each selected reference file and extract structural patterns (heading format, section organization, naming conventions, code style, etc.)
   - Read up to 3 selected files
   - Extract: section structure, formatting conventions, placeholder patterns, error handling patterns

**Early termination**: If 3 or more candidates are found in Step 1, proceed directly to Step 4 without executing Steps 2-3.

**Selection criteria** (when multiple candidates found):

| Priority | Criterion | Reason |
|----------|-----------|--------|
| 1 | Same directory files | Most likely to share conventions |
| 2 | Files with similar functionality (determined by file name semantics and directory context, e.g., both are CRUD operation commands) | Similar structure expected |
| 3 | Recently modified files (`Glob` tool returns results sorted by modification time; prefer files appearing earlier in results) | Reflect latest conventions |

Limit to **max 3 reference files** to avoid information overload.

**Record format**: See the "参考実装" section in the 3.3 template for the exact format. The record must include both the reference file paths and the structural patterns extracted in Step 4.

**When no references found**:

```markdown
### 参考実装
参考実装: なし（新規ディレクトリまたは初めてのファイルパターン）
→ プロジェクト全体の慣習に従ってください
```

### 3.3 Implementation Plan Generation

Generate an implementation plan in the following format:

```
## 実装計画

### 変更対象ファイル
| ファイル | 変更内容 |
|---------|---------|
| {file_path} | {change_description} |

### 参考実装
| 参考ファイル | 参考理由 |
|-------------|---------|
| {reference_file_path} | {reason} |

#### 参考にすべきパターン
- {pattern_1}
- {pattern_2}

### 実装ステップ（依存グラフ）

| Step | 内容 | depends_on | 並列グループ |
|------|------|------------|-------------|
| S1 | {step_1} | — | A |
| S2 | {step_2} | — | A |
| S3 | {step_3} | S1 | B |
| S4 | {step_4} | S1, S2 | C |

> **depends_on**: そのステップの前提となるステップ ID（`—` は依存なし＝最初に実行可能）
> **並列グループ**: 同じグループのステップは並列実行可能（依存関係がないため）

### 注意点・考慮事項
- {consideration_1}
- {consideration_2}
```

**Note**: The "参考実装" section is populated from 3.2.1 discovery results. If no references were found, use the "no references" format from 3.2.1.

### 3.4 User Confirmation

Confirm the plan with `AskUserQuestion`:

```
上記の実装計画で進めますか？

オプション:
- 計画を承認（推奨）
- 計画を修正
- スキップ（計画なしで進める）
```

**Subsequent processing for each option**:

| Option | Subsequent Processing |
|--------|----------------------|
| **Approve plan** | -> Record in work memory in 3.5 -> Proceed to Phase 4 |
| **Modify plan** | Receive additional instructions from user and regenerate plan -> Return to 3.4 |
| **Skip** | Skip 3.5 -> Proceed directly to Phase 4 (plan is not recorded) |

**Note**: Implementation work itself starts after Phase 4 is complete. This phase only handles plan confirmation and recording.

### 3.5 Record in Work Memory

Record the approved plan in the work memory comment.

#### 3.5.1 Re-fetch Comment Body

Re-fetch the work memory comment body immediately before updating. This defends against context compaction that may have discarded the body from Phase 2.6:

```bash
comment_id=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty')
comment_body=$(gh api repos/{owner}/{repo}/issues/comments/${comment_id} --jq '.body')
```

#### 3.5.2 Selective Update

**Critical**: Do NOT reconstruct the entire comment body from context or memory. Use the re-fetched `comment_body` as the base and apply only the modifications listed below.

**Sections to UPDATE:**

| Section | Update Rule |
|---------|------------|
| `最終更新` (in セッション情報) | Replace with current timestamp |
| `コマンド` (in セッション情報) | Set to `rite:issue:start` |
| `フェーズ` (in セッション情報) | Set to `phase3` |
| `フェーズ詳細` (in セッション情報) | Set to `実装計画生成` |
| `次のステップ` | Set to `1. 実装計画に沿って作業開始` |

**Section to ADD/REPLACE:**

| Section | Content |
|---------|---------|
| `実装計画` | Insert the approved plan from Phase 3.3. Place after `### セッション情報` and before `### 進捗サマリー` |
| `計画逸脱ログ` | Add if not present: `_計画逸脱はありません_` |

**Sections to PRESERVE as-is (copy verbatim from existing body):**

- `Issue` / `開始` / `ブランチ` (in セッション情報)
- `進捗サマリー`
- `要確認事項`
- `変更ファイル`
- `決定事項・メモ`
- All other existing sections not listed in the UPDATE/ADD tables above

#### 3.5.3 Update the Comment

> **Reference**: Apply [Work Memory Update Safety Patterns](../../references/gh-cli-patterns.md#work-memory-update-safety-patterns) for all steps below.

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
tmpfile=$(mktemp)
backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
trap 'rm -f "$tmpfile"' EXIT

# 1. Backup before update
printf '%s' "$comment_body" > "$backup_file"
original_length=$(printf '%s' "$comment_body" | wc -c)

# 2. Write the selectively-updated body
printf '%s' "$updated_body" > "$tmpfile"

# 3. Empty body guard (10 bytes = minimum plausible work memory content)
if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH. Backup: $backup_file" >&2
  exit 1
fi

# 4. Header validation
if grep -q '📜 rite 作業メモリ' "$tmpfile"; then
  : # Header present, proceed
else
  echo "ERROR: Updated body missing work memory header. Restoring from backup." >&2
  cp "$backup_file" "$tmpfile"
  exit 1
fi

# 5. Body length comparison safety check (reject if updated body is less than 50% of original)
updated_length=$(wc -c < "$tmpfile")
if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
  echo "ERROR: Updated body is less than 50% of original (${updated_length}/${original_length}). Aborting PATCH. Backup: $backup_file" >&2
  exit 1
fi

# 6. Safe PATCH with error handling
jq -n --rawfile body "$tmpfile" '{"body": $body}' | gh api repos/{owner}/{repo}/issues/comments/${comment_id} \
  -X PATCH \
  --input -
patch_status=$?
if [[ "${patch_status:-1}" -ne 0 ]]; then
  echo "ERROR: PATCH failed (exit code: $patch_status). Backup saved at: $backup_file" >&2
  exit 1
fi
```

**Implementation note for Claude**: `$updated_body` is the `comment_body` from Phase 3.5.1 with **only** the changes specified in Phase 3.5.2 applied. The `実装計画` section is inserted (or replaced if already present). All other sections must be copied verbatim from the re-fetched body. **Do NOT reconstruct the body from memory — use the re-fetched text as the base.** `$comment_body` is the same re-fetched body used for backup.

#### 3.5.4 Local Work Memory Sync

After updating the Issue comment, sync to the local work memory file:

```bash
WM_SOURCE="plan" \
  WM_PHASE="phase3" \
  WM_PHASE_DETAIL="実装計画生成" \
  WM_NEXT_ACTION="実装計画に沿って作業開始" \
  WM_BODY_TEXT="Implementation plan recorded." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**Notes**:
- By explicitly retrieving the comment ID, the correct comment can be updated even if other comments are added in between
- If the user selects "Skip", skip this phase and proceed to Phase 4

### 3.5.1 Mid-Implementation Replanning (Triggered by Bottleneck Detection)

> **Reference**: [Bottleneck Detection Reference](../../references/bottleneck-detection.md) for thresholds and Oracle discovery protocol.

This section is executed **during Phase 5.1** (not during Phase 3) when the bottleneck detection in [5.1.0.5](./implement.md) triggers step re-decomposition. It defines how re-decomposed sub-steps are integrated back into the implementation plan and work memory.

**Trigger**: Invoked from `implement.md` 5.1.0.5 step 5 (Bottleneck detection) when a threshold is exceeded and the step is re-decomposed into sub-steps.

#### Plan Update Procedure

1. **Replace original step**: In the dependency graph, mark the original step `S{n}` as `re-decomposed` and insert sub-steps `S{n}.1`, `S{n}.2`, etc.
2. **Update dependencies**: Any step that previously depended on `S{n}` now depends on the **last** sub-step (e.g., `S{n}.3` if decomposed into 3 sub-steps)
3. **Retain parallel groups**: Sub-steps with no inter-dependencies can be assigned the same parallel group

#### Work Memory Update

Update the "実装計画" section in work memory to reflect the re-decomposition. This is done at the next bulk update point (commit time) along with other work memory updates, to avoid excessive API calls.

**Updated plan format in work memory**:

```markdown
### 実装計画（更新済み）

| Step | 内容 | depends_on | 並列グループ | 状態 |
|------|------|------------|-------------|------|
| S1 | {step_1} | — | A | ✅ |
| S2 | {step_2} | — | A | ✅ |
| ~~S3~~ | ~~{original_step_3}~~ | S1 | B | ⚠️ 再分解 |
| S3.1 | {sub_step_1} | S1 | B' | ⬜ |
| S3.2 | {sub_step_2} | S3.1 | B' | ⬜ |
| S4 | {step_4} | S3.2 | C | 🔒 |
```

**Note**: The re-decomposition is also recorded in the "ボトルネック検出ログ" section (see [bottleneck-detection.md](../../references/bottleneck-detection.md#work-memory-recording-format)).

### 3.6 Issue Body Checklist Tracking

If the Issue body has a checklist, record and track it in the work memory.

#### 3.6.1 Checklist Extraction

Extract the checklist from the Issue body (`body`) obtained in Phase 0.1:

**Extraction pattern:**

```
パターン: /^- \[[ xX]\] (.+)$/gm
```

**Note**: Tasklist-format Issue references (`- [ ] #XX`) are used for parent-child Issue detection in Phase 0.3, so they are **excluded** here. Only pure task checklists without Issue references are targeted.

**Exclusion pattern:**

```
パターン: /^- \[[ xX]\] #\d+/gm  # Issue 参照は除外
```

**Extraction example:**

```markdown
## チェックリスト

- [ ] 現在の CLAUDE.md の内容を評価
- [ ] 不要な情報を削除
- [ ] 必要な情報を追加
- [x] Best Practices のフォーマットに準拠
```

The following are extracted from the above:
- `[ ] 現在の CLAUDE.md の内容を評価`
- `[ ] 不要な情報を削除`
- `[ ] 必要な情報を追加`
- `[x] Best Practices のフォーマットに準拠`

#### 3.6.2 Checklist Retention

Retain the extracted checklist in conversation context:

```json
{
  "issue_checklist": {
    "total": 4,
    "completed": 1,
    "items": [
      { "text": "現在の CLAUDE.md の内容を評価", "completed": false },
      { "text": "不要な情報を削除", "completed": false },
      { "text": "必要な情報を追加", "completed": false },
      { "text": "Best Practices のフォーマットに準拠", "completed": true }
    ]
  }
}
```

**Retention purpose:**

1. **Phase 5 implementation completion**: Reflect completion state of relevant tasks in Issue body
2. **PR creation**: Warning display for incomplete tasks
3. **Cleanup**: Confirmation of all tasks complete

#### 3.6.3 Record in Work Memory

If a checklist exists, record it in the "Issue checklist" section of the work memory:

```markdown
### Issue チェックリスト
<!-- Issue 本文のチェックリストを追跡 -->

| # | タスク | 状態 |
|---|--------|------|
| 1 | 現在の CLAUDE.md の内容を評価 | ⬜ |
| 2 | 不要な情報を削除 | ⬜ |
| 3 | 必要な情報を追加 | ⬜ |
| 4 | Best Practices のフォーマットに準拠 | ✅ |
```

**State notation:**
- `⬜`: Incomplete (`- [ ]` in Issue body)
- `✅`: Complete (`- [x]` in Issue body)

#### 3.6.4 When No Checklist Exists

If the Issue body has no checklist, skip this section and do not record in the work memory.
