---
name: wiki-ingest
description: |
  rite workflow の Wiki 統合ステップ: Raw Source から経験則を抽出・統合し Wiki ページを更新する。
  /rite:cleanup から programmatic に呼ばれる sub-step、または手動 /rite:wiki-ingest。汎用の
  「知識をまとめる」ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:wiki-ingest
argument-hint: ""
---

# /rite:wiki-ingest

Wiki Ingest エンジン。`.rite/wiki/raw/` の Raw Source を読解し、`.rite/wiki/pages/` に経験則として統合する。やることは以下のシーケンシャルなタスク列:

1. 事前チェック（Wiki 設定 / plugin root / worktree セットアップ）
2. Raw Source の候補列挙と `ingested: false` 判定
3. 既存 Wiki インデックス (`index.md`) の読み込み
4. LLM による読解と統合判定（新規 / 更新 / スキップ）
5. ページの書き込み + commit（worktree ベース。push はステップ 8.6 で 1 回に集約）
6. `index.md` の更新
7. `log.md` への append-only 追記
8. 自動 Lint (`/rite:wiki-lint --auto`) + push の集約（8.6）
9. 完了レポート

Raw Source の wiki branch 着地は `wiki-ingest-commit.sh` が `review` / `fix` / `issue-close` から直接呼ばれて完了している前提。本コマンドが扱うのは page 統合の LLM 責務のみ。

`separate_branch` 戦略では `.rite/wiki-worktree/` worktree のツリーに対して Read/Write/Edit を行う。dev ブランチは ingest 実行中も常にそのまま。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md) で解決する。共通パターン (ディレクトリ構造 / ブランチ管理 / テンプレート展開) は [Wiki Patterns](../../references/wiki-patterns.md) を参照。Wiki が育たない / 動作しないときの診断手順 (raw が増えない / page が増えない / growth-check alarm の読み方) は [Wiki トラブルシューティング](./references/wiki-troubleshooting.md) を参照。

## Arguments

| Argument | Description |
|----------|-------------|
| `[raw-file-path]` | 単一の Raw Source ファイルを指定して Ingest（省略時は `.rite/wiki/raw/` 配下の `ingested: false` 全ファイルを処理） |

## Examples

```
/rite:wiki-ingest
/rite:wiki-ingest .rite/wiki/raw/reviews/20260413T...md
```

---

## ステップ 1: 事前チェック

### 1.1 Wiki 設定の読み取りとブランチ戦略判定

`rite-config.yml` から `wiki_enabled` / `wiki_branch` / `branch_strategy` を**単一の bash ブロック**で取得する (本ブロックはプローブ用。helper 解決失敗のみ明示 fail-fast で扱い、値の欠落は `${var:-default}` で吸収するため `set -euo pipefail` は不要。strict mode はステップ 5.1 / 5.2 で明示宣言する):

```bash
# YAML 読み取りは canonical helper (実ファイル) に委譲する。skill 本文の fenced bash に
# パーサを書くと Skill loader が位置パラメータを起動引数へ展開し、行マッチが恒偽化して
# 全キーが空になる (静的検出: hooks/scripts/dollar-zero-check.sh)。
# helper 不在は fail-fast: ingest は Wiki 操作そのものであり、設定不明のまま opt-out
# default で「Wiki 無効」と報告するのは、この Issue が潰した誤報告パターンの再演になる。
if ! . {plugin_root}/hooks/scripts/lib/wiki-config.sh 2>/dev/null; then
  echo "ERROR: {plugin_root}/hooks/scripts/lib/wiki-config.sh を読み込めません" >&2
  echo "  Wiki 設定を判定できないため ingest を中止します (無効扱いへは倒しません)" >&2
  echo "[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1" >&2
  exit 1
fi

wiki_enabled=$(parse_wiki_scalar enabled | tr '[:upper:]' '[:lower:]')
wiki_branch=$(parse_wiki_scalar branch_name)
branch_strategy=$(parse_wiki_scalar branch_strategy)

case "$wiki_enabled" in false|no|0) wiki_enabled=false ;; *) wiki_enabled=true ;; esac  # opt-out default
wiki_branch="${wiki_branch:-wiki}"
branch_strategy="${branch_strategy:-separate_branch}"

echo "wiki_enabled=$wiki_enabled branch_strategy=$branch_strategy wiki_branch=$wiki_branch"
```

分散実装の完全一覧と設計差異は [Wiki 有効判定パターン §分散実装ファイル一覧](../../references/wiki-patterns.md#分散実装ファイル一覧-single-source-of-truth) を SoT として参照する。本ファイルは `lib/wiki-config.sh` の `parse_wiki_scalar` を直接呼ぶ lenient 2-arm 経路 (inject.sh と同型の lenient ファミリ、opt-out default)。trigger.sh は意図的に strict 3-arm fail-fast で別経路 — 詳細は SoT を参照。

**`[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1` (bash が rc=1 で終了) の場合**: 設定を判定できていないため無効扱いへ倒さず、そのまま中止してユーザーに案内する:

```
Wiki 設定を読み取れませんでした（hooks/scripts/lib/wiki-config.sh を解決できません）。
plugin のインストール状態を確認するか /rite:setup を再実行してください。
```

**`wiki_enabled=false` の場合**: 早期 return:

```
Wiki 機能が無効です（wiki.enabled: false）。
有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki-init を実行してください。
```

### 1.2 Plugin Root の解決

ステップ 1.3 の `wiki-worktree-setup.sh` 呼び出しが `$plugin_root` に依存するため、Wiki 初期化判定よりも前に解決する:

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

以降のすべての Bash ブロックでは `plugin_root` / `branch_strategy` / `wiki_branch`、および ステップ 1.3 で取得した `wiki_worktree_abs`（`WIKI_WORKTREE_ABS` の値）をリテラル値として埋め込んで使用する（Claude Code の Bash ツール間でシェル変数は保持されない）。

### 1.3 Wiki 初期化判定と worktree セットアップ

ステップ 1.1 で取得した `branch_strategy` / `wiki_branch` とステップ 1.2 の `plugin_root` を使い、wiki ブランチの存在と worktree の有効性を確認する。`separate_branch` 戦略では、ブランチがローカル/リモートのどちらかに存在することと worktree が有効に存在することを両方確認する:

```bash
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"
plugin_root="{plugin_root}"

if [ "$branch_strategy" = "separate_branch" ]; then
  if ! ( git rev-parse --verify "origin/${wiki_branch}" >/dev/null 2>&1 || \
         git rev-parse --verify "${wiki_branch}" >/dev/null 2>&1 ); then
    echo "WIKI_INITIALIZED=false"
    echo "WIKI_INIT_REASON=branch_missing"
  else
    # `if ! cmd; then rc=$?` は bash 仕様で常に rc=0 を返すため、set +e/-e で明示的に rc を捕捉する。
    # setup.sh の stderr は ERROR / WARNING / hint をユーザーに届けるため stderr に透過させ、
    # stdout のみ /dev/null に捨てる。
    set +e
    setup_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-setup.sh")
    setup_rc=$?
    set -e
    if [ "$setup_rc" -ne 0 ]; then
      echo "WIKI_INITIALIZED=false"
      echo "WIKI_INIT_REASON=worktree_setup_failed; rc=$setup_rc"
    else
      # Capture the ABSOLUTE wiki worktree path from the setup status line
      # ([wiki-worktree-setup] status=...; path=<abs>; branch=...). All
      # subsequent Wiki Read/Write/Edit + bash use this absolute base so ingest
      # is cwd-independent — it resolves to the single shared-root wiki worktree
      # even when invoked directly from a session worktree (multi-session §9).
      # Fall back to the shared-root resolver if the field is '-' (skip line).
      wiki_wt_abs=$(printf '%s\n' "$setup_out" | sed -n 's/.*; path=\([^;]*\);.*/\1/p' | head -1)
      if [ -z "$wiki_wt_abs" ] || [ "$wiki_wt_abs" = "-" ]; then
        wiki_wt_abs="$(bash "$plugin_root/hooks/state-path-resolve.sh")/.rite/wiki-worktree"
      fi
      echo "WIKI_INITIALIZED=true"
      echo "WIKI_WORKTREE_ABS=$wiki_wt_abs"
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
Wiki が初期化されていません ({reason})。先に /rite:wiki-init を実行してください。
```

`reason=worktree_setup_failed` の場合は `wiki-worktree-setup.sh` のエラー出力を確認し、`git worktree prune` / `git fetch origin wiki:wiki` 等で復旧してから再実行する。

`separate_branch` の場合、ステップ 1.3 が出力した絶対パス `WIKI_WORKTREE_ABS` を基点に（以降 `{wiki_worktree_abs}` として `plugin_root` と同様にリテラル埋め込みする）、すべての Wiki Read / Write / Edit と bash ブロックは `{wiki_worktree_abs}/.rite/wiki/...` で指す。これにより呼び出し時の cwd（セッション worktree でも main checkout でも）に依存せず、常に共有 root の wiki worktree 一箇所に解決される（multi-session design §9 / AC-5）。`{wiki_worktree_abs}` が空（旧バージョン互換のため未取得の場合）は `.rite/wiki-worktree` の相対パスに縮退してよい。

### 1.4 Ingest セッション lock の取得（並行 ingest の直列化）

複数セッションが同時に ingest（cleanup → ingest 連鎖を含む）へ入っても安全になるよう、LLM の Write/Edit フェーズを直列化する。`flock` は複数 Bash 呼び出しに跨る ingest を守れないため、ingest 期間中保持する持続的 mkdir lock（`<共有root>/.rite/state/wiki-ingest-session.lockdir`）を取得する。stale 判定は保持セッションの flow-state liveness（`active=true` ∧ `updated_at` 2h 以内）を流用する（multi-session design §9）:

```bash
plugin_root="{plugin_root}"
bash "$plugin_root/hooks/scripts/wiki-ingest-lock.sh" acquire
```

出力で分岐する:

- `acquired` / `acquired_stale_reclaimed`（rc 0）: 取得成功。ステップ 2 以降へ進む。
- `concurrent_ingest`（rc 11）: 他の live セッションが ingest 中。**以下を出力して即座に終了する**（pending raw は wiki branch に残り、次回 ingest が冪等に回収する — AC-4。新しい回収機構は作らない）:

  ```
  [CONTEXT] WIKI_INGEST_SKIPPED reason=concurrent_ingest
  ```

  別セッションの ingest と競合したため今回はスキップしました。未処理の Raw Source は次回の ingest で自動的に回収されます。

ステップ 9 完了時（およびエラー終了時）に `wiki-ingest-lock.sh release` で解放する（ステップ 9 参照）。

---

## ステップ 2: Raw Source の解決

### 2.1 引数の判定とカウンター変数の初期化

引数 `<raw-file-path>` が指定されている場合は単一ファイルを Ingest 対象とし、省略時は `.rite/wiki/raw/` 配下から `ingested: false` を持つ Raw Source を全て列挙する。

以下のカウンターを会話コンテキストに保持し、各ステップで incrementate する。値は ステップ 5 commit message と ステップ 9 完了レポートで literal substitute されるため、placeholder のまま使用してはならない:

| 変数 | 初期値 | 確定 / incrementate するタイミング |
|------|:--:|---|
| `n_raw_sources` | 0 | ステップ 2.3 末尾で処理対象件数に上書き |
| `n_pages_created` | 0 | ステップ 4 で「新規ページ作成」決定ごとに +1 |
| `n_pages_updated` | 0 | ステップ 4 で「既存ページ更新」決定ごとに +1 |
| `n_skipped` | 0 | ステップ 4 で「スキップ」決定ごとに +1 |
| `n_warnings` | 0 | ステップ 8.5 で Lint の検出件数合計（`n_unregistered_raw` を除く 5 カテゴリ）を加算。加えて ステップ 8.3 の Lint 実行異常検出時 `n_warnings += 1` と `n_lint_anomaly += 1` を並行加算。さらに ステップ 6 手順 3 の統計同期が中止した場合（`[CONTEXT] WIKI_INGEST_STATS=aborted`）も `n_warnings += 1`（`n_lint_anomaly` は Lint 由来の指標なので加算しない） |
| `n_lint_anomaly` | 0 | ステップ 8.3 step 1/3/4 (ERROR 行検出 / stdout 空 / regex mismatch) でそれぞれ +1。`n_warnings` と並行加算 |
| `n_contradictions` / `n_stale` / `n_orphans` / `n_missing_concept` / `n_unregistered_raw` / `n_broken_refs` | 0 | ステップ 8.3 step 2 (6 フィールド regex match) で Lint stdout から抽出 |

`n_unregistered_raw` は informational 指標で `n_warnings` には加算しない（意図的に経験則化しなかった件数は警告ではない）。`auto_lint=false` 経路で ステップ 8.2-8.5 が skip された場合も、本ステップで 0 初期化されているためステップ 9 完了レポートの placeholder 残留は発生しない。

### 2.2 候補 Raw Source の列挙 (worktree ベース)

`separate_branch` 戦略では Raw Source は wiki ブランチ上にあり、`{wiki_worktree_abs}/.rite/wiki/raw/` を直接 find する。dev ブランチ側 (`.rite/wiki/raw/`) は通常存在しないが、過去バージョンからのマイグレーション残骸を検出するために存在チェックして WARNING を出す:

```bash
branch_strategy="{branch_strategy}"
wiki_wt_abs="{wiki_worktree_abs}"

if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_raw_root="${wiki_wt_abs:-.rite/wiki-worktree}/.rite/wiki/raw"
else
  wiki_raw_root=".rite/wiki/raw"
fi

candidates=()
if [ -d "$wiki_raw_root" ]; then
  # signal-specific trap (EXIT/INT/TERM/HUP) で find_err tempfile orphan 防止。
  # 詳細は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照。
  find_err=""
  _cleanup() { [ -n "${find_err:-}" ] && rm -f "$find_err"; return 0; }
  trap 'rc=$?; _cleanup; exit $rc' EXIT
  trap '_cleanup; exit 130' INT
  trap '_cleanup; exit 143' TERM
  trap '_cleanup; exit 129' HUP

  find_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-ingest-find-err-XXXXXX" 2>/dev/null) || {
    echo "WARNING: stderr 退避 tempfile (find_err) の mktemp に失敗しました。find の詳細エラー情報は失われます" >&2
    echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
    echo "  影響: permission denied で raw source が silent 脱落する可能性があります" >&2
    find_err=""
  }
  while IFS= read -r f; do candidates+=("$f"); done < <(find "$wiki_raw_root" -type f -name '*.md' 2>"${find_err:-/dev/null}")
  if [ -n "$find_err" ] && [ -s "$find_err" ]; then
    echo "WARNING: find '$wiki_raw_root' が stderr 出力を返しました (permission denied / IO error の可能性):" >&2
    head -3 "$find_err" | sed 's/^/  /' >&2
    echo "  影響: 一部候補が silent に脱落した可能性があります。ディレクトリ権限を確認してください" >&2
  fi
  [ -n "$find_err" ] && rm -f "$find_err"
fi

# 旧 stash+checkout 経路の残骸検出 (separate_branch のみ)
if [ "$branch_strategy" = "separate_branch" ] && [ -d ".rite/wiki/raw" ]; then
  drift_count_raw=$(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  drift_count="${drift_count_raw:-0}"
  [[ "$drift_count" =~ ^[0-9]+$ ]] || drift_count=0
  if [ "$drift_count" -gt 0 ]; then
    echo "WARNING: dev ツリー側 '.rite/wiki/raw/' に $drift_count 件の Raw Source が残留しています" >&2
    echo "  対処: 本 Ingest では処理されません。wiki-ingest-commit.sh で移送するか手動削除してください" >&2
  fi
fi

printf 'Found %d candidate raw source(s)\n' "${#candidates[@]}"
for c in "${candidates[@]}"; do echo "  - $c"; done
```

### 2.3 Ingested フラグの判定

各候補ファイルの YAML frontmatter から `ingested:` を読み、`false` / `no` / `0` / 未設定のものを処理対象とする（YAML spec 準拠の lowercase + quote 除去で正規化）。引数で単一ファイル指定時は値に関わらず処理対象とする（再 Ingest 許可）。

`for candidate in "${candidates[@]}"; do ... done` ループ内で以下を実行する:

```bash
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
ingested_norm=$(printf '%s' "$ingested_value" | tr -d '"'\''' | tr '[:upper:]' '[:lower:]')
case "$ingested_norm" in
  false|no|0|"") process="yes" ;;
  *) process="no" ;;
esac
```

候補は worktree (separate_branch) または dev ツリー (same_branch) を直接 Read / `cat` で読み取れる（`git show` / `git checkout` は不要）。読み取り失敗時は WARNING を出して次の候補へ:

```bash
# signal-specific trap (EXIT/INT/TERM/HUP) は反復ごとに再設定される (bash 仕様で idempotent)。
cat_err=""
_cleanup() { [ -n "${cat_err:-}" ] && rm -f "$cat_err"; return 0; }
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

cat_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-ingest-cat-err-XXXXXX" 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (cat_err) の mktemp に失敗しました。cat の詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: file body 読取失敗の根本原因 (permission / IO error) が不可視になります" >&2
  cat_err=""
}
if ! file_body=$(cat "$candidate" 2>"${cat_err:-/dev/null}"); then
  echo "WARNING: failed to read $candidate" >&2
  [ -n "$cat_err" ] && [ -s "$cat_err" ] && head -3 "$cat_err" | sed 's/^/  /' >&2
  echo "  この候補をスキップして次の Raw Source に進みます" >&2
  [ -n "$cat_err" ] && rm -f "$cat_err"
  continue
fi
[ -n "$cat_err" ] && rm -f "$cat_err"
```

**処理対象が 0 件の場合**: 早期 return:

```
未 Ingest の Raw Source は見つかりませんでした。
新しい経験則を蓄積するには /rite:pr-review や /rite:fix の完了後に再実行してください。
```

**処理対象が確定したら**: ステップ 2.1 で初期化した `n_raw_sources` を件数に上書きする。各 Raw Source の完全な本文 (frontmatter + body) を Read ツールで取得し、会話コンテキストに保持する（ステップ 5 の Write/Edit phase で参照）。

---

## ステップ 3: 既存 Wiki インデックスの読み込み

統合判定 (新規 vs 更新) のため `index.md` を読み込む:

```bash
branch_strategy="{branch_strategy}"
wiki_wt_abs="{wiki_worktree_abs}"
if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_index_path="${wiki_wt_abs:-.rite/wiki-worktree}/.rite/wiki/index.md"
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

LLM は Read ツールで `$wiki_index_path` を直接開き、既存ページのタイトル一覧・ドメイン分布・最終更新日を把握する。

---

## ステップ 4: LLM による読解と統合判定

ステップ 2.3 で確定した処理対象 Raw Source 1 件ずつに対して、LLM が以下を行う:

1. **読解**: Raw Source 本文から抽出可能な経験則を特定
2. **ドメイン判定**: `patterns` / `heuristics` / `anti-patterns` に分類
3. **既存ページ照合**: `index.md` に同テーマの既存ページが存在するかを意味的に判定 (厳密一致ではなく、一行サマリーとタイトルから判断)
4. **アクション決定**: 下表に従い 新規 / 更新 / スキップ を決定
5. **関連ページ特定**: ステップ 5.3 の `{related_page_title}` / `{related_page_path}` の値を決定 (詳細はステップ 4.3)

| 判定 | アクション |
|------|----------|
| 同テーマの既存ページなし | 新規ページ作成 |
| 同テーマの既存ページあり | 既存ページ更新（追記 or 統合） |
| 経験則が抽出できない（一時的な情報のみ） | スキップ（理由を log に記録） |

### 4.1 タイトル/ドメイン/サマリーの生成

新規ページ作成時、LLM は以下を生成する:

| フィールド | ガイドライン |
|-----------|-------------|
| `title` | 経験則を 1 行で表現（30-60 字推奨） |
| `domain` | `patterns` / `heuristics` / `anti-patterns` |
| `summary` | 1-2 文の要約（index.md に掲載される） |
| `details` | 背景・具体例・根拠を含む詳細 |
| `confidence` | `high` / `medium` / `low`（根拠の強さ） |

ファイル名は `pages/{domain}/{slug}.md`、`slug` は `title` を kebab-case 化（最大 60 文字）。

### 4.2 既存ページ更新時の統合方針

- **追記**: 既存内容と矛盾せず補強する場合は「## 詳細」セクションに追記
- **統合**: 一部矛盾するが新情報の方が確度が高い場合は該当箇所を書き換え（`updated` フィールド更新）
- **`sources` 配列追記**: 新しい Raw Source への参照を必ず追加する。追加する各エントリは `- type: "{type}"` / `  ref: "raw/{type}/{filename}"` の形式とし、**`ref` は必ず Raw Source のファイルパス形式 (`raw/{type}/{filename}`、wiki-root 起点)** にする。raw frontmatter の `source_ref` フィールド値（PR 識別子形式、例: `pr-1143`）を `ref` に転記してはならない（ステップ 5.3 `{source_ref}` 行の dual-use 警告と同一契約）
- **`updated` 更新**: 現在の ISO 8601 タイムスタンプに更新
- **`description` の新設・更新**: 本サイクルで概要が変わった場合は frontmatter `description` を更新する（未設定なら新設してよい）。ステップ 6 手順 2 のサマリー列はこの値を第 1 候補として読むため、ここを更新しないと index のサマリーは既存値が保持される

### 4.3 関連ページの特定

新規ページ作成・既存ページ更新のいずれの場合も、ステップ 5.3 で展開する `{related_page_title}` / `{related_page_path}` placeholder の値を本ステップで決定する（本セクションが値決定手順の canonical source。ステップ 5.3 placeholder 表との矛盾発生時は本 4.3 を優先）。

**実行タイミング**: ステップ 4.1 でタイトル/ドメイン決定後、ステップ 5 の Write/Edit に進む前。

**選定基準**:

| 基準 | 説明 |
|------|------|
| Semantic 近接性 | `index.md` の登録ページ一覧（テーブル行）から、本ページと同ドメインの隣接トピック、または別ドメインだが概念的に関連するページを選定する |
| 確信度 | LLM の判定として確信があるもの 1-3 件に絞る（量より質） |
| index.md との照合 | ステップ 3 で読み込んだ `index_content` の一行サマリーとタイトルから判断する |

**title 規約**: `{related_page_title}` は対象ページの frontmatter `title` フィールドと **literal 一致** させる。独自言い換えは禁止 (index.md ↔ link text の drift 防止)。`index.md` 登録行の link text は同じ値だが、ステップ 6 のセル区切りエスケープ（`|` → `\|`）が適用されている場合がある — **literal 一致の基準は frontmatter `title` の生値**であり、index 側のエスケープは表記上の措置なので転記してはならない。

**path 計算規約**: `{related_page_path}` には **page-dir 相対** の path を substitute する。新規 page 格納位置 `.rite/wiki/pages/{domain}/{slug}.md` の page-dir = `.rite/wiki/pages/{domain}/` を起点として相対 path を計算する:

| ケース | path 例 (推奨形) |
|--------|------------------|
| 同ドメイン内 | `./other-page.md` (`./` prefix 付き推奨。page-dir 相対の意図を視覚的に表現する) |
| 別ドメイン | `../{domain}/other-page.md` |

`{source_ref}` (template 側で `../../` prefix を hardcode、wiki-root 起点) とは起点が異なるため、`{related_page_path}` には template リテラル側で prefix を付けず、placeholder 値そのものに page-dir 相対 path を入れる。

**該当ページなし時の処理**: 確信ある関連ページが特定できない場合、`## 関連ページ` セクション全体を Edit ツールで以下に置き換える（空 placeholder のままだと Markdown リンク `[]()` が破綻するため）:

```
## 関連ページ

- （関連ページなし）
```

`{related_page_title}` / `{related_page_path}` の両 placeholder への substitute は行わず、セクション全体差し替えを優先する。

---

## ステップ 5: ページの書き込み

ステップ 4 で決定したアクション (新規 / 更新) を、ブランチ戦略に応じて適用する。

### 5.0 LLM が実行すべき具体的手順 (worktree ベース)

`separate_branch` では `{wiki_worktree_abs}/` worktree のツリー（ステップ 1.3 で取得した絶対パス）に対して、`same_branch` では dev ツリーに対して直接 Write/Edit する。絶対パスを使うことで、ingest がセッション worktree 内から起動された場合でも共有 root の wiki worktree に正しく書き込まれる（§9 / AC-5）。LLM は以下を順に実施するだけ:

1. **Raw Source 本文の確保**: ステップ 2.3 末尾で取得した本文を作業メモリに展開
2. **Raw Source の `ingested: true` 化** (全戦略共通 — create / update / skip いずれでも実施):
   - **separate_branch**: Edit ツールで `{wiki_worktree_abs}/.rite/wiki/raw/{type}/{filename}` の frontmatter `ingested: false` を `ingested: true` に書き換える
   - **same_branch**: Edit ツールで `.rite/wiki/raw/{type}/{filename}` を書き換える
3. **新規 Wiki ページの作成** (ステップ 4 で新規決定): `{plugin_root}/templates/wiki/page-template.md` を Read で読み、ステップ 5.3 のプレースホルダーを置換した内容を Write:
   - **separate_branch**: `{wiki_worktree_abs}/.rite/wiki/pages/{domain}/{slug}.md`
   - **same_branch**: `.rite/wiki/pages/{domain}/{slug}.md`

   `n_pages_created` を +1 する

   > **複数 Raw Source からの作成**: page-template.md の `sources:` は単一スロット（`{source_type}`/`{source_ref}` 各 1 個）のみ。multi-cycle PR 等で複数の Raw Source を 1 ページに統合する場合は、Write 後に Edit で `- type: "{type}"` / `  ref: "raw/{type}/{filename}"` エントリを追加する。**追加・置換するすべての `ref` は Raw Source のファイルパス形式 (`raw/{type}/{filename}`)** であり、raw frontmatter の `source_ref` フィールド値（PR 識別子形式）ではない（ステップ 5.3 `{source_ref}` 行の dual-use 警告と同一契約）。
4. **既存 Wiki ページの更新** (ステップ 4 で更新決定): 対象ページを Read で読み、Edit で `## 詳細` 追記・`updated` 更新・`sources` 配列追記。`n_pages_updated` を +1 する。**`sources` に追記する各 `ref` は必ず Raw Source のファイルパス形式 `raw/{type}/{filename}`**（PR 識別子形式 `pr-NNNN` 禁止。ステップ 4.2 / 5.3 と同一契約）
5. **スキップ決定の処理** (ステップ 4 で skip 決定): step 2 と同じ手順で `ingested: true` 化し、**さらに当該 raw frontmatter に `ingest_status: skipped` と `skip_reason: "{理由}"` を Edit で追記する**（skip 状態の Source of Truth は raw frontmatter。lint の `wiki-lint-skipped-refs.sh` がこれを走査して `unregistered_raw` を判定する。Issue #1520）。ステップ 7 の log.md には人間向けの Skip エントリ (OKF bullet) も追記する。`n_skipped` を +1 する
6. **index.md の更新**: ステップ 6 の指示に従い Edit する
7. **log.md への追記**: ステップ 7 の指示に従い Edit で append-only 追加する

### 5.0.c canonical commit message 契約

ステップ 5.1 (separate_branch) と ステップ 5.2 (same_branch) の両 bash block で使用する commit message は以下を **唯一の真実源** とする。両 phase は独立した bash block (Bash tool 呼び出し間でシェル状態が継承されない) のため、両サイトで以下と literal 一致する実装を保持する。drift 検出は将来 /rite:lint が本 section と ステップ 5.1 / 5.2 を grep で比較する予定。

**canonical template**:

```
docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})
```

**canonical placeholder-residue gate**:

```bash
case "$commit_msg" in
  *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
    echo "ERROR: ステップ 5.{X} の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
    echo "  対処: ステップ 2.1 / 4 / 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する" >&2
    exit 1
    ;;
esac
```

ステップ 5.1 / 5.2 では `commit_msg=` 行を上記 canonical と literal 一致させ、placeholder-residue gate のサイト識別子 (`ステップ 5.{X}`) のみを 5.1 / 5.2 で置換する。template を変更する際は本セクション + ステップ 5.1 + ステップ 5.2 の **3 箇所を必ず同時に更新する**。

### 5.1 separate_branch 戦略 (worktree ベース)

ステップ 5.0 手順 1-7 を Write/Edit ツールで実施した後、以下の bash ブロックを実行して worktree 内の変更を commit する。**push はここでは行わない**（#1941 wiki push batch/defer: 複数 raw source を処理するループの中で raw source ごとに push すると、SSH host alias 環境で毎回 sandbox バイパスが必要になり同一 push の短時間重複実行も起きていた。ステップ 8.6 で全 raw source 処理後にまとめて 1 回だけ push する）。commit 処理は `wiki-worktree-commit.sh --commit-only` に委譲されており、LLM が bash 契約を書く必要はない:

```bash
# ステップ 5.2 と対称に set -euo pipefail を宣言する (strict mode)
set -euo pipefail

branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  plugin_root="{plugin_root}"
  wiki_wt_abs="{wiki_worktree_abs}"; wiki_wt_abs="${wiki_wt_abs:-.rite/wiki-worktree}"

  # script の rc は $(...) 代入では伝播しないため、事前に存在確認する
  if [ ! -x "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" ]; then
    echo "ERROR: wiki-worktree-commit.sh が見つからないか実行権限がありません: $plugin_root/hooks/scripts/wiki-worktree-commit.sh" >&2
    exit 1
  fi

  # {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} は
  # ステップ 2.1 で初期化され ステップ 4 / 5.0 step 5 で incrementate されたカウンター値を literal substitute する。
  # ステップ 5.0.c canonical commit message と literal 一致させること。
  commit_msg="docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"

  case "$commit_msg" in
    *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
      echo "ERROR: ステップ 5.1 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
      echo "  対処: ステップ 2.1 / 4 / 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する" >&2
      exit 1
      ;;
  esac

  # set -e 下で script の非 0 exit を許容して rc を capture する
  set +e
  commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --commit-only --message "$commit_msg")
  commit_rc=$?
  set -e
  echo "$commit_out"

  case "$commit_rc" in
    0) echo "[CONTEXT] WIKI_INGEST_COMMIT=ok" ;;
    2) echo "[CONTEXT] WIKI_INGEST_COMMIT=skipped; reason=wiki-disabled" >&2 ;;
    3)
      echo "ERROR: wiki-worktree-commit.sh 内部で git 操作失敗 (rc=3)" >&2
      echo "  対処: git -C \"$wiki_wt_abs\" status で worktree の状態を確認" >&2
      exit 1
      ;;
    *)
      # --commit-only は push を行わないため rc=4 (push 失敗) はここでは発生しない。
      echo "ERROR: wiki-worktree-commit.sh が予期しない exit code ($commit_rc) を返しました" >&2
      exit 1
      ;;
  esac

elif [ "$branch_strategy" = "same_branch" ]; then
  # same_branch はステップ 5.2 で扱う
  :
else
  echo "ERROR: 未知の branch_strategy: '$branch_strategy' (受け付け: separate_branch / same_branch)" >&2
  echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください" >&2
  exit 1
fi
```

### 5.2 same_branch 戦略

`same_branch` では Raw Source / ページ / index.md / log.md はすべて dev ブランチのワークツリーに存在する。ステップ 5.0 手順 1-7 を Write/Edit で実施した後、以下の bash ブロックで一括 commit する (ブランチ切り替え不要、worktree も不要):

```bash
set -euo pipefail
branch_strategy="{branch_strategy}"

if [ "$branch_strategy" = "same_branch" ]; then
  # signal-specific trap (EXIT/INT/TERM/HUP) で _reset_err tempfile orphan 防止。
  # 詳細は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照。
  _reset_err=""
  _cleanup() { [ -n "${_reset_err:-}" ] && rm -f "$_reset_err"; return 0; }
  trap 'rc=$?; _cleanup; exit $rc' EXIT
  trap '_cleanup; exit 130' INT
  trap '_cleanup; exit 143' TERM
  trap '_cleanup; exit 129' HUP

  # same_branch 戦略では .gitignore に `!.rite/wiki/` negation が必要。
  # 失敗時は anchor marker (gitignore-wiki-section-start) を案内する。
  add_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-ingest-add-err-XXXXXX" 2>/dev/null) || add_err=""
  if ! git add .rite/wiki/ 2>"${add_err:-/dev/null}"; then
    echo "ERROR: git add .rite/wiki/ failed" >&2
    if [ -n "$add_err" ] && [ -s "$add_err" ]; then
      echo "  詳細 (git add stderr 先頭 5 行):" >&2
      head -5 "$add_err" | sed 's/^/    /' >&2
    fi
    echo "  原因候補: same_branch 戦略で .gitignore に '!.rite/wiki/' negation が未設定の可能性" >&2
    echo "  対処:" >&2
    echo "    1. grep -n 'gitignore-wiki-section-start' .gitignore で anchor 位置を特定" >&2
    echo "    2. 同ブロック内の手順に従い '!.rite/wiki/' negation を追加し、git add --dry-run で verification してから再実行" >&2
    echo "    3. それ以外の原因 (permission / disk full / corrupt index 等) は上記 stderr の詳細を確認" >&2
    [ -n "$add_err" ] && rm -f "$add_err"
    exit 1
  fi
  [ -n "$add_err" ] && rm -f "$add_err"

  # {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} を literal substitute する。
  # ステップ 5.0.c canonical commit message と literal 一致させること。
  commit_msg="docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"

  case "$commit_msg" in
    *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
      echo "ERROR: ステップ 5.2 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
      echo "  対処: ステップ 2.1 / 4 / 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する" >&2
      exit 1
      ;;
  esac

  if ! git commit -m "$commit_msg"; then
    echo "ERROR: git commit failed" >&2
    echo "  ロールバック: staging area の .rite/wiki/ 変更を unstage します" >&2
    _reset_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-ingest-reset-err-XXXXXX" 2>/dev/null) || {
      echo "  WARNING: stderr 退避 tempfile (_reset_err) の mktemp に失敗しました。git reset の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: git reset 失敗の根本原因 (index lock / permission denied 等) が不可視になります" >&2
      _reset_err=""
    }
    if ! git reset HEAD .rite/wiki/ 2>"${_reset_err:-/dev/null}"; then
      echo "  WARNING: git reset HEAD .rite/wiki/ に失敗。手動で unstage してください: git reset HEAD .rite/wiki/" >&2
      [ -n "${_reset_err:-}" ] && [ -s "${_reset_err:-}" ] && head -3 "$_reset_err" | sed 's/^/    /' >&2
    fi
    [ -n "${_reset_err:-}" ] && rm -f "$_reset_err"
    _reset_err=""
    echo "  注意: Write/Edit した ingested:true 化と index.md / log.md 変更はワークツリーに残っています" >&2
    echo "  対処: git status で変更内容を確認後、手動で commit するか git checkout で破棄してください" >&2
    exit 1
  fi
  # same_branch では raw cleanup は不要 (PR diff に含めるのが意図的選択)
  trap - EXIT INT TERM HUP
fi
```

### 5.3 新規ページのテンプレート展開

新規ページ作成時は `{plugin_root}/templates/wiki/page-template.md` を読み込み、以下のプレースホルダーを置換した上で書き込む:

| プレースホルダー | 値 |
|----------------|-----|
| `{concept_type}` | OKF v0.1 必須フィールド。page-template.md の frontmatter トップレベル `type:` に substitute する concept 種別。値は `{domain}` と同じ literal（`patterns` / `heuristics` / `anti-patterns`）を入れる。OKF consumer の type ベース routing 用。**⚠️ 本 placeholder は同名衝突回避のため `{concept_type}` と命名している** — ステップ 4.2 / 5.0 の `raw/{type}/{filename}` パスや `sources[].type` 追記で使う `{type}` は Raw Source type（`reviews` / `retrospectives` / `fixes`、`{source_type}` 由来）であり別物 |
| `{title}` | ステップ 4.1 で生成したタイトル |
| `{domain}` | `patterns` / `heuristics` / `anti-patterns` |
| `{description}` | ステップ 4.1 のサマリー（`{summary}` と同源の 1-2 文）。OKF 推奨の concept 説明文として page frontmatter `description` に機械可読で保持し、ステップ 6 で index.md 登録行のサマリー列にも反映する。**⚠️ 読み手側は未対応**: `/rite:wiki-query` の Pass 1（`hooks/wiki-query-inject.sh`）は候補抽出が箇条書き行限定のため、テーブル形式 index ではサマリー列を消費しない（キーワード照合に使われるのは箇条書き形式で運用されている index のみ。読み手のテーブル対応は Issue #2053） |
| `{created}` / `{updated}` | 現在の ISO 8601 タイムスタンプ |
| `{source_type}` | Raw Source の `type` フィールド (`reviews` / `retrospectives` / `fixes` の 3 値のみ — `wiki-ingest-trigger.sh` が受理する値と一致) |
| `{source_ref}` | Raw Source の wiki-root 起点ファイル相対パス（例: `raw/reviews/20260413T...md`）。template 側で `../../` prefix を hardcode するため、placeholder 値自体には prefix を含めない。**⚠️ raw frontmatter の `source_ref` フィールド値（PR 識別子、例: `pr-1143`）をそのまま使ってはならない** — page の `sources[].ref` は常に Raw Source の**ファイルパス形式** `raw/{type}/{filename}` であり、PR 識別子形式ではない（同名 placeholder と raw フィールドの dual-use 混同による drift。概念は Wiki anti-pattern `placeholder-dual-use-resolution-drift`〔wiki ブランチに蓄積される経験則ページ。develop ツリーには実体なし〕）。lint はこの `ref` をファイルパス形式で raw と突合するため、PR 識別子だと raw→page 追跡が切れ false `missing_concept` を量産する |
| `{summary}` | ステップ 4.1 のサマリー |
| `{details}` | ステップ 4.1 の詳細 |
| `{related_page_title}` / `{related_page_path}` | ステップ 4.3 で決定した値。**該当ページがない場合は `## 関連ページ` セクション全体を `- （関連ページなし）` の平文 1 行に Edit で書き換える** (空 placeholder のままにすると Markdown link `[]()` が破綻) |
| `{source_description}` | Raw Source の `title` フィールド (空なら `source_ref` を使用)。`## ソース` セクションのリンク表示テキストに使われ、URL には `{source_ref}` が使われることで両者を分離する |

**confidence フィールド**: page-template.md の `confidence: medium` はリテラル値で、placeholder 走査の誤置換を避けるため上表とは別管理。Write 後に Edit で ステップ 4 の判定値 (`high` / `medium` / `low`) に置換する。

---

## ステップ 6: index.md の更新

`.rite/wiki/index.md` の `## ページ一覧` セクションにある **5 列 GFM テーブル**（列順: ページ / ドメイン / サマリー / 更新日 / 確信度）を更新する。テーブルの**内側**に別形式の行を挿入すると挿入行以降の構造が崩れるため、テーブル節の中には本ステップが規定するテーブル行だけを置く（節の外にある旧テンプレート由来の箇条書き行は GFM 上テーブルと別ブロックとして共存するので、削除も移送もせずそのまま残す）。

**セル区切り文字のエスケープ（新規追加・既存更新の両経路に適用）**: `{title}` / `{description}`、および手順 2 で既存行から保持したサマリー列の値に `|` が含まれる場合、index 登録行では `\|` にエスケープして substitute する。**インラインコード `` ` `` の内側も対象** — GFM はコードスパン内の生 `|` もセル区切りとして解釈するため、エスケープしないと列がずれて 5 列構造が壊れる。値を言い換えて `|` を避けるのは禁止（ステップ 4.3 の title 規約が frontmatter `title` との literal 一致を要求するため）。**エスケープは index 登録行にのみ適用し、page frontmatter の `title` / `description` は改変しない**。残る `{path}` / `{domain}` / `{updated}` / `{confidence}` は slug・enum・ISO 8601 タイムスタンプで `|` を含み得ないため対象外。

**登録行の同定述語（手順 1 / 2 / 3 共通）**: 「`## ページ一覧` 見出しから**次の `##` 見出しまでの範囲**にある `|` 始まりの行（ヘッダ行・区切り行を除く）のうち、その行で**最初に現れる** `](pages/{domain}/{slug}.md)` の `{slug}` が対象ページと一致する行」とする。**ページ列は「`|` で分割した最初のセル」ではなく、行頭の `|` からその最初のリンクの閉じ括弧までの範囲**と定義する — `title` に未エスケープの生 `|` を含む行ではリンクが 2 つ目以降のセルへ落ちるため、セル分割を前提にすると実在する登録行を同定できず、手順 1 が重複行を追加したうえ手順 3 の重複削除も同じ述語なので回収できない。「最初に現れる」リンクだけを見ることで、サマリー列に置かれた他ページへの相互参照リンクは自動的に対象外になる（実 index.md にはサマリー列に他ページへのリンクを含む行が複数存在する）。**「GFM がテーブル行として解釈する行」ではなく上記の位置で定義する** — 節内に空行があると GFM は先頭ブロックだけをテーブルとして解釈し、以降の登録行は段落として描画されるため、レンダリング結果を基準にすると実在する登録行の一部が同定対象から漏れて更新サイクルごとに行が増える。**共通なのは同定規則そのものだけで、次の中止条項は手順 1 / 2 に限る**: 同定結果が 2 行以上になった場合は WARNING を出して**当該ページの index 更新を中止する**（1 件目を採る等の fallback は禁止 — 誤った行を silent に書き換える経路が残る）。**手順 3 の重複削除は本中止条項の対象外**で、2 行以上の状態を入力として受け取り後発行を削除する（中止条項を手順 3 にも適用すると、重複が一度できた時点で手順 1 / 2 が永久に中止し続け、唯一の修復経路である手順 3 も同時に塞がって index が自己修復不能になる）。

**手順**（0 → 1 → 2 → 3 の順に実行する。手順 3 も省略可の任意項目ではない）:

- **0. テーブル節の用意（無条件・毎回確認する）**: `## ページ一覧` 節が無ければ見出しと下記 2 行を新設する。**挿入位置**は既存の本文・HTML コメントより後で、`## 統計` 節があればその直前、なければファイル末尾とする（位置を自分で決めない）。節が既にありヘッダ行・区切り行が欠けている場合は、見出しの直後（既存の登録行より前）に補う。さらに**節内の `|` 始まりの行の間に空行があれば削除する** — 空行は GFM のテーブルブロックを分断し、以降の登録行がテーブルとして描画されなくなるため（既存 index の是正も兼ねる）:

  ```
  | ページ | ドメイン | サマリー | 更新日 | 確信度 |
  |--------|---------|---------|--------|--------|
  ```

- **1. 新規ページ行の追加**: 上記の同定述語に一致する行が既に存在する場合は追加せず「2. 既存ページ行の更新」へ回す（行の二重化防止）。節の外にある旧形式の箇条書き行は本判定の対象にしない（それしか無いページは新規追加として扱い、旧行はそのまま残す）。存在しなければ `## ページ一覧` テーブルの末尾に次の 1 行を追加する:

  ```
  | [{title}]({path}) | {domain} | {description} | {updated} | {confidence} |
  ```

  - 列数 (5) と列順は実 index.md のヘッダ行 `| ページ | ドメイン | サマリー | 更新日 | 確信度 |` と一致させる
  - `{path}` は `pages/{domain}/{slug}.md` 形式を維持する（孤児検出のリンク grep `](pages/...)` 生存条件、`wiki-lint-orphans.sh`）
  - `{description}` はステップ 4.1 のサマリー（page frontmatter の `description` と同源、1-2 文）
  - `{updated}` / `{confidence}` は page frontmatter の値と同じにする（ISO 8601 タイムスタンプ / `high`・`medium`・`low`）。**YAML の引用符は含めない**（frontmatter 側が `updated: "2026-..."` でも index 列は引用符なし）
- **2. 既存ページ行の更新**: 対象行は上記の同定述語で特定する（節の外にある旧形式の箇条書き行を書き換えてはならない — テーブル行を箇条書きリストの中へ置くと GFM は箇条書きの継続行として literal text にレンダリングする）。同定したら**その 1 行を上記「新規ページ行の追加」と同一形式で丸ごと再生成して置換する**（列位置を数えて特定のセルだけ書き換えることはしない）。`title` / `updated` / `confidence` は更新後の page frontmatter の値（YAML の引用符は外す）を使い、エスケープ規約を適用する。**サマリー列の値は次の順で決める**: (1) frontmatter に `description` があればその値、(2) 無ければ**既存行のサマリー列の値を保持する**（新たに生成し直さないという意味であり、上記のエスケープ規約は保持値にも適用する。ステップ 4.1 のサマリー生成は新規ページ作成時にしか実行されないため、更新経路では候補にならない）。**既存行のサマリー列は位置で切り出す** — 同定述語で確定したページ列より後ろを `|` で分割し、**分割結果の先頭要素と末尾要素は行頭側・行末側の区切りに由来して必ず空（空白のみ）になるので捨てる**。残った並びの先頭をドメイン列、**末尾 2 つを更新日列・確信度列**、その間に残るすべてを `|` で再結合したものをサマリー列とする。更新日は ISO 8601、確信度は enum でどちらも `|` を含み得ないため、末尾から数える方法はサマリー列に生 `|` が残っている行でも決定的に働く。`description` は schema 上 optional で実際に持たない page が多数あるため、**空文字で上書きしてはならない**（蓄積済みのサマリーが失われる）。これにより、既に未エスケープの生 `|` で列がずれている既存行も当該 page の更新サイクルで正しい 5 列へ是正される。
- **3. 統計**: `## 統計` 節が存在する場合、**総ページ数 / ドメイン別内訳 / 最終更新**の 3 行を今回の ingest 結果と同期する。総ページ数 = `pages/` 配下の **`*.md` ファイル数**（`wiki-init` が置く `.gitkeep` 等の非ページファイルを除く）、ドメイン別 = `patterns` / `heuristics` / `anti-patterns` 各配下の `*.md` 件数、最終更新 = 今回の `{updated}` タイムスタンプ。件数は目視で数えず下記で算出する（ステップ 3 の `wiki_index_path` と同じ基点解決を使う — 素の相対パスは呼び出し時の cwd がセッション worktree / main checkout のとき 0 件になり、統計を silent に 0 で上書きする）:

  ```bash
  branch_strategy="{branch_strategy}"
  wiki_wt_abs="{wiki_worktree_abs}"
  if [ "$branch_strategy" = "separate_branch" ]; then
    pages_root="${wiki_wt_abs:-.rite/wiki-worktree}/.rite/wiki/pages"
  else
    pages_root=".rite/wiki/pages"
  fi
  # signal-specific trap (EXIT/INT/TERM/HUP) で find_err tempfile orphan 防止。
  # 詳細は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照。
  find_err=""
  _cleanup() { [ -n "${find_err:-}" ] && rm -f "$find_err"; return 0; }
  trap 'rc=$?; _cleanup; exit $rc' EXIT
  trap '_cleanup; exit 130' INT
  trap '_cleanup; exit 143' TERM
  trap '_cleanup; exit 129' HUP
  find_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-stat-err-XXXXXX" 2>/dev/null) || {
    echo "WARNING: stderr 退避 tempfile (find_err) の mktemp に失敗しました。統計同期を中止します" >&2
    echo "[CONTEXT] WIKI_INGEST_STATS=aborted; reason=mktemp"
    exit 0
  }

  # 単一 find でページ一覧を取り、総数もドメイン別も同じ出力から数える。
  # 内訳の grep は必ず $pages_root に anchor する — 素の "/${d}/" は path のどこにでも一致するため、
  # 基点より上のディレクトリ名にドメイン名が現れると内訳だけが膨張して総数と別の述語になる。
  # anchor したうえで producer が 3 ドメイン以外のディレクトリを作らない前提が成り立つ限り、
  # 総数と内訳は同一基点・同一出力由来で一致するため両者のズレを別途検査する必要がない
  # (前提が崩れた場合は下の合計一致検査が中止へ倒す)。
  if ! pages_list=$(find "$pages_root" -type f -name '*.md' 2>"$find_err"); then
    echo "WARNING: find '$pages_root' が失敗しました。統計同期を中止します" >&2
    head -3 "$find_err" | sed 's/^/  /' >&2
    echo "  影響: 過少計上した値で正しい統計を上書きしないため、本サイクルの統計は更新しません" >&2
    echo "[CONTEXT] WIKI_INGEST_STATS=aborted; reason=find_rc"
    exit 0
  fi
  if [ -s "$find_err" ]; then
    echo "WARNING: find '$pages_root' が stderr 出力を返しました (permission denied / IO error の可能性)。統計同期を中止します:" >&2
    head -3 "$find_err" | sed 's/^/  /' >&2
    echo "  影響: 一部ディレクトリを読めておらず、統計が過少計上される可能性があります" >&2
    echo "[CONTEXT] WIKI_INGEST_STATS=aborted; reason=find_stderr"
    exit 0
  fi

  if [ -z "$pages_list" ]; then
    total=0
  else
    total=$(printf '%s\n' "$pages_list" | wc -l | tr -d ' ')
  fi
  domain_sum=0
  for d in patterns heuristics anti-patterns; do
    if [ -z "$pages_list" ]; then
      n=0
    else
      n=$(printf '%s\n' "$pages_list" | grep -c "^${pages_root}/${d}/")
    fi
    printf '%s=%s\n' "$d" "$n"
    domain_sum=$((domain_sum + n))
  done
  if [ "$domain_sum" -ne "$total" ]; then
    echo "WARNING: ドメイン別の合計 ($domain_sum) が総ページ数 ($total) と一致しません。統計同期を中止します" >&2
    echo "  原因候補: 3 ドメイン以外のディレクトリに *.md が置かれている / pages_root 直下に *.md がある" >&2
    echo "  影響: 内訳と総数が食い違う値で正しい統計を上書きしないため、本サイクルの統計は更新しません" >&2
    echo "[CONTEXT] WIKI_INGEST_STATS=aborted; reason=domain_sum_mismatch"
    exit 0
  fi
  echo "total=$total"
  ```

  **`total=0` が出たら統計同期を中止して WARNING を出し、`[CONTEXT] WIKI_INGEST_STATS=aborted; reason=total_zero` を emit する** — 手順 3 は新規・更新ページが 1 件以上ある前提で走るため総ページ数 0 は構造的にありえず、パス解決失敗を意味する（0 をそのまま書くと正しい値を silent に破壊する）。

  **中止時の報告（全 5 経路共通）**: `WIKI_INGEST_STATS=aborted` を観測したら `n_warnings += 1` を加算し（ステップ 8.3 の Lint 実行異常と同じ受け皿。`n_lint_anomaly` は Lint 由来の指標なので加算しない）、ステップ 9 完了レポートの `{ingest_outstanding_line}` に `- ⚠️ 統計同期: {reason} により中止。index.md の `## 統計` は前サイクルの値のままです（手順 1 / 2 の行追加は適用済みのため、データ行数と統計が一時的に食い違います）` を 1 行追加する。中止しても完了レポートが「非ブロッキングで継続した失敗はありませんでした」と報告する経路を残さないこと — 統計節を検査する lint 経路は存在しないため、これが唯一の下流検出器になる。3 行の literal 形式は既存行に合わせる（`- 総ページ数: {n}` / `- ドメイン別: patterns={n}, heuristics={n}, anti-patterns={n}` / `- 最終更新: {updated}`）。**総ページ数がテーブルのデータ行数と一致しないときに本ステップで行うのは、`データ行数 > 総ページ数` の場合に限り、上記の同定述語（ページ列 anchor 付き）で同一ページを指す行が 2 行以上あるものについて後発行を削除することだけ**（`総ページ数 > データ行数` は未登録ページ由来なので何もしない）。それ以外の原因（未登録ページ、節の外に旧形式の箇条書き行で登録されているページ）では何もせずステップ 8 の lint に委ねる（今回読んでいない page を投機的に登録・削除すると孤児検出のシグナルが消える）。`## 統計` 節が**存在しない** index.md では統計同期をスキップする（節を新設しない）。全 Raw Source が skip されたサイクル（新規・更新ページ 0 件）も統計同期をスキップする。

> **読み手側の対応状況**: `wiki-lint-orphans.sh` は `](pages/...)` リンクの grep ベースで形式非依存に登録判定するため、`{path}` の形式維持だけが孤児検出の必須条件になる。一方 `/rite:wiki-query` の Pass 1 はテーブル行を parse しないため、テーブル形式 index では index 経由のキーワード照合が機能しない（ステップ 5.3 の `{description}` 注記と同じ理由。読み手のテーブル対応は Issue #2053）。

書き込みはステップ 5 と同じブランチコンテキスト (separate_branch なら worktree、same_branch なら dev ツリー) で行う。

---

## ステップ 7: log.md の追記

`.rite/wiki/log.md` に OKF v0.1 予約構造（`## YYYY-MM-DD` 見出し + 散文 bullet、**新しい順** = 先頭が最新）で **append-only** に変更履歴を追記する。本ログは人間向けの変更履歴であり、skip 等の機械可読状態は raw frontmatter の `ingest_status`（ステップ 5）が Source of Truth で、本ログには保持しない。

**追記ルール**:

- 今日の日付見出し `## YYYY-MM-DD` が `# Directory Update Log` 直後（ログ先頭）に無ければ新規追加する（新しい順のため最新日付を先頭に置く）。既にあればその見出し配下の bullet 群末尾に追加する
- 各 Raw Source 1 件につき 1 bullet を追加する:
  - **新規**: `* **Create**: [{title}](pages/{domain}/{slug}.md) — {source_ref} を新規ページ化`（`{title}` はステップ 5.3 で定義したページタイトル、リンク先は index.md の登録行と同じ `pages/{domain}/{slug}.md`）
  - **更新**: `* **Update**: [{title}](pages/{domain}/{slug}.md) — {source_ref} を統合`
  - **スキップ**: `* **Skip**: [{filename}](raw/{type}/{filename}) — {skip_reason}`（`{filename}` は当該 Raw Source のファイル名、`{type}` は Raw Source type）
- 既存の日付見出し・bullet（過去エントリ）は改変しない

log.md は append-only。既存エントリを変更してはいけない。

---

## ステップ 8: 自動 Lint

Ingest 直後、Wiki 全体の品質チェックを `/rite:wiki-lint --auto` として実行する。**5 ブロッキング観点** (矛盾・陳腐化・孤児ページ・欠落概念・壊れた相互参照) + **1 informational 指標** (未登録 raw、`ingest_status: skipped` 済み) で計 6 フィールドを検査する。

### 8.1 auto_lint 設定の確認

`rite-config.yml` の `wiki.auto_lint` を読み取る。**ステップ 1.1 とは別の inline lenient パーサ**を使う (1.1 は `lib/wiki-config.sh` の `parse_wiki_scalar` へ委譲済み。本ステップの awk は位置パラメータを参照しない bare regex 形のため Skill loader の展開を受けず、委譲しなくても壊れない — 検出は `hooks/scripts/dollar-zero-check.sh`)。**1.1 の旧形 (awk で行全体を参照する形) をここへ持ち込んではならない**:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
auto_lint=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_lint:/ { print; exit }' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*auto_lint:[[:space:]]*//' | tr -d '[:space:]"'\''' | tr '[:upper:]' '[:lower:]')
case "$auto_lint" in
  false|no|0) auto_lint=false ;;
  *) auto_lint=true ;;  # default: true
esac
echo "auto_lint=$auto_lint"
```

**`auto_lint=false` の場合**: ステップ 8.2-8.5 を skip する。**ステップ 8.6 (push の集約) はスキップしない** — ステップ 5.1 で `--commit-only` 積んだ raw source の commit を push するのは auto_lint の有無に関わらず必須のため、ステップ 8.6 を実行してからステップ 9 へ進む。Lint カウンタ 6 種はステップ 2.1 で 0 初期化済みのため placeholder 残留は発生しない。ステップ 9 完了レポートの「Wiki 品質警告」行は「スキップ (auto_lint disabled)」、「未登録 raw」行は `0` 件として表示する。

### 8.2 Lint エンジンの呼び出し

LLM は `skill: "rite:wiki-lint", args: "--auto"` 形式で `/rite:wiki-lint` を `--auto` モードで呼び出す。`--auto` モードの契約:

- `Lint: contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` 形式の 1 行 + `<!-- skill return signal: caller must continue next step -->` + `<!-- [lint:returned-to-caller:auto] -->` HTML コメント sentinel の 3 行を出力する (0 件でも必ず出力)。本 phase の parser (ステップ 8.3) は 1 行目の `^Lint: contradictions=` regex のみに依存するため、2 行目以降の disambiguator marker 追加 は互換性に影響しない
- log.md への追記は lint.md 側がブランチ状態を判定し自律実行する
- 常に exit 0 (非ブロッキング)

呼び出し時の CWD は常に dev ブランチ。lint.md ステップ 8.2 は `separate_branch` 戦略時に worktree 内で log.md 追記 → `wiki-worktree-commit.sh` 呼び出しを行う。

Skill return 後、ステップ 8.3 (パース) → 8.4 (完了レポート統合) → 8.5 (n_warnings 加算) → ステップ 9 を順に実行する。

### 8.3 Lint 実行結果の取得とパース

LLM は Skill 応答テキスト (= `lint.md` ステップ 9.2 の最終 stdout 出力) を会話コンテキストからパースする。Skill ツール呼び出しはシェル exit code を返さないため、**Skill 応答テキストの内容**で成否を判定する。以降の「stdout」はすべて Skill 応答テキストを指し、lint.md 内部の中間出力 (`pages_list=` 等) ではない。

判定優先順位 (step 番号は **項目の論理的役割の名称** であり実行順とは異なる):

```
優先 1: step 2 (6 フィールド regex match) を試行
  ├─ match 成功 → 6 変数を抽出して continue (step 1 / 3 / 4 は skip)
  └─ match 失敗 → 優先 2 へ

優先 2: step 1 (ERROR 行 scan) を試行
  ├─ ERROR: 行検出 → n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
  └─ ERROR 行なし → 優先 3 へ

優先 3: step 3 (stdout 空 check) を試行
  ├─ stdout 空 → n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
  └─ stdout 非空 → 優先 4 へ

優先 4: step 4 (format mismatch fallback)
  └─ n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
```

通常時は step 2 のみで完結する (lint.md ステップ 9.2 が必ず 6 フィールド 1 行を emit する契約のため)。

1. **ERROR 行の検出**: Skill 応答テキストに `ERROR:` で始まる任意行 (例: `ERROR: 未知の branch_strategy 値を検出しました`) が含まれるかを検査する。検出時:

   - `n_warnings += 1` + `n_lint_anomaly += 1`
   - 6 変数 (`n_contradictions` 等) はすべて `0` に fallback
   - stderr に WARNING を出力 (検出行を 4 スペース prefix で展開):

     ```
     WARNING: /rite:wiki-lint --auto の Skill 応答テキストに ERROR: 行を検出しました（Lint 実行失敗）。
       検出行: {error_line_first1line}
       考えられる原因: lint.md 内の echo "ERROR: ..." 経由の fail-fast 経路が発火
       Ingest 完了レポートには「Lint 結果: 実行失敗」と表示します。
       対処: /rite:wiki-lint を手動実行してエラー内容を確認してください。
     ```

   - ステップ 8.4 では「Lint 結果: 実行失敗（ERROR: 行検出のため詳細取得不可）」と表示

2. **stdout のパース** (優先 1): exit 0 の場合、stdout の **全行を上から scan し、最初に以下の正規表現にマッチした行から** 6 つの変数を抽出する: `^Lint: contradictions=([0-9]+), stale=([0-9]+), orphans=([0-9]+), missing_concept=([0-9]+), unregistered_raw=([0-9]+), broken_refs=([0-9]+)$`

   | 変数 | regex group |
   |------|-------------|
   | `n_contradictions` | group 1 |
   | `n_stale` | group 2 |
   | `n_orphans` | group 3 |
   | `n_missing_concept` | group 4 |
   | `n_unregistered_raw` | group 5 |
   | `n_broken_refs` | group 6 |

   全行 scan + 最初の match 採用とすることで、lint.md 側で preamble の echo / debug 出力が混入しても決定論的に `Lint:` 行を拾う (`set -x` debug / observability echo / informational banner 等の追加変更に対する resilience)。

3. **stdout が空の場合**: **Lint 実行失敗として扱う** (lint.md の契約では regex-matchable な `Lint:` data 行を 0 件でも必ず 1 行出力するため、stdout 空は bash syntax error / 未捕捉 fatal error / SIGPIPE / OOM 等の異常経路。lint.md の総出力は disambiguator marker + sentinel を含めて 3 行だが、本 phase の parser が依存するのは regex `^Lint:` でマッチする 1 行目の data 行のみ):

   - `n_warnings += 1` + `n_lint_anomaly += 1`
   - 6 変数を `0` に fallback
   - stderr に WARNING を出力:

     ```
     WARNING: /rite:wiki-lint --auto の stdout が空でした（Lint 実行失敗）。
       期待される出力: Lint: contradictions=N, stale=N, orphans=N, missing_concept=N, unregistered_raw=N, broken_refs=N
       考えられる原因: lint.md の bash syntax error / 未捕捉 fatal error / SIGPIPE / OOM
       Ingest 完了レポートには「Lint 結果: 実行失敗」と表示します。
       対処: /rite:wiki-lint を手動実行してエラー内容を確認してください。
     ```

   - ステップ 8.4 では「Lint 結果: 実行失敗（stdout が空のため詳細取得不可）」と表示

4. **stdout のどの行も regex にマッチしない場合**: Lint 側のフォーマット変更を検出した警告として扱う (silent に 0 件と誤認することを防ぐ):

   - `n_warnings += 1` + `n_lint_anomaly += 1` (format drift を Lint 異常経路として計上)
   - 6 変数を `0` に fallback
   - stderr に WARNING を出力 (stdout 先頭 3 行を 4 スペース prefix で展開):

     ```
     WARNING: /rite:wiki-lint --auto の出力形式が期待と異なります（stdout のいずれの行も 6 フィールド regex にマッチしませんでした）。
       stdout の先頭 3 行:
         {lint_stdout_first3lines}
       期待される形式: Lint: contradictions=N, stale=N, orphans=N, missing_concept=N, unregistered_raw=N, broken_refs=N
     ```

### 8.4 Ingest 完了レポートへの統合

ステップ 9 の完了レポートに以下を埋め込む:

```
Lint 結果: 矛盾 {n_contradictions} 件 / 陳腐化 {n_stale} 件 / 孤児 {n_orphans} 件 / 欠落 {n_missing_concept} 件（未登録 skip {n_unregistered_raw} 件）/ 壊れた相互参照 {n_broken_refs} 件
```

**全カテゴリが 0 件の場合** (`n_contradictions + n_stale + n_orphans + n_missing_concept + n_unregistered_raw + n_broken_refs == 0`): 「Lint 結果: 問題なし」とのみ表示する。1 件以上検出された場合は必ず全カテゴリを表示する (`n_unregistered_raw` は informational だが表示判定には含める)。

ERROR / stdout 空 / regex mismatch 経路では「Lint 結果: 実行失敗（{原因}）」と表示する。

### 8.5 `n_warnings` カウンタへの加算

本ステップは **ステップ 8.3 step 2 (6 フィールド regex match 成功) 経路でのみ実行する**。step 1/3/4 経路ではステップ 8.3 内で既に `n_warnings += 1` と `n_lint_anomaly += 1` が加算済みのため skip する。

ステップ 2.1 で初期化した `n_warnings` に、Lint の検出件数合計を加算する (step 2 経路のみ):

```
n_warnings += n_contradictions + n_stale + n_orphans + n_missing_concept + n_broken_refs
```

**`n_unregistered_raw` は加算しない**: skip 済み raw (`ingest_status: skipped`) は意図的に経験則化しなかった件数 (skip 理由は raw frontmatter の `skip_reason` に記録済み) であり、警告として数えると skip 運用が膨らむほど警告カウンタが無意味に肥大する。informational 指標として完了レポートの内訳にのみ表示する。

**詳細な修正対応**: 検出結果の詳細確認は、Ingest 完了後に `/rite:wiki-lint`（`--auto` なし）で再実行して取得する。

### 8.6 Wiki push の集約（#1941 wiki push batch/defer）

**`auto_lint` の値に関わらず必ず実行する**（ステップ 8.1 参照）。ステップ 5.1 (separate_branch) は raw source ごとに `--commit-only` で commit のみを行い、push を意図的に遅延させてきた。ステップ 8.2 の自動 Lint (`--auto` モード) も同様に `--commit-only` で log.md 追記を積む（[skills/wiki-lint/SKILL.md](../wiki-lint/SKILL.md) ステップ 8.3 参照）。ここで、蓄積されたローカル commit（0 件のこともある）をまとめて 1 回だけ push する（AC-1: 1 回の ingest フローで `git push origin {wiki_branch}` は最大 1 回）。

`same_branch` では worktree を使わず push もこのフローの管轄外（PR ブランチの通常 push に含まれる）のため本ステップは no-op:

```bash
branch_strategy="{branch_strategy}"
if [ "$branch_strategy" = "separate_branch" ]; then
  plugin_root="{plugin_root}"
  wiki_wt_abs="{wiki_worktree_abs}"; wiki_wt_abs="${wiki_wt_abs:-.rite/wiki-worktree}"
  wiki_branch="{wiki_branch}"

  if [ ! -x "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" ]; then
    echo "ERROR: wiki-worktree-commit.sh が見つからないか実行権限がありません: $plugin_root/hooks/scripts/wiki-worktree-commit.sh" >&2
    exit 1
  fi

  # set -e 下で script の非 0 exit を許容して rc を capture する
  set +e
  push_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --push-only)
  push_rc=$?
  set -e
  echo "$push_out"

  case "$push_rc" in
    0) echo "[CONTEXT] WIKI_INGEST_PUSH=ok" ;;
    4)
      echo "WARNING: 蓄積した wiki commit の push に失敗しました (rc=4)。commit は local wiki branch に landed 済みです（AC-2: 非ブロッキングで継続、次回セッションの push-only 呼び出しが自動で flush する）" >&2
      echo "  手動回復: git -C \"$wiki_wt_abs\" push origin $wiki_branch" >&2
      echo "[CONTEXT] WIKI_INGEST_PUSH=failed" >&2
      ;;
    *)
      echo "ERROR: wiki-worktree-commit.sh --push-only が予期しない exit code ($push_rc) を返しました" >&2
      exit 1
      ;;
  esac
else
  echo "[CONTEXT] WIKI_INGEST_PUSH=skipped; reason=same_branch"
fi
```

`push_out` に含まれる `push=no-op` はそもそも push すべき commit が無かった（今回の全 raw source が skip 判定だった等）ことを示し、失敗ではない (`WIKI_INGEST_PUSH=ok` 扱いで問題ない)。`[CONTEXT] WIKI_INGEST_PUSH=` marker はステップ 9.0 完了レポートの push 状態表示、および `/rite:cleanup` ステップ 9 の push 失敗判定（stdout 中の `push=failed` 部分文字列を検出）に使う。

---

## ステップ 9: 完了レポート

### 9.0 Ingest セッション lock の解放

ステップ 5〜8 の Write/Edit/commit/lint がすべて完了したので、ステップ 1.4 で取得した ingest セッション lock を解放する（保持し続けると他セッションの ingest が `concurrent_ingest` で skip され続ける）。万一解放を逃しても次回 ingest が stale 判定で回収するため fail-safe だが、正常系では明示的に解放する:

```bash
bash "{plugin_root}/hooks/scripts/wiki-ingest-lock.sh" release
```

```
Wiki Ingest が完了しました。

処理サマリー:
- 処理した Raw Source: {n_raw_sources} 件
- 新規作成したページ: {n_pages_created} 件
- 更新したページ: {n_pages_updated} 件
- スキップした Raw Source: {n_skipped} 件
- {wiki_warnings_line}
- 未登録 raw（skip 済、warnings 不加算）: {n_unregistered_raw} 件
- {wiki_push_line}

未完了事項:
{ingest_outstanding_line}

新規/更新ページ:
- {path1} ({action1})
- {path2} ({action2})

次のステップ:
- /rite:wiki-query で経験則を参照
- 詳細な品質チェックは /rite:wiki-lint で確認してください（ステップ 8 で自動実行済み）
```

`{wiki_warnings_line}` の展開ルール (lint.md ステップ 9.1 と設計対称):

| `auto_lint` | 「Wiki 品質警告:」行の展開 |
|-------------|-----------------------|
| `true` (通常経路) | `Wiki 品質警告: {n_warnings} 件（内訳: 矛盾 {n_contradictions} / 陳腐化 {n_stale} / 孤児 {n_orphans} / 欠落 {n_missing_concept} / 壊れた相互参照 {n_broken_refs} / Lint 異常経路 {n_lint_anomaly}）` |
| `false` (skip 経路) | `Wiki 品質警告: スキップ (auto_lint disabled)` (内訳は表示しない) |

「未登録 raw」行は `auto_lint=false` の場合も `0` 件として展開する (ステップ 2.1 で 0 初期化済みの値)。

**等式**: `n_warnings = n_contradictions + n_stale + n_orphans + n_missing_concept + n_broken_refs + n_lint_anomaly`。step 2 成功時は `n_lint_anomaly=0` のため 5 カテゴリ合計が `n_warnings` と一致。step 1/3/4 anomaly 経路では 5 カテゴリは 0 fallback だが `n_lint_anomaly >= 1` のため `n_warnings >= 1` となる。

`{wiki_push_line}` の展開ルール (ステップ 8.6 の `[CONTEXT] WIKI_INGEST_PUSH=` marker を上から評価し最初の一致を採用。#1941 AC-2: 未 push の wiki commit があれば回復コマンドを明示する):

| `WIKI_INGEST_PUSH=` | 展開 |
|---|---|
| `ok` | `Wiki push: 完了`（`push=no-op` だった場合も含む — push すべき commit が無かっただけで失敗ではない） |
| `failed` | `⚠️ Wiki push: commit は local wiki branch に landed しましたが origin への push に失敗しました。手動回復: git -C {wiki_worktree_abs} push origin {wiki_branch}` |
| `skipped; reason=same_branch` | `Wiki push: 対象外 (same_branch 戦略。通常の PR push に含まれる)` |
| marker なし（ステップ 8.6 未到達などの想定外経路） | `⚠️ Wiki push: 実行結果が確認できませんでした。git -C {wiki_worktree_abs} status で確認してください` |

`{ingest_outstanding_line}`（Issue #1946: 非ブロッキング失敗の集約 surface）: `WIKI_INGEST_PUSH=` と `WIKI_INGEST_STATS=` の 2 marker を評価し、該当する行を**すべて**列挙する（どちらも該当しない場合のみ「なし」を出す）。

| marker | 展開 |
|---|---|
| `WIKI_INGEST_PUSH=failed` | `- ⚠️ Wiki push: commit は local wiki branch に landed しましたが origin への push に失敗しました。手動回復: git -C {wiki_worktree_abs} push origin {wiki_branch}（次回 /rite:wiki-ingest 実行時にも自動で flush を試みます）` |
| `WIKI_INGEST_PUSH=` marker なし（ステップ 8.6 未到達などの想定外経路） | `- ⚠️ Wiki push: 実行結果が確認できませんでした。git -C {wiki_worktree_abs} status で確認してください`（`{wiki_push_line}` の同ケースと同じ扱い — 未確認を「失敗なし」と断定しない） |
| `WIKI_INGEST_STATS=aborted; reason={r}` | `- ⚠️ 統計同期: {r} により中止。index.md の `## 統計` は前サイクルの値のままです（手順 1 / 2 の行追加は適用済みのため、データ行数と統計が一時的に食い違います）` |
| 上記いずれも該当なし（`WIKI_INGEST_PUSH=ok` / `skipped; reason=same_branch` かつ統計中止なし） | `- なし（非ブロッキングで継続した失敗はありませんでした）` |

### 9.1 Return-to-Caller Signal

完了レポート本体 (処理サマリー + 新規/更新ページ + 次のステップ) を出力した後、**最終 2 行**に HTML コメント sentinel を出力する:

```
<!-- skill return signal: caller must continue next step -->
<!-- [ingest:returned-to-caller] -->
```

sentinel は grep 可能 (`grep -F '[ingest:returned-to-caller]'`) で rendered view では不可視。bare bracket `[ingest:returned-to-caller]` は LLM turn-boundary heuristic 誤発火のため禁止、HTML コメント形式のみ許容する。

> **Why `returned-to-caller` (not `completed`)**: 旧 `ingest:completed` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、caller skill (cleanup / open 等) の次 step を skip して turn が暗黙終了する事象が複数回再発した。`returned-to-caller` は「caller skill に return した = caller の次 step に進む」というネスト構造を semantic に内包し、terminal vocabulary を構造的に排除する。

---

## エラーハンドリング

| エラー | 対処 |
|--------|------|
| `wiki.enabled: false` | 早期 return（ステップ 1.1） |
| `lib/wiki-config.sh` 読込失敗 (helper 不在 / 解決失敗) | exit 1 で fail-fast（`[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1`。設定を判定できないまま無効扱いへ倒さない。plugin のインストール状態を確認するか `/rite:setup` を再実行、ステップ 1.1） |
| Wiki 未初期化 / worktree セットアップ失敗 | `/rite:wiki-init` を案内、または `wiki-worktree-setup.sh` のエラー出力を確認して `git worktree prune` / `git fetch origin wiki:wiki` で復旧 (ステップ 1.3) |
| 処理対象 0 件 | 静かに終了し情報メッセージのみ表示（ステップ 2.3） |
| `wiki-worktree-commit.sh --commit-only` exit 3 (git add/commit 失敗、ステップ 5.1) | exit 1 で fail-fast。`git -C .rite/wiki-worktree status` で worktree の状態を確認 |
| `wiki-worktree-commit.sh --push-only` exit 4 (push 失敗、ステップ 8.6) | 非 fatal で継続。commit は local wiki branch に保持される。`git -C .rite/wiki-worktree push origin {wiki_branch}` で手動回復、または次回 ingest の ステップ 8.6 が自動で flush を試みる |
| `wiki-worktree-commit.sh` 未知の exit code | exit 1 で fail-fast |
| `branch_strategy` が未知の値 | ステップ 5.1 の if/elif/else 末尾 else 分岐で fail-fast (ステップ 5.2 の bash block は same_branch 単独分岐のため未知値はステップ 5.1 の else が catch する。`rite-config.yml` の `wiki.branch_strategy` を確認) |
| LLM が経験則を抽出できない | 該当 Raw Source の raw frontmatter に `ingest_status: skipped` + `skip_reason` を追記（skip 状態の SoT）、`ingested: true` に変更、log.md に人間向け Skip bullet を追記、`n_skipped` を +1（ステップ 5 step 5 参照） |

---

## 設計原則

- **単一責任**: Ingest は「Raw Source → Wiki ページ」の変換のみ。Query / Lint は別コマンド
- **冪等性**: 同じ Raw Source を再 Ingest しても結果が同じ (`ingested: true` フラグで重複防止)
- **append-only な log**: 変更履歴ログ (log.md) は履歴として残し、追加のみ
- **PR diff からの分離**: `separate_branch` 戦略では Wiki 変更は `.rite/wiki-worktree/` worktree 内に閉じ、dev ブランチのツリーは一切変更されない (`.gitignore` で worktree path を除外)
- **opt-out**: `wiki.enabled: true` がデフォルト。`wiki:` セクション未指定でも有効扱い
