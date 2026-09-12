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

### 1.0 履歴形状の事前チェック（main が develop に含まれているか）

昇格 PR がマージコミット方式以外（squash / rebase）でマージされると、develop の各コミットが main の祖先にならない。以後の昇格 PR は前回リリースまでに出荷済みのコミットを差分として抱え込み、Phase 3.2 の検証はその中に merged PR の merge commit でないコミット（back-merge 等）が 1 つでもあると停止する。症状は次回以降のリリース終盤に出るが、原因は前回の昇格にある。バージョンバンプにも Issue 作成にも入る前にここで検査する。

健全な形は 2 つ。main の tip が develop の祖先である（back-merge 直後）か、main の tip がマージコミットでその第 2 親が develop の祖先である（マージコミット方式の昇格直後）か。どちらでもなければ乖離として停止する。ネットワーク不通で検査できない場合は、その旨を出して続行する（リリースをブロックしない）。

```bash
if ! git fetch origin main develop >/dev/null 2>&1; then
  echo "ℹ️ main / develop の同期に失敗しました（ネットワーク不通の可能性）。履歴形状の事前チェックは検査できませんでした。続行します。"
else
  main_tip=$(git rev-parse origin/main)
  if git merge-base --is-ancestor "$main_tip" origin/develop; then
    echo "[CONTEXT] RELEASE_ANCESTRY=ok; form=main-is-ancestor"
  elif git rev-parse -q --verify "${main_tip}^2" >/dev/null 2>&1 \
       && git merge-base --is-ancestor "${main_tip}^2" origin/develop; then
    echo "[CONTEXT] RELEASE_ANCESTRY=ok; form=merge-parent-is-ancestor"
  else
    main_only=$(git rev-list --count origin/develop..origin/main)
    echo "[CONTEXT] RELEASE_ANCESTRY=diverged; main_only_commits=$main_only"
  fi
fi
```

| `RELEASE_ANCESTRY` | アクション |
|---|---|
| `ok` | 1.1 へ進む |
| `diverged` | **停止する**。1.1 以降（バージョンバンプ・Issue 作成・PR 作成）へ進まない。下記の停止報告を出し、[復旧手順](#復旧手順-main-が-develop-の祖先でない場合) を提示する。復旧の実行はユーザーの明示指示を待つ |
| marker なし（fetch 失敗） | 検査できなかった旨は出力済み。1.1 へ進む |

停止報告:

```
## リリース停止: main が develop に含まれていません

main 側にしか無いコミット: {main_only_commits} 件（`git log origin/develop..origin/main --oneline`）

原因: 前回の昇格 PR がマージコミット方式以外（squash / rebase）でマージされた可能性があります。
このまま進めると Phase 3.2 の検証が出荷済みコミットを差分として拒否します。
復旧手順（本スキル末尾「復旧手順」節）を実行してから、リリースを最初からやり直してください。
```

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
  echo ""
  echo "PR → Issue 番号の対応:"
  errfile=$(mktemp)
  git log "${latest_tag}..develop" --format='%s' --no-merges | while IFS= read -r subj; do
    n=$(printf '%s\n' "$subj" | grep -oE '#[0-9]+' | tail -1 | tr -d '#')
    [ -n "$n" ] || { echo "- (番号なし) $subj"; continue; }
    : > "$errfile"
    if body=$(gh pr view "$n" --json body --jq '.body' 2>"$errfile"); then
      issue=$(printf '%s\n' "$body" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1)
      if [ -n "$issue" ]; then
        echo "- PR #$n → Issue #$issue"
      else
        echo "- PR #$n → 解決失敗（closing keyword なし）。Issue 番号を手動確認してください。PR 番号は使いません。"
      fi
    else
      errtxt=$(tr '\n' ' ' < "$errfile")
      case "$errtxt" in
        *"Could not resolve to a PullRequest"*)
          echo "- #$n → Issue #$n（PR として解決できないため Issue 番号として採用）"
          ;;
        *)
          echo "- #$n → 解決不能（gh エラー）。手動で確認してください。"
          ;;
      esac
    fi
  done
  rm -f "$errfile"
fi
```

対応表を目視し、CHANGELOG エントリの草案を作成して `AskUserQuestion` でユーザーに提示し、リリースを進めてよいか確認する。「解決失敗」「解決不能」の行は人間が Issue 番号を補う。PR 番号は書かない。

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

新規エントリに Issue/PR 番号トークンは書かない。変更は散文のみ。`git log` の末尾番号も転記しない。

#### CHANGELOG.md（英語）

既存の最新セクションの上に新セクションを挿入:

```markdown
## [{VERSION}] - {YYYY-MM-DD}

### Added

- {feature description}

### Fixed

- {fix description}

### Changed

- {change description}
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
gh pr merge {PREP_PR_NUMBER} --squash
```

prep PR は `--squash` でマージする。Phase 3.2 の `release-promotion-verify.sh` は、
前回リリース以降の develop の全 commit が squash commit であること（その SHA 自身を
`merge_commit_sha` とする merged PR を持つこと）を要求する。merge commit 方式だと
develop に載る実コミットがこの不変条件を満たさない。

GitHub UI から merge commit / rebase merge を選んでも同じ不変条件を破れる
（`allow_merge_commit` / `allow_rebase_merge` が有効な間）。本スキルはリポジトリの
マージ方式設定を変更しない。prep PR は必ず上記コマンドで squash すること。

マージ後、**Issue の Status を `Done` に更新する**。`Closes` キーワードで自動クローズされるが、されなければ手動でクローズ。

リリース準備ブランチと session worktree の削除は Phase 3.0 の `/rite:cleanup` に委ねる。
Phase 2.5 ではブランチ切替もブランチ削除も行わない。

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

昇格 PR は `--merge`（マージコミット方式）でマージする。GitHub UI から squash / rebase を選ぶと
develop の各コミットが main の祖先にならず、§1.0 の不変条件を破る。影響は今回ではなく
**次回以降のリリース**に現れ、§1.0 の事前チェックが停止する（復旧は本スキル末尾の復旧手順）。
prep PR が squash を必須とするのと対称に、昇格 PR は必ず上記コマンドでマージコミットにすること。
本スキルはリポジトリのマージ方式設定を変更しない。

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
| 7 | 昇格コミットがマージコミットである（次回の §1.0 が通過する） | `git rev-parse -q --verify origin/main^2` が SHA を返すこと |

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
| §1.0 の事前チェックで停止（main が develop に含まれない） | 前回の昇格が squash / rebase でマージされている。[復旧手順](#復旧手順-main-が-develop-の祖先でない場合) を実行してからリリースを最初からやり直す |
| 復旧手順 R.2 が `conflict` で停止 | back-merge が 3-way merge で衝突し、PR 経由でも取り込めない。R.2 の `conflict` 行の 2 択（検証条件の例外を別 Issue で契約する / 乖離を持ち越す）を人間が選ぶ。履歴は変更されていない |
| 復旧手順 R.2 が `already-contained` で停止 | ローカル develop が既に origin/main を含み、取り込むものが無い。R.2 の `already-contained` 行に従う。履歴は変更されていない |
| 復旧手順 R.2 が dry-run の取り消し失敗で停止（`ERROR: dry-run の merge を取り消せていません` を出し、`RECOVERY_DRYRUN` が出ていない） | dry-run の取り込みを取り消せず、MERGE_HEAD と merge 途中の index が残っている。`git merge --abort`（失敗する場合は `git reset --merge`）を手動で実行し、`git rev-parse -q --verify MERGE_HEAD` が失敗することを確かめてから R.2 をやり直す |
| 昇格コミットの PR 検証失敗 | 直接 push を取り除くか、対象 commit を通常 PR 経由で develop に取り込み直してから検証を再実行。差分に前回リリースまでの出荷済みコミットが含まれるなら原因は前回の昇格方式にあるので、§1.0 と復旧手順を参照 |
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

# main 側にしか無いコミット（件数は健全性の判定材料にならない。判定は下の §1.0 と同じ祖先チェックで行う）
git log origin/develop..origin/main --oneline
git merge-base --is-ancestor origin/main origin/develop \
  || git merge-base --is-ancestor origin/main^2 origin/develop \
  || echo "diverged: 復旧手順を参照"

# 既存の GitHub Release
gh release list --limit 5

# Issue の Projects ステータス確認
gh issue view {ISSUE_NUMBER} --json state,projectItems
```

---

## 復旧手順: main が develop の祖先でない場合

§1.0 が `diverged` で停止したときに使う。提示のみで自動実行しない。各ブロックはユーザーの明示指示を受けてから実行する。

**方式**: main → develop の PR をマージコミット方式で取り込む。develop へ back-merge コミットを直接 push しない。Phase 3.2 の検証は昇格差分の各コミットが merged PR の merge commit であることを要求するため、直接 push した back-merge コミットは次回の昇格で拒否される。PR 経由のマージコミットは、3-way merge が衝突しない場合に限りその条件を満たす（衝突時の帰結は R.2 の `conflict` 行）。

### R.1 事前検証（履歴を変更しない）

main のツリーが develop のいずれかのコミットのツリーと完全一致することを確認する。一致しなければ main 単独の内容がある可能性があり、自動手順では扱わない。範囲は develop にあって main に無いコミット（squash の元になったコミットはここに含まれる）。

```bash
git fetch origin main develop || exit 1
main_tree=$(git rev-parse "origin/main^{tree}")
if git log origin/main..origin/develop --format=%T | grep -qx "$main_tree"; then
  echo "[CONTEXT] RECOVERY_PRECHECK=ok; main_tree=$main_tree"
else
  echo "[CONTEXT] RECOVERY_PRECHECK=mismatch; main_tree=$main_tree"
fi
```

| `RECOVERY_PRECHECK` | アクション |
|---|---|
| `ok` | R.2 へ |
| `mismatch` | **履歴を変更せず停止する**。「main のツリーが develop のどのコミットとも一致しません。main 単独の内容がある可能性があるため人間の判断が必要です」と伝え、`git diff origin/develop origin/main --stat` を提示する |

### R.2 マージ結果の事前確認（ローカル dry-run）

復旧後の develop のツリーが復旧前と変わらないことを、push する前にローカルで確かめる。R.3 の GitHub マージと同じ 3-way merge を dry-run する。R.4 へは `RECOVERY_DRYRUN=ok` が出した `before_tree=` をリテラルで渡す。

squash 昇格後に develop 側でリリース範囲内の行を再編集していると、この 3-way merge は衝突する（merge-base が前回リリース前まで後退するため）。衝突は R.3 の PR でも同じく起きるので、衝突分岐は「停止して人間へ渡す」経路になる。

```bash
git checkout develop || exit 1
git pull origin develop || exit 1
before_head=$(git rev-parse develop)
before_tree=$(git rev-parse "develop^{tree}")
abort_error="dry-run の merge を取り消せていません。git merge --abort（失敗する場合は git reset --merge）を手動で実行し、git rev-parse -q --verify MERGE_HEAD が失敗することを確かめてから R.2 をやり直してください"
# 取り込み済みの merge は「Already up to date」で MERGE_HEAD を作らず、後段の取り消しが必ず失敗するため先に止める
if git merge-base --is-ancestor origin/main develop; then
  echo "[CONTEXT] RECOVERY_DRYRUN=already-contained; before_head=$before_head"
  exit 1
fi
if ! git merge --no-ff --no-commit origin/main; then
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    git merge --abort || { echo "ERROR: $abort_error" >&2; exit 1; }
  fi
  echo "[CONTEXT] RECOVERY_DRYRUN=conflict; before_head=$before_head; before_tree=$before_tree"
  exit 1
fi
merged_tree=$(git write-tree)
git merge --abort || { echo "ERROR: $abort_error" >&2; exit 1; }
# --no-commit の merge は HEAD を動かさないため、取り消しの成否は MERGE_HEAD の有無で確かめる
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "ERROR: $abort_error" >&2
  exit 1
fi
if [ "$merged_tree" = "$before_tree" ]; then
  echo "[CONTEXT] RECOVERY_DRYRUN=ok; before_head=$before_head; before_tree=$before_tree"
else
  echo "[CONTEXT] RECOVERY_DRYRUN=tree-changed; before_tree=$before_tree; merged_tree=$merged_tree"
fi
```

| `RECOVERY_DRYRUN` | アクション |
|---|---|
| `ok` | R.3 へ |
| `already-contained` | **履歴を変更せず停止する**。ローカル develop が既に origin/main を含んでいて、取り込むものが無い。`git merge-base --is-ancestor origin/main origin/develop` の成否で案内を分ける: (1) 失敗 → origin/develop は origin/main を含まず、origin/develop に無いローカルのコミット（未 push の back-merge 等）が含んでいる。origin 同士で比べる §1.0 の判定とずれている。`git log --first-parent origin/develop..develop --oneline` でそのコミットを確認し、残すか捨てるかを人間が決め、ローカル develop を origin/develop に揃えてから §1.0 からやり直す。(2) 成功 → origin/develop 自体が origin/main を含んでおり、R.3 までの復旧は済んでいる。`git log --first-parent origin/develop..develop --oneline` に出力があれば、R.4 の前にそのローカルにだけあるコミットの扱いを人間が決める（そのまま進むと Phase 1 の変更一覧と Phase 3.5 の push に混ざる）。R.4 を実行して `RECOVERY=ok` を確かめてからリリースを Phase 1 の最初からやり直す（`{BEFORE_TREE}` には R.3 の前に R.2 が `RECOVERY_DRYRUN=ok` で出した `before_tree=` を使う。`already-contained` の marker は `before_tree=` を持たない。この時点で取れるのは back-merge 後のツリーで、R.4 が自分自身との比較になるため。R.3 の前の値が手元に無ければ R.4 を実行せずに止まり、復旧でツリーが変わっていないことを検証できないと人間に伝える） |
| `tree-changed` | 停止し、`git diff "$before_tree" "$merged_tree" --stat` で変化する内容を提示する（履歴は変更していない） |
| `conflict` | **本手順では復旧できない**。R.3 の PR も同じ衝突で GitHub 上で unmergeable になる。R.1 が通っているので正しい合流結果は develop のツリーそのもの（`git merge -s ours origin/main` 相当）だが、そのコミットは GitHub の PR マージでは作れず、ローカルで作って PR 経由で取り込むと Phase 3.2 の検証（昇格差分の各コミットが merged PR の merge commit であること）が拒否する。develop は `$before_head` のまま変更していないことを伝え、次の 2 択を人間に提示して終了する: (1) 昇格ゲートの検証条件に「第 2 親が origin/main の tip であるマージコミット」だけを許す例外を設ける（検証条件の変更なので別 Issue の契約とする）、(2) 復旧を諦めて次回の昇格までこの乖離を持ち越す（その昇格は Phase 3.2 で必ず止まる） |

### R.3 back-merge PR の作成とマージ

```bash
gh pr create \
  --base develop \
  --head main \
  --title "chore: main を develop へ back-merge して昇格履歴の乖離を解消する" \
  --body "前回の昇格がマージコミット方式以外でマージされたため main が develop の祖先になっていない。マージコミット方式で取り込み、develop のツリーは変えない。"
```

作成された PR 番号を `{RECOVERY_PR_NUMBER}` として retain する。マージは merge gate（レビュー結果 JSON）を通るため `/rite:iterate {RECOVERY_PR_NUMBER}` で `[review:mergeable]` を得てから、**必ず `--merge`** でマージする（squash / rebase を選ぶと乖離が解消しない）:

```bash
gh pr merge {RECOVERY_PR_NUMBER} --merge
```

### R.4 復旧後の検証

`{BEFORE_TREE}` は R.3 の前に実行した R.2 の `RECOVERY_DRYRUN=ok` が出した `before_tree=` をリテラル置換する。その値が手元に無ければ本ブロックを実行せずに止まり、復旧でツリーが変わっていないことを検証できないと人間に伝える。

```bash
git fetch origin main develop || exit 1
after_tree=$(git rev-parse "origin/develop^{tree}")
if [ "$after_tree" != "{BEFORE_TREE}" ]; then
  echo "ERROR: 復旧後に develop のツリーが変化しました。復旧を成功として扱いません" >&2
  git diff "{BEFORE_TREE}" origin/develop --stat
  exit 1
fi
git merge-base --is-ancestor origin/main origin/develop \
  || { echo "ERROR: main が develop の祖先になっていません" >&2; exit 1; }
echo "[CONTEXT] RECOVERY=ok"
git checkout develop && git pull origin develop
```

`RECOVERY=ok` を確認したら、リリースを Phase 1 の最初からやり直す。
