---
name: wiki-lint
description: |
  rite workflow の Wiki 品質チェックステップ: 矛盾・陳腐化・孤児・欠落概念・壊れた相互参照等を
  検査する。/rite:wiki-ingest から programmatic に呼ばれる sub-step、または手動 /rite:wiki-lint。
  汎用の「lint」ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:wiki-lint [--auto]
argument-hint: "[--auto]"
---

# /rite:wiki-lint

Wiki Lint エンジン。`.rite/wiki/pages/` の Wiki ページ、`.rite/wiki/raw/` の Raw Source、`.rite/wiki/index.md` の整合性を検査する。やることは以下のシーケンシャルなタスク列:

1. 事前チェック (Wiki 設定 / 初期化判定 / 引数解析・カウンタ初期化)
2. 検査対象の収集 (pages_list / raw_list)
3. 矛盾検出 (タイトル衝突 / 方針逆転 / 重複情報)
4. 陳腐化検出 (`updated` frontmatter が閾値超過、`wiki-lint-stale.sh` 委譲)
5. 孤児ページ検出 (`index.md` 未登録、`wiki-lint-orphans.sh` 委譲)
6. 欠落概念検出 (`missing_concept` + `unregistered_raw` の 3 分岐)
7. 壊れた相互参照検出 (Markdown link 解決失敗、`wiki-lint-broken-refs.sh` 委譲)
7.5. 説明的番号参照検出 (ページ本文の Issue/PR/commit 番号参照、informational)
8. log.md 追記 (`lint:clean` / `lint:warning`)
9. 完了レポート (通常モード / `--auto` モード)

機械判定可能な 3 カテゴリ (陳腐化 / 孤児 / 壊れた相互参照) は helper script に委譲する。helper が件数を marker block + `[CONTEXT]` sentinel で emit するため、LLM は数値を転記するだけになり「bash を実行せず 0 件と推測報告する」経路が構造的に存在しない (欠落概念の集合構築 helper `wiki-lint-skipped-refs.sh` / `wiki-lint-source-refs.sh` と同じ保証)。

| 観点 | 検出対象 | ブロッキング |
|------|---------|--------------|
| **矛盾** | 同じトピックで異なる結論を持つページ（タイトル衝突・方針逆転・重複情報） | Yes |
| **陳腐化** | `updated` frontmatter が閾値（デフォルト 90 日）を超えて更新されていないページ | Yes |
| **孤児ページ** | `pages/` 配下に存在するが `index.md` の OKF 箇条書き（`* [title](pages/...) - desc`）に登録されていないページ | Yes |
| **欠落概念 (missing_concept)** | `raw/` に `ingested: true` の Raw Source があるが、対応ページも `sources.ref` 登録も `ingest_status: skipped` 記録（raw frontmatter）も存在しない真の欠落 | Yes |
| **壊れた相互参照** | ページ本文の Markdown リンク `](...)` が `pages/` 配下の実在ファイルを指していない | Yes |
| **未登録 raw (unregistered_raw)** | `ingested: true` で `sources.ref` 未登録だが、raw frontmatter に `ingest_status: skipped` 記録がある raw。意図的に経験則化しなかった件数の informational 指標 | **No** (`n_warnings` 不加算) |
| **説明的番号参照 (descriptive_number_ref)** | ページ本文に残った説明目的の Issue/PR 番号参照（裸の「PR #N は…」「Issue #N」、括弧付き「(refs #N)」、日本語の「#N で対応」「詳細は #N」）。Wiki は番号の受け皿ではなく Why 散文の場のため surface する。frontmatter・`## ソース` 節・コードフェンス / スパン・TODO/FIXME は除外 | **No** (`n_warnings` 不加算、ステップ 7.5) |

**設計契約**: lint は **読み取り専用** (`log.md` への追記を除く)。**原則 exit 0**で終了し、検出件数・事前チェック失敗 (下記 (c) を除く)・ブランチ読取失敗は非ブロッキングとして扱う。例外は (a) `branch_strategy` 未知値検出 (ステップ 2.2 / 4 / 5 / 6.0 / 6.2 / 7 / 8.2 / 8.3 で同型 fail-fast。うち 4 / 5 / 6.0 / 6.2 / 7 は helper 内で実行)、(b) `{mode}` / `{pages_list}` / `{log_entry}` / counter 等の Claude placeholder 残留検知 (各 site で同型 fail-fast)、(c) `lib/wiki-config.sh` の source 失敗 (ステップ 1.1)。いずれも設定ミス / 実装ミスを silent に通過させないための設計判断。

矛盾検出 (ステップ 3) と欠落概念検出 (ステップ 6) は LLM のセマンティック読解に依存する。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md) で解決する。共通パターン (ディレクトリ構造 / ブランチ管理 / テンプレート展開) は [Wiki Patterns](../../references/wiki-patterns.md) を参照。

## Arguments

| 引数 | 説明 |
|------|------|
| `--auto` | 自動実行モード（Ingest 完了時に呼び出される想定）。検出結果を `log.md` に `lint:warning` として追記し、通常モードよりも出力を最小化する |
| `--stale-days <N>` | 陳腐化判定の閾値を日数で指定（デフォルト: 90） |

## Examples

```
/rite:wiki-lint
/rite:wiki-lint --auto
/rite:wiki-lint --stale-days 30
```

---

## ステップ 1: 事前チェック

### 1.1 Wiki 設定の読み取りとブランチ戦略判定

`rite-config.yml` から `wiki_enabled` / `wiki_branch` / `branch_strategy` を取得する。ingest.md ステップ 1.1 と同型の設定読み取り (`lib/wiki-config.sh` 委譲)。`branch_strategy` 未知値は fail-fast (silent default を撤廃):

```bash
# YAML 読み取りは canonical helper (実ファイル) に委譲する。skill 本文の fenced bash に
# パーサを書くと Skill loader が位置パラメータを起動引数へ展開し、行マッチが恒偽化して
# 全キーが空になる (静的検出: hooks/scripts/dollar-zero-check.sh)。
# helper 不在は下段の branch_strategy 未知値と同じく fail-fast。設定不明のまま opt-out
# default で「Wiki 無効」と報告するのは silent default そのもの。
if ! . {plugin_root}/hooks/scripts/lib/wiki-config.sh 2>/dev/null; then
  echo "ERROR: {plugin_root}/hooks/scripts/lib/wiki-config.sh を読み込めません" >&2
  echo "  Wiki 設定を判定できないため lint を中止します (無効扱いへは倒しません)" >&2
  echo "[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1" >&2
  exit 1
fi

wiki_enabled=$(parse_wiki_scalar enabled | tr '[:upper:]' '[:lower:]')
wiki_branch=$(parse_wiki_scalar branch_name)
branch_strategy=$(parse_wiki_scalar branch_strategy)

case "$wiki_enabled" in false|no|0) wiki_enabled=false ;; *) wiki_enabled=true ;; esac  # opt-out default
wiki_branch="${wiki_branch:-wiki}"

# branch_strategy: 空文字列は legitimate fallback、未知値は fail-fast (ステップ 2.2 / 6.0 / 6.2 / 8.2 / 8.3 の case * fail-fast と対称化)
case "$branch_strategy" in
  "")
    echo "WARNING: rite-config.yml に wiki.branch_strategy が未設定のため 'separate_branch' を使用します" >&2
    echo "  対処: 意図しない場合は rite-config.yml の wiki.branch_strategy を明示的に設定してください" >&2
    branch_strategy="separate_branch"
    ;;
  separate_branch|same_branch) : ;;
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

分散実装の完全一覧と設計差異は [Wiki 有効判定パターン §分散実装ファイル一覧](../../references/wiki-patterns.md#分散実装ファイル一覧-single-source-of-truth) を SoT として参照する。本ファイルは ingest.md と対称な `parse_wiki_scalar` 委譲の lenient 2-arm 経路 (#483 opt-out default)。`[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1` (bash rc=1) のときは設定を判定できていないため無効扱いへ倒さず中止し、plugin のインストール状態確認 / `/rite:setup` 再実行を案内する。

**Wiki が無効の場合**: 早期 return (`--auto` モードでは ステップ 9.2 の 3 行出力契約を必ず守る):

```bash
# Claude placeholder {mode} 残留 fail-fast gate (glob pattern 版、同型 gate: ステップ 1.1 / 1.3 / 8.1 / 8.3 + helper 内 (4 / 5 / 6.0 / 6.2 / 7))
mode="{mode}"
case "$mode" in
  "{"*"}")
    echo "ERROR: ステップ 1.1 早期 return の {mode} placeholder が literal substitute されていません" >&2
    echo "  Claude は lint skill 呼び出し時の args 文字列 (--auto / 空) を literal で置換する必要があります" >&2
    exit 1
    ;;
esac
if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  # ステップ 9.2 contract: Lint 1 行 + return signal comment + HTML sentinel の 3 行を出力
  # (stdout 空は ingest 側で「Lint 実行失敗」扱い)
  echo "Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0"
  echo "<!-- skill return signal: caller must continue next step -->"
  echo "<!-- [lint:returned-to-caller:auto] -->"
else
  echo "Wiki 機能が無効です（wiki.enabled: false）。" >&2
  echo "有効化するには rite-config.yml の wiki.enabled を true にしてから /rite:wiki-init を実行してください。" >&2
fi
exit 0
```

`{mode}` placeholder には lint skill 起動時の引数文字列 (`--auto` 等) を Claude が literal substitute する。

### 1.3 Wiki 初期化判定

ステップ 1.1 で取得した `branch_strategy` と `wiki_branch` を使い、Wiki が初期化済みかを判定する:

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

**Wiki 未初期化の場合**: 早期 return (`--auto` モードでは ステップ 9.2 の 3 行出力契約を必ず守る):

```bash
mode="{mode}"
case "$mode" in
  "{"*"}")
    echo "ERROR: ステップ 1.3 早期 return の {mode} placeholder が literal substitute されていません" >&2
    echo "  Claude は lint skill 呼び出し時の args 文字列 (--auto / 空) を literal で置換する必要があります" >&2
    exit 1
    ;;
esac
if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  echo "Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0"
  echo "<!-- skill return signal: caller must continue next step -->"
  echo "<!-- [lint:returned-to-caller:auto] -->"
else
  echo "Wiki が初期化されていません。先に /rite:wiki-init を実行してください。" >&2
fi
exit 0
```

### 1.4 引数の解析とカウンタ変数の初期化

引数から `--auto` と `--stale-days N` を解析する:

| 変数 | 初期値 | 説明 |
|------|--------|------|
| `auto_mode` | `false` | `--auto` 指定時に `true` |
| `stale_days` | `90` | `--stale-days N` で上書き |

**カウンタ変数の初期化** (ステップ 9 完了レポートで参照される):

| 変数 | 初期値 | 確定方法 |
|------|--------|--------------------|
| `n_contradictions` | 0 | ステップ 3 で矛盾検出するごとに +1 (LLM セマンティック判定) |
| `n_stale` | 0 | ステップ 4 の `wiki-lint-stale.sh` が emit する `n_stale=` 値を転記 (LLM 独自カウント禁止) |
| `n_orphans` | 0 | ステップ 5 の `wiki-lint-orphans.sh` が emit する `n_orphans=` 値を転記 (LLM 独自カウント禁止) |
| `n_missing_concept` | 0 | ステップ 6.2 で真の欠落（raw frontmatter の `ingest_status: skipped` 記録も `sources.ref` 登録も無い）を検出するごとに +1。ingest から呼ばれた場合、ingest 側 ステップ 8.5 で `n_warnings` に加算される（ブロッキング相当） |
| `n_unregistered_raw` | 0 | ステップ 6.2 で raw frontmatter に `ingest_status: skipped` 記録ありの未登録 raw を検出するごとに +1。意図的に経験則化しなかった raw の informational 指標で `n_warnings` には加算しない |
| `n_broken_refs` | 0 | ステップ 7 の `wiki-lint-broken-refs.sh` が emit する `n_broken_refs=` 値を転記 (LLM 独自カウント禁止) |
| `n_descriptive_refs` | 0 | ステップ 7.5 でページ本文の説明的 Issue/PR/commit 番号参照を検出した hits 合計。informational 指標で `n_warnings` には加算しない。canonical `Lint:` summary 行には含めない |
| `issues[]` | `[]` | 各検出結果を `{category, page, detail}` として append (helper 委譲カテゴリは marker block の行を転記) |

---

## ステップ 2: 検査対象の収集

### 2.1 検査対象ブランチの決定

ステップ 8 log.md 追記時を除き lint は **読み取り専用** のため、`git show <branch>:<path>` および `git ls-tree -r --name-only <branch>` で wiki ブランチの内容を読み出す。

### 2.2 branch_strategy の検証と検査対象の一括収集

未知の `branch_strategy` 値を silent に same-branch 扱いしないよう case 文で検証し、`pages_list` / `raw_list` を 1 回の `git ls-tree` で抽出する。非ブロッキング契約に従い `git ls-tree` 失敗時は exit 0 + WARNING + 空 list で継続:

```bash
# signal-specific trap (EXIT/INT/TERM/HUP) で tempfile orphan を防ぐ。
# 詳細は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照。
ls_err=""
_cleanup() { [ -n "${ls_err:-}" ] && rm -f "$ls_err"; return 0; }
trap 'rc=$?; _cleanup; exit $rc' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP

branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

pages_list=""
raw_list=""

case "$branch_strategy" in
  separate_branch)
    ls_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-lint-ls-err-XXXXXX" 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile の mktemp に失敗しました。ls-tree の詳細エラー情報は失われます" >&2
      ls_err=""
    }
    # 1 回の git ls-tree で pages と raw を抽出 (重複呼び出しの排除)
    if ls_out=$(git ls-tree -r --name-only "$wiki_branch" 2>"${ls_err:-/dev/null}"); then
      pages_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/pages/(patterns|heuristics|anti-patterns)/[^/]+\.md$' || true)
      raw_list=$(printf '%s\n' "$ls_out" | grep -E '^\.rite/wiki/raw/(reviews|retrospectives|fixes)/[^/]+\.md$' || true)
    else
      rc=$?
      echo "WARNING: git ls-tree '$wiki_branch' に失敗しました (rc=$rc)" >&2
      [ -n "$ls_err" ] && [ -s "$ls_err" ] && head -3 "$ls_err" | sed 's/^/  /' >&2
      echo "  対処: wiki ブランチが存在するか確認してください (git rev-parse --verify $wiki_branch)" >&2
      echo "  影響: 検査対象を 0 件として扱い、ステップ 9 で「検査対象なし」を表示します（非ブロッキング）" >&2
    fi
    ;;
  same_branch)
    [ -d ".rite/wiki/pages" ] && pages_list=$(find .rite/wiki/pages -type f -name '*.md' 2>/dev/null || true)
    [ -d ".rite/wiki/raw" ]   && raw_list=$(find .rite/wiki/raw -type f -name '*.md' 2>/dev/null || true)
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 2.2)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    echo "  本エラーは設定ミスを silent に通過させないための fail-fast です（ステップ 2.2 / 6.0 / 6.2 / 8.2 / 8.3 で同型）" >&2
    exit 1
    ;;
esac

[ -n "$ls_err" ] && rm -f "$ls_err"

# stdout 構造: pages_list 行 → "---" separator → raw_list 行 の 3 部構成
# 空文字列ガード: 旧 `printf '%s\n' ""` は blank line 1 行を emit するため、ステップ 6.2 が
# 「pages_list=1 件 (空文字列)」と誤解釈する余地があった。`[ -n ... ] && printf` で空時は何も emit しない。
[ -n "$pages_list" ] && printf '%s\n' "$pages_list"
echo "---"
[ -n "$raw_list" ] && printf '%s\n' "$raw_list"
```

LLM は stdout から `pages_list` と `raw_list` を会話コンテキストに保持する。両方空ならステップ 3-7 を skip し ステップ 9 に進む (検出結果なしの完了レポート)。

`index.md` の読み込みは ステップ 5 の `wiki-lint-orphans.sh` が内包する (孤児検出でのみ使用するため、本ステップでの事前読出は不要)。

---

## ステップ 3: 矛盾検出

### 3.1 ページ frontmatter とタイトル・ドメインの抽出

ステップ 2.2 で収集した各ページについて、`git show` または `cat` で本文を取得し、以下のフィールドを抽出する:

| フィールド | 抽出元 | 用途 |
|-----------|--------|------|
| `title` | YAML frontmatter | タイトル衝突検出 |
| `domain` | YAML frontmatter | ドメイン単位での比較 |
| `updated` | YAML frontmatter | ステップ 4（陳腐化）で使用 |
| `confidence` | YAML frontmatter | 矛盾判定の優先度 |
| 本文（概要・詳細） | frontmatter 除外後 | 方針逆転・重複情報の検出 |

### 3.2 矛盾の判定

LLM が `pages_list` の全ページペアを意味的に比較し、以下の観点で矛盾を検出する:

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

矛盾を検出したら `issues[]` に append し `n_contradictions` を +1 する:

```
{
  "category": "contradiction",
  "page_a": ".rite/wiki/pages/patterns/error-handling.md",
  "page_b": ".rite/wiki/pages/anti-patterns/error-silent.md",
  "detail": "方針逆転: Page A は try-catch ラップを推奨、Page B は同パターンを anti-pattern として記載",
  "subcategory": "方針逆転"
}
```

`subcategory` は `タイトル衝突` / `方針逆転` / `重複情報` のいずれかを使用する（ステップ 9 の表示で使用）。

---

## ステップ 4: 陳腐化検出

検出本体は `wiki-lint-stale.sh` に委譲する。helper は全ページの frontmatter `updated` を cutoff (`now - stale_days`) と比較し、件数 + stale 集合を marker block で emit する。GNU date 事前検査 (macOS/BSD 非互換 skip) も helper が内包する。

> **Reference**: canonical 実装は `plugins/rite/hooks/scripts/wiki-lint-stale.sh`。helper は GNU date 検査・branch_strategy 別のページ読出 (`git show`(separate_branch) / `cat`(same_branch))・`updated` frontmatter 抽出・date パース失敗の WARNING skip・marker block / `stale_check_ok` enum / `[CONTEXT]` sentinel 出力をすべて内包する (旧 GNU date 事前検査 + 陳腐化検出 inline 実装を委譲)。placeholder residue gate も helper 内で実行される。state machine 契約 (marker block + enum) は `references/bash-cross-boundary-state-transfer.md` の Pattern 1/2 を参照。

**Bash tool 呼び出し境界での state 伝達**: ステップ 1.1 の `branch_strategy` / `wiki_branch` は helper の `--branch-strategy` / `--wiki-branch` arg、ステップ 1.4 の `stale_days` は `--stale-days` arg に literal substitute する。`pages_list` は stdin (HEREDOC、single-quoted delimiter) で渡す (ステップ 6.2 の `wiki-lint-source-refs.sh` 呼び出しと同じ契約)。

**`{pages_list}` substitute 契約**: ステップ 2.2 stdout の **pages_list ブロックのみ** (separator `---` より前の `.rite/wiki/pages/...` 行のみ) を substitute する。空 HEREDOC は Wiki 初期化直後 / 0 件で legitimate (`n_stale=0` が emit される)。

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/wiki-lint-stale.sh" ]; then
  # helper 不在: LLM が手動カウントに fallback すると「走らせたフリ」経路が復活するため、
  # 件数は 0 のまま skipped enum を明示出力し、ステップ 9.1 で skip note を展開する。
  echo "WARNING: wiki-lint-stale.sh が見つからないため陳腐化検出を skip します (plugin_root='${plugin_root:-<empty>}')" >&2
  echo "  対処: rite プラグインのソースツリーから実行するか、.rite-plugin-root を確認してください" >&2
  echo "n_stale=0"
  echo "---stale_pages_begin---"
  echo "---stale_pages_end---"
  echo "stale_check_ok=skipped_helper_missing"
else
  bash "$plugin_root/hooks/scripts/wiki-lint-stale.sh" \
    --branch-strategy "{branch_strategy}" \
    --wiki-branch "{wiki_branch}" \
    --stale-days "{stale_days}" <<'PAGES_LIST_EOF'
{pages_list}
PAGES_LIST_EOF
fi
```

**検出結果の記録**: LLM は stdout の `n_stale=` 値を転記し、`---stale_pages_begin---` / `---stale_pages_end---` 間の各行 (`{page}|{updated}|{days_since_update}` 形式) を `issues[]` に append する:

```
{
  "category": "stale",
  "page": ".rite/wiki/pages/heuristics/old-pattern.md",
  "updated": "2025-09-01T10:00:00+09:00",
  "days_since_update": 223,
  "detail": "90 日以上更新なし（223 日前）"
}
```

**`stale_check_ok` enum**: `true` (通常実行) / `skipped_no_gnu_date` (GNU date 非互換環境、`n_stale=0` のまま継続) / `skipped_helper_missing` (上記 fallback)。`true` 以外はステップ 9.1 で skip note を表示する。marker block 未受信 (bash block 途中異常終了) も skip note 対象として同様に扱う。

---

## ステップ 5: 孤児ページ検出

検出本体は `wiki-lint-orphans.sh` に委譲する。helper は index.md を branch_strategy 別に読み出し、OKF 箇条書き（`* [title](pages/...) - desc`）の登録ページと `pages_list` の集合差分を marker block で emit する。登録ページの抽出は `](pages/...)` リンクの grep ベース（テーブルか箇条書きかに非依存）なので、Issue #1519 の index 箇条書き化後も無改修で機能する（リンク先 `pages/{domain}/{slug}.md` を維持する条件）。

> **Reference**: canonical 実装は `plugins/rite/hooks/scripts/wiki-lint-orphans.sh`。helper は index.md 読出 (`git show`(separate_branch) / `cat`(same_branch))・登録ページ抽出 (`](pages/...)` リンクの `./pages/` / `../pages/` 形式対応の緩和 regex + `sort -u`、テーブル／箇条書き両形式で機能)・`.rite/wiki/` プレフィックス正規化・集合差分・読出失敗 / 抽出 0 件の skip 判定 (全ページ orphan 誤検出防止)・marker block / `orphan_check_ok` enum / `[CONTEXT]` sentinel 出力をすべて内包する (旧 index.md 事前読出 + 孤児検出 inline 実装を委譲)。placeholder residue gate も helper 内で実行される。

**Bash tool 呼び出し境界での state 伝達**: `branch_strategy` / `wiki_branch` は helper の arg、`pages_list` は stdin (HEREDOC) で渡す。substitute 契約はステップ 4 と同一 (pages_list ブロックのみ)。

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/wiki-lint-orphans.sh" ]; then
  echo "WARNING: wiki-lint-orphans.sh が見つからないため孤児ページ検出を skip します (plugin_root='${plugin_root:-<empty>}')" >&2
  echo "  対処: rite プラグインのソースツリーから実行するか、.rite-plugin-root を確認してください" >&2
  echo "n_orphans=0"
  echo "---orphans_begin---"
  echo "---orphans_end---"
  echo "orphan_check_ok=skipped_helper_missing"
else
  bash "$plugin_root/hooks/scripts/wiki-lint-orphans.sh" \
    --branch-strategy "{branch_strategy}" \
    --wiki-branch "{wiki_branch}" <<'PAGES_LIST_EOF'
{pages_list}
PAGES_LIST_EOF
fi
```

**検出結果の記録**: LLM は stdout の `n_orphans=` 値を転記し、`---orphans_begin---` / `---orphans_end---` 間の各行を `issues[]` に append する:

```
{
  "category": "orphan",
  "page": ".rite/wiki/pages/patterns/new-page.md",
  "detail": "index.md の OKF 箇条書き（* [title](pages/...) - desc）に未登録"
}
```

**`orphan_check_ok` enum**: `true` (通常実行) / `index_unreadable` (index.md 読出失敗、`n_orphans=0` のまま継続) / `index_empty` (登録ページ抽出 0 件、全ページ orphan 誤検出防止の skip) / `skipped_helper_missing` (上記 fallback)。`true` 以外はステップ 9.1 で skip note を表示する。marker block 未受信も同様に扱う。

---

## ステップ 6: 欠落概念検出

ステップ 6 は検出結果を 2 カテゴリに分ける:

- **`missing_concept`**: `ingested: true` の raw source のうち、対応ページも `sources.ref` 登録も `ingest_status: skipped` 記録（raw frontmatter）も存在しない真の欠落。`n_warnings` に加算（ブロッキング相当）
- **`unregistered_raw`**: `ingested: true` で `sources.ref` 未登録だが raw frontmatter に `ingest_status: skipped` 記録がある raw source。意図的に経験則化しなかった informational 指標（`n_warnings` 不加算）

### 6.0 skip 済み raw source の集合構築

ステップ 6.2 で参照する `skipped_refs` 集合の構築 (ステップ 6.2 の `all_source_refs` と対称な marker block + `log_read_ok` 4 値 enum) は `wiki-lint-skipped-refs.sh` に委譲する。Issue #1520 (Sub-3) で skip SoT が log.md から raw frontmatter (`ingest_status: skipped`) へ移行したため、helper は log.md ではなく **raw frontmatter を走査**する。

> **Reference**: 集合構築の canonical 実装は `plugins/rite/hooks/scripts/wiki-lint-skipped-refs.sh`。helper は `branch_strategy` 別の raw 走査 (`git ls-tree` + `git show`(separate_branch) / `find` + `cat`(same_branch)) で `.rite/wiki/raw/**/*.md` の frontmatter を読み、`ingest_status: skipped` を持つ raw を `raw/{type}/{filename}` 形式で抽出する・**legitimate absence** (raw ディレクトリ不在) と**真の IO error** (permission / 破損 / wiki_branch race) の `LC_ALL=C` 固定 stderr pattern 判別・`sort -u` 重複排除・列挙失敗時の io_error 降格・marker block / `log_read_ok` 4 値 enum 出力 (enum 名は stdout 契約のため据え置き、値は raw 走査状態を表す)・signal-specific trap cleanup をすべて内包する。`ingest_status` 欠落 raw は skipped でないものとして permissive に扱う (AC-6 後方互換)。placeholder residue gate も helper 内で実行される。state machine 契約 (marker block + 4 値 enum) は `references/bash-cross-boundary-state-transfer.md` の Pattern 1/2 を参照。

**Bash tool 呼び出し境界での state 伝達**: ステップ 1.1 の `branch_strategy` / `wiki_branch` は別 Bash tool 呼び出しで定義されているため、Claude は会話コンテキストから helper の `--branch-strategy` / `--wiki-branch` arg に literal substitute する (ステップ 6.2 の `wiki-lint-source-refs.sh` 呼び出しと同じ契約)。

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/wiki-lint-skipped-refs.sh" ]; then
  # helper 不在: skipped_refs を io_error 扱いにして ステップ 9.1 の false positive note を展開する。
  # silent 空集合だと skip 済み raw が missing_concept に誤計上されるため、
  # 「marker 未受信 → io_error 同等扱い」契約 (ステップ 6.2 末尾) と整合する形で io_error を明示出力する。
  echo "WARNING: wiki-lint-skipped-refs.sh が見つからないため skipped_refs を io_error 扱いにします (plugin_root='${plugin_root:-<empty>}')" >&2
  echo "  対処: rite プラグインのソースツリーから実行するか、.rite-plugin-root を確認してください" >&2
  echo "skipped_refs_count=0"
  echo "---skipped_refs_begin---"
  echo "---skipped_refs_end---"
  echo "log_read_ok=io_error"
else
  # branch_strategy / wiki_branch は arg。placeholder residue gate は helper 内で実行される。
  bash "$plugin_root/hooks/scripts/wiki-lint-skipped-refs.sh" \
    --branch-strategy "{branch_strategy}" \
    --wiki-branch "{wiki_branch}"
fi
```

**`log_read_ok` 4 値 enum による状態伝達**: bash 変数は Bash tool 呼び出し境界を超えて失われるため、`log_read_ok` を stdout に `log_read_ok={value}` 形式で出力する。Issue #1520 (Sub-3) で skip SoT が log.md から raw frontmatter (`ingest_status: skipped`) へ移行したため、本 enum は **raw frontmatter 走査の状態**を表す (enum 名は lint.md の stdout 契約のため据え置き):

| 値 | 意味 | ステップ 9.1 完了レポートでの扱い |
|----|------|---------------------------------|
| `unknown` | 初期値 (branch_strategy fail-fast で後段未到達のときのみ残る) | 表示しない (後段未実行) |
| `true` | raw frontmatter 走査成功 (skip 集合は信頼できる) | 通常表示 (false positive なし) |
| `absent` | raw 走査対象の正当な不在 (same_branch: raw ディレクトリ不在 / separate_branch: wiki branch ref 不在) — 空集合は妥当 | 通常表示 (skip 記録なしは妥当) |
| `io_error` | raw ディレクトリ列挙失敗 (permission / 破損 / race) | ⚠️ note 表示「raw frontmatter 走査失敗により `missing_concept` 件数に false positive を含む可能性あり」 |

**LLM による集合保持の契約**: 上記 bash block の stdout に `---skipped_refs_begin---` / `---skipped_refs_end---` で挟まれた行を LLM が会話コンテキストに保持し、ステップ 6.2 の (b) 分岐判定材料とする。0 件でも begin/end marker は必ず出力される (集合構築ステップが実行されたことの positive confirmation)。

### 6.1 Ingest 済み Raw Source の列挙

ステップ 2.2 で収集した `raw_list` から、frontmatter の `ingested: true` を持つファイルを抽出する。`ingested` フィールド不在は `false` 扱い (未統合) として明示する:

```bash
# 各 raw_file について:
raw_content=$(git show "${wiki_branch}:$raw_file" 2>/dev/null || cat "$raw_file" 2>/dev/null)

ingested=$(printf '%s' "$raw_content" | awk '/^ingested:/ { gsub(/^ingested:[[:space:]]*"?|"$/, ""); print; exit }')
ingested="${ingested:-false}"  # 未設定は false 扱い

raw_title=$(printf '%s' "$raw_content" | awk '/^title:/ { gsub(/^title:[[:space:]]*"?|"$/, ""); print; exit }')

if [ "$ingested" = "true" ]; then
  # ステップ 6.2 の対応ページ確認へ
  :
fi
```

### 6.2 対応ページの存在確認と 3 分岐

`raw_list` のパスは `.rite/wiki/` プレフィックス付き (例: `.rite/wiki/raw/reviews/20260410T...md`) で取得されているため、`sources[].ref` および ステップ 6.0 の `skipped_refs` と比較する前に両辺から `.rite/wiki/` を除去して `raw/{type}/{filename}` 形式に正規化する:

1. `pages_list` の各 Wiki ページ本文を取得し、frontmatter `sources[].ref` を抽出して `all_source_refs` 集合を保持する (step 3(a) で参照される)
2. `raw_list` の各 Raw Source について `.rite/wiki/` プレフィックスを除去した相対パスを計算
3. 相対パスを以下の優先順で 3 分岐する:
   - **(a) 登録済み**: step 1 の `all_source_refs` のいずれかに含まれる → 何もしない (健全)
   - **(b) 未登録だが skip 記録あり**: ステップ 6.0 の `skipped_refs` 集合に含まれる → ステップ 6.3 の `unregistered_raw` として記録
   - **(c) 真の欠落**: 上記いずれにも該当しない → LLM が Raw Source 本文を読み経験則として価値がある内容か判定した上で ステップ 6.3 の `missing_concept` として記録 (単なるエラーログや空コメントは除外)

**`all_source_refs` の集合構築** (ステップ 6.0 の `skipped_refs` と対称な marker block + io_error 3 値 enum) は `wiki-lint-source-refs.sh` に委譲する。

> **Reference**: 集合構築の canonical 実装は `plugins/rite/hooks/scripts/wiki-lint-source-refs.sh`。helper は per-page の `git show`(separate_branch) / `cat`(same_branch) 読出・`sources[].ref` 抽出 (legacy 単行形式 `- ref:` と canonical multi-line 形式 ` ref:` の両対応)・legitimate absence と真の io_error の `LC_ALL=C` 固定 stderr pattern 判別・`sort -u` 重複排除・marker block / read_ok enum 出力・signal-specific trap cleanup をすべて内包する (旧 ~240 行 inline 実装を委譲)。placeholder residue gate / partial pollution gate も helper 内に移設済み。state machine 契約 (marker block + io_error 3 値 enum) は `references/bash-cross-boundary-state-transfer.md` の Pattern 1/2 を参照。

**Bash tool 呼び出し境界での state 伝達**: ステップ 1.1 の `branch_strategy` / `wiki_branch` と ステップ 2.2 の `pages_list` は別 Bash tool 呼び出しで定義されているため、Claude は会話コンテキストから literal substitute する。`branch_strategy` / `wiki_branch` は helper の `--branch-strategy` / `--wiki-branch` arg、`pages_list` は stdin (HEREDOC、single-quoted delimiter で shell expansion 抑制) で渡す。

**`{pages_list}` substitute 契約**: ステップ 2.2 stdout は「pages_list 行 → '---' separator → raw_list 行」の 3 部構成。LLM は **pages_list ブロックのみ** (separator より前の `.rite/wiki/pages/...` 行のみ) を HEREDOC に substitute する。`.rite/wiki/raw/...` 行を含めると helper の partial pollution gate が fail-fast (exit 1) する (旧 silent missing_concept 誤分類の再発防止契約)。空 HEREDOC は Wiki 初期化直後 / 0 件で legitimate。

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/wiki-lint-source-refs.sh" ]; then
  # helper 不在: all_source_refs を io_error 扱いにして ステップ 9.1 の false positive note を展開する。
  # silent 空集合だと真の欠落 (missing_concept) 判定が false positive になるため、
  # 「marker 未受信 → io_error 同等扱い」契約 (本節末尾) と整合する形で io_error を明示出力する。
  echo "WARNING: wiki-lint-source-refs.sh が見つからないため all_source_refs を io_error 扱いにします (plugin_root='${plugin_root:-<empty>}')" >&2
  echo "  対処: rite プラグインのソースツリーから実行するか、.rite-plugin-root を確認してください" >&2
  echo "---all_source_refs_begin---"
  echo "---all_source_refs_end---"
  echo "all_source_refs_read_ok=io_error"
  echo "all_source_refs_read_errors=0"
else
  # branch_strategy / wiki_branch は arg、pages_list は stdin。
  # placeholder residue gate / partial pollution gate は helper 内で実行される。
  bash "$plugin_root/hooks/scripts/wiki-lint-source-refs.sh" \
    --branch-strategy "{branch_strategy}" \
    --wiki-branch "{wiki_branch}" <<'PAGES_LIST_EOF'
{pages_list}
PAGES_LIST_EOF
fi
```

**`skipped_refs` 集合の参照方法**: ステップ 6.0 の bash block 終了後、LLM は stdout から `---skipped_refs_begin---` と `---skipped_refs_end---` で囲まれた行を抽出して会話コンテキストに集合として保持する。ファイルパスの比較は両辺を `raw/{type}/{filename}` 形式に正規化してから完全一致で判定する。

**marker block 未受信時の fallback** (silent false positive 防止): step 3 の 3 分岐は LLM が stdout の marker block を会話コンテキストに保持する契約に依存する。bash block が途中異常終了 (SIGPIPE / OOM / 構文 error / LLM context truncation) で marker block 自体を受信できなかった場合、当該集合を「空」と同視してはならない:

- `---skipped_refs_begin---` / `---skipped_refs_end---` のいずれかが欠落 → `log_read_ok="io_error"` と同等扱い、ステップ 9.1 の false positive note を展開
- `---all_source_refs_begin---` / `---all_source_refs_end---` のいずれかが欠落 → `all_source_refs_read_ok="io_error"` と同等扱い、ステップ 9.1 の false positive note を展開

### 6.3 検出結果の記録

**真の欠落 (missing_concept)**:

```
{
  "category": "missing_concept",
  "raw_source": ".rite/wiki/raw/reviews/20260410T...md",
  "title": "PR #123 review findings",
  "detail": "Ingest 済みだが対応ページも ingest_status: skipped 記録（raw frontmatter）も存在しない"
}
```

`n_missing_concept` を +1。

**未登録 raw (unregistered_raw)**:

```
{
  "category": "unregistered_raw",
  "raw_source": ".rite/wiki/raw/reviews/20260417T...md",
  "title": "Final mergeable check after fix retries",
  "detail": "skip 済みで経験則化されなかった raw（raw frontmatter に ingest_status: skipped）"
}
```

`n_unregistered_raw` を +1 (`n_warnings` には加算されない informational カウンタ)。

---

## ステップ 7: 壊れた相互参照検出

検出本体は `wiki-lint-broken-refs.sh` に委譲する。helper は各ページ本文から Markdown リンクを抽出し、ページディレクトリ起点の `realpath -m -s` 解決で実在確認した結果を marker block で emit する。

> **Reference**: canonical 実装は `plugins/rite/hooks/scripts/wiki-lint-broken-refs.sh`。解決規約 (page_dir 起点 / `realpath -m -s` / 文字列マッチ禁止) と edge case は [Broken Reference Resolution](./references/broken-ref-resolution.md) を参照。helper は branch_strategy 別のページ読出・リンク抽出 (コードフェンス除去は awk による indent 不問の開閉トラッキングで、旧 `sed '/^```/,/^```/d'` の行頭限定の限界を解消。インライン code span 内の説明的リンク引用も除去)・画像リンク / 絶対パス / 外部 URL / アンカーのみの除外・`pages_list` / `raw_list` 突合・marker block / `broken_refs_read_ok` enum / `[CONTEXT]` sentinel 出力をすべて内包する (旧 7.1/7.2 inline 実装を委譲)。placeholder residue gate も helper 内で実行される。

**Bash tool 呼び出し境界での state 伝達**: `branch_strategy` / `wiki_branch` は helper の arg。stdin には ステップ 2.2 stdout の **3 部構成をそのまま** (pages_list 行 → `---` separator → raw_list 行) substitute する (raw_list は `raw/...` 参照リンクの突合に使用するため、ステップ 4/5 と異なり separator 以降も含める)。

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/wiki-lint-broken-refs.sh" ]; then
  echo "WARNING: wiki-lint-broken-refs.sh が見つからないため壊れた相互参照検出を skip します (plugin_root='${plugin_root:-<empty>}')" >&2
  echo "  対処: rite プラグインのソースツリーから実行するか、.rite-plugin-root を確認してください" >&2
  echo "n_broken_refs=0"
  echo "---broken_refs_begin---"
  echo "---broken_refs_end---"
  echo "broken_refs_read_ok=skipped_helper_missing"
else
  bash "$plugin_root/hooks/scripts/wiki-lint-broken-refs.sh" \
    --branch-strategy "{branch_strategy}" \
    --wiki-branch "{wiki_branch}" <<'LISTS_EOF'
{pages_list}
---
{raw_list}
LISTS_EOF
fi
```

**検出結果の記録**: LLM は stdout の `n_broken_refs=` 値を転記し、`---broken_refs_begin---` / `---broken_refs_end---` 間の各行 (`{page}|{link}` 形式) を `issues[]` に append する:

```
{
  "category": "broken_ref",
  "page": ".rite/wiki/pages/heuristics/pattern-a.md",
  "link": "../patterns/deleted-page.md",
  "detail": "リンク先ファイルが存在しない"
}
```

**`broken_refs_read_ok` enum**: `true` (全ページ読出成功) / `io_error` (1 件以上のページ読出失敗 — 未検査リンクによる false negative の可能性あり、ステップ 9.1 で note 表示) / `skipped_helper_missing` (上記 fallback)。marker block 未受信も `io_error` 同等に扱う。

**URL 内の `)` を含むリンク**: `[^)]+` regex では検出対象外とする既知の限界。実運用では Wiki 内で括弧付き URL を使わない規約で回避。

---

## ステップ 7.5: 説明的番号参照検出 (informational)

Wiki ページ本文に残った**説明目的の Issue/PR 番号参照**を検出する。Wiki は番号の受け皿ではなく経験則を Why 散文で残す場であり（Comment Best Practices SoT の[適用スコープ](../../skills/rite-workflow/references/comment-best-practices.md#適用スコープ)が Wiki ページを含む）、本文に「PR #N は…を統一した」「Issue #N 系譜の継続」「詳細は #N 参照」「(refs #N)」等が残っていれば finding として surface する。括弧やキーワードに包まれない裸の `PR #N` / `Issue #N` も対象で、これは SoT §C Detection Heuristics が reviewer 側 regex として既に宣言している範囲に機構を追随させたもの。[廃止判定ルール](../../skills/rite-workflow/references/comment-best-practices.md#廃止判定ルール-説明的参照-vs-前方ポインタ)に従い、TODO/FIXME 追跡番号は検出除外する。

**検出対象と除外**:
- 対象: ステップ 2 で収集した `pages_list` の各ページ**本文**
- 除外: frontmatter（`sources:` / `ref:` は番号ではなく provenance のため維持）、`## ソース` 節（provenance リンクラベル。維持対象）、コードフェンス / インラインコードスパン（literal 引用）、TODO/FIXME を含む行（前方追跡ポインタ）

検出は 2 規則の**正規化**で表現する（表層形の列挙ではない）。R1 は「参照キーワードが番号の直前に来る」形で、括弧付き `(refs #N)` / `see PR #N` / 裸の `PR #N は…` はすべてこの 1 規則に畳まれる。R2 はキーワードを持たない日本語 2 構文（`#N で対応` / `詳細は #N`）。キーワードを伴わない裸の `#N` は正当な文脈が多すぎるため検出しない。語境界は `([^0-9]|$)` で表現する（gawk の `\b` はバックスペース扱いで never-match になるため使用禁止）。各除外の判断根拠と副作用（その範囲内では既知の再発が見えなくなる）は helper 冒頭コメントに記録している。

**検出ロジック**は `wiki-lint-descriptive-refs.sh` に委譲する（ステップ 6.0 / 6.2 helper と同じ stdin `pages_list` + marker block + read_ok enum 契約）。

> **Reference**: canonical 実装は `plugins/rite/hooks/scripts/wiki-lint-descriptive-refs.sh`。helper は per-page の `git show`(separate_branch) / `cat`(same_branch) 読出・本文抽出フィルタ（frontmatter / `## ソース` 節 / コードフェンス / コードスパン / TODO・FIXME）・2 規則の検出・placeholder residue gate / partial pollution gate をすべて内包する。

**Bash tool 呼び出し境界での state 伝達**: ステップ 1.1 の `branch_strategy` / `wiki_branch` は helper の `--branch-strategy` / `--wiki-branch` arg、ステップ 2.2 の `pages_list` は stdin (HEREDOC、single-quoted delimiter) で渡す（ステップ 6.2 の `wiki-lint-source-refs.sh` 呼び出しと同じ契約）。

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/wiki-lint-descriptive-refs.sh" ]; then
  # helper 不在 (marketplace install で scripts/ を持たない等): informational 指標のため
  # 0 件で縮退し lint 本体は継続する。ステップ 6.0 / 6.2 の集合構築と違い、本指標は
  # 他の判定の入力にならないため io_error 扱いにする必要がない。
  echo "WARNING: wiki-lint-descriptive-refs.sh が見つからないため説明的番号参照検出をスキップします (plugin_root='${plugin_root:-<empty>}')" >&2
  echo "---descriptive_refs_begin---"
  echo "---descriptive_refs_end---"
  echo "descriptive_refs_pages=0"
  echo "[CONTEXT] WIKI_DESCRIPTIVE_REFS=0"
  echo "descriptive_refs_read_ok=skipped_helper_missing"
else
  bash "$plugin_root/hooks/scripts/wiki-lint-descriptive-refs.sh" \
    --branch-strategy "{branch_strategy}" --wiki-branch "{wiki_branch}" <<'PAGES_LIST_EOF'
{pages_list}
PAGES_LIST_EOF
fi
```

**`descriptive_refs_read_ok` enum**: `true`（全ページ読出成功）/ `io_error`（ページが存在するのに全件読出失敗 — 0 件が実体を反映していない）/ `skipped_helper_missing`（上記 fallback）。`io_error` / `skipped_helper_missing` のときステップ 9 完了レポートの該当行に「実測されていない」旨を併記する。

**扱い**: `n_descriptive_refs` は **informational 指標**（`unregistered_raw` と同様に `n_warnings` に加算しない）。canonical な `Lint: contradictions=...` summary 行（ステップ 9）の形式は **変更しない**（ingest 側の `^Lint: contradictions=...broken_refs=([0-9]+)$` parser 互換を維持するため）。検出結果はステップ 9 完了レポートの専用行で別途 surface する。

> **検出機構との関係**: 同じ説明的参照は `/rite:lint` Phase 3.5（generic loop の `comment-journal-check.sh`、`.rite/wiki/**/*.md` をスコープに含む）でも検出される。本ステップは `/rite:wiki-lint` 単体実行時にも Wiki ページの番号参照を可視化するための Wiki レイヤ固有のチェックである。

---

## ステップ 8: log.md 追記

### 8.1 検出結果の log.md 記録

Lint 完了後、`.rite/wiki/log.md` に OKF v0.1 予約構造（`## YYYY-MM-DD` 見出し + 散文 bullet、**新しい順** = 先頭が最新）で **append-only** にエントリを追記する。今日の日付見出し `## YYYY-MM-DD` が `# Directory Update Log` 直後（ログ先頭）に無ければ新規追加し、その見出し配下の **bullet 群末尾** に以下の 1 bullet を追加する（同日内の追記位置を ingest.md ステップ 7 と揃え、bullet 順序を実行者非依存にする。Issue #1520 で log.md はテーブルから OKF 形式へ移行）:

```
* **{lint_action}** — contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}
```

`{lint_action}` は `lint:clean` / `lint:warning`（下記判定基準・ステップ 8.1 bash の `[CONTEXT] lint_action=` emit 参照）。既存の日付見出し・bullet は改変しない（append-only）。

**`lint:clean` / `lint:warning` の判定基準** (`n_unregistered_raw` は informational で判定に含めない):

- `lint:clean`: ブロッキングカテゴリ 5 種 (`n_contradictions`, `n_stale`, `n_orphans`, `n_missing_concept`, `n_broken_refs`) **すべてが 0** の場合。`n_unregistered_raw` の値に依存しない (`n_unregistered_raw > 0` でも他 5 カテゴリが全 0 なら `lint:clean`)
- `lint:warning`: 上記 5 カテゴリのいずれか 1 つ以上が `> 0` の場合。`n_unregistered_raw` は判定から除外する

**`lint_action` 自動判定** (Pattern 1: `[CONTEXT] key=value` stdout emit、Issue #573): 上記 prose 判定基準を LLM 解釈から切り離し、bash block で機械的に決定して stdout に emit する。ステップ 8.3 の `{log_entry}` 組み立てはこの emit 値を **single source of truth** として参照する:

```bash
# ステップ 8.1 canonical lint_action decision logic (ステップ 8.3 sibling sync 契約相手)
# 本 bash block の判定ロジックは上記「`lint:clean` / `lint:warning` の判定基準」prose と一字一句同期する。
# canonical reference: references/bash-cross-boundary-state-transfer.md#pattern-1-multi-value-enum-via-key-value-stdout
set -o pipefail

n_contradictions={n_contradictions}
n_stale={n_stale}
n_orphans={n_orphans}
n_missing_concept={n_missing_concept}
n_broken_refs={n_broken_refs}
# 参考: n_unregistered_raw={n_unregistered_raw} — 判定式から意図的に除外 (informational、Issue #563)

# Placeholder residue fail-fast gate (同型 gate: ステップ 1.1 / 1.3 / 8.1 / 8.3 + helper 内 (4 / 5 / 6.0 / 6.2 / 7)): LLM が literal substitute を忘れると
# `[ "{n_contradictions}" -gt 0 ]` が rc=2 を返し、set -o pipefail のみでは検知できず else 分岐に
# 流れて `lint_action="lint:clean"` が silent emit される fail-silent regression を防ぐ。
for _n_var in n_contradictions n_stale n_orphans n_missing_concept n_broken_refs; do
  _n_val=$(eval echo \$"$_n_var")
  case "$_n_val" in
    ""|*[!0-9]*|"{"*"}")
      echo "ERROR: ステップ 8.1 の $_n_var が literal substitute されていないか非整数です (値: '$_n_val')" >&2
      echo "  LLM は ステップ 3-7 で累積したカウンタ値を非負整数の literal で置換する必要があります" >&2
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
```

### 8.2 書き込み先パスの決定

`branch_strategy` の値に応じて書き込み先パスを決定する (ステップ 2.2 / 6.0 / 6.2 / 8.2 / 8.3 で同型の case 文 + fail-fast。うち 6.0 / 6.2 は helper 内):

```bash
branch_strategy="{branch_strategy}"

case "$branch_strategy" in
  same_branch)
    log_path=".rite/wiki/log.md"
    ;;
  separate_branch)
    log_path=".rite/wiki-worktree/.rite/wiki/log.md"
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 8.2)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac
echo "log_path=$log_path"
```

### 8.3 書き込み手順

**`{log_entry}` / `{log_path}` placeholder source 契約**:

| placeholder | source | 責務 |
|-------------|--------|------|
| `{log_path}` | ステップ 8.2 bash block の `echo "log_path=$log_path"` | LLM は会話コンテキストから `log_path=` 行を grep し literal substitute |
| `{log_entry}` | **LLM が ステップ 8.1 の OKF bullet 形式から組み立てる** | LLM は ステップ 1.4 / 3-7 で蓄積された Lint カウンタ値を 6 フィールド形式 (`contradictions={n}, stale={n}, ...`) に埋め込み、`* **{lint_action}** — {6 フィールド}` の OKF bullet を生成する。**`{lint_action}` は LLM 独自判定ではなく、ステップ 8.1 bash block が emit する `[CONTEXT] lint_action=...` 行を first-match で抽出し、`=` 右辺の enum 値 (`lint:clean` / `lint:warning`) を literal 代入する**。追記時は今日の日付見出し `## YYYY-MM-DD` がログ先頭に無ければ追加し（新しい順）、その配下に bullet を append する |

**書き込み手順**:

1. Edit ツールで `{log_path}` (ステップ 8.2 で出力された値を literal substitute) に ステップ 8.1 の OKF bullet（必要なら日付見出し）を **append-only** で追加する。**注意**: シェル変数 `$log_path` は Bash ツール呼び出し境界を超えると失われ、Edit ツールはシェル変数を解釈しない。`echo "log_path=..."` 出力を会話文脈から拾って literal value で置換する
2. 以下の bash ブロックで commit + push する (`{log_entry}` は LLM が上記契約に従い ステップ 8.1 の OKF bullet 形式から生成した literal 文字列で substitute する)

```bash
# ステップ 8.3: log.md 追記後の commit
# lint.md 内で唯一 set -euo pipefail を使う phase。他 phase は set -o pipefail のみ (非ブロッキング契約のため
# stdout 空吐き出し経路を意図的に許容)。本 phase は外部 script 呼出 + commit msg placeholder gate を持つため
# set -e が必要。外部 script rc capture は separate_branch 経路の commit_out capture 直前で `set +e` する。
set -euo pipefail

# plugin_root の inline 解決 (lint.md には専用解決ステップがないため inline)
branch_strategy="{branch_strategy}"
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi' || true)
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "WARNING: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}'). log.md 追記の commit を skip します (非ブロッキング契約)" >&2
  exit 0
fi

# Claude placeholder {mode} 残留 fail-fast gate (同型 gate: ステップ 1.1 / 1.3)。#1941 wiki push
# batch/defer: --auto (ingest から呼ばれた) なら push を ingest 側の集約 push (ingest.md ステップ 8.6)
# に委ね、ここでは --commit-only で commit のみ行う。standalone 実行 (mode 空) は従来どおり commit + push
# を即座に行う (standalone lint はそれ自身で完結した 1 フローのため、集約する相手が存在しない)。
mode="{mode}"
case "$mode" in
  "{"*"}")
    echo "ERROR: ステップ 8.3 の {mode} placeholder が literal substitute されていません (値: '$mode')" >&2
    echo "  Claude は lint skill 呼び出し時の args 文字列 (--auto / 空) を literal で置換する必要があります" >&2
    exit 1
    ;;
esac
if printf '%s' "$mode" | grep -qE '(^|[[:space:]])--auto([[:space:]]|$)'; then
  auto_mode=true
else
  auto_mode=false
fi

# {log_entry} placeholder 残留検知 fail-fast gate (同型 gate: ステップ 1.1 / 1.3 / 8.1 / 8.3 + helper 内 (4 / 5 / 6.0 / 6.2 / 7))
log_entry="{log_entry}"
case "$log_entry" in
  "{"*"}")
    echo "ERROR: ステップ 8.3 の {log_entry} placeholder が literal substitute されていません (値: '$log_entry')" >&2
    echo "  対処: LLM は ステップ 8.1 の OKF bullet 形式に Lint カウンタ値を埋め込んで 6 フィールド形式の 1 行文字列を組み立て、本 bash block 冒頭の log_entry= 行を実際の値で置換する必要があります" >&2
    exit 1
    ;;
esac

commit_msg="docs(wiki): lint report — ${log_entry}"

case "$branch_strategy" in
  "{"*"}")
    echo "ERROR: ステップ 8.3 の {branch_strategy} placeholder が literal substitute されていません (値: '$branch_strategy')" >&2
    exit 1
    ;;
  separate_branch)
    # set -euo pipefail 下で commit_out=$(bash ...) が rc != 0 のとき bash が即時 exit する罠を回避。
    # set +e で囲み rc capture を保証する。2>&1 は付けない (構造化 stdout / WARNING stderr の責務分離維持)。
    set +e
    if [ "$auto_mode" = "true" ]; then
      # --auto: ingest から呼ばれている。push は ingest.md ステップ 8.6 の集約 push に委ね、
      # ここでは commit のみ行う (#1941 AC-1)。
      commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --commit-only --message "$commit_msg")
    else
      # standalone: この lint 実行自身が唯一のフローのため、従来どおり即座に commit + push する。
      commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --message "$commit_msg")
    fi
    commit_rc=$?
    set -e
    echo "$commit_out"
    # lint は非ブロッキング契約のため exit 1 はせず、すべて WARNING のみで継続する
    case "$commit_rc" in
      0) : ;;
      2) echo "[CONTEXT] WIKI_LINT_COMMIT=skipped; reason=wiki-disabled-or-no-pending" >&2 ;;
      3) echo "WARNING: wiki-worktree-commit.sh で git 操作失敗 (rc=3)。log.md 追記は非ブロッキングのため継続します" >&2 ;;
      4) echo "WARNING: wiki-worktree-commit.sh で commit landed but push 失敗 (rc=4)。次回再 push が必要 (standalone 実行時のみ到達 — --commit-only は push を行わない)" >&2 ;;
      *) echo "WARNING: wiki-worktree-commit.sh が予期しない rc=$commit_rc で失敗しました。log.md 追記は非ブロッキングのため継続します" >&2 ;;
    esac
    ;;
  same_branch)
    # signal-specific trap (canonical 4 行パターン)
    add_err=""
    commit_err=""
    _cleanup() {
      [ -n "${add_err:-}" ] && rm -f "$add_err"
      [ -n "${commit_err:-}" ] && rm -f "$commit_err"
      return 0
    }
    trap 'rc=$?; _cleanup; exit $rc' EXIT
    trap '_cleanup; exit 130' INT
    trap '_cleanup; exit 143' TERM
    trap '_cleanup; exit 129' HUP

    # mktemp 失敗時の loud WARNING (Pattern 3 規範): silent fallback では pre-commit hook /
    # gpg sign / index lock 等の根本原因が不可視になる。
    add_err=$(mktemp "${TMPDIR:-/tmp}/rite-lint-add-err-XXXXXX" 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile (add_err) の mktemp に失敗しました。git add の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: index lock / permission denied 等の根本原因が不可視になります" >&2
      add_err=""
    }
    commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-lint-commit-err-XXXXXX" 2>/dev/null) || {
      echo "WARNING: stderr 退避 tempfile (commit_err) の mktemp に失敗しました。git commit の詳細エラー情報は失われます" >&2
      echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "  影響: pre-commit hook / gpg sign / author config 失敗の根本原因が不可視になります" >&2
      commit_err=""
    }

    if ! git add .rite/wiki/log.md 2>"${add_err:-/dev/null}"; then
      echo "WARNING: git add .rite/wiki/log.md に失敗しました" >&2
      [ -n "$add_err" ] && [ -s "$add_err" ] && head -3 "$add_err" | sed 's/^/  /' >&2
      echo "  対処: index lock / permission denied / path error のいずれかを確認してください" >&2
      exit 0
    fi

    if ! git commit -m "$commit_msg" 2>"${commit_err:-/dev/null}"; then
      echo "WARNING: log.md のコミットに失敗しました" >&2
      [ -n "$commit_err" ] && [ -s "$commit_err" ] && head -3 "$commit_err" | sed 's/^/  /' >&2
      echo "  対処: pre-commit hook / gpg sign / author config / permission のいずれかを確認してください" >&2
    fi

    [ -n "$add_err" ] && rm -f "$add_err"
    [ -n "$commit_err" ] && rm -f "$commit_err"
    trap - EXIT INT TERM HUP
    ;;
  *)
    echo "ERROR: 未知の branch_strategy 値を検出しました: '$branch_strategy' (ステップ 8.3)" >&2
    echo "  対処: rite-config.yml の wiki.branch_strategy を 'separate_branch' または 'same_branch' に設定してください" >&2
    exit 1
    ;;
esac
# 非ブロッキング契約: 失敗しても exit 0 で継続
```

**書き込み失敗時**: 検出結果は既に stdout に表示済みのため、log.md 追記失敗は WARNING を出して exit 0 で継続する (非ブロッキング契約維持)。

---

## ステップ 9: 完了レポート

### 9.1 通常モードの出力

```
Wiki Lint が完了しました。

検査サマリー:
- 検査した Wiki ページ: {n_pages} 件
- 検査した Raw Source: {n_raw} 件

検出結果:
- 矛盾: {n_contradictions} 件
- 陳腐化: {n_stale} 件{stale_check_ok_note}
- 孤児ページ: {n_orphans} 件{orphan_check_ok_note}
- 欠落概念: {n_missing_concept} 件{log_read_ok_note}{all_source_refs_read_ok_note}
- 壊れた相互参照: {n_broken_refs} 件{broken_refs_read_ok_note}
- 未登録 raw（skip 済）: {n_unregistered_raw} 件（informational、`n_warnings` 不加算）
- 説明的番号参照: {n_descriptive_refs} 件（informational、`n_warnings` 不加算。ページ本文の Issue/PR/commit 番号参照。ステップ 7.5）

{log_read_ok_warning}{all_source_refs_read_ok_warning}

検出詳細:
{issues_list_formatted}

次のステップ:
- 矛盾は手動で該当ページを統合してください
- 陳腐化ページは /rite:wiki-ingest で新しい Raw Source を統合するか、手動で updated フィールドを更新してください
- 孤児ページは index.md に追加するか、不要なら削除してください
- 欠落概念は /rite:wiki-ingest で該当 Raw Source を再処理してください
- 壊れた相互参照は該当ページを手動で修正してください
- 未登録 raw（skip 済）は意図的な skip (`ingest_status: skipped`) なら放置で OK。skip 記録を取り消して経験則化したい場合は /rite:wiki-ingest で再処理してください
- 説明的番号参照は該当ページ本文の番号を削除し、背景を Why 散文へ書き換えてください（出所は frontmatter `sources.ref` で辿れます）
```

**`{n_pages}` / `{n_raw}` 展開ルール**: LLM は ステップ 2.2 bash block stdout から `pages_list` / `raw_list` を会話コンテキストに保持している。各配列の要素数（空行と `---` separator を除いた非空行の数）を数えて展開する。両 list が空の場合は `0`。

**`{n_descriptive_refs}` 展開ルール**: LLM は ステップ 7.5 bash block stdout の `[CONTEXT] WIKI_DESCRIPTIVE_REFS=` 行から値を読み取り `{n_descriptive_refs}` に展開する。ステップ 7.5 が skip された（`pages_list` 空）場合は `0`。`descriptive_refs_read_ok` が `true` 以外（`io_error` / `skipped_helper_missing`）のときは、件数に続けて「（未実測: {read_ok 値}）」を併記する — 読出失敗由来の `0` を「解消済み」と読ませないため。

**`{stale_check_ok_note}` / `{orphan_check_ok_note}` / `{broken_refs_read_ok_note}` 展開ルール**: LLM は ステップ 4 / 5 / 7 の helper stdout から `stale_check_ok=` / `orphan_check_ok=` / `broken_refs_read_ok=` を読み取り、それぞれ独立に展開する。ステップ 3-7 skip 経路 (処理対象 0 件) では空文字列:

| enum 値 | note (行末) |
|--------|------------|
| `true` | 空文字列 |
| `skipped_no_gnu_date` (stale_check_ok) | ` ⚠️ (GNU date 非互換環境のため陳腐化検出を skip)` |
| `index_unreadable` (orphan_check_ok) | ` ⚠️ (index.md 読出失敗のため孤児検出を skip)` |
| `index_empty` (orphan_check_ok) | ` ⚠️ (index.md から登録ページを抽出できず孤児検出を skip)` |
| `io_error` (broken_refs_read_ok) | ` ⚠️ (一部ページ読出失敗により false negative を含む可能性あり)` |
| `skipped_helper_missing` (3 enum 共通) | ` ⚠️ (helper script 不在のため検出を skip)` |
| marker block 未受信 | 各 enum の最も悲観的な値と同等に扱う (`skipped_helper_missing` / `io_error`) |

**`{log_read_ok_note}` / `{log_read_ok_warning}` / `{all_source_refs_read_ok_note}` / `{all_source_refs_read_ok_warning}` 展開ルール**:

LLM は ステップ 6.0 stdout から `log_read_ok={value}`、ステップ 6.2 stdout から `all_source_refs_read_ok={value}` を読み取り、それぞれ独立に展開する。ステップ 6.0 / 6.2 が実行されなかった場合 (`pages_list` と `raw_list` が両方空でステップ 3-7 が skip された経路) は両 placeholder を空文字列として展開する:

| enum 値 | `{..._note}` (行末 note) | `{..._warning}` (block warning) |
|--------|------------------------|--------------------------------|
| `true` | 空文字列 | 空文字列 |
| `absent` (log_read_ok のみ) | 空文字列 | 空文字列 |
| `io_error` (log_read_ok) | ` ⚠️ (raw frontmatter 読出失敗により false positive を含む可能性あり)` | `⚠️ raw source frontmatter 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。separate_branch なら wiki branch の \`.rite/wiki/raw/\` blob integrity (git ls-tree / git show)、same_branch なら \`.rite/wiki/raw/\` の存在 / 権限を確認して /rite:wiki-lint を再実行してください。` |
| `io_error` (all_source_refs_read_ok) | ` ⚠️ (ページ frontmatter 読出失敗により sources.ref 集合が不完全、false positive を含む可能性あり)` | `⚠️ ページ frontmatter 読出失敗: 真の欠落 (missing_concept) 件数が正確でない可能性があります。Wiki ページ格納先 (wiki branch or \`.rite/wiki/pages/\` filesystem) の integrity / 権限を確認して /rite:wiki-lint を再実行してください。` |
| `unknown` | 空文字列 (この状態では通常 ステップ 9.1 に到達しない) | 空文字列 |
| `(未 emit: ステップ 6.0 / 6.2 skip、処理対象 0 件)` | 空文字列 | 空文字列 |

**空行処理ルール (3 行ブロック原子的扱い)**: template は `{log_read_ok_warning}{all_source_refs_read_ok_warning}` を中心に 3 行ブロック (直前空行 / placeholder 行 / 直後空行) を持つ。LLM は以下のルールで 3 行すべてを原子的に展開する:

| 2 warning placeholder の合成値 | 3 行ブロックの展開 |
|-------------------------------|-------------------|
| 両方とも空文字列 (`true` / `absent`) | **3 行すべて省略** (前段「未登録 raw」行の直後に後段「検出詳細:」行を隣接させる) |
| 片方が非空 + もう片方が空文字列 | **3 行すべて展開** (空行 + 非空 warning 1 行 + 空行) |
| 両方が非空 (両 enum が `io_error`) | **3 行展開 + 2 warning の間に改行挿入** (空行 + warning + 改行 + warning + 空行) |

`{issues_list_formatted}` は `issues[]` の各要素をカテゴリ別にグループ化し、以下の形式で表示する:

```
### 矛盾
- [方針逆転] pages/patterns/x.md ↔ pages/anti-patterns/y.md
  X を使う vs X は使わない

### 陳腐化
- pages/heuristics/old.md (223 日前)

### 孤児ページ
- pages/patterns/new.md

### 欠落概念
- raw/reviews/20260410T...md

### 壊れた相互参照
- pages/heuristics/a.md → ../patterns/deleted.md

### 未登録 raw（skip 済）
- raw/reviews/20260417T...md (cycle 5 final mergeable 確認のみ)
```

### 9.2 `--auto` モードの出力

Ingest 完了直後に呼ばれる場合、出力は最小化される。`--auto` モードの stdout は次の 3 行を **この順序で** 出力する:

```
Lint: contradictions={n_contradictions}, stale={n_stale}, orphans={n_orphans}, missing_concept={n_missing_concept}, unregistered_raw={n_unregistered_raw}, broken_refs={n_broken_refs}
<!-- skill return signal: caller must continue next step -->
<!-- [lint:returned-to-caller:auto] -->
```

1. **6 フィールド 1 行** (`Lint: contradictions=N, ...`): ingest 側の `^Lint: contradictions=` regex parser 互換 (形式不変)
2. **Return signal comment** (`<!-- skill return signal: caller must continue next step -->`): caller (ingest 等) が次 step を skip しないよう active disambiguation
3. **HTML コメント sentinel** (`<!-- [lint:returned-to-caller:auto] -->`): 最終行に出力。rendered view では不可視で `grep -F '[lint:returned-to-caller:auto]'` で検出可能

検出件数が全て 0 の場合も含めて常にこの 3 行を出力する。空 stdout は ingest 側で「lint 実行失敗」として扱われる。

> **Why `returned-to-caller` (not `completed`)**: 旧 `lint:completed:auto` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、caller skill (ingest 等) の次 step を skip して turn が暗黙終了する事象が複数回再発した。`returned-to-caller` は「caller に return した = caller の次 step に進む」という semantic に置換することで、terminal vocabulary を構造的に排除する。

### 9.3 exit code

- **原則 exit 0**: 検出件数・事前チェック失敗 (下記 helper 解決失敗を除く)・ブランチ読取失敗のいずれも非ブロッキング
- **例外 (`exit 1` fail-fast)**:
  - `lib/wiki-config.sh` の source 失敗 (ステップ 1.1、`WIKI_CONFIG_HELPER_UNAVAILABLE`。設定を判定できないまま「Wiki 無効」へ倒す silent default の防止)
  - `branch_strategy` 未知値 (ステップ 2.2 / 8.2 / 8.3 + helper 内 (4 / 5 / 6.0 / 6.2 / 7) で同型。設定ミスの silent 通過防止)
  - `{mode}` placeholder 残留 (ステップ 1.1 / 1.3 / 8.3)
  - helper 委譲ステップ (4 / 5 / 6.0 / 6.2 / 7) の placeholder 残留 (`{branch_strategy}` / `{wiki_branch}` / `{stale_days}` / `{pages_list}` + 6.2 の partial pollution gate、LLM substitute 忘れによる silent 誤分類防止。各 helper 内で検知)
  - ステップ 8.1 の counter placeholder (`n_*` 5 種) 残留 / 非整数検知 (silent `lint:clean` 誤 emit 防止)
  - ステップ 8.3 の placeholder 残留 (`{log_entry}` / `{branch_strategy}` の 2 種、literal 残留 commit landed 防止)
  - GNU realpath (-m -s) 不在 (全 link silent broken 判定の防止、ステップ 7 helper 内)
- 内部 bash 構文エラー等の unrecoverable error のみ非 0 exit となる可能性あり

---

## エラーハンドリング

| エラー | 対処 | ステップ |
|--------|------|---------|
| `wiki.enabled: false` | 早期 return (`--auto` モード時は ステップ 9.2 の 3 行出力後 exit 0、それ以外は警告のみ exit 0) | ステップ 1.1 |
| `lib/wiki-config.sh` 読込失敗 (helper 不在 / 解決失敗) | **exit 1 で fail-fast** (`[CONTEXT] WIKI_CONFIG_HELPER_UNAVAILABLE=1`。設定不明のまま「Wiki 無効」へ倒す silent default の防止。plugin インストール状態を確認するか `/rite:setup` を再実行) | ステップ 1.1 |
| GNU date 非互換環境 | 陳腐化検出 skip（exit 0 + WARNING + `stale_check_ok=skipped_no_gnu_date`） | ステップ 4 (helper 内) |
| Wiki 未初期化 | `/rite:wiki-init` を案内 (`--auto` モード時は ステップ 9.2 の 3 行出力後 exit 0) | ステップ 1.3 |
| `{mode}` placeholder 残留 (各 site で同型) | **exit 1 で fail-fast** | ステップ 1.1 / 1.3 / 8.3 |
| helper 委譲ステップの placeholder 残留 (`{branch_strategy}` / `{wiki_branch}` / `{stale_days}` / `{pages_list}` + 6.2 の partial pollution) | **exit 1 で fail-fast** (silent 誤分類防止、各 helper 内で検知) | ステップ 4 / 5 / 6.0 / 6.2 / 7 |
| ステップ 8.1 の counter placeholder (`n_*` 5 種) 残留 / 非整数 | **exit 1 で fail-fast** (silent `lint:clean` 誤 emit 防止) | ステップ 8.1 |
| ステップ 8.3 の placeholder 残留 (`{log_entry}` / `{branch_strategy}` の 2 種) | **exit 1 で fail-fast** (literal 残留 commit landed 防止) | ステップ 8.3 |
| `git ls-tree` 失敗 | WARNING + `pages_list=""`/`raw_list=""` で継続（exit 0） | ステップ 2.2 |
| `branch_strategy` 未知値 (各 site で同型) | **exit 1 で fail-fast** | ステップ 2.2 / 8.2 / 8.3 + helper 内 (4 / 5 / 6.0 / 6.2 / 7) |
| `index.md` 読出失敗 | WARNING + 孤児検出 skip（exit 0 + `orphan_check_ok=index_unreadable`） | ステップ 5 (helper 内) |
| raw 走査対象の正当な不在 (same_branch: `.rite/wiki/raw/` 不在 / separate_branch: wiki branch ref 不在) | WARNING 抑制 + `skipped_refs=""` + `log_read_ok=absent`（exit 0） | ステップ 6.0 |
| raw frontmatter 読出失敗 (真の IO error) | WARNING + `skipped_refs=""` + `log_read_ok=io_error` + ステップ 9.1 で false positive note 表示（exit 0） | ステップ 6.0 |
| ls-tree / find / awk scan 失敗 | WARNING + `skipped_refs=""` で継続（exit 0） | ステップ 6.0 |
| `date -d` パース失敗 | 該当ページを skip し WARNING を stderr に出力（`n_stale` 非加算） | ステップ 4 (helper 内) |
| `grep` no-match（indexed_pages 空） | WARNING + 孤児判定 skip（`orphan_check_ok=index_empty`、全ページ orphan 誤検出防止） | ステップ 5 (helper 内) |
| ページ読出失敗 (broken-refs 走査中) | WARNING + 該当ページ skip + `broken_refs_read_ok=io_error`（false negative note 表示） | ステップ 7 (helper 内) |
| GNU realpath (-m -s) 不在 | **exit 1 で fail-fast** (全 link silent broken 判定の防止) | ステップ 7 (helper 内) |
| helper script 不在 | WARNING + 該当カテゴリ skip（`*_check_ok=skipped_helper_missing` を明示 emit、exit 0） | ステップ 4 / 5 / 7 |
| 処理対象 0 件 | ステップ 3-7 を skip し ステップ 9 で「検査対象なし」表示 | ステップ 2.2 末尾 |
| log.md 追記失敗 | WARNING + exit 0 で継続（検出結果は stdout に表示済み） | ステップ 8 |
