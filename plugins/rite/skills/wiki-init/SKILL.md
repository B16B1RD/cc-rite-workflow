---
name: wiki-init
description: |
  rite workflow の Wiki 初期化スキル: 経験則 Wiki のディレクトリ構造・テンプレート展開・
  ブランチ作成を行う。ユーザーが明示的に /rite:wiki-init で起動する。auto-activate しない。
  起動: /rite:wiki-init
argument-hint: ""
---

# /rite:wiki-init

Wiki の初期化を行います。3層ディレクトリ構造の作成、テンプレート展開、Git ブランチの設定を実行します。

> **Reference**: [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造、ブランチ管理、テンプレート展開の共通パターン

## ステップ 1: 事前チェック

### 1.1 Wiki 設定の読み取り

`rite-config.yml` から Wiki 設定を読み取ります:

```bash
# Wiki は opt-out — `wiki:` セクションや `enabled` キー未指定時のデフォルトは true
wiki_enabled=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+enabled:' | head -1 | sed 's/#.*//' \
  | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]')
wiki_enabled=$(echo "$wiki_enabled" | tr '[:upper:]' '[:lower:]')
case "$wiki_enabled" in
  false|no|0) wiki_enabled="false" ;;
  true|yes|1) wiki_enabled="true" ;;
  *)
    # opt-out default: 未指定 / 不明値は有効として扱う
    _wiki_raw="$wiki_enabled"  # 上書き前に保存 (typo 検出用)
    wiki_enabled="true"
    if [ -z "$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null | grep -E '^[[:space:]]+enabled:')" ]; then
      echo "INFO: wiki.enabled キーが rite-config.yml に見つかりません。デフォルト値 'true' (opt-out) を使用します" >&2
    elif [ -n "$_wiki_raw" ]; then
      # enabled キーは存在するが値が認識不能 (typo: ture / yse 等)
      echo "WARNING: wiki.enabled の値 '$_wiki_raw' を解釈できません。デフォルト 'true' (opt-out) を使用します。値は true/false/yes/no/1/0 のいずれかを指定してください" >&2
    fi
    unset _wiki_raw
    ;;
esac
echo "wiki_enabled=$wiki_enabled"
```

**Wiki が無効の場合**: `AskUserQuestion` で有効化を確認:
```
Wiki 機能が無効です（wiki.enabled: false）。

オプション:
- Wiki を有効化して初期化（推奨）: rite-config.yml の wiki.enabled を true に変更して続行
- キャンセル: 初期化を中止
```

「有効化」選択時は Edit ツールで `rite-config.yml` の `wiki.enabled` を `true` に変更してから続行。

### 1.2 既存 Wiki の確認とブランチ戦略の読み取り

Wiki が既に初期化済みかを判定し、ブランチ戦略の値も同時に出力します。以下の bash コードをインラインで実行してください:

```bash
wiki_branch=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_name:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
wiki_branch="${wiki_branch:-wiki}"

branch_strategy=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null \
  | grep -E '^[[:space:]]+branch_strategy:' | head -1 | sed 's/#.*//' \
  | sed 's/.*branch_strategy:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
branch_strategy="${branch_strategy:-separate_branch}"

# 変数の値を出力（後続ステップで使用）
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

初期化済みの場合は `AskUserQuestion`:

```
Wiki は既に初期化されています。

オプション:
- 再初期化（既存データをバックアップして上書き）
- キャンセル
```

「再初期化」選択時のバックアップ方法は `branch_strategy` に応じて分岐:
- `separate_branch`: `set -o pipefail && ts=$(date +%s) && mkdir -p .rite/wiki.bak.$ts && git archive "$wiki_branch" -- .rite/wiki/ | tar -x -C .rite/wiki.bak.$ts && set +o pipefail && git branch -D "$wiki_branch" && { git push origin --delete "$wiki_branch" 2>/dev/null || true; }` で wiki ブランチからデータを取得後、既存ブランチを削除（`set -o pipefail` で `git archive` 失敗時にバックアップなしでブランチ削除に進行することを防止。`|| true` は `git push origin --delete` のみに適用。`git checkout --orphan` が同名ブランチ存在時に失敗するため削除が必要）
- `same_branch`: `cp -r .rite/wiki .rite/wiki.bak.$(date +%s)` で working tree から直接コピー

**変数保持指示**: ステップ 1.2 で出力された `branch_strategy` と `wiki_branch` の値を保持し、**ステップ 1.3 以降のすべての Bash ブロック** (ステップ 1.3 / 2 / 3 / 3.5 / 3.5.1) で**リテラル値として埋め込んで**使用すること。Claude Code の Bash ツール間でシェル変数は保持されないため、各 Bash ブロックの冒頭で値をリテラルに再定義する必要がある。

### 1.3 same_branch 戦略向け .gitignore negation 自動注入

`.rite/wiki/` が `.gitignore` に追加されているため、`same_branch` 戦略ユーザーは ステップ 3.1 の `git add .rite/wiki/` が "paths are ignored" で hard fail します。本ステップは negation エントリ (`!.rite/wiki/` および `!.rite/wiki/**`) を対話的に追記し、hard fail を未然に防ぎます。

**発動条件** (すべて満たすときのみ):

| # | 条件 |
|---|------|
| 1 | ステップ 1.2 で取得した `branch_strategy == "same_branch"` |
| 2 | `.gitignore` が存在する |
| 3 | `.gitignore` に `^\.rite/wiki/[[:space:]]*$` に match する行が存在する（末尾 whitespace 許容で手動編集された `.gitignore` との衝突耐性を確保） |
| 4 | `.gitignore` に `# <<< gitignore-wiki-section-end` anchor が存在する（ステップ 1.3.3 Edit ツールが anchor を `old_string` に hardcode するため、不在の場合 hard fail する。consumer project は本 anchor を持たないため early skip + 手動追記案内へ分岐する） |

**Skip 条件** (idempotent):

- `.gitignore` に既に `^!\.rite/wiki/[[:space:]]*$` に match する行が存在する → 既に注入済みのため idempotent skip。LLM 分岐テーブル (`already_negated` 行) で `✅ .gitignore に既に negation エントリが存在します（idempotent skip）` メッセージを表示してから ステップ 2 へ進む（rebase シナリオで「既に注入済み」をユーザーに通知し信頼性を確保）。末尾 whitespace 許容

#### 1.3.1 事前検査

```bash
# ステップ 1.2 の値をリテラル埋め込み（例: branch_strategy="same_branch"）
branch_strategy="{branch_strategy}"

state="skip"
reason=""

if [ "$branch_strategy" != "same_branch" ]; then
  state="skip"
  reason="not_same_branch"
elif [ ! -f .gitignore ]; then
  state="skip"
  reason="gitignore_absent"
elif ! grep -qE '^\.rite/wiki/[[:space:]]*$' .gitignore; then
  state="skip"
  reason="rule_absent"
elif grep -qE '^!\.rite/wiki/[[:space:]]*$' .gitignore; then
  state="skip"
  reason="already_negated"
elif ! grep -qF '# <<< gitignore-wiki-section-end (anchor / F-09 対応)' .gitignore; then
  # ステップ 1.3.3 Edit ツールが hardcode する anchor が不在の場合、
  # Edit が `old_string not found` で hard fail するため、early skip + 手動追記案内に分岐する。
  # 本 anchor は rite-workflow 自己開発 repo の .gitignore の `# <<< gitignore-wiki-section-end (anchor / F-09 対応)` 行のみに存在し、consumer project には
  # distribution 経路がない (templates/ に該当 .gitignore template なし、/rite:setup ステップ 4.6 と
  # gitignore-health-check.sh どちらも anchor を inject しない)。consumer が手動で `.rite/wiki/` を
  # 追加した .gitignore は条件 1-3 を満たすが anchor を持たないため、本条件で fall-back する。
  # grep -qF (fixed-string match) を使うのは anchor コメント文字列に regex メタ文字 (括弧) が
  # 含まれるため (`(anchor / F-09 対応)`)。
  #
  # grep の検索文字列は anchor の prefix のみ (`# <<< gitignore-wiki-section-end`) ではなく、
  # ステップ 1.3.3 Edit ツールの old_string が要求する suffix 込みの exact 文字列
  # (`# <<< gitignore-wiki-section-end (anchor / F-09 対応)`) と完全一致させる。
  # consumer が anchor の suffix を独自編集 (例: `# <<< gitignore-wiki-section-end (custom note)`)
  # している場合に検出 grep は通過するが Edit が hard fail する strictness 差を防ぐためで、
  # 検出と Edit の strictness を完全一致させる (consumer の anchor fork 編集ケースもこの elif で skip される)。
  state="skip"
  reason="anchor_absent"
else
  state="prompt"
  reason="injection_needed"
fi

# 2 行に分離して emit する (F-04 対応)。
# `GITIGNORE_NEGATION_STATE=$state; reason=$reason` の 1 行 emit だと、
# bash ではセミコロンが statement 区切りとなり意味論が混乱する。分離することで、
# LLM の marker grep も後述テーブルの列挙も単一 key=value 行として扱える。
echo "GITIGNORE_NEGATION_STATE=$state"
echo "GITIGNORE_NEGATION_REASON=$reason"
```

**LLM 分岐** (Bash ツール間でシェル変数は保持されないため、上記 2 行の stdout marker を読んで分岐する):

| `GITIGNORE_NEGATION_STATE` | `GITIGNORE_NEGATION_REASON` | 次の処理 |
|---------------------------|------------------------------|---------|
| `skip` | `not_same_branch` | ステップ 2 へ（通知不要 — separate_branch 戦略は worktree 経路で .gitignore の影響を受けない） |
| `skip` | `gitignore_absent` | ステップ 2 へ（通知不要 — `.gitignore` がなければ ignore の影響も無し） |
| `skip` | `rule_absent` | ステップ 2 へ（通知不要 — `.rite/wiki/` が `.gitignore` に追加される以前のリポジトリで ignore されていない） |
| `skip` | `already_negated` | `✅ .gitignore に既に negation エントリが存在します（idempotent skip）` を表示して ステップ 2 へ |
| `skip` | `anchor_absent` | `⚠️ .gitignore に '# <<< gitignore-wiki-section-end' anchor が見つかりません。ステップ 1.3.3 の自動追記を skip します。手動で .gitignore 末尾に !.rite/wiki/ と !.rite/wiki/** を追記してください` を表示して ステップ 2 へ（ステップ 3.1 の git add で hard fail するリスクをユーザーに明示） |
| `prompt` | `injection_needed` | ステップ 1.3.2 へ進む |

#### 1.3.2 ユーザー確認

`AskUserQuestion` で次のように確認:

```
質問: same_branch 戦略を検出しました。.gitignore に negation エントリ (!.rite/wiki/ と !.rite/wiki/**) を自動追記しますか？

背景: .rite/wiki/ が .gitignore に追加されているため、same_branch 戦略では git add .rite/wiki/ が exit 1 で失敗します。negation を追記するとこの問題が解消されます。

オプション:
- negation エントリを追記（推奨）: ステップ 1.3.3 で自動追記 → ステップ 1.3.4 で verification 実行
- スキップ: 手動で追記するか、separate_branch 戦略に切り替えてください（ステップ 3.1 で hard fail する可能性あり）
- キャンセル: 初期化を中止
```

**選択肢別処理**:

| 選択肢 | 処理 |
|--------|------|
| negation エントリを追記（推奨） | ステップ 1.3.3 へ |
| スキップ | `⚠️ ステップ 3.1 の git add で失敗する可能性があります（手動で .gitignore に !.rite/wiki/ と !.rite/wiki/** を追記してください）` を表示して ステップ 2 へ |
| キャンセル | 初期化全体を中止（exit） |

#### 1.3.3 `.gitignore` への追記

Edit ツールで `.gitignore` の既存 anchor `# <<< gitignore-wiki-section-end (anchor / F-09 対応)` 行の **直後** に以下のブロックを挿入する（wiki section の直後を指定することで、関連コメントと配置を近接させる）:

```
# >>> gitignore-wiki-negation-start (same_branch 戦略用 negation 自動注入)
# 本プロジェクトは same_branch 戦略のため、.rite/wiki/ 配下を再包含する。
# verification 手順は本 .gitignore 上部の Step 1-5 コメントを参照。
!.rite/wiki/
!.rite/wiki/**
# <<< gitignore-wiki-negation-end
```

**Edit ツール呼び出しパラメータ**:

- `file_path`: `.gitignore`
- `old_string` — 以下の 1 行を exact match する（一意にマッチ）:

```
# <<< gitignore-wiki-section-end (anchor / F-09 対応)
```

- `new_string` — 以下の 7 行を literal で指定する（`old_string` の 1 行 + 改行 + negation ブロック 6 行）:

```
# <<< gitignore-wiki-section-end (anchor / F-09 対応)
# >>> gitignore-wiki-negation-start (same_branch 戦略用 negation 自動注入)
# 本プロジェクトは same_branch 戦略のため、.rite/wiki/ 配下を再包含する。
# verification 手順は本 .gitignore 上部の Step 1-5 コメントを参照。
!.rite/wiki/
!.rite/wiki/**
# <<< gitignore-wiki-negation-end
```

**注意点**:

1. 末尾改行は Edit ツールが自動付与するため new_string の末尾に付与しない
2. 提示したコードフェンス ` ``` ` は Markdown の表示用で、new_string には含めない
3. `old_string` と `new_string` の先頭行は同一文字列で、その後に 6 行の negation ブロックが続く
4. 各行の先頭インデントは 0 スペース。Markdown レンダラや Claude が参照時に余計な先頭空白を認識した場合でも、new_string では**行頭を `#` または 「!」 から直接開始する**（`  # >>> ...` のような先頭空白は含めない）

`!.rite/wiki/**` は glob を明示する防御的エントリで、単独では機能しない（parent exclusion が残るため）が、gitignore を消費する一部のツール (IDE の VCS integration 等) への defense-in-depth として推奨される（`.gitignore` 上部 Step 1 コメントと同じ根拠）。

#### 1.3.4 verification

> **Reference**: negation 注入が効いているかの検証は `plugins/rite/hooks/scripts/gitignore-health-check.sh --verify-negation` に委譲する。`git add --dry-run` を使い `git check-ignore -v` は使わない理由（rc と出力の両方が negation 成立と不在で同じ値を取り得るため決定論的判別不能）・canonical impl は同 helper の `DRIFT-CHECK ANCHOR: same_branch negation grep-qF healthy check` 節（および対の `(verify-negation copy)` 節）と `.gitignore` の `DRIFT-CHECK ANCHOR: negation verification canonical` 節を参照。

ステップ 1.3.3 の Edit が完了したら、negation override が実際に効いているかを helper で検証する。helper は probe ファイルの作成・`git add --dry-run` 検証・signal-specific trap cleanup・non-blocking 判定をすべて内包する（旧 ~110 行 inline 実装を `--verify-negation` モードへ委譲）。`plugin_root` はステップ 2.1 で解決されるが本ステップ (1.3) はそれより前にあるため、ここで前倒し解決する:

```bash
# plugin_root 解決 (ステップ 2.1 の inline one-liner を前倒し。
#  canonical: references/plugin-path-resolution.md#inline-one-liner-for-command-files)
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

if [ -z "$plugin_root" ] || [ ! -f "$plugin_root/hooks/scripts/gitignore-health-check.sh" ]; then
  # non-blocking: plugin_root 解決失敗時も verification を skip して ステップ 2 へ進行する
  # (ステップ 3.1 の git add で negation 不在ならそこで改めてエラーが出る)。
  echo "WARNING: plugin_root 解決に失敗したため negation verification を skip します (non-blocking)" >&2
  echo "  ステップ 3.1 の git add で negation が効いていなければそこで改めてエラーが出ます" >&2
else
  bash "$plugin_root/hooks/scripts/gitignore-health-check.sh" --verify-negation
fi
```

`--verify-negation` モードは post-injection 専用で、config 読込・strategy 判定・parent-exclusion check をスキップし、全分岐 non-blocking (exit 0) で結果を stdout / stderr に出す。probe の親ディレクトリ (`.rite/wiki/raw/`) は rmdir せず残すため、後続ステップ 2 のディレクトリ作成と衝突しない。

**成功時**: helper が `✅ .gitignore negation verification OK: ...` を **stdout** に出力する。続けて `✅ .gitignore に negation エントリを追記しました` を表示して ステップ 2 へ。

**失敗時 (non-blocking)**: helper が `WARNING: .gitignore negation verification failed ...` を **stderr** に出力する。WARNING 表示のみで ステップ 2 に進行する。ステップ 3.1 の `git add .rite/wiki/` で改めてエラーが出れば、そこでユーザーに手動対応を促す。

## ステップ 2: ディレクトリ構造の作成

### 2.1 Plugin Root の解決

> **Reference**: [Plugin Path Resolution](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files)

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/templates/wiki" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

**変数保持指示**: ステップ 2.1 で出力された `plugin_root` の値を保持し、以降の Bash ブロックでは**リテラル値として埋め込んで**使用すること。

### 2.2 ディレクトリ作成と `.gitkeep` 配置

`pages/{patterns,heuristics,anti-patterns}/` は初期状態ではファイルを持たないため、`.gitkeep` を配置して git tree に保持する。これがないと `/rite:wiki-ingest` が page を書き込もうとした際に親ディレクトリ不在で Write が失敗する。

```bash
mkdir -p .rite/wiki/raw/reviews
mkdir -p .rite/wiki/raw/retrospectives
mkdir -p .rite/wiki/raw/fixes
mkdir -p .rite/wiki/pages/patterns
mkdir -p .rite/wiki/pages/heuristics
mkdir -p .rite/wiki/pages/anti-patterns

# .gitkeep で空ディレクトリを tracked に保持
touch .rite/wiki/pages/patterns/.gitkeep
touch .rite/wiki/pages/heuristics/.gitkeep
touch .rite/wiki/pages/anti-patterns/.gitkeep
```

### 2.3 テンプレート展開

タイムスタンプを生成し、テンプレートのプレースホルダーを置換して展開。ステップ 2.1 で取得した `plugin_root` をリテラル値として埋め込むこと:

```bash
# ステップ 2.1 で取得した plugin_root をリテラル値として埋め込む（例: plugin_root="/home/user/plugins/rite"）
plugin_root="{plugin_root}"

initialized_at=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
# log.md の OKF 日付見出し (## YYYY-MM-DD) は日付だけを受理するため date-only 値を使う。
initialized_date=$(date -u +"%Y-%m-%d")

# SCHEMA.md（{initialized_at} プレースホルダーを含まないため単純コピー）
cp "${plugin_root}/templates/wiki/schema-template.md" .rite/wiki/SCHEMA.md

# index.md
sed "s/{initialized_at}/$initialized_at/g" \
  "${plugin_root}/templates/wiki/index-template.md" > .rite/wiki/index.md

# log.md (OKF 日付見出し {initialized_date} のみ使用、date-only。log-template.md に {initialized_at} は無い)
sed "s/{initialized_date}/$initialized_date/g" \
  "${plugin_root}/templates/wiki/log-template.md" > .rite/wiki/log.md
```

## ステップ 3: Git ブランチ設定

ステップ 1.2 で取得した `branch_strategy` と `wiki_branch` の値をリテラルに埋め込んで実行すること。

### 3.1 初期コミット (wiki-branch-init.sh へ委譲)

> **Reference**: [separate_branch 戦略のブランチ操作](../../references/wiki-patterns.md#separate_branch-戦略のブランチ操作)

ステップ 2 で展開した `.rite/wiki/` の初期コミットは `wiki-branch-init.sh` に委譲する。helper は separate_branch (orphan ブランチ作成 + push + 元ブランチ復帰、dirty tree の stash 退避/復帰、異常終了時の trap による元ブランチ復帰保証) / same_branch (現在ブランチへコミット) の両戦略と、未知 strategy の fail-fast をすべて内包する (旧 ~95 行 inline block を委譲)。

**出力契約** (旧 inline block と同一): 成功時は `✅ Wiki ブランチ '{wiki_branch}' を作成しました` (separate_branch) または `✅ Wiki を現在のブランチに初期化しました` (same_branch) を stdout 出力。失敗時は `ERROR: ...` (stderr) + exit 1 (blocking)。

```bash
# ステップ 1.2 の値と ステップ 2.1 で解決済みの plugin_root をリテラルで埋め込む
plugin_root="{plugin_root}"

bash "$plugin_root/hooks/scripts/wiki-branch-init.sh" \
  --branch-strategy "{branch_strategy}" \
  --wiki-branch "{wiki_branch}"
```

## ステップ 3.5: Wiki Worktree セットアップ

`separate_branch` 戦略の場合、ステップ 3.1 で wiki ブランチを作成した直後に `.rite/wiki-worktree/` worktree を作成します。これにより `/rite:wiki-ingest` は dev ブランチを離脱することなく wiki ブランチのツリーに Write/Edit できるようになります。

```bash
branch_strategy="{branch_strategy}"
plugin_root="{plugin_root}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # wiki-worktree-setup.sh は冪等 (既存なら no-op) で安全に呼べる
  # 注意: `if ! cmd; then rc=$?` パターンは bash 仕様上 `$?` が常に 「!」 の終了 status (= 0) を
  # 返すため、setup.sh の真の rc (1=env error / 2=disabled / 3=worktree add 失敗) を捕捉できない。
  # `set +e; cmd; rc=$?; set -e` で明示的に capture する (ingest.md ステップ 1.3 と対称)。
  set +e
  bash "$plugin_root/hooks/scripts/wiki-worktree-setup.sh"
  setup_rc=$?
  set -e
  if [ "$setup_rc" -ne 0 ]; then
    echo "WARNING: wiki-worktree-setup.sh failed (rc=$setup_rc)" >&2
    echo "  影響: /rite:wiki-ingest 実行前に手動で worktree を作成する必要があります" >&2
    echo "  手動回復: bash $plugin_root/hooks/scripts/wiki-worktree-setup.sh" >&2
    # 非ブロッキング: worktree 作成失敗は init 全体を失敗させない
  fi
fi
```

### 3.5.1 既存 wiki ブランチへの `.gitkeep` 補完 migration

`.gitkeep` の自動補完が導入される以前に init した wiki ブランチは `pages/{patterns,heuristics,anti-patterns}/.gitkeep` を持たないため、`/rite:wiki-ingest` の Write が親ディレクトリ不在で失敗します。この migration は冪等に既存 wiki ブランチに `.gitkeep` を補完します。worktree 経由で commit するため dev ブランチの HEAD は移動しません:

```bash
branch_strategy="{branch_strategy}"
plugin_root="{plugin_root}"

if [ "$branch_strategy" = "separate_branch" ] && [ -d .rite/wiki-worktree/.rite/wiki/pages ]; then
  wt_pages=".rite/wiki-worktree/.rite/wiki/pages"
  migration_needed=false
  for domain in patterns heuristics anti-patterns; do
    mkdir -p "$wt_pages/$domain"
    if [ ! -f "$wt_pages/$domain/.gitkeep" ]; then
      touch "$wt_pages/$domain/.gitkeep"
      migration_needed=true
    fi
  done

  if [ "$migration_needed" = "true" ]; then
    commit_msg="chore(wiki): migrate pages/ directories with .gitkeep"
    # 2>&1 は付けない: 構造化 stdout (committed= 行) と WARNING stderr の分離を維持する
    commit_out=$(bash "$plugin_root/hooks/scripts/wiki-worktree-commit.sh" --message "$commit_msg")
    commit_rc=$?
    echo "$commit_out"
    case "$commit_rc" in
      0) echo "✅ pages/ migration committed to wiki branch" ;;
      3)
        echo "WARNING: migration commit 内部で git 操作失敗 (rc=3)" >&2
        echo "  対処: git -C .rite/wiki-worktree status で状態を確認してください" >&2
        ;;
      4) echo "WARNING: migration commit landed locally but push failed (rc=4)" >&2 ;;
      *)
        echo "WARNING: pages/ migration commit failed (rc=$commit_rc). /rite:wiki-ingest 側でも .gitkeep が作成されないと Write 失敗する可能性あり" >&2
        ;;
    esac
  else
    echo "✅ pages/.gitkeep はすべて存在します (migration 不要)"
  fi
fi
```

## ステップ 4: 完了レポート

ステップ 1.2 で取得した `branch_strategy` と `wiki_branch` の値を以下のテンプレートに埋め込んで表示すること:

```
Wiki の初期化が完了しました。

ブランチ戦略: {branch_strategy の値}
{separate_branch の場合: Wiki ブランチ: {wiki_branch の値}}

作成されたファイル:
- .rite/wiki/SCHEMA.md (蓄積規約)
- .rite/wiki/index.md (ページカタログ)
- .rite/wiki/log.md (変更履歴ログ、OKF 形式・人間向け)
- .rite/wiki/pages/{patterns, heuristics, anti-patterns}/.gitkeep (空ディレクトリ git 追跡用)

作成されたディレクトリ:
- .rite/wiki/raw/{reviews, retrospectives, fixes}
- .rite/wiki/pages/{patterns, heuristics, anti-patterns}

{separate_branch の場合: worktree: .rite/wiki-worktree (→ wiki ブランチ)}

次のステップ:
- /rite:wiki-ingest で経験則の蓄積を開始
- /rite:wiki-query で経験則を参照
- /rite:wiki-lint で Wiki の品質チェック
```
