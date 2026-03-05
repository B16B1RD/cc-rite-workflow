# Completion Report (Phase 5.6)

> **Source**: Extracted from `start.md` Phase 5.6. This file is the source of truth for the completion report procedure.

Execute the following steps **in order**. Do NOT skip any step. Always base your output on the template file read in Step 1 (or the inline fallback below if the Read tool fails).

**Step 1 — Read template** (MANDATORY):

Use the Read tool to read `{plugin_root}/templates/completion-report.md`. Select the appropriate section:
- PR created → **"一気通貫フロー完了時のフォーマット（Phase 5.6 用）"** section
- PR not created → **"PR 未作成時のフォーマット（エッジケース）"** section

If the Read tool fails, proceed to Step 2 using the inline fallback below instead.

**Step 2 — Substitute placeholders**:

Using the template content you just read in Step 1, replace **only** `{...}` placeholders with actual values. Do NOT alter table structure, headings, row order, or add/remove any rows.

| Placeholder | Value Source |
|-------------|-------------|
| `{number}`, `{title}` | Issue info from Phase 0.1 |
| `{owner}`, `{repo}` | Repository info from pre-Phase 0.1 |
| `{pr_number}` | PR number from Phase 5.3 |
| `{pr_state}` | Draft / Ready for Review / Merged |
| `{status}` | Current Projects Status |
| `{score}` | Quality score from Phase 1.1 |
| `{branch_name}` | Branch from Phase 2.1 |
| `{changed_files_count}` | `git diff --name-only origin/{base_branch}...HEAD \| wc -l` (`{base_branch}` = PR base ref from Phase 2.1, e.g. `develop`) |
| `{review_result}` | Review assessment from Phase 5.4 |

**Step 3 — Output**:

Output the substituted template as your response. First determine which case applies, then verify the output matches **all three required sections** for that case:

**Case A — PR was created** (normal case, `{pr_number}` is set):
1. **項目テーブル** (7 rows: Issue, Issue URL, PR, PR URL, PR 状態, 関連 Issue, Status)
2. **フェーズ進捗テーブル** (6 rows: Issue 分析, ブランチ作成, 実装, 品質チェック, PR 作成, セルフレビュー — all ✅)
3. **次のステップ** (3 items, using the content from the template read in Step 1)

**Case B — PR was NOT created** (edge case, no `{pr_number}`):
1. **項目テーブル** (5 rows: Issue, Issue URL, PR, ブランチ, Status)
2. **フェーズ進捗テーブル** (6 rows: completed phases ✅, incomplete phases ⏳)
3. **次のステップ** (3 items, using the content from the template read in Step 1)

**Step 4 — Self-verification**:

After outputting, verify your output matches the case determined in Step 3:

For **Case A** (PR created):
- [ ] `## 完了報告` heading
- [ ] 項目テーブル with exactly **7** data rows
- [ ] `### フェーズ進捗` heading with exactly 6 data rows
- [ ] `### 次のステップ` heading with exactly 3 numbered items

For **Case B** (PR not created):
- [ ] `## 完了報告` heading
- [ ] 項目テーブル with exactly **5** data rows
- [ ] `### フェーズ進捗` heading with exactly 6 data rows (with ⏳ for incomplete phases)
- [ ] `### 次のステップ` heading with exactly 3 numbered items

If any check fails, re-read the template and regenerate.

**MUST NOT**: Omit any template rows, merge fields into a single line, invent fields not in the template, or change the table format (e.g., no ASCII box-drawing).

---

**Inline fallbacks** (use ONLY if Read tool fails on the template file). Select the matching case:

**Case A fallback — PR created**:

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | #{pr_number} |
| PR URL | https://github.com/{owner}/{repo}/pull/{pr_number} |
| PR 状態 | {pr_state} |
| 関連 Issue | #{number} |
| Status | {status} |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ✅ | lint 通過 |
| PR 作成 | ✅ | #{pr_number} |
| セルフレビュー | ✅ | {review_result} |

### 次のステップ

1. レビュアーに PR レビューを依頼
2. レビューコメントに対応
3. PR マージ後、Issue は自動クローズ
```

**Case B fallback — PR not created**:

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | 未作成 |
| ブランチ | {branch_name} |
| Status | In Progress |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ⏳ | 未実施 |
| PR 作成 | ⏳ | - |
| セルフレビュー | ⏳ | - |

### 次のステップ

1. `/rite:pr:create` で PR を作成
2. `/rite:pr:review` でセルフレビュー
3. レビュアーに PR レビューを依頼
```

See template "エッジケース対応表" for other edge cases.
