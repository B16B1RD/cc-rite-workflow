# Session Detection Reference

Mechanism to automatically detect work state at session start and notify if interrupted work exists.

## Detection Flow

### 1. Branch Detection

```bash
git branch --show-current
```

### 2. Issue Number Extraction

Pattern: `{type}/issue-{number}-{slug}`

Example: `feat/issue-288-checkpoint-removal` → issue number `288`

### 3. Work Memory Retrieval

> `{plugin_root}` は [Plugin Path Resolution](../../../references/plugin-path-resolution.md) で解決する。

```bash
# First, get {owner} and {repo} (execute before variable expansion).
# SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback
# (canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}

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

Issue: - checkpoint.json を廃止し Issue 作業メモリに統合
ブランチ: refactor/issue-288-checkpoint-removal
コマンド: /rite:open
フェーズ: implement
フェーズ詳細: 実装作業中
最終更新: 2026-01-29T12:00:00+09:00

続行するには /rite:recover を実行してください。
```

## Prerequisites

- The `/rite:recover` command must be available (defined in [recover.md](../../../skills/recover/SKILL.md))

## Related

- [Phase Mapping](./phase-mapping.md) - Phase definitions
- [Work Memory Format](./work-memory-format.md) - Work memory format
