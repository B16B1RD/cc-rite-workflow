---
name: release
description: |
  rite workflow のリリースを実行するスキル。バージョンバンプ（6ファイル）、
  CHANGELOG 更新（英語・日本語）、develop→main マージ PR、タグ作成、
  GitHub Release 作成までを一気通貫で行う。
  「リリース」「release」「バージョンアップ」「version bump」「CHANGELOG」
  「タグ作成」「GitHub Release」といったキーワードで発動する。
  リリース作業を行いたいとき、新しいバージョンを公開したいときに使うこと。
---

# Rite Workflow Release

rite workflow のリリースを4フェーズで実行する。各フェーズでユーザーの確認を挟みながら進める。

**ユーザーへの質問は必ず `AskUserQuestion` ツールを使うこと。** テキスト出力で質問して応答を待つのではなく、AskUserQuestion で明示的に入力を求める。これにより、ユーザーが何を求められているか明確になり、ワークフローの中断ポイントがはっきりする。

---

## GitHub Projects 連携の共通手順

リリースで作成する Issue は GitHub Projects に登録し、処理状態に応じてステータスを遷移させる。

**ステータス遷移**: `Todo` → `In Progress` → `In Review` → `Done`

### Projects 設定の取得

`rite-config.yml` から `github.projects` セクションの `project_number` と `owner` を読み取る。

### Issue の Projects 登録 + ステータス設定

```bash
# 1. Issue を Projects に登録
gh project item-add {PROJECT_NUMBER} --owner {OWNER} --url {ISSUE_URL} --format json

# 2. Projects メタデータ取得（Project ID, Status Field ID, Option IDs）
STATUS_FIELD_ID=$(gh project field-list {PROJECT_NUMBER} --owner {OWNER} --format json \
  --jq '.fields[] | select(.name=="Status") | .id')

# Status Option ID を取得（必要なもの）
TODO_OPTION_ID=$(gh project field-list {PROJECT_NUMBER} --owner {OWNER} --format json \
  --jq '.fields[] | select(.name=="Status") | .options[] | select(.name=="Todo") | .id')

# 3. Item ID を取得（--limit を十分大きくすること）
ITEM_ID=$(gh project item-list {PROJECT_NUMBER} --owner {OWNER} --limit 200 --format json \
  --jq '.items[] | select(.content.number=={ISSUE_NUMBER}) | .id')

# 4. Project ID を取得
PROJECT_ID=$(gh project list --owner {OWNER} --format json \
  --jq '.projects[] | select(.number=={PROJECT_NUMBER}) | .id')

# 5. ステータスを設定
gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" \
  --field-id "$STATUS_FIELD_ID" --single-select-option-id "$TODO_OPTION_ID"
```

### ステータス更新

登録済み Issue のステータス変更は、手順 3〜5 を繰り返し、Option ID を目的のステータスに変更する。

---

## Phase 1: リリース情報の確認

### 1.1 現在のバージョン確認

```bash
current_version=$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)
echo "Current version: $current_version"
```

### 1.2 リリースバージョンの決定

ユーザーがバージョンを指定していない場合、以下を確認して提案する：

1. `git log $(git describe --tags --abbrev=0)..develop --oneline` で前回リリースからの変更を確認
2. 変更内容から semver のバンプ種別を判定:
   - **major**: 破壊的変更がある場合
   - **minor**: 新機能追加がある場合
   - **patch**: バグ修正のみの場合
3. `AskUserQuestion` ツールでユーザーに確認: `v{proposed_version} でリリースしますか？`

### 1.3 リリース内容のプレビュー

develop ブランチと最新タグの差分から、CHANGELOG に含めるべき変更を一覧表示する。

```bash
latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$latest_tag" ]; then
  git log "${latest_tag}..develop" --oneline --no-merges
fi
```

関連する Issue/PR 番号も `gh` で確認し、CHANGELOG エントリの草案を作成して `AskUserQuestion` でユーザーに提示し、リリースを進めてよいか確認する。

---

## Phase 2: リリース準備（バージョンバンプ + CHANGELOG 更新）

### 2.1 リリース準備 Issue の作成

```
タイトル: v{VERSION} リリース準備（バージョンバンプ + CHANGELOG 更新）
ラベル: chore
```

`gh issue create` で Issue を作成し、**GitHub Projects に登録して Status を `Todo` に設定する**。

### 2.2 ブランチ作成

ブランチ作成前に、**Issue の Status を `In Progress` に更新する**。

```bash
git checkout develop
git pull origin develop
git checkout -b chore/issue-{ISSUE_NUMBER}-v{VERSION_SLUG}-release-prep
```

`{VERSION_SLUG}` はバージョン番号のドット(`.`)をハイフン(`-`)に置換（例: `0.3.0` → `0-3-0`）。

### 2.3 バージョン番号の更新（6ファイル）

以下の全ファイルでバージョン番号を更新する。過去のリリースで更新漏れが発生した教訓があるため、1つも漏らさないこと。

| # | ファイル | 更新箇所 |
|---|---------|---------|
| 1 | `.claude-plugin/marketplace.json` | `"version": "{VERSION}"` |
| 2 | `plugins/rite/.claude-plugin/plugin.json` | `"version": "{VERSION}"` |
| 3 | `README.md` | バッジ URL 内のバージョン表記（`version-{VERSION}-blue` と `tag/v{VERSION}` の2箇所） |
| 4 | `README.ja.md` | 同上 |
| 5 | `docs/SPEC.md` | JSON 例の `"version": "{VERSION}"` |
| 6 | `docs/SPEC.ja.md` | JSON 例の `"version": "{VERSION}"` |

**検証**: 更新後に漏れがないか確認する:

```bash
grep -rn "{OLD_VERSION}" .claude-plugin/ plugins/rite/.claude-plugin/ README.md README.ja.md docs/SPEC.md docs/SPEC.ja.md
```

出力が空であれば OK。

### 2.4 CHANGELOG 更新（2ファイル）

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 形式で、英語版と日本語版を更新する。

#### CHANGELOG.md（英語）

既存の最新セクションの上に新セクションを挿入:

```markdown
## [{VERSION}] - {YYYY-MM-DD}

### Added

- {feature description} (#{issue_number})

### Fixed

- {fix description} (#{issue_number})

### Changed

- {change description} (#{issue_number})
```

カテゴリ（Added/Fixed/Changed/Removed）は該当するもののみ。ファイル末尾の比較リンクも追加:

```markdown
[{VERSION}]: https://github.com/B16B1RD/cc-rite-workflow/compare/v{PREV_VERSION}...v{VERSION}
```

#### CHANGELOG.ja.md（日本語）

同じ構造で日本語版も更新。カテゴリ名は `追加` / `修正` / `変更` / `削除`。

### 2.5 コミット・PR 作成・マージ

```bash
git add -A
git commit -m "chore: v{VERSION} バージョンバンプ + CHANGELOG 更新"
git push -u origin HEAD
```

develop に向けて PR を作成し、**Issue の Status を `In Review` に更新する**:

```bash
gh pr create \
  --base develop \
  --title "chore: v{VERSION} バージョンバンプ + CHANGELOG 更新" \
  --body "Closes #{PREP_ISSUE_NUMBER}"
```

`AskUserQuestion` でユーザーに PR を確認してマージしてよいか確認し、承認後にマージ:

```bash
gh pr merge --merge
```

マージ後、**Issue の Status を `Done` に更新する**。`Closes` キーワードで自動クローズされるが、されなければ手動でクローズ。

**ブランチ削除**: マージ後、不要になったリリース準備ブランチをローカルとリモートから削除する:

```bash
# develop に切り替え
git checkout develop
git pull origin develop

# リリース準備ブランチを削除
git branch -d chore/issue-{ISSUE_NUMBER}-v{VERSION_SLUG}-release-prep
git push origin --delete chore/issue-{ISSUE_NUMBER}-v{VERSION_SLUG}-release-prep 2>/dev/null || true
```

---

## Phase 3: リリース実行（develop → main マージ + GitHub Release）

Phase 2 の PR が develop にマージされた後に実行する。

### 3.1 リリース実行 Issue の作成

```
タイトル: v{VERSION} リリース（develop→main マージ、タグ作成、GitHub Release）
ラベル: chore
```

`gh issue create` で Issue を作成し、**GitHub Projects に登録して Status を `Todo` に設定する**。

### 3.2 develop → main マージ PR

**必ずタグ作成・GitHub Release 作成の前に行う。** v0.2.2 で main マージを忘れたまま GitHub Release を作成し、後から修正が必要になった教訓がある。順序を間違えると、Release のタグが main の古いコミットを指してしまう。

**Issue の Status を `In Progress` に更新する。**

```bash
git checkout develop
git pull origin develop
```

PR を作成し、**Issue の Status を `In Review` に更新する**:

```bash
gh pr create \
  --base main \
  --head develop \
  --title "release: v{VERSION}" \
  --body "Merge develop into main for v{VERSION} release. Closes #{RELEASE_ISSUE_NUMBER}"
```

`AskUserQuestion` でユーザーに main へのマージを確認し、承認後にマージ:

```bash
gh pr merge --merge
```

### 3.3 タグ作成 + GitHub Release

main が最新であることを確認してから実行:

```bash
git checkout main
git pull origin main
```

CHANGELOG.md から該当バージョンのセクションを抽出してリリースノートに使用:

```bash
gh release create "v{VERSION}" \
  --title "v{VERSION}" \
  --notes-file <(sed -n '/^## \[{VERSION}\]/,/^## \[/{ /^## \[{VERSION}\]/d; /^## \[/d; p; }' CHANGELOG.md) \
  --target main
```

### 3.4 リリース実行 Issue のクローズ

**Issue の Status を `Done` に更新する。** PR マージで自動クローズされなければ手動でクローズ。

### 3.5 develop ブランチの復旧・同期

GitHub のリポジトリ設定で「マージ後にブランチを自動削除」が有効な場合、develop→main の PR マージで develop ブランチがリモートから削除される。ローカルの develop を再プッシュして復旧すること。

```bash
git checkout develop

# リモートに develop が存在するか確認
if ! git ls-remote --exit-code origin develop &>/dev/null; then
  echo "develop branch was auto-deleted on remote, re-pushing..."
  git push origin develop
fi

git pull origin develop
```

---

## Phase 4: リリース後の確認

### 4.1 検証チェックリスト

| # | 確認項目 | コマンド |
|---|---------|---------|
| 1 | GitHub Release が公開されている | `gh release view v{VERSION}` |
| 2 | main に最新コードが反映されている | `git log main --oneline -1` |
| 3 | タグが正しいコミットを指している | `git log v{VERSION} --oneline -1` |
| 4 | 両 Issue がクローズされている | `gh issue view {PREP_ISSUE} --json state && gh issue view {RELEASE_ISSUE} --json state` |
| 5 | 両 Issue の Projects Status が Done | `gh issue view {PREP_ISSUE} --json projectItems && gh issue view {RELEASE_ISSUE} --json projectItems` |
| 6 | リリース準備ブランチが削除されている | `git branch --list 'chore/issue-*-release-prep'` が空であること |

### 4.2 結果報告

```
[release:success] v{VERSION} released successfully
- GitHub Release: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v{VERSION}
- Issues closed: #{PREP_ISSUE_NUMBER}, #{RELEASE_ISSUE_NUMBER}
```

---

## エラーハンドリング

| 状況 | 対応 |
|------|------|
| バージョン番号の更新漏れ | grep で検出し、追加コミットで修正 |
| CHANGELOG の形式不備 | 既存エントリのパターンに合わせて修正 |
| main マージ前に Release を作成してしまった | Release を削除 → main マージ → Release 再作成 |
| PR マージ衝突 | 衝突を解消してから再試行 |
| Projects 登録失敗 | `gh project item-add` を再実行。`--limit` を増やして Item ID を再取得 |
| ステータス更新失敗 | Field ID / Option ID を再取得して `gh project item-edit` を再実行 |

## 中断時の再開

どのフェーズで中断しても、以下で状態を確認して再開できる:

```bash
# 現在のバージョン
jq -r '.plugins[0].version' .claude-plugin/marketplace.json

# リリース関連の open Issue
gh issue list --search "リリース" --state open

# main と develop の差分
git log main..develop --oneline

# 既存の GitHub Release
gh release list --limit 5

# Issue の Projects ステータス確認
gh issue view {ISSUE_NUMBER} --json state,projectItems
```
