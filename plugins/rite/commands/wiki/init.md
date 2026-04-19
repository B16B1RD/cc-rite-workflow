---
description: Wiki の初期化（ディレクトリ構造・テンプレート展開・ブランチ作成）
---

# /rite:wiki:init

Wiki の初期化を行います。3層ディレクトリ構造の作成、テンプレート展開、Git ブランチの設定を実行します。

> **Reference**: [Wiki Patterns](../../references/wiki-patterns.md) — ディレクトリ構造、ブランチ管理、テンプレート展開の共通パターン

## Phase 1: 事前チェック

### 1.1 Wiki 設定の読み取り

`rite-config.yml` から Wiki 設定を読み取ります:

```bash
# #483: Wiki は opt-out — `wiki:` セクションや `enabled` キー未指定時のデフォルトは true
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

# 変数の値を出力（後続 Phase で使用）
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

**変数保持指示**: Phase 1.2 で出力された `branch_strategy` と `wiki_branch` の値を保持し、**Phase 1.3 以降のすべての Bash ブロック** (Phase 1.3 / 2 / 3 / 3.5 / 3.5.1) で**リテラル値として埋め込んで**使用すること。Claude Code の Bash ツール間でシェル変数は保持されないため、各 Bash ブロックの冒頭で値をリテラルに再定義する必要がある。

### 1.3 same_branch 戦略向け .gitignore negation 自動注入

PR #564 で `.rite/wiki/` が `.gitignore` に追加されたため、`same_branch` 戦略ユーザーは Phase 3.1 の `git add .rite/wiki/` が "paths are ignored" で hard fail します。本 Phase は negation エントリ (`!.rite/wiki/` および `!.rite/wiki/**`) を対話的に追記し、hard fail を未然に防ぎます。

**発動条件** (すべて満たすときのみ):

| # | 条件 |
|---|------|
| 1 | Phase 1.2 で取得した `branch_strategy == "same_branch"` |
| 2 | `.gitignore` が存在する |
| 3 | `.gitignore` に `^\.rite/wiki/[[:space:]]*$` に match する行が存在する（PR #564 以降のリポジトリ。末尾 whitespace 許容で手動編集された `.gitignore` との衝突耐性を確保） |
| 4 | `.gitignore` に `# <<< gitignore-wiki-section-end` anchor が存在する（Phase 1.3.3 Edit ツールが anchor を `old_string` に hardcode するため、不在の場合 hard fail する。consumer project は本 anchor を持たないため early skip + 手動追記案内へ分岐する） |

**Skip 条件** (idempotent):

- `.gitignore` に既に `^!\.rite/wiki/[[:space:]]*$` に match する行が存在する → 既に注入済みのため idempotent skip。LLM 分岐テーブル (`already_negated` 行) で `✅ .gitignore に既に negation エントリが存在します（idempotent skip）` メッセージを表示してから Phase 2 へ進む（rebase シナリオで「既に注入済み」をユーザーに通知し信頼性を確保）。末尾 whitespace 許容

#### 1.3.1 事前検査

```bash
# Phase 1.2 の値をリテラル埋め込み（例: branch_strategy="same_branch"）
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
  # PR #586 F-01 対応: Phase 1.3.3 Edit ツールが hardcode する anchor が不在の場合、
  # Edit が `old_string not found` で hard fail するため、early skip + 手動追記案内に分岐する。
  # 本 anchor は rite-workflow 自己開発 repo の .gitignore L131 のみに存在し、consumer project には
  # distribution 経路がない (templates/ に該当 .gitignore template なし、/rite:init Phase 4.6 と
  # gitignore-health-check.sh どちらも anchor を inject しない)。consumer が手動で `.rite/wiki/` を
  # 追加した .gitignore は条件 1-3 を満たすが anchor を持たないため、本条件で fall-back する。
  # grep -qF (fixed-string match) を使うのは anchor コメント文字列に regex メタ文字 (括弧) が
  # 含まれるため (`(anchor / F-09 対応)`)。
  #
  # PR #586 F-04 (cycle 5) 対応: cycle 4 で grep の検索文字列を anchor の prefix のみ
  # (`# <<< gitignore-wiki-section-end`) で書いていたが、Phase 1.3.3 Edit ツールの old_string は
  # suffix 込みの exact 文字列 (`# <<< gitignore-wiki-section-end (anchor / F-09 対応)`) を要求する。
  # consumer が anchor の suffix を独自編集 (例: `# <<< gitignore-wiki-section-end (custom note)`)
  # している場合、検出 grep は通過するが Edit が hard fail する strictness 差を残していた。
  # cycle 6 で grep の検索文字列を Edit と同一の exact 文字列に統一し、検出と Edit の strictness
  # を完全一致させる (consumer の anchor fork 編集ケースもこの elif で skip される)。
  state="skip"
  reason="anchor_absent"
else
  state="prompt"
  reason="injection_needed"
fi

# 2 行に分離して emit する (F-04 対応)。
# 旧実装は `GITIGNORE_NEGATION_STATE=$state; reason=$reason` の 1 行 emit だったが、
# bash としてはセミコロンが statement 区切りとなり意味論が混乱する。分離することで、
# LLM の marker grep も後述テーブルの列挙も単一 key=value 行として扱える。
echo "GITIGNORE_NEGATION_STATE=$state"
echo "GITIGNORE_NEGATION_REASON=$reason"
```

**LLM 分岐** (Bash ツール間でシェル変数は保持されないため、上記 2 行の stdout marker を読んで分岐する):

| `GITIGNORE_NEGATION_STATE` | `GITIGNORE_NEGATION_REASON` | 次の処理 |
|---------------------------|------------------------------|---------|
| `skip` | `not_same_branch` | Phase 2 へ（通知不要 — separate_branch 戦略は worktree 経路で .gitignore の影響を受けない） |
| `skip` | `gitignore_absent` | Phase 2 へ（通知不要 — `.gitignore` がなければ ignore の影響も無し） |
| `skip` | `rule_absent` | Phase 2 へ（通知不要 — PR #564 以前のリポジトリで `.rite/wiki/` が ignore されていない） |
| `skip` | `already_negated` | `✅ .gitignore に既に negation エントリが存在します（idempotent skip）` を表示して Phase 2 へ |
| `skip` | `anchor_absent` | `⚠️ .gitignore に '# <<< gitignore-wiki-section-end' anchor が見つかりません。Phase 1.3.3 の自動追記を skip します。手動で .gitignore 末尾に !.rite/wiki/ と !.rite/wiki/** を追記してください` を表示して Phase 2 へ（Phase 3.1 の git add で hard fail するリスクをユーザーに明示） |
| `prompt` | `injection_needed` | Phase 1.3.2 へ進む |

#### 1.3.2 ユーザー確認

`AskUserQuestion` で次のように確認:

```
質問: same_branch 戦略を検出しました。.gitignore に negation エントリ (!.rite/wiki/ と !.rite/wiki/**) を自動追記しますか？

背景: PR #564 で .rite/wiki/ が .gitignore に追加されたため、same_branch 戦略では git add .rite/wiki/ が exit 1 で失敗します。negation を追記するとこの問題が解消されます。

オプション:
- negation エントリを追記（推奨）: Phase 1.3.3 で自動追記 → Phase 1.3.4 で verification 実行
- スキップ: 手動で追記するか、separate_branch 戦略に切り替えてください（Phase 3.1 で hard fail する可能性あり）
- キャンセル: 初期化を中止
```

**選択肢別処理**:

| 選択肢 | 処理 |
|--------|------|
| negation エントリを追記（推奨） | Phase 1.3.3 へ |
| スキップ | `⚠️ Phase 3.1 の git add で失敗する可能性があります（手動で .gitignore に !.rite/wiki/ と !.rite/wiki/** を追記してください）` を表示して Phase 2 へ |
| キャンセル | 初期化全体を中止（exit） |

#### 1.3.3 `.gitignore` への追記

Edit ツールで `.gitignore` の既存 anchor `# <<< gitignore-wiki-section-end (anchor / F-09 対応)` 行の **直後** に以下のブロックを挿入する（PR #564 で配置された wiki section の直後を指定することで、関連コメントと配置を近接させる）:

```
# >>> gitignore-wiki-negation-start (Issue #568 — same_branch 戦略用 negation 自動注入)
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
# >>> gitignore-wiki-negation-start (Issue #568 — same_branch 戦略用 negation 自動注入)
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
4. 各行の先頭インデントは 0 スペース。Markdown レンダラや Claude が参照時に余計な先頭空白を認識した場合でも、new_string では**行頭を `#` または `!` から直接開始する**（`  # >>> ...` のような先頭空白は含めない）

`!.rite/wiki/**` は glob を明示する防御的エントリで、単独では機能しない（parent exclusion が残るため）が、gitignore を消費する一部のツール (IDE の VCS integration 等) への defense-in-depth として推奨される（`.gitignore` 上部 Step 1 コメントと同じ根拠）。

#### 1.3.4 verification

> **Reference**: `.gitignore` の `DRIFT-CHECK ANCHOR: negation verification canonical` 節（「動作確認の正典」 + `git check-ignore -v` を sanity check に使わない理由）。`git add --dry-run` を使用し、`git check-ignore -v` は使わない（rc と出力の両方が negation 成立と単純 match で同じ値を取り得るため決定論的判別不能）。canonical impl は `plugins/rite/hooks/scripts/gitignore-health-check.sh` の `DRIFT-CHECK ANCHOR: same_branch negation grep-qF healthy check` 節の `grep -qF` パターン参照。

```bash
# signal-specific trap で probe ファイルの残留を防ぐ
# (canonical: plugins/rite/commands/pr/references/bash-trap-patterns.md
#  の `#signal-specific-trap-template` anchor)。
#
# SIGINT/SIGTERM/SIGHUP で rm -f がスキップされ、Phase 3.1 の same_branch ブロックの
# `git add .rite/wiki/` に probe (.negation-probe) が混入する経路を塞ぐ。
# 関数名は上記 canonical の命名規約 `_rite_<scope>_<phase>_cleanup` に準拠。
# (Phase 3.1 の `_rite_wiki_init_cleanup` は規約確立前の旧命名維持対象。本 Phase 1.3 は
#  新規追加なので規約準拠の `_rite_wiki_init_phase13_cleanup` を採用。)
#
# canonical instantiation 順序 (re-review cycle 3 F-A 対応):
#   (1) パス変数を空文字で先行宣言
#   (2) cleanup 関数と 4 行 trap を設定
#   (3) その後で mktemp を実行
# これにより trap arm と mktemp の間に signal が到達しても、cleanup 関数が未定義変数
# を参照する経路を閉じる。
probe_mkdir_err=""
probe_touch_err=""
dry_run_err=""

_rite_wiki_init_phase13_cleanup() {
  rm -f "${probe_mkdir_err:-}" "${probe_touch_err:-}" "${dry_run_err:-}" .rite/wiki/raw/.negation-probe
}
trap 'rc=$?; _rite_wiki_init_phase13_cleanup; exit $rc' EXIT
trap '_rite_wiki_init_phase13_cleanup; exit 130' INT
trap '_rite_wiki_init_phase13_cleanup; exit 143' TERM
trap '_rite_wiki_init_phase13_cleanup; exit 129' HUP

# mkdir / touch の失敗を明示的にハンドリング + stderr を退避。
# permission/disk full/readonly 等で probe 作成失敗時、verification 自体を skip して
# WARNING を表示する (non-blocking、Phase 2 へ進行)。silent に `git add --dry-run` を
# 実行して pathspec mismatch 警告 (rc=128) を「negation 不在」と誤認することを防ぐ。
# stderr は tempfile に退避し、失敗時に head -3 で先頭行を stderr に流す
# (canonical: plugins/rite/hooks/scripts/gitignore-health-check.sh の probe 作成 +
#  stderr 退避パターン参照)。
probe_mkdir_err=$(mktemp /tmp/rite-wiki-init-p13-mkdir-err-XXXXXX 2>/dev/null) || probe_mkdir_err=""
probe_touch_err=$(mktemp /tmp/rite-wiki-init-p13-touch-err-XXXXXX 2>/dev/null) || probe_touch_err=""
probe_created="false"
if mkdir -p .rite/wiki/raw 2>"${probe_mkdir_err:-/dev/null}" && \
   touch .rite/wiki/raw/.negation-probe 2>"${probe_touch_err:-/dev/null}"; then
  probe_created="true"
else
  echo "WARNING: negation probe の作成に失敗しました (read-only fs / permission / disk full の可能性)" >&2
  if [ -n "$probe_mkdir_err" ] && [ -s "$probe_mkdir_err" ]; then
    echo "  mkdir stderr (先頭 3 行):" >&2
    head -3 "$probe_mkdir_err" | sed 's/^/    /' >&2
  fi
  if [ -n "$probe_touch_err" ] && [ -s "$probe_touch_err" ]; then
    echo "  touch stderr (先頭 3 行):" >&2
    head -3 "$probe_touch_err" | sed 's/^/    /' >&2
  fi
  echo "  verification を skip して Phase 2 に進行します (non-blocking)" >&2
  echo "  Phase 3.1 の git add で negation が効いていなければそこで改めてエラーが出ます" >&2
fi

if [ "$probe_created" = "true" ]; then
  # verification: rc=0 かつ stdout に canonical pattern `add '<path>'` (probe フルパス) を含めば OK
  # `grep -q "^add '"` (単純プレフィックス) では偶然 `add '...'` で始まる任意パスが出ると
  # false positive になるため、`grep -qF "add '<probe path 全体>'"` で完全パス fixed-string
  # match に統一する (canonical: plugins/rite/hooks/scripts/gitignore-health-check.sh の
  # `grep -qF "add '${negation_probe}'"` パターン)。
  #
  # PR #586 F-02 対応: stderr を独立 tempfile に退避し stdout に merge しない。
  # 同一ファイル内 Phase 3.5.1 のプロジェクト規約「2>&1 は付けない: 構造化 stdout と WARNING stderr
  # の分離を維持する」に準拠する。canonical 参照実装 gitignore-health-check.sh の
  # `DRIFT-CHECK ANCHOR: same_branch add_dry_run rc capture` 節の
  # `add_dry_err=$(mktemp ...) ... if add_dry_out=$(...); then add_dry_rc=0; else add_dry_rc=$?; fi`
  # パターンに **rc capture 構造ごと** 揃える (canonical drift 防止)。実害として、success path で
  # git が emit する stderr 警告 (例: `warning: in the working copy of '...', LF will be replaced
  # by CRLF`) が success メッセージに混入することを防ぎ、`grep -qF "add '...'"` の false positive
  # リスクを排除する。
  #
  # PR #586 F-01 (cycle 5) 対応: cycle 4 で stderr 退避部分のみ canonical に揃え rc capture
  # 構造を簡略な `var=$(cmd); rc=$?` に留めていたが、コメントは「一字一句揃える」と謳っており
  # 主張と実装が乖離していた。cycle 6 で if-wrapper 構造に統一して drift を解消する。
  # `set -e` 不在の bash block 内では機能等価だが、Wiki 経験則「canonical reference 文書の
  # サンプルコードは canonical 実装と一字一句同期する」(patterns/high) を厳守する。
  dry_run_err=$(mktemp /tmp/rite-wiki-init-p13-dryrun-err-XXXXXX 2>/dev/null) || dry_run_err=""
  dry_run_out=""
  dry_run_rc=0
  if dry_run_out=$(git add --dry-run -- .rite/wiki/raw/.negation-probe 2>"${dry_run_err:-/dev/null}"); then
    dry_run_rc=0
  else
    dry_run_rc=$?
  fi

  if [ "$dry_run_rc" -eq 0 ] && printf '%s' "$dry_run_out" | grep -qF "add '.rite/wiki/raw/.negation-probe'"; then
    echo "✅ .gitignore negation verification OK: $dry_run_out"
  else
    echo "WARNING: .gitignore negation verification failed (rc=$dry_run_rc)" >&2
    echo "  stdout: $dry_run_out" >&2
    if [ -n "$dry_run_err" ] && [ -s "$dry_run_err" ]; then
      echo "  stderr (先頭 3 行):" >&2
      head -3 "$dry_run_err" | sed 's/^/    /' >&2
    fi
    echo "  対処: .gitignore の .rite/wiki/ 行直後 (gitignore-wiki-section-end anchor 直後) に" >&2
    echo "        !.rite/wiki/ と !.rite/wiki/** が配置されているか確認してください" >&2
  fi
fi

# 明示 rm → trap 解除 の順序 (canonical: bash-trap-patterns.md `#signal-specific-trap-template`)。
# 役割分離:
#   - 明示 rm (通常パス): Phase 1.3.4 の処理完了時点で同期的に probe を削除。script は
#     Phase 2 以降を継続するため、EXIT trap に delegate するだけでは処理途中の cleanup
#     にならない (EXIT trap は script 終了時のみ発火する)。
#   - trap cleanup (signal 経路 defense-in-depth): SIGINT/SIGTERM/SIGHUP で明示 rm に
#     到達できなかった場合の保険として動作する。
# 明示 rm を trap 解除より前に置くことで、rm〜trap 解除間の micro-race window を排除する。
# trap 解除後は EXIT trap が発火しないため、script 終了時に冗長 rm が走らない。
rm -f "${probe_mkdir_err:-}" "${probe_touch_err:-}" "${dry_run_err:-}" .rite/wiki/raw/.negation-probe
trap - EXIT INT TERM HUP
```

**成功時**: `✅ .gitignore に negation エントリを追記しました` を追加で表示し Phase 2 へ。

**失敗時 (non-blocking)**: WARNING 表示のみで Phase 2 に進行する。Phase 3.1 の `git add .rite/wiki/` で改めてエラーが出れば、そこでユーザーに手動対応を促す。

## Phase 2: ディレクトリ構造の作成

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

**変数保持指示**: Phase 2.1 で出力された `plugin_root` の値を保持し、以降の Bash ブロックでは**リテラル値として埋め込んで**使用すること。

### 2.2 ディレクトリ作成と `.gitkeep` 配置

Issue #547 で追加: `pages/{patterns,heuristics,anti-patterns}/` は初期状態ではファイルを持たないため、`.gitkeep` を配置して git tree に保持する。これがないと `/rite:wiki:ingest` が page を書き込もうとした際に親ディレクトリ不在で Write が失敗する。

```bash
mkdir -p .rite/wiki/raw/reviews
mkdir -p .rite/wiki/raw/retrospectives
mkdir -p .rite/wiki/raw/fixes
mkdir -p .rite/wiki/pages/patterns
mkdir -p .rite/wiki/pages/heuristics
mkdir -p .rite/wiki/pages/anti-patterns

# .gitkeep で空ディレクトリを tracked に保持 (Issue #547)
touch .rite/wiki/pages/patterns/.gitkeep
touch .rite/wiki/pages/heuristics/.gitkeep
touch .rite/wiki/pages/anti-patterns/.gitkeep
```

### 2.3 テンプレート展開

タイムスタンプを生成し、テンプレートのプレースホルダーを置換して展開。Phase 2.1 で取得した `plugin_root` をリテラル値として埋め込むこと:

```bash
# Phase 2.1 で取得した plugin_root をリテラル値として埋め込む（例: plugin_root="/home/user/plugins/rite"）
plugin_root="{plugin_root}"

initialized_at=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

# SCHEMA.md（{initialized_at} プレースホルダーを含まないため単純コピー）
cp "${plugin_root}/templates/wiki/schema-template.md" .rite/wiki/SCHEMA.md

# index.md
sed "s/{initialized_at}/$initialized_at/g" \
  "${plugin_root}/templates/wiki/index-template.md" > .rite/wiki/index.md

# log.md
sed "s/{initialized_at}/$initialized_at/g" \
  "${plugin_root}/templates/wiki/log-template.md" > .rite/wiki/log.md
```

## Phase 3: Git ブランチ設定

Phase 1.2 で取得した `branch_strategy` と `wiki_branch` の値をリテラルに埋め込んで実行すること。

### 3.1 separate_branch 戦略の場合

> **Reference**: [separate_branch 戦略のブランチ操作](../../references/wiki-patterns.md#separate_branch-戦略のブランチ操作)

```bash
# Phase 1.2 の値をリテラルで埋め込む（例: branch_strategy="separate_branch", wiki_branch="wiki"）
branch_strategy="{branch_strategy}"
wiki_branch="{wiki_branch}"

if [ "$branch_strategy" = "separate_branch" ]; then
  current_branch=$(git branch --show-current)

  # cleanup trap: 異常終了時に元のブランチに復帰を保証
  # canonical signal-specific trap パターン (references/bash-trap-patterns.md 準拠)
  _rite_wiki_init_cleanup() {
    git checkout "$current_branch" 2>/dev/null || true
    if [ "${stash_needed:-false}" = true ]; then
      git stash pop 2>/dev/null || echo "WARNING: git stash pop failed in cleanup — manual recovery needed: git stash list" >&2
    fi
  }
  trap 'rc=$?; _rite_wiki_init_cleanup; exit $rc' EXIT
  trap '_rite_wiki_init_cleanup; exit 130' INT
  trap '_rite_wiki_init_cleanup; exit 143' TERM
  trap '_rite_wiki_init_cleanup; exit 129' HUP

  # dirty tree チェック（未コミットの変更を保護）
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
    echo "WARNING: 未コミットの変更があります。git stash で退避します。"
    git stash push -m "rite-wiki-init-stash"
    stash_needed=true
  else
    stash_needed=false
  fi

  # orphan ブランチを作成
  git checkout --orphan "$wiki_branch" || {
    echo "ERROR: git checkout --orphan '$wiki_branch' failed" >&2
    exit 1
  }
  git rm -rf . 2>/dev/null || true

  # Wiki ファイルのみをステージング
  git add .rite/wiki/ || {
    echo "ERROR: git add .rite/wiki/ failed" >&2
    exit 1
  }

  git commit -m "feat(wiki): initialize Wiki structure

- 3-layer structure: Raw Sources / Wiki Pages / Schema
- Templates: SCHEMA.md, index.md, log.md
- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}" || {
    echo "ERROR: git commit failed" >&2
    exit 1
  }

  git push -u origin "$wiki_branch" || {
    echo "ERROR: git push failed for branch '$wiki_branch'" >&2
    echo "  対処: gh auth status / ネットワーク接続 / リモートリポジトリの権限を確認してください" >&2
    exit 1
  }

  # 元のブランチに戻る
  git checkout "$current_branch" || {
    echo "ERROR: git checkout '$current_branch' failed — wiki ブランチ上に残っている可能性があります" >&2
    exit 1
  }

  # stash した場合のみ pop
  if [ "$stash_needed" = true ]; then
    git stash pop
    stash_needed=false  # EXIT trap での二重 pop を防止
  fi

  # cleanup trap を解除（正常完了時は不要）
  trap - EXIT INT TERM HUP

  echo "✅ Wiki ブランチ '$wiki_branch' を作成しました"

elif [ "$branch_strategy" = "same_branch" ]; then
  git add .rite/wiki/ || {
    echo "ERROR: git add .rite/wiki/ failed" >&2
    exit 1
  }
  git commit -m "feat(wiki): initialize Wiki structure

- 3-layer structure: Raw Sources / Wiki Pages / Schema
- Templates: SCHEMA.md, index.md, log.md
- Directories: raw/{reviews,retrospectives,fixes}, pages/{patterns,heuristics,anti-patterns}" || {
    echo "ERROR: git commit failed" >&2
    exit 1
  }

  echo "✅ Wiki を現在のブランチに初期化しました"

else
  echo "ERROR: 未知の branch_strategy: '$branch_strategy'" >&2
  echo "  受け付け可能な値: separate_branch / same_branch" >&2
  echo "  対処: rite-config.yml の wiki.branch_strategy を確認してください" >&2
  exit 1
fi
```

## Phase 3.5: Wiki Worktree セットアップ (Issue #547)

`separate_branch` 戦略の場合、Phase 3.1 で wiki ブランチを作成した直後に `.rite/wiki-worktree/` worktree を作成します。これにより `/rite:wiki:ingest` は dev ブランチを離脱することなく wiki ブランチのツリーに Write/Edit できるようになります。

```bash
branch_strategy="{branch_strategy}"
plugin_root="{plugin_root}"

if [ "$branch_strategy" = "separate_branch" ]; then
  # wiki-worktree-setup.sh は冪等 (既存なら no-op) で安全に呼べる
  # 注意: `if ! cmd; then rc=$?` パターンは bash 仕様上 `$?` が常に `!` の終了 status (= 0) を
  # 返すため、setup.sh の真の rc (1=env error / 2=disabled / 3=worktree add 失敗) を捕捉できない。
  # `set +e; cmd; rc=$?; set -e` で明示的に capture する (ingest.md Phase 1.3 と対称)。
  set +e
  bash "$plugin_root/hooks/scripts/wiki-worktree-setup.sh"
  setup_rc=$?
  set -e
  if [ "$setup_rc" -ne 0 ]; then
    echo "WARNING: wiki-worktree-setup.sh failed (rc=$setup_rc)" >&2
    echo "  影響: /rite:wiki:ingest 実行前に手動で worktree を作成する必要があります" >&2
    echo "  手動回復: bash $plugin_root/hooks/scripts/wiki-worktree-setup.sh" >&2
    # 非ブロッキング: worktree 作成失敗は init 全体を失敗させない
  fi
fi
```

### 3.5.1 既存 wiki ブランチへの `.gitkeep` 補完 migration

Issue #547 以前に init した wiki ブランチは `pages/{patterns,heuristics,anti-patterns}/.gitkeep` を持たないため、`/rite:wiki:ingest` の Write が親ディレクトリ不在で失敗します。この migration は冪等に既存 wiki ブランチに `.gitkeep` を補完します。worktree 経由で commit するため dev ブランチの HEAD は移動しません:

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
    commit_msg="chore(wiki): migrate pages/ directories with .gitkeep (Issue #547)"
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
        echo "WARNING: pages/ migration commit failed (rc=$commit_rc). /rite:wiki:ingest 側でも .gitkeep が作成されないと Write 失敗する可能性あり" >&2
        ;;
    esac
  else
    echo "✅ pages/.gitkeep はすべて存在します (migration 不要)"
  fi
fi
```

## Phase 4: 完了レポート

Phase 1.2 で取得した `branch_strategy` と `wiki_branch` の値を以下のテンプレートに埋め込んで表示すること:

```
Wiki の初期化が完了しました。

ブランチ戦略: {branch_strategy の値}
{separate_branch の場合: Wiki ブランチ: {wiki_branch の値}}

作成されたファイル:
- .rite/wiki/SCHEMA.md (蓄積規約)
- .rite/wiki/index.md (ページカタログ)
- .rite/wiki/log.md (活動ログ)
- .rite/wiki/pages/{patterns, heuristics, anti-patterns}/.gitkeep (空ディレクトリ git 追跡用、Issue #547)

作成されたディレクトリ:
- .rite/wiki/raw/{reviews, retrospectives, fixes}
- .rite/wiki/pages/{patterns, heuristics, anti-patterns}

{separate_branch の場合: worktree: .rite/wiki-worktree (→ wiki ブランチ)}

次のステップ:
- /rite:wiki:ingest で経験則の蓄積を開始
- /rite:wiki:query で経験則を参照
- /rite:wiki:lint で Wiki の品質チェック
```
