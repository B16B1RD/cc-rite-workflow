---
description: Issue に作業メモリコメントを初期化
---

# Work Memory Initialization Module

This module handles the initialization of work memory — both local file (SoT) and Issue comment (backup replica).

**Placeholder legend:**
- `{issue_number}`: Issue number (from caller argument)
- `{owner}`, `{repo}`: Repository information (from caller context or `gh repo view --json owner,name`)
- `{plugin_root}`: Plugin root directory. Resolve per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing any bash code blocks in this module.

## Phase 2.6: Work Memory Initialization

> **⚠️ 注意**: 作業メモリは Issue のコメントとして公開されます。公開リポジトリでは第三者に閲覧可能です。機密情報（認証情報、個人情報、内部 URL 等）を作業メモリに記録しないでください。

### 2.6.1 Local Work Memory File (SoT)

Create the local work memory file via `local-wm-update.sh` (handles directory creation, locking, and atomic write):

```bash
WM_SOURCE="init" \
  WM_PHASE="phase2" \
  WM_PHASE_DETAIL="ブランチ作成・準備" \
  WM_NEXT_ACTION="実装計画を生成" \
  WM_BODY_TEXT="Work memory initialized. Issue #{issue_number} の作業を開始しました。" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh
```

**Placeholder value:**
- `{issue_number}`: Issue number from argument (the only value LLM must substitute)

### 2.6.2 Issue Comment (Backup Replica)

Add a work memory comment to the Issue as a backup. The script handles template generation, comment creation, post-creation validation, and comment ID caching in `.rite-flow-state`:

```bash
bash {plugin_root}/hooks/issue-comment-wm-sync.sh init \
  --issue {issue_number} \
  --branch "{branch_name}" \
  2>/dev/null || true
```

**On failure**: The script outputs `WARNING` on stderr and exits 0 (non-blocking). The work memory will be rebuilt in subsequent phases (Phase 3.5, Phase 5.5.2) which re-fetch and validate before updating.

Timestamp format: `YYYY-MM-DDTHH:MM:SS+09:00` (ISO 8601)

**Progress summary state notation:**

| State | Notation |
|-------|----------|
| Not started | ⬜ 未着手 |
| In progress | 🔄 進行中 |
| Completed | ✅ 完了 |

**Purpose of confirmation items:**

Accumulate confirmation items that arise during work (design decisions, specification confirmations, review request items, etc.). Follow the "consolidation of confirmation items" rule in SKILL.md and request confirmation collectively at session end.

---

## Defense-in-Depth: Flow State Update (Before Return)

> **Reference**: This pattern follows `start.md`'s sub-skill defense-in-depth model (e.g., `lint.md` Phase 4.0, `review.md` Phase 8.0).

Before returning control to the caller, update `.rite-flow-state` to the post-work-memory phase. This ensures the stop-guard routes correctly even if the caller's 🚨 Mandatory After section is not executed immediately:

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase2_post_work_memory" \
  --next "rite:issue:work-memory-init completed. Proceed to Phase 3 (implementation plan). Do NOT stop." \
  --if-exists
```

After the flow-state update above, output the result pattern:

- **Work memory initialized**: `[work-memory:initialized]`

This pattern is consumed by the orchestrator (`start.md`) to determine the next action.

---

## 🚨 Caller Return Protocol

When this sub-skill completes, control **MUST** return to the caller (`start.md`). The caller **MUST immediately** execute its 🚨 Mandatory After 2.6 section:

1. Proceed to Phase 3 (implementation plan)

**→ Return to `start.md` and proceed to Phase 3 now. Do NOT stop.**
