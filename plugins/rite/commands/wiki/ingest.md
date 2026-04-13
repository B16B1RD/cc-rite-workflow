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

### 1.1 Wiki 設定の読み取りとブランチ戦略判定

`rite-config.yml` から Wiki 設定 (`wiki_enabled`, `wiki_branch`, `branch_strategy`) を**単一の bash ブロック**で読み取ります。`init.md` Phase 1.1/1.2 と同じ判定結果を返しますが、実装パイプラインは異なります (本コマンドは F-23 修正済みの awk + YAML コメント除去パターンを使用し、`wiki_section` を 1 回のみ取得して 3 値を同時に抽出します):

```bash
# NOTE: set -euo pipefail を意図的に省略。本ブロックはプローブ用で各コマンドの失敗を
# `|| fallback=""` で個別処理する。Phase 5.1/5.2 では set -euo pipefail を明示的に使用。
#
# cycle 6 fix: Phase 1.1 と 1.2 の bash block を統合。wiki_section を 1 回のみ取得し、
# wiki_enabled / wiki_branch / branch_strategy を単一ブロックで全て抽出する。
# 旧実装は Phase 1.1 と 1.2 で wiki_section を独立して 2 回取得していた (重複)。
#
# F-05/F-06 fix: trigger.sh の F-23 修正済みパターンに統一
# - sed 's/[[:space:]]#.*//' (YAML 仕様準拠: スペース直前の # のみコメント扱い)
# - クォート除去 (tr -d '"'\''')
# - F-01 fix: pipefail × grep no-match silent abort を回避するため分割実行
#
# Note: trigger.sh (hooks/wiki-ingest-trigger.sh L206-223) にも同じ YAML パースロジックが
# 存在する。両ファイルのパースロジックは F-23 修正版 (awk + YAML コメント除去) で統一されている。
# trigger.sh 側は lenient 設計 (false/no/0 のみ reject、それ以外は通過) であり、
# 本ファイルの strict 4 分岐とはセマンティクスが異なる (意図的な設計差異)。
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

# --- wiki_branch の抽出 (同じ wiki_section を再利用) ---
wiki_branch_line=""
if [[ -n "$wiki_section" ]]; then
  wiki_branch_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+branch_name:/ { print; exit }') || wiki_branch_line=""
fi
wiki_branch=""
if [[ -n "$wiki_branch_line" ]]; then
  wiki_branch=$(printf '%s' "$wiki_branch_line" | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
fi
wiki_branch="${wiki_branch:-wiki}"

# --- branch_strategy の抽出 (同じ wiki_section を再利用) ---
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

### 2.1 引数の判定とカウンター変数の初期化

引数 `<raw-file-path>` が指定されている場合は、その単一ファイルのみを Ingest 対象とします。指定がない場合は `.rite/wiki/raw/` 配下から `ingested: false` を持つ Raw Source ファイルを **すべて** 列挙します。

**カウンター変数の初期化** (Phase 5 commit message と Phase 9 完了レポートで参照):

LLM は本 Phase で以下のカウンター変数を会話コンテキストに保持し、各 Phase で incrementate します:

| 変数 | Phase 2.1 時点の初期値 | 確定 / incrementate するタイミング |
|------|---------------------|---------------------------------|
| `n_raw_sources` | `0` | cycle 2 M3 fix: Phase 2.3 末尾で処理対象件数が確定した時点で `n_raw_sources = <件数>` に設定 (Phase 2.1 時点では Phase 2.3 を先読みできないため 0 で初期化) |
| `n_pages_created` | `0` | Phase 4 で「新規ページ作成」を決定するごとに +1 |
| `n_pages_updated` | `0` | Phase 4 で「既存ページ更新」を決定するごとに +1 |
| `n_skipped` | `0` | Phase 4 で「スキップ」を決定するごとに +1 |
| `n_warnings` | `0` | Phase 8 で矛盾検出するごとに +1 |
| `processed_files[]` | `[]` (空配列) | Phase 5.0 step 7 で Write/Edit 処理後に append (詳細・プレフィックス規約は Phase 5.0 step 7 参照) |

これらの値は Phase 5 の `git commit -m` 実行時にリテラル整数として **必ず置換** すること (placeholder のまま commit してはならない)。

### 2.2 separate_branch 戦略時のブランチ切り替え

`separate_branch` 戦略では、Raw Source は wiki ブランチに保存されています。一方、`wiki-ingest-trigger.sh` は呼び出された時点のブランチ (= 通常は開発ブランチ) のワークツリーに書き込むため、Ingest 時には:

1. 開発ブランチ側の `.rite/wiki/raw/` に新規ファイルがあるか確認
2. ある場合: それらを wiki ブランチに移送する必要がある
3. wiki ブランチに切り替えて、Raw Source を読み込み・統合

このため、Ingest コマンドは「開発ブランチでステージングされた Raw Source を wiki ブランチに反映する」役割も担います。

> **Reference**: [Wiki ブランチへの書き込み（Ingest 時）](../../references/wiki-patterns.md#wiki-ブランチへの書き込みingest-時) — `current_branch` 退避、stash、cleanup trap、復帰

具体的な手順は Phase 5 (書き込み) に集約します。Phase 2 ではどのブランチに対象 Raw Source が存在するかを把握するため、両ブランチを参照できるようにします。

```bash
# Phase 1.2 の値をリテラル値として埋め込む。Claude は <{...}> プレースホルダーを実際の値で
# 必ず substitute すること (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

# 候補リストを作成（開発ブランチ側 + wiki ブランチ側）
# cycle 9 MEDIUM fix: find stderr を tempfile に捕捉 (silent swallow 禁止)。
# permission denied / IO error が silent に空扱いされ候補列挙を誤判定する経路を防ぐ。
candidates=()
if [ -d ".rite/wiki/raw" ]; then
  find_err=$(mktemp /tmp/rite-wiki-ingest-find-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for find_err, stderr capture disabled" >&2; find_err=""; }
  while IFS= read -r f; do candidates+=("$f"); done < <(find .rite/wiki/raw -type f -name '*.md' 2>"${find_err:-/dev/null}")
  if [ -n "$find_err" ] && [ -s "$find_err" ]; then
    echo "WARNING: find .rite/wiki/raw が stderr 出力を返しました (permission denied / IO error の可能性):" >&2
    head -3 "$find_err" | sed 's/^/  /' >&2
    echo "  影響: 一部候補が silent に脱落した可能性があります。ディレクトリ権限を確認してください" >&2
  fi
  [ -n "$find_err" ] && rm -f "$find_err"
fi

# F-30 fix: wiki ブランチ側候補列挙の `|| true` silent fallback を廃止し、
# git ls-tree の失敗 (wiki branch 消失等) を WARNING で可視化する
if [ "$branch_strategy" = "separate_branch" ]; then
  ls_tree_err=$(mktemp /tmp/rite-wiki-ingest-lstree-err-XXXXXX) || { echo "WARNING: mktemp failed for ls_tree_err, stderr capture disabled" >&2; ls_tree_err=""; }
  if ls_tree_out=$(git ls-tree -r --name-only "$wiki_branch" 2>"${ls_tree_err:-/dev/null}"); then
    while IFS= read -r f; do
      case "$f" in .rite/wiki/raw/*.md) candidates+=("wiki:${f}") ;; esac
    done <<< "$ls_tree_out"
  else
    ls_tree_rc=$?
    echo "WARNING: cannot list wiki branch raw sources (git ls-tree '$wiki_branch' failed, rc=$ls_tree_rc)" >&2
    [ -n "$ls_tree_err" ] && [ -s "$ls_tree_err" ] && head -3 "$ls_tree_err" | sed 's/^/  /' >&2
    echo "  対処: wiki ブランチが存在するか確認してください (git rev-parse --verify $wiki_branch)" >&2
  fi
  [ -n "$ls_tree_err" ] && rm -f "$ls_tree_err"
fi

printf 'Found %d candidate raw source(s)\n' "${#candidates[@]}"
for c in "${candidates[@]}"; do echo "  - $c"; done
```

### 2.3 Ingested フラグの判定

各候補ファイルの YAML frontmatter から `ingested:` を読み、`false` のものだけを処理対象とします。`wiki-ingest-trigger.sh` が生成するファイルは初期値 `ingested: false` を持つため、これが Ingest 待ちのマーカーになります。

引数で単一ファイルが指定されている場合は、`ingested:` の値にかかわらず処理対象とします（再 Ingest を許可）。

**`ingested:` フラグの抽出手順** (F-17 fix): 各候補ファイルの先頭 frontmatter ブロック (`---` 〜 `---` 区間) 内から `ingested:` 行を抽出します。bash で行う場合は以下のスニペット:

```bash
# frontmatter 区間内の ingested: 値を抽出
# cycle 9 HIGH fix: Phase 1.1 wiki.enabled パースと同型の lowercase + quote 除去正規化を適用。
# YAML spec 準拠の表現 (False / FALSE / "false" / no / 0) をすべて受理し、手動投入や re-stage の
# drift を吸収する。
ingested_value=$(awk '
  BEGIN { in_fm=0 }
  /^---$/ { in_fm++; next }
  in_fm == 1 && /^ingested:[[:space:]]*/ {
    sub(/^ingested:[[:space:]]*/, "")
    sub(/[[:space:]]*$/, "")
    print
    exit
  }
' "$candidate_file")
# lowercase 化 + クォート除去 (Phase 1.1 wiki.enabled パースと同パイプライン)
ingested_norm=$(printf '%s' "$ingested_value" | tr -d '"'\''' | tr '[:upper:]' '[:lower:]')
case "$ingested_norm" in
  false|no|0|"") process="yes" ;;  # 未設定 / false 族はすべて unstaged とみなす
  *)             process="no"  ;;
esac
```

**wiki ブランチ (`wiki:` プレフィックス) からの読み取り**: 候補名が `wiki:` プレフィックスを持つ場合、prefix を剥がしてから `git show` で取得します。

> **⚠️ 以下のスニペットは `for candidate in "${candidates[@]}"; do ... done` ループ内で実行されることを前提**としています (Phase 2.2 の `candidates[]` 配列を iterate)。`continue` は enclosing for-loop の次 iteration へ進む制御です。ループ骨組みを省略して単発実行すると `continue` が構文エラーになります。cycle 9 MEDIUM fix で明示化。

```bash
# cycle 3 fix (F-12): git show に stderr 捕捉を追加 (Phase 3 の F-18 パターンを適用)。
# ref drift / blob 欠落時に空 Raw Source を LLM に渡し ingest:skip で ingested:true 化する
# silent data loss 経路を防ぐ。
# enclosing loop の例: for candidate in "${candidates[@]}"; do ... done
case "$candidate" in
  wiki:*)
    actual_path="${candidate#wiki:}"
    # F-09 fix: stderr を stdout に混合しない (git 警告テキストが file_body に混入する)
    git_show_err=$(mktemp /tmp/rite-wiki-ingest-show-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for git_show_err, stderr capture disabled" >&2; git_show_err=""; }
    if ! file_body=$(git show "${wiki_branch}:${actual_path}" 2>"${git_show_err:-/dev/null}"); then
      echo "WARNING: failed to read ${actual_path} from wiki branch" >&2
      [ -n "$git_show_err" ] && [ -s "$git_show_err" ] && head -3 "$git_show_err" | sed 's/^/  /' >&2
      echo "  この候補をスキップして次の Raw Source に進みます" >&2
      [ -n "$git_show_err" ] && rm -f "$git_show_err"
      continue
    fi
    [ -n "$git_show_err" ] && rm -f "$git_show_err"
    ;;
  *)
    actual_path="$candidate"
    # F-13/F-07 fix: cat 失敗時のエラーハンドリング + stderr 捕捉 (git show パスと対称化)
    cat_err=$(mktemp /tmp/rite-wiki-ingest-cat-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for cat_err, stderr capture disabled" >&2; cat_err=""; }
    if ! file_body=$(cat "$actual_path" 2>"${cat_err:-/dev/null}"); then
      echo "WARNING: failed to read ${actual_path}" >&2
      [ -n "$cat_err" ] && [ -s "$cat_err" ] && head -3 "$cat_err" | sed 's/^/  /' >&2
      echo "  この候補をスキップして次の Raw Source に進みます" >&2
      [ -n "$cat_err" ] && rm -f "$cat_err"
      continue
    fi
    [ -n "$cat_err" ] && rm -f "$cat_err"
    ;;
esac
```

**ファイル本体の取得方法**:

| 場所 | 取得コマンド |
|------|-------------|
| 開発ブランチのワークツリー | Read ツールで直接読み取り |
| wiki ブランチ (`wiki:` プレフィックス) | `git show "${wiki_branch}:${path}"` で取得 (上記参照) |

**処理対象が0件の場合**: 早期 return:

```
未 Ingest の Raw Source は見つかりませんでした。
新しい経験則を蓄積するには /rite:pr:review や /rite:pr:fix の完了後に再実行してください。
```

**処理対象が確定した時点で**: cycle 2 M3 fix — Phase 2.1 で初期化した `n_raw_sources` を本時点での処理対象件数に上書きする (Phase 2.1 時点では Phase 2.3 を先読みできないため `0` で初期化されている)。

**処理対象 Raw Source の本文事前読み込み**: cycle 2 推奨事項対応 — Phase 5.0 step 1 への接続のため、本時点で各 Raw Source の **完全な本文** (frontmatter + body) を Read ツール (dev branch 側) または `git show "${wiki_branch}:${path}"` (wiki branch 側) で取得し、会話コンテキストに保持しておく。Phase 5.0 step 1 で再利用される。

---

## Phase 3: 既存 Wiki インデックスの読み込み

統合判定（新規ページ作成 vs 既存ページ更新）のため、現在の `index.md` を読み込みます。

```bash
# Phase 1.2 の値をリテラルで埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

# F-18 fix: stderr を捕捉し、git show の真の失敗 (ref drift / blob 欠落) と
# 「初回 ingest で index.md がそもそも存在しない」初期状態を区別する
# cycle 2 M4 fix: cleanup を trap に一元化し L261/L265 の冗長 rm を解消
if [ "$branch_strategy" = "separate_branch" ]; then
  # cycle 3 fix (F-05/F-13): signal-specific trap + 成功時 tempfile 明示削除
  index_err=""
  _rite_wiki_index_err_cleanup() {
    rm -f "${index_err:-}"
  }
  trap 'rc=$?; _rite_wiki_index_err_cleanup; exit $rc' EXIT
  trap '_rite_wiki_index_err_cleanup; exit 130' INT
  trap '_rite_wiki_index_err_cleanup; exit 143' TERM
  trap '_rite_wiki_index_err_cleanup; exit 129' HUP
  index_err=$(mktemp /tmp/rite-wiki-ingest-index-err-XXXXXX) || { echo "WARNING: mktemp failed for index_err, stderr capture disabled" >&2; index_err=""; }
  # cycle 3 fix (F-06): locale 依存の git エラーメッセージ regex を回避。
  # git cat-file -e で blob の存在を先行判定し、存在しなければ初期状態として扱う。
  if ! git cat-file -e "${wiki_branch}:.rite/wiki/index.md" 2>/dev/null; then
    echo "INFO: index.md not yet present on '$wiki_branch'. Treating all pages as new (initial state)." >&2
    index_content=""
  elif index_content=$(git show "${wiki_branch}:.rite/wiki/index.md" 2>"${index_err:-/dev/null}"); then
    : # success
  else
    git_show_rc=$?
    echo "ERROR: failed to read index.md from '$wiki_branch' (git show rc=$git_show_rc)" >&2
    [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  /' >&2
    echo "  対処: wiki branch drift / network 接続 / git バイナリの状態を確認してください" >&2
    exit 1  # trap が index_err を削除する
  fi
  # 成功時: tempfile を明示削除してから trap 解除 (リーク防止)
  [ -n "${index_err:-}" ] && rm -f "$index_err"
  trap - EXIT INT TERM HUP
else
  if [ -f .rite/wiki/index.md ]; then
    index_content=$(cat .rite/wiki/index.md)
  else
    echo "INFO: .rite/wiki/index.md not found (initial state). Treating all pages as new." >&2
    index_content=""
  fi
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

### 5.0 LLM が実行すべき具体的手順 (F-02 fix, cycle 2 で C1/C2/H3 修正)

**重要**: Phase 5.1 / 5.2 を実行する前に、LLM は以下の番号付き手順を **必ず順番に**実施します。Phase 2.3 / Phase 4 で会話コンテキストに保持した Raw Source 本文と Phase 4 で決定したアクションを、Write/Edit ツールで実ファイルに反映する責務は LLM 側にあります。

> **⚠️ 実行モデル (cycle 2 C2 fix — Phase 5.0 step 2/8 矛盾解消)**: Phase 5.1 (separate_branch) は **3 つの bash ブロックに分割実行** されます。Bash tool 呼び出し間でシェル変数 (`current_branch`, `stash_needed`, trap) は失われるため、変数を **次のブロックでリテラル substitute** する必要があります。具体的な分割境界:
>
> | bash block | 実行内容 | LLM が次 block で substitute する変数 |
> |-----------|---------|-------------------------------------|
> | **Block A**: Phase 5.1 前半 | trap 武装 + detached HEAD 検出 + stash + `git checkout "$wiki_branch"` | `current_branch`, `stash_needed`, `wiki_branch` |
> | **(LLM Write/Edit phase)** | 下記 step 1-7 を Write/Edit ツールで実施 | (bash 不要) |
> | **Block B**: Phase 5.1 後半 | `git add` + `git commit` + `git push` + `git checkout "$current_branch"` + `git stash pop` + `processed_files[]` 限定 cleanup | (Block A の値を全て literal substitute、`processed_files=("path1" "path2")` 形式で bash 配列を宣言) |
>
> Block A の最後で `trap - EXIT INT TERM HUP` により trap が解除される。**Block B の冒頭で cleanup trap を再武装すること** (Block A のシェル状態は Bash tool 呼び出し境界で失われるため、Block B 内の sequential failure — 例: git push 成功後に git checkout 失敗 — で stash 未回復になることを防ぐ)。LLM Write/Edit phase 中にエラーが発生した場合は LLM が `git checkout "$current_branch" && git stash pop` を含む cleanup Block を即座に発行する責務を負います。これは 1 回の bash invocation に収めるべき設計だが、Claude Code の Bash tool は LLM の Write/Edit を bash の中間に挟めないための制約による (将来 1 ブロック実行可能になれば統合される)。

1. **Raw Source 本文の確保**: Phase 2.3 **末尾の「処理対象 Raw Source の本文事前読み込み」プロセス** (上記 Phase 2.3 末尾段落を参照) で Read ツールまたは `git show` により取得され会話コンテキストに保持された本文を、LLM の作業メモリに取り出す。Phase 2.3 前半の `file_body` シェル変数は Bash tool 境界で失われているため、本 step 1 はシェル変数ではなく会話コンテキスト保持値を参照する (cycle 9 MEDIUM 明示化)
2. **Raw Source の wiki ブランチ側への配置** (separate_branch 戦略のみ、**create / update 決定の Raw Source に適用**。skip 決定 Raw Source は step 4.5 で同等の分岐を別途実施する):
   - **Block A 実行後** (= `git checkout "$wiki_branch"` 完了後)、候補の prefix に応じて操作を分岐する:
     - **`wiki:` プレフィックス付き候補** (= wiki ブランチに既存のファイル): `git checkout` 後にワークツリーに存在するため、Edit ツールで frontmatter の `ingested: false` を `ingested: true` に書き換える (Write 上書き不要)
     - **プレフィックスなし候補** (= 開発ブランチ側で stash 退避されたファイル): Write ツールで `.rite/wiki/raw/{type}/{filename}` に Raw Source 本文を書き出し、frontmatter の `ingested: false` を `ingested: true` に書き換える
3. **新規 Wiki ページの作成**: Phase 4 で「新規ページ作成」と決定した Raw Source について、`{plugin_root}/templates/wiki/page-template.md` を Read で読み込み、Phase 5.3 のプレースホルダーを置換した内容を Write で `.rite/wiki/pages/{domain}/{slug}.md` に書き出す。`n_pages_created` を +1 する
4. **既存 Wiki ページの更新**: Phase 4 で「既存ページ更新」と決定した Raw Source について、対象ページを Read で読み込み、Edit で `## 詳細` セクションへの追記、`updated` フィールド更新、`sources` 配列への追記を行う。`n_pages_updated` を +1 する
4.5. **スキップ決定 Raw Source の処理** (cycle 9 HIGH fix + cycle 10 HIGH-1 fix — n_skipped カウンタ更新 + prefix 別 Edit/Write 分岐の契約明示): Phase 4 で「スキップ」と決定した Raw Source について、以下を実施する:
   - **Raw Source の frontmatter `ingested: true` 化** (step 2 と同じ prefix 別分岐を適用 — separate_branch 戦略のみ):
     - **`wiki:` プレフィックス付き候補** (= wiki ブランチに既存のファイル): `git checkout` 後にワークツリーに存在するため、Edit ツールで frontmatter の `ingested: false` を `ingested: true` に書き換える
     - **プレフィックスなし候補** (= 開発ブランチ側で stash 退避されたファイル): Write ツールで `.rite/wiki/raw/{type}/{filename}` に **Raw Source 本文全体を書き出し** (frontmatter は `ingested: true` に変更済みの状態)。本文は Phase 2.3 末尾の事前読み込みで会話コンテキストに保持されているものを使用する
     - **same_branch 戦略**: 上記分岐不要。Raw Source は既にワークツリーに存在するため、Edit ツールで `ingested: true` に書き換える
   - Phase 7 の log.md 追記 step で `ingest:skip` エントリを追加する (reason も記録)
   - **`n_skipped` を +1 する** (Phase 9 完了レポート / commit message の整合性確保)
   - `processed_files[]` 配列にも append する (step 7 と同じ prefix 規約。skip 決定ファイルも wiki ブランチ側なら `wiki:` prefix を保持する。same_branch 戦略では processed_files は参照されないため no-op)
5. **index.md の更新**: Phase 6 の指示に従い Edit で `.rite/wiki/index.md` を更新する
6. **log.md への追記**: Phase 7 の指示に従い Edit で `.rite/wiki/log.md` に append-only でエントリを追加する
7. **`processed_files[]` への記録** (cycle 2 C1/H2/H3 fix):
   - 処理した Raw Source の **リポジトリルート基準の相対パス** を会話コンテキストの `processed_files[]` 配列に append する
   - **wiki ブランチ側ファイル**: `wiki:` プレフィックスを **保持したまま** append (例: `wiki:.rite/wiki/raw/reviews/foo.md`)。これにより Block B の cleanup ループの `case "$f" in wiki:*) continue ;;` ガードが正しく発火し、開発ブランチ側で誤って `git ls-files` / `rm` を実行することを防ぐ
   - **開発ブランチ側ファイル**: `wiki:` プレフィックスなしで append (例: `.rite/wiki/raw/reviews/foo.md`)
   - **bash 配列宣言の必須化**: Block B 冒頭で LLM は **必ず** `processed_files=("path1" "path2" "path3" ...)` のリテラル bash 配列宣言を Block B の bash block 内に展開する。これを忘れると Block B の cleanup ループは `${#processed_files[@]}` を 0 と評価し silent no-op となる
8. **Block B 実行**: 上記 step 1-7 (Write/Edit phase) が完了してから、Block B の bash block を `processed_files=(...)` substitute 付きで実行する

これらの手順は **prose による自然言語契約** ですが、LLM はこれを順序通りに実行する責務を負います。手順 1-7 を skip して Block B を実行すると、(a) `git add .rite/wiki/` が空 staging になり `git commit` が失敗、または (b) `processed_files=()` 空配列で cleanup ループが silent no-op し開発ブランチに raw file が残留します。

### 5.1 separate_branch 戦略

> **Reference**: [Wiki ブランチへの書き込み（Ingest 時）](../../references/wiki-patterns.md#wiki-ブランチへの書き込みingest-時) のテンプレートに従う

**Block A: Pre-checkout phase** (separate_branch のみ — trap 武装 + stash + checkout)

```bash
# F-19 fix: trap を先行武装してから git branch --show-current を実行する
# F-10 fix: detached HEAD を fail-fast で検出する (current_branch 空文字の silent fall を防止)
# F-06 fix: Phase 5.1 bash ブロック末尾 (本ブロックの末尾) に branch_strategy unknown 時の else 分岐を追加
#   (cycle 2 M1: 旧コメント "Phase 5.2 末尾" は誤記。実際の else は本ブロック L=末尾)
# F-05 fix: {n_pages_created} 等は Claude が Phase 2.1 冒頭のカウンター変数表で初期化したカウンター変数を
#           リテラル整数として substitute する (placeholder 文字列のままコミット禁止)
#
# Phase 1.2 の値をリテラルで埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  set -euo pipefail  # cycle 2 M5 fix: strict mode を有効化

  # F-19 fix: パス先行宣言 → trap 先行設定 → 主処理の順序
  current_branch=""
  stash_needed=false
  checkout_err=""
  stash_err=""
  _rite_wiki_ingest_cleanup() {
    if [ -n "$current_branch" ]; then
      checkout_err=$(mktemp /tmp/rite-wiki-ingest-checkout-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for checkout_err, stderr capture disabled" >&2; checkout_err=""; }
      # cycle 2 H6 fix: stderr を保持して原因を可視化 (2>/dev/null は禁止)
      if ! git checkout "$current_branch" 2>"${checkout_err:-/dev/null}"; then
        echo "WARNING: cleanup の git checkout '$current_branch' に失敗。手動で元ブランチに戻ってください" >&2
        [ -n "$checkout_err" ] && [ -s "$checkout_err" ] && head -3 "$checkout_err" | sed 's/^/  /' >&2
      fi
      [ -n "${checkout_err:-}" ] && rm -f "$checkout_err"
    fi
    if [ "${stash_needed:-false}" = true ]; then
      stash_err=$(mktemp /tmp/rite-wiki-ingest-stash-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for stash_err, stderr capture disabled" >&2; stash_err=""; }
      if ! git stash pop 2>"${stash_err:-/dev/null}"; then
        echo "WARNING: cleanup の git stash pop に失敗。手動回復が必要: git stash list" >&2
        [ -n "$stash_err" ] && [ -s "$stash_err" ] && head -3 "$stash_err" | sed 's/^/  /' >&2
      fi
      [ -n "${stash_err:-}" ] && rm -f "$stash_err"
    fi
  }
  # cycle 9 CRITICAL fix: INT/TERM/HUP ハンドラで `trap - EXIT` を先行実行する。
  # これがないと INT trap 実行 → cleanup → exit 130 → EXIT trap 連鎖発火 → cleanup 二重実行となり、
  # 非冪等な `git stash pop` が 2 回走って無関係 stash を誤 pop する状態破壊経路が開く。
  trap 'rc=$?; _rite_wiki_ingest_cleanup; exit $rc' EXIT
  trap 'trap - EXIT; _rite_wiki_ingest_cleanup; exit 130' INT
  trap 'trap - EXIT; _rite_wiki_ingest_cleanup; exit 143' TERM
  trap 'trap - EXIT; _rite_wiki_ingest_cleanup; exit 129' HUP

  # F-10 fix: detached HEAD を fail-fast 検出
  current_branch=$(git branch --show-current)
  if [ -z "$current_branch" ]; then
    echo "ERROR: detached HEAD 状態のため /rite:wiki:ingest を実行できません" >&2
    echo "  対処: ブランチに切り替えてから再実行してください (例: git checkout develop)" >&2
    exit 1
  fi

  # F-03 fix: untracked Raw Source も stash 対象にするため -u を追加。
  # `git diff` は untracked を検出しないため、まず untracked の有無も判定する。
  # cycle 3 fix: git diff --quiet の rc を明示区別 (rc=0: 差分なし, rc=1: 差分あり, rc>=2: エラー)
  # `!` 否定は rc=1 と rc>=2 を区別できず、`2>/dev/null` で stderr も消えるため、
  # broken repo / empty repo / index.lock 競合が暗黙に stash trigger される問題を防ぐ。
  has_changes=false
  # cycle 8 F-07 fix: git diff の stderr を tempfile に捕捉 (trigger.sh の stderr tempfile パターンと統一)
  # cycle 9 CRITICAL fix: `set -e` 配下で `cmd; rc=$?` は bash 仕様上 cmd の非 0 終了を「test されている」
  # と見なさず即 exit する (実証: `bash -c 'set -e; false; rc=$?; echo $rc'` は echo に到達しない)。
  # `rc=0; cmd || rc=$?` 形式で cmd を `||` の LHS に置くことで set -e トリガーを回避しつつ rc を捕捉する。
  _diff_err=$(mktemp /tmp/rite-wiki-ingest-diff-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for _diff_err, stderr capture disabled" >&2; _diff_err=""; }
  _diff_rc=0
  git diff --quiet HEAD 2>"${_diff_err:-/dev/null}" || _diff_rc=$?
  if [ "$_diff_rc" -ge 2 ]; then
    echo "ERROR: git diff --quiet HEAD がエラーを返しました (rc=$_diff_rc)" >&2
    [ -n "$_diff_err" ] && [ -s "$_diff_err" ] && head -3 "$_diff_err" | sed 's/^/  /' >&2
    echo "  対処: git status / git repo の整合性を確認してください" >&2
    [ -n "$_diff_err" ] && rm -f "$_diff_err"
    exit 1
  elif [ "$_diff_rc" -eq 1 ]; then
    has_changes=true
  fi
  _cached_rc=0
  git diff --cached --quiet HEAD 2>"${_diff_err:-/dev/null}" || _cached_rc=$?
  if [ "$_cached_rc" -ge 2 ]; then
    echo "ERROR: git diff --cached --quiet HEAD がエラーを返しました (rc=$_cached_rc)" >&2
    [ -n "$_diff_err" ] && [ -s "$_diff_err" ] && head -3 "$_diff_err" | sed 's/^/  /' >&2
    [ -n "$_diff_err" ] && rm -f "$_diff_err"
    exit 1
  elif [ "$_cached_rc" -eq 1 ]; then
    has_changes=true
  fi
  # cycle 9 MEDIUM fix: git ls-files の stderr を tempfile に捕捉 (silent swallow 禁止)。
  # git 破損 / permission denied が silent に empty 扱いされ untracked 判定を誤る経路を防ぐ。
  _lsf_err=$(mktemp /tmp/rite-wiki-ingest-lsf-err-XXXXXX 2>/dev/null) || _lsf_err=""
  if _lsf_out=$(git ls-files --others --exclude-standard 2>"${_lsf_err:-/dev/null}"); then
    if [ -n "$_lsf_out" ]; then
      has_changes=true
    fi
  else
    _lsf_rc=$?
    echo "WARNING: git ls-files --others --exclude-standard が失敗 (rc=$_lsf_rc)" >&2
    [ -n "$_lsf_err" ] && [ -s "$_lsf_err" ] && head -3 "$_lsf_err" | sed 's/^/  /' >&2
    echo "  対処: git repo の整合性を確認してください。untracked 判定を skip します" >&2
  fi
  [ -n "$_lsf_err" ] && rm -f "$_lsf_err"
  [ -n "$_diff_err" ] && rm -f "$_diff_err"
  if [ "$has_changes" = "true" ]; then
    git stash push -u -m "rite-wiki-ingest-stash" || {
      echo "ERROR: git stash push -u に失敗しました" >&2
      exit 1
    }
    stash_needed=true
  fi

  git checkout "$wiki_branch" || { echo "ERROR: git checkout '$wiki_branch' failed" >&2; exit 1; }

  # Block A 成功: trap を解除して cleanup が発火しないようにする。
  # これにより後続の LLM Write/Edit phase と Block B は wiki ブランチ上で正しく動作する。
  # Phase 3 の trap 解除パターンと整合。
  trap - EXIT INT TERM HUP

  # current_branch / stash_needed / wiki_branch の値を Block B に渡すため stdout に明示出力
  # (Bash tool 呼び出し間でシェル変数は失われるため、Block B 冒頭で literal substitute)
  echo "[CONTEXT] BLOCK_A_DONE; current_branch=$current_branch; stash_needed=$stash_needed; wiki_branch=$wiki_branch"

elif [ "$branch_strategy" = "same_branch" ]; then
  # same_branch 戦略は Phase 5.2 で扱う
  :
else
  # F-06 fix: 未知の branch_strategy を fail-fast で拒否
  echo "ERROR: 未知の branch_strategy: '$branch_strategy'" >&2
  echo "  受け付け可能な値: separate_branch / same_branch" >&2
  echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください" >&2
  exit 1
fi
```

**(LLM Write/Edit phase)**: Phase 5.0 step 1-7 を実施。Write/Edit ツールで Raw Source 配置 / 新規ページ作成 / 既存ページ更新 / index.md 更新 / log.md 追記。`processed_files[]` 配列に処理済みパスを会話コンテキストで保持 (`wiki:` プレフィックスは wiki ブランチ側ファイルのみ保持)。

**Block B: Post-checkout phase** (separate_branch のみ — git add/commit/push + checkout-back + cleanup)

```bash
# Block A の [CONTEXT] BLOCK_A_DONE 行から読み取った値を literal substitute する
# (例: current_branch="develop", stash_needed=false)
current_branch="{current_branch}"
stash_needed="{stash_needed}"
wiki_branch="{wiki_branch}"

# cycle 2 C1 fix: processed_files[] を bash 配列として明示的に宣言する。
# LLM は以下の行全体を、Phase 5.0 step 7 で保持したパス一覧の
# リテラル bash 配列宣言に置き換えること (行置換、placeholder 部分のみの差し替えではない)。
# 例: processed_files=(".rite/wiki/raw/reviews/foo.md" "wiki:.rite/wiki/raw/fixes/bar.md")
# 空配列時は: processed_files=()
# この宣言を忘れると下流の cleanup ループが silent no-op になる。
processed_files=()

set -euo pipefail  # cycle 2 M5 fix: strict mode 有効化

# cycle 6 fix: Block B にも cleanup trap を設置する。Block A のシェル状態 (trap 含む) は
# Bash tool 呼び出し境界で失われるため、Block B 内で git push 成功後に git checkout が
# 失敗した場合、stash 未回復のままユーザーが wiki ブランチに取り残される。
# Block A の cleanup_err 分離パターン (checkout_err / stash_err) と同型。
_rite_wiki_ingest_blockB_cleanup() {
  local _bb_checkout_err _bb_stash_err _bb_checkout_ok
  _bb_checkout_ok=true
  _bb_checkout_err=$(mktemp /tmp/rite-wiki-ingest-bb-checkout-err-XXXXXX 2>/dev/null) || _bb_checkout_err=""
  # cycle 7 fix: 二重 stderr redirect (2>tempfile 2>/dev/null) を修正。Block A (L464) と同型にする。
  if ! git checkout "$current_branch" 2>"${_bb_checkout_err:-/dev/null}"; then
    echo "WARNING: Block B cleanup の git checkout '$current_branch' に失敗" >&2
    [ -n "$_bb_checkout_err" ] && [ -s "$_bb_checkout_err" ] && head -3 "$_bb_checkout_err" | sed 's/^/  /' >&2
    echo "  対処: 手動で git checkout $current_branch を実行してください" >&2
    _bb_checkout_ok=false
  fi
  [ -n "${_bb_checkout_err:-}" ] && rm -f "$_bb_checkout_err"
  # cycle 9 HIGH fix: checkout 失敗時は stash pop を skip する (wiki ブランチ上での誤 pop 防止)。
  # 旧実装は WARNING を出すだけで stash pop に進行し、ユーザーの dev ブランチ変更が wiki ブランチ
  # に紛れ込むリスクがあった。
  if [ "$_bb_checkout_ok" = "false" ]; then
    echo "  WARNING: checkout 失敗のため stash pop を skip します (手動回復: git stash list で確認)" >&2
    return
  fi
  if [ "$stash_needed" = "true" ]; then
    # cycle 7 fix: stash pop の stderr も Block A (L471-476) と同型に tempfile 捕捉する。
    _bb_stash_err=$(mktemp /tmp/rite-wiki-ingest-bb-stash-err-XXXXXX 2>/dev/null) || _bb_stash_err=""
    if ! git stash pop 2>"${_bb_stash_err:-/dev/null}"; then
      echo "WARNING: Block B cleanup の git stash pop に失敗。手動回復が必要: git stash list" >&2
      [ -n "$_bb_stash_err" ] && [ -s "$_bb_stash_err" ] && head -3 "$_bb_stash_err" | sed 's/^/  /' >&2
    fi
    [ -n "${_bb_stash_err:-}" ] && rm -f "$_bb_stash_err"
  fi
}
# cycle 9 CRITICAL fix: INT/TERM/HUP で `trap - EXIT` を先行実行し cleanup 二重発火を防ぐ (Block A と対称)
trap 'rc=$?; _rite_wiki_ingest_blockB_cleanup; exit $rc' EXIT
trap 'trap - EXIT; _rite_wiki_ingest_blockB_cleanup; exit 130' INT
trap 'trap - EXIT; _rite_wiki_ingest_blockB_cleanup; exit 143' TERM
trap 'trap - EXIT; _rite_wiki_ingest_blockB_cleanup; exit 129' HUP

git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }

# F-05 fix: {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} は整数値に置換すること
# cycle 9 MEDIUM fix: n_skipped を commit message に含めて履歴追跡性を確保
git commit -m "docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})" \
  || { echo "ERROR: git commit failed" >&2; exit 1; }

# F-12 fix: git push 失敗時に手動回復手順を明示
git push origin "$wiki_branch" || {
  echo "ERROR: git push failed for branch '$wiki_branch'" >&2
  echo "  ローカルコミットは '$wiki_branch' ブランチに残っています" >&2
  echo "  手動回復: git checkout $wiki_branch && git push origin $wiki_branch" >&2
  echo "  対処: gh auth status / network 接続 / リモートリポジトリの権限を確認" >&2
  exit 1
}

git checkout "$current_branch" || {
  echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
  exit 1
}

# F-11 fix: git stash pop の失敗 (merge conflict 等) を必ず検出して fail-fast
# cycle 8 F-03 fix: stash pop 成功後に stash_needed=false を設定し、EXIT trap での二重 pop を防止
if [ "$stash_needed" = "true" ]; then
  if ! git stash pop; then
    echo "ERROR: git stash pop に失敗しました — stash が残っています" >&2
    echo "  対処: 'git stash list' で確認し、競合を手動で解消してください" >&2
    exit 1
  fi
  stash_needed=false
fi

# main body の checkout/stash pop が完了したため trap を解除 (二重実行防止)
trap - EXIT INT TERM HUP

# F-04 fix: 削除対象を processed_files[] のみに限定し、find -delete 二重サイレンサーを廃止
# cycle 2 C1 fix: processed_files[] が上記で bash 配列として明示宣言されているため silent no-op しない
# cycle 2 C1 fix: 空配列の場合は WARNING を出して LLM の契約違反を可視化
if [ "${#processed_files[@]}" -eq 0 ]; then
  echo "WARNING: processed_files[] is empty — Phase 5.0 step 7 で LLM が populate したか確認してください" >&2
  echo "  影響: 開発ブランチ側 raw file が残留し、PR diff に混入する可能性があります" >&2
else
  for f in "${processed_files[@]}"; do
    # wiki: プレフィックス付きは wiki ブランチ側のファイルなので開発ブランチでは削除しない
    case "$f" in
      wiki:*) continue ;;
    esac
    # tracked file 誤削除を防ぐため、untracked のみを削除
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      echo "WARNING: '$f' は tracked file のため削除しません (PR diff に混入する可能性)" >&2
      echo "  対処: 手動で git rm するか、トリガースクリプトの呼び出し方を再確認してください" >&2
      continue
    fi
    if ! rm -f "$f"; then
      echo "WARNING: 開発ブランチ側 raw file の削除に失敗: $f" >&2
      echo "  対処: 手動で削除してください (PR diff に混入するリスクあり)" >&2
    fi
  done
  # 空ディレクトリのみ削除
  find .rite/wiki/raw -type d -empty -delete || \
    echo "WARNING: 開発ブランチ側 raw ディレクトリの空削除に失敗 (手動確認推奨)" >&2
fi
```

### 5.2 same_branch 戦略

> **F-03/F-04/F-11 fix**: Phase 5.1 と同様に Write/Edit phase と bash block を分離し、実行モデルを明示化。

**same_branch 実行モデル** (2 段構成 — Phase 5.1 と異なりブランチ切り替え Block A は不要):

1. **Write/Edit phase**: Phase 5.0 の手順 1-7 と同じ責務を実行する (same_branch では Wiki ブランチへの移送は不要だが、ファイル書き込みの責務は同一):
   - Raw Source の frontmatter `ingested: false` を Edit ツールで `ingested: true` に書き換え (same_branch では Raw Source は既にワークツリーに存在するため Write 上書き不要)
   - 新規/既存 Wiki ページを Write/Edit で更新
   - index.md / log.md を更新
   - processed_files[] 配列に処理済みパスを記録 (Claude がコンテキストで保持)
2. **Post-write bash block**: Write/Edit 完了後に以下を実行する:

```bash
# F-04 fix: set -euo pipefail を追加 (Phase 5.1 Block B と整合)
set -euo pipefail

branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "same_branch" ]; then
  # cycle 9 HIGH fix: same_branch 戦略でも git add 成功 → git commit 失敗時に stage をロールバックする。
  # これがないと LLM が事前に Edit した ingested:true 化と index.md / log.md 変更が staging に残留し、
  # ユーザーが気付かずに次の操作で混入したり、未 commit な ingested:true で再 ingest が silent skip される
  # 冪等性破綻が発生する。
  git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }

  # cycle 9 MEDIUM fix: commit message に n_skipped を含める
  if ! git commit -m "docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"; then
    echo "ERROR: git commit failed" >&2
    echo "  ロールバック: staging area の .rite/wiki/ 変更を unstage します" >&2
    # cycle 10 LOW fix: stderr を tempfile に捕捉 (silent suppress 禁止)。他箇所 (cycle 9 MEDIUM fix)
    # の tempfile stderr パターンと統一する。primary error は既に出力済みのため best-effort だが、
    # git reset 失敗の根本原因 (permission / repo 破損) を可視化する。
    _reset_err=$(mktemp /tmp/rite-wiki-ingest-reset-err-XXXXXX 2>/dev/null) || _reset_err=""
    # cycle 12 LOW fix: `${_reset_err:-}` defensive form で Block B (L633, L648) と対称化
    # 現状の制御フローでは _reset_err は必ず定義されるが、将来 early-return を挟むリファクタでの
    # `set -u` トリップを予防する (hypothetical guard)。
    if ! git reset HEAD .rite/wiki/ 2>"${_reset_err:-/dev/null}"; then
      echo "  WARNING: git reset HEAD .rite/wiki/ に失敗。手動で unstage してください: git reset HEAD .rite/wiki/" >&2
      [ -n "${_reset_err:-}" ] && [ -s "${_reset_err:-}" ] && head -3 "$_reset_err" | sed 's/^/    /' >&2
    fi
    [ -n "${_reset_err:-}" ] && rm -f "$_reset_err"
    echo "  注意: LLM が事前に Edit した ingested:true 化と index.md / log.md 変更はワークツリーに残っています" >&2
    echo "  対処: git status で変更内容を確認後、手動で commit するか git checkout で破棄してください" >&2
    exit 1
  fi

  # same_branch では raw cleanup は不要 (PR diff に含めるのが意図的な選択)
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
| `{source_type}` | Raw Source の `type` フィールド (reviews/retrospectives/fixes — `wiki-ingest-trigger.sh` が受理する 3 値のみ) |
| `{source_ref}` | Raw Source の相対パス（例: `raw/reviews/20260413T...md`） |
| `{summary}` | Phase 4.1 で生成したサマリー |
| `{details}` | Phase 4.1 で生成した詳細 |
| `{related_page_title}` / `{related_page_path}` | F-14 fix: 関連ページがある場合は両方を埋める。**該当ページがない場合は `## 関連ページ` セクション全体を Edit で書き換え、`- （関連ページなし）` の平文 1 行に置き換える** (Markdown リンク `[]()` の破綻を防ぐため、空 placeholder のままにしない) |
| `{source_description}` | Raw Source の `title` フィールド (空なら `source_ref` を使用) |

> **confidence フィールド** (F-12/F-27 fix): page-template.md の `confidence: medium` は**リテラル値**であり、上記テーブルの `{...}` プレースホルダーとは処理方式が異なります。Write 後に Edit ツールで `confidence: medium` を Phase 4 の判定値 (`high` / `medium` / `low`) に置換してください。テーブル内に含めると LLM がプレースホルダー走査で誤置換するため、意図的に分離しています。

> **`{source_type}` から `manual` を削除** (F-15 fix): `wiki-ingest-trigger.sh` は `reviews|retrospectives|fixes` の 3 値のみを受理するため、本 placeholder で `manual` を許容すると drift 源になります。手動投入経路を導入する場合は trigger.sh 側のバリデーションも同時に拡張すること。
>
> **`{source_ref}` のセマンティクス分離** (F-15 fix): page-template.md は frontmatter の `sources[].ref` と「## ソース」セクションのリンク URL の 2 箇所で `{source_ref}` を参照しますが、両方とも **ファイル相対パス** (例: `raw/reviews/20260413T...md`) を使用します。リンクの**表示テキスト**には `{source_description}` を使い、URL には `{source_ref}` を使うことで両者を分離してください。`wiki-ingest-trigger.sh` の frontmatter 内 `source_ref` フィールド (例: `pr-123`) は識別子であり、ここで参照される `{source_ref}` (ファイル相対パス) とは別物です。

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
| Detached HEAD | F-10 fix: Phase 5.1 冒頭で fail-fast 検出、`current_branch` 空文字を許容しない |
| ブランチ切り替え失敗 | cleanup trap で元ブランチに復帰、cleanup 失敗時は WARNING を出して手動回復を促す |
| `git stash pop` 失敗 (merge conflict) | F-11 fix: 即座に exit 1 し、`git stash list` で確認するよう案内 |
| `git push` 失敗 | F-12 fix: エラー出力に手動回復手順を含める。`git checkout {wiki_branch} && git log origin/{wiki_branch}..HEAD` で未 push コミットを確認後、`git push origin {wiki_branch}` でリトライ |
| `branch_strategy` が未知の値 | F-06 fix: Phase 5.1 (Block A) の bash block 末尾の `else` 分岐で fail-fast 検出 (rite-config.yml の `wiki.branch_strategy` を確認するよう案内) |
| LLM が経験則を抽出できない | 該当 Raw Source は `ingest:skip` として log.md に記録、`ingested: true` に変更、`n_skipped` を +1 |

---

## 設計原則

- **単一責任**: Ingest は「Raw Source → Wiki ページ」の変換のみ。Query (`/rite:wiki:query`) と Lint (`/rite:wiki:lint`) は別コマンド
- **冪等性**: 同じ Raw Source を再 Ingest しても結果が同じ（`ingested: true` フラグで重複防止）
- **append-only な log**: 活動ログは履歴として残し、追加のみ
- **PR diff からの分離**: `separate_branch` 戦略では Wiki 変更は wiki ブランチに閉じる。開発ブランチには Raw Source の一時ファイルすら残さない
- **opt-in**: `wiki.enabled: false` がデフォルト。既存ワークフローへの影響なし
