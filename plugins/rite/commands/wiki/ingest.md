---
description: Wiki Ingest — Raw Source から経験則を抽出・統合し Wiki ページを更新
---

# /rite:wiki:ingest

Wiki Ingest エンジン。`.rite/wiki/raw/` に蓄積された Raw Source を読解し、`.rite/wiki/pages/` 配下に経験則を統合します。新規ページの作成、既存ページの更新、`index.md` の自動更新、`log.md` への活動記録、基本的な矛盾チェックを行います。

> **Reference**: [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造、ブランチ管理、テンプレート展開の共通パターン
> **Reference**: [Plugin Path Resolution](../../references/plugin-path-resolution.md) — `{plugin_root}` の解決手順

**Arguments** (オプショナル):

| 引数 | 説明 |
|------|------|
| `<raw-file-path>` | 単一の Raw Source ファイルを指定して Ingest（省略時は `.rite/wiki/raw/` 配下の `ingested: false` 全ファイルを処理） |

**Examples**:

```
/rite:wiki:ingest
/rite:wiki:ingest .rite/wiki/raw/reviews/20260413T...md
```

---

## Phase 1: 事前チェック

### 1.1 Wiki 設定の読み取り

`rite-config.yml` から Wiki 設定を読み取ります。`init.md` Phase 1.1 と同じ判定パターンを使用してください:

```bash
wiki_enabled=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+enabled:' | head -1 | sed 's/#.*//' \
  | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]')
wiki_enabled=$(echo "$wiki_enabled" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  true|yes|1) wiki_enabled="true" ;;
  *) wiki_enabled="false" ;;
esac
echo "wiki_enabled=$wiki_enabled"
```

**Wiki が無効の場合**: 早期 return:

```
Wiki 機能が無効です（wiki.enabled: false）。
有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki:init を実行してください。
```

### 1.2 ブランチ戦略と Wiki 初期化判定

`init.md` Phase 1.2 と同じ手順で `branch_strategy` と `wiki_branch` を取得し、Wiki が初期化済みかを判定します:

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"

branch_strategy=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_strategy:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_strategy:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
branch_strategy="${branch_strategy:-separate_branch}"

echo "branch_strategy=$branch_strategy"
echo "wiki_branch=$wiki_branch"

if [ "$branch_strategy" = "separate_branch" ]; then
  if git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
     git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
else
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
  fi
fi
```

**Wiki 未初期化の場合**: 早期 return:

```
Wiki が初期化されていません。先に /rite:wiki:init を実行してください。
```

**変数保持指示**: Phase 1.2 で出力された `branch_strategy` と `wiki_branch` の値を保持し、以降のすべての Bash ブロックで**リテラル値として埋め込んで**使用してください。Claude Code の Bash ツール間でシェル変数は保持されません。

### 1.3 Plugin Root の解決

> **Reference**: [Plugin Path Resolution](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files)

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

以降のすべての Bash ブロックで `plugin_root` をリテラル値として埋め込んで使用してください。

---

## Phase 2: Raw Source の解決

### 2.1 引数の判定

引数 `<raw-file-path>` が指定されている場合は、その単一ファイルのみを Ingest 対象とします。指定がない場合は `.rite/wiki/raw/` 配下から `ingested: false` を持つ Raw Source ファイルを **すべて** 列挙します。

### 2.2 separate_branch 戦略時のブランチ切り替え

`separate_branch` 戦略では、Raw Source は wiki ブランチに保存されています。一方、`wiki-ingest-trigger.sh` は呼び出された時点のブランチ (= 通常は開発ブランチ) のワークツリーに書き込むため、Ingest 時には:

1. 開発ブランチ側の `.rite/wiki/raw/` に新規ファイルがあるか確認
2. ある場合: それらを wiki ブランチに移送する必要がある
3. wiki ブランチに切り替えて、Raw Source を読み込み・統合

このため、Ingest コマンドは「開発ブランチでステージングされた Raw Source を wiki ブランチに反映する」役割も担います。

> **Reference**: [Wiki ブランチへの書き込み（Ingest 時）](../../references/wiki-patterns.md#wiki-ブランチへの書き込みingest-時) — `current_branch` 退避、stash、cleanup trap、復帰

具体的な手順は Phase 5 (書き込み) に集約します。Phase 2 ではどのブランチに対象 Raw Source が存在するかを把握するため、両ブランチを参照できるようにします。

```bash
# Phase 1.2 の値をリテラルで埋め込む
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

# 候補リストを作成（開発ブランチ側 + wiki ブランチ側）
candidates=()
if [ -d ".rite/wiki/raw" ]; then
  while IFS= read -r f; do candidates+=("$f"); done < <(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null)
fi

# separate_branch の場合、wiki ブランチ側の未 ingest ファイルも候補に加える
if [ "$branch_strategy" = "separate_branch" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && candidates+=("wiki:${f}")
  done < <(git ls-tree -r --name-only "$wiki_branch" 2>/dev/null | grep -E '^\.rite/wiki/raw/.*\.md$' || true)
fi

printf 'Found %d candidate raw source(s)\n' "${#candidates[@]}"
for c in "${candidates[@]}"; do echo "  - $c"; done
```

### 2.3 Ingested フラグの判定

各候補ファイルの YAML frontmatter から `ingested:` を読み、`false` のものだけを処理対象とします。`wiki-ingest-trigger.sh` が生成するファイルは初期値 `ingested: false` を持つため、これが Ingest 待ちのマーカーになります。

引数で単一ファイルが指定されている場合は、`ingested:` の値にかかわらず処理対象とします（再 Ingest を許可）。

**ファイル本体の取得方法**:

| 場所 | 取得コマンド |
|------|-------------|
| 開発ブランチのワークツリー | Read ツールで直接読み取り |
| wiki ブランチ (`wiki:` プレフィックス) | `git show "${wiki_branch}:${path}"` で取得 |

**処理対象が0件の場合**: 早期 return:

```
未 Ingest の Raw Source は見つかりませんでした。
新しい経験則を蓄積するには /rite:pr:review や /rite:pr:fix の完了後に再実行してください。
```

---

## Phase 3: 既存 Wiki インデックスの読み込み

統合判定（新規ページ作成 vs 既存ページ更新）のため、現在の `index.md` を読み込みます。

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  index_content=$(git show "${wiki_branch}:.rite/wiki/index.md" 2>/dev/null) || index_content=""
else
  index_content=$(cat .rite/wiki/index.md 2>/dev/null) || index_content=""
fi

if [ -z "$index_content" ]; then
  echo "WARNING: index.md is empty or unreachable. Treating all pages as new." >&2
fi
```

LLM はこの `index_content` を読み、既存ページのタイトル一覧、ドメイン分布、最終更新日を把握します。

---

## Phase 4: LLM による読解と統合判定

Phase 2.3 で確定した処理対象 Raw Source 1件ずつに対して、LLM が以下を行います:

1. **読解**: Raw Source 本文を読み、抽出可能な経験則を特定
2. **ドメイン判定**: 経験則を `patterns` / `heuristics` / `anti-patterns` のどれに分類するか決定
3. **既存ページとの照合**: `index.md` に同テーマの既存ページが存在するか判定
4. **アクション決定**:

| 判定 | アクション |
|------|----------|
| 同テーマの既存ページなし | 新規ページ作成 |
| 同テーマの既存ページあり | 既存ページ更新（追記 or 統合） |
| 経験則が抽出できない（一時的な情報のみ） | スキップ（理由を log に記録） |

**注意**: 既存ページとの「同テーマ」判定は厳密一致ではなく意味的な近さで行います。LLM は `index.md` の一行サマリーとタイトルから判断します。

### 4.1 タイトル/ドメイン/サマリーの生成

新規ページを作成する場合、LLM は以下を生成します:

| フィールド | ガイドライン |
|-----------|-------------|
| `title` | 経験則を1行で表現（30-60字推奨） |
| `domain` | `patterns` / `heuristics` / `anti-patterns` |
| `summary` | 1-2 文での要約（index.md に掲載される） |
| `details` | 背景、具体例、根拠を含む詳細説明 |
| `confidence` | `high` / `medium` / `low`（根拠の強さ） |

ファイル名は `pages/{domain}/{slug}.md` とし、`slug` は `title` を kebab-case に正規化したもの（最大60文字）を使用します。

### 4.2 既存ページ更新時の統合方針

既存ページを更新する場合、LLM は次の方針で統合します:

- **追記**: 既存内容と矛盾せず補強する場合は「## 詳細」セクションに追記
- **統合**: 一部矛盾するが新情報の方が確度が高い場合は該当箇所を書き換え（`updated` フィールド更新）
- **`sources` 配列追記**: 新しい Raw Source への参照を必ず追加
- **`updated` 更新**: `updated` を現在の ISO 8601 タイムスタンプに更新

---

## Phase 5: ページの書き込み

Phase 4 で決定したアクション（新規 or 更新）を、ブランチ戦略に応じて適用します。

### 5.1 separate_branch 戦略

> **Reference**: [Wiki ブランチへの書き込み（Ingest 時）](../../references/wiki-patterns.md#wiki-ブランチへの書き込みingest-時) のテンプレートに従う

```bash
# Phase 1.2 の値をリテラルで埋め込む
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  current_branch=$(git branch --show-current)

  # cleanup trap (canonical signal-specific pattern)
  _rite_wiki_ingest_cleanup() {
    git checkout "$current_branch" 2>/dev/null || true
    if [ "${stash_needed:-false}" = true ]; then
      git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
    fi
  }
  trap 'rc=$?; _rite_wiki_ingest_cleanup; exit $rc' EXIT
  trap '_rite_wiki_ingest_cleanup; exit 130' INT
  trap '_rite_wiki_ingest_cleanup; exit 143' TERM
  trap '_rite_wiki_ingest_cleanup; exit 129' HUP

  stash_needed=false
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
    git stash push -m "rite-wiki-ingest-stash"
    stash_needed=true
  fi

  git checkout "$wiki_branch" || { echo "ERROR: git checkout '$wiki_branch' failed" >&2; exit 1; }

  # （ここで Phase 4 で決定したファイル変更を Write/Edit ツールで適用する）
  # - 新規ページ: pages/{domain}/{slug}.md を作成（page-template.md ベース）
  # - 既存ページ更新: 既存ファイルを Edit ツールで更新
  # - Raw Source ステージング: 開発ブランチから持ち込んだファイルを raw/{type}/ に配置し、frontmatter の ingested: true に書き換える
  # - index.md / log.md の更新（Phase 6/7 で行う）

  git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
  git commit -m "docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s)" \
    || { echo "ERROR: git commit failed" >&2; exit 1; }
  git push origin "$wiki_branch" || { echo "ERROR: git push failed" >&2; exit 1; }

  git checkout "$current_branch" || {
    echo "ERROR: git checkout '$current_branch' failed" >&2
    exit 1
  }

  if [ "$stash_needed" = true ]; then
    git stash pop
    stash_needed=false
  fi

  trap - EXIT INT TERM HUP

  # 開発ブランチ側にステージングされていた Raw Source は wiki ブランチに移送済みなので、開発ブランチ側からは削除して PR diff に混入しないようにする
  if [ -d ".rite/wiki/raw" ]; then
    find .rite/wiki/raw -type f -name '*.md' -delete 2>/dev/null || true
    find .rite/wiki/raw -type d -empty -delete 2>/dev/null || true
  fi
fi
```

### 5.2 same_branch 戦略

```bash
branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "same_branch" ]; then
  # Write/Edit ツールで .rite/wiki/pages/{domain}/{slug}.md を直接更新
  # （Phase 4 で決定したアクションを適用、Phase 6/7 で index/log を更新後）
  git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }
  git commit -m "docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages" \
    || { echo "ERROR: git commit failed" >&2; exit 1; }
fi
```

### 5.3 新規ページのテンプレート展開

新規ページを作成する際は `{plugin_root}/templates/wiki/page-template.md` を読み込み、以下のプレースホルダーを置換した上で書き込みます:

| プレースホルダー | 値 |
|----------------|-----|
| `{title}` | Phase 4.1 で生成したタイトル |
| `{domain}` | Phase 4.1 で決定したドメイン |
| `{created}` | 現在の ISO 8601 タイムスタンプ |
| `{updated}` | 現在の ISO 8601 タイムスタンプ |
| `{source_type}` | Raw Source の `type` フィールド (reviews/retrospectives/fixes/manual) |
| `{source_ref}` | Raw Source の相対パス（例: `raw/reviews/20260413T...md`） |
| `{summary}` | Phase 4.1 で生成したサマリー |
| `{details}` | Phase 4.1 で生成した詳細 |
| `{related_page_title}` | （該当があれば）最も近い既存ページのタイトル。なければ「（関連ページなし）」 |
| `{related_page_path}` | （該当があれば）相対パス |
| `{source_description}` | Raw Source の `title` フィールド or `source_ref` |

`confidence` は frontmatter のデフォルト `medium` を上書きする場合のみ Edit で変更してください。

---

## Phase 6: index.md の更新

`.rite/wiki/index.md` の「ページ一覧」テーブルに新規ページの行を追加し、既存ページが更新された場合は該当行の「更新日」を更新します。「統計」セクションの総ページ数とドメイン別カウントも再計算してください。

**更新ルール**:

- **新規ページ**: テーブル末尾に `| [{title}]({path}) | {domain} | {summary} | {updated} | {confidence} |` を追加
- **既存ページ更新**: 該当行の「更新日」と必要に応じて「サマリー」「確信度」を上書き
- **統計再計算**: テーブルの全行を数えてカウントを更新

書き込みは Phase 5 と同じブランチコンテキスト（separate_branch なら wiki ブランチ上）で行います。

---

## Phase 7: log.md の追記

`.rite/wiki/log.md` の「活動ログ」テーブルに **append-only** で新しいエントリを追記します。各 Raw Source 1件につき1行を追加してください。

| 列 | 値 |
|----|-----|
| 日時 | 現在の ISO 8601 タイムスタンプ |
| アクション | `ingest:create` (新規) / `ingest:update` (更新) / `ingest:skip` (スキップ) |
| 対象 | 対象ページの相対パス（スキップ時は Raw Source の相対パス） |
| 詳細 | Raw Source の `source_ref` や Issue/PR 番号、スキップ理由など |

**注意**: log.md は **append-only** です。既存行を変更してはいけません。

---

## Phase 8: 矛盾チェック

Ingest 直後、新規作成/更新したページと既存ページの間に明らかな矛盾がないか LLM が確認します。

**チェック観点**:

| 観点 | 検出方法 |
|------|---------|
| **タイトル衝突** | 新規ページのタイトルが既存ページと完全一致または高類似 |
| **方針逆転** | 既存ページが「X が推奨」、新規ページが「X は避けるべき」のような直接的対立 |
| **重複情報** | 既存ページに同じ情報がすでに記載されている |

**矛盾検出時の動作**:

矛盾を検出した場合、log.md に `ingest:warning` エントリを追記し、ユーザーに表示します:

```
⚠️ 矛盾の可能性を検出しました:
- {新規ページ}: {観点}
- 既存ページ: {既存ページ}

詳細レビューは /rite:wiki:lint で実施できます（後続 Issue で実装予定）。
```

**注意**: 本 Phase はあくまで **基本的な** チェックです。深い意味解析は将来の `/rite:wiki:lint` コマンドで実装されます（設計ドキュメント F4 参照）。

---

## Phase 9: 完了レポート

Ingest 完了後、以下の情報を表示します:

```
Wiki Ingest が完了しました。

処理サマリー:
- 処理した Raw Source: {n_raw_sources} 件
- 新規作成したページ: {n_pages_created} 件
- 更新したページ: {n_pages_updated} 件
- スキップした Raw Source: {n_skipped} 件
- 矛盾警告: {n_warnings} 件

新規/更新ページ:
- {path1} ({action1})
- {path2} ({action2})

次のステップ:
- /rite:wiki:query で経験則を参照（後続 Issue で実装予定）
- /rite:wiki:lint で Wiki の品質チェック（後続 Issue で実装予定）
```

---

## エラーハンドリング

| エラー | 対処 |
|--------|------|
| `wiki.enabled: false` | 早期 return（Phase 1.1） |
| Wiki 未初期化 | `/rite:wiki:init` を案内（Phase 1.2） |
| 処理対象0件 | 静かに終了し情報メッセージのみ表示（Phase 2.3） |
| ブランチ切り替え失敗 | cleanup trap で元ブランチに復帰、エラー出力 |
| `git push` 失敗 | エラー出力。ローカルコミットは残るので手動で push 可能 |
| LLM が経験則を抽出できない | 該当 Raw Source は `ingest:skip` として log.md に記録、`ingested: true` に変更 |

---

## 設計原則

- **単一責任**: Ingest は「Raw Source → Wiki ページ」の変換のみ。Query (`/rite:wiki:query`) と Lint (`/rite:wiki:lint`) は別コマンド
- **冪等性**: 同じ Raw Source を再 Ingest しても結果が同じ（`ingested: true` フラグで重複防止）
- **append-only な log**: 活動ログは履歴として残し、追加のみ
- **PR diff からの分離**: `separate_branch` 戦略では Wiki 変更は wiki ブランチに閉じる。開発ブランチには Raw Source の一時ファイルすら残さない
- **opt-in**: `wiki.enabled: false` がデフォルト。既存ワークフローへの影響なし
