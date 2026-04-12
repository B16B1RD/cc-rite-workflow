---
description: Wiki の初期化（ディレクトリ構造・テンプレート展開・ブランチ作成）
---

# /rite:wiki:init

Wiki の初期化を行います。3層ディレクトリ構造の作成、テンプレート展開、Git ブランチの設定を実行します。

> **Reference**: [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造、ブランチ管理、テンプレート展開の共通パターン

## Phase 1: 事前チェック

### 1.1 Wiki 設定の読み取り

`rite-config.yml` から Wiki 設定を読み取ります:

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

**Wiki が無効の場合**: `AskUserQuestion` で有効化を確認:
```
Wiki 機能が無効です（wiki.enabled: false）。

オプション:
- Wiki を有効化して初期化（推奨）: rite-config.yml の wiki.enabled を true に変更して続行
- キャンセル: 初期化を中止
```

「有効化」選択時は Edit ツールで `rite-config.yml` の `wiki.enabled` を `true` に変更してから続行。

### 1.2 既存 Wiki の確認

> **Reference**: [Wiki 初期化判定パターン](../../references/wiki-patterns.md#wiki-初期化判定パターン)

Wiki が既に初期化済みかを確認します。初期化済みの場合は `AskUserQuestion`:

```
Wiki は既に初期化されています。

オプション:
- 再初期化（既存データをバックアップして上書き）
- キャンセル
```

### 1.3 ブランチ戦略の読み取り

```bash
branch_strategy=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_strategy:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_strategy:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
branch_strategy="${branch_strategy:-separate_branch}"

wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"

echo "branch_strategy=$branch_strategy"
echo "wiki_branch=$wiki_branch"
```

## Phase 2: ディレクトリ構造の作成

### 2.1 Plugin Root の解決

> **Reference**: [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script)

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "ERROR: plugin_root resolution failed" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

### 2.2 ディレクトリ作成

```bash
mkdir -p .rite/wiki/raw/reviews
mkdir -p .rite/wiki/raw/retrospectives
mkdir -p .rite/wiki/raw/fixes
mkdir -p .rite/wiki/pages/patterns
mkdir -p .rite/wiki/pages/heuristics
mkdir -p .rite/wiki/pages/anti-patterns
```

### 2.3 テンプレート展開

タイムスタンプを生成し、テンプレートのプレースホルダーを置換して展開:

```bash
initialized_at=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

# SCHEMA.md
sed "s/{initialized_at}/$initialized_at/g" \
  "${plugin_root}/templates/wiki/schema-template.md" > .rite/wiki/SCHEMA.md

# index.md
sed "s/{initialized_at}/$initialized_at/g" \
  "${plugin_root}/templates/wiki/index-template.md" > .rite/wiki/index.md

# log.md
sed "s/{initialized_at}/$initialized_at/g" \
  "${plugin_root}/templates/wiki/log-template.md" > .rite/wiki/log.md
```

## Phase 3: Git ブランチ設定

### 3.1 separate_branch 戦略の場合

> **Reference**: [separate_branch 戦略のブランチ操作](../../references/wiki-patterns.md#separate_branch-戦略のブランチ操作)

```bash
if [ "$branch_strategy" = "separate_branch" ]; then
  current_branch=$(git branch --show-current)

  # orphan ブランチを作成
  git checkout --orphan "$wiki_branch"
  git rm -rf . 2>/dev/null || true

  # Wiki ファイルのみをステージング
  git add .rite/wiki/

  git commit -m "feat(wiki): initialize Wiki structure

- 3-layer structure: Raw Sources / Wiki Pages / Schema
- Templates: SCHEMA.md, index.md, log.md
- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}"

  git push -u origin "$wiki_branch"

  # 元のブランチに戻る
  git checkout "$current_branch"

  echo "✅ Wiki ブランチ '$wiki_branch' を作成しました"
fi
```

### 3.2 same_branch 戦略の場合

```bash
if [ "$branch_strategy" = "same_branch" ]; then
  git add .rite/wiki/
  git commit -m "feat(wiki): initialize Wiki structure

- 3-layer structure: Raw Sources / Wiki Pages / Schema
- Templates: SCHEMA.md, index.md, log.md
- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}"

  echo "✅ Wiki を現在のブランチに初期化しました"
fi
```

## Phase 4: 完了レポート

```
Wiki の初期化が完了しました。

ブランチ戦略: {branch_strategy}
{wiki_branch 情報（separate_branch の場合のみ）}

作成されたファイル:
- .rite/wiki/SCHEMA.md (蓄積規約)
- .rite/wiki/index.md (ページカタログ)
- .rite/wiki/log.md (活動ログ)

作成されたディレクトリ:
- .rite/wiki/raw/{reviews, retrospectives, fixes}
- .rite/wiki/pages/{patterns, heuristics, anti-patterns}

次のステップ:
- /rite:wiki:ingest で経験則の蓄積を開始
- /rite:wiki:query で経験則を参照
- /rite:wiki:lint で Wiki の品質チェック
```
