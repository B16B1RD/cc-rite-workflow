---
description: Issue に作業メモリコメントを初期化
---

# Work Memory Initialization Module

This module handles the initialization of work memory — both local file (SoT) and Issue comment (backup replica).

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

Add a work memory comment to the Issue as a backup:

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'EOF' > "$tmpfile"
## 📜 rite 作業メモリ

### セッション情報
- **Issue**: #{issue_number}
- **開始**: {timestamp}
- **ブランチ**: {branch_name}
- **最終更新**: {timestamp}
- **コマンド**: rite:issue:start
- **フェーズ**: phase2
- **フェーズ詳細**: ブランチ作成・準備

### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ⬜ 未着手 | - |
| テスト | ⬜ 未着手 | - |
| ドキュメント | ⬜ 未着手 | - |

### 要確認事項
<!-- 作業中に発生した確認事項を蓄積。セッション終了時にまとめて確認 -->
_確認事項はありません_

### 変更ファイル
<!-- 自動更新 -->
_まだ変更はありません_

### 決定事項・メモ
<!-- 重要な判断や発見 -->

### 計画逸脱ログ
<!-- 実装中に計画から逸脱した場合に記録 -->
_計画逸脱はありません_

### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->
_ボトルネック検出はありません_

### レビュー対応履歴
<!-- レビュー対応時に自動記録 -->
_レビュー対応はありません_

### 次のステップ
1. Issue の内容を確認
2. 実装を開始
EOF

gh issue comment {issue_number} --body-file "$tmpfile"
```

#### 2.6.3 Post-Creation Validation

Verify the created comment has the expected structure. This catches silent failures where `gh issue comment` succeeds but the content is truncated or corrupted:

```bash
# Retrieve the last work memory comment and validate structure
# Note: GitHub API has eventual consistency — the comment may not appear immediately after creation.
# A brief delay (1-2 seconds) or a single retry is acceptable if the initial fetch returns empty.
created_body=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body // empty')

if [ -z "$created_body" ]; then
  echo "WARNING: 作業メモリコメントの作成を確認できません。後続フェーズで再作成される可能性があります。" >&2
else
  session_count=$(echo "$created_body" | grep -c '### セッション情報' || true)
  progress_count=$(echo "$created_body" | grep -c '### 進捗サマリー' || true)
  if [ "$session_count" -eq 0 ]; then
    echo "WARNING: 作業メモリコメントの構造が不完全です（セッション情報セクション欠落）。" >&2
  elif [ "$progress_count" -eq 0 ]; then
    echo "WARNING: 作業メモリコメントの構造が不完全です（進捗サマリーセクション欠落）。" >&2
  fi
fi
```

**On validation failure**: Display the warning and continue (non-blocking). The work memory will be rebuilt in subsequent phases (Phase 3.5, Phase 5.5.2) which re-fetch and validate before updating. Note that `created_body` being empty immediately after creation may be caused by GitHub API eventual consistency rather than an actual failure — this is expected behavior and the warning is intentionally non-blocking.

Timestamp format: `YYYY-MM-DDTHH:MM:SS+09:00` (ISO 8601)

**Progress summary state notation:**

| State | Notation |
|-------|----------|
| Not started | ⬜ 未着手 |
| In progress | 🔄 進行中 |
| Completed | ✅ 完了 |

**Purpose of confirmation items:**

Accumulate confirmation items that arise during work (design decisions, specification confirmations, review request items, etc.). Follow the "consolidation of confirmation items" rule in SKILL.md and request confirmation collectively at session end.
