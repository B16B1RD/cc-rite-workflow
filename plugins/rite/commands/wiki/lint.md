---
description: Wiki Lint — Wiki の品質チェック（矛盾・陳腐化・孤児・欠落・壊れた相互参照）
---

# /rite:wiki:lint

Wiki Lint エンジン。`.rite/wiki/pages/` 配下の Wiki ページと `.rite/wiki/raw/` の Raw Source、`.rite/wiki/index.md` の整合性を検査し、以下の 5 観点で品質問題を検出します:

| 観点 | 検出対象 |
|------|---------|
| **矛盾** | 同じトピックで異なる結論を持つページ（タイトル衝突・方針逆転・重複情報） |
| **陳腐化** | `updated` frontmatter が閾値（デフォルト 90 日）を超えて更新されていないページ |
| **孤児ページ** | `pages/` 配下に存在するが `index.md` の「ページ一覧」テーブルに登録されていないページ |
| **欠落概念** | `raw/` に `ingested: true` の Raw Source があるが、対応する Wiki ページが生成されていないトピック |
| **壊れた相互参照** | ページ本文の Markdown リンク `](...)` が `pages/` 配下の実在ファイルを指していない |

> **Reference**: [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造、ブランチ管理、テンプレート展開の共通パターン
> **Reference**: [Plugin Path Resolution](../../references/plugin-path-resolution.md) — `{plugin_root}` の解決手順

**Arguments** (オプショナル):

| 引数 | 説明 |
|------|------|
| `--auto` | 自動実行モード（Ingest 完了時に呼び出される想定）。検出結果を `log.md` に `lint:warning` として追記し、通常モードよりも出力を最小化する |
| `--stale-days <N>` | 陳腐化判定の閾値を日数で指定（デフォルト: 90） |

**Examples**:

```
/rite:wiki:lint
/rite:wiki:lint --auto
/rite:wiki:lint --stale-days 30
```

---

## Phase 1: 事前チェック

### 1.1 Wiki 設定の読み取りとブランチ戦略判定

`rite-config.yml` から Wiki 設定 (`wiki_enabled`, `wiki_branch`, `branch_strategy`) を**単一の bash ブロック**で読み取ります。ingest.md Phase 1.1/1.2 と同じ F-23 修正済みパーサーを使用します:

```bash
# NOTE: set -euo pipefail を意図的に省略。本ブロックはプローブ用で各コマンドの失敗を
# `|| fallback=""` で個別処理する。
#
# F-23 修正済みパターン: awk + YAML コメント除去 + 大文字小文字正規化
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""

# --- wiki_enabled の抽出 ---
wiki_enabled_line=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }') || wiki_enabled_line=""
fi
wiki_enabled=""
if [[ -n "$wiki_enabled_line" ]]; then
  wiki_enabled=$(printf '%s' "$wiki_enabled_line" | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in
  true|yes|1) wiki_enabled="true" ;;
  false|no|0|"") wiki_enabled="false" ;;
  *) wiki_enabled="false" ;;
esac

# --- wiki_branch の抽出 ---
wiki_branch_line=""
if [[ -n "$wiki_section" ]]; then
  wiki_branch_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+branch_name:/ { print; exit }') || wiki_branch_line=""
fi
wiki_branch=""
if [[ -n "$wiki_branch_line" ]]; then
  wiki_branch=$(printf '%s' "$wiki_branch_line" | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
fi
wiki_branch="${wiki_branch:-wiki}"

# --- branch_strategy の抽出 ---
branch_strategy_line=""
if [[ -n "$wiki_section" ]]; then
  branch_strategy_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+branch_strategy:/ { print; exit }') || branch_strategy_line=""
fi
branch_strategy=""
if [[ -n "$branch_strategy_line" ]]; then
  branch_strategy=$(printf '%s' "$branch_strategy_line" | sed 's/[[:space:]]#.*//' | sed 's/.*branch_strategy:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
fi
branch_strategy="${branch_strategy:-separate_branch}"

echo "wiki_enabled=$wiki_enabled"
echo "branch_strategy=$branch_strategy"
echo "wiki_branch=$wiki_branch"
```

**Wiki が無効の場合**: 早期 return:

```
Wiki 機能が無効です（wiki.enabled: false）。
有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki:init を実行してください。
```

exit 0 で終了。`--auto` モードでは stdout を空にして exit 0（非ブロッキング）。

### 1.2 Wiki 初期化判定

Phase 1.1 で取得した `branch_strategy` と `wiki_branch` を使い、Wiki が初期化済みかを判定します:

```bash
# Phase 1.1 の値をリテラルで埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

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

exit 0 で終了。`--auto` モードでは stdout を空にして exit 0。

**変数保持指示**: Phase 1.2 で出力された `branch_strategy` と `wiki_branch` の値を保持し、以降のすべての Bash ブロックで**リテラル値として埋め込んで**使用してください。Claude Code の Bash ツール間でシェル変数は保持されません。

### 1.3 引数の解析

引数から `--auto` と `--stale-days N` を解析し、以下の変数を会話コンテキストに保持します:

| 変数 | 初期値 | 説明 |
|------|--------|------|
| `auto_mode` | `false` | `--auto` 指定時に `true` |
| `stale_days` | `90` | `--stale-days N` で上書き |

**カウンター変数の初期化** (Phase 9 完了レポートで参照):

| 変数 | 初期値 | incrementate タイミング |
|------|--------|----------------------|
| `n_contradictions` | `0` | Phase 3 で矛盾検出するごとに +1 |
| `n_stale` | `0` | Phase 4 で陳腐化検出するごとに +1 |
| `n_orphans` | `0` | Phase 5 で孤児ページ検出するごとに +1 |
| `n_missing` | `0` | Phase 6 で欠落概念検出するごとに +1 |
| `n_broken_refs` | `0` | Phase 7 で壊れた相互参照検出するごとに +1 |
| `issues[]` | `[]` | 各検出結果を `{category, page, detail}` として append |

---

## Phase 2: 検査対象の収集

### 2.1 separate_branch 戦略時のブランチ切替

`separate_branch` 戦略では、Wiki データは wiki ブランチに存在します。lint は**読み取り専用**の操作のみ行い、`.rite/wiki/pages/` と `.rite/wiki/raw/` と `.rite/wiki/index.md` を検査対象として収集します。

> **Reference**: [Wiki ブランチへの書き込み（Ingest 時）](../../references/wiki-patterns.md#wiki-ブランチへの書き込みingest-時) — ブランチ切替・cleanup trap のパターンは ingest.md と共通

**方針**: lint は書き込みを行わないため、ブランチを切り替えず `git show <branch>:<path>` および `git ls-tree -r --name-only <branch>` で wiki ブランチの内容を読み出します。これにより worktree の退避・復帰が不要で、実装が単純化されます。例外は Phase 8 の `log.md` 追記で、ここだけ一時的にブランチを切り替えます（ingest.md Phase 5 と同じパターン）。

### 2.2 Wiki ページの列挙

`pages/patterns/`, `pages/heuristics/`, `pages/anti-patterns/` 配下の `.md` ファイルを列挙します:

```bash
# Phase 1 の値をリテラルで埋め込む
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

pages_list=""
if [ "$branch_strategy" = "separate_branch" ]; then
  ls_err=$(mktemp /tmp/rite-wiki-lint-ls-err-XXXXXX 2>/dev/null) || ls_err=""
  if ls_out=$(git ls-tree -r --name-only "$wiki_branch" 2>"${ls_err:-/dev/null}"); then
    pages_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/pages/(patterns|heuristics|anti-patterns)/[^/]+\.md$' || true)
  else
    rc=$?
    echo "WARNING: git ls-tree '$wiki_branch' failed (rc=$rc)" >&2
    [ -n "$ls_err" ] && [ -s "$ls_err" ] && head -3 "$ls_err" | sed 's/^/  /' >&2
    echo "  対処: wiki ブランチが存在するか確認してください (git rev-parse --verify $wiki_branch)" >&2
    exit 1
  fi
  [ -n "$ls_err" ] && rm -f "$ls_err"
else
  if [ -d ".rite/wiki/pages" ]; then
    pages_list=$(find .rite/wiki/pages -type f -name '*.md' 2>/dev/null || true)
  fi
fi

printf '%s\n' "$pages_list"
```

LLM は stdout の出力結果を `pages_list` として会話コンテキストに保持し、以降の Phase で参照します。

### 2.3 Raw Source の列挙

`pages_list` と同じ方針で `.rite/wiki/raw/{reviews,retrospectives,fixes}/` 配下の `.md` ファイルを列挙します。出力結果を `raw_list` として保持します。

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

raw_list=""
if [ "$branch_strategy" = "separate_branch" ]; then
  if ls_out=$(git ls-tree -r --name-only "$wiki_branch" 2>/dev/null); then
    raw_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/raw/(reviews|retrospectives|fixes)/[^/]+\.md$' || true)
  fi
else
  if [ -d ".rite/wiki/raw" ]; then
    raw_list=$(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null || true)
  fi
fi

printf '%s\n' "$raw_list"
```

### 2.4 index.md の読み込み

`.rite/wiki/index.md` の内容を `index_content` として会話コンテキストに保持します。

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  git show "${wiki_branch}:.rite/wiki/index.md" 2>/dev/null || {
    echo "ERROR: index.md を wiki ブランチから読み出せません" >&2
    exit 1
  }
else
  cat .rite/wiki/index.md 2>/dev/null || {
    echo "ERROR: .rite/wiki/index.md が存在しません" >&2
    exit 1
  }
fi
```

**処理対象 0 件の場合**: `pages_list` と `raw_list` が両方空なら、Phase 3-7 をスキップし Phase 8 に進みます（検出結果なしの完了レポート）。

---

## Phase 3: 矛盾検出

### 3.1 ページ frontmatter とタイトル・ドメインの抽出

Phase 2.2 で収集した各ページについて、`git show` または `cat` で本文を取得し、以下のフィールドを抽出します:

| フィールド | 抽出元 | 用途 |
|-----------|--------|------|
| `title` | YAML frontmatter | タイトル衝突検出 |
| `domain` | YAML frontmatter | ドメイン単位での比較 |
| `updated` | YAML frontmatter | Phase 4（陳腐化）で使用 |
| `confidence` | YAML frontmatter | 矛盾判定の優先度 |
| 本文（概要・詳細） | frontmatter 除外後 | 方針逆転・重複情報の検出 |

### 3.2 矛盾の判定

LLM が `pages_list` の全ページペアを意味的に比較し、以下の観点で矛盾を検出します:

| 観点 | 検出方法 | 判定例 |
|------|---------|--------|
| **タイトル衝突** | title フィールドが同一または 90% 以上類似 | `エラーハンドリングのパターン` と `エラーハンドリング パターン` |
| **方針逆転** | 同じトピックで `推奨` と `避けるべき` が直接対立 | Page A「X を使う」 / Page B「X は使わない」 |
| **重複情報** | 異なるページに同一の概要・結論が記載 | 概要テキストが 80% 以上一致 |

**セマンティック比較の指針**:

- ページ数が多い場合（> 20）は、まず `domain` と `title` の表層マッチでフィルタリングし、候補ペアのみ詳細比較
- `confidence` が両方 `low` の場合は矛盾判定の優先度を下げる（警告のみ、発見しても `n_contradictions` に加算するが強調しない）
- 方針逆転の判定には必ず両ページの「詳細」セクションの該当箇所を引用する

### 3.3 検出結果の記録

矛盾を検出したら `issues[]` に以下の形式で append し、`n_contradictions` を +1 します:

```
{
  "category": "contradiction",
  "page_a": ".rite/wiki/pages/patterns/error-handling.md",
  "page_b": ".rite/wiki/pages/anti-patterns/error-silent.md",
  "detail": "方針逆転: Page A は try-catch ラップを推奨、Page B は同パターンを anti-pattern として記載",
  "subcategory": "方針逆転" | "タイトル衝突" | "重複情報"
}
```

---

## Phase 4: 陳腐化検出

### 4.1 updated タイムスタンプの比較

各ページの frontmatter `updated` フィールドを取得し、現在時刻との差分を計算します。`stale_days`（デフォルト 90）を超えるページを陳腐化として記録します。

```bash
# Phase 1.3 の値をリテラルで埋め込む
stale_days="{stale_days}"

current_epoch=$(date +%s)
threshold_seconds=$((stale_days * 86400))
cutoff_epoch=$((current_epoch - threshold_seconds))
echo "cutoff_epoch=$cutoff_epoch"
```

各ページについて以下を実行します:

```bash
# ページ本文から updated フィールドを抽出
updated_str=$(printf '%s' "$page_content" | awk '/^updated:/ { gsub(/^updated:[[:space:]]*"?|"$/, ""); print; exit }')
# ISO 8601 を epoch 秒に変換（GNU date 前提）
updated_epoch=$(date -d "$updated_str" +%s 2>/dev/null || echo "")
if [ -n "$updated_epoch" ] && [ "$updated_epoch" -lt "$cutoff_epoch" ]; then
  echo "STALE: $page_path (updated: $updated_str)"
fi
```

### 4.2 検出結果の記録

陳腐化を検出したら `issues[]` に以下の形式で append し、`n_stale` を +1 します:

```
{
  "category": "stale",
  "page": ".rite/wiki/pages/heuristics/old-pattern.md",
  "updated": "2025-09-01T10:00:00+09:00",
  "days_since_update": 223,
  "detail": "90 日以上更新なし（223 日前）"
}
```

**注意**: `date -d` は GNU date（Linux）前提です。macOS 環境での動作は保証しません（本プロジェクトは Linux WSL が主想定のため許容）。

---

## Phase 5: 孤児ページ検出

### 5.1 index.md の「ページ一覧」テーブル解析

Phase 2.4 で取得した `index_content` から「ページ一覧」テーブルの行を抽出し、登録済みページパスを集合 `indexed_pages` として保持します:

```bash
# index_content は Phase 2.4 の結果。LLM が変数として保持しているため、
# ここでは解析ロジックのみ示す。

# テーブル行から Markdown リンク `[title](path)` の path を抽出
# 例: | [エラーハンドリング](pages/patterns/error-handling.md) | patterns | ... |
printf '%s\n' "$index_content" \
  | grep -E '^\|.*\]\(pages/[^)]+\)' \
  | sed -E 's/.*\]\((pages\/[^)]+)\).*/\1/' \
  | sort -u
```

### 5.2 孤児ページの判定

Phase 2.2 で収集した `pages_list` から `.rite/wiki/` プレフィックスを除いた相対パス（`pages/patterns/...`）を計算し、`indexed_pages` に含まれないページを孤児として記録します。

LLM は両集合を比較し、差分（`pages_list \ indexed_pages`）を `n_orphans` として +1 し、`issues[]` に append します:

```
{
  "category": "orphan",
  "page": ".rite/wiki/pages/patterns/new-page.md",
  "detail": "index.md の「ページ一覧」テーブルに未登録"
}
```

---

## Phase 6: 欠落概念検出

### 6.1 Ingest 済み Raw Source の列挙

Phase 2.3 で収集した `raw_list` から、frontmatter の `ingested: true` を持つファイルを抽出します:

```bash
# 各 raw_file について:
ingested=$(printf '%s' "$raw_content" | awk '/^ingested:/ { gsub(/^ingested:[[:space:]]*"?|"$/, ""); print; exit }')
raw_title=$(printf '%s' "$raw_content" | awk '/^title:/ { gsub(/^title:[[:space:]]*"?|"$/, ""); print; exit }')
# ingested == "true" なら処理対象
```

### 6.2 対応ページの存在確認

各「Ingest 済み Raw Source」の `title` または `source_ref` が、Phase 5.1 の `indexed_pages` に含まれるページの `sources[]` に参照されているかを LLM が判定します。

判定方法:

1. `indexed_pages` の各 Wiki ページの frontmatter `sources[].ref` を抽出
2. `raw_list` の各 Raw Source の相対パス（`raw/reviews/...`）がどの Wiki ページの `sources[].ref` にも含まれないなら「欠落概念」候補
3. さらに LLM が Raw Source 本文を読み、経験則として価値がある内容かを判定（単なるエラーログや空コメントは除外）

### 6.3 検出結果の記録

```
{
  "category": "missing_concept",
  "raw_source": ".rite/wiki/raw/reviews/20260410T...md",
  "title": "PR #123 review findings",
  "detail": "Ingest 済みだが対応する Wiki ページが生成されていない"
}
```

`n_missing` を +1。

---

## Phase 7: 壊れた相互参照検出

### 7.1 ページ本文の Markdown リンク抽出

各 Wiki ページの本文から Markdown リンク `[text](path)` を抽出します:

```bash
# 各 page_content について:
printf '%s' "$page_content" | grep -oE '\]\([^)]+\)' | sed -E 's/\]\(([^)]+)\)/\1/'
```

### 7.2 相互参照の妥当性判定

抽出した各リンクについて以下を判定します:

| リンク種別 | 判定方法 |
|----------|---------|
| **相対パス (`../pages/...`, `pages/...`)** | `pages_list` に実在するか確認 |
| **絶対パス (`/pages/...`)** | 対象外（HTTP URL 等） |
| **外部 URL (`http://...`, `https://...`)** | 対象外（lint 対象外） |
| **アンカー (`#section`)** | 対象外（同一ファイル内参照） |
| **Raw Source 参照 (`raw/...`)** | `raw_list` に実在するか確認（Phase 2.3 の結果を使用） |

壊れた参照を検出したら `issues[]` に以下を append し、`n_broken_refs` を +1 します:

```
{
  "category": "broken_ref",
  "page": ".rite/wiki/pages/heuristics/pattern-a.md",
  "link": "../patterns/deleted-page.md",
  "detail": "リンク先ファイルが存在しない"
}
```

---

## Phase 8: log.md 追記

### 8.1 検出結果の log.md 記録

Lint 完了後、`.rite/wiki/log.md` に以下の形式でエントリを追記します:

| 列 | 値 |
|----|-----|
| 日時 | 現在の ISO 8601 タイムスタンプ |
| アクション | `lint:clean`（問題なし）/ `lint:warning`（検出あり） |
| 対象 | `—`（全体チェック） |
| 詳細 | `contradictions={n}, stale={n}, orphans={n}, missing={n}, broken_refs={n}` |

**書き込みは `separate_branch` 戦略時のみブランチ切替が必要**です。ingest.md Phase 5 の wiki ブランチ書き込みパターンを踏襲してください（`git stash` → `git checkout {wiki_branch}` → Edit → `git commit` → `git push origin {wiki_branch}` → 元ブランチに復帰 → `git stash pop`）。

> **Reference**: [Wiki ブランチへの書き込み（Ingest 時）](../../references/wiki-patterns.md#wiki-ブランチへの書き込みingest-時)

**同一ブランチ戦略の場合**: 直接 Edit ツールで `.rite/wiki/log.md` に追記します。

**append-only の原則**: log.md の既存行を変更してはいけません。必ず末尾に新規行を追加します。

**`--auto` モード**: Ingest 完了直後に呼ばれる場合、Ingest 側が同じ wiki ブランチ上で既に書き込み済みであるため、ここでのブランチ切替は不要です。LLM は呼び出しコンテキストから `auto_mode=true` を判別し、直接 Edit で追記してください。

---

## Phase 9: 完了レポート

### 9.1 通常モードの出力

```
Wiki Lint が完了しました。

検査サマリー:
- 検査した Wiki ページ: {n_pages} 件
- 検査した Raw Source: {n_raw} 件

検出結果:
- 矛盾: {n_contradictions} 件
- 陳腐化: {n_stale} 件
- 孤児ページ: {n_orphans} 件
- 欠落概念: {n_missing} 件
- 壊れた相互参照: {n_broken_refs} 件

検出詳細:
{issues_list_formatted}

次のステップ:
- 矛盾は手動で該当ページを統合してください
- 陳腐化ページは /rite:wiki:ingest で新しい Raw Source を統合するか、手動で updated フィールドを更新してください
- 孤児ページは index.md に追加するか、不要なら削除してください
- 欠落概念は /rite:wiki:ingest で該当 Raw Source を再処理してください
- 壊れた相互参照は該当ページを手動で修正してください
```

`{issues_list_formatted}` は `issues[]` の各要素をカテゴリ別にグループ化し、以下の形式で表示します:

```
### 矛盾
- [方針逆転] pages/patterns/x.md ↔ pages/anti-patterns/y.md
  X を使う vs X は使わない

### 陳腐化
- pages/heuristics/old.md (223 日前)

### 孤児ページ
- pages/patterns/new.md

### 欠落概念
- raw/reviews/20260410T...md (PR #123 review findings)

### 壊れた相互参照
- pages/heuristics/a.md → ../patterns/deleted.md
```

### 9.2 `--auto` モードの出力

Ingest 完了直後に呼ばれる場合、出力は最小化されます:

```
Lint: contradictions={n_contradictions}, stale={n_stale}, orphans={n_orphans}, missing={n_missing}, broken_refs={n_broken_refs}
```

検出件数が全て 0 の場合は stdout を空にして exit 0（非ブロッキング）。

### 9.3 exit code

- 検出件数に関わらず **exit 0**（非ブロッキング設計）
- 事前チェック失敗（wiki.enabled: false, Wiki 未初期化, ブランチ読み取り失敗）は exit 0 + 警告メッセージ
- 内部エラー（bash 構文エラー、jq パース失敗等）のみ exit 1

**非ブロッキングの理由**: Ingest 時の自動 Lint でワークフローを停止しないため、および `rite:lint` 呼び出しは warning 相当で Issue ドリブン開発を妨げないため。ユーザーは検出結果を完了レポートで確認し、手動で対応判断を行います。

---

## エラーハンドリング

| エラー | 対処 |
|--------|------|
| `wiki.enabled: false` | 早期 return（Phase 1.1）、exit 0 |
| Wiki 未初期化 | `/rite:wiki:init` を案内（Phase 1.2）、exit 0 |
| `git ls-tree '$wiki_branch'` 失敗 | Phase 2 で WARNING + exit 1（wiki ブランチ不存在は lint 不能状態のため fail-fast） |
| `date -d "$updated_str"` 失敗 | 該当ページをスキップし log に記録、`n_stale` には加算しない |
| `index.md` 読み出し失敗 | Phase 2.4 で exit 1（orphan 検出不能のため続行不可） |
| 処理対象 0 件 | Phase 3-7 をスキップし、Phase 9 で「検査対象なし」のメッセージを表示 |
| `branch_strategy` が未知の値 | Phase 2.2 の bash block 末尾で fail-fast 検出（ingest.md と同じ挙動） |
| log.md 追記失敗（`--auto` 以外） | WARNING を出し処理を継続（検出結果は stdout に表示済み） |

---

## 設計原則

- **読み取り専用**: lint は Wiki ページ・Raw Source を変更しない。log.md 追記のみが唯一の書き込み操作
- **非ブロッキング**: 検出件数によらず exit 0。ワークフロー停止は ingest/review/fix の責務
- **単一責任**: 品質チェック専用。修正は `/rite:wiki:ingest` の再実行や手動編集で行う
- **opt-in**: `wiki.enabled: false` がデフォルト。既存ワークフローへの影響なし
- **自動/手動の両対応**: Ingest 時の `auto_lint` フラグと手動 `/rite:wiki:lint` の両方で同じロジックを共有し、出力形式のみ `--auto` で切替
- **セマンティック比較**: 矛盾・欠落概念の判定は LLM の読解能力に依存。単純な文字列一致では検出できないため、Phase 3/6 では LLM が本文を実際に読む
