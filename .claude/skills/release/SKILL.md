---
name: release
description: |
  rite workflow のリリースを実行するスキル。バージョンバンプ（5ファイル）、
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

> **タグ同期（最新タグ判定の前に必須）**: リリースタグは Phase 3.3 で `--target main`（develop→main マージコミット）に付与されるため、develop からは到達不可能。`git describe --tags --abbrev=0` は HEAD から到達可能なタグしか返さず develop 上では古いタグを拾うため、最新タグの判定には使わない。最新タグは到達可能性に依存しないバージョン順（`git tag --sort=-v:refname`）で判定する。判定の前にリモートのタグをローカルへ同期しておく（ネットワーク不通でもリリースをブロックしない）。`--force` はリモートの正規リリースタグを真実の源とするため意図的に付与する（ローカル分岐タグが残ると最新タグ判定を誤るため。リリース運用でローカル専用のリリース形式タグを持つ現実的シナリオは無く blast radius は限定的）。fetch 失敗は silent にせず一言ログを出して続行する:
>
> ```bash
> if ! git fetch --tags --force origin >/dev/null 2>&1; then
>   echo "ℹ️ リモートのタグ同期に失敗しました（ネットワーク不通の可能性）。ローカルのタグで続行します。"
> fi
> ```

### 1.1 現在のバージョン確認

```bash
current_version=$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)
echo "Current version: $current_version"
```

### 1.2 リリースバージョンの決定

ユーザーがバージョンを指定していない場合、以下を確認して提案する：

1. 前回リリースからの変更を確認: `latest_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1); [ -n "$latest_tag" ] && git log "${latest_tag}..develop" --oneline`（最新タグはリリースタグ形式 `vX.Y.Z` に限定してバージョン順で取得。`grep` で非バージョンタグを除外し、version sort で上位に来る非リリースタグの誤検出を防ぐ。`git describe --tags --abbrev=0` は develop から到達不可能なリリースタグを取りこぼすため使わない）
2. 変更内容から semver のバンプ種別を判定:
   - **major**: 破壊的変更がある場合
   - **minor**: 新機能追加がある場合
   - **patch**: バグ修正のみの場合
3. `AskUserQuestion` ツールでユーザーに確認: `v{proposed_version} でリリースしますか？`

### 1.3 リリース内容のプレビュー

develop ブランチと最新タグの差分から、CHANGELOG に含めるべき変更を一覧表示する。

```bash
# 最新タグはリリースタグ形式 vX.Y.Z に限定してバージョン順で取得（HEAD 到達可能性に非依存）。
# grep で非バージョンタグ（refactor-pr3-done 等）を除外し、version sort で
# 上位に来る非リリースタグの誤検出を防ぐ。
# リリースタグは main マージコミットに付くため git describe では取りこぼす。
# 注: 末尾の head -1 が先頭行で pipe を閉じ上流（git tag / grep）が SIGPIPE を受け得るが、
# 終了コードは latest_tag 代入後の [ -n "$latest_tag" ] ガードで判定するため実害はない
# （本 skill は set -o pipefail 未使用。§1.2 の inline 版も同パターンで同様に benign）。
# 将来 set -o pipefail を導入する場合のみ、本 pipeline に対処（|| true や pipe 排除）が必要。
latest_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
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
branch="chore/issue-{ISSUE_NUMBER}-v{VERSION_SLUG}-release-prep"
ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' \
  | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac

if [ "$ms_enabled" = "true" ]; then
  # main checkout では branch を checkout しない。local ref を作ってから共通 helper に
  # session worktree への配置を委譲し、失敗時は develop 上で編集を始める前に停止する。
  git fetch origin develop || exit 1
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    git branch "$branch" origin/develop || exit 1
  fi
  ensure_out=$(bash plugins/rite/hooks/scripts/lib/worktree-git.sh \
    ensure-session-worktree --issue {ISSUE_NUMBER} --branch "$branch") || {
    printf '%s\n' "$ensure_out"
    echo "ERROR: リリース準備用 session worktree の作成に失敗しました" >&2
    exit 1
  }
  printf '%s\n' "$ensure_out"
  case "$ensure_out" in
    *"[CONTEXT] WT_ENSURE=reconstructed;"*|*"[CONTEXT] WT_ENSURE=reenter;"*) ;;
    *"[CONTEXT] WT_ENSURE=already_in;"*)
      [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ] || {
        echo "ERROR: session worktree の HEAD がリリース準備ブランチと一致しません" >&2
        exit 1
      } ;;
    *)
      echo "ERROR: session worktree を保証できないためリリース準備を停止します" >&2
      exit 1 ;;
  esac
else
  git checkout develop || exit 1
  git pull origin develop || exit 1
  git checkout -b "$branch"
fi
```

`{VERSION_SLUG}` はバージョン番号のドット(`.`)をハイフン(`-`)に置換（例: `0.3.0` → `0-3-0`）。

`multi_session=true` の場合は、上記出力の `[CONTEXT] WT_ENSURE=` を確認する。

- `reconstructed` / `reenter`: `path=` の session worktree に `EnterWorktree` で入場し、直後に下記の hard gate を実行する
- `already_in`: 現在の worktree で同じ branch を checkout 済みなので、そのまま Phase 2.3 へ進む
- `disabled`: 設定の再読込結果と矛盾するためエラーを表示して停止する
- `residue` / `branch_other_worktree` / `branch_absent` / `failed`: エラーを表示して停止する。**develop 上で Phase 2.3 以降を実行しない**

これにより分岐は Phase 2.2 だけに閉じ、入場後の Phase 2.3〜2.5 は `multi_session` の有効・無効にかかわらず同じ手順を使う。

`reconstructed` / `reenter` で入場したら、marker の `path=` を `{WORKTREE_PATH}` に置換して、cwd と HEAD の両方を機械検証する。不一致時は Phase 2.3 へ進まない。

```bash
expected_worktree="{WORKTREE_PATH}"
expected_branch="chore/issue-{ISSUE_NUMBER}-v{VERSION_SLUG}-release-prep"
[ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$expected_worktree" ] \
  && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$expected_branch" ] || {
  echo "ERROR: session worktree の cwd または HEAD がリリース準備ブランチと一致しません" >&2
  exit 1
}
```

### 2.3 バージョン番号の更新（5ファイル）

以下の全ファイルでバージョン番号を更新する。過去のリリースで更新漏れが発生した教訓があるため、1つも漏らさないこと。

| # | ファイル | 更新箇所 |
|---|---------|---------|
| 1 | `.claude-plugin/marketplace.json` | `"version": "{VERSION}"` |
| 2 | `plugins/rite/.claude-plugin/plugin.json` | `"version": "{VERSION}"` |
| 3 | `README.md` | バッジ URL 内のバージョン表記（`version-{VERSION}-blue` と `tag/v{VERSION}` の2箇所） |
| 4 | `README.ja.md` | バッジ URL 内のバージョン表記（`version-{VERSION}-blue` と `tag/v{VERSION}` の2箇所） |
| 5 | `docs/SPEC.md` | JSON 例の `"version": "{VERSION}"` |

**検証**: 更新後に漏れがないか確認する:

```bash
grep -rn "{OLD_VERSION}" .claude-plugin/ plugins/rite/.claude-plugin/ README.md README.ja.md docs/SPEC.md
```

出力が空であれば OK。

### 2.4 CHANGELOG 更新（2ファイル）

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 形式で、英語版と日本語版を更新する。

エントリは機能名レベルで記述し、「従来の挙動」「以前の方式」のような基準点が新規読者に不明な暗黙の歴史依存表現を避ける（修正対象の旧挙動を述べる場合も変更対象のキー・機能名を明示する）。詳細は CHANGELOG.md / CHANGELOG.ja.md 冒頭の「歴史依存表現の取扱方針」注記を参照。

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
git add .claude-plugin/marketplace.json \
  plugins/rite/.claude-plugin/plugin.json \
  README.md README.ja.md docs/SPEC.md CHANGELOG.md CHANGELOG.ja.md
git status --short --untracked-files=no
expected_staged=$(printf '%s\n' \
  .claude-plugin/marketplace.json plugins/rite/.claude-plugin/plugin.json \
  README.md README.ja.md docs/SPEC.md CHANGELOG.md CHANGELOG.ja.md | sort)
actual_staged=$(git diff --cached --name-only | sort)
if [ "$actual_staged" != "$expected_staged" ]; then
  echo "ERROR: release staging が期待する7ファイルと一致しません" >&2
  exit 1
fi
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

`/rite:iterate {PREP_PR_NUMBER}` を実行し、`[review:mergeable]` を確認する。レビューが
収束しない場合はマージせず停止する。その後、`AskUserQuestion` でユーザーに PR を確認して
マージしてよいか確認し、承認後にマージ:

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

### 3.0 session worktree から退出

Phase 2 で `/rite:iterate` を経由した場合、セッションは session worktree 内にいる。Phase 3 は
main checkout 上で `develop` / `main` を操作するため、最初に現在地を判定する。

```bash
current_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 1
case "$common_dir" in /*) ;; *) common_dir="$current_root/$common_dir" ;; esac
main_root=$(cd "$(dirname "$common_dir")" && pwd -P) || exit 1
if [ "$current_root" = "$main_root" ]; then
  echo "[CONTEXT] RELEASE_PHASE3_EXIT=noop; main_root=$main_root"
else
  echo "[CONTEXT] RELEASE_PHASE3_EXIT=required; worktree=$current_root; main_root=$main_root"
fi
```

- `RELEASE_PHASE3_EXIT=noop`: すでに main checkout にいるため、そのまま Phase 3.1 へ進む
- `RELEASE_PHASE3_EXIT=required`: `ExitWorktree` ツールを **`action: "keep"`** で呼び出す。`remove` は使わない。リリース準備 branch と `.rite/worktrees/issue-{N}` の削除は `/rite:cleanup` に委ねる

退出後は、別の Bash 呼び出しで main checkout に戻ったことを検証する。不一致なら Phase 3.1 へ進まない。

```bash
current_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 1
case "$common_dir" in /*) ;; *) common_dir="$current_root/$common_dir" ;; esac
main_root=$(cd "$(dirname "$common_dir")" && pwd -P) || exit 1
[ "$current_root" = "$main_root" ] || {
  echo "ERROR: main checkout への退出を確認できないため Phase 3 を停止します" >&2
  exit 1
}
```

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

昇格 PR の全コミットが既にマージ済み PR 経由であることを検証する。helper は PR が
`develop -> main` であることも確認し、merge gate 用のアテステーションを保存する:

```bash
VERIFIED_HEAD_OID=$(bash plugins/rite/hooks/release-promotion-verify.sh {RELEASE_PR_NUMBER})
```

検証失敗時は fail-loud で停止する。成功後、`AskUserQuestion` でユーザーに main へのマージを
確認し、承認後に、出力された SHA を下記の `{VERIFIED_HEAD_OID}` に**リテラル置換**してマージする
（変数形式のまま実行しない）:

```bash
gh pr merge {RELEASE_PR_NUMBER} --merge --match-head-commit {VERIFIED_HEAD_OID}
```

#### 3.2.1 Decision Log

昇格マージは base/head の形状だけでは許可しない。`release-promotion-verify.sh` が差分内の
各 commit SHA について、同じ SHA を merge commit とする既マージ PR の存在を検証し、検証時の
head SHA をアテステーションへ記録する。merge gate はそのアテステーションと
`--match-head-commit` の SHA が一致するときだけレビュー結果 JSON の代替として扱う。
GitHub API が返したコミット件数は PR metadata の総コミット数と照合し、API 上限等で完全な一覧を
取得できない場合はアテステーションを作らず停止する。

この方式により、通常の実装 PR は従来どおり review-results JSON が必須のまま、直接 push を含む
昇格と検証後に head が変わった昇格は `merge-release-promotion-unverified` で fail-loud に停止する。
単なる `base=main` / `head=develop` 判定は、未レビュー commit を区別できないため採用しない。

### 3.3 タグ作成 + GitHub Release

main が最新であることを確認してから実行:

```bash
git checkout main
git pull origin main
```

CHANGELOG.md から該当バージョンのセクションを抽出してリリースノートに使用:

```bash
release_notes=$(mktemp) || exit 1
sed -n '/^## \[{VERSION}\]/,/^## \[/{ /^## \[{VERSION}\]/d; /^## \[/d; p; }' \
  CHANGELOG.md > "$release_notes" || exit 1
echo "[CONTEXT] RELEASE_NOTES_PATH=$release_notes"
```

スクラッチファイルを指定して Release を作成する。プロセス置換は使用しない。

```bash
gh release create "v{VERSION}" \
  --title "v{VERSION}" \
  --notes-file "{RELEASE_NOTES_PATH}" \
  --target main
```

`{RELEASE_NOTES_PATH}` は直前の `[CONTEXT] RELEASE_NOTES_PATH=` marker の値へリテラル置換する。
Release 作成後にそのスクラッチファイルを削除する。

```bash
rm -f "{RELEASE_NOTES_PATH}"
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
| 昇格コミットの PR 検証失敗 | 直接 push を取り除くか、対象 commit を通常 PR 経由で develop に取り込み直してから検証を再実行 |
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
