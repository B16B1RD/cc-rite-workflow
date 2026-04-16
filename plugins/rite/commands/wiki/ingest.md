---
description: Wiki Ingest — Raw Source から経験則を抽出・統合し Wiki ページを更新
---

# /rite:wiki:ingest

Wiki Ingest エンジン。`.rite/wiki/raw/` に蓄積された Raw Source を読解し、`.rite/wiki/pages/` 配下に経験則を統合します。新規ページの作成、既存ページの更新、`index.md` の自動更新、`log.md` への活動記録、基本的な矛盾チェックを行います。

> **責務スコープ (重要 — Issue #547 で設計変更)**: 本コマンドは **Wiki page 統合の LLM 責務のみ**を担います。Raw Source を **wiki branch に commit する責務**は `plugins/rite/hooks/scripts/wiki-ingest-commit.sh` に移譲されており、`pr/review.md` Phase 6.5.W.2 / `pr/fix.md` Phase 4.6.W.2 / `issue/close.md` Phase 4.4.W.2 から各 review-fix-close サイクル終了時に直接呼ばれます。これにより raw source の wiki branch 着地は Claude orchestrator の多段実行に依存しない single-process 契約で保証され、本コマンドの LLM 責務（page 統合）とは独立に完了します。
>
> 本コマンドが実行される時点では、raw source は既に wiki branch 側に commit 済みであることが期待されます。
>
> **実行モデル (Issue #547 で worktree ベースに移行)**: `separate_branch` 戦略では `.rite/wiki-worktree/` に wiki ブランチの git worktree を用意し、そのツリーに対して Read/Write/Edit を行います。これにより:
>
> 1. `git stash push -u` / `git checkout wiki` が不要（dev ブランチは常にそのまま）
> 2. `plugins/rite/templates/wiki/page-template.md` への dev ブランチ経由アクセスが継続可能
> 3. `processed_files[]` bash 配列のリテラル substitute 契約が不要（LLM は worktree path に直接 Write/Edit するだけ）
> 4. commit は `wiki-worktree-commit.sh` に委譲（worktree 内で `git -C ... add/commit/push` を実行）
>
> 旧 Block A/B パターン（stash → checkout → Write/Edit → add/commit/push → checkout-back → stash pop）は Issue #547 / PR で完全に廃止されました。

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
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *) wiki_enabled="true" ;;  # #483: opt-out default — 空文字 / 不明値は section/key 未指定とみなして有効化
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

### 1.2 Plugin Root の解決

> **Reference**: [Plugin Path Resolution](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files)

Phase 1.3 の `wiki-worktree-setup.sh` 呼び出しが `$plugin_root` に依存するため、wiki 初期化判定よりも前に解決します（cycle review で発覚した `WIKI_INIT_REASON=worktree_setup_failed` 早期 return の修正）。

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

以降のすべての Bash ブロックで `plugin_root` をリテラル値として埋め込んで使用してください。

### 1.3 Wiki 初期化判定と worktree セットアップ

Phase 1.1 で取得した `branch_strategy` / `wiki_branch` と Phase 1.2 で解決した `plugin_root` を使い、Wiki が初期化済みかを判定します。`separate_branch` 戦略では、wiki ブランチがローカルに存在することと `.rite/wiki-worktree/` worktree が有効に存在することを両方確認します（Issue #547）:

```bash
# Phase 1.1 / Phase 1.2 の値をリテラルで埋め込む
# (例: branch_strategy="separate_branch", wiki_branch="wiki", plugin_root="/abs/path/to/plugins/rite")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"
plugin_root="{plugin_root}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # wiki ブランチがローカル / リモートのどちらかに存在することを確認
  if ! ( git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
         git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1 ); then
    echo "WIKI_INITIALIZED=false"
    echo "WIKI_INIT_REASON=branch_missing"
  else
    # worktree をセットアップ (冪等 — 既存なら no-op、未作成なら新規作成)
    # 注意: `if ! cmd; then rc=$?` パターンは bash 仕様上 `$?` が常に `!` の終了 status (= 0) を
    # 返すため、setup.sh の真の rc を捕捉できない。`set +e; cmd; rc=$?; set -e` で明示的に capture する。
    # また、setup.sh の stderr は `>/dev/null` で捨てない (ERROR / WARNING / hint をユーザーに届ける
    # ため `>&2` で透過させる、ただし stdout は不要なため `>/dev/null` で捨てる)。
    set +e
    bash "$plugin_root/hooks/scripts/wiki-worktree-setup.sh" >/dev/null
    setup_rc=$?
    set -e
    if [ "$setup_rc" -ne 0 ]; then
      echo "WIKI_INITIALIZED=false"
      echo "WIKI_INIT_REASON=worktree_setup_failed; rc=$setup_rc"
    else
      echo "WIKI_INITIALIZED=true"
    fi
  fi
else
  if [ -f ".rite/wiki/SCHEMA.md" ]; then
    echo "WIKI_INITIALIZED=true"
  else
    echo "WIKI_INITIALIZED=false"
    echo "WIKI_INIT_REASON=schema_missing"
  fi
fi
```

**Wiki 未初期化の場合**: 早期 return:

```
Wiki が初期化されていません ({reason})。先に /rite:wiki:init を実行してください。
```

`reason=worktree_setup_failed` の場合は `wiki-worktree-setup.sh` のエラー出力を確認し、`git worktree prune` / `git fetch origin wiki:wiki` 等で復旧してから再実行してください。

**worktree path の固定**: `separate_branch` 戦略では以降のすべての Wiki 書き込みは `.rite/wiki-worktree/.rite/wiki/...` に対して行われます。Read / Write / Edit ツールには常にこの完全相対パスを渡してください。

**変数保持指示**: Phase 1.1 で出力された `branch_strategy` / `wiki_branch` および Phase 1.2 で解決した `plugin_root` の値を保持し、以降のすべての Bash ブロックで**リテラル値として埋め込んで**使用してください。Claude Code の Bash ツール間でシェル変数は保持されません。

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
| `n_warnings` | `0` | Phase 8 で Lint の全検出件数合計（矛盾・陳腐化・孤児・欠落・壊れた相互参照）を加算する。`n_warnings += n_contradictions + n_stale + n_orphans + n_missing + n_broken_refs` |

これらの値は Phase 5 の commit message 生成時にリテラル整数として **必ず置換** すること (placeholder のまま commit してはならない)。

### 2.2 候補 Raw Source の列挙 (worktree ベース)

`separate_branch` 戦略では、Raw Source は wiki ブランチ上に存在します。Issue #547 で worktree ベースに移行したため、候補列挙は `.rite/wiki-worktree/.rite/wiki/raw/` を直接 `find` するだけで完結します。dev ブランチ側の `.rite/wiki/raw/` は存在しない想定ですが、過去バージョンからのマイグレーション期を考慮して両方を探索し、dev 側に残っていれば WARNING を出して重複排除します。

```bash
# Phase 1.1 の値をリテラル値として埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

# worktree path (separate_branch 戦略時のみ有効。same_branch では空)
if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_raw_root=".rite/wiki-worktree/.rite/wiki/raw"
else
  wiki_raw_root=".rite/wiki/raw"
fi

candidates=()
# メイン候補: wiki worktree (separate_branch) or dev ツリー (same_branch)
if [ -d "$wiki_raw_root" ]; then
  find_err=$(mktemp /tmp/rite-wiki-ingest-find-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for find_err, stderr capture disabled" >&2; find_err=""; }
  while IFS= read -r f; do candidates+=("$f"); done < <(find "$wiki_raw_root" -type f -name '*.md' 2>"${find_err:-/dev/null}")
  if [ -n "$find_err" ] && [ -s "$find_err" ]; then
    echo "WARNING: find '$wiki_raw_root' が stderr 出力を返しました (permission denied / IO error の可能性):" >&2
    head -3 "$find_err" | sed 's/^/  /' >&2
    echo "  影響: 一部候補が silent に脱落した可能性があります。ディレクトリ権限を確認してください" >&2
  fi
  [ -n "$find_err" ] && rm -f "$find_err"
fi

# 旧実装ドリフト検出: separate_branch で dev ツリー側 `.rite/wiki/raw/` に残留している Raw Source を警告
# (Issue #547 / PR #548 以前の stash + checkout 経路で書き込まれた残骸がある場合を検出)
if [ "$branch_strategy" = "separate_branch" ] && [ -d ".rite/wiki/raw" ]; then
  # find / wc が IO エラーで失敗した場合も `drift_count` が空文字列にならないよう default 0 を保証し、
  # さらに数値バリデーションを通すことで `[ -gt 0 ]` の silent pass を防ぐ (cycle review HIGH #2 対応)。
  drift_count_raw=$(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  drift_count="${drift_count_raw:-0}"
  if ! [[ "$drift_count" =~ ^[0-9]+$ ]]; then
    echo "WARNING: drift_count が数値ではありません (raw='$drift_count_raw')。drift 検出を skip します" >&2
    drift_count=0
  fi
  if [ "$drift_count" -gt 0 ]; then
    echo "WARNING: dev ツリー側 '.rite/wiki/raw/' に $drift_count 件の Raw Source が残留しています" >&2
    echo "  原因: Issue #547 以前の stash + checkout 経路で書き込まれた可能性" >&2
    echo "  対処: これらは本 Ingest では処理されません。wiki-ingest-commit.sh で手動移送するか削除してください" >&2
  fi
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

**ファイル本体の取得 (worktree ベース)**: 候補パスは既に `.rite/wiki-worktree/.rite/wiki/raw/...` (separate_branch) または `.rite/wiki/raw/...` (same_branch) を直接指しているため、`git show` や `git checkout` は不要で、Read ツール / `cat` で直接読み取れます。

> **⚠️ 以下のスニペットは `for candidate in "${candidates[@]}"; do ... done` ループ内で実行されることを前提**としています (Phase 2.2 の `candidates[]` 配列を iterate)。

```bash
# Issue #547: candidate は常に実ファイルパスなので、prefix の剥がし処理は不要
actual_path="$candidate"

cat_err=$(mktemp /tmp/rite-wiki-ingest-cat-err-XXXXXX 2>/dev/null) || { echo "WARNING: mktemp failed for cat_err, stderr capture disabled" >&2; cat_err=""; }
if ! file_body=$(cat "$actual_path" 2>"${cat_err:-/dev/null}"); then
  echo "WARNING: failed to read ${actual_path}" >&2
  [ -n "$cat_err" ] && [ -s "$cat_err" ] && head -3 "$cat_err" | sed 's/^/  /' >&2
  echo "  この候補をスキップして次の Raw Source に進みます" >&2
  [ -n "$cat_err" ] && rm -f "$cat_err"
  continue
fi
[ -n "$cat_err" ] && rm -f "$cat_err"
```

**ファイル本体の取得方法**:

| 場所 | 取得コマンド |
|------|-------------|
| wiki worktree (separate_branch) | Read ツールで `.rite/wiki-worktree/.rite/wiki/raw/...` を直接読み取り |
| 開発ブランチのワークツリー (same_branch) | Read ツールで `.rite/wiki/raw/...` を直接読み取り |

**処理対象が0件の場合**: 早期 return:

```
未 Ingest の Raw Source は見つかりませんでした。
新しい経験則を蓄積するには /rite:pr:review や /rite:pr:fix の完了後に再実行してください。
```

**処理対象が確定した時点で**: cycle 2 M3 fix — Phase 2.1 で初期化した `n_raw_sources` を本時点での処理対象件数に上書きする (Phase 2.1 時点では Phase 2.3 を先読みできないため `0` で初期化されている)。

**処理対象 Raw Source の本文事前読み込み**: Phase 5 Write/Edit phase への接続のため、本時点で各 Raw Source の **完全な本文** (frontmatter + body) を Read ツールで取得し、会話コンテキストに保持しておく。Issue #547 以降はすべての候補が実ファイルパスを指すため、`git show` は使用しない。

---

## Phase 3: 既存 Wiki インデックスの読み込み

統合判定（新規ページ作成 vs 既存ページ更新）のため、現在の `index.md` を読み込みます。Issue #547 以降は worktree 経由でファイルとして直接読み取るだけなので、`git show` / stash / checkout は不要です。

```bash
# Phase 1.1 の値をリテラルで埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_index_path=".rite/wiki-worktree/.rite/wiki/index.md"
else
  wiki_index_path=".rite/wiki/index.md"
fi

if [ -f "$wiki_index_path" ]; then
  index_content=$(cat "$wiki_index_path")
else
  echo "INFO: '$wiki_index_path' not found (initial state). Treating all pages as new." >&2
  index_content=""
fi
```

LLM はこの `index_content` を読み、既存ページのタイトル一覧、ドメイン分布、最終更新日を把握します。Read ツールで `$wiki_index_path` を直接開いて全文を把握するのが最も確実です。

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

### 5.0 LLM が実行すべき具体的手順 (Issue #547 で worktree 化)

> **実行モデル**: Issue #547 以降、`separate_branch` 戦略では `.rite/wiki-worktree/` worktree のツリーに対して直接 Write/Edit を行います。旧 Block A/B の `git stash + git checkout + git checkout-back + git stash pop` 契約は **完全に廃止** されました。LLM は以下の手順を順に実施するだけで足ります:

1. **Raw Source 本文の確保**: Phase 2.3 末尾の「処理対象 Raw Source の本文事前読み込み」で Read ツールにより取得され会話コンテキストに保持された本文を、LLM の作業メモリに取り出す
2. **Raw Source の `ingested: true` 化** (全戦略共通 — create / update / skip のいずれでも実施):
   - **separate_branch**: Edit ツールで `.rite/wiki-worktree/.rite/wiki/raw/{type}/{filename}` の frontmatter `ingested: false` を `ingested: true` に書き換える。worktree は常に wiki ブランチの最新 HEAD を指しているため、既存ファイルが確実に存在する
   - **same_branch**: Edit ツールで `.rite/wiki/raw/{type}/{filename}` の frontmatter `ingested: false` を `ingested: true` に書き換える
3. **新規 Wiki ページの作成**: Phase 4 で「新規ページ作成」と決定した Raw Source について、`{plugin_root}/templates/wiki/page-template.md` を Read で読み込み (**dev 側のツリーから直接読める — worktree 化以前は checkout 後に `plugins/` が消えて読めなかったが、この問題は worktree 化で完全に解消**)、Phase 5.3 のプレースホルダーを置換した内容を Write で書き出す:
   - **separate_branch**: `.rite/wiki-worktree/.rite/wiki/pages/{domain}/{slug}.md`
   - **same_branch**: `.rite/wiki/pages/{domain}/{slug}.md`

   `n_pages_created` を +1 する
4. **既存 Wiki ページの更新**: Phase 4 で「既存ページ更新」と決定した Raw Source について、対象ページを Read で読み込み、Edit で `## 詳細` セクションへの追記、`updated` フィールド更新、`sources` 配列への追記を行う。Read / Edit のパスは step 3 と同じ worktree パス規則に従う。`n_pages_updated` を +1 する
5. **スキップ決定 Raw Source の処理**: Phase 4 で「スキップ」と決定した Raw Source について、step 2 と同じ手順で `ingested: true` 化を行い、Phase 7 の log.md 追記 step で `ingest:skip` エントリを追加する (reason も記録)。`n_skipped` を +1 する
6. **index.md の更新**: Phase 6 の指示に従い Edit で `.rite/wiki-worktree/.rite/wiki/index.md` (separate_branch) または `.rite/wiki/index.md` (same_branch) を更新する
7. **log.md への追記**: Phase 7 の指示に従い Edit で `.rite/wiki-worktree/.rite/wiki/log.md` (separate_branch) または `.rite/wiki/log.md` (same_branch) に append-only でエントリを追加する

Issue #547 以降、`processed_files[]` bash 配列のリテラル substitute 契約 / Block A / Block B の分割実行 / `wiki:` プレフィックスの二重規約はすべて不要です。LLM は worktree の実ファイルに直接 Write/Edit するだけで、差分が確実に検出されコミットされます。

### 5.1 separate_branch 戦略 (worktree ベース)

上記 Phase 5.0 手順 1-7 を Write/Edit ツールで実施した後、以下の単一 bash ブロックを実行して worktree 内の変更を commit + push します。commit 処理は `wiki-worktree-commit.sh` に完全委譲されており、LLM が bash 契約を書く必要はありません:

```bash
# Phase 5.2 same_branch と対称に set -euo pipefail を宣言する (strict mode)。
# 未定義変数参照 (`set -u`) と pipeline failure (`set -o pipefail`) を silent にしない。
set -euo pipefail

# Phase 1.1 の値をリテラルで埋め込む (例: branch_strategy="separate_branch", wiki_branch="wiki")
# wiki_branch は rc=4 (push failure) hint メッセージで参照するため bash block 冒頭で宣言する
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # plugin_root は Phase 1.2 で解決済み。LLM はリテラル値を substitute すること
  plugin_root="{plugin_root}"

  # 事前に script 存在確認 ($(...) 代入では内部コマンドの exit code が伝播しないため、
  # path 誤り等で silent OK 判定される経路を遮断する)。
  if [ ! -x "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" ]; then
    echo "ERROR: wiki-worktree-commit.sh が見つからないか実行権限がありません: $plugin_root/hooks/scripts/wiki-worktree-commit.sh" >&2
    exit 1
  fi

  # {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} は Phase 2.1 で
  # 初期化され Phase 4 / 5.0 step 5 で incrementate されたカウンター変数を整数値に substitute する
  commit_msg="docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"

  # set -e 下で script の非 0 exit を許容して rc を capture するため set +e; ... set -e で囲う。
  # 2>&1 は付けない — 構造化 stdout (committed= 行) と WARNING stderr の分離を維持する。
  set +e
  commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --message "$commit_msg")
  commit_rc=$?
  set -e
  echo "$commit_out"

  case "$commit_rc" in
    0) echo "[CONTEXT] WIKI_INGEST_COMMIT=ok" ;;
    2) echo "[CONTEXT] WIKI_INGEST_COMMIT=skipped; reason=wiki-disabled" >&2 ;;
    3)
      echo "ERROR: wiki-worktree-commit.sh 内部で git 操作失敗 (rc=3)" >&2
      echo "  対処: worktree の状態を確認してください: git -C .rite/wiki-worktree status" >&2
      exit 1
      ;;
    4)
      echo "WARNING: commit は landed したが push に失敗しました (rc=4)" >&2
      echo "  手動回復: git -C .rite/wiki-worktree push origin $wiki_branch" >&2
      # Issue #528 PR #529 と同じく push 失敗は非 fatal — ユーザーが後で回復可能
      ;;
    *)
      echo "ERROR: wiki-worktree-commit.sh が予期しない exit code ($commit_rc) を返しました" >&2
      exit 1
      ;;
  esac

elif [ "$branch_strategy" = "same_branch" ]; then
  # same_branch 戦略は Phase 5.2 で扱う
  :
else
  echo "ERROR: 未知の branch_strategy: '$branch_strategy'" >&2
  echo "  受け付け可能な値: separate_branch / same_branch" >&2
  echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください" >&2
  exit 1
fi
```

### 5.2 same_branch 戦略

**実行モデル**: `same_branch` 戦略では Raw Source / ページ / index.md / log.md はすべて現在の dev ブランチのワークツリーに存在します。Phase 5.0 の手順 1-7 を Write/Edit ツールで実施した後、以下の bash ブロックで一括 commit します。ブランチ切り替えは発生しません (worktree も不要):

```bash
set -euo pipefail

branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "same_branch" ]; then
  # Phase 5.0 step 2 / step 3-6 の Write/Edit はすでに完了している前提
  git add .rite/wiki/ || { echo "ERROR: git add .rite/wiki/ failed" >&2; exit 1; }

  # {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} は整数値に substitute する
  if ! git commit -m "docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"; then
    echo "ERROR: git commit failed" >&2
    echo "  ロールバック: staging area の .rite/wiki/ 変更を unstage します" >&2
    _reset_err=$(mktemp /tmp/rite-wiki-ingest-reset-err-XXXXXX 2>/dev/null) || _reset_err=""
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

## Phase 8: 自動 Lint

Ingest 直後、Wiki 全体の品質チェックを `/rite:wiki:lint --auto` として実行します。矛盾・陳腐化・孤児ページ・欠落概念・壊れた相互参照の 5 観点で検査します。

### 8.1 auto_lint 設定の確認

`rite-config.yml` の `wiki.auto_lint` を Phase 1.1 と同じ F-23 パーサーで読み取ります:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
auto_lint_line=""
if [[ -n "$wiki_section" ]]; then
  auto_lint_line=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_lint:/ { print; exit }') || auto_lint_line=""
fi
auto_lint=""
if [[ -n "$auto_lint_line" ]]; then
  auto_lint=$(printf '%s' "$auto_lint_line" | sed 's/[[:space:]]#.*//' | sed 's/.*auto_lint:[[:space:]]*//' | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]')
fi
case "$auto_lint" in
  true|yes|1) auto_lint="true" ;;
  false|no|0) auto_lint="false" ;;
  "") auto_lint="true" ;;  # default: true
  *) auto_lint="true" ;;
esac
echo "auto_lint=$auto_lint"
```

**`auto_lint: false` の場合**: Phase 8.2-8.5 をスキップし Phase 9 へ進みます。Phase 9 完了レポートの Lint カウンタ（`n_contradictions` / `n_stale` / `n_orphans` / `n_missing` / `n_broken_refs`）は Phase 8.3 でのみ初期化されるため、`auto_lint: false` 時は Phase 9 レポートの「Wiki 品質警告」行を「Wiki 品質警告: スキップ (auto_lint disabled)」と表示します。

### 8.2 Lint エンジンの呼び出し

> **ブランチ状態の前提** (Issue #547 で更新): 本 Phase の呼び出し時点での CWD は常に dev ブランチです (Issue #547 以降、ingest 実行中は dev ブランチから一切離脱しない worktree ベース実装のため)。lint.md Phase 8.2 は `separate_branch` 戦略時に `.rite/wiki-worktree/` worktree 内で `log.md` の追記 → `wiki-worktree-commit.sh` 呼び出しを行います。dev ブランチ側で stash / checkout が発生することはありません。

LLM は `skill: "rite:wiki:lint", args: "--auto"` 形式で `/rite:wiki:lint` を `--auto` モードで呼び出します。`--auto` モードでは:

- 出力が最小化される（`Lint: contradictions={n}, stale={n}, orphans={n}, missing={n}, broken_refs={n}` 形式の 1 行）
- 検出件数が全て 0 の場合は stdout が空
- log.md への追記は lint.md Phase 8.2 が自律的にブランチ状態を判定し実行する
- lint.md は常に exit 0（非ブロッキング）

### 8.3 Lint 実行結果の取得とパース

LLM は Lint Skill 呼び出し後の会話コンテキストから結果をパースします。Skill ツール経由の呼び出しはシェル exit code を返さないため、**stdout テキストの内容**で成否を判定します:

1. **エラー出力の確認**: Lint Skill の応答テキストに `ERROR:` や `WARNING: ... 実行失敗` が含まれる場合、失敗として扱い `n_warnings += 1` を加算して以降のパースは skip します:

   ```
   WARNING: /rite:wiki:lint --auto がエラーを返しました。
     Ingest 完了レポートには「Lint 結果: 実行失敗」と表示します。
   ```

2. **stdout のパース**: exit 0 の場合、stdout の 1 行目を正規表現 `^Lint: contradictions=([0-9]+), stale=([0-9]+), orphans=([0-9]+), missing=([0-9]+), broken_refs=([0-9]+)$` で抽出し、5 つの変数を会話コンテキストに保持します:

   | 変数 | 正規表現 group |
   |------|---------------|
   | `n_contradictions` | group 1 |
   | `n_stale` | group 2 |
   | `n_orphans` | group 3 |
   | `n_missing` | group 4 |
   | `n_broken_refs` | group 5 |

3. **stdout が空の場合**: Lint は検出 0 件で終了したとみなし、5 変数すべて `0` に設定します。

4. **1 行目が正規表現にマッチしない場合**: Lint 側のフォーマット変更を検出した警告として扱い、以下を stderr に出力してから全変数を `0` に設定します（silent に 0 件と誤認することを防ぐ）:

   ```
   WARNING: /rite:wiki:lint --auto の出力形式が期待と異なります。
     実際の出力: {first_line}
     期待される形式: Lint: contradictions=N, stale=N, orphans=N, missing=N, broken_refs=N
   ```

### 8.4 Ingest 完了レポートへの統合

Phase 9 の完了レポートに以下のように埋め込みます:

```
Lint 結果: 矛盾 {n_contradictions} 件 / 陳腐化 {n_stale} 件 / 孤児 {n_orphans} 件 / 欠落 {n_missing} 件 / 壊れた相互参照 {n_broken_refs} 件
```

**全カテゴリが 0 件の場合** (`n_contradictions + n_stale + n_orphans + n_missing + n_broken_refs == 0`): 「Lint 結果: 問題なし」とのみ表示します。**矛盾以外の 1 件以上が検出された場合は必ず全カテゴリを表示**します（旧「矛盾以外の検出が 0 件の場合」条件は論理エラーのため削除）。

### 8.5 `n_warnings` カウンタへの加算

Phase 2.1 で初期化した `n_warnings` に、Lint の全検出件数の合計を加算します:

```
n_warnings += n_contradictions + n_stale + n_orphans + n_missing + n_broken_refs
```

これにより Phase 9 の完了レポートの「Wiki 品質警告」欄に Lint 検出件数が反映されます。

**詳細な修正対応**: 検出結果の詳細確認と対応は、Ingest 完了後に `/rite:wiki:lint`（`--auto` なし）で再実行して取得してください。

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
- Wiki 品質警告: {n_warnings} 件（内訳: 矛盾 {n_contradictions} / 陳腐化 {n_stale} / 孤児 {n_orphans} / 欠落 {n_missing} / 壊れた相互参照 {n_broken_refs}）

新規/更新ページ:
- {path1} ({action1})
- {path2} ({action2})

次のステップ:
- /rite:wiki:query で経験則を参照
- 詳細な品質チェックは /rite:wiki:lint で確認してください（Phase 8 で自動実行済み）
```

---

## エラーハンドリング

| エラー | 対処 |
|--------|------|
| `wiki.enabled: false` | 早期 return（Phase 1.1） |
| Wiki 未初期化 / worktree セットアップ失敗 | `/rite:wiki:init` を案内、または `wiki-worktree-setup.sh` のエラー出力を確認して `git worktree prune` / `git fetch origin wiki:wiki` で復旧（Phase 1.3） |
| 処理対象0件 | 静かに終了し情報メッセージのみ表示（Phase 2.3） |
| `wiki-worktree-commit.sh` が exit 3 (git add/commit 失敗) | exit 1 で fail-fast。`git -C .rite/wiki-worktree status` で worktree の状態を確認する |
| `wiki-worktree-commit.sh` が exit 4 (push 失敗) | 非 fatal で継続。local wiki ブランチにコミットは残っているため、`git -C .rite/wiki-worktree push origin {wiki_branch}` で手動回復 |
| `wiki-worktree-commit.sh` が未知の exit code | exit 1 で fail-fast。予期しない状態のため worktree / script を確認する |
| `branch_strategy` が未知の値 | Phase 5.1 末尾 / Phase 5.2 末尾の `else` 分岐で fail-fast 検出 (rite-config.yml の `wiki.branch_strategy` を確認するよう案内) |
| LLM が経験則を抽出できない | 該当 Raw Source は `ingest:skip` として log.md に記録、`ingested: true` に変更、`n_skipped` を +1 |

---

## 設計原則

- **単一責任**: Ingest は「Raw Source → Wiki ページ」の変換のみ。Query (`/rite:wiki:query`) と Lint (`/rite:wiki:lint`) は別コマンド
- **冪等性**: 同じ Raw Source を再 Ingest しても結果が同じ（`ingested: true` フラグで重複防止）
- **append-only な log**: 活動ログは履歴として残し、追加のみ
- **PR diff からの分離** (Issue #547): `separate_branch` 戦略では Wiki 変更は **`.rite/wiki-worktree/` worktree 内** に閉じる。dev ブランチのツリーは一切変更されず、`.gitignore` で worktree path が除外されているため PR diff に混入しない
- **dev ブランチ不動**: Issue #547 以降、ingest 実行中に dev ブランチの HEAD が移動することはない。`git stash` / `git checkout wiki` / `git checkout-back` はすべて廃止済み
- **opt-out**: `wiki.enabled: true` がデフォルト。`wiki:` セクション未指定でも有効扱い。明示的に `wiki.enabled: false` を設定すれば従来通り無効化可能
