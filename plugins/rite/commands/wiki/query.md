---
description: Wiki Query — キーワードから関連する経験則ページを検索しコンテキストに注入
---

# /rite:wiki:query

Wiki Query エンジン。`.rite/wiki/index.md` からキーワード一致で関連ページを検索し、フォーマットされた Markdown コンテキストブロックとして出力します。rite ワークフロー各フェーズで自動注入することも、手動で任意キーワードから検索することも可能です。

> **Reference**: [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造、ブランチ管理
> **Reference**: [Experience Heuristics Persistence Layer — F3 Query サイクル](../../../../docs/designs/experience-heuristics-persistence-layer.md)

**Arguments** (オプショナル):

| 引数 | 説明 |
|------|------|
| `<keywords>` | カンマ区切りキーワード（例: `database,migration`）。省略時はユーザーに入力を促す |

**Examples**:

```
/rite:wiki:query database,migration
/rite:wiki:query "review context optimization,N+1"
/rite:wiki:query
```

---

## Phase 1: 事前チェック

### 1.1 Wiki 設定の確認

> **Reference**: [Wiki 有効判定パターン](../../references/wiki-patterns.md#wiki-有効判定パターン)

`rite-config.yml` の `wiki.enabled` を確認します。`wiki-query-inject.sh` 内で同じチェックを行うため、ここでは早期メッセージのみを目的とした **probe 用簡易版**として読み取ります:

> **Note**: 本 bash block は probe 用の簡易パーサで、`ingest.md` Phase 1.1 の cycle-6 fix 済み堅牢版 (分割実行・YAML コメント除去・F-01 pipefail 回避・stderr capture) とは挙動が異なります。値の真の採用は `wiki-query-inject.sh` 内の `_extract_yaml_value` が行うため、本 block は UX 上の早期エラー表示専用です。
>
> Wiki の `wiki.enabled` YAML パース実装は以下のファイルに分散しています。パース仕様を変更する場合は全ファイルの同期を確認してください:
>
> - `plugins/rite/commands/wiki/query.md` (本ファイル、probe 用簡易版)
> - `plugins/rite/commands/wiki/ingest.md` Phase 1.1 (堅牢版 / F-01 fix 済み)
> - `plugins/rite/commands/wiki/init.md` Phase 1.1 (初期化用簡易版)
> - `plugins/rite/hooks/wiki-query-inject.sh` (本体実装 / trap + stderr capture)
> - `plugins/rite/hooks/wiki-ingest-trigger.sh` (F-23 lenient 版)
> - `plugins/rite/commands/issue/implementation-plan.md` Phase 3.0.W (統合用簡易版)
> - `plugins/rite/commands/issue/implement.md` Phase 5.0.W (統合用簡易版)
> - `plugins/rite/commands/issue/close.md` Phase 4.4.W (統合用簡易版)
> - `plugins/rite/commands/pr/fix.md` Phase 0.5.W / Phase 4.6.W (統合用簡易版)
> - `plugins/rite/commands/pr/review.md` Phase 4.0.W / Phase 6.5.W (統合用簡易版)

```bash
wiki_enabled=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | awk '/^[[:space:]]+enabled:/ { print; exit }' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' \
  | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  false|no|0) echo "wiki_enabled=false" ;;
  true|yes|1) echo "wiki_enabled=true" ;;
  *)          echo "wiki_enabled=true" ;;  # #483: opt-out default — section/key 未指定時も有効
esac
```

`wiki_enabled=false` の場合は以下を表示して早期 return:

```
Wiki 機能が無効です（wiki.enabled: false）。
有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki:init を実行してください。
```

### 1.2 Plugin Root の解決

> **Reference**: [Plugin Path Resolution](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files)

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/wiki-query-inject.sh" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

以降の Bash ブロックでは `plugin_root` をリテラル値として埋め込んでください。

---

## Phase 2: キーワードの決定

### 2.1 引数の確認

引数 `<keywords>` が指定されている場合は、それをそのまま使用します。カンマ区切りで複数指定できます（空白を含む場合は引用符で囲む）。

### 2.2 引数未指定時

引数が未指定の場合は `AskUserQuestion` でキーワード入力を促します。`AskUserQuestion` は選択式 UI のため、フリーテキスト入力には **Other 選択肢**を使います (既存 `issue/edit.md` Phase 2.1 と同じパターン):

```
Wiki を検索するキーワードを入力してください。
- カンマ区切りで複数指定できます（例: database, migration, N+1）
- フリーテキスト入力には「Other」を選択してください
- キャンセルする場合は「キャンセル」を選択

オプション:
- キーワードを入力（Other を選択）: The user may freely type comma-separated keywords when selecting Other.
- キャンセル: Query を中止
```

「Other」経由で入力されたフリーテキストをそのまま `keywords` 変数に設定します。「キャンセル」選択時は何も出力せず終了します。

---

## Phase 3: Query 実行

`wiki-query-inject.sh` を呼び出して検索を実行します。結果は stdout に Markdown ブロックとして出力されます:

```bash
# Phase 1.2 の値をリテラルで埋め込む
plugin_root="{plugin_root}"

# Phase 2 で決定した keywords をそのまま渡す
# --max-pages / --min-score はスクリプトのデフォルト値 (5 / 1) と同一のため省略する。
# ユーザーが明示的に制御したい場合のみ下記の「オプション」表を参照して付与する。
bash "${plugin_root}/hooks/wiki-query-inject.sh" \
  --keywords "{keywords}" \
  --format compact
```

**オプション**:

| オプション | 用途 |
|-----------|------|
| `--max-pages N` | 返すページ数の上限（デフォルト: 5） |
| `--min-score N` | ヒットとみなす最小スコア（デフォルト: 1） |
| `--format full` | ページ本文まで含めて出力（コンテキスト消費が大きい） |
| `--format compact` | タイトル・サマリーのみ（デフォルト） |

詳細な検索動作が必要な場合は `--format full` を使い、全体把握には `--format compact` を使います。

---

## Phase 4: 結果の扱い

### 4.1 マッチ有り

`wiki-query-inject.sh` が Markdown ブロックを出力した場合、そのまま表示します。LLM はこの内容を参照してユーザーへの回答に役立てます。

### 4.2 マッチ無し

`wiki-query-inject.sh` が空出力の場合（該当ページ無し、Wiki 未初期化、ブランチ参照失敗など）は以下を表示:

```
該当する Wiki ページが見つかりませんでした（キーワード: {keywords}）。

ヒント:
- 別のキーワードで再検索: /rite:wiki:query <new-keywords>
- Wiki の蓄積状況を確認: .rite/wiki/index.md を参照（または wiki ブランチを確認）
- 新しい経験則を蓄積: /rite:wiki:ingest
```

---

## 注入先フェーズ（自動統合）

> **✅ 実装済み**: 以下の自動注入は **#472 で実装済み** です。`wiki.auto_query: true` 時に各コマンド内部から `wiki-query-inject.sh` が自動呼び出しされ、結果がコンテキストに注入されます。手動での `/rite:wiki:query` 実行も引き続き利用可能です。

以下のコマンドで自動注入が行われます（`wiki.auto_query: true` 時）:

| コマンド | 注入タイミング | キーワードソース | 統合セクション |
|---------|--------------|------------------|--------------|
| `/rite:issue:start` | 実装計画生成前 | Issue タイトル + ラベル + 変更対象ファイル名 | `implementation-plan.md` Phase 3.0.W |
| `/rite:pr:review` | レビュアー投入前 | 変更ファイルパス + ファイル種別 | `review.md` Phase 4.0.W |
| `/rite:pr:fix` | 修正計画前 | レビュー指摘のカテゴリ + 対象ファイル | `fix.md` Phase 0.5.W |
| `/rite:issue:implement` | 実装開始前 | 計画に含まれるキーワード | `implement.md` Phase 5.0.W |
