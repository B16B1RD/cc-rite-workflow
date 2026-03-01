# 完了報告フォーマット定義

このファイルは `/rite:issue:start` の完了報告フォーマットを一元管理する。
Phase 4.1（作業開始）と Phase 5.6（一気通貫フロー完了）の両方で、このファイルを読み込んでフォーマットを参照する。

---

## フォーマット使用時の注意（必読）

> **絶対厳守**: 以下のテンプレートを**そのまま使用**すること
>
> - 独自のフォーマットや創作は**禁止**
> - テーブル構造と見出しを正確に再現すること
> - プレースホルダ `{...}` の部分のみを実際の値で置換すること

---

## 作業開始時のフォーマット（Phase 4.1 用）

Phase 2 のブランチ作成・準備が完了した後に使用する。

```markdown
## 作業開始

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| ブランチ | {branch_name} |
| Status | In Progress |
| Iteration | {iteration_title} |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ⏳ | - |
| 品質チェック | ⏳ | - |
| PR 作成 | ⏳ | - |
| セルフレビュー | ⏳ | - |

作業メモリを初期化しました。
```

**注意:**
- Iteration 行は `iteration.enabled: true` の場合のみ表示（無効時は行ごと省略）

---

## 一気通貫フロー完了時のフォーマット（Phase 5.6 用）

Phase 5 の実装 → lint → PR 作成 → レビューが完了した後に使用する。

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

---

## PR 未作成時のフォーマット（エッジケース）

Phase 5 が途中で中断された場合など、PR が作成されていない状態で完了報告を行う場合。

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

---

## プレースホルダ一覧

| プレースホルダ | 説明 | 取得方法 |
|---------------|------|----------|
| `{number}` | Issue 番号 | コマンド引数から取得 |
| `{title}` | Issue タイトル | `gh issue view --json title` |
| `{owner}` | リポジトリオーナー | `gh repo view --json owner` |
| `{repo}` | リポジトリ名 | `gh repo view --json name` |
| `{branch_name}` | 作成したブランチ名 | Phase 2.3 で作成 |
| `{iteration_title}` | Iteration 名 | Phase 2.5 で取得 |
| `{score}` | 品質スコア（A/B/C/D） | Phase 1.1 で判定 |
| `{pr_number}` | PR 番号 | Phase 5.3 で作成 |
| `{pr_state}` | PR 状態（Draft / Ready for Review / Merged） | `gh pr view --json isDraft,state` |
| `{status}` | Projects Status（In Progress / In Review / Done） | Projects API |
| `{changed_files_count}` | 変更ファイル数 | `git diff --stat` |
| `{review_result}` | レビュー結果（マージ可 / 要修正） | Phase 5.4 の結果 |

---

## エッジケース対応表

| ケース | 対応 |
|--------|------|
| PR 未作成 | 「PR 未作成時のフォーマット」を使用 |
| PR がマージ済み | PR 状態を「Merged」と表示し、次のステップに `/rite:pr:cleanup` を案内 |
| レビュー未実施 | セルフレビュー行の状態を「⏳ 保留」、備考を「未実施」と表示 |
| lint スキップ | 品質チェック行の備考を「lint スキップ」と表示 |
| Iteration 無効 | Iteration 行を省略（行ごと削除） |
