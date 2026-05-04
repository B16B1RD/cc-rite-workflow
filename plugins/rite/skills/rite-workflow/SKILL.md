---
name: rite-workflow
description: |
  Automates the complete Issue-to-PR lifecycle: create new Issues,
  start working on Issues, create branches, implement changes, run
  quality checks, and manage PRs — all through a single workflow.
  Essential for any /rite: command, workflow questions, or when
  working with Issues, branches, commits, or PRs.
  Activates on "create issue", "new issue", "起票", "Issue を作成",
  "タスクを登録", "Issue 化", "新規 Issue", "start issue", "create PR",
  "next steps", "workflow", "rite", "Issue作業", "ブランチ",
  "コミット規約", "PR作成", "作業開始", "ワークフロー", "次のステップ".
  Use for workflow state detection, phase transitions, and command
  suggestions.
---

# Rite Workflow Skill

This skill provides context for rite workflow operations.

## Auto-Activation Keywords

- Issue, PR, Pull Request
- workflow, rite
- branch, commit
- GitHub Projects
- review, lint
- recall, 決定事項検索, コンテキスト, なぜ

## Context

When activated, this skill provides:

1. **Workflow Awareness**
   - Current branch and associated Issue
   - Work memory state
   - Status in GitHub Projects

2. **Command Guidance**
   - Suggest appropriate commands
   - Remind about work memory updates
   - Guide through workflow steps

3. **Best Practices**
   - Conventional Commits format
   - Branch naming conventions
   - PR template usage

4. **Coding Principles**
   - Avoid common AI coding failure patterns
   - See [references/coding-principles.md](./references/coding-principles.md) for details

5. **Common Principles**
   - Reduce excessive AskUserQuestion usage
   - See [references/common-principles.md](./references/common-principles.md) for details

6. **Comment Best Practices**
   - WHY > WHAT, no journal comments, no line/cycle number references, jargon whitelist enforcement
   - See [references/comment-best-practices.md](./references/comment-best-practices.md) for details

## Workflow Identity (品質 > 時間/context)

rite workflow の identity は「定義された step を全て実行し、生成物の品質を担保する」ことである。**時間的制約や context 残量を理由にした step の省略は禁止**。残量の推論も禁止。context が実際に枯渇した場合の正規経路は `/clear` + `/rite:resume` の組合せであり、LLM が自己判断でワークフローを短縮する経路は存在しない。

**さらに、workflow は途中で止まらない。そして最後のわけのわからない出力で終わらない。** sub-skill の return tag (`[interview:completed]` / `[create:completed:{N}]` 等) は **turn 境界ではなく継続トリガ** である。ユーザー介入 (`continue` 入力) を要求せずに、同 turn 内で次 phase へ進む。また、ワークフロー完了時の user-visible な最終行は sentinel marker ではなく「✅ Issue #{N} を作成しました: {url}」のような人間可読な完了メッセージで終わる。sentinel marker は hook/grep 契約のため出力は保持するが、HTML コメント化等で user-visible な末端に孤立させない。

| 禁止事項 | 正規経路 |
|---------|---------|
| 「時間が足りないので X を省略します」 | 手順どおり実行 |
| 「context が圧迫しているので要約します」 | 手順どおり実行 |
| 「残量が不安なので review を切り上げます」 | `/clear` + `/rite:resume` をユーザーに案内 |
| return tag 直後に turn を閉じる | 同 turn 内で次 phase に継続 (stop-guard + HTML コメント化 sentinel により機械的に enforcement) |
| sentinel marker `[create:completed:{N}]` を user-visible な最終行として残す | HTML コメント `<!-- [create:completed:{N}] -->` として末尾に配置し、user-visible な最終行は `✅ ...` 完了メッセージにする |

詳細と Anti-pattern / Correct Pattern は [references/workflow-identity.md](./references/workflow-identity.md) を参照。各 command (start / review / fix / ready / lint / cleanup / create / resume 等) からも同 reference を引いている。

## Workflow State Detection

Detect current state from:
- Branch name pattern: `{type}/issue-{number}-*`
  - `{type}` values: `feat`, `fix`, `docs`, `refactor`, `chore`, `style`, `test`
  - `style` is used for code style/formatting changes (no logic changes)
- Git status
- Open PRs

## Suggested Actions

| State | Suggestion |
|-------|------------|
| On main/develop, no Issue | `/rite:issue:create` or `/rite:issue:list` |
| On feature branch, no PR | `/rite:pr:create` after work |
| PR open, draft | `/rite:pr:review` then `/rite:pr:ready` |
| Long session (30+ minutes elapsed) | `/rite:issue:update` |
| Sprint with Todo Issues available | `/rite:sprint:execute` to run Issues sequentially |
| Sprint with multiple independent Issues | `/rite:sprint:team-execute` to run Issues in parallel with worktrees |
| Want to recall past decisions or context | `/rite:issue:recall` or `/rite:issue:recall {scope}` |

## Question Management

> **Key Principle**: Always apply `question_self_check` (see [references/common-principles.md](./references/common-principles.md)) before asking questions. Most questions can be avoided through context inference and using sensible defaults.

### When Questions Are Necessary

Ask immediately (do not defer) when:
- **Blockers**: Issues that prevent further progress
- **Security-related**: Decisions affecting security
- **Destructive operations**: Actions that cannot be undone
- **External impacts**: Changes affecting users or external systems

### Work Memory Integration

If questions arise during work, record them in the work memory comment under "要確認事項" (Items to Confirm):

```markdown
### 要確認事項

1. [ ] {confirmation_item_1}
2. [ ] {confirmation_item_2}
```

### Expected Question Frequency

**Target**: Minimize questions through context inference and sensible defaults. Issue Start: 0-1 (score C/D only), Implementation: 0, PR Review: 0-1 (critical decisions only). Record non-blocking questions in work memory.

See [references/common-principles.md](./references/common-principles.md) for detailed frequency table by phase.

## Session Start Auto-Detection

Automatically detect work state at session start and notify if interrupted work exists.

See [references/session-detection.md](./references/session-detection.md) for details.

### Quick Reference

1. Extract Issue number from branch name (`{type}/issue-{number}-*` pattern)
2. Fetch work memory comment from the Issue
3. Extract and display phase information

See [references/phase-mapping.md](./references/phase-mapping.md) for phase list.

See [references/work-memory-format.md](./references/work-memory-format.md) for work memory format.

## Sub-skill Return Auto-Continuation Contract

When an orchestrator command (e.g., `/rite:issue:start`, `/rite:issue:create`) invokes a sub-skill via the Skill tool, the LLM **MUST** continue in the same response turn after the sub-skill returns. The return tag is a continuation trigger, not a turn boundary — stopping prematurely abandons the workflow before the terminal completion marker is output.

See [references/sub-skill-return-protocol.md](./references/sub-skill-return-protocol.md) for the full contract, anti-pattern / correct-pattern examples, and the three defense-in-depth layers (prompt / flow-state / caller-continuation hint). The canonical specification lives in `docs/SPEC.md` "Sub-skill Return Auto-Continuation Contract" section.

## AI Coding Principles (Summary)

Avoid common AI coding failure patterns: surface assumptions, manage confusion, push back when warranted, enforce simplicity, maintain scope discipline, clean dead code, plan inline, address all discovered issues, and keep documentation in sync with specification changes (`documentation_consistency`) — when the implementation changes user-visible behavior, update related README / docs / CLAUDE.md / plugin .md files in the same PR rather than deferring to a follow-up Issue.

See [references/coding-principles.md](./references/coding-principles.md) for the full principle list and details.

## Simplification Charter (rite plugin maintenance)

`plugins/rite/` 配下のファイルを編集する LLM・メンテナ、および rite workflow が生成する commit message / Issue body / PR description / review 指摘は、自己生成的に肥大化しないよう **Simplification Charter** に従う。runtime に効かない経緯記述は書かない / git log で代替できるものはコードに書かない / `Issue #` / `PR #` / `cycle #` の本文引用は禁止 / 重複 confirmation 禁止。

See [references/simplification-charter.md](./references/simplification-charter.md) for the 5 self-questions, prohibited patterns, and recommended patterns.

## Common Principles (AskUserQuestion Reduction)

Reduce excessive questions: self-check necessity, use defaults when available, infer from context.

See [references/common-principles.md](./references/common-principles.md) for details.

## Preflight Guard (All Commands)

Before executing any `/rite:*` command, run the preflight guard. Resolve `{plugin_root}` per [references/plugin-path-resolution.md](../../references/plugin-path-resolution.md#resolution-script-full-version).

```bash
bash {plugin_root}/hooks/preflight-check.sh --command-id "{current_command_id}" --cwd "$(pwd)"
```

Replace `{current_command_id}` with the slash command being executed (e.g., `/rite:lint`, `/rite:pr:review`).

If exit code is `1` (blocked), stop execution and display the preflight output. Do NOT proceed.

## gh CLI Safety Rules

All `gh` commands that accept `--body` or `--comment` parameters **MUST** use safe patterns to avoid shell injection:

- Use `--body-file` with `mktemp` for multi-line content
- Reference: See `references/gh-cli-patterns.md` for detailed safe patterns

**Never** pass user-generated content directly via `--body` or `--comment` flags.

## Workflow Incident Detection (#366)

The rite workflow auto-detects **workflow blockers** (Skill load failure, hook abnormal exit, manual fallback adoption) during `/rite:issue:start` end-to-end execution and registers them as Issues to prevent silent loss.

**Architecture**:
1. Each skill (`rite:lint`, `rite:pr:fix`, `rite:pr:review`) emits a sentinel via `plugins/rite/hooks/workflow-incident-emit.sh` when an internal failure path is taken.
2. The orchestrator (`/rite:issue:start` Phase 5.4.4.1) detects sentinels via context grep, presents `AskUserQuestion` for confirmation, and calls `create-issue-with-projects.sh` to register the incident with `Status: Todo / Priority: High / Complexity: S`.
3. Same-session duplicate types are suppressed (1 incident per type per session).
4. Failure to register is non-blocking — the workflow continues regardless.

**Configuration** (default-on):

```yaml
workflow_incident:
  enabled: true              # set to false to disable detection entirely
```

**Sentinel format** (`root_cause_hint` is optional and entirely omitted when empty):

```
[CONTEXT] WORKFLOW_INCIDENT=1; type=<type>; details=<details>; (root_cause_hint=<hint>; )?iteration_id=<pr>-<epoch>
```

See `docs/SPEC.md` "Workflow Incident Detection" section for the full specification, including AC mapping and Phase 7 non-interference guarantees.

## Integration

This skill works with:
- All `/rite:*` commands
- GitHub CLI operations
- Git operations
