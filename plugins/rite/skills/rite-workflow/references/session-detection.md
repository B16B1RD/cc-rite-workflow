# Session Detection Reference

Mechanism to automatically detect work state at session start and notify if interrupted work exists.

## Detection Flow

### 1. Branch Detection

```bash
git branch --show-current
```

### 2. Issue Number Extraction

Pattern: `{type}/issue-{number}-{slug}`

Example: `feat/issue-288-checkpoint-removal` → Issue #288

### 3. Work Memory Retrieval

```bash
# First, get {owner} and {repo} (execute before variable expansion):
gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'
# → {"owner":"B16B1RD","repo":"cc-rite-workflow"}

# Use the retrieved values to search for work memory:
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ"))'
```

### 4. Phase Information Extraction

Extract the following from the session information section:
- `コマンド`
- `フェーズ`
- `フェーズ詳細`
- `最終更新`

## Display Conditions

Display when ALL of the following conditions are met:

1. On a feature branch (`{type}/issue-{number}-*` pattern)
2. Work memory exists for the corresponding Issue
3. Phase information is recorded in the work memory
4. Phase is not `completed`

## Display Example

```
前回の作業状態が検出されました

Issue: #288 - checkpoint.json を廃止し Issue 作業メモリに統合
ブランチ: refactor/issue-288-checkpoint-removal
コマンド: rite:issue:start
フェーズ: phase5_implementation
フェーズ詳細: 実装作業中
最終更新: 2026-01-29T12:00:00+09:00

続行するには /rite:resume を実行してください。
```

## Prerequisites

- The `/rite:resume` command must be available (defined in [resume.md](../../commands/resume.md))

## Related

- [Phase Mapping](./phase-mapping.md) - Phase definitions
- [Work Memory Format](./work-memory-format.md) - Work memory format
