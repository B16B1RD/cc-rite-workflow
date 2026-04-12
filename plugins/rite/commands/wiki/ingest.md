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

### 2.1 引数の判定とカウンター変数の初期化

引数 `<raw-file-path>` が指定されている場合は、その単一ファイルのみを Ingest 対象とします。指定がない場合は `.rite/wiki/raw/` 配下から `ingested: false` を持つ Raw Source ファイルを **すべて** 列挙します。

**カウンター変数の初期化** (Phase 5 commit message と Phase 9 完了レポートで参照):

LLM は本 Phase で以下のカウンター変数を会話コンテキストに保持し、各 Phase で incrementate します:

| 変数 | 初期値 | incrementate するタイミング |
|------|--------|---------------------------|
| `n_raw_sources` | Phase 2.3 で決定した処理対象件数 | 処理対象決定時に固定 |
| `n_pages_created` | `0` | Phase 4 で「新規ページ作成」を決定するごとに +1 |
| `n_pages_updated` | `0` | Phase 4 で「既存ページ更新」を決定するごとに +1 |
| `n_skipped` | `0` | Phase 4 で「スキップ」を決定するごとに +1 |
| `n_warnings` | `0` | Phase 8 で矛盾検出するごとに +1 |
| `processed_files[]` | `[]` (空配列) | Phase 4 で処理した Raw Source パスを append (Phase 5 cleanup で参照) |

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
candidates=()
if [ -d ".rite/wiki/raw" ]; then
  while IFS= read -r f; do candidates+=("$f"); done < <(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null)
fi

# F-30 fix: wiki ブランチ側候補列挙の `|| true` silent fallback を廃止し、
# git ls-tree の失敗 (wiki branch 消失等) を WARNING で可視化する
if [ "$branch_strategy" = "separate_branch" ]; then
  ls_tree_err=$(mktemp /tmp/rite-wiki-ingest-lstree-err-XXXXXX) || ls_tree_err=""
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
# frontmatter 区間内の ingested: 値を抽出 (legacy `false` 文字列のみを判定対象)
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
case "$ingested_value" in
  false|"") process="yes" ;;  # 未設定も unstaged とみなす
  *)        process="no"  ;;
esac
```

**wiki ブランチ (`wiki:` プレフィックス) からの読み取り**: 候補名が `wiki:` プレフィックスを持つ場合、prefix を剥がしてから `git show` で取得します:

```bash
case "$candidate" in
  wiki:*)
    actual_path="${candidate#wiki:}"
    file_body=$(git show "${wiki_branch}:${actual_path}")
    ;;
  *)
    actual_path="$candidate"
    file_body=$(cat "$actual_path")
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

---

## Phase 3: 既存 Wiki インデックスの読み込み

統合判定（新規ページ作成 vs 既存ページ更新）のため、現在の `index.md` を読み込みます。

```bash
# Phase 1.2 の値をリテラルで埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

# F-18 fix: stderr を捕捉し、git show の真の失敗 (ref drift / blob 欠落) と
# 「初回 ingest で index.md がそもそも存在しない」初期状態を区別する
if [ "$branch_strategy" = "separate_branch" ]; then
  index_err=$(mktemp /tmp/rite-wiki-ingest-index-err-XXXXXX) || index_err=""
  if index_content=$(git show "${wiki_branch}:.rite/wiki/index.md" 2>"${index_err:-/dev/null}"); then
    : # success
  else
    git_show_rc=$?
    # `pathspec ... unknown` (legitimate な初期状態) と他のエラーを区別
    if [ -n "$index_err" ] && grep -qE "(does not exist|unknown revision|pathspec)" "$index_err"; then
      echo "INFO: index.md not yet present on '$wiki_branch'. Treating all pages as new (initial state)." >&2
      index_content=""
    else
      echo "ERROR: failed to read index.md from '$wiki_branch' (git show rc=$git_show_rc)" >&2
      [ -n "$index_err" ] && [ -s "$index_err" ] && head -3 "$index_err" | sed 's/^/  /' >&2
      echo "  対処: wiki branch drift / network 接続 / git バイナリの状態を確認してください" >&2
      [ -n "$index_err" ] && rm -f "$index_err"
      exit 1
    fi
  fi
  [ -n "$index_err" ] && rm -f "$index_err"
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

### 5.0 LLM が実行すべき具体的手順 (F-02 fix)

**重要**: Phase 5.1 / 5.2 を実行する前に、LLM は以下の番号付き手順を **必ず順番に**実施します。Phase 2.3 / Phase 4 で会話コンテキストに保持した Raw Source 本文と Phase 4 で決定したアクションを、Write/Edit ツールで実ファイルに反映する責務は LLM 側にあります。

1. **Raw Source 本文の確保**: Phase 2.3 で Read 済みの Raw Source 本文 (frontmatter + body) を会話コンテキストから取り出し、LLM の作業メモリに保持する
2. **Raw Source の wiki ブランチ側への配置** (separate_branch 戦略のみ):
   - Phase 5.1 の `git checkout "$wiki_branch"` 後、Write ツールで `.rite/wiki/raw/{type}/{filename}` に Raw Source 本文を書き出す
   - 書き出す際、frontmatter の `ingested: false` を `ingested: true` に書き換える
3. **新規 Wiki ページの作成**: Phase 4 で「新規ページ作成」と決定した Raw Source について、`{plugin_root}/templates/wiki/page-template.md` を Read で読み込み、Phase 5.3 のプレースホルダーを置換した内容を Write で `.rite/wiki/pages/{domain}/{slug}.md` に書き出す。`n_pages_created` を +1 する
4. **既存 Wiki ページの更新**: Phase 4 で「既存ページ更新」と決定した Raw Source について、対象ページを Read で読み込み、Edit で `## 詳細` セクションへの追記、`updated` フィールド更新、`sources` 配列への追記を行う。`n_pages_updated` を +1 する
5. **index.md の更新**: Phase 6 の指示に従い Edit で `.rite/wiki/index.md` を更新する
6. **log.md への追記**: Phase 7 の指示に従い Edit で `.rite/wiki/log.md` に append-only でエントリを追加する
7. **`processed_files[]` への記録**: 処理した Raw Source の **絶対パス** (開発ブランチ側ファイルなら開発ブランチでの相対パス、wiki ブランチ側ファイルなら `wiki:` プレフィックス除去後のパス) を会話コンテキストの `processed_files[]` 配列に append する
8. **Phase 5.1 / 5.2 の bash block 実行**: 上記 1-7 が完了してから、ブランチ戦略に応じた bash ブロックを実行する

これらの手順は **prose による自然言語契約** ですが、LLM はこれを順序通りに実行する責務を負います。手順 1-7 を skip して Phase 5.1 / 5.2 の bash を実行すると `git add .rite/wiki/` が空 staging になり、`git commit` が失敗します。

### 5.1 separate_branch 戦略

> **Reference**: [Wiki ブランチへの書き込み（Ingest 時）](../../references/wiki-patterns.md#wiki-ブランチへの書き込みingest-時) のテンプレートに従う

```bash
# F-19 fix: trap を先行武装してから git branch --show-current を実行する
# F-10 fix: detached HEAD を fail-fast で検出する (current_branch 空文字の silent fall を防止)
# F-06 fix: Phase 5.2 末尾 (本ブロックの末尾) に branch_strategy unknown 時の else 分岐を追加
# F-05 fix: {n_pages_created} 等は Claude が Phase 2.1 で初期化したカウンター変数を
#           リテラル整数として substitute する (placeholder 文字列のままコミット禁止)
#
# Phase 1.2 の値をリテラルで埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # F-19 fix: パス先行宣言 → trap 先行設定 → 主処理の順序
  current_branch=""
  stash_needed=false
  _rite_wiki_ingest_cleanup() {
    if [ -n "$current_branch" ]; then
      git checkout "$current_branch" 2>/dev/null || \
        echo "WARNING: cleanup の git checkout '$current_branch' に失敗。手動で元ブランチに戻ってください" >&2
    fi
    if [ "${stash_needed:-false}" = true ]; then
      git stash pop 2>/dev/null || \
        echo "WARNING: cleanup の git stash pop に失敗。手動回復が必要: git stash list" >&2
    fi
  }
  trap 'rc=$?; _rite_wiki_ingest_cleanup; exit $rc' EXIT
  trap '_rite_wiki_ingest_cleanup; exit 130' INT
  trap '_rite_wiki_ingest_cleanup; exit 143' TERM
  trap '_rite_wiki_ingest_cleanup; exit 129' HUP

  # F-10 fix: detached HEAD を fail-fast 検出
  current_branch=$(git branch --show-current)
  if [ -z "$current_branch" ]; then
    echo "ERROR: detached HEAD 状態のため /rite:wiki:ingest を実行できません" >&2
    echo "  対処: ブランチに切り替えてから再実行してください (例: git checkout develop)" >&2
    exit 1
  fi

  # F-03 fix: untracked Raw Source も stash 対象にするため -u を追加。
  # `git diff` は untracked を検出しないため、まず untracked の有無も判定する。
  if ! git diff --quiet HEAD 2>/dev/null || \
     ! git diff --cached --quiet HEAD 2>/dev/null || \
     [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    git stash push -u -m "rite-wiki-ingest-stash" || {
      echo "ERROR: git stash push -u に失敗しました" >&2
      exit 1
    }
    stash_needed=true
  fi

  git checkout "$wiki_branch" || { echo "ERROR: git checkout '$wiki_branch' failed" >&2; exit 1; }

  # ============================================================================
  # ⚠️ 重要 — Phase 5.0 の手順 1-7 をここで実施すること:
  #
  # 1. Raw Source を Write ツールで `.rite/wiki/raw/{type}/{filename}` に書き出す
  #    (Phase 2.3 で Read 済みの本文を会話コンテキストから取得、frontmatter の ingested: true に書き換え)
  # 2. 新規 Wiki ページを Write ツールで `.rite/wiki/pages/{domain}/{slug}.md` に作成
  #    (Phase 5.3 のプレースホルダー置換ルールに従う)
  # 3. 既存 Wiki ページを Edit ツールで更新
  # 4. index.md を Edit ツールで更新 (Phase 6 参照)
  # 5. log.md に append (Phase 7 参照)
  # 6. processed_files[] 配列に処理済み Raw Source のパスを追加
  # ============================================================================

  git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }

  # F-05 fix: {n_pages_created} / {n_pages_updated} / {n_raw_sources} は Claude が
  # Phase 2.1 で初期化したカウンター変数の **整数値** に置換すること
  git commit -m "docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s)" \
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
  if [ "$stash_needed" = true ]; then
    if ! git stash pop; then
      echo "ERROR: git stash pop に失敗しました — stash が残っています" >&2
      echo "  対処: 'git stash list' で確認し、競合を手動で解消してください" >&2
      exit 1
    fi
    stash_needed=false  # cleanup trap の二重 pop 防止
  fi

  trap - EXIT INT TERM HUP

  # F-04 fix: 削除対象を processed_files[] のみに限定し、find -delete 二重サイレンサーを廃止
  # processed_files[] は Phase 5.0 の手順 6 で append された処理済みファイルパスのみを含む
  if [ "${#processed_files[@]}" -gt 0 ]; then
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
    # 空ディレクトリのみ削除 (find -depth で深い階層から処理)
    find .rite/wiki/raw -type d -empty -delete || \
      echo "WARNING: 開発ブランチ側 raw ディレクトリの空削除に失敗 (手動確認推奨)" >&2
  fi

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

### 5.2 same_branch 戦略

```bash
# Phase 1.2 の値をリテラルで埋め込む (例: branch_strategy="same_branch")
branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "same_branch" ]; then
  # ============================================================================
  # ⚠️ 重要 — Phase 5.0 の手順 1-7 をここで実施すること (separate_branch と同じ責務):
  #
  # 1. Raw Source を Write ツールで `.rite/wiki/raw/{type}/{filename}` に配置
  #    (frontmatter の ingested: true に書き換え)
  # 2. 新規/既存 Wiki ページを Write/Edit で更新
  # 3. index.md / log.md を更新
  # 4. processed_files[] 配列に処理済みパスを追加
  # ============================================================================

  git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }

  # F-05 fix: {n_pages_created} / {n_pages_updated} / {n_raw_sources} は整数値に置換
  git commit -m "docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s)" \
    || { echo "ERROR: git commit failed" >&2; exit 1; }

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
| `{confidence}` | F-27 fix: page-template.md の `confidence: medium` を Write 時点で sed/Edit 置換する。デフォルトの `medium` を変えない場合でも、Phase 4 で確信度を判定した結果を必ず明示的に置換する (high/medium/low の 3 値) |

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
| `branch_strategy` が未知の値 | F-06 fix: Phase 5.1/5.2 の bash block 末尾の `else` 分岐で fail-fast 検出 (rite-config.yml の `wiki.branch_strategy` を確認するよう案内) |
| LLM が経験則を抽出できない | 該当 Raw Source は `ingest:skip` として log.md に記録、`ingested: true` に変更、`n_skipped` を +1 |

---

## 設計原則

- **単一責任**: Ingest は「Raw Source → Wiki ページ」の変換のみ。Query (`/rite:wiki:query`) と Lint (`/rite:wiki:lint`) は別コマンド
- **冪等性**: 同じ Raw Source を再 Ingest しても結果が同じ（`ingested: true` フラグで重複防止）
- **append-only な log**: 活動ログは履歴として残し、追加のみ
- **PR diff からの分離**: `separate_branch` 戦略では Wiki 変更は wiki ブランチに閉じる。開発ブランチには Raw Source の一時ファイルすら残さない
- **opt-in**: `wiki.enabled: false` がデフォルト。既存ワークフローへの影響なし
