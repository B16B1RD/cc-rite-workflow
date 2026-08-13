---
name: template-reset
description: |
  rite workflow のテンプレート再生成ヘルパー: rite-config / Issue / PR / review / GitHub テンプレートを
  再生成する。ユーザーが明示的に /rite:template-reset で起動する。auto-activate しない。
  起動: /rite:template-reset [target]
argument-hint: "[target]"
---

# /rite:template-reset

テンプレートを再生成する。次の Phase を順に実行する。

## Arguments

| Argument | Description |
|------|------|
| `github` | `.github/` の Issue / PR テンプレート一式を `templates/github/` から再生成 |
| `--force` | Skip template overwrite confirmation (does not apply to rite-config.yml regeneration confirmation) |

`github` 指定時は検出・上書き確認・生成・完了報告を Phase 3.1.0 の GitHub テンプレートに限定する。無指定は既存の全テンプレートフロー。

`github` ターゲットの Phase 2 は 2 択のみ: `GitHubテンプレート4ファイルをすべて上書き` / `キャンセル`。結果は `github_reset_set=all|none`。`--force` は `all`。部分選択は出さない。`all` のときだけ Phase 3.1.0 へ。
rationale: references/rationale.md#github-target-scope

---

## Phase 1: Configuration Check

### 1.1 Read rite-config.yml

Read configuration from the project root or `.claude/` directory:

```bash
# 設定ファイルの存在確認
ls rite-config.yml .claude/rite-config.yml 2>/dev/null
```

If the configuration file does not exist:

```
rite-config.yml が見つかりません

テンプレートを生成するには先に /rite:setup を実行してください

オプション:
- /rite:setup を実行
- キャンセル
```

## Phase 2: Check Existing Templates

### 2.1 Detect Existing Files

Check the following files and directories:

```bash
# Issue テンプレート
ls -la .github/ISSUE_TEMPLATE/ 2>/dev/null

# PR テンプレート
ls -la .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null

# 設定ファイル
ls -la rite-config.yml 2>/dev/null
```

### 2.2 Overwrite Confirmation (skipped when --force is specified)

If existing files are found, confirm with `AskUserQuestion`:

```
以下の既存ファイルが見つかりました:

| ファイル | 最終更新 |
|---------|---------|
| .github/ISSUE_TEMPLATE/bug_report.md | 2025-01-01 |
| .github/PULL_REQUEST_TEMPLATE.md | 2025-01-01 |

どのファイルを再生成しますか？

オプション:
- すべて上書き
- Issue テンプレートのみ
- PR テンプレートのみ
- キャンセル
```

If `--force` is specified, skip the confirmation and overwrite all.

---

## Phase 3: Template Generation

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before reading any bundled template. Do not duplicate bundled template contents in this skill.

### 3.0 Directory Preparation

Create necessary directories before generating templates:

```bash
# .github ディレクトリを作成（存在しない場合）
mkdir -p .github

# Issue テンプレート用ディレクトリを作成
mkdir -p .github/ISSUE_TEMPLATE
```

rationale: references/rationale.md#mkdir-order

---

### 3.1 Generate Issue Templates

#### 3.1.0 Generate GitHub Templates (`github` target)

When the target is `github`, use `{plugin_root}/templates/github/` as the single source of truth and regenerate exactly these files:

| Source | Destination |
|--------|-------------|
| `{plugin_root}/templates/github/ISSUE_TEMPLATE/bug_report.md` | `.github/ISSUE_TEMPLATE/bug_report.md` |
| `{plugin_root}/templates/github/ISSUE_TEMPLATE/feature_request.md` | `.github/ISSUE_TEMPLATE/feature_request.md` |
| `{plugin_root}/templates/github/ISSUE_TEMPLATE/config.yml` | `.github/ISSUE_TEMPLATE/config.yml` |
| `{plugin_root}/templates/github/PULL_REQUEST_TEMPLATE.md` | `.github/PULL_REQUEST_TEMPLATE.md` |

各 source をそのまま destination へ書く。既存ファイルの上書きは Phase 2 確認後、または `--force`。source 欠落・読めない場合は WARNING してその destination は触らず、残りを続行し skip を報告する。

書込前に project root を canonicalize し、`.github` または `.github/ISSUE_TEMPLATE` が symlink なら GitHub reset 全体を拒否する。`github` ターゲットは汎用 Phase 3.0 を skip し、guard 成功後に 3.1.0 内だけで親ディレクトリを作る。destination が symlink、または canonical parent が project root 外ならその 1 件を拒否。write loop に入れるのは `github_reset_set=all` のみ。source を destination ディレクトリの tempfile へ完全コピーし、symlink / canonical-parent を再検査してから `mv temp destination`。コピー未完了時は tempfile を消し旧 destination を残す。失敗は WARNING-only で次へ。
rationale: references/rationale.md#approved-replacement

4 ファイル処理後は Phase 3.1（legacy Issue）/ 3.2 / 3.3 を skip して Phase 4 へ。
rationale: references/rationale.md#github-target-scope

Generate the following template files:

#### Default Issue Template

Reference `templates/issue/default.md` to generate `.github/ISSUE_TEMPLATE/task.md`:

```markdown
---
name: Task
about: General task or feature request
title: ''
labels: ''
assignees: ''
---

## Overview

<!-- Brief description of the task -->

## Background

<!-- Why is this needed? What problem does it solve? -->

## Acceptance Criteria

- [ ]

## Technical Notes

<!-- Any technical considerations, constraints, or implementation hints -->

## Related

<!-- Links to related issues, PRs, or documentation -->

---
🤖 Generated with [rite workflow](https://github.com/B16B1RD/cc-rite-workflow)
```

#### Bug Report Template

Generate `.github/ISSUE_TEMPLATE/bug_report.md`:

```markdown
---
name: Bug Report
about: Report a bug or unexpected behavior
title: '[Bug] '
labels: bug
assignees: ''
---

## Description

<!-- Clear description of the bug -->

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

<!-- What should happen -->

## Actual Behavior

<!-- What actually happens -->

## Environment

- OS:
- Version:

## Additional Context

<!-- Screenshots, logs, or other relevant information -->

---
🤖 Generated with [rite workflow](https://github.com/B16B1RD/cc-rite-workflow)
```

### 3.2 Generate PR Template

**Steps:**

1. Load the template file `templates/pr/generic.md`
2. Write as `.github/PULL_REQUEST_TEMPLATE.md`

```bash
# Read ツールでテンプレートを読み込み
# Write ツールで .github/PULL_REQUEST_TEMPLATE.md を生成
```

**If existing file exists:** Overwrite only if selected in Phase 2.

### 3.3 Regenerate Configuration File (optional)

Regenerate `rite-config.yml` only if the user selects to do so:

```
rite-config.yml も再生成しますか？

既存の設定（Projects 連携など）が失われます
バックアップは自動的に作成されます

オプション:
- はい、再生成する
- いいえ、スキップ（推奨）
```

**Steps for regeneration:**

1. Back up the existing `rite-config.yml`:
   ```bash
   # バックアップファイル名: rite-config.yml.backup.{timestamp}
   # 例: rite-config.yml.backup.2026-01-04T12-00-00
   cp rite-config.yml "rite-config.yml.backup.$(date +%Y-%m-%dT%H-%M-%S)"
   ```

2. Reference `templates/config/rite-config.yml` to generate the default configuration

3. Include the backup file path in the completion report

---

## Phase 4: Completion Report

### 4.1 Display Generation Results

For the `github` target, list the four GitHub template destinations above with their actual status (`作成`, `更新`, or `スキップ`) instead of the legacy example below.

```
テンプレートを再生成しました

## 生成されたファイル

| ファイル | 状態 |
|---------|------|
| .github/ISSUE_TEMPLATE/task.md | 作成 |
| .github/ISSUE_TEMPLATE/bug_report.md | 作成 |
| .github/PULL_REQUEST_TEMPLATE.md | 更新 |

## バックアップ（該当する場合）

| 元ファイル | バックアップ |
|-----------|-------------|
| rite-config.yml | rite-config.yml.backup.{timestamp} |

## 次のステップ

1. 生成されたテンプレートを確認
2. 必要に応じてカスタマイズ
3. 変更をコミット
```

**Note:** The backup section is only displayed when rite-config.yml was regenerated.

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Write Permission Is Missing | See [common patterns](../../references/common-error-handling.md) |
| When Template Source Is Not Found | See [common patterns](../../references/common-error-handling.md) |
