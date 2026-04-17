---
description: Wiki Lint — Wiki の品質チェック（矛盾・陳腐化・孤児・欠落概念・未登録 raw・壊れた相互参照）
---

# /rite:wiki:lint

Wiki Lint エンジン。`.rite/wiki/pages/` 配下の Wiki ページと `.rite/wiki/raw/` の Raw Source、`.rite/wiki/index.md` の整合性を検査し、以下の **5 ブロッキング観点 + 1 informational 指標**で品質問題を検出します:

| 観点 | 検出対象 | ブロッキング |
|------|---------|--------------|
| **矛盾** | 同じトピックで異なる結論を持つページ（タイトル衝突・方針逆転・重複情報） | Yes |
| **陳腐化** | `updated` frontmatter が閾値（デフォルト 90 日）を超えて更新されていないページ | Yes |
| **孤児ページ** | `pages/` 配下に存在するが `index.md` の「ページ一覧」テーブルに登録されていないページ | Yes |
| **欠落概念 (missing_concept)** | `raw/` に `ingested: true` の Raw Source があるが、対応ページも `sources.ref` 登録も `ingest:skip` 記録も存在しない真の欠落 | Yes |
| **未登録 raw (unregistered_raw)** | `ingested: true` で `sources.ref` 未登録だが、`log.md` に `ingest:skip` 記録がある raw。意図的に経験則化しなかった件数の informational 指標 | **No** (`n_warnings` 不加算) |
| **壊れた相互参照** | ページ本文の Markdown リンク `](...)` が `pages/` 配下の実在ファイルを指していない | Yes |

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

## 設計原則（全 Phase 共通）

- **非ブロッキング契約**: 検出件数・事前チェック失敗・ブランチ読取失敗にかかわらず、本コマンドは **常に exit 0** で終了する。例外は `{branch_strategy}` が未知の値だった場合の fail-fast（Phase 2.2 / Phase 6.0 / Phase 8.2 の 3 箇所で同型）で、これは設定ミスを silent に通過させないための設計判断である
- **読み取り専用**: `log.md` への追記を除き、Wiki データ・Raw Source は一切変更しない
- **LLM セマンティック依存**: 矛盾検出（Phase 3）・欠落概念検出（Phase 6）は LLM の読解能力に依存する。単純な文字列一致では検出できないため本文を実際に読む
- **GNU date 前提**: Phase 4 の陳腐化検出は GNU date (`date -d`) に依存する。Phase 1.2 で事前検査を行い、macOS/BSD 環境では警告のうえ Phase 4 を skip する
- **単一責任**: 品質チェック専用。修正は `/rite:wiki:ingest` 再実行や手動編集で行う

---

## Phase 1: 事前チェック

### 1.1 Wiki 設定の読み取りとブランチ戦略判定

`rite-config.yml` から Wiki 設定 (`wiki_enabled`, `wiki_branch`, `branch_strategy`) を単一の bash ブロックで読み取ります。ingest.md Phase 1.1 と同じ F-23 修正済みパーサーを使用します:

```bash
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
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *) wiki_enabled="true" ;;  # #483: opt-out default — 空文字 / 不明値は section/key 未指定とみなして有効化
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

exit 0 で終了。`--auto` モードでは stdout を空にして exit 0。

### 1.2 GNU date 事前検査

Phase 4（陳腐化検出）は `date -d "ISO 8601 string"` に依存します。macOS/BSD 環境では GNU date 非互換のため silent に陳腐化判定を skip しないよう、事前に検査します:

```bash
if date -d "2025-01-01" +%s >/dev/null 2>&1; then
  date_gnu_available="true"
else
  date_gnu_available="false"
  echo "WARNING: GNU date 非互換環境を検出しました。Phase 4（陳腐化検出）は skip されます" >&2
  echo "  対処: macOS/BSD 環境では coreutils (gdate) のインストールを検討してください" >&2
fi
echo "date_gnu_available=$date_gnu_available"
```

`date_gnu_available=false` の場合、Phase 4 全体を skip し `n_stale=0` のまま Phase 5 へ進みます（非ブロッキング契約維持）。

### 1.3 Wiki 初期化判定

Phase 1.1 で取得した `branch_strategy` と `wiki_branch` を使い、Wiki が初期化済みかを判定します:

```bash
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

exit 0 で終了。

### 1.4 引数の解析とカウンタ変数の初期化

引数から `--auto` と `--stale-days N` を解析します:

| 変数 | 初期値 | 説明 |
|------|--------|------|
| `auto_mode` | `false` | `--auto` 指定時に `true` |
| `stale_days` | `90` | `--stale-days N` で上書き |

**カウンタ変数の初期化** (Phase 9 完了レポートで参照される。`increment` タイミングを明示):

| 変数 | 初期値 | increment タイミング |
|------|--------|--------------------|
| `n_contradictions` | `0` | Phase 3 で矛盾検出するごとに +1 |
| `n_stale` | `0` | Phase 4 で陳腐化検出するごとに +1 |
| `n_orphans` | `0` | Phase 5 で孤児ページ検出するごとに +1 |
| `n_missing_concept` | `0` | Phase 6.2 で真の欠落（`ingest:skip` 記録も `sources.ref` 登録も無い）を検出するごとに +1。ingest から呼ばれた場合、ingest 側 Phase 8.5 で `n_warnings` に加算される（ブロッキング相当。lint 単独実行時は `n_warnings` 変数は lint 内には存在せず、加算は ingest 側の責務） |
| `n_unregistered_raw` | `0` | Phase 6.2 で `ingest:skip` 記録ありの未登録 raw を検出するごとに +1。意図的に経験則化しなかった raw の informational 指標で、`n_warnings` に加算しない |
| `n_broken_refs` | `0` | Phase 7 で壊れた相互参照検出するごとに +1 |
| `issues[]` | `[]` | 各検出結果を `{category, page, detail}` として append |

---

## Phase 2: 検査対象の収集

### 2.1 検査対象ブランチの決定

Phase 8 log.md 追記時を除き lint は**読み取り専用**のため、`git show <branch>:<path>` および `git ls-tree -r --name-only <branch>` で wiki ブランチの内容を読み出します。

### 2.2 branch_strategy の検証と検査対象の一括収集

未知の `branch_strategy` 値を silent に same-branch 扱いしないよう、`case` 文で検証し、Phase 2.2 と 2.3 の重複 `git ls-tree` 呼び出しを 1 回に統合します。非ブロッキング契約に従い、`git ls-tree` 失敗時は exit 0 + WARNING + `pages_list=""` / `raw_list=""` で継続します:

```bash
# signal-specific trap でリソースの orphan を防ぐ
ls_err=""
_rite_wiki_lint_phase2_cleanup() {
  rm -f "${ls_err:-}"
}
trap 'rc=$?; _rite_wiki_lint_phase2_cleanup; exit $rc' EXIT
trap '_rite_wiki_lint_phase2_cleanup; exit 130' INT
trap '_rite_wiki_lint_phase2_cleanup; exit 143' TERM
trap '_rite_wiki_lint_phase2_cleanup; exit 129' HUP

# Phase 1 の値をリテラル substitute
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

pages_list=""
raw_list=""

case "$branch_strategy" in
  separate_branch)
    ls_err=$(mktemp /tmp/rite-wiki-lint-ls-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile の mktemp に失敗しました。ls-tree の詳細エラー情報は失われます" >&2
      ls_err=""
    }
    # 1 回の git ls-tree で pages と raw の両方を抽出する（重複呼び出しの排除）
    if ls_out=$(git ls-tree -r --name-only "$wiki_branch" 2>"${ls_err:-/dev/null}"); then
      pages_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/pages/(patterns|heuristics|anti-patterns)/[^/]+\.md$' || true)
      raw_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/raw/(reviews|retrospectives|fixes)/[^/]+\.md$' || true)
    else
      rc=$?
      echo "WARNING: git ls-tree '$wiki_branch' に失敗しました (rc=$rc)" >&2
      [ -n "$ls_err" ] && [ -s "$ls_err" ] && head -3 "$ls_err" | sed 's/^/  /' >&2
      echo "  対処: wiki ブランチが存在するか確認してください (git rev-parse --verify $wiki_branch)" >&2
      echo "  影響: 検査対象を 0 件として扱い、Phase 9 で「検査対象なし」を表示します（非ブロッキング）" >&2
    fi
    ;;
  same_branch)
    if [ -d ".rite/wiki/pages" ]; then
      pages_list=$(find .rite/wiki/pages -type f -name '*.md' 2>/dev/null || true)
    fi
    if [ -d ".rite/wiki/raw" ]; then
      raw_list=$(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null || true)
    fi
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy'" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（非ブロッキング契約の唯一の例外）" >&2
    exit 1
    ;;
esac

[ -n "$ls_err" ] && rm -f "$ls_err"

printf '%s\n' "$pages_list"
echo "---"
printf '%s\n' "$raw_list"
```

LLM は stdout から `pages_list` と `raw_list` を会話コンテキストに保持します。`pages_list` と `raw_list` が両方空なら、Phase 3-7 をスキップし Phase 9 に進みます（検出結果なしの完了レポート）。

### 2.3 index.md の読み込み

`.rite/wiki/index.md` の内容を `index_content` として会話コンテキストに保持します。失敗時は非ブロッキング契約に従い warning + Phase 5（孤児検出）skip で継続します:

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

index_read_ok="true"
index_err=$(mktemp /tmp/rite-wiki-lint-index-err-XXXXXX 2>/dev/null) || index_err=""

if [ "$branch_strategy" = "separate_branch" ]; then
  if index_content=$(git show "${wiki_branch}:.rite/wiki/index.md" 2>"${index_err:-/dev/null}"); then
    # 成功時でも ambiguous ref 等の git hint が stderr に出る場合がある
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  WARNING(git hint): /' >&2
  else
    echo "WARNING: index.md を wiki ブランチから読み出せません" >&2
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  /' >&2
    echo "  影響: Phase 5（孤児ページ検出）を skip します（非ブロッキング）" >&2
    index_content=""
    index_read_ok="false"
  fi
else
  if index_content=$(cat .rite/wiki/index.md 2>"${index_err:-/dev/null}"); then
    :
  else
    echo "WARNING: .rite/wiki/index.md を読み出せません" >&2
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  /' >&2
    echo "  影響: Phase 5（孤児ページ検出）を skip します（非ブロッキング）" >&2
    index_content=""
    index_read_ok="false"
  fi
fi

[ -n "$index_err" ] && rm -f "$index_err"
echo "index_read_ok=$index_read_ok"
```

`index_read_ok="false"` の場合、Phase 5 全体を skip し `n_orphans=0` のまま Phase 6 へ進みます。

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

- ページ数が多い場合（> 20）は、まず同じ `domain` 内のペアのみを比較対象とし、cross-domain 比較は domain pair 単位で実施する
- `confidence` が両方 `low` の場合は矛盾判定の優先度を下げる
- 方針逆転の判定には必ず両ページの「詳細」セクションの該当箇所を引用する

### 3.3 検出結果の記録

矛盾を検出したら `issues[]` に以下の形式で append し、`n_contradictions` を +1 します:

```
{
  "category": "contradiction",
  "page_a": ".rite/wiki/pages/patterns/error-handling.md",
  "page_b": ".rite/wiki/pages/anti-patterns/error-silent.md",
  "detail": "方針逆転: Page A は try-catch ラップを推奨、Page B は同パターンを anti-pattern として記載",
  "subcategory": "方針逆転"
}
```

`subcategory` は `タイトル衝突` / `方針逆転` / `重複情報` のいずれかを使用します（Phase 9 の表示で使用）。

---

## Phase 4: 陳腐化検出

### 4.1 事前条件

Phase 1.2 で `date_gnu_available="false"` と判定された場合、Phase 4 全体を skip し `n_stale=0` のまま Phase 5 へ進みます。

### 4.2 updated タイムスタンプの比較

```bash
stale_days="{stale_days}"
current_epoch=$(date +%s)
threshold_seconds=$((stale_days * 86400))
cutoff_epoch=$((current_epoch - threshold_seconds))
echo "cutoff_epoch=$cutoff_epoch"
```

> **⚠️ 以下のスニペットは LLM が各ページに対して for-loop 内で実行することを前提**とします。`continue` は enclosing loop の次 iteration へ進む制御です。`{cutoff_epoch}` は上の bash block の出力値を LLM が literal substitute してください。ループ骨組み例: `for page_path in <pages_list の各要素>; do page_content=$(git show "${wiki_branch}:$page_path" 2>/dev/null || cat "$page_path" 2>/dev/null); <以下のスニペット>; done`

```bash
updated_str=$(printf '%s' "$page_content" | awk '/^updated:/ { gsub(/^updated:[[:space:]]*"?|"$/, ""); print; exit }')

if [ -z "$updated_str" ]; then
  echo "WARNING: $page_path に updated フィールドが存在しません。陳腐化判定を skip します" >&2
  continue
fi

date_err=$(mktemp /tmp/rite-wiki-lint-date-err-XXXXXX 2>/dev/null) || date_err=""
if updated_epoch=$(date -d "$updated_str" +%s 2>"${date_err:-/dev/null}"); then
  :
else
  echo "WARNING: $page_path の updated フィールド '$updated_str' をパースできません。陳腐化判定を skip します" >&2
  [ -n "$date_err" ] && [ -s "$date_err" ] && head -3 "$date_err" | sed 's/^/  /' >&2
  echo "  対処: ISO 8601 形式（例: 2025-01-01T00:00:00+09:00）で記述してください" >&2
  [ -n "$date_err" ] && rm -f "$date_err"
  continue
fi
[ -n "$date_err" ] && rm -f "$date_err"

if [ "$updated_epoch" -lt "{cutoff_epoch}" ]; then
  current_epoch=$(date +%s)
  days_diff=$(( (current_epoch - updated_epoch) / 86400 ))
  echo "STALE: $page_path (updated: $updated_str, ${days_diff} 日前)"
fi
```

### 4.3 検出結果の記録

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

---

## Phase 5: 孤児ページ検出

### 5.1 事前条件

Phase 2.3 で `index_read_ok="false"` と判定された場合、Phase 5 全体を skip し `n_orphans=0` のまま Phase 6 へ進みます。

### 5.2 index.md の「ページ一覧」テーブル解析

Phase 2.3 で取得した `index_content` から「ページ一覧」テーブルのリンクを抽出します。`./pages/` や `../pages/` 形式にも対応するよう正規表現を緩和し、pipefail を有効にして grep no-match を `|| true` で明示処理します:

```bash
# grep -o で 1 行複数リンクも個別抽出（sed greedy 問題の回避）
# pipefail + || true で grep no-match を IO error と区別
set -o pipefail

indexed_pages=$(printf '%s\n' "$index_content" \
  | { grep -oE '\]\((\.{0,2}\/?pages/[^)]+)\)' || true; } \
  | sed -E 's/^\]\(//; s/\)$//' \
  | sed -E 's|^\.{0,2}/?||' \
  | sort -u)

set +o pipefail

orphan_check_ok="true"
if [ -z "$indexed_pages" ]; then
  echo "WARNING: index.md のページ一覧テーブルから登録済みページを抽出できませんでした" >&2
  echo "  対処: index.md のテーブルフォーマット（| [title](pages/foo.md) | ... |）を確認してください" >&2
  echo "  影響: Phase 5.3 を skip します（全ページを orphan と誤検出しないため）" >&2
  orphan_check_ok="false"
fi

echo "orphan_check_ok=$orphan_check_ok"
```

### 5.3 孤児ページの判定

**事前条件**: Phase 5.2 で `orphan_check_ok="false"` の場合は本ステップを skip し、`n_orphans=0` のまま Phase 6 へ進みます。

`pages_list` は `.rite/wiki/` プレフィックス付きの相対パス（例: `.rite/wiki/pages/patterns/foo.md`）を持つため、`indexed_pages` と比較する前に `.rite/wiki/` プレフィックスを除去して正規化します。

LLM は両集合を比較し、差分（`pages_list_normalized \ indexed_pages`）を `n_orphans` として +1 し、`issues[]` に append します:

```
{
  "category": "orphan",
  "page": ".rite/wiki/pages/patterns/new-page.md",
  "detail": "index.md の「ページ一覧」テーブルに未登録"
}
```

---

## Phase 6: 欠落概念検出

Phase 6 は検出結果を 2 カテゴリに分けます:

- **`missing_concept`**: `ingested: true` の raw source のうち、対応ページも `sources.ref` 登録も `ingest:skip` 記録も存在しない真の欠落。`n_warnings` に加算（ブロッキング相当）
- **`unregistered_raw`**: `ingested: true` で `sources.ref` 未登録だが、`log.md` に `ingest:skip` 記録がある raw source。意図的に経験則化しなかった informational 指標（`n_warnings` 不加算）

### 6.0 `ingest:skip` 済み raw source の集合構築

Phase 6.2 の突合で参照する `skipped_refs` 集合を `log.md` から抽出します。`branch_strategy` に応じて読み出し元を切り替え、非ブロッキング契約として読み出し失敗時は空集合で継続します:

```bash
# 設計原則: Phase 2.3 の selective surface pattern と対称にし、stderr を
# 廃棄せず tempfile に退避して失敗時に可視化する。legitimate absence
# (fresh branch / log.md 未存在) と IO error (permission / blob 破損) を
# 区別する。branch_strategy 未知値は Phase 2.2 と対称に fail-fast する。

# signal-specific trap で tempfile orphan を防ぐ (canonical 4 行パターン)
log_err=""
awk_sort_err=""
_rite_wiki_lint_p60_cleanup() {
  # L-04 対応: 空引数ガード。BSD/macOS rm の一部実装で `rm -f ""` が
  # stderr に "cannot remove ''" を出すバージョンに対する defense-in-depth。
  # GNU rm は silent no-op だが、portable に統一する。
  [ -n "${log_err:-}" ] && rm -f "$log_err"
  [ -n "${awk_sort_err:-}" ] && rm -f "$awk_sort_err"
}
trap 'rc=$?; _rite_wiki_lint_p60_cleanup; exit $rc' EXIT
trap '_rite_wiki_lint_p60_cleanup; exit 130' INT
trap '_rite_wiki_lint_p60_cleanup; exit 143' TERM
trap '_rite_wiki_lint_p60_cleanup; exit 129' HUP

# mktemp 失敗時も silent 扱いせず WARNING で可視化する (Phase 2.2 と対称、
# 経験則「mktemp 失敗は silent 握り潰さず WARNING を可視化する」準拠)。
log_err=$(mktemp /tmp/rite-wiki-lint-p60-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile の mktemp に失敗しました。log.md 読み出しの詳細エラー情報は失われます" >&2
  log_err=""
}

branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

skipped_refs=""
log_content=""
# log_read_ok は 4 値 enum (unknown / true / absent / io_error)。
# - unknown: 初期値 (branch_strategy fail-fast 経路でのみ残る、後段未到達)
# - true:    log.md 読出成功
# - absent:  legitimate absence (fresh branch / ENOENT / blob not found) — skipped_refs="" は妥当
# - io_error: 真の IO error (permission / 破損 / wiki_branch race 等) — false positive リスクあり
# bash block 末尾で stdout に出力し、Phase 9.1 完了レポートで io_error 時に note 表示する。
log_read_ok="unknown"

# branch_strategy を case で検証 (Phase 2.2 と対称に未知値は fail-fast)
case "$branch_strategy" in
  separate_branch)
    if log_content=$(git show "${wiki_branch}:.rite/wiki/log.md" 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
    else
      rc=$?
      # legitimate absence 判別 (R-08 対応で wiki_branch 消失 race と区別):
      # 現行 git (2.x) で実際に出力される 2 pattern を primary として使用する:
      # - `path '...' does not exist in '...'`: blob not found (標準的な legitimate absence)
      # - `path '...' exists on disk, but not in '...'`: git show の path 対 ref 不整合
      # 加えて旧 git / 将来 wording 変更への safety margin として 2 pattern を残す:
      # - `Not a valid object name`: 古い git の revspec 不正メッセージ
      # - `fatal: invalid object name '<ref>:.rite/wiki/log.md'`: blob path 指定形式
      # これら 4 pattern のいずれにも match しない場合 (典型: blob path なしの
      # `fatal: invalid object name 'wiki'`) は wiki_branch 自体の race 消失として
      # io_error 扱いとする (Phase 1.3 後の race 検出)。
      if [ -n "$log_err" ] && [ -s "$log_err" ] && \
         grep -qE "does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:\\.rite/wiki/log\\.md'" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の git show に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | sed 's/^/  /' >&2
        echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
        echo "  対処: wiki branch の integrity / 権限を確認してください" >&2
      else
        # L-09 対応: stderr 退避失敗 + git show 失敗 sub-path で WARNING を出力
        # (primary 経路との diagnostic 対称性、silent に rc 値を失わない)。
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の git show に失敗し、かつ stderr 退避も失敗しました (rc=$rc、原因区別不能のため io_error 扱い)" >&2
        echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
        echo "  対処: /tmp の容量 / permission と wiki branch の integrity / 権限を確認してください" >&2
      fi
      log_content=""
    fi
    ;;
  same_branch)
    if log_content=$(cat .rite/wiki/log.md 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
    else
      rc=$?
      if [ -n "$log_err" ] && [ -s "$log_err" ] && grep -qE "No such file or directory|cannot open" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の cat に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | sed 's/^/  /' >&2
        echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
        echo "  対処: .rite/wiki/log.md の存在 / 権限を確認してください" >&2
      else
        # L-09 対応: 同上、sub-path WARNING 追加
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の cat に失敗し、かつ stderr 退避も失敗しました (rc=$rc、原因区別不能のため io_error 扱い)" >&2
        echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
        echo "  対処: /tmp の容量 / permission と .rite/wiki/log.md の存在 / 権限を確認してください" >&2
      fi
      log_content=""
    fi
    ;;
  *)
    # Phase 2.2 と対称: 未知値は fail-fast (log_read_ok は "unknown" のまま、fail-fast で後段未到達)
    echo "ERROR: 未知の branch_strategy: '$branch_strategy' (Phase 6.0、許容値: separate_branch / same_branch)" >&2
    exit 1
    ;;
esac

# log.md から ingest:skip レコードを抽出 (field 3 厳密一致、field 4 prefix 正規化)。
# R-03 対応: `if ! cmd; then rc=$?` の bash 既知バグ (! 否定で $? が常に 0) を回避するため、
# 2 文分割形式 (cmd; rc=$?) に書き換え。
if [ -n "$log_content" ]; then
  set -o pipefail
  # R-05 対応: awk_sort_err mktemp 失敗時も WARNING を可視化 (log_err と対称)。
  awk_sort_err=$(mktemp /tmp/rite-wiki-lint-p60-awk-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: awk/sort stderr 退避 tempfile の mktemp に失敗しました。pipeline の詳細エラー情報は失われます" >&2
    awk_sort_err=""
  }
  skipped_refs=$(printf '%s\n' "$log_content" \
    | awk -F'|' 'NF >= 4 {
        action=$3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", action)
        if (action == "ingest:skip") {
          target=$4
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
          sub(/^\.rite\/wiki\//, "", target)
          if (length(target) > 0) print target
        }
      }' 2>"${awk_sort_err:-/dev/null}" \
    | LC_ALL=C sort -u 2>>"${awk_sort_err:-/dev/null}")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WARNING: Phase 6.0 の awk/sort pipeline が失敗しました (rc=$rc)" >&2
    if [ -n "$awk_sort_err" ] && [ -s "$awk_sort_err" ]; then
      head -3 "$awk_sort_err" | sed 's/^/  /' >&2
    fi
    echo "  対処: awk / sort バイナリと /tmp の容量を確認してください" >&2
    skipped_refs=""
  fi
  set +o pipefail
fi

# 集合本体を stdout に出力する（Phase 6.2 の (b) 分岐で LLM が会話コンテキストに保持する）。
# bash 変数は Bash tool 呼び出し境界を超えると失われるため count だけでは不十分。
# delimiter 付きで本体を出力し、LLM が `---skipped_refs_begin---` と `---skipped_refs_end---`
# 間の行を集合として保持して Phase 6.2 の membership check に使う契約にする。
if [ -n "$skipped_refs" ]; then
  # awk での件数カウントは grep -c の IO error 吸収問題を回避する
  count=$(printf '%s\n' "$skipped_refs" | awk 'NF>0 {n++} END {print n+0}')
  echo "skipped_refs_count=$count"
  echo "---skipped_refs_begin---"
  printf '%s\n' "$skipped_refs"
  echo "---skipped_refs_end---"
else
  echo "skipped_refs_count=0"
  echo "---skipped_refs_begin---"
  echo "---skipped_refs_end---"
fi

# R-01 対応: log_read_ok を stdout 出力 (LLM が Phase 9.1 完了レポートで参照する契約)。
# bash 変数は Bash tool 呼び出し境界を超えて失われるため、4 値 enum 値を明示伝達する。
echo "log_read_ok=$log_read_ok"

# R-07 対応: 明示的 tempfile rm + 変数 reset (Phase 2.2 と対称、trap と冗長だが保守性向上)。
[ -n "$log_err" ] && rm -f "$log_err"
log_err=""
[ -n "$awk_sort_err" ] && rm -f "$awk_sort_err"
awk_sort_err=""
```

**非ブロッキング契約**: `log.md` 読み出し失敗時は `skipped_refs=""` のまま継続し、全件 `missing_concept` として計上されます（旧動作との下位互換）。ただし上記実装の通り **legitimate absence (fresh branch / 初回 lint / ENOENT / blob not found) は WARNING 抑制、真の IO error (permission denied / blob 破損 / wiki_branch race 等) は selective surface pattern で stderr に可視化** する。

**`log_read_ok` 4 値 enum による状態伝達**: bash 変数は Bash tool 呼び出し境界を超えて失われるため、`log_read_ok` を stdout に `log_read_ok={value}` 形式で出力して LLM の会話コンテキストに伝達する。値は以下の 4 種:

| 値 | 意味 | Phase 9.1 完了レポートでの扱い |
|----|------|---------------------------------|
| `unknown` | 初期値 (branch_strategy fail-fast で後段未到達のときのみ残る) | 表示しない (後段未実行) |
| `true` | log.md 読出成功 | 通常表示 (false positive なし) |
| `absent` | legitimate absence (fresh branch / ENOENT / blob not found) | 通常表示 (skip 記録なしは妥当) |
| `io_error` | 真の IO error (permission / 破損 / race) — skip 記録が読めず false positive リスクあり | ⚠️ note 表示「log.md 読出失敗により `missing_concept` 件数に false positive を含む可能性あり」 |

legitimate / IO error の判別は stderr 内容の pattern matching で行い、silent な同視を防ぐ。`wiki_branch` 自体の race 消失 (`fatal: invalid object name '<ref>'` — blob path 指定なし) は Phase 1.3 後の race として `io_error` に分類する (R-08 対応)。

**LLM による集合保持の契約**: 上記 bash block の stdout に `---skipped_refs_begin---` / `---skipped_refs_end---` で挟まれた行を LLM が会話コンテキストに保持し、Phase 6.2 の (b) 分岐判定材料とする。行数が 0 件でも begin/end marker は必ず出力される（集合構築ステップが実行されたことの positive confirmation）。

### 6.1 Ingest 済み Raw Source の列挙

Phase 2.2 で収集した `raw_list` から、frontmatter の `ingested: true` を持つファイルを抽出します。`ingested` フィールド不在は `false` 扱い（未統合）として明示します:

```bash
# 各 raw_file について:
raw_content=$(git show "${wiki_branch}:$raw_file" 2>/dev/null || cat "$raw_file" 2>/dev/null)

# ingested: true / false / 未設定を明示処理
ingested=$(printf '%s' "$raw_content" | awk '/^ingested:/ { gsub(/^ingested:[[:space:]]*"?|"$/, ""); print; exit }')
ingested="${ingested:-false}"  # 未設定は false 扱い

raw_title=$(printf '%s' "$raw_content" | awk '/^title:/ { gsub(/^title:[[:space:]]*"?|"$/, ""); print; exit }')

if [ "$ingested" = "true" ]; then
  # Phase 6.2 の対応ページ確認へ
  :
fi
```

### 6.2 対応ページの存在確認と 3 分岐

`raw_list` のパスは Phase 2.2 で `.rite/wiki/` プレフィックス付き（例: `.rite/wiki/raw/reviews/20260410T...md`）で取得されているため、Phase 5.2 と同じ prefix 正規化を適用してから `sources[].ref` および Phase 6.0 の `skipped_refs` と比較します。`sources[].ref` は `raw/reviews/...` 形式（template.md の `{source_ref}` 規約参照）のため、両辺から `.rite/wiki/` を除去して突合します:

1. `pages_list` の各 Wiki ページ本文を `git show` / `cat` で取得し、frontmatter `sources[].ref` を抽出して全ページ分を集約し `all_source_refs` として保持する（この集合は step 3(a) で参照される。**重要**: 本集合は `indexed_pages` とは別物。`indexed_pages` は Phase 5.2 で `index.md` の「ページ一覧」テーブルから抽出したページパス集合であり `sources[].ref` を含まない）
2. `raw_list` の各 Raw Source について `.rite/wiki/` プレフィックスを除去した相対パス（`raw/reviews/...`）を計算
3. 相対パスを以下の優先順で 3 分岐に振り分ける:
   - **(a) 登録済み**: step 1 の `all_source_refs` のいずれかに含まれる → 何もしない（健全）
   - **(b) 未登録だが skip 記録あり**: Phase 6.0 の `skipped_refs` 集合に含まれる → Phase 6.3 の `unregistered_raw` として記録
   - **(c) 真の欠落**: 上記いずれにも該当しない → LLM が Raw Source 本文を読み経験則として価値がある内容か判定した上で Phase 6.3 の `missing_concept` として記録（単なるエラーログや空コメントは除外）

**`skipped_refs` 集合の参照方法**: Phase 6.0 の bash block 終了後、LLM は stdout から `---skipped_refs_begin---` と `---skipped_refs_end---` で囲まれた行を抽出して会話コンテキストに集合として保持する。ファイルパスの比較は両辺を `raw/{type}/{filename}` 形式に正規化してから完全一致で判定する（`.rite/wiki/` プレフィックスを両辺から除去、log.md 記録時のプレフィックス有無の暗黙的 drift を吸収）。

### 6.3 検出結果の記録

**真の欠落 (missing_concept)**:

```
{
  "category": "missing_concept",
  "raw_source": ".rite/wiki/raw/reviews/20260410T...md",
  "title": "PR #123 review findings",
  "detail": "Ingest 済みだが対応ページも ingest:skip 記録も存在しない"
}
```

`n_missing_concept` を +1。

**未登録 raw (unregistered_raw)**:

```
{
  "category": "unregistered_raw",
  "raw_source": ".rite/wiki/raw/reviews/20260417T...md",
  "title": "cycle 5 final mergeable 確認のみ",
  "detail": "ingest:skip 済みで経験則化されなかった raw（log.md に skip 記録あり）"
}
```

`n_unregistered_raw` を +1（`n_warnings` には加算されない informational カウンタ）。

---

## Phase 7: 壊れた相互参照検出

### 7.1 ページ本文の Markdown リンク抽出

各 Wiki ページの本文から Markdown リンク `[text](path)` を抽出します。画像リンク（`![alt](path)` の `!` prefix）は対象外とし、pipefail を有効化して grep no-match を明示処理します:

```bash
set -o pipefail

# 画像リンク `![alt](path)` を先に sed で除去し、その後に通常リンク `[text](path)` を抽出
# これにより画像リンクの path が broken ref として false positive になることを防ぐ
# アンカー (#section) も除去してから pages_list と突合する
page_links=$(printf '%s' "$page_content" \
  | sed -E 's/!\[[^]]*\]\([^)]*\)//g' \
  | { grep -oE '\]\([^)]+\)' || true; } \
  | sed -E 's/^\]\(//; s/\)$//' \
  | sed -E 's/#.*$//')

set +o pipefail
```

### 7.2 相互参照の妥当性判定

抽出した各リンクについて以下を判定します:

| リンク種別 | 判定方法 |
|----------|---------|
| **相対パス (`./pages/...`, `../pages/...`, `pages/...`)** | アンカー (`#section`) を除去してから `pages_list_normalized` に実在するか確認 |
| **絶対パス (`/pages/...`)** | 対象外（HTTP URL 等の可能性） |
| **外部 URL (`http://...`, `https://...`)** | 対象外（lint 対象外） |
| **アンカーのみ (`#section`)** | 対象外（同一ファイル内参照） |
| **Raw Source 参照 (`raw/...`)** | `raw_list_normalized` に実在するか確認 |

**アンカー除去ルール**: 相対パスリンクの `#...` 部分を切り落としてから実在確認を行います（例: `pages/foo.md#section` → `pages/foo.md` として照合）。

**URL 内の `)` を含むリンク**: 現行の `[^)]+` regex では検出対象外とする既知の限界。実運用では Wiki 内で括弧付き URL を使わない規約で回避します。

壊れた参照を検出したら `issues[]` に append し、`n_broken_refs` を +1 します:

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
| 詳細 | `contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` |

### 8.2 書き込み先パスの決定 (Issue #547 で worktree 化)

Issue #547 以降、`separate_branch` 戦略では `.rite/wiki-worktree/` worktree を経由するため、`stash + checkout` による dev ブランチの HEAD 移動は発生しません。`branch_strategy` の値に応じて書き込み先パスを決定するだけです:

```bash
branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "same_branch" ]; then
  log_path=".rite/wiki/log.md"
elif [ "$branch_strategy" = "separate_branch" ]; then
  log_path=".rite/wiki-worktree/.rite/wiki/log.md"
else
  echo "ERROR: 未知の branch_strategy: '$branch_strategy'" >&2
  exit 1
fi
echo "log_path=$log_path"
```

### 8.3 書き込み手順

1. Edit ツールで `{log_path}` (Phase 8.2 の bash で出力された `log_path` 値をリテラル substitute) に Phase 8.1 の log.md 追記行を **append-only** で追加する。**注意**: シェル変数 `$log_path` は Bash ツール呼び出し境界を超えると失われ、Edit ツールはシェル変数を解釈しない。Phase 8.2 の `echo "log_path=..."` 出力を会話文脈から拾って literal value で置換すること
2. 以下の bash ブロックで commit + push する

```bash
# Phase 8.3: log.md 追記後の commit
# plugin_root の inline 解決 (lint.md には専用解決 Phase が存在しないため)
# Reference: ../../references/plugin-path-resolution.md#inline-one-liner-for-command-files
branch_strategy="{branch_strategy}"
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "WARNING: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}'). log.md 追記の commit を skip します (非ブロッキング契約)" >&2
  exit 0
fi
log_entry="{log_entry}"  # Phase 8.1 で生成した log.md 追記行

commit_msg="docs(wiki): lint report — ${log_entry}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # worktree 経由で commit + push
  # 2>&1 は付けない: wiki-worktree-commit.sh は構造化 status 行 (`[wiki-worktree-commit] committed=...`)
  # を stdout、WARNING / ERROR を stderr で出力する責務分離設計。2>&1 で mix すると将来の parser
  # regression を生む。stderr は端末に直接流して観測性を保つ。
  commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --message "$commit_msg")
  commit_rc=$?
  echo "$commit_out"
  if [ "$commit_rc" -ne 0 ] && [ "$commit_rc" -ne 4 ]; then
    echo "WARNING: wiki-worktree-commit.sh が失敗しました (rc=$commit_rc)。log.md 追記は非ブロッキングのため継続します" >&2
  fi
elif [ "$branch_strategy" = "same_branch" ]; then
  # git add / commit の stderr を tempfile に捕捉 (silent failure 防止):
  # pre-commit hook / gpg sign / author config / permission / index lock 等の根本原因を可視化する
  add_err=$(mktemp /tmp/rite-lint-add-err-XXXXXX 2>/dev/null) || add_err=""
  commit_err=$(mktemp /tmp/rite-lint-commit-err-XXXXXX 2>/dev/null) || commit_err=""
  trap 'rm -f "${add_err:-}" "${commit_err:-}"' EXIT INT TERM HUP

  if ! git add .rite/wiki/log.md 2>"${add_err:-/dev/null}"; then
    echo "WARNING: git add .rite/wiki/log.md に失敗しました" >&2
    if [ -n "$add_err" ] && [ -s "$add_err" ]; then
      head -3 "$add_err" | sed 's/^/  /' >&2
    fi
    echo "  対処: index lock / permission denied / path error のいずれかを確認してください" >&2
    exit 0
  fi

  if ! git commit -m "$commit_msg" 2>"${commit_err:-/dev/null}"; then
    echo "WARNING: log.md のコミットに失敗しました" >&2
    if [ -n "$commit_err" ] && [ -s "$commit_err" ]; then
      head -3 "$commit_err" | sed 's/^/  /' >&2
    fi
    echo "  対処: pre-commit hook / gpg sign / author config / permission のいずれかを確認してください" >&2
  fi

  [ -n "$add_err" ] && rm -f "$add_err"
  [ -n "$commit_err" ] && rm -f "$commit_err"
  trap - EXIT INT TERM HUP
fi
# 非ブロッキング契約: 失敗しても exit 0 で継続
```

**`append-only` の原則**: log.md の既存行を変更してはいけません。必ず末尾に新規行を追加します。

**書き込み失敗時**: 検出結果は既に stdout に表示済みのため、log.md 追記失敗は WARNING を出して **exit 0 で継続**します（非ブロッキング契約維持）。

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
- 欠落概念: {n_missing_concept} 件{log_read_ok_note}
- 未登録 raw（skip 済）: {n_unregistered_raw} 件（informational、`n_warnings` 不加算）
- 壊れた相互参照: {n_broken_refs} 件

{log_read_ok_warning}

検出詳細:
{issues_list_formatted}

次のステップ:
- 矛盾は手動で該当ページを統合してください
- 陳腐化ページは /rite:wiki:ingest で新しい Raw Source を統合するか、手動で updated フィールドを更新してください
- 孤児ページは index.md に追加するか、不要なら削除してください
- 欠落概念は /rite:wiki:ingest で該当 Raw Source を再処理してください
- 未登録 raw（skip 済）は意図的な `ingest:skip` なら放置で OK。skip 記録を取り消して経験則化したい場合は /rite:wiki:ingest で再処理してください
- 壊れた相互参照は該当ページを手動で修正してください
```

**`{log_read_ok_note}` / `{log_read_ok_warning}` 展開ルール** (R-01 対応、log_read_ok 4 値 enum に基づく):

LLM は Phase 6.0 bash block の stdout から `log_read_ok={value}` を読み取り、値に応じて以下を展開する:

| `log_read_ok` 値 | `{log_read_ok_note}` | `{log_read_ok_warning}` |
|-----------------|----------------------|--------------------------|
| `true` | 空文字列 | 空文字列 |
| `absent` | 空文字列 | 空文字列 |
| `io_error` | ` ⚠️ (log.md 読出失敗により false positive を含む可能性あり)` | `⚠️ log.md 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。wiki branch の integrity / 権限を確認して /rite:wiki:lint を再実行してください。` |
| `unknown` | (この状態では Phase 9.1 に到達しない、branch_strategy fail-fast で exit 1 済み) | 空文字列 |

**空行処理ルール (単一ルールに統一)**: template は `{log_read_ok_warning}` の**直前**に空行を 1 行持つ (前段の「壊れた相互参照」行との区切り)。`{log_read_ok_warning}` が空文字列の場合は **その直前の空行もまとめて省略**し、非空 (`io_error` のみ) の場合は **空行を残したまま値をそのまま埋め込む**。

**展開例** (前段「壊れた相互参照: {n} 件」の直後):

- `log_read_ok=true` / `absent`:
  ```
  - 壊れた相互参照: 2 件
  ↑ ここで「検出詳細:」に続く (空行なし)
  ```

- `log_read_ok=io_error`:
  ```
  - 壊れた相互参照: 2 件

  ⚠️ log.md 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。wiki branch の integrity / 権限を確認して /rite:wiki:lint を再実行してください。
  ↑ 空行を 1 行残して警告ブロックを表示 (前段と区切る)
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

### 未登録 raw（skip 済）
- raw/reviews/20260417T...md (cycle 5 final mergeable 確認のみ)

### 壊れた相互参照
- pages/heuristics/a.md → ../patterns/deleted.md
```

### 9.2 `--auto` モードの出力

Ingest 完了直後に呼ばれる場合、出力は最小化されます:

```
Lint: contradictions={n_contradictions}, stale={n_stale}, orphans={n_orphans}, missing_concept={n_missing_concept}, unregistered_raw={n_unregistered_raw}, broken_refs={n_broken_refs}
```

「検出件数が全て 0」とは **6 フィールド全部** の合計が 0 であること、すなわち `n_contradictions + n_stale + n_orphans + n_missing_concept + n_unregistered_raw + n_broken_refs == 0` を意味する。この場合のみ stdout を空にして exit 0。それ以外（いずれか 1 フィールドでも非 0）は 1 行を出力する。`unregistered_raw` は `n_warnings` に加算されないため、`n_unregistered_raw > 0` だけで `missing_concept` と他 4 カテゴリが 0 の場合も「0 ではない」と判定され、この 1 行を出力する（ingest 側が parse できるように常に 6 フィールドを揃える）。

### 9.3 exit code

- **常に exit 0**: 検出件数・事前チェック失敗・ブランチ読取失敗のいずれも非ブロッキング
- **例外 (`exit 1` fail-fast)**: Phase 2.2 / Phase 6.0 / Phase 8.2 の `branch_strategy` 未知値 (3 箇所で同型、設定ミスの silent 通過防止)
- 内部 bash 構文エラー等の unrecoverable error のみ非 0 exit となる可能性あり

---

## エラーハンドリング

| エラー | 対処 | Phase |
|--------|------|-------|
| `wiki.enabled: false` | 早期 return（exit 0 + 警告） | Phase 1.1 |
| GNU date 非互換環境 | Phase 4 skip（exit 0 + WARNING） | Phase 1.2 |
| Wiki 未初期化 | `/rite:wiki:init` を案内（exit 0 + 警告） | Phase 1.3 |
| `git ls-tree` 失敗 | WARNING + `pages_list=""`/`raw_list=""` で継続（exit 0） | Phase 2.2 |
| `branch_strategy` が未知の値 (Phase 2.2 / Phase 6.0 / Phase 8.2 の 3 箇所) | **exit 1 で fail-fast**（設定ミスの silent 通過防止、3 箇所で同型） | Phase 2.2 / Phase 6.0 / Phase 8.2 |
| `index.md` 読出失敗 | WARNING + Phase 5 skip（exit 0） | Phase 2.3 |
| `log.md` 読出失敗 (legitimate absence: fresh branch / ENOENT / blob not found) | WARNING 抑制 + `skipped_refs=""` + `log_read_ok=absent`（exit 0） | Phase 6.0 |
| `log.md` 読出失敗 (真の IO error: permission / 破損 / wiki_branch race) | WARNING + `skipped_refs=""` + `log_read_ok=io_error` + Phase 9.1 完了レポートで false positive note 表示（exit 0） | Phase 6.0 |
| awk/sort pipeline 失敗 | WARNING + `skipped_refs=""` で継続（exit 0） | Phase 6.0 |
| `date -d` パース失敗 | 該当ページを skip し WARNING を stderr に出力（`n_stale` 非加算） | Phase 4.2 |
| `grep` no-match（indexed_pages 空） | WARNING + Phase 5 skip（全ページ orphan 誤検出防止） | Phase 5.2 |
| 処理対象 0 件 | Phase 3-7 を skip し Phase 9 で「検査対象なし」表示 | Phase 2.2 末尾 |
| log.md 追記失敗 | WARNING + exit 0 で継続（検出結果は stdout に表示済み） | Phase 8 |
