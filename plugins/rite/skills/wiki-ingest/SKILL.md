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

Wiki Ingest エンジン。`.rite/wiki/raw/` の Raw Source を読解し、`.rite/wiki/pages/` に経験則として統合する。

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

`separate_branch` では `.rite/wiki-worktree/` に対して Read/Write/Edit する。dev ブランチは触らない。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md)。共通パターンは [Wiki Patterns](../../references/wiki-patterns.md)。診断は [Wiki トラブルシューティング](./references/wiki-troubleshooting.md)。

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

`rite-config.yml` から `wiki_enabled` / `wiki_branch` / `branch_strategy` を**単一の bash ブロック**で取得する:
rationale: references/rationale.md#wiki-config-opt-out

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

分散実装の一覧は [Wiki 有効判定パターン §分散実装ファイル一覧](../../references/wiki-patterns.md#分散実装ファイル一覧-single-source-of-truth) を SoT とする。

**`[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1` (bash が rc=1 で終了) の場合**: 無効扱いへ倒さず中止し、ユーザーに案内する:

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

Wiki 初期化判定より前に `plugin_root` を解決する:
rationale: references/rationale.md#plugin-root-literal-embed

```bash
plugin_root=$(cat .rite/plugin-root 2>/dev/null || cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

以降のすべての Bash ブロックでは `plugin_root` / `branch_strategy` / `wiki_branch`、およびステップ 1.3 の `wiki_worktree_abs`（`WIKI_WORKTREE_ABS`）をリテラル埋め込みする。

### 1.3 Wiki 初期化判定と worktree セットアップ

ステップ 1.1 の `branch_strategy` / `wiki_branch` とステップ 1.2 の `plugin_root` で、wiki ブランチの存在と worktree の有効性を確認する。`separate_branch` ではローカル/リモートいずれかのブランチ存在と有効な worktree の両方を確認する:

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

`separate_branch` ではステップ 1.3 の絶対パス `WIKI_WORKTREE_ABS` を `{wiki_worktree_abs}` としてリテラル埋め込みし、すべての Wiki Read / Write / Edit と bash は `{wiki_worktree_abs}/.rite/wiki/...` で指す。空なら `.rite/wiki-worktree` に縮退してよい。
rationale: references/rationale.md#cwd-independent-worktree

### 1.4 Ingest セッション lock の取得（並行 ingest の直列化）

Write/Edit フェーズを直列化する持続的 mkdir lock（`<共有root>/.rite/state/wiki-ingest-session.lockdir`）を取得する:
rationale: references/rationale.md#session-lock-mkdir

```bash
plugin_root="{plugin_root}"
bash "$plugin_root/hooks/scripts/wiki-ingest-lock.sh" acquire
```

出力で分岐する:

- `acquired` / `acquired_stale_reclaimed`（rc 0）: 取得成功。ステップ 2 以降へ進む。
- `concurrent_ingest`（rc 11）: 他の live セッションが ingest 中。**以下を出力して即座に終了する**（pending raw は次回 ingest が冪等回収。新しい回収機構は作らない）:

  ```
  [CONTEXT] WIKI_INGEST_SKIPPED reason=concurrent_ingest
  ```

  別セッションの ingest と競合したため今回はスキップしました。未処理の Raw Source は次回の ingest で自動的に回収されます。

ステップ 9 完了時（およびエラー終了時）に `wiki-ingest-lock.sh release` で解放する（ステップ 9 参照）。

### 1.5 OKF 版数検査と一括 migration

`wiki.enabled: true` のときのみ到達する（1.1 の早期 return 済み）。`index.md` frontmatter の `okf_version` が不在または `"0.1"` なら `wiki-okf-migrate.sh` を実行してから通常処理へ進む。既に `"0.2"` なら helper が無変更で終了する。helper 非ゼロは fail-loud（`okf_version` は bump されない）。
rationale: references/rationale.md#okf-migrate-on-first-touch

```bash
branch_strategy="{branch_strategy}"
wiki_wt_abs="{wiki_worktree_abs}"
plugin_root="{plugin_root}"
if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_root="${wiki_wt_abs:-.rite/wiki-worktree}/.rite/wiki"
else
  wiki_root=".rite/wiki"
fi
if [ ! -x "$plugin_root/hooks/scripts/wiki-okf-migrate.sh" ]; then
  echo "ERROR: wiki-okf-migrate.sh が見つからないか実行権限がありません: $plugin_root/hooks/scripts/wiki-okf-migrate.sh" >&2
  exit 1
fi
set +e
migrate_out=$(bash "$plugin_root/hooks/scripts/wiki-okf-migrate.sh" --wiki-root "$wiki_root")
migrate_rc=$?
set -e
printf '%s\n' "$migrate_out"
if [ "$migrate_rc" -ne 0 ]; then
  echo "ERROR: OKF v0.2 migration が失敗しました (rc=$migrate_rc)。原因除去後に再実行してください（okf_version は bump されていません）" >&2
  exit 1
fi
```

---

## ステップ 2: Raw Source の解決

### 2.1 引数の判定とカウンター変数の初期化

引数 `<raw-file-path>` が指定されている場合は単一ファイルを Ingest 対象とし、省略時は `.rite/wiki/raw/` 配下から `ingested: false` を持つ Raw Source を全て列挙する。

以下のカウンターを会話コンテキストに保持し、各ステップで incrementate する。ステップ 5 commit message とステップ 9 完了レポートで literal substitute する。placeholder のまま使用してはならない:

| 変数 | 初期値 | 確定 / incrementate するタイミング |
|------|:--:|---|
| `n_raw_sources` | 0 | ステップ 2.3 末尾で処理対象件数に上書き |
| `n_pages_created` | 0 | ステップ 4 で「新規ページ作成」決定ごとに +1 |
| `n_pages_updated` | 0 | ステップ 4 で「既存ページ更新」決定ごとに +1 |
| `n_skipped` | 0 | ステップ 4 で「スキップ」決定ごとに +1 |
| `n_warnings` | 0 | ステップ 8.5 で Lint の検出件数合計（`n_stale` / `n_unregistered_raw` を除く 4 カテゴリ）を加算。加えて ステップ 8.3 の Lint 実行異常検出時 `n_warnings += 1` と `n_lint_anomaly += 1` を並行加算 |
| `n_lint_anomaly` | 0 | ステップ 8.3 step 1/3/4 (ERROR 行検出 / stdout 空 / regex mismatch) でそれぞれ +1。`n_warnings` と並行加算 |
| `n_dedup_removed` | 0 | ステップ 6 の各 helper 呼び出しが出力する `dedup_removed=` の値を加算 |
| `n_contradictions` / `n_stale` / `n_orphans` / `n_missing_concept` / `n_unregistered_raw` / `n_broken_refs` | 0 | ステップ 8.3 step 2 (6 フィールド regex match) で Lint stdout から抽出 |

`n_stale` と `n_unregistered_raw` と `n_dedup_removed` は informational で `n_warnings` には加算しない。`auto_lint=false` で 8.2-8.5 が skip されても、本ステップの 0 初期化でステップ 9 の placeholder 残留は起きない。
rationale: references/rationale.md#informational-counters

### 2.2 候補 Raw Source の列挙 (worktree ベース)

`separate_branch` では `{wiki_worktree_abs}/.rite/wiki/raw/` を直接 find する。dev 側 `.rite/wiki/raw/` が存在すれば WARNING を出す:
rationale: references/rationale.md#dev-tree-drift

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

候補は worktree (separate_branch) または dev ツリー (same_branch) を Read / `cat` で読む（`git show` / `git checkout` は不要）。読み取り失敗時は WARNING を出して次の候補へ:

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

**処理対象が確定したら**: `n_raw_sources` を件数に上書きする。各 Raw Source の完全な本文 (frontmatter + body) を Read し、会話コンテキストに保持する。

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
2.5. **昇格分類**: 本経験則が rite workflow 自体の挙動・スキル記述法に関するものなら、環境非依存性も判定する。環境非依存なら frontmatter に `promote: rite-plugin` を付け、環境固有なら一般化してから昇格するか、一般化できない domain 知見として Wiki に残す。**機械検出可能（2.6）と両方に該当する場合は 2.6 が優先**し、ページを作らない（`promote` はページ作成時のみ）
   rationale: references/rationale.md#knowledge-routing
2.6. **検出器化候補の分類**: grep / lint / lib 関数で機械的に強制できるかフラグ付けするのみ（アクション決定はしない）。できるなら `detector_candidate=true`、できないなら `false`
   rationale: references/rationale.md#detector-candidate
3. **既存ページ照合**: `index.md` に同テーマの既存ページが存在するかを意味的に判定 (厳密一致ではなく、一行サマリーとタイトルから判断)
4. **アクション決定**: 下表に**上から first-match**で 新規 / 更新 / スキップ を決定（2.6 のフラグとステップ 3 の照合結果を入力とする）
5. **関連ページ特定**: ステップ 5.3 の `{related_page_title}` / `{related_page_path}` の値を決定 (詳細はステップ 4.3)

| 判定（上から first-match） | アクション |
|------|----------|
| `detector_candidate=true` かつ同テーマの既存ページあり | 新規ページを作らず既存ページを更新。ステップ 9 の検出器化候補に 1 行列挙する（人間が Issue 化を判断する材料。`promote: rite-plugin` タグと同様の役割） |
| `detector_candidate=true` かつ同テーマの既存ページなし | ページ化せずスキップ（`skip_reason: "detector-candidate: {one-line-summary}"`）。ステップ 9 の検出器化候補に 1 行列挙する |
| 同テーマの既存ページなし | 新規ページ作成 |
| 同テーマの既存ページあり | 既存ページ更新（追記 or 統合） |
| 経験則が抽出できない（一時的な情報のみ） | スキップ（理由を log に記録） |

### 4.1 タイトル/ドメイン/サマリーの生成

新規ページ作成時、LLM は以下を生成する:

| フィールド | ガイドライン |
|-----------|-------------|
| `title` | 経験則を 1 行で表現（30-60 字推奨） |
| `domain` | `patterns` / `heuristics` / `anti-patterns` |
| `summary` | 1-2 文の Why 要約（page frontmatter `description` と index.md のサマリー列へ同一文言を掲載する）。Issue / PR 番号は出典の識別子であって概念の理由を説明しないため、`Issue #NNN` / `PR #NNN` / `refs #NNN` 等の番号参照を書かず、番号が担っていた観測事実・条件・因果を自己完結した散文で記述する。provenance は `sources` に分離して保持する |
| `details` | 背景・具体例・根拠を含む詳細 |
| `confidence` | `high` / `medium` / `low`（根拠の強さ） |
| `promote` | ステップ 4 の昇格分類で rite 挙動・スキル記述法かつ環境非依存（または一般化済み）と判定した場合のみ `rite-plugin`。それ以外はフィールド自体を付けない |

ファイル名は `pages/{domain}/{slug}.md`、`slug` は `title` を kebab-case 化（最大 60 文字）。

### 4.2 既存ページ更新時の統合方針

- **追記（補強のみ）**: 既存内容と矛盾せず補強する場合は「## 詳細」に追記する。`generated` を `{ by: "rite-wiki-ingest/<model-id>", at: <now> }` に更新し、`verified` へ `{ by, at }` を 1 件追記する
- **統合（改訂を 1 件でも含む）**: 該当箇所を書き換える。`generated` のみ更新する。既存 `verified` は追記もクリアもしない
- **混在**: 同一サイクルに補強 raw と改訂 raw の両方がある場合は `generated` のみ更新し、`verified` へ追記しない
- **`sources` 配列追記**: 新しい Raw Source への参照を必ず追加する。追加する各エントリは `- type: "{type}"` / `  resource: "raw/{type}/{filename}"` の形式とし、**`resource` は必ず Raw Source のファイルパス形式 (`raw/{type}/{filename}`、wiki-root 起点)** にする。raw frontmatter の `source_ref` フィールド値（PR 識別子形式、例: `pr-1143`）を `resource` に転記してはならない
- **`generated` 更新**: 現在の ISO 8601 タイムスタンプを `generated.at` に書く。`<model-id>` はセッションが報告する実行モデル ID。特定できない場合は該当 write を失敗させる（既定値を握り込まない）
- **`verified` / `status` / `stale_after`**: 実イベント時のみ。空の `verified: []` は書かない。`status` はページ全文が撤回されたときだけ `deprecated`（現行 ingest の新規/追記/統合では書かない）。`stale_after` は本文に絶対日付拘束がある経験則にのみ `YYYY-MM-DD` で書く。`human:` prefix は書かない
- **`description` の新設・更新**: 本サイクルで概要が変わった場合は frontmatter `description` を更新する（未設定なら新設してよい）。値は上表の番号なし Why 要約をそのまま使い、独自の短縮・言い換えをしない。ステップ 6 の helper はこの値を index サマリー列へ渡す
rationale: references/rationale.md#source-ref-path-form
rationale: references/rationale.md#summary-provenance

### 4.3 関連ページの特定

新規・更新のいずれも、ステップ 5.3 の `{related_page_title}` / `{related_page_path}` を本ステップで決定する（値決定の canonical source。5.3 表と矛盾したら本 4.3 を優先）。
rationale: references/rationale.md#related-page-literal

**実行タイミング**: ステップ 4.1 でタイトル/ドメイン決定後、ステップ 5 の Write/Edit に進む前。

**選定基準**:

| 基準 | 説明 |
|------|------|
| Semantic 近接性 | `index.md` の登録ページ一覧（テーブル行）から、本ページと同ドメインの隣接トピック、または別ドメインだが概念的に関連するページを選定する |
| 確信度 | LLM の判定として確信があるもの 1-3 件に絞る（量より質） |
| index.md との照合 | ステップ 3 で読み込んだ `index_content` の一行サマリーとタイトルから判断する |

**title 規約**: `{related_page_title}` は対象ページの frontmatter `title` フィールドと **literal 一致** させる。独自言い換えは禁止。**literal 一致の基準は frontmatter `title` の生値**であり、index 側のセル区切りエスケープとリンク構文中和は転記しない。

**path 計算規約**: `{related_page_path}` には **page-dir 相対** の path を substitute する。新規 page 格納位置 `.rite/wiki/pages/{domain}/{slug}.md` の page-dir = `.rite/wiki/pages/{domain}/` を起点として相対 path を計算する:

| ケース | path 例 (推奨形) |
|--------|------------------|
| 同ドメイン内 | `./other-page.md` (`./` prefix 付き推奨。page-dir 相対の意図を視覚的に表現する) |
| 別ドメイン | `../{domain}/other-page.md` |

`{source_ref}`（template 側で `../../` prefix、wiki-root 起点）とは起点が異なる。`{related_page_path}` には template 側 prefix を付けず、page-dir 相対 path を入れる。

**該当ページなし時の処理**: 確信ある関連ページが特定できない場合、`## 関連ページ` セクション全体を Edit で以下に置き換える:

```
## 関連ページ

- （関連ページなし）
```

`{related_page_title}` / `{related_page_path}` の両 placeholder への substitute は行わず、セクション全体差し替えを優先する。

---

## ステップ 5: ページの書き込み

ステップ 4 で決定したアクション (新規 / 更新) を、ブランチ戦略に応じて適用する。

### 5.0 LLM が実行すべき具体的手順 (worktree ベース)

`separate_branch` では `{wiki_worktree_abs}/`（ステップ 1.3 の絶対パス）、`same_branch` では dev ツリーに直接 Write/Edit する。順に実施する:

1. **Raw Source 本文の確保**: ステップ 2.3 末尾で取得した本文を作業メモリに展開
2. **Raw Source の `ingested: true` 化** (全戦略共通 — create / update / skip いずれでも実施):
   - **separate_branch**: Edit ツールで `{wiki_worktree_abs}/.rite/wiki/raw/{type}/{filename}` の frontmatter `ingested: false` を `ingested: true` に書き換える
   - **same_branch**: Edit ツールで `.rite/wiki/raw/{type}/{filename}` を書き換える
3. **新規 Wiki ページの作成** (ステップ 4 で新規決定): `{plugin_root}/templates/wiki/page-template.md` を Read で読み、ステップ 5.3 のプレースホルダーを置換した内容を Write:
   - **separate_branch**: `{wiki_worktree_abs}/.rite/wiki/pages/{domain}/{slug}.md`
   - **same_branch**: `.rite/wiki/pages/{domain}/{slug}.md`

   `n_pages_created` を +1 する

   > **複数 Raw Source からの作成**: page-template.md の `sources:` は単一スロット（`{source_type}`/`{source_ref}` 各 1 個）のみ。複数 Raw Source を 1 ページに統合する場合は、Write 後に Edit で `- type: "{type}"` / `  resource: "raw/{type}/{filename}"` を追加する。**すべての `resource` はファイルパス形式 (`raw/{type}/{filename}`)** であり、raw の `source_ref`（PR 識別子）ではない。新規ページは `generated: { by: "rite-wiki-ingest/<model-id>", at }` を書き、`verified` / `status` は書かない。
4. **既存 Wiki ページの更新** (ステップ 4 で更新決定): 対象ページを Read で読み、Edit で `## 詳細` 追記・`generated` 更新・（補強のみなら）`verified` 追記・`sources` 配列追記。`n_pages_updated` を +1 する。**`sources` に追記する各 `resource` は必ず Raw Source のファイルパス形式 `raw/{type}/{filename}`**（PR 識別子形式 `pr-NNNN` 禁止。ステップ 4.2 / 5.3 と同一契約）
5. **スキップ決定の処理** (ステップ 4 で skip 決定): step 2 と同じ手順で `ingested: true` 化し、**さらに当該 raw frontmatter に `ingest_status: skipped` と `skip_reason: "{理由}"` を Edit で追記する**（skip 状態の SoT は raw frontmatter）。**検出器化候補**（ステップ 4 表の `detector_candidate=true` かつ既存ページなし）は `skip_reason: "detector-candidate: {one-line-summary}"` を使い、同じ要約をステップ 9 の `{detector_candidate_lines}` に列挙する。ステップ 7 の log.md に人間向け Skip エントリ (OKF bullet) を追記する。`n_skipped` を +1 する
6. **index.md の更新**: **手順 3 / 4 を実施した Raw Source についてのみ**、ステップ 6 に従い `wiki-index-update.sh` を bash で呼ぶ（LLM は Edit しない）。**skip 決定（手順 5）では実行しない**
   rationale: references/rationale.md#skip-no-index-update
7. **log.md への追記**: ステップ 7 の指示に従い Edit で append-only 追加する

### 5.0.c canonical commit message 契約

ステップ 5.1 と ステップ 5.2 の commit message は以下を **唯一の真実源** とする。両サイトで以下と literal 一致させる。
rationale: references/rationale.md#commit-msg-three-sites

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

### 5.0.n commit 前の番号参照検査 (両戦略共通)

ステップ 5.0 手順 1-7 の Write/Edit を終えたら、**commit の前に**書いた分を検査する。Raw Source の本文には番号が載っており（raw は出典なので正しい）、そこから読解して書く過程で番号が Wiki 側へ転記される。ここで止めないと混入は ingest のたびに増える。
rationale: references/rationale.md#numref-precommit

**検査対象は `.rite/wiki` 配下の未 commit 差分**。ページだけでなく `index.md` のエントリ行も `log.md` の bullet も同じ 1 回で通る（`{skip_reason}` や Update の説明文に載る番号を素通りさせないため）。**対象の列挙もラベルも LLM が選ばない** — `git diff` が未 commit の追加行を渡し、パスは git が返す実体をそのまま使う。

走査範囲は commit 範囲（`.rite/wiki`）と一致させ、新規ページは走査直前に `git add -N` で差分へ載せる。この 2 つを外すと新規ページが検査されないまま `clean` になる。`raw/**` は委譲先が除外する（raw は出典なので番号を持つ）。

`{numref_tree}` は `separate_branch` では `{wiki_worktree_abs}`（ステップ 1.3 の絶対パス）、`same_branch` では dev ツリーの repo root を literal substitute する。

```bash
plugin_root="{plugin_root}"
numref_tree="{numref_tree}"
# 残留検査はブレースの**形状**で行う（`"{"*"}"`）。placeholder 名そのものをパターンに書くと、
# substitute がパターン側まで書き換えて検査が自分を無効化する。sibling の同型 gate と同じ形。
for _v in "$plugin_root" "$numref_tree"; do
  case "$_v" in
    ""|"{"*"}")
      echo "ERROR: ステップ 5.0.n の placeholder が literal substitute されていません (plugin_root='$plugin_root' numref_tree='$numref_tree')" >&2
      echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=placeholder_residue" >&2
      exit 1
      ;;
  esac
done
check="$plugin_root/hooks/scripts/number-reference-check.sh"
if [ ! -f "$check" ]; then
  echo "ERROR: number-reference-check.sh が見つかりません (path='$check')。検査せずに commit すると番号混入を止められないため中止します" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=helper_missing" >&2
  exit 1
fi
# 新規ページ (untracked) を差分へ載せる。内容は stage しない intent-to-add で、
# index にはエントリだけが載り `git diff --cached` は空のまま。commit まで進んだ回は
# ステップ 5.1 / 5.2 が同じ範囲を stage し直すので後段への影響はない。hit / error で
# 停止した回はエントリが index に残るが、次回実行の add -N が冪等に上書きする。
numref_stage_rc=0
git -C "$numref_tree" add -N -- .rite/wiki || numref_stage_rc=$?
if [ "$numref_stage_rc" -ne 0 ]; then
  echo "ERROR: .rite/wiki の intent-to-add に失敗しました (rc=$numref_stage_rc)。新規ページが検査されないため commit しません" >&2
  echo "  原因候補: same_branch 戦略で .gitignore に '!.rite/wiki/' negation が未設定の可能性" >&2
  echo "  対処: root .gitignore に '!.rite/wiki/' と '!.rite/wiki/**' を追記する" >&2
  echo "    (置く位置は '.rite/wiki/' 除外行より後ろ。anchor '# <<< gitignore-wiki-section-end'" >&2
  echo "     があればその直後、無ければ末尾。前に置くと後勝ちで negation が効かない)" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=stage_failed; rc=$numref_stage_rc" >&2
  exit 1
fi
# rc だけでは足りない。ディレクトリ自体は非 ignore で**配下ファイルだけ**が ignore された
# ドリフト (`.rite/.gitignore` が '*' + '!wiki/' を持ち '!wiki/**' を欠く形) では、
# add -N は rc=0 で何も stage せず、続く git diff が空 = 無言の 0 件 clean になる。
# rc ではなく実体 (ignore されたまま残っているファイル) を見て fail-loud にする。
# rc は直前の add -N と同型に捕捉する。この arm は 2 つの呼び出しの間に git が壊れた場合しか
# 踏まないため専用 fixture を持たない (非 repo / パス不在はどちらも add -N が先に落ちる)。
numref_ig_rc=0
# core.quotePath 既定 (true) だと非 ASCII パスが C クォート済み literal で返り、それを
# check-ignore へ渡しても実パスに一致せず原因を名指しできない。既存の同型呼び出しと揃える。
numref_ignored=$(git -C "$numref_tree" -c core.quotePath=false ls-files --others --ignored --exclude-standard -- .rite/wiki) || numref_ig_rc=$?
if [ "$numref_ig_rc" -ne 0 ]; then
  echo "ERROR: ignore 残存の検査に失敗しました (git ls-files rc=$numref_ig_rc)。検査結果が不明なまま commit しません" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=ignored_check_failed; rc=$numref_ig_rc" >&2
  exit 1
fi
if [ -n "$numref_ignored" ]; then
  echo "ERROR: .rite/wiki 配下に gitignore されたままのファイルがあります。検査にも commit にも載らないため中止します" >&2
  printf '%s\n' "$numref_ignored" | head -5 | sed 's/^/    /' >&2
  # どの .gitignore のどのパターンが効いているかは手元で確定できる。委譲先の health-check は
  # rite-config.yml と state_root を前提に別ツリーを見るため、$numref_tree の原因を名指しできない。
  # ここでは ignore 済みが確定しているので、check-ignore の negation 非決定性の caveat も効かない。
  # 表示した全件を渡す。先頭 1 件だけを名指しすると、原因が複数ある回は直して再実行しても
  # 同じ reason で止まり、委譲をやめてまで削ろうとした往復がそのまま残る。
  # 出力が空なら見出しを出さない（「以下」と言って中身が無い形にしない）。
  numref_causes=$(printf '%s\n' "$numref_ignored" | head -5 \
    | git -C "$numref_tree" -c core.quotePath=false check-ignore -v --stdin 2>&1) || true
  if [ -n "$numref_causes" ]; then
    echo "  原因: 以下の .gitignore のパターンが効いています" >&2
    printf '%s\n' "$numref_causes" | sed 's/^/    /' >&2
  else
    echo "  原因: check-ignore が原因を特定できませんでした。$numref_tree で" >&2
    echo "        git check-ignore -v -- <上記のファイル> を手動実行してください" >&2
  fi
  echo "  対処: そのファイルを直す。nested .rite/.gitignore なら 3 行構成 '*' / '!wiki/' / '!wiki/**'" >&2
  echo "        へ戻す。root .gitignore なら '.rite/wiki/' 除外行より後ろに negation を追記する" >&2
  echo "        (root への追記では nested の '*' は解除できない)" >&2
  echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=ignored_paths" >&2
  exit 1
fi
numref_rc=0
bash "$check" --repo-root "$numref_tree" --diff HEAD --path .rite/wiki --quiet || numref_rc=$?
case "$numref_rc" in
  0) echo "[CONTEXT] WIKI_INGEST_NUMREF=clean" ;;
  1) echo "[CONTEXT] WIKI_INGEST_NUMREF=hit" ;;
  *)
    echo "ERROR: number-reference-check.sh の実行に失敗しました (rc=$numref_rc)。検査結果が不明なまま commit しません" >&2
    echo "[CONTEXT] WIKI_INGEST_NUMREF=error; reason=check_failed; rc=$numref_rc" >&2
    exit 1
    ;;
esac
```

| `WIKI_INGEST_NUMREF` | アクション |
|---|---|
| `clean` | ステップ 5.1 / 5.2 へ進む |
| `hit` | stdout の `file:line: 内容` が指す行を書き直してから**本ステップを再実行**する。書き直しは番号を落として現在形の Why にすること — 番号を消した跡に経緯文を置き換えない。ソース bullet は説明だけを表示テキストにし、説明が無ければ種別語（「レビュー結果」「fix 結果」「close retrospective」）にする（リンク先パスは変えない）。**`index.md` の行は Edit しない** — ステップ 6 の `wiki-index-update.sh` を修正した `--description` で呼び直す（index.md への書き換えは helper が atomic に行う契約のため）。この禁止は ingest 実行中（helper を呼べる文脈）の話で、lint 指摘の事後手当ては `/rite:wiki-lint` の手順に従う。再実行で `clean` にできなければ commit せず停止し、残った行と `/rite:recover` を案内する |
| `error` (`reason=stage_failed`) | bash が `exit 1` で停止済み。`same_branch` では root `.gitignore` に `!.rite/wiki/` と `!.rite/wiki/**` を**`.rite/wiki/` 除外行より後ろ**へ追記してから**本ステップを再実行**する（`# <<< gitignore-wiki-section-end` anchor があればその直後、無ければ末尾。前に置くと後勝ちで効かない）。`separate_branch` では root `.gitignore` を持たないので、`{numref_tree}` が wiki worktree の絶対パスに substitute されているか（ステップ 1.3）を先に疑う |
| `error` (`reason=ignored_paths`) | bash が `exit 1` で停止済み。stderr が `check-ignore -v` で名指しした `.gitignore` を直してから**本ステップを再実行**する。nested `.rite/.gitignore` なら 3 行構成 '*' / '!wiki/' / '!wiki/**' へ戻す（root への negation では nested の '*' は解除できない） |
| `error` (`reason=placeholder_residue`) | bash が `exit 1` で停止済み。`{plugin_root}` / `{numref_tree}` を literal substitute して**本ステップを再実行**する |
| `error` (`reason=helper_missing` / `check_failed` / `ignored_check_failed`) | bash が `exit 1` で停止済み。commit せず停止し、stderr の原因と `/rite:recover` を案内する |

> 番号の定義は `number-reference-check.sh` が持つ（3-4 桁の番号トークン）。本ステップは文法を書き下さない。1-2 桁 / 5 桁以上（上流トラッカ id 等）は**本検査の検出対象外**であり、検出されないことは規則上書いてよいことを意味しない（規則の SoT は `SCHEMA.md` の「番号ではなく Why 散文」）。

#### canonical numref_verdict gate (唯一の真実源)

ステップ 5.1 / 5.2 の bash 冒頭に置く commit ゲートは以下を **literal 一致**させる。`{numref_verdict}` はステップ 5.0.n の `[CONTEXT] WIKI_INGEST_NUMREF=` の最新値を literal substitute する。片側だけ直すと 2 経路で commit ゲートの強さが割れるため、変更時は本節 + ステップ 5.1 + ステップ 5.2 の **3 箇所を必ず同時に更新する**（ステップ 5.0.c の commit message 契約と同じ規約）。

```bash
# ステップ 5.0.n の判定を機械的に受ける。`{numref_verdict}` は同ステップの
# [CONTEXT] WIKI_INGEST_NUMREF= の最新値を literal substitute する。
# 未置換 / 未知値 / hit のいずれも commit しない（検査を飛ばした実行を素通しさせないため）。
numref_verdict="{numref_verdict}"
case "$numref_verdict" in
  clean) ;;
  hit)
    echo "ERROR: 番号参照が残ったままです。commit しません (ステップ 5.0.n の hit 行を書き直してから再実行してください)" >&2
    exit 1
    ;;
  *)
    echo "ERROR: ステップ 5.0.n の判定を受け取れていません (numref_verdict='$numref_verdict')。commit しません" >&2
    exit 1
    ;;
esac
```

### 5.1 separate_branch 戦略 (worktree ベース)

ステップ 5.0 手順 1-7 を Write/Edit し、ステップ 5.0.n の検査を通した後、以下で worktree 内の変更を commit する。**下の bash 冒頭のゲートは canonical numref_verdict gate 節の literal 複製**で、変更時は同節の 3 箇所同時更新規約に従う。値はステップ 5.0.n の `[CONTEXT] WIKI_INGEST_NUMREF=` の最新値（`clean` / `hit`）を literal substitute する。散文で 5.0.n を名指しするだけでは、5.0.n を飛ばしても commit が成功してしまう。**push はここでは行わない**。commit は `wiki-worktree-commit.sh --commit-only` に委譲する:
rationale: references/rationale.md#push-defer-1941

```bash
# ステップ 5.2 と対称に set -euo pipefail を宣言する (strict mode)
set -euo pipefail

# ステップ 5.0.n の判定を機械的に受ける。`{numref_verdict}` は同ステップの
# [CONTEXT] WIKI_INGEST_NUMREF= の最新値を literal substitute する。
# 未置換 / 未知値 / hit のいずれも commit しない（検査を飛ばした実行を素通しさせないため）。
numref_verdict="{numref_verdict}"
case "$numref_verdict" in
  clean) ;;
  hit)
    echo "ERROR: 番号参照が残ったままです。commit しません (ステップ 5.0.n の hit 行を書き直してから再実行してください)" >&2
    exit 1
    ;;
  *)
    echo "ERROR: ステップ 5.0.n の判定を受け取れていません (numref_verdict='$numref_verdict')。commit しません" >&2
    exit 1
    ;;
esac

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

`same_branch` では Raw Source / ページ / index.md / log.md はすべて dev ブランチ上。ステップ 5.0 手順 1-7 とステップ 5.0.n の検査の後、以下で一括 commit する（ブランチ切り替え・worktree 不要）。**canonical numref_verdict gate 節の literal 複製を bash 冒頭に置く**（変更時は同節の 3 箇所同時更新規約に従う）:

```bash
set -euo pipefail

# ステップ 5.0.n の判定を機械的に受ける。`{numref_verdict}` は同ステップの
# [CONTEXT] WIKI_INGEST_NUMREF= の最新値を literal substitute する。
# 未置換 / 未知値 / hit のいずれも commit しない（検査を飛ばした実行を素通しさせないため）。
numref_verdict="{numref_verdict}"
case "$numref_verdict" in
  clean) ;;
  hit)
    echo "ERROR: 番号参照が残ったままです。commit しません (ステップ 5.0.n の hit 行を書き直してから再実行してください)" >&2
    exit 1
    ;;
  *)
    echo "ERROR: ステップ 5.0.n の判定を受け取れていません (numref_verdict='$numref_verdict')。commit しません" >&2
    exit 1
    ;;
esac

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
  # 失敗時は anchor marker (gitignore-wiki-section-end) を案内する。
  add_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-ingest-add-err-XXXXXX" 2>/dev/null) || add_err=""
  if ! git add .rite/wiki/ 2>"${add_err:-/dev/null}"; then
    echo "ERROR: git add .rite/wiki/ failed" >&2
    if [ -n "$add_err" ] && [ -s "$add_err" ]; then
      echo "  詳細 (git add stderr 先頭 5 行):" >&2
      head -5 "$add_err" | sed 's/^/    /' >&2
    fi
    echo "  原因候補: same_branch 戦略で .gitignore に '!.rite/wiki/' negation が未設定の可能性" >&2
    echo "  対処:" >&2
    echo "    1. grep -n 'gitignore-wiki-section-end' .gitignore で anchor 位置を特定 (配布先には anchor が無いことがある。その場合は '.rite/wiki/' 除外行より後ろ、無ければ末尾へ追記する)" >&2
    echo "    2. 同ブロック内の手順に従い '!.rite/wiki/' negation を追加し (追記位置は上記 1 に従う。'.rite/wiki/' 除外行より前に置くと後勝ちで効かない)、git add --dry-run で verification してから再実行" >&2
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
| `{concept_type}` | OKF v0.2 必須フィールド。page-template.md の frontmatter トップレベル `type:` に substitute する concept 種別。値は `{domain}` と同じ literal（`patterns` / `heuristics` / `anti-patterns`）を入れる。OKF consumer の type ベース routing 用。**⚠️ 本 placeholder は同名衝突回避のため `{concept_type}` と命名している** — ステップ 4.2 / 5.0 の `raw/{type}/{filename}` パスや `sources[].type` 追記で使う `{type}` は Raw Source type（`reviews` / `retrospectives` / `fixes`、`{source_type}` 由来）であり別物 |
| `{title}` | ステップ 4.1 で生成したタイトル |
| `{domain}` | `patterns` / `heuristics` / `anti-patterns` |
| `{description}` | ステップ 4.1 のサマリー（`{summary}` と同源の 1-2 文）。OKF 推奨の concept 説明文として page frontmatter `description` に機械可読で保持し、ステップ 6 で index.md 登録行のサマリー列にも反映する。`/rite:wiki-query` の Pass 1（`hooks/wiki-query-inject.sh`）はテーブル行のサマリー列をキーワード照合に使う（箇条書き形式の index も引き続き読む） |
| `{created}` / `{generated_at}` | `{created}` は初出時刻（独自拡張）。`{generated_at}` は最終内容変更時刻（OKF `generated.at`）。いずれも現在の ISO 8601。`{model_id}` はセッションが報告する実行モデル ID。空なら Write しない（fail-loud） |
| `{source_type}` | Raw Source の `type` フィールド (`reviews` / `retrospectives` / `fixes` の 3 値のみ — `wiki-ingest-trigger.sh` が受理する値と一致) |
| `{source_ref}` | Raw Source の wiki-root 起点ファイル相対パス（例: `raw/reviews/20260413T...md`）。template 側で `../../` prefix を hardcode するため、placeholder 値自体には prefix を含めない。**⚠️ raw frontmatter の `source_ref` フィールド値（PR 識別子、例: `pr-1143`）をそのまま使ってはならない** — page の `sources[].resource` は常に Raw Source の**ファイルパス形式** `raw/{type}/{filename}` であり、PR 識別子形式ではない（同名 placeholder と raw フィールドの dual-use 混同による drift。概念は Wiki anti-pattern `placeholder-dual-use-resolution-drift`〔wiki ブランチに蓄積される経験則ページ。develop ツリーには実体なし〕）。lint はこの `resource` をファイルパス形式で raw と突合するため、PR 識別子だと raw→page 追跡が切れ false `missing_concept` を量産する |
| `{summary}` | ステップ 4.1 のサマリー |
| `{details}` | ステップ 4.1 の詳細 |
| `{related_page_title}` / `{related_page_path}` | ステップ 4.3 で決定した値。**該当ページがない場合は `## 関連ページ` セクション全体を `- （関連ページなし）` の平文 1 行に Edit で書き換える** (空 placeholder のままにすると Markdown link `[]()` が破綻) |
| `{source_description}` | Raw Source の `title` から**番号・日付を落とした説明文**。説明が取れない場合は種別語（「レビュー結果」「fix 結果」「close retrospective」）。`title` をそのまま転記してはならない（規則の SoT は `SCHEMA.md` の「番号ではなく Why 散文」。日付はリンク先パスにあるので重ねない）。`## ソース` セクションのリンク表示テキストに使われ、URL には `{source_ref}` が使われることで両者を分離する |

**confidence フィールド**: page-template.md の `confidence: medium` はリテラル。Write 後に Edit でステップ 4 の判定値 (`high` / `medium` / `low`) に置換する。
rationale: references/rationale.md#confidence-literal

---

## ステップ 6: index.md の更新

`.rite/wiki/index.md` の `## ページ一覧` 5 列テーブル（列順: ページ / ドメイン / サマリー / 更新日 / 確信度）への登録行の追加/更新・重複行の回収・`## 統計` 3 行の同期を、`{plugin_root}/hooks/scripts/wiki-index-update.sh` の 1 回呼び出しで行う。同定述語・セル区切りエスケープ・重複中止・統計最小形・統計節不在スキップの確定仕様は **helper のヘッダ docstring が Source of Truth**。挙動は `hooks/tests/wiki-index-update.test.sh` の fixture が固定する。本ステップは substitute と結果 marker の読み取りのみ。index.md への書き換えは helper が atomic に行う（LLM が Read/Edit で index.md を直接操作してはならない）。

**入力契約**: 対象ページの frontmatter 値とファイルパスを substitute する。

- `{title}` / `{description}` / `{updated}` / `{confidence}` は page frontmatter の値から **YAML の引用符を外して**渡す（`title: "…"` の実体は引用符の内側）。`{updated}` の値は `generated.at`（index 列名「更新日」と `--updated` フラグ名は不変）。**値の加工はそれだけ** — セル区切りエスケープとリンク構文の中和は helper 内で一元適用するので呼び出し側では行わず、言い換えも禁止
- `{description}` は frontmatter に `description` が無ければ**空のまま**渡す（helper が既存行のサマリー列を保持する）。非空ならステップ 4.1 で作成した番号なし Why 要約と literal に同じ値を渡し、index 用の別要約を生成しない
- `{domain}` / `{slug}` は対象ページの**ファイルパス** `pages/{domain}/{slug}.md` から取る（新規経路はステップ 4.1 で決めた値、更新経路はステップ 5.0 手順 4 で Read した既存ファイルの domain ディレクトリ名とファイル名 stem）。`title` からの再導出はしない

**substitute する 6 値はすべて quoted heredoc で受ける**。
rationale: references/rationale.md#index-quoted-heredoc

**実行前ゲート（必須）**: substitute する 6 値のいずれかが**複数行**、またはいずれかの**行が終端子 `WIU_EOF` と完全一致**する場合、**この bash を実行してはならない**。該当したら当該ページの index 更新をスキップし、ステップ 9 の未完了事項に載せる（marker 表の exit 1 行と同じ扱い）:

```bash
branch_strategy="{branch_strategy}"
wiki_wt_abs="{wiki_worktree_abs}"
if [ "$branch_strategy" = "separate_branch" ]; then
  wiki_root="${wiki_wt_abs:-.rite/wiki-worktree}/.rite/wiki"
else
  wiki_root=".rite/wiki"
fi
wiu_title=$(cat <<'WIU_EOF'
{title}
WIU_EOF
)
wiu_description=$(cat <<'WIU_EOF'
{description}
WIU_EOF
)
wiu_domain=$(cat <<'WIU_EOF'
{domain}
WIU_EOF
)
wiu_slug=$(cat <<'WIU_EOF'
{slug}
WIU_EOF
)
wiu_updated=$(cat <<'WIU_EOF'
{updated}
WIU_EOF
)
wiu_confidence=$(cat <<'WIU_EOF'
{confidence}
WIU_EOF
)
bash "{plugin_root}/hooks/scripts/wiki-index-update.sh" \
  --index "$wiki_root/index.md" --pages-root "$wiki_root/pages" \
  --title "$wiu_title" --description "$wiu_description" \
  --domain "$wiu_domain" --slug "$wiu_slug" \
  --updated "$wiu_updated" --confidence "$wiu_confidence"
```

**結果 marker**: helper は 1 回の呼び出しで `row_action=` / `dedup_removed=` / `stats_sync=` の 3 marker を**必ず同時に**出力する。**`row_action` 軸と `stats_sync` 軸は独立で、両軸の該当行をそれぞれ適用する**。`dedup_removed=` は分岐を持たず、1 以上なら回収件数をステップ 9 の未完了事項へ載せる:
rationale: references/rationale.md#index-axes-independent

| 結果 | アクション |
|---|---|
| exit 0 + `row_action=added` / `updated` | 正常。次の処理へ続行（`stats_sync` 軸も併せて評価する） |
| exit 0 + `row_action=aborted_duplicate` | 対象ページの登録行が 2 行以上あり追加/更新を中止（first-match fallback はしない）。重複の後発行は同呼び出しの回収処理が削除済みのため、次に当該ページが ingest されるサイクルでは中止条項に掛からない（**本サイクル分の登録行更新は失われ、登録行は旧値のまま残る**）。**helper の WARNING をそのまま表示し、当該ページの登録行が旧値のまま残ることをステップ 9 の未完了事項に含める**（exit 1 行と同じく Lint のどの観点にも載らないため）。続行 |
| exit 0 + `stats_sync=synced` | 統計同期完了。ただし **stderr に `'## 統計' 節に既存行が見つからない統計行があります` を含む WARNING がある場合**は 3 行のうち一部しか同期できていない（既存行が無い統計行は新設しない仕様）。その WARNING をそのまま表示し、未同期の統計行名をステップ 9 の未完了事項に含める。続行（**判別は本 literal で行う** — 同じ呼び出しで重複中止の WARNING も stderr に出るため、WARNING の有無だけで判定すると統計が完全に同期された呼び出しを部分未同期と誤報告する。重複中止は `row_action=aborted_duplicate` 行が受け持つ） |
| exit 0 + `stats_sync=skipped_no_section` | `## 統計` 節が無い（節は新設しない仕様。総ページ数は `/rite:wiki-lint` のレポートで確認できる）。続行 |
| exit 0 + `stats_sync=skipped_unreadable` | 統計同期をスキップ（原因は stderr の WARNING に出ているのでそれを表示する。`## 統計` 節は前サイクルの内容のまま）。続行。**本行と部分未同期 WARNING はステップ 9 の未完了事項へ載せる** — 統計可視化の追加機構（専用 lint / marker attest / サイクル gating）は helper ヘッダで「実装しない」と明記（根拠は helper ヘッダ「Observability of procedure 3b」） |
| exit 0 だが marker が 1 行も出ない | helper 呼び出しが構文レベルで壊れている（上記 bash の継続バックスラッシュ脱落・placeholder 置換崩れ等で、helper に到達せず別コマンドの rc が返っている）。**成功として扱わない** — 実行した bash をそのまま表示し、当該 Raw Source の index 更新をスキップしてステップ 9 の未完了事項に含め、ステップ 7 へ続行する |
| exit 2（ERROR 出力） | 引数不正 = 呼び出し側の substitute 漏れ・値の混入。**部分適用は無い**（書き込みは全処理成功時の atomic 1 回のみ）。ERROR が指す引数を substitute し直して**同じ bash を再実行**する（再実行しても exit 2 なら ERROR を表示して当該 Raw Source の index 更新をスキップし、ステップ 7 へ続行） |
| exit 1（ERROR 出力） | 環境・構造要因（index.md 不在・想定外構造）で再実行では解消しない。**部分適用は無い**（同上）。ERROR をそのまま表示して当該 Raw Source の index 更新をスキップし、ステップ 7 へ続行する。新規ページの未登録はステップ 8 の Lint が orphans として検出するが、**既存ページの更新失敗は登録行が旧値のまま残り Lint のどの観点にも載らない** — 表示した ERROR が唯一のシグナルなのでステップ 9 の未完了事項（`{ingest_outstanding_line}`）に必ず含める |
| 上記以外の非ゼロ exit（helper パスを解決できない 127、signal 中断の 130 / 143 / 129 等。marker は 1 行も出力されない） | helper の出力（あれば）と exit code をそのまま表示し、当該 Raw Source の index 更新をスキップしてステップ 7 へ続行する。**部分適用は無い**（同上）。exit 1 と同様、表示した内容をステップ 9 の未完了事項に含める |

**全 Raw Source が skip 決定だったサイクルでは本ステップが 1 度も走らない**（ステップ 5.0 手順 6 の条件）。書き込みはステップ 5 と同じブランチコンテキスト。`same_branch` および `{wiki_worktree_abs}` 空の縮退は **dev ツリー root を cwd とする前提**。
rationale: references/rationale.md#skip-cycle-no-3a

---

## ステップ 7: log.md の追記

`.rite/wiki/log.md` に OKF 予約構造（`## YYYY-MM-DD` 見出し + 散文 bullet、**新しい順** = 先頭が最新。v0.2 §9 は v0.1 から不変）で **append-only** に変更履歴を追記する。skip 等の機械可読状態は raw frontmatter の `ingest_status`（ステップ 5）が SoT。
rationale: references/rationale.md#log-human-only

**追記ルール**:

- 今日の日付見出し `## YYYY-MM-DD` が `# Directory Update Log` 直後（ログ先頭）に無ければ新規追加する（新しい順のため最新日付を先頭に置く）。既にあればその見出し配下の bullet 群末尾に追加する
- 各 Raw Source 1 件につき 1 bullet を追加する:
  - **新規**: `* **Create**: [{title}](pages/{domain}/{slug}.md) — {source_ref} を新規ページ化`（`{title}` はステップ 5.3 で定義したページタイトル、リンク先は index.md の登録行と同じ `pages/{domain}/{slug}.md`）
  - **更新**: `* **Update**: [{title}](pages/{domain}/{slug}.md) — {source_ref} を統合`
  - **スキップ**: `* **Skip**: [{filename}](raw/{type}/{filename}) — {skip_reason}`（`{filename}` は当該 Raw Source のファイル名、`{type}` は Raw Source type）
- 既存の日付見出し・bullet（過去エントリ）は改変しない

---

## ステップ 8: 自動 Lint

Ingest 直後、Wiki 全体の品質チェックを `/rite:wiki-lint --auto` として実行する。**4 ブロッキング観点** (矛盾・孤児ページ・欠落概念・壊れた相互参照) + **2 informational 指標** (陳腐化、未登録 raw（`ingest_status: skipped` 済み）) で計 6 フィールドを検査する。

### 8.1 auto_lint 設定の確認

`rite-config.yml` の `wiki.auto_lint` を読み取る。**ステップ 1.1 とは別の inline lenient パーサ**を使う。**1.1 の旧形 (awk で行全体を参照する形) をここへ持ち込んではならない**:
rationale: references/rationale.md#auto-lint-inline-parser

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

**`auto_lint=false` の場合**: ステップ 8.2-8.5 を skip する。**ステップ 8.6 (push の集約) はスキップしない**。ステップ 8.6 を実行してからステップ 9 へ進む。Lint カウンタ 6 種はステップ 2.1 で 0 初期化済み。ステップ 9 の「Wiki 品質警告」行は「スキップ (auto_lint disabled)」、「未登録 raw」行は `0` 件。

### 8.2 Lint エンジンの呼び出し

LLM は `skill: "rite:wiki-lint", args: "--auto"` 形式で `/rite:wiki-lint` を `--auto` モードで呼び出す。`--auto` モードの契約:

- `Lint: contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` 形式の 1 行 + `<!-- skill return signal: caller must continue next step -->` + `<!-- [lint:returned-to-caller:auto] -->` HTML コメント sentinel の 3 行を出力する (0 件でも必ず出力)
- log.md への追記は lint.md 側がブランチ状態を判定し自律実行する
- 常に exit 0 (非ブロッキング)
rationale: references/rationale.md#lint-parser-first-line

呼び出し時の CWD は常に dev ブランチ。lint ステップ 8.2 は `separate_branch` 時に worktree 内で log.md 追記 → `wiki-worktree-commit.sh` を呼ぶ。Skill return 後、8.3 → 8.4 → 8.5 → ステップ 9 の順。

### 8.3 Lint 実行結果の取得とパース

LLM は Skill 応答テキスト (= `lint.md` ステップ 9.2 の最終 stdout) を会話コンテキストからパースする。**Skill 応答テキストの内容**で成否を判定する。

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

通常時は step 2 のみで完結する。

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

3. **stdout が空の場合**: **Lint 実行失敗として扱う**:

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

4. **stdout のどの行も regex にマッチしない場合**: フォーマット変更の警告として扱う:

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

**全カテゴリが 0 件の場合** (`n_contradictions + n_stale + n_orphans + n_missing_concept + n_unregistered_raw + n_broken_refs == 0`): 「Lint 結果: 問題なし」とのみ表示する。1 件以上検出された場合は必ず全カテゴリを表示する (`n_stale` / `n_unregistered_raw` は informational だが表示判定には含める)。

ERROR / stdout 空 / regex mismatch 経路では「Lint 結果: 実行失敗（{原因}）」と表示する。

### 8.5 `n_warnings` カウンタへの加算

**ステップ 8.3 step 2 (6 フィールド regex match 成功) 経路でのみ実行する**。step 1/3/4 は 8.3 内で加算済みのため skip。step 2 経路のみ `n_warnings` に Lint 検出件数合計を加算する:

```
n_warnings += n_contradictions + n_orphans + n_missing_concept + n_broken_refs
```

**`n_stale` と `n_unregistered_raw` は加算しない**。informational 指標として `n_warnings` には算入せず、完了レポートに件数のみ表示する — `n_stale` は `Lint 結果:` 行（ステップ 8.4 で定義）に、`n_unregistered_raw` は同行と未登録 raw 専用行に現れる。どちらも `{wiki_warnings_line}` の内訳には含めない。
rationale: references/rationale.md#n-unregistered-not-warning

**詳細な修正対応**: 検出結果の詳細確認は、Ingest 完了後に `/rite:wiki-lint`（`--auto` なし）で再実行して取得する。

### 8.6 Wiki push の集約（wiki push batch/defer）

**`auto_lint` の値に関わらず必ず実行する**（ステップ 8.1 参照）。蓄積されたローカル commit（0 件のこともある）をまとめて 1 回だけ push する。`same_branch` では本ステップは no-op:
rationale: references/rationale.md#push-defer-1941

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

`push_out` の `push=no-op` は失敗ではない（`WIKI_INGEST_PUSH=ok`）。`[CONTEXT] WIKI_INGEST_PUSH=` はステップ 9.0 の push 状態表示と `/rite:cleanup` ステップ 9 の push 失敗判定（stdout 中の `push=failed`）に使う。

---

## ステップ 9: 完了レポート

### 9.0 Ingest セッション lock の解放

ステップ 1.4 で取得した ingest セッション lock を解放する:
rationale: references/rationale.md#lock-release-failsafe

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

検出器化候補:
{detector_candidate_lines}

未完了事項:
{ingest_outstanding_line}

新規/更新ページ:
- {path1} ({action1})
- {path2} ({action2})

次のステップ:
- /rite:wiki-query で経験則を参照
- 詳細な品質チェックは /rite:wiki-lint で確認してください（ステップ 8 で自動実行済み）
```

`{detector_candidate_lines}` の展開規則:

| 条件 | 展開 |
|------|------|
| 1 件以上 | 各候補を `- [検出器化候補] {one-line-summary}（raw/{type}/{filename}）` の 1 行で列挙（1 経験則 1 行。`skip_reason: "detector-candidate: ..."` の要約と同一文にする） |
| 0 件 | `- なし` |

`{wiki_warnings_line}` の展開ルール:

| `auto_lint` | 「Wiki 品質警告:」行の展開 |
|-------------|-----------------------|
| `true` (通常経路) | `Wiki 品質警告: {n_warnings} 件（内訳: 矛盾 {n_contradictions} / 孤児 {n_orphans} / 欠落 {n_missing_concept} / 壊れた相互参照 {n_broken_refs} / Lint 異常経路 {n_lint_anomaly}）` |
| `false` (skip 経路) | `Wiki 品質警告: スキップ (auto_lint disabled)` (内訳は表示しない) |

「未登録 raw」行は `auto_lint=false` の場合も `0` 件として展開する (ステップ 2.1 で 0 初期化済みの値)。

**等式**: `n_warnings = n_contradictions + n_orphans + n_missing_concept + n_broken_refs + n_lint_anomaly`。step 2 成功時は `n_lint_anomaly=0`。step 1/3/4 では 4 カテゴリは 0 fallback だが `n_lint_anomaly >= 1` のため `n_warnings >= 1`。

`{wiki_push_line}` の展開ルール (ステップ 8.6 の `[CONTEXT] WIKI_INGEST_PUSH=` を上から評価し最初の一致を採用):

| `WIKI_INGEST_PUSH=` | 展開 |
|---|---|
| `ok` | `Wiki push: 完了`（`push=no-op` だった場合も含む — push すべき commit が無かっただけで失敗ではない） |
| `failed` | `⚠️ Wiki push: commit は local wiki branch に landed しましたが origin への push に失敗しました。手動回復: git -C {wiki_worktree_abs} push origin {wiki_branch}` |
| `skipped; reason=same_branch` | `Wiki push: 対象外 (same_branch 戦略。通常の PR push に含まれる)` |
| marker なし（ステップ 8.6 未到達などの想定外経路） | `⚠️ Wiki push: 実行結果が確認できませんでした。git -C {wiki_worktree_abs} status で確認してください` |

`{ingest_outstanding_line}`（非ブロッキング失敗の集約欄。Wiki push については `{wiki_push_line}` と同じ `WIKI_INGEST_PUSH=` marker を再評価するだけで新しい記録先は持たない）。**ステップ 6 の index 更新と Wiki push の 2 系統を評価し、該当するものをすべて列挙する**:
rationale: references/rationale.md#outstanding-no-new-store

| 系統 | 条件 | 展開 |
|---|---|---|
| index 更新 | ステップ 6 が ERROR 表示 / 実行スキップに至った Raw Source がある（exit 1 / exit 2 の再実行後失敗 / marker 無しの非ゼロ exit / marker 無しの exit 0 / 実行前ゲートによるスキップ） | `- ⚠️ index 未更新: pages/{domain}/{slug}.md（{ステップ 6 で表示した出力の 1 行目}）` を該当件数ぶん列挙。**ERROR 行があるとは限らない** — 127 は bash の `No such file or directory`、signal 中断（130 / 143 / 129）は出力ゼロなので、その場合は `（出力なし、exit code {n}）` と書く（実行前ゲートによるスキップは `（実行前ゲート: 値が複数行または終端子行と一致）`） |
| index 更新 | `row_action=aborted_duplicate` / `stats_sync=synced` かつ stderr に `'## 統計' 節に既存行が見つからない統計行があります` を含む WARNING あり / `stats_sync=skipped_unreadable` の Raw Source がある | `- ⚠️ index 部分未同期: pages/{domain}/{slug}.md（{WARNING 1 行目}）` を該当件数ぶん列挙（`synced` 側の判別が本 literal に閉じているのはステップ 6 marker 表と同じ理由 — 重複中止 WARNING との二重計上を防ぐ） |
| index 更新 | `{n_dedup_removed}` が 1 以上 | `- ℹ️ index 重複行を {n_dedup_removed} 件回収しました` |
| Wiki push | `WIKI_INGEST_PUSH=failed` | `- ⚠️ Wiki push: commit は local wiki branch に landed しましたが origin への push に失敗しました。手動回復: git -C {wiki_worktree_abs} push origin {wiki_branch}（次回 /rite:wiki-ingest 実行時にも自動で flush を試みます）` |
| Wiki push | marker なし（ステップ 8.6 未到達などの想定外経路） | `- ⚠️ Wiki push: 実行結果が確認できませんでした。git -C {wiki_worktree_abs} status で確認してください`（`{wiki_push_line}` の同ケースと同じ扱い — 未確認を「失敗なし」と断定しない） |
| （両系統） | 上記のいずれにも該当しない（index 更新が全件成功し、回収した重複行が 0 件で、push も `ok` / `skipped; reason=same_branch`） | `- なし（非ブロッキングで継続した失敗はありませんでした）` |

### 9.1 Return-to-Caller Signal

完了レポート本体 (処理サマリー + 新規/更新ページ + 次のステップ) を出力した後、**最終 2 行**に HTML コメント sentinel を出力する:

```
<!-- skill return signal: caller must continue next step -->
<!-- [ingest:returned-to-caller] -->
```

sentinel は grep 可能 (`grep -F '[ingest:returned-to-caller]'`) で rendered view では不可視。bare bracket `[ingest:returned-to-caller]` は禁止、HTML コメント形式のみ許容する。
rationale: references/rationale.md#returned-to-caller

---

## エラーハンドリング

| エラー | 対処 |
|--------|------|
| `wiki.enabled: false` | 早期 return（ステップ 1.1。版数検査・migration とも不発動） |
| `wiki-okf-migrate.sh` 非ゼロ（ステップ 1.5） | exit 1 で fail-loud。`okf_version` は bump されない。原因除去後に再実行 |
| `lib/wiki-config.sh` 読込失敗 (helper 不在 / 解決失敗) | exit 1 で fail-fast（`[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1`。設定を判定できないまま無効扱いへ倒さない。plugin のインストール状態を確認するか `/rite:setup` を再実行、ステップ 1.1） |
| Wiki 未初期化 / worktree セットアップ失敗 | `/rite:wiki-init` を案内、または `wiki-worktree-setup.sh` のエラー出力を確認して `git worktree prune` / `git fetch origin wiki:wiki` で復旧 (ステップ 1.3) |
| 処理対象 0 件 | 静かに終了し情報メッセージのみ表示（ステップ 2.3） |
| `wiki-worktree-commit.sh --commit-only` exit 3 (git add/commit 失敗、ステップ 5.1) | exit 1 で fail-fast。`git -C .rite/wiki-worktree status` で worktree の状態を確認 |
| `wiki-worktree-commit.sh --push-only` exit 4 (push 失敗、ステップ 8.6) | 非 fatal で継続。commit は local wiki branch に保持される。`git -C .rite/wiki-worktree push origin {wiki_branch}` で手動回復、または次回 ingest の ステップ 8.6 が自動で flush を試みる |
| `wiki-worktree-commit.sh` 未知の exit code | exit 1 で fail-fast |
| `wiki-index-update.sh` 非ゼロ exit（exit 1 / exit 2 / 127 / signal 130・143・129 等、ステップ 6） | 当該 Raw Source の index 更新をスキップして続行（非 fatal）。分岐と対処はステップ 6 の結果 marker 表が SoT |
| `branch_strategy` が未知の値 | ステップ 5.1 の if/elif/else 末尾 else 分岐で fail-fast (ステップ 5.2 の bash block は same_branch 単独分岐のため未知値はステップ 5.1 の else が catch する。`rite-config.yml` の `wiki.branch_strategy` を確認) |
| LLM が経験則を抽出できない | 該当 Raw Source の raw frontmatter に `ingest_status: skipped` + `skip_reason` を追記（skip 状態の SoT）、`ingested: true` に変更、log.md に人間向け Skip bullet を追記、`n_skipped` を +1（ステップ 5 step 5 参照） |
| 機械検出可能でページ化しない（検出器化候補） | 既存ページなし: `skip_reason: "detector-candidate: {one-line-summary}"` で skip + ステップ 9 検出器化候補に 1 行列挙。既存ページあり: 既存ページを更新しつつステップ 9 に 1 行列挙（ステップ 4 表 / ステップ 5 step 5 参照） |

---

## 設計原則

- **単一責任**: Ingest は「Raw Source → Wiki ページ」の変換のみ。Query / Lint は別コマンド
- **冪等性**: 同じ Raw Source を再 Ingest しても結果が同じ (`ingested: true` フラグで重複防止)
- **append-only な log**: 変更履歴ログ (log.md) は履歴として残し、追加のみ
- **PR diff からの分離**: `separate_branch` 戦略では Wiki 変更は `.rite/wiki-worktree/` worktree 内に閉じ、dev ブランチのツリーは一切変更されない (`.gitignore` で worktree path を除外)
- **opt-out**: `wiki.enabled: true` がデフォルト。`wiki:` セクション未指定でも有効扱い
