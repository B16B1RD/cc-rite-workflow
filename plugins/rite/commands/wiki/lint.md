---
description: Wiki Lint — Wiki の品質チェック（5 ブロッキング: 矛盾・陳腐化・孤児・欠落概念・壊れた相互参照 + 1 informational: 未登録 raw）
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

- **非ブロッキング契約**: 検出件数・事前チェック失敗・ブランチ読取失敗にかかわらず、本コマンドは **原則 exit 0** で終了する。例外は (a) `{branch_strategy}` が未知の値だった場合の fail-fast（Phase 2.2 / Phase 6.0 / Phase 6.2 / Phase 8.2 / Phase 8.3 の 5 箇所で同型）、および (b) Phase 1.1 / Phase 1.3 の `{mode}` placeholder 残留検知 fail-fast（2 箇所で同型、Claude substitute 忘れを silent 通過させない）で、いずれも設定ミス / 実装ミスを silent に通過させないための設計判断である
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

# F-09 (PR #564 cycle 8 F-09) 対応: silent default の撤廃と fail-fast 設計への統一。
# Phase 2.2/6.0/6.2/8.2/8.3 では `case *) fail-fast` で未知値を reject する設計に統一済みだが、
# Phase 1.1 だけ silent default `${branch_strategy:-separate_branch}` で「separate_branch 扱いで
# Phase 8.2 へ到達したが実は未設定」という経路を許容していた。fail-fast 設計と対称化する。
# - 空文字列: rite-config.yml に branch_strategy が未設定 → WARNING + default (legitimate fallback)
# - "separate_branch" / "same_branch": 正常値 → そのまま採用
# - その他 (未知値): fail-fast + ERROR (rite-config.yml の typo 等を silent に通さない)
case "$branch_strategy" in
  "")
    # legitimate fallback: rite-config.yml に branch_strategy キーがない (default 運用)
    echo "WARNING: rite-config.yml に wiki.branch_strategy が未設定のため 'separate_branch' を使用します" >&2
    echo "  対処: 意図しない場合は rite-config.yml の wiki.branch_strategy を明示的に設定してください" >&2
    branch_strategy="separate_branch"
    ;;
  separate_branch|same_branch)
    # 正常値、そのまま採用
    :
    ;;
  *)
    echo "ERROR: rite-config.yml の wiki.branch_strategy に未知の値: '$branch_strategy'" >&2
    echo "  受理値: 'separate_branch' / 'same_branch'" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください (typo の可能性)" >&2
    echo "[CONTEXT] LINT_BRANCH_STRATEGY_UNKNOWN=1; value=$branch_strategy" >&2
    exit 1
    ;;
esac

echo "wiki_enabled=$wiki_enabled"
echo "branch_strategy=$branch_strategy"
echo "wiki_branch=$wiki_branch"
```

**Wiki が無効の場合**: 早期 return:

```bash
# --auto モードでは 6 フィールドの 1 行を必ず出力する (stdout 空は ingest 側 Phase 8.3 step 3 で
# 「Lint 実行失敗」として扱われる unreachable 経路のため)。
# mode は Phase 1.4 で解析されるが、本経路は Phase 1.1 直後の早期 return のため引数文字列を直接 scan する。
# Claude placeholder {mode} 残留 fail-fast gate (glob pattern 版。fix.md / review.md の
# placeholder 残留 gate は exact-string match (`case "$review_file_path" in "{review_file_path_from_phase_1_0_1}"...)`)
# を採用しているが、本 site では glob pattern `"{"*"}"` を採用している。両者の approach は異なるが
# 検出目的 (「literal 残留」= Claude が substitute し忘れて `{...}` のままの状態) は共通):
# 変数代入 mode="{mode}" のみを substitute 対象とし、case pattern `"{"*"}"` で placeholder 残留形状を検出する。
# 正常時: mode="--auto" → "--auto" は "{"*"}" にマッチしない → gate 通過
# 未置換時: mode="{mode}" → "{mode}" は "{"*"}" にマッチ → exit 1
# trade-off: glob 版は `{foo}` を legitimate 値とする edge case (Template 系プロジェクトで `{var}` 含みの
# 引数を lint mode として渡した場合 — 現状 /rite:wiki:lint の args 仕様としてはあり得ない) で false positive
# 発火リスクがあるが、mode の値域が `--auto` のみなので本 site では許容する。将来 mode 値域が拡張される
# 場合は fix.md / review.md 型の exact-string match に揃えること。
mode="{mode}"
case "$mode" in
  "{"*"}")
    echo "ERROR: Phase 1.1 早期 return の {mode} placeholder が literal substitute されていません" >&2
    echo "  Claude は lint skill 呼び出し時の args 文字列 (--auto / 空) を literal で置換する必要があります" >&2
    exit 1
    ;;
esac
if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  echo "Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0"
else
  echo "Wiki 機能が無効です（wiki.enabled: false）。" >&2
  echo "有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki:init を実行してください。" >&2
fi
exit 0
```

{mode} placeholder には lint skill 起動時の引数文字列 (`--auto` 等) を Claude が literal substitute する。

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

```bash
# --auto モードでは 6 フィールドの 1 行を必ず出力する (Phase 1.1 と対称、ingest 側 Phase 8.3 step 3 で
# stdout 空を「Lint 実行失敗」として扱う silent false positive を防ぐ)。
# Claude placeholder {mode} 残留 fail-fast gate (canonical pattern、Phase 1.1 と対称):
mode="{mode}"
case "$mode" in
  "{"*"}")
    echo "ERROR: Phase 1.3 早期 return の {mode} placeholder が literal substitute されていません" >&2
    echo "  Claude は lint skill 呼び出し時の args 文字列 (--auto / 空) を literal で置換する必要があります" >&2
    exit 1
    ;;
esac
if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  echo "Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0"
else
  echo "Wiki が初期化されていません。先に /rite:wiki:init を実行してください。" >&2
fi
exit 0
```

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
# trap + cleanup パターンの canonical 説明は ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code、race window 回避、rc=$? capture、${var:-} safety、関数契約)
# 空引数ガード variant (BSD/macOS rm 対応) は同ファイルの "BSD/macOS rm の `rm -f ""` 対応" セクション参照。
ls_err=""
_rite_wiki_lint_phase2_cleanup() {
  # BSD/macOS rm の空引数対応 (Phase 6.0 と対称化、portable variant)
  [ -n "${ls_err:-}" ] && rm -f "$ls_err"
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
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (Phase 2.2)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（非ブロッキング契約の唯一の例外、5 箇所で同型）" >&2
    exit 1
    ;;
esac

[ -n "$ls_err" ] && rm -f "$ls_err"

# F-15 対応: 空文字列 guard を追加。
# 旧実装 `printf '%s\n' ""` は blank line 1 行を emit するため、stdout が `\n---\n\n` となり
# Phase 6.2 HEREDOC の `{pages_list}` 契約 (「先頭から `---` 行より前の行」) で LLM が
# blank line 1 行を「pages_list=1 件 (空文字列)」と誤解釈する余地があった。
# `[ -n ... ] && printf` で空時に何も emit しないよう変更し、後続 phase は「`---` の前後で空集合」を
# decisive に判別できる。
[ -n "$pages_list" ] && printf '%s\n' "$pages_list"
echo "---"
[ -n "$raw_list" ] && printf '%s\n' "$raw_list"
```

LLM は stdout から `pages_list` と `raw_list` を会話コンテキストに保持します。`pages_list` と `raw_list` が両方空なら、Phase 3-7 をスキップし Phase 9 に進みます（検出結果なしの完了レポート）。

### 2.3 index.md の読み込み

`.rite/wiki/index.md` の内容を `index_content` として会話コンテキストに保持します。失敗時は非ブロッキング契約に従い warning + Phase 5（孤児検出）skip で継続します:

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

index_read_ok="true"
# F-05 対応: mktemp 失敗時の loud WARNING (Pattern 3 規範準拠、Phase 6.0 / 6.2 と対称化)。
# silent fallback では `[ -s "$index_err" ]` check が必ず false になり、index.md の真の IO エラーが
# silent に握りつぶされて pattern match が実行不能 → index_read_ok="false" 経路に倒れ、
# Phase 5 (孤児ページ検出) が skip → n_orphans=0 のまま Phase 6 へ進み、**本来 orphan となるページが
# n_orphans に加算されない** false negative に倒れる (PR #564 2nd-review F-05 対応、cycle 8 で修正)。
index_err=$(mktemp /tmp/rite-wiki-lint-index-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (index_err) の mktemp に失敗しました。index.md 読出の詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり io_error 側に倒します (孤児検出 Phase 5 が skip される可能性)" >&2
  index_err=""
}

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

> **⚠️ 以下のスニペットは LLM が各ページに対して for-loop 内で実行することを前提**とします。`continue` は enclosing loop の次 iteration へ進む制御です。`{cutoff_epoch}` と `{wiki_branch}` は LLM が Phase 1.1 / 上の bash block の出力値を literal substitute してください (Phase 2.2 / 2.3 / 6.0 / 6.2 / 8.2 と同じ literal substitute 方式)。F-13 word-split 修正 (Phase 6.2) と同型に `while IFS= read -r page_path; do ...` 形式を推奨。ループ骨組み例:
>
> ```bash
> wiki_branch="{wiki_branch}"  # F-03 対応: Phase 1.1 の出力値を LLM が literal substitute する (他 5 Phase と対称化)
> case "$wiki_branch" in
>   "{"*"}")
>     echo "ERROR: Phase 4.2 の {wiki_branch} placeholder が literal substitute されていません" >&2
>     exit 1 ;;
> esac
> while IFS= read -r page_path; do
>   page_content=$(git show "${wiki_branch}:$page_path" 2>/dev/null || cat "$page_path" 2>/dev/null)
>   # 以下のスニペット
> done <<< "$pages_list"
> ```

```bash
updated_str=$(printf '%s' "$page_content" | awk '/^updated:/ { gsub(/^updated:[[:space:]]*"?|"$/, ""); print; exit }')

if [ -z "$updated_str" ]; then
  echo "WARNING: $page_path に updated フィールドが存在しません。陳腐化判定を skip します" >&2
  continue
fi

# F-05 対応: mktemp 失敗時の silent fallback `|| date_err=""` を loud WARNING に置き換え。
# bash-cross-boundary-state-transfer.md#pattern-3-legitimate-absence-vs-io-error-classification
# の canonical 例 (mktemp loud WARNING 規範) に準拠 (Phase 6.0 / 6.2 と対称化)。
# /tmp 枯渇 / inode 枯渇 / readonly filesystem の根本原因が operator から不可視になる経路を遮断する。
date_err=$(mktemp /tmp/rite-wiki-lint-date-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (date_err) の mktemp に失敗しました。$page_path の date エラー詳細は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり、日付パース失敗の根本原因が不可視になります" >&2
  date_err=""
}
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
  | LC_ALL=C sort -u)
# Phase 6.0 の sort -u と locale 指定を対称化 (PR #564 レビュー LOW #8 対応)。
# de-duplication 目的で locale 依存は不要のため LC_ALL=C で固定。

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
# trap + cleanup パターンの canonical 説明は ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code、race window 回避、rc=$? capture、${var:-} safety、関数契約)
# 空引数ガード variant (BSD/macOS rm 対応) は同ファイルの "BSD/macOS rm の `rm -f ""` 対応" セクション参照。
log_err=""
awk_sort_err=""
_rite_wiki_lint_phase60_cleanup() {
  # L-04 対応: BSD/macOS rm の空引数対応 (portable variant)
  [ -n "${log_err:-}" ] && rm -f "$log_err"
  [ -n "${awk_sort_err:-}" ] && rm -f "$awk_sort_err"
}
trap 'rc=$?; _rite_wiki_lint_phase60_cleanup; exit $rc' EXIT
trap '_rite_wiki_lint_phase60_cleanup; exit 130' INT
trap '_rite_wiki_lint_phase60_cleanup; exit 143' TERM
trap '_rite_wiki_lint_phase60_cleanup; exit 129' HUP

# PR #564 F-07 対応: skipped_refs 空継続時の「影響」文言を単一源として helper 化。
# 従来 4 箇所 (Phase 6.0 sub-path helper / primary git show / primary cat / awk/sort post-loop) で
# literal duplicate していた文言を本 helper に集約し、文言変更時の 4 箇所 drift リスクを排除する。
_rite_log_read_impact_advice() {
  echo "  影響: skipped_refs を空として継続するため、skip 済み raw が誤って missing_concept に計上される可能性あり" >&2
}

# L-09 対応 sub-path (stderr 退避失敗 + tool 失敗の複合経路) の共通 helper。
# separate_branch (git show) と same_branch (cat) で tool 名と remedy target
# のみ異なる 3 行 WARNING を DRY 化する (PR #564 レビュー推奨 #4 由来)。
# 引数: $1=tool_desc (例: "git show") / $2=remedy_target (例: "wiki branch の integrity / 権限") / $3=rc
_rite_log_read_sub_path_warning() {
  local tool_desc="$1"
  local remedy_target="$2"
  local rc="$3"
  echo "WARNING: .rite/wiki/log.md の ${tool_desc} に失敗し、かつ stderr 退避も失敗しました (rc=${rc}、原因区別不能のため io_error 扱い)" >&2
  _rite_log_read_impact_advice
  echo "  対処: /tmp の容量 / permission と ${remedy_target} を確認してください" >&2
}

# F-03 (PR #564 cycle 8 F-03) 対応: 3 行 loud emit (Pattern 3 規範準拠、Phase 2.3 / 4.2 / 6.2 / 8.3 と対称化)。
# bash-cross-boundary-state-transfer.md#pattern-3-legitimate-absence-vs-io-error-classification
# は本 Phase 6.0 を canonical 参照実装として明記しているため、規範の 3 行 loud emit
# (WARNING + 対処 + 影響) と非対称のままだと、reference 読者が Phase 6.0 を真似た
# 規範違反コードを書く経路を生む。
log_err=$(mktemp /tmp/rite-wiki-lint-p60-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (log_err) の mktemp に失敗しました。log.md 読み出しの詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: stderr pattern match が実行不能になり io_error 側に倒れ、false positive note が発火します (Phase 9.1 完了レポートで io_error の note が常に表示される regression)" >&2
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
# 本パターンの canonical 定義は references/bash-cross-boundary-state-transfer.md#pattern-1-multi-value-enum-via-key-value-stdout 参照。
log_read_ok="unknown"

# LC_ALL=C で locale を固定 (PR #564 F-05 対応、Phase 6.2 と対称)。ja_JP.UTF-8 等で git/cat の
# stderr メッセージが gettext 経由で翻訳されると、下記 legitimate absence 判別 regex (例:
# `does not exist`, `No such file or directory`) と不一致になり legitimate absence が io_error
# に誤分類される silent regression を防ぐ。各コマンドに `LC_ALL=C` prefix を付ける方式で実装する
# (bash block 冒頭で一括 export すると Phase 6.2 等の他 block に影響するため、最小 scope で固定)。
# branch_strategy を case で検証 (Phase 2.2 と対称に未知値は fail-fast)
case "$branch_strategy" in
  separate_branch)
    if log_content=$(LC_ALL=C git show "${wiki_branch}:.rite/wiki/log.md" 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      # git show 成功時でも stderr に ambiguous ref hint 等が残ることがあるため surface する
      # (Phase 2.3 の index_read_ok 成功経路と対称化、PR #564 レビュー LOW #6 対応)。
      # selective surface pattern: 成功 exit code でも warning を握りつぶさない。
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | sed 's/^/  WARNING(git hint): /' >&2
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
        _rite_log_read_impact_advice
        echo "  対処: wiki branch の integrity / 権限を確認してください" >&2
      else
        # L-09 対応: stderr 退避失敗 + git show 失敗 sub-path で WARNING を出力
        # (primary 経路との diagnostic 対称性、silent に rc 値を失わない)。
        # 文言は _rite_log_read_sub_path_warning helper に集約 (DRY)。
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "git show" "wiki branch の integrity / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
  same_branch)
    # LC_ALL=C で locale を固定 (PR #564 F-05 対応): cat は gettext 対応のため ja_JP.UTF-8 下では
    # 「そのようなファイルやディレクトリはありません」を emit し、下記 grep regex `No such file or
    # directory|cannot open` と不一致 → legitimate absence が io_error に誤分類される silent regression
    # を防ぐ。git show 側も同じ理由で LC_ALL=C で統一 (本 PR では cat 側のみ影響あるが defense-in-depth)。
    if log_content=$(LC_ALL=C cat .rite/wiki/log.md 2>"${log_err:-/dev/null}"); then
      log_read_ok="true"
      # selective surface pattern: cat は通常 stderr を成功経路で emit しないが、separate_branch
      # 成功経路 (直上 git show) と対称化するため同型 surface を配置する (Issue #571)。
      # BSD cat 等が diagnostic を emit する稀なケースで silent に warning を握りつぶさないための
      # defense-in-depth であり、LC_ALL=C による locale 固定との併用で対称性を完成させる。
      [ -n "$log_err" ] && [ -s "$log_err" ] && head -3 "$log_err" | sed 's/^/  WARNING(cat hint): /' >&2
    else
      rc=$?
      if [ -n "$log_err" ] && [ -s "$log_err" ] && grep -qE "No such file or directory|cannot open" "$log_err"; then
        log_read_ok="absent"
      elif [ -n "$log_err" ] && [ -s "$log_err" ]; then
        log_read_ok="io_error"
        echo "WARNING: .rite/wiki/log.md の cat に失敗しました (rc=$rc)" >&2
        head -3 "$log_err" | sed 's/^/  /' >&2
        _rite_log_read_impact_advice
        echo "  対処: .rite/wiki/log.md の存在 / 権限を確認してください" >&2
      else
        # L-09 対応: 同上、separate_branch と同じ helper に集約
        log_read_ok="io_error"
        _rite_log_read_sub_path_warning "cat" ".rite/wiki/log.md の存在 / 権限" "$rc"
      fi
      log_content=""
    fi
    ;;
  *)
    # Phase 2.2 と対称: 未知値は fail-fast (log_read_ok は "unknown" のまま、fail-fast で後段未到達)
    # 5 箇所 (Phase 2.2 / Phase 6.0 / Phase 6.2 / Phase 8.2 / Phase 8.3) で同型診断に統一 (PR #564 レビュー MEDIUM #3 対応)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (Phase 6.0)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（非ブロッキング契約の唯一の例外、5 箇所で同型）" >&2
    exit 1
    ;;
esac

# log.md から ingest:skip レコードを抽出 (field 3 厳密一致、field 4 prefix 正規化)。
# R-03 対応: `if ! cmd; then rc=$?` の bash 既知バグ (! 否定で $? が常に 0) を回避するため、
# 2 文分割形式 (cmd; rc=$?) に書き換え。
if [ -n "$log_content" ]; then
  set -o pipefail
  # R-05 対応: awk_sort_err mktemp 失敗時も WARNING を可視化 (log_err と対称)。
  # PR #564 cycle 11 F-02 対応: 3 行 loud emit (WARNING + 対処 + 影響) に拡張し、Phase 6.0 log_err / Phase 6.2
  # sort_err / page_err 等の他 mktemp 失敗 WARNING および bash-cross-boundary-state-transfer.md Pattern 3
  # canonical の 3 行規範と対称化する。
  awk_sort_err=$(mktemp /tmp/rite-wiki-lint-p60-awk-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: awk/sort stderr 退避 tempfile の mktemp に失敗しました" >&2
    echo "  対処: /tmp の容量 / inode 枯渇 / read-only filesystem / permission 拒否を確認してください" >&2
    echo "  影響: pipeline 失敗時の詳細エラー情報 (awk syntax error / sort OOM 等) が失われ、根本原因が不可視になります" >&2
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
    _rite_log_read_impact_advice
    skipped_refs=""
    # awk/sort 後段失敗時の log_read_ok 降格 (PR #564 レビュー HIGH #2 対応):
    # log_read_ok="true" のまま据え置くと Phase 9.1 の {log_read_ok_note} /
    # {log_read_ok_warning} が展開されず、完了レポート上「log.md 読出成功 + 欠落概念 N 件」として
    # silent に表示される。本 PR の「silent false positive を防ぐ」設計意図と矛盾するため、
    # awk/sort 失敗経路でも io_error に降格させ、Phase 9.1 の note 展開を発火させる。
    # 設計原則は references/bash-cross-boundary-state-transfer.md#pattern-3-legitimate-absence-vs-io-error-classification の
    # 「後段 pipeline 失敗も同 enum の io_error 側に降格する」に記載。
    log_read_ok="io_error"
  fi
  set +o pipefail
fi

# 集合本体を stdout に出力する（Phase 6.2 の (b) 分岐で LLM が会話コンテキストに保持する）。
# bash 変数は Bash tool 呼び出し境界を超えると失われるため count だけでは不十分。
# delimiter 付きで本体を出力し、LLM が `---skipped_refs_begin---` と `---skipped_refs_end---`
# 間の行を集合として保持して Phase 6.2 の membership check に使う契約にする。
# 本パターン (marker-delimited multi-value block) の canonical 定義は
# references/bash-cross-boundary-state-transfer.md#pattern-2-marker-delimited-multi-value-block 参照。
if [ -n "$skipped_refs" ]; then
  # awk `NF>0 {n++}` は grep -c の **no-match rc=1 問題** を回避する
  # (pipefail 下で grep -c が 0 件マッチで rc=1 を返すと pipeline 全体が失敗扱いになるため)。
  # IO error (rc=2) 対策ではなく、legitimate な「0 件」を pipeline 失敗として誤検出しないための選択。
  count=$(printf '%s\n' "$skipped_refs" | awk 'NF>0 {n++} END {print n+0}')
  # skipped_refs_count は human observability only (operator が tail -f で件数を目視確認する用途)。
  # LLM contract は下記の marker block (`---skipped_refs_begin/end---`) のみを parse し、
  # LLM は skipped_refs_count 値を判定/計算には参照しない。marker block の begin/end で 0 件も positive
  # confirmation できるため機能的には不要だが、/tmp で実行ログを追うときの件数即値が便利なため残置する。
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
# F-19 対応: 冗長 cleanup の正当化を実状に合わせて修正。
# 旧コメントは「後続 block が `ls /tmp/rite-wiki-lint-p60-*` で state probe する可能性」を理由に挙げていたが、
# 現行 lint.md には該当 probe が存在しない (`Grep "rite-wiki-lint-p60-"` で probe site なし)。
# 実際の冗長 cleanup の正当化は以下の 2 点:
# (a) 後続 bash block が同名 path で再 mktemp する race window を防ぐ defense-in-depth
# (b) trap EXIT が bash block 終了時に発火するが、明示 rm は trap 発火前 (block 内 mid-flow exit 経路) でも
#     確実に削除を保証する (例: 後続 set -e 経路で trap が走る前に exit する場合の orphan 防止)
# 現行 lint.md には probe site なし、将来追加されうる probe のための防御深度として保持する。
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

**`all_source_refs` の bash 実装** (Phase 6.0 の `skipped_refs` と対称な marker block + io_error 4 値 enum):

step 1 の決定論的 parse は Phase 6.0 と同じ awk + marker block パターンで実装する。prose 以上に読解コストを払わせないことと、Phase 6.0 と同じ io_error 検知層を提供することが目的:

```bash
# ⚠️ pages_list が空 (Wiki 初期化直後 / index.md のみ) の場合、下記 for ループは 1 度も回らない。
# その場合 all_source_refs は空、all_source_refs_read_ok="true" で正常終了する (legitimate 0 件)。
# Phase 2.2 の pages_list 収集自体が失敗した場合は Phase 2.2 側の fail-fast で lint 全体が停止する
# ため、本 block は pages_list の真偽を前提にしない。
#
# ⚠️ Bash tool 呼び出し境界での state 伝達 (PR #564 レビュー CRITICAL 対応):
# Phase 1.1 の wiki_branch / branch_strategy と Phase 2.2 の pages_list は別 Bash tool 呼び出しで
# 定義されており、Claude Code の Bash tool はシェル変数を境界越えで保持しない
# (references/bash-cross-boundary-state-transfer.md)。LLM は Phase 1.1 / 2.2 の stdout から各値を
# 会話コンテキストに保持しているため、本 block 冒頭で literal substitute する
# (Phase 2.2 / Phase 6.0 / Phase 8.2 冒頭の branch_strategy / wiki_branch substitute と対称化。
# 行番号は drift するため Phase 番号と semantic 名のみで参照する)。
# pages_list は複数行のため HEREDOC (single-quoted delimiter) で shell expansion を抑制して substitute する。

# Phase 1 / Phase 2.2 の値をリテラル substitute (Phase 6.0 / Phase 2.2 と対称、LLM が会話コンテキストから埋め込む)
# ⚠️ **`{pages_list}` substitute 契約** (PR #564 F-01 対応、silent regression 防止):
# Phase 2.2 の stdout 構造は `printf '%s\n' "$pages_list" ; echo "---" ; printf '%s\n' "$raw_list"` で、
# **pages_list 行 → `---` separator → raw_list 行** の 3 部構成になっている (lint.md line 289-291 参照)。
# LLM は **pages_list ブロックのみ** (先頭から `---` 行より前の `.rite/wiki/pages/...` 行のみ) を本
# HEREDOC に substitute すること。`---` 行と raw_list 行 (`.rite/wiki/raw/...`) を含めてはならない。
# 契約違反が発生すると `.rite/wiki/raw/...` path が Wiki page 扱いされ `sources[].ref` 抽出が 0 件 →
# 全 ingested raw の missing_concept 誤分類が再発する (PR #564 F-01 の根本原因)。
# Phase 2.2 L261 の pages_list filter (`grep -E '^\.rite/wiki/pages/(patterns|heuristics|anti-patterns)/[^/]+\.md$'`)
# で pages_list 自体には pages/ 以外の path が混入しないため、LLM は「separator より前の行」だけを
# substitute すれば契約を満たせる。
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"
pages_list=$(cat <<'PAGES_LIST_EOF'
{pages_list}
PAGES_LIST_EOF
)

# F-01 (PR #564 cycle 8 F-01) 対応: placeholder 残留 fail-fast gate (Phase 1.1 / 1.3 / 8.3 と対称化)。
# LLM が substitute を忘れた場合、後段の `LC_ALL=C git show "{wiki_branch}:$page"` が
# `fatal: invalid object name '{wiki_branch}:...'` を stderr に出力する。この stderr は
# Phase 6.2 の legitimate absence regex (blob not found) に match し、all_source_refs_read_ok="true"
# のまま all_source_refs が空集合に倒れ、**全 ingested raw が step 3(c) で missing_concept に
# 誤分類される silent regression** を起こす (PR #564 最大の攻撃経路)。Phase 1.1 / 1.3 / 8.3 では
# 同型 gate を設置済みだが Phase 6.2 だけ非対称だったため対称化する。
# - branch_strategy: 必ず "separate_branch" or "same_branch" のいずれか (Phase 1.1 で validate 済み)
# - wiki_branch: 必ず非空文字列 (separate_branch 戦略の場合)
# - pages_list: 空 HEREDOC (Wiki 初期化直後 / 0 件) は legitimate のため literal 完全一致のみ error
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: Phase 6.2 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  LLM は Phase 1.1 の stdout から会話コンテキストに保持された branch_strategy 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_6_2_PLACEHOLDER_RESIDUE=1; reason=branch_strategy_unsubstituted; value=$branch_strategy" >&2
    exit 1
    ;;
esac
case "$wiki_branch" in
  "{"*"}")
    echo "ERROR: Phase 6.2 の {wiki_branch} placeholder が literal substitute されていません (値: '$wiki_branch')" >&2
    echo "  LLM は Phase 1.1 の stdout から会話コンテキストに保持された wiki_branch 値を literal substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_6_2_PLACEHOLDER_RESIDUE=1; reason=wiki_branch_unsubstituted; value=$wiki_branch" >&2
    exit 1
    ;;
esac
# pages_list は空 HEREDOC (空 pages_list = Wiki 初期化直後 / 0 件) が legitimate なため、
# literal 完全一致 "{pages_list}" のみ error にする (非空の literal path が含まれていれば substitute 済み)
case "$pages_list" in
  "{pages_list}")
    echo "ERROR: Phase 6.2 の {pages_list} placeholder が literal substitute されていません (値: '$pages_list')" >&2
    echo "  LLM は Phase 2.2 の stdout から会話コンテキストに保持された pages_list (separator 前の部分のみ) を HEREDOC に substitute する必要があります" >&2
    echo "[CONTEXT] LINT_PHASE_6_2_PLACEHOLDER_RESIDUE=1; reason=pages_list_unsubstituted" >&2
    exit 1
    ;;
esac

# F-21 (Issue #572) 対応: pages_list partial pollution 検出 gate (F-01 再発防止の runtime 契約)。
# 旧 gate (上記 case 文) は literal `{pages_list}` 残留のみを検出する。しかし LLM が Phase 2.2 stdout の
# `printf '%s\n' "$pages_list" ; echo "---" ; printf '%s\n' "$raw_list"` 3 部構造を
# 全体 substitute すると `.rite/wiki/raw/...` path が HEREDOC に混入し、下記 while ループで
# `git show "${wiki_branch}:.rite/wiki/raw/..."` が legitimate absence (blob not found) として
# 処理され、all_source_refs_read_ok="true" のまま sources[].ref 抽出が 0 件になる → 全 ingested raw が
# step 3(c) で missing_concept 誤分類される silent regression を再発させる (PR #564 F-01 と同型)。
# 対称化されていた 3 gate (branch_strategy / wiki_branch / pages_list literal) は「未 substitute」検出のみで
# 「誤 substitute (partial pollution)」を検出できず、Wiki 経験則「散文で宣言した設計は対応する実装契約が
# なければ機能しない」(Prose-only design anti-pattern) に該当していた。本 gate で runtime 契約を追加する。
#
# 検証ロジック: pages_list の各非空行が `.rite/wiki/pages/` prefix を持つことを確認。
# 違反行を 1 件でも検出すれば fail-fast で exit 1 (既存 literal gate と同じ exit convention、
# 本 gate が発火する状況は LLM substitute ミスのため継続処理は silent regression を招くだけ)。
#
# Iteration 方式: F-13 対応 (Phase 6.2 main loop: `while IFS= read -r page; do ... done <<< "$pages_list"`
# ブロック) と同型の `done <<< "$pages_list"` here-string を採用する。
# 同一 Phase 6.2 内で同じ $pages_list を iterate するループは here-string に統一 (canonical 同期)。
# 注: 行番号参照は drift するため semantic 参照のみを使う (PR #564 cycle 11 F-06 で Phase 6.2 per-page loop
# の branch_strategy case 分岐コメント内で確立された原則、Phase 番号 + 実 regex / semantic 名で参照する)。
if [ -n "$pages_list" ]; then
  partial_pollution_line=""
  while IFS= read -r pollution_check_line; do
    [ -z "$pollution_check_line" ] && continue  # blank line guard (末尾改行 / 空 HEREDOC 対応)
    case "$pollution_check_line" in
      .rite/wiki/pages/*) ;;  # OK: 正当な pages_list 行
      *)
        partial_pollution_line="$pollution_check_line"
        break  # 1 件検出したら以降の走査を打ち切り fail-fast
        ;;
    esac
  done <<< "$pages_list"
  if [ -n "$partial_pollution_line" ]; then
    echo "ERROR: Phase 6.2 の \$pages_list に '.rite/wiki/pages/' prefix を持たない行が含まれています (partial pollution 検出)" >&2
    echo "  違反行: '$partial_pollution_line'" >&2
    echo "  原因: LLM が Phase 2.2 stdout の separator ('---') より後 (raw_list) を含めて HEREDOC に substitute した可能性があります" >&2
    echo "  対処: Phase 2.2 stdout から separator より前の '.rite/wiki/pages/...' 行のみを substitute してください" >&2
    echo "[CONTEXT] LINT_PHASE_6_2_PLACEHOLDER_RESIDUE=1; reason=pages_list_partial_pollution; violation_line=$partial_pollution_line" >&2
    exit 1
  fi
fi

# F-10 (PR #564 cycle 8 F-10) 対応: HEREDOC 空文字列 / blank line の挙動を明示。
# {pages_list} が空文字列または blank line 1 行のみに substitute された場合 (Wiki 初期化直後 /
# pages 0 件の legitimate ケース)、while ループは 0 回で終了し、下記 all_source_refs="" および
# all_source_refs_read_ok="true" の emit で正常終了する。blank line guard (`[ -z "$page" ] && continue`)
# が末尾改行を skip するため silent regression は起きない。

# signal-specific trap (Phase 2.2 / Phase 6.0 と対称、for ループ内 mktemp の orphan 防止)
# canonical pattern: ../pr/references/bash-trap-patterns.md#signal-specific-trap-template
# 本 Block は per-iteration で page_err / awk_diag tempfile を、post-loop で sort_err tempfile を
# 作成するため、SIGINT/TERM/HUP 到達時の orphan を全 3 変数について防ぐ必要がある
# (Phase 6.0 の _rite_wiki_lint_phase60_cleanup が log_err + awk_sort_err の両方を保護しているのと対称化)。
page_err=""
awk_diag=""
sort_err=""
_rite_wiki_lint_phase62_cleanup() {
  [ -n "${page_err:-}" ] && rm -f "$page_err"
  [ -n "${awk_diag:-}" ] && rm -f "$awk_diag"
  [ -n "${sort_err:-}" ] && rm -f "$sort_err"
}
trap 'rc=$?; _rite_wiki_lint_phase62_cleanup; exit $rc' EXIT
trap '_rite_wiki_lint_phase62_cleanup; exit 130' INT
trap '_rite_wiki_lint_phase62_cleanup; exit 143' TERM
trap '_rite_wiki_lint_phase62_cleanup; exit 129' HUP

all_source_refs_read_ok="unknown"  # 3 値 enum: unknown / true / io_error (Phase 6.0 log_read_ok の 4 値とは異なる — legitimate absence は per-page で吸収されるため absent 値を持たない)
all_source_refs_read_errors=0
all_source_refs=""
# F-12 対応: counter semantics を accumulator (累積件数) に統一する。
# 旧実装は awk_diag_mktemp_failed が binary flag (0/1)、page_err_mktemp_failed が累積カウント
# だったが、両方とも for-loop 内 mktemp 失敗追跡用の parallel counter であり semantics 混在は
# 将来の保守者を混乱させる。両方を accumulator に統一し、コメントで「accumulator (失敗件数)」を明示。
awk_diag_mktemp_failed=0  # accumulator (失敗件数): awk_diag mktemp 失敗を検出する累積カウンタ
page_err_mktemp_failed=0  # accumulator (失敗件数): page_err mktemp 失敗を検出する累積カウンタ

# F-13 対応: `for page in $pages_list` の word-split を `while IFS= read -r page` に変更。
# Phase 2.2 の grep filter は空白を reject しないため、ページパスに空白が含まれた場合
# (例: `.rite/wiki/pages/patterns/foo bar.md`) に 3 iterations に誤分割される脆弱性があった。
# pages_list は改行区切りの文字列のため `<<<` here-string で IFS= read に渡す。
while IFS= read -r page; do
  [ -z "$page" ] && continue  # blank line guard (空 pages_list / 末尾空行対応)
  # ページ本文の取得は branch_strategy ごとに 2 経路に分岐する (Phase 2.2 / 2.3 / 6.0 / 8.2 と同型)。
  # - separate_branch: git show "${wiki_branch}:$page" (worktree には存在しない、ref からの読取)
  # - same_branch: cat "$page" (filesystem 上の tracked file を直接読む)
  # この分岐を欠落させると same_branch 環境で wiki_branch ref が存在せず全ページ読取が失敗し、
  # 全 ingested raw が missing_concept に誤分類される regression を起こす (PR #564 CRITICAL #1 対応)。
  # stderr pattern matching も 2 経路で異なる legitimate absence を考慮する
  # (separate_branch: blob 不在、same_branch: ENOENT / No such file)。
  page_err=$(mktemp /tmp/rite-lint-page-err-XXXXXX 2>/dev/null) || { page_err=""; page_err_mktemp_failed=$((page_err_mktemp_failed + 1)); }  # F-12: accumulator (累積)
  # LC_ALL=C で locale を固定 (PR #564 F-05 対応、Phase 6.0 と対称)。cat / git show の stderr
  # メッセージが gettext 経由で翻訳されると下記 Phase 6.2 の grep regex
  # (`does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:|No such file or directory|cannot open .* for reading`) と
  # 不一致になり、legitimate absence が io_error に誤分類される。
  # PR #564 cycle 11 F-06 対応: 旧コメントの「下記 905 の grep regex」は stale 行番号参照だった
  # (実際の grep regex は本ファイル下方の Phase 6.2 内、`per-page 読取失敗の WARNING 出力` ブロック
  # で `[ -n "$page_err" ] && [ -s "$page_err" ] && grep -qE ...` として使用されている)。
  # 本 PR 内の他コメントは「Phase 番号と semantic 名のみで参照する」原則を明示しているため、
  # 行番号参照ではなく Phase 番号 + 実際の regex 文字列で参照する形式に修正した。
  case "$branch_strategy" in
    separate_branch)
      page_read_cmd_result=$(LC_ALL=C git show "${wiki_branch}:$page" 2>"${page_err:-/dev/null}")
      page_read_cmd_rc=$?
      ;;
    same_branch)
      page_read_cmd_result=$(LC_ALL=C cat "$page" 2>"${page_err:-/dev/null}")
      page_read_cmd_rc=$?
      ;;
    *)
      echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (Phase 6.2)" >&2
      echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
      echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（非ブロッキング契約の唯一の例外、5 箇所で同型）" >&2
      [ -n "$page_err" ] && rm -f "$page_err"
      exit 1
      ;;
  esac
  if [ "$page_read_cmd_rc" -eq 0 ]; then
    page_content="$page_read_cmd_result"
    # 成功: frontmatter YAML list から `sources[].ref` を抽出
    # awk は in_sources フラグを ON にした回数と extract した ref 数を stderr に emit して
    # 「sources: 節は検出したが ref が 0 件」という frontmatter 破損 (改行混入 / quote 不整合) を可視化する (F-14 対応)
    awk_diag=$(mktemp /tmp/rite-lint-p62-awk-diag-XXXXXX 2>/dev/null) || awk_diag=""
    # set -e 互換のため if 文化 (set -e 環境下で `[ ] && ...` は rc=1 → script exit の罠)
    if [ -z "$awk_diag" ]; then
      awk_diag_mktemp_failed=$((awk_diag_mktemp_failed + 1))  # F-12: accumulator (累積) に統一
    fi
    # awk に page を -v で渡すことで、awk_diag mktemp 失敗経路でも END block から per-page WARNING を
    # stderr に直接 emit できる (PR #564 cycle 4 MEDIUM 対応、F-14 の per-page 可視化設計を mktemp 失敗
    # 経路でも保つ)。diag=="/dev/null" (mktemp 失敗時の fallback) のときだけ stderr に emit し、
    # 通常経路 (tempfile 経由) では bash 側の per-page WARNING と二重出力にならないよう静かに書き込む。
    # F-01 対応: page-template.md の canonical YAML は multi-line 形式 (`- type: "..."\n    ref: "..."`)。
    # 従来の `^[[:space:]]*-[[:space:]]*ref:` (同一行 `- ref:` 限定) は実際の wiki page にマッチせず、
    # extracted=0 で all_source_refs が空集合となり、登録済み raw が missing_concept に誤分類される
    # (Issue #563 完了条件 missing_concept=0 が満たせない CRITICAL regression)。
    # multi-line 形式の `    ref:` (dash なし、インデント付き) も抽出対象に追加することで、
    # canonical template と legacy 単行形式 (`- ref:`) の両方を support する。
    # post-condition: page-template.md / wiki branch の実 page の両方で `extracted >= 1` になること。
    page_refs=$(printf '%s\n' "$page_content" | awk -v diag="${awk_diag:-/dev/null}" -v page="$page" '
      /^sources:/ { in_sources=1; sources_seen++; next }
      # Issue #570: frontmatter terminator (`---`) を明示検出。
      # minimal frontmatter (sources: 直後に `---` で閉じる、tags:/confidence: なし) でも
      # sources 節が確実に閉じ、body 内 YAML code block の `    ref: "..."` 誤抽出を防ぐ。
      in_sources && /^---[[:space:]]*$/ { in_sources=0; next }
      in_sources && /^[a-zA-Z]/ { in_sources=0 }
      in_sources && /^[[:space:]]*-[[:space:]]*ref:[[:space:]]/ {
        # legacy 単行形式: `- ref: "..."` (dash と ref が同一行)
        sub(/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*/, "")
        gsub(/["\x27]/, "")
        sub(/^\.rite\/wiki\//, "")  # prefix 正規化
        extracted++
        print
        next
      }
      in_sources && /^[[:space:]]+ref:[[:space:]]/ {
        # canonical multi-line 形式: `    ref: "..."` (前行が `- type: ...` で dash なしインデント付き)
        # page-template.md L7 の `  - type: "{source_type}"\n    ref: "{source_ref}"` 形式に対応
        sub(/^[[:space:]]+ref:[[:space:]]*/, "")
        gsub(/["\x27]/, "")
        sub(/^\.rite\/wiki\//, "")
        extracted++
        print
      }
      END {
        if (sources_seen > 0 && extracted == 0) {
          if (diag == "/dev/null") {
            # mktemp 失敗経路 fallback: bash 側の [ -s "$awk_diag" ] check が必ず false になるため、
            # awk から直接 stderr に per-page WARNING を emit することで page 名を失わない
            printf "WARNING: %s の frontmatter に sources: 節が存在しますが ref が 1 件も抽出できませんでした (awk_diag mktemp 失敗経路 fallback)\n", page > "/dev/stderr"
            printf "  原因候補: YAML 構造破損 (改行混入 / quote 不整合 / インデント不正)\n" > "/dev/stderr"
            printf "  影響: 本ページが参照する raw source が all_source_refs 集合から欠落し、登録済み raw が missing_concept に誤分類される可能性\n" > "/dev/stderr"
          } else {
            # 通常経路: tempfile にマーカーを書き込み、bash 側が per-page WARNING を emit する
            printf "sources_section_empty\n" > diag
          }
        }
      }
    ')
    if [ -n "$awk_diag" ] && [ -s "$awk_diag" ]; then
      echo "WARNING: $page の frontmatter に sources: 節が存在しますが ref が 1 件も抽出できませんでした" >&2
      echo "  原因候補: YAML 構造破損 (改行混入 / quote 不整合 / インデント不正)" >&2
      echo "  影響: 本ページが参照する raw source が all_source_refs 集合から欠落し、登録済み raw が missing_concept に誤分類される可能性" >&2
    fi
    [ -n "$awk_diag" ] && rm -f "$awk_diag"
    awk_diag=""  # Phase 6.0 R-07 パターンと対称化: 次 iteration の trap cleanup で stale path を二重 rm しないため明示 reset
    if [ -n "$page_refs" ]; then
      all_source_refs=$(printf '%s\n%s' "$all_source_refs" "$page_refs")
    fi
  else
    # Phase 6.0 と同じ stderr pattern matching で legitimate absence と io_error を判別する。
    # branch_strategy ごとに legitimate absence の文言が異なるため両経路のパターンを OR する:
    # - separate_branch (git show): `fatal: invalid object name '<ref>:<path>'` / `does not exist` /
    #   `path '.+' exists on disk, but not in` / `Not a valid object name` — ページが wiki_branch に未 commit
    # - same_branch (cat): `No such file or directory` / `cannot open` — ページが filesystem 上から削除された (race)
    if [ -n "$page_err" ] && [ -s "$page_err" ] && grep -qE "does not exist|path '.+' exists on disk, but not in|Not a valid object name|fatal: invalid object name '[^']*:|No such file or directory|cannot open .* for reading" "$page_err"; then
      # legitimate absence: ページ格納先 (separate: wiki ref / same: filesystem) に存在しない
      # 集合には追加しないが read_ok は下げない (io_error 降格対象外)
      :
    else
      # 真の IO error: all_source_refs_read_errors を increment
      # (後段で io_error に畳み込み、all_source_refs_read_ok の 3 値 enum 宣言方針に準拠)
      all_source_refs_read_errors=$((all_source_refs_read_errors + 1))
      echo "WARNING: $page の sources[].ref 抽出に失敗 (rc=$page_read_cmd_rc, branch_strategy=$branch_strategy)" >&2
      [ -n "$page_err" ] && [ -s "$page_err" ] && head -3 "$page_err" | sed 's/^/  /' >&2
    fi
  fi
  [ -n "$page_err" ] && rm -f "$page_err"
  page_err=""  # Phase 6.0 R-07 パターンと対称化: 次 iteration の trap cleanup で stale path を二重 rm しないため明示 reset
done <<< "$pages_list"  # F-13 対応: while IFS= read -r で word-split 脆弱性を排除

# F-12 対応: counter semantics を accumulator 統一 (page_err_mktemp_failed と対称化)。
# 旧 binary flag check `= "1"` を `-gt 0` に変更し、失敗件数を WARNING に付記する。
# awk_diag mktemp 失敗の集約 WARNING (Phase 6.0 awk_sort_err と対称に loud fallback、per-iteration spam 回避のため for ループ後に 1 回のみ emit)
# ⚠️ 注: mktemp 失敗経路では awk の END block が /dev/stderr に per-page WARNING (page 名付き) を
# 直接 emit するため、sources_section_empty 検出の per-page 可視性は保たれる (PR #564 cycle 4 MEDIUM 対応)。
# 本集約 WARNING は /tmp の容量 / 権限問題の operator 通知を主目的とする sanity 情報として残す。
if [ "$awk_diag_mktemp_failed" -gt 0 ]; then
  echo "WARNING: awk_diag tempfile の mktemp が $awk_diag_mktemp_failed 件失敗しました。per-page の sources_section_empty 検出は awk END block から /dev/stderr 経由で emit 済み (page 名付き) のため silent drop は発生していませんが、/tmp 問題の検知として通知します" >&2
  echo "  対処: /tmp の容量 / 権限 / readonly filesystem を確認してください" >&2
fi

# page_err mktemp 失敗の集約 WARNING (PR #564 F-10 対応、awk_diag_mktemp_failed と対称化)
# per-iteration WARNING は spam の原因となるため post-loop で 1 回のみ emit する。失敗件数を付記。
# page_err 不在時は下流 io_error 判定 ([ -n "$page_err" ] && [ -s "$page_err" ] check) が false に
# 倒れるため silent 0 件には落ちないが、root cause (/tmp 枯渇・権限) が operator から不可視だった。
if [ "$page_err_mktemp_failed" -gt 0 ]; then
  echo "WARNING: page_err tempfile の mktemp が $page_err_mktemp_failed 件失敗しました" >&2
  echo "  対処: /tmp の容量 / 権限 / inode 枯渇 / readonly filesystem を確認してください" >&2
  echo "  影響: 本 Block の legitimate absence / io_error 判別は失敗経路でのみ精度低下 (io_error 側に倒す defense で silent 0 件は防止済み)" >&2
fi

# 終状態の enum 決定
if [ "$all_source_refs_read_errors" -gt 0 ]; then
  # 1 件でも IO error があれば io_error 扱い (false positive 警告発火)
  # 設計原則: 部分成功を silent に 0 件扱いしない (Phase 6.0 の log_read_ok と対称)
  all_source_refs_read_ok="io_error"
else
  all_source_refs_read_ok="true"
fi

# sort -u で重複排除 (Phase 6.0 の awk/sort pipeline と対称に pipefail + stderr 捕捉で IO error を io_error に降格)
if [ -n "$all_source_refs" ]; then
  set -o pipefail
  # F-05 対応: mktemp 失敗時の loud WARNING (Pattern 3 規範準拠、Phase 6.0 / 6.2 awk_diag と対称化)。
  # silent fallback では sort_err="" になり、`[ -s "$sort_err" ]` check が false → sort 失敗時の root cause が不可視。
  sort_err=$(mktemp /tmp/rite-lint-p62-sort-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: stderr 退避 tempfile (sort_err) の mktemp に失敗しました。sort/awk pipeline の詳細エラー情報は失われます" >&2
    echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
    echo "  影響: pipeline 失敗時の根本原因 (sort バイナリ異常 / OOM 等) が不可視になり、all_source_refs が io_error 降格しても理由が追えません" >&2
    sort_err=""
  }
  # pipefail 下で末尾 `grep -v '^$'` が no-match (rc=1) を返すと pipeline 全体が失敗扱いになり
  # all_source_refs が改行のみの edge case で io_error に誤降格する。Phase 6.0 の
  # `awk 'NF>0 {n++} END {print n+0}'` が「grep -c の no-match rc=1 問題」を回避する同型パターンを
  # 採用しており、それと対称化する (行番号は drift するため pattern 名で参照)。
  # stderr 退避は sort / awk 両 stage で共有する (`2>>` append)。pipefail 下で awk 側が失敗した場合でも
  # head -3 "$sort_err" が空になる diagnostic gap を防ぐ (Phase 6.0 awk_sort_err と対称)。
  normalized=$(printf '%s\n' "$all_source_refs" | LC_ALL=C sort -u 2>"${sort_err:-/dev/null}" | awk 'NF>0' 2>>"${sort_err:-/dev/null}")
  sort_rc=$?
  if [ "$sort_rc" -ne 0 ]; then
    echo "WARNING: Phase 6.2 の all_source_refs 正規化 pipeline が失敗しました (rc=$sort_rc)" >&2
    if [ -n "$sort_err" ] && [ -s "$sort_err" ]; then
      head -3 "$sort_err" | sed 's/^/  /' >&2
    fi
    echo "  対処: sort バイナリ / /tmp の容量 / 権限を確認してください" >&2
    echo "  影響: all_source_refs が部分出力で populate されると、真の欠落判定が false positive になるため io_error に降格します" >&2
    all_source_refs_read_ok="io_error"
  else
    all_source_refs="$normalized"
  fi
  [ -n "$sort_err" ] && rm -f "$sort_err"
  sort_err=""  # Phase 6.0 R-07 パターンと対称化: trap cleanup で stale path を二重 rm しないため明示 reset
  set +o pipefail
fi

# marker block で集合を出力 (Phase 6.0 の skipped_refs と同じパターン、Phase 6.2 step 3(a) で LLM が参照)
echo "---all_source_refs_begin---"
[ -n "$all_source_refs" ] && printf '%s\n' "$all_source_refs"
echo "---all_source_refs_end---"

# enum を stdout に emit (LLM が Phase 6.2 step 3 と Phase 9.1 note 展開で参照)
echo "all_source_refs_read_ok=$all_source_refs_read_ok"
echo "all_source_refs_read_errors=$all_source_refs_read_errors"
```

**`skipped_refs` 集合の参照方法**: Phase 6.0 の bash block 終了後、LLM は stdout から `---skipped_refs_begin---` と `---skipped_refs_end---` で囲まれた行を抽出して会話コンテキストに集合として保持する。ファイルパスの比較は両辺を `raw/{type}/{filename}` 形式に正規化してから完全一致で判定する（`.rite/wiki/` プレフィックスを両辺から除去、log.md 記録時のプレフィックス有無の暗黙的 drift を吸収）。

**marker block 未受信時の fallback** (silent false positive 防止):

step 3 の 3 分岐は LLM が stdout の marker block (`---skipped_refs_begin/end---` および `---all_source_refs_begin/end---`) を会話コンテキストに保持する契約に依存する。bash block が途中異常終了 (SIGPIPE / OOM / 構文 error / LLM context truncation) で **marker block 自体を受信できなかった場合**、当該集合を「空」と同視してはならない。以下のルールで io_error 相当に降格する:

- `---skipped_refs_begin---` / `---skipped_refs_end---` のいずれかが欠落 → `log_read_ok="io_error"` と同等に扱い、Phase 9.1 の false positive note を展開する
- `---all_source_refs_begin---` / `---all_source_refs_end---` のいずれかが欠落 → `all_source_refs_read_ok="io_error"` と同等に扱い、Phase 9.1 の false positive note を展開する

これにより、step 3 の (a)/(b)/(c) 分岐が「空集合のため全件 (c) に誤分類」する silent false positive 経路を塞ぐ (PR #564 レビュー HIGH #2 対応)。

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
| アクション | `lint:clean` / `lint:warning`（下記判定基準参照） |
| 対象 | `—`（全体チェック） |
| 詳細 | `contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` |

**`lint:clean` / `lint:warning` の判定基準** (`n_unregistered_raw` は informational で判定に含めない):

- `lint:clean`: ブロッキングカテゴリ 5 種 (`n_contradictions`, `n_stale`, `n_orphans`, `n_missing_concept`, `n_broken_refs`) **すべてが 0** の場合。`n_unregistered_raw` の値に依存しない（`n_unregistered_raw > 0` でも他 5 カテゴリが全 0 なら `lint:clean`）
- `lint:warning`: 上記 5 カテゴリのいずれか 1 つ以上が `> 0` の場合。`n_unregistered_raw` は判定から除外する（Issue #563 の「`unregistered_raw` は informational で `n_warnings` 不加算」仕様に準拠、log.md に false warning を記録して growth_check を歪めることを防ぐ）

**`lint_action` 自動判定 (Issue #573 — Pattern 1 key=value stdout emit 準拠)**:

上記 prose 判定基準を LLM 解釈から切り離し、bash block で機械的に決定して stdout に emit します。Phase 8.3 の `{log_entry}` 組み立てはこの emit 値を **single source of truth** として参照します（下記 8.3 placeholder 契約表参照）。

```bash
# >>> DRIFT-CHECK ANCHOR: Phase 8.1 canonical lint_action decision logic <<<
# Phase 8.1: lint_action 自動判定 (Pattern 1: `[CONTEXT] key=value` stdout emit)
# Reference: references/bash-cross-boundary-state-transfer.md#pattern-1-multi-value-enum-via-key-value-stdout
#
# 本 bash block の判定ロジックは上記「`lint:clean` / `lint:warning` の判定基準」節の prose
# (5 ブロッキングカテゴリ集計、`n_unregistered_raw` 除外) と一字一句同期する必要がある。
# prose 側でカテゴリ追加・informational 指標変更が発生した場合、本 bash block の counter list
# および条件式を同時に更新すること (逆も然り)。片方だけの変更は canonical reference として
# 参照される本 Phase 8.1 の信頼性を損なう。行番号は drift するため Phase 番号と semantic 名
# (「判定基準」節) のみで参照する (ingest.md Phase 5.0.c ANCHOR 形式と統一)。
#
# LLM は Phase 3-7 の LLM 内部状態 (会話コンテキスト) に累積したカウンタ値を
# (bash tool 境界を越えて保持できないため Phase 8.3 `{log_entry}` 生成と同じ経路で)
# 以下 5 行に literal substitute する。Phase 1.4 のカウンタ初期化 table (L233-243 相当) は
# shell 変数の初期化ではなく LLM 内部状態の初期化を指す。`n_unregistered_raw` は
# informational 指標 (Issue #563) のため判定式に含めない — 意図的に除外している旨を
# 明示するコメントを残す。
#
# Downstream parse 規約: 会話コンテキストから `[CONTEXT] lint_action=` prefix の行を
# **first-match で抽出**し、`=` 右辺を literal 値として受け取る (Phase 8.3 `{log_entry}`
# 組み立て / ingest.md 等の将来の consumer に共通)。Pattern 1 設計原則に従い enum 値は
# 固定有限集合 (`lint:clean` / `lint:warning`) のみ。
set -o pipefail

n_contradictions={n_contradictions}
n_stale={n_stale}
n_orphans={n_orphans}
n_missing_concept={n_missing_concept}
n_broken_refs={n_broken_refs}
# 参考: n_unregistered_raw={n_unregistered_raw} — 判定式から意図的に除外 (informational)

# Placeholder residue fail-fast gate (Phase 8.3 F-14 / review.md Phase 6.1.b json_saved_from_p61a
# gate と同型、5 site 対称化: Phase 1.1 / 1.3 / 6.2 / 8.3 / 本 8.1)。
# LLM が literal substitute を忘れると `[ "{n_contradictions}" -gt 0 ]` が rc=2 を返し、
# `set -o pipefail` のみでは検知できず `else` 分岐に流れて `lint_action="lint:clean"` が
# silent emit される fail-silent regression の防止。
# 5 counter のいずれかが `{...}` placeholder 残留 または整数以外 (空文字 / 非数字) の場合に
# fail-fast する。`n_unregistered_raw` は判定式に含めないため本 gate の対象外。
for _n_var in n_contradictions n_stale n_orphans n_missing_concept n_broken_refs; do
  _n_val=$(eval echo \$"$_n_var")
  case "$_n_val" in
    ""|*[!0-9]*|"{"*"}")
      echo "ERROR: Phase 8.1 の $_n_var が literal substitute されていないか非整数です (値: '$_n_val')" >&2
      echo "  LLM は Phase 3-7 で累積したカウンタ値を非負整数の literal で置換する必要があります" >&2
      echo "[CONTEXT] LINT_PHASE_8_1_PLACEHOLDER_RESIDUE=1; variable=$_n_var; value=$_n_val" >&2
      exit 1
      ;;
  esac
done

if [ "$n_contradictions" -gt 0 ] \
  || [ "$n_stale" -gt 0 ] \
  || [ "$n_orphans" -gt 0 ] \
  || [ "$n_missing_concept" -gt 0 ] \
  || [ "$n_broken_refs" -gt 0 ]; then
  lint_action="lint:warning"
else
  lint_action="lint:clean"
fi
echo "[CONTEXT] lint_action=$lint_action"
# >>> DRIFT-CHECK ANCHOR END: Phase 8.1 canonical lint_action decision logic <<<
```

### 8.2 書き込み先パスの決定 (Issue #547 で worktree 化)

Issue #547 以降、`separate_branch` 戦略では `.rite/wiki-worktree/` worktree を経由するため、`stash + checkout` による dev ブランチの HEAD 移動は発生しません。`branch_strategy` の値に応じて書き込み先パスを決定するだけです:

```bash
branch_strategy="{branch_strategy}"

# 5 箇所 (Phase 2.2 / Phase 6.0 / Phase 6.2 / Phase 8.2 / Phase 8.3) で同型の case 文 + 3 行診断に統一
# (PR #564 レビュー MEDIUM #3 対応、旧 if/elif/else から変更)
case "$branch_strategy" in
  same_branch)
    log_path=".rite/wiki/log.md"
    ;;
  separate_branch)
    log_path=".rite/wiki-worktree/.rite/wiki/log.md"
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (Phase 8.2)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（非ブロッキング契約の唯一の例外、5 箇所で同型）" >&2
    exit 1
    ;;
esac
echo "log_path=$log_path"
```

### 8.3 書き込み手順

**`{log_entry}` / `{log_path}` placeholder source 契約** (PR #564 cycle 4 MEDIUM 対応、bash echo emit 契約との対称性を明示):

| placeholder | source | 責務 |
|-------------|--------|------|
| `{log_path}` | Phase 8.2 bash block が `echo "log_path=$log_path"` で stdout に emit | LLM は会話コンテキストから `log_path=...` 行を grep し、本 Phase の Edit ツール呼び出しと下記 bash block に literal substitute する |
| `{log_entry}` | **LLM が Phase 8.1 の table 定義 (日時 / アクション / 対象 / 詳細 の 4 列、詳細列は `contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` の 6 フィールド形式) から組み立てる** | LLM は **Phase 1.4 (カウンタ初期化) / Phase 3-7 (各カテゴリで increment) で蓄積された** Lint カウンタ値を Phase 8.1 table の各フィールドに埋め込み、1 行の log.md 追記文字列として生成する。bash echo emit ではなく LLM 生成 — 本 placeholder だけが bash substitute 経路と非対称になるため、本表で契約を明示する。**アクション列の値は LLM 独自判定ではなく、Phase 8.1 bash block が stdout に emit する `[CONTEXT] lint_action=...` 行を first-match で抽出し、`=` 右辺の enum 値 (`lint:clean` / `lint:warning`) を literal 代入する (Issue #573、Pattern 1 準拠)** — これにより prose 判定基準の LLM 解釈 drift を排除する |

**6 フィールド形式の同期関係**: Phase 8.1 table の「詳細」列は **必ず** 6 フィールド (`contradictions` / `stale` / `orphans` / `missing_concept` / `unregistered_raw` / `broken_refs`) を含む。本 Phase 8.3 の `{log_entry}` も同じ 6 フィールド形式で生成すること。Phase 8.1 で形式を変更する場合は本表の契約と同時に更新する (drift 防止)。

**`lint_action` stdout 参照契約** (Issue #573、bash-cross-boundary-state-transfer.md Pattern 1 準拠): `{log_entry}` のアクション列値は Phase 8.1 bash block の `[CONTEXT] lint_action=$lint_action` 出力を single source of truth とし、会話コンテキストを `[CONTEXT] lint_action=` prefix で **first-match** grep して取得する。Phase 8.1 の prose 判定基準 (5 ブロッキングカテゴリの集計) と bash ロジックは DRIFT-CHECK anchor コメントで一字一句同期される契約になっているため、LLM は独自の prose 再解釈を行わず必ず bash emit 値を採用する。

**書き込み手順**:

1. Edit ツールで `{log_path}` (Phase 8.2 の bash で出力された `log_path` 値をリテラル substitute) に Phase 8.1 table に基づく log.md 追記行を **append-only** で追加する。**注意**: シェル変数 `$log_path` は Bash ツール呼び出し境界を超えると失われ、Edit ツールはシェル変数を解釈しない。Phase 8.2 の `echo "log_path=..."` 出力を会話文脈から拾って literal value で置換すること
2. 以下の bash ブロックで commit + push する (`{log_entry}` は LLM が上記契約に従い Phase 8.1 table + Lint カウンタから生成した literal 文字列で substitute する)

```bash
# Phase 8.3: log.md 追記後の commit
# PR #564 F-12 対応: set -euo pipefail を冒頭で明示し、fail-fast を既定化する
# (ingest.md Phase 5.1 / 5.2 と対称化)。non-blocking 契約は末尾の明示 exit 0 / skip 経路で担保する。
# unset variable (`-u`) と pipe 末尾以外の失敗 (`-o pipefail`) を捕捉し、bash -c 内 jq 失敗 /
# sub-command failure が silent で null に倒れる経路を閉塞する。
# F-18 対応: lint.md 内の他 phase (Phase 5.2, 6.0, 6.2, 7.1) は `set -o pipefail` のみで `set -e` / `set -u` を
# 使わない方針 (非ブロッキング契約のため fail-fast は最小限に抑え、stdout 空吐き出し経路を意図的に許容する)。
# 本 Phase 8.3 は `wiki-worktree-commit.sh` 等の外部スクリプト呼出 + commit msg placeholder gate を持つため、
# `set -e` が必要。`set +e` を separate_branch 経路の commit_out capture 直前に入れる (F-02 対応) ことで
# 「外部スクリプト rc capture」と「内部処理 fail-fast」を両立させる。
# (lint.md 内で唯一 `set -euo pipefail` を使う phase であり、他 phase の mental model から逸脱する点は
# 本コメントで明示する。読者は phase を切り替える際にエラー伝播 semantics の違いに注意。)
set -euo pipefail

# plugin_root の inline 解決 (lint.md には専用解決 Phase が存在しないため)
# Reference: ../../references/plugin-path-resolution.md#inline-one-liner-for-command-files
branch_strategy="{branch_strategy}"
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi' || true)
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "WARNING: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}'). log.md 追記の commit を skip します (非ブロッキング契約)" >&2
  exit 0
fi

# PR #564 F-14 対応: {log_entry} placeholder 残留検知 fail-fast gate
# lint.md Phase 1.1 / 1.3 の `mode={mode}` と同型。LLM が Phase 8.1 table から log_entry を組み立てられず
# literal `{log_entry}` のまま残した場合、commit_msg に literal `{log_entry}` が含まれる意味不明な commit
# が landed する silent regression を防ぐ。
log_entry="{log_entry}"  # Phase 8.1 で生成した log.md 追記行
case "$log_entry" in
  "{"*"}")
    echo "ERROR: Phase 8.3 の {log_entry} placeholder が literal substitute されていません (値: '$log_entry')" >&2
    echo "  対処: LLM は Phase 8.1 table の Lint カウンタ値 (contradictions / stale / orphans / missing_concept / unregistered_raw / broken_refs) から 6 フィールド形式の 1 行文字列を組み立て、本 bash block 冒頭の log_entry=... 行を実際の値で置換する必要があります" >&2
    exit 1
    ;;
esac

commit_msg="docs(wiki): lint report — ${log_entry}"

# F-04 対応: branch_strategy 分岐を case * fail-fast に変更し、5 site (Phase 2.2 / 6.0 / 6.2 / 8.2 / 8.3) で対称化。
# 旧 if/elif/else なし は未知の値で silent skip する経路があった。
# F-04 placeholder 残留 gate も追加: literal `{branch_strategy}` のままなら fail-fast。
case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: Phase 8.3 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    echo "  対処: LLM は Phase 1.1 で取得した branch_strategy 値 (separate_branch / same_branch) を本 bash block 冒頭の branch_strategy=... 行で literal substitute する必要があります" >&2
    exit 1
    ;;
  separate_branch)
    # F-02 対応: `set -euo pipefail` 配下で `commit_out=$(bash ...)` が rc != 0 のとき bash が即時 exit する罠を回避。
    # ingest.md Phase 5.1 と同型に `set +e; ...; set -e` で囲み、rc capture を保証する。
    # 2>&1 は付けない: wiki-worktree-commit.sh は構造化 status 行 (`[wiki-worktree-commit] committed=...`)
    # を stdout、WARNING / ERROR を stderr で出力する責務分離設計。2>&1 で mix すると将来の parser
    # regression を生む。stderr は端末に直接流して観測性を保つ。
    set +e
    commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --message "$commit_msg")
    commit_rc=$?
    set -e
    echo "$commit_out"
    # F-09 対応: rc 5 分岐 case に拡張 (ingest.md Phase 5.1 と同型)。
    # rc=2 (wiki-disabled / skipped) は INFO 相当、rc=3 (git failure) と rc=4 (push failed) と rc=* (未知) は WARNING。
    # lint は非ブロッキング契約のため exit 1 はせず、すべて WARNING のみで継続する。
    case "$commit_rc" in
      0)
        : # 正常完了
        ;;
      2)
        echo "[CONTEXT] WIKI_LINT_COMMIT=skipped; reason=wiki-disabled-or-no-pending" >&2
        ;;
      3)
        echo "WARNING: wiki-worktree-commit.sh で git 操作失敗 (rc=3)。log.md 追記は非ブロッキングのため継続します" >&2
        ;;
      4)
        echo "WARNING: wiki-worktree-commit.sh で commit landed but push 失敗 (rc=4)。次回再 push が必要" >&2
        ;;
      *)
        echo "WARNING: wiki-worktree-commit.sh が予期しない rc=$commit_rc で失敗しました。log.md 追記は非ブロッキングのため継続します" >&2
        ;;
    esac
    ;;
  same_branch)
    # PR #564 cycle 11 F-05 対応: case body indent を 4-space に統一 (separate_branch arm と対称化)。
    # 旧実装は同 case 文内で separate_branch arm が 4-space、same_branch arm が 2-space、*) arm が
    # 0-space と 3 種類の indent style 混在で reader に「`*)` は別ブロック?」と誤認させるリスクがあった。
    # Phase 6.0 / 6.2 / 8.2 の case 文と同じ「pattern 2-space + body 4-space + `;;` 4-space」規範に統一。
    #
    # git add / commit の stderr を tempfile に捕捉 (silent failure 防止):
    # pre-commit hook / gpg sign / author config / permission / index lock 等の根本原因を可視化する
    #
    # PR #564 F-13 対応: canonical signal-specific 4 行 trap に変更 (Phase 6.0 / 6.2 と対称化、
    # ../pr/references/bash-trap-patterns.md#signal-specific-trap-template 参照)。
    # 旧 1 行統合 trap `trap '...' EXIT INT TERM HUP` は SIGINT 等で exit code 130/143/129 を明示返却
    # しないため、上位 orchestrator が rc=0 と誤判定する可能性があった。
    add_err=""
    commit_err=""
    _rite_wiki_lint_phase83_cleanup() {
      # F-06 (PR #564 cycle 8 F-06) 対応: BSD variant に統一 (Phase 6.0 / 6.2 cleanup と対称化)。
      # bash-trap-patterns.md の『BSD/macOS rm の rm -f "" 対応 (空引数ガード variant)』規範に準拠。
      # 旧実装 `rm -f "${add_err:-}" "${commit_err:-}"` は GNU rm では空引数 silent no-op だが
      # BSD/macOS rm では `rm: : No such file or directory` が stderr に出て operator を混乱させる。
      [ -n "${add_err:-}" ] && rm -f "$add_err"
      [ -n "${commit_err:-}" ] && rm -f "$commit_err"
    }
    trap 'rc=$?; _rite_wiki_lint_phase83_cleanup; exit $rc' EXIT
    trap '_rite_wiki_lint_phase83_cleanup; exit 130' INT
    trap '_rite_wiki_lint_phase83_cleanup; exit 143' TERM
    trap '_rite_wiki_lint_phase83_cleanup; exit 129' HUP
    # F-05 対応: mktemp 失敗時の loud WARNING (Pattern 3 規範準拠、Phase 6.0 / 6.2 と対称化)。
    # silent fallback では add_err="" / commit_err="" になり、`[ -s "$add_err" ]` check が false →
    # git add / commit 失敗時の根本原因 (pre-commit hook / gpg sign / index lock 等) が不可視になる。
    add_err=$(mktemp /tmp/rite-lint-add-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile (add_err) の mktemp に失敗しました。git add の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: index lock / permission denied 等の根本原因が不可視になります" >&2
      add_err=""
    }
    commit_err=$(mktemp /tmp/rite-lint-commit-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile (commit_err) の mktemp に失敗しました。git commit の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: pre-commit hook / gpg sign / author config 失敗の根本原因が不可視になります" >&2
      commit_err=""
    }

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
    # F-20 対応: trap - EXIT INT TERM HUP の意図は、明示 rm 後に trap を解除して、後続 (`exit 0` で継続)
    # 行で trap が再発火しないようにすること (R-07 と同型の冗長 cleanup 正当化)。
    # 同期 cleanup と trap cleanup の役割分離: 上記 2 行が同期 cleanup (通常パス)、trap は signal 経路の defense-in-depth。
    trap - EXIT INT TERM HUP
    ;;
  *)
    # F-04 対応: 未知の branch_strategy 値 (設定ミス、新規モード追加忘れ等) を silent skip させない。
    # 5 site (Phase 2.2 / 6.0 / 6.2 / 8.2 / 8.3) で同型の fail-fast メッセージに揃える。
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (Phase 8.3)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（非ブロッキング契約の唯一の例外、5 箇所で同型）" >&2
    exit 1
    ;;
esac
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
- 欠落概念: {n_missing_concept} 件{log_read_ok_note}{all_source_refs_read_ok_note}
- 未登録 raw（skip 済）: {n_unregistered_raw} 件（informational、`n_warnings` 不加算）
- 壊れた相互参照: {n_broken_refs} 件

{log_read_ok_warning}{all_source_refs_read_ok_warning}

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

**`{n_pages}` / `{n_raw}` 展開ルール** (F-01 対応、Phase 2.2 の `pages_list` / `raw_list` から派生):

LLM は Phase 2.2 bash block の stdout から `pages_list` / `raw_list` を会話コンテキストに保持している。各配列の要素数（空行と `---` separator を除いた非空行の数）を数えて `{n_pages}` / `{n_raw}` に展開する。両 list が空の場合は `0` を展開する。

**`{log_read_ok_note}` / `{log_read_ok_warning}` / `{all_source_refs_read_ok_note}` / `{all_source_refs_read_ok_warning}` 展開ルール** (F-05 対応、log_read_ok / all_source_refs_read_ok の両 enum を独立 4 placeholder で表現):

LLM は Phase 6.0 bash block の stdout から `log_read_ok={value}` を、Phase 6.2 bash block の stdout から `all_source_refs_read_ok={value}` を読み取り、それぞれ独立に以下を展開する。両 enum はいずれかが `io_error` なら false positive note / warning を展開する独立チャネル (両者が io_error のときは 2 行の note が並ぶ)。**Phase 6.0 / Phase 6.2 が実行されなかった場合** (Phase 2.2 末尾で `pages_list` と `raw_list` が両方空で Phase 3-7 が skip された経路、stdout 行が emit されない) は、両 placeholder を空文字列として展開する:

| enum 値 | `{..._note}` (行末 note) | `{..._warning}` (block warning) |
|--------|------------------------|--------------------------------|
| `true` | 空文字列 | 空文字列 |
| `absent` (log_read_ok のみ) | 空文字列 | 空文字列 |
| `io_error` (log_read_ok) | ` ⚠️ (log.md 読出失敗により false positive を含む可能性あり)` | `⚠️ log.md 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。separate_branch なら wiki branch の log.md blob integrity、same_branch なら \`.rite/wiki/log.md\` の存在 / 権限を確認して /rite:wiki:lint を再実行してください。` |
| `io_error` (all_source_refs_read_ok) | ` ⚠️ (ページ frontmatter 読出失敗により sources.ref 集合が不完全、false positive を含む可能性あり)` | `⚠️ ページ frontmatter 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。Wiki ページ格納先 (wiki branch or \`.rite/wiki/pages/\` filesystem) の integrity / 権限を確認して /rite:wiki:lint を再実行してください。` |
| `unknown` (log_read_ok) | (この状態では Phase 9.1 に到達しない、branch_strategy fail-fast で exit 1 済み) | 空文字列 |
| `unknown` (all_source_refs_read_ok) | 空文字列 (Phase 6.2 block 途中異常終了時の fallback — emit 自体は enum decision 後に行うため通常は届かないが、防御深度として stdout 上に `all_source_refs_read_ok=unknown` が残留した場合の扱いを明示) | 空文字列 |
| `(未 emit: Phase 6.0 / 6.2 skip、処理対象 0 件)` | 空文字列 | 空文字列 |

**空行処理ルール (3 行ブロック原子的扱い)**: template は `{log_read_ok_warning}{all_source_refs_read_ok_warning}` を中心に **3 行ブロック**を持つ:

1. 直前の空行 (前段「壊れた相互参照」行との区切り)
2. `{log_read_ok_warning}{all_source_refs_read_ok_warning}` placeholder 行 (2 つの warning placeholder が隣接)
3. 直後の空行 (後段「検出詳細:」との区切り)

LLM は以下のルールで **3 行すべてを原子的に展開**する (部分的な削除・保持は禁止):

| 2 warning placeholder の合成値 | 3 行ブロックの展開 |
|-------------------------------|-------------------|
| 両方とも空文字列 (`true` / `absent`) | **3 行すべて省略** (前段「壊れた相互参照」行の直後に後段「検出詳細:」行を隣接させる) |
| 片方が非空 + もう片方が空文字列 | **3 行すべて展開** (空行 + 非空 warning 1 行 + 空行) |
| 両方が非空 (両 enum が `io_error`) | **3 行展開 + 2 warning の間に改行挿入** (空行 + `{log_read_ok_warning}` + 改行 + `{all_source_refs_read_ok_warning}` + 空行、計 4 行を原子的に展開。template 上は同一行に隣接配置されているが LLM は substitute 時に **必ず両 warning 間に改行 1 つを挿入すること**) |

これにより「連続空行 2 行が残る silent regression」および「空行 0 行で読みにくくなる問題」の両方を防ぐ。

**展開例** (前段「壊れた相互参照: {n} 件」の直後):

- `log_read_ok=true` / `absent` (3 行ブロック全削除 → 空行なしで次の section へ直結):
  ```
  - 壊れた相互参照: 2 件
  検出詳細:
  ```

- `log_read_ok=io_error` (3 行ブロックそのまま展開、F-04 対応で表 (L1437) と文言同期):
  ```
  - 壊れた相互参照: 2 件

  ⚠️ log.md 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。separate_branch なら wiki branch の log.md blob integrity、same_branch なら `.rite/wiki/log.md` の存在 / 権限を確認して /rite:wiki:lint を再実行してください。

  検出詳細:
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

**検出件数が全て 0 の場合も含め、`--auto` モードの stdout は常にこの 1 行を出力する**（PR #564 レビュー MEDIUM #2 対応 — 旧仕様の「0 件なら stdout を空にして exit 0」は bash syntax error や未捕捉 fatal error での空 stdout を silent に "clean" と誤認する経路を生むため撤廃）。6 フィールド全てが 0 のときは `Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0` を出力する。これにより ingest 側の Phase 8.3 step 3 は「stdout が空 = Lint 実行失敗」として扱うことができる（stdout 空は unreachable な経路として定義される）。`unregistered_raw` は `n_warnings` に加算されないため、`n_unregistered_raw > 0` だけで `missing_concept` と他 4 カテゴリが 0 の場合も 6 フィールドを揃えたこの 1 行を出力する。

### 9.3 exit code

- **原則 exit 0**: 検出件数・事前チェック失敗・ブランチ読取失敗のいずれも非ブロッキング
- **例外 (`exit 1` fail-fast)**:
  - Phase 2.2 / Phase 6.0 / Phase 6.2 / Phase 8.2 / Phase 8.3 の `branch_strategy` 未知値 (5 箇所で同型、設定ミスの silent 通過防止)
  - Phase 1.1 / Phase 1.3 の `{mode}` placeholder 残留検知 (2 箇所で同型、Claude substitute 忘れの silent 通過防止)
- 内部 bash 構文エラー等の unrecoverable error のみ非 0 exit となる可能性あり

---

## エラーハンドリング

| エラー | 対処 | Phase |
|--------|------|-------|
| `wiki.enabled: false` | 早期 return (`--auto` モード時は 6 フィールド 0 件 1 行を出力後 exit 0、それ以外は警告のみ exit 0) | Phase 1.1 |
| GNU date 非互換環境 | Phase 4 skip（exit 0 + WARNING） | Phase 1.2 |
| Wiki 未初期化 | `/rite:wiki:init` を案内 (`--auto` モード時は 6 フィールド 0 件 1 行を出力後 exit 0) | Phase 1.3 |
| `{mode}` placeholder 残留 (Phase 1.1 / Phase 1.3 の 2 箇所) | **exit 1 で fail-fast**（Claude substitute 忘れの silent 通過防止、2 箇所で同型） | Phase 1.1 / Phase 1.3 |
| `git ls-tree` 失敗 | WARNING + `pages_list=""`/`raw_list=""` で継続（exit 0） | Phase 2.2 |
| `branch_strategy` が未知の値 (Phase 2.2 / Phase 6.0 / Phase 6.2 / Phase 8.2 / Phase 8.3 の 5 箇所) | **exit 1 で fail-fast**（設定ミスの silent 通過防止、5 箇所で同型） | Phase 2.2 / Phase 6.0 / Phase 6.2 / Phase 8.2 / Phase 8.3 |
| `index.md` 読出失敗 | WARNING + Phase 5 skip（exit 0） | Phase 2.3 |
| `log.md` 読出失敗 (legitimate absence: fresh branch / ENOENT / blob not found) | WARNING 抑制 + `skipped_refs=""` + `log_read_ok=absent`（exit 0） | Phase 6.0 |
| `log.md` 読出失敗 (真の IO error: permission / 破損 / wiki_branch race) | WARNING + `skipped_refs=""` + `log_read_ok=io_error` + Phase 9.1 完了レポートで false positive note 表示（exit 0） | Phase 6.0 |
| awk/sort pipeline 失敗 | WARNING + `skipped_refs=""` で継続（exit 0） | Phase 6.0 |
| `date -d` パース失敗 | 該当ページを skip し WARNING を stderr に出力（`n_stale` 非加算） | Phase 4.2 |
| `grep` no-match（indexed_pages 空） | WARNING + Phase 5 skip（全ページ orphan 誤検出防止） | Phase 5.2 |
| 処理対象 0 件 | Phase 3-7 を skip し Phase 9 で「検査対象なし」表示 | Phase 2.2 末尾 |
| log.md 追記失敗 | WARNING + exit 0 で継続（検出結果は stdout に表示済み） | Phase 8 |
