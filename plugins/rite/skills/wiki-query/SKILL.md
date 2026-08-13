---
name: wiki-query
description: |
  rite workflow の Wiki 検索スキル: キーワードから関連する経験則ページを検索しコンテキストに
  注入する。ユーザーが明示的に /rite:wiki-query で起動する（自動注入は hook 経由）。
  auto-activate しない。
  起動: /rite:wiki-query <keywords>
argument-hint: "<keywords>"
---

# /rite:wiki-query

`.rite/wiki/index.md` からキーワード一致で関連ページを検索し、Markdown コンテキストブロックとして出力する。共通パターンは [Wiki Patterns](../../references/wiki-patterns.md)、設計は [F3 Query サイクル](../../../../docs/designs/experience-heuristics-persistence-layer.md)。

**Arguments** (オプショナル):

| 引数 | 説明 |
|------|------|
| `<keywords>` | カンマ区切りキーワード（例: `database,migration`）。省略時はユーザーに入力を促す |

**Examples**:

```
/rite:wiki-query database,migration
/rite:wiki-query "review context optimization,N+1"
/rite:wiki-query
```

---

## ステップ 1: 事前チェック

### 1.1 Wiki 設定の確認

`rite-config.yml` の `wiki.enabled` を確認する ([Wiki 有効判定パターン](../../references/wiki-patterns.md#wiki-有効判定パターン))。
rationale: references/rationale.md#wiki-config-probe

```bash
wiki_enabled=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
 | awk '/^[[:space:]]+enabled:/ { print; exit }' \
 | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' \
 | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
 false|no|0) echo "wiki_enabled=false" ;;
 true|yes|1) echo "wiki_enabled=true" ;;
 *) echo "wiki_enabled=true" ;; # opt-out default — section/key 未指定時も有効
esac
```

`wiki_enabled=false` の場合は以下を表示して早期 return:

```
Wiki 機能が無効です（wiki.enabled: false）。
有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki-init を実行してください。
```

### 1.2 Plugin Root の解決

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files) で解決する:

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

## ステップ 2: キーワードの決定

### 2.1 引数の確認

引数 `<keywords>` が指定されている場合は、それをそのまま使用します。カンマ区切りで複数指定できます（空白を含む場合は引用符で囲む）。

### 2.2 引数未指定時

引数未指定時は `AskUserQuestion` でキーワード入力を促す。フリーテキストは **Other**。
rationale: references/rationale.md#other-choice

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

## ステップ 3: Query 実行

`wiki-query-inject.sh` を呼び出す。結果は stdout の Markdown ブロック:

```bash
# ステップ 1.2 の値をリテラルで埋め込む
plugin_root="{plugin_root}"

# ステップ 2 で決定した keywords をそのまま渡す
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

---

## ステップ 4: 結果の扱い

### 4.1 マッチ有り

Markdown ブロックをそのまま表示する。**出力が `> ⚠️ Wiki index に登録行がありますが…` の 1 行だけの場合はマッチ有りではない**。その 1 行を表示したうえで 4.2 のヒントも併せて提示する。
rationale: references/rationale.md#warning-only-not-match

### 4.2 マッチ無し

空出力（該当ページ無し、Wiki 未初期化、ブランチ参照失敗など）は以下を表示:

```
該当する Wiki ページが見つかりませんでした（キーワード: {keywords}）。

ヒント:
- 別のキーワードで再検索: /rite:wiki-query <new-keywords>
- Wiki の蓄積状況を確認: .rite/wiki/index.md を参照（または wiki ブランチを確認）
- 新しい経験則を蓄積: /rite:wiki-ingest
```

---

## 注入先フェーズ（自動統合）

`wiki.auto_query: true` 時、以下から `wiki-query-inject.sh` が自動呼び出しされる。手動 `/rite:wiki-query` も利用可能:

| コマンド | 注入タイミング | キーワードソース | 統合セクション |
|---------|--------------|------------------|--------------|
| `/rite:open` | 実装計画生成前 | Issue タイトル + ラベル + 変更対象ファイル名 | `skills/open/SKILL.md` ステップ 3 (実装計画) |
| `/rite:pr-review` | レビュアー投入前 | 変更ファイルパス + ファイル種別 | `pr-review.md` ステップ 4.0.W |
| `/rite:fix` | 修正計画前 | レビュー指摘のカテゴリ + 対象ファイル | `fix.md` ステップ 0.5.W |
| `/rite:issue-implement` | 実装開始前 | 計画に含まれるキーワード | `implement.md` Phase 5.0.W |
