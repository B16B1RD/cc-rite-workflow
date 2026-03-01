# Review Context Optimization

Optimization rules for handling large PRs in `/rite:pr:review`.

## Change Scale Determination

Check the change scale to determine the need for context optimization:

```bash
gh pr view {pr_number} --json additions,deletions,changedFiles --jq '{additions: .additions, deletions: .deletions, files: .changedFiles}'
```

**Scale determination table:**

| Scale | Condition | Diff Retrieval Method |
|------|------|--------------|
| Small | Total changed lines <= 500 AND file count <= 10 | Retrieve entire diff at once |
| Medium | Does not meet small-scale conditions, total changed lines <= 2000, file count <= 30 | After retrieving diff, each reviewer references their relevant file sections |
| Large | Total changed lines > 2000 OR file count > 30 (31 or more) | Retrieve only related file diffs per reviewer |

Conditions are evaluated top-down. `total_changes = additions + deletions`.

## Diff Retrieval by Scale

### Small Scale (Default)

Retrieve the PR diff in bulk:

```bash
gh pr diff {pr_number}
```

### Medium/Large Scale

Retrieve only the related file diffs per reviewer. First retrieve the changed file list:

```bash
gh pr view {pr_number} --json files --jq '.files[].path'
```

Then extract per-reviewer diffs in Phase 4.3.

## Context Pressure Detection

When a large diff is detected during the end-to-end flow (`/rite:issue:start`):

| State | Action |
|------|------|
| Context headroom available | Continue review as normal |
| Signs of context pressure | Automatically switch to per-file split mode |

**Signs of context pressure (OR evaluation, optimization applied if any one matches):**
- Tool calls exceed 50
- Read exceeds 5000 lines (or 10+ files)
- diff exceeds 2000 lines
- review-fix loop exceeds 3 cycles

Under pressure, apply optimization of passing only related diffs per reviewer.

## Diff Passing Optimization

Optimize diff passing based on scale:

| Scale | How to Pass Diff | Context Efficiency |
|------|--------------|-----------------|
| Small (<= 500 lines) | Pass entire diff to all reviewers | Normal |
| Medium (501-2000 lines) | Pass only related file diffs to each reviewer | Optimized |
| Large (> 2000 lines) | Pass only related file diffs + summary information to each reviewer | Significantly optimized |

### Determining Related Files (Medium/Large Scale)

Use file pattern analysis results from Phase 2.2 to narrow down the diff passed to each reviewer.

**Actual behavior:**
1. Retrieve the entire diff with `gh pr diff {pr_number}`
2. Extract diff sections for files matching each reviewer's Activation pattern
3. Pass only the extracted diff to each reviewer's Task

### Additional Optimization for Large Diffs

For diffs exceeding 2000 lines, pass the following information to each reviewer:

1. **Change summary**: Changed file list with additions/deletions per file
2. **Related file diffs**: Only diffs for files matching the pattern
3. **Detailed retrieval instructions**: Instruct to retrieve specific file details with the Read tool as needed

**`{change_summary}` format:**

```
### 変更概要（大規模 diff - {total_changes} 行）

| ファイル | 追加行 | 削除行 | 種別 |
|---------|--------|--------|------|
| {file_path} | +{additions} | -{deletions} | {file_type} |

**注**: コンテキスト最適化のため、あなたの専門領域に関連するファイルの diff のみを以下に含めています。
他のファイルの詳細が必要な場合は、Read ツールで該当ファイルを取得してください。
```

**`{file_type}` classification:** Determined from extension (`.md` -> Document, `.ts/.tsx` -> TypeScript, `.py` -> Python, etc.).

## Placeholder Embedding by Scale

`{diff_content}` embedding varies by scale:

| Scale | `{diff_content}` Content |
|------|------------------------|
| Small (<= 500 lines) | Embed entire diff as-is |
| Medium (501-2000 lines) | Embed only diffs for files matching `{relevant_files}` |
| Large (> 2000 lines) | Embed `{change_summary}` and diffs for files matching `{relevant_files}`, plus retrieval instructions |

**How `{relevant_files}` is determined:**

`{relevant_files}` is a different file list for each reviewer depending on their area of expertise. Only files matching the reviewer's Activation pattern are included.

**Example:** Security Expert receives files matching `**/auth/**`, Frontend Expert receives files matching `**/*.tsx`.

## Retrieval Guidelines for Large Diffs

Reviewers retrieve additional files with the Read tool in the following cases:
- When wanting to check the definition source of functions/classes referenced within the embedded diff
- When tracking dependencies from import statements
- When wanting to check details of files with many "additions" in the change summary table

**Path specification method**: The "File" column in the change summary table contains paths relative to the repository root (e.g., `plugins/rite/commands/pr/review.md`). For the Read tool, specify this path as-is or convert it to an absolute path from the working directory.
