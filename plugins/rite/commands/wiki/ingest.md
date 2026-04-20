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

## Sub-skill Return Protocol (Issue #604)

> **Reference**: See `start.md` [Sub-skill Return Protocol (Global)](../issue/start.md#sub-skill-return-protocol-global) and `create.md` [Sub-skill Return Protocol](../issue/create.md#sub-skill-return-protocol) for the canonical contract. The same rules apply here for Phase 8 (`rite:wiki:lint --auto` Skill invocation) — DO NOT end your response after the lint sub-skill returns, DO NOT re-invoke the completed skill, and IMMEDIATELY proceed to the 🚨 Mandatory After Auto-Lint section in the **same response turn**.

### Pre-check list (Issue #604 — mandatory before ending any response turn)

**Enforcement coupling**: `ingest.md` は flow-state-update.sh を直接呼ばない設計 (Phase 9.1 「flow-state ownership」設計判断) のため、単独実行時の `stop-guard.sh` block は発火しない。caller (`pr/cleanup.md` Phase 4.W) からの sub-skill invoke 経由時のみ caller 側 phase (`cleanup_pre_ingest`) が flow-state を支配し、protocol violation 時に `stop-guard.sh` が caller phase を block し `manual_fallback_adopted` workflow_incident sentinel が stderr に echo されて Phase 5.4.4.1 (start.md 配下) で post-hoc 検出される (AC-7)。本 Pre-check list は両経路で共通に適用するが、enforcement の主たる発火経路は caller 経由のみである。

**Evaluation context** (2 場面で同じチェックリストを使う):

| 場面 (a): sub-skill (lint) return 直後 | 場面 (b): turn 終了直前 |
|---|---|
| まだ ingest workflow 中途。`NO` は「次の継続ステップを実行すべき」を意味する | 終端到達確認。`NO` は **protocol violation** (Phase 9 完了レポートを飛ばして停止しようとしている) |

場面 (a) では Item 1-2 が `NO` でも正常 (Phase 9 完了レポート未出力段階)。場面 (b) では 2 項目すべて `YES` が turn 終了の必要条件。

**Procedure**: Item 0 は **routing dispatcher** (YES/NO ではなく tag に応じて経路を選ぶ前段処理)。

| # | Check (種別) | If YES/NO / routing, do |
|---|-------------|------------------------|
| 0 | **Routing dispatcher** (状態質問ではない): 直前の sub-skill return tag は何か? | **Primary detection (Issue #618 AC-1)**: grep the recent output for `<!-- [lint:completed:auto] -->` HTML コメント sentinel (`grep -F '[lint:completed:auto]'`、fixed string で HTML コメント内の文字列も matchable)。HTML コメント形式は tag 形式としての一意性を持ち `Lint:` prefix の fragility (下記 note 参照) を解消する。matched → **continuation trigger** — immediately run 🚨 Mandatory After Auto-Lint (本 skill は Phase 8.2 Pre-write (`ingest_pre_lint`) / Mandatory After Step 1 (`ingest_post_lint`) / Phase 9.1 Step 3 (`ingest_completed, active=false`) の **3 箇所** で flow-state を patch する ring 構造のため、Step 1 で `ingest_post_lint` を patch → Phase 8.3-8.5 → Phase 9 Completion Report 出力 → Phase 9.1 Step 3 で `ingest_completed` に deactivate patch する).<br><br>**Fallback detection (legacy)**: HTML コメント sentinel が見つからない場合、`Lint:` 行 (lint.md Phase 9.2 の 6 フィールド 1 行 emit) または stop-guard hint を検出。matched → 同じ continuation trigger 経路。If no recognized tag: 通常の Phase 進行中なので Item 1-2 を評価。**本 Item は YES/NO 集計から除外**。<br><br>⚠️ **Fragility note** (`Lint:` prefix fallback に関して): `Lint:` prefix は tag 形式ではなく一般的な文字列 prefix のため、user-provided text や Phase 9 template 内の rendered 結果に混入する経路があり fragile。そのため HTML コメント sentinel を primary に、`Lint:` prefix を fallback に降格した (Issue #618 Decision D-1 — fallback 残置は legacy lint.md 互換性 + sentinel stripping edge case への defense-in-depth)。現状 lint.md は HTML コメント sentinel を emit しないため実効的には `Lint:` fallback が発火する (lint.md への sentinel 追加は別 Issue で追跡 — Issue #618 4.2 Non-Target)。LLM は両方を grep しどちらかが matched したら continuation trigger として扱うこと。unknown tag 検出時の default path は「ingest 自身の Phase 8.3 に進む」とする。 |
| 1 | **State check**: `[ingest:completed]` が HTML コメント形式で最終行 (あるいは末尾近傍) に出力済みか? | 推奨形式: `grep -F '[ingest:completed]'` (fixed string で HTML コメント内の string も matchable)。場面 (a) では `NO` でも legitimate — 次の Phase 9 出力に進む。場面 (b) では `NO` は Phase 9 が未完了 — Phase 9 完了レポート + caller 継続 HTML コメント + sentinel HTML コメントを出力する。 |
| 2 | **State check**: ユーザー向け完了メッセージ (`Wiki Ingest が完了しました` 行を含むブロック) が表示済みか? | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は Phase 9 完了レポートが欠落 — Phase 9 を実行する。 |

**Rule**: **Item 1-2 すべて `YES`** が turn 終了の必要条件 **ただし場面 (b) においてのみ**。Item 0 は routing dispatcher で YES/NO 集計には含まれない。

### Anti-pattern (what NOT to do)

When `rite:wiki:lint --auto` returns (typically with the `Lint: contradictions=N, ...` 1 行 stdout):

```
[WRONG]
<Skill rite:wiki:lint returns>
<LLM output: brief summary like "Lint: 0 件の問題">
<LLM ends turn. User must type `continue` manually before Phase 9 is output.>
```

This is a **bug**. The lint sub-skill return is NOT a turn boundary — it is a hand-off signal to Phase 8.4 (Ingest 完了レポート統合) → Phase 9 (Completion Report). Ending the turn here abandons the ingest workflow with no completion sentinel emitted, breaking caller continuation (cleanup Phase 5 won't be triggered).

### Correct-pattern (what to do)

```
[CORRECT]
<Skill rite:wiki:lint returns with "Lint: ..." line>
<LLM output: brief recap (optional)>
<In the same response turn, LLM IMMEDIATELY:>
  1. Parses Lint stdout (Phase 8.3 step 2) and integrates into Phase 8.4
  2. Outputs Phase 9 Completion Report (user-visible message + next-steps block)
  3. Outputs caller continuation HTML comment (Phase 9.1 設計判断により実行経路を問わず常に出力)
  4. Outputs <!-- [ingest:completed] --> as the absolute last line
```

**Rule**: Treat `rite:wiki:lint` return as a **continuation trigger**, not a stopping point. The **only** valid stop is after Phase 9's user-visible message + caller continuation HTML comment + `<!-- [ingest:completed] -->` HTML comment sentinel are all output. The sentinel is the absolute last line — invisible in rendered views, grep-matchable for hooks/scripts.

> **Contract phrases (AC-6 / Issue #604)**: The anti-pattern / correct-pattern contract above uses these exact phrases: `anti-pattern`, `correct-pattern`, `same response turn`, `DO NOT stop`. These phrases are grep-verified as part of the AC-6 static check. Manual verification command:
>
> ```bash
> for p in "anti-pattern" "correct-pattern" "same response turn" "DO NOT stop"; do
>   grep -c "$p" plugins/rite/commands/wiki/ingest.md
> done
> # Expected: all 4 counts >= 1
> ```

**Completion marker convention** (Issue #604, mirrors create.md Issue #561 D-01): The unified completion marker for `/rite:wiki:ingest` is `[ingest:completed]`, emitted as an HTML comment (`<!-- [ingest:completed] -->`) on the absolute last line of Phase 9's output. The HTML comment form keeps the string grep-matchable (`grep -F '[ingest:completed]'`) while ensuring the user-visible final content is the Phase 9 completion report block.

**Caller continuation marker** (Issue #604 三点セット — **Phase 9.1 設計判断により常時出力**): When `ingest.md` is invoked from a caller (現時点では `pr/cleanup.md` Phase 4.W のみ — Issue #547 以降、`pr/review.md` Phase 6.5.W / `pr/fix.md` Phase 4.6.W / `issue/close.md` Phase 4.4.W は `wiki-ingest-trigger.sh` + `wiki-ingest-commit.sh` の単一プロセス設計に移行し、Skill: `rite:wiki:ingest` を invoke しない)、Phase 9 also outputs a caller continuation HTML comment (`<!-- continuation: caller MUST proceed to its own Phase 5/Phase X (Completion Report). DO NOT stop. -->`) **before** the `[ingest:completed]` sentinel. This makes the caller's continuation requirement machine-readable (grep-able) while remaining invisible in rendered views. **シンプルさ優先の設計判断 (Phase 9.1 Step 0) により、単独 (`/rite:wiki:ingest`) 実行時も含め invoke 経路を問わず常に出力する** (単独実行時に出力しても無害 — 該当する caller がいないため grep 結果が利用されないだけ)。

**Defense-in-depth — flow-state ring** (Issue #618, supersedes the former #608 follow-up YAGNI stance): `ingest.md` は Phase 8.2 直前 (Pre-write、`ingest_pre_lint`) / 🚨 Mandatory After Auto-Lint Step 1 (post-lint patch、`ingest_post_lint`) / Phase 9.1 Step 3 (terminal patch、`ingest_completed, active=false`) の **3 箇所** で `flow-state-update.sh` を呼ぶ。caller 経由時は caller phase (例: `cleanup_pre_ingest`) を一時的に `ingest_pre_lint` / `ingest_post_lint` / `ingest_completed` に上書きし、sub-skill return 後 caller の Mandatory After (例: cleanup.md `🚨 Mandatory After Wiki Ingest`) が caller phase (`cleanup_post_ingest`) に書き戻す ring 構造で完遂する。単独実行 (`/rite:wiki:ingest`) 時は flow-state が不在 (caller 未起動) のため `--if-exists` フラグで no-op となり、従来挙動と互換。本反転の目的は Issue #621 (cleanup→ingest) と同型の Mode B 症状 (ingest→lint return 後の implicit stop) を多層防御で防ぐこと (Issue #618 AC-2/AC-3/AC-4)。

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
| `n_warnings` | `0` | Phase 8 で Lint の全検出件数合計（矛盾・陳腐化・孤児・欠落概念・壊れた相互参照）を加算する。`n_warnings += n_contradictions + n_stale + n_orphans + n_missing_concept + n_broken_refs`。**`n_unregistered_raw` は informational 指標のため加算しない**（ingest:skip 済み raw は意図的に経験則化しなかった件数であり警告ではない）。加えて Phase 8.3 step 1/3/4 で Lint 実行異常を検出した場合 `n_warnings += 1` と `n_lint_anomaly += 1` を並行加算する (詳細は下記 `n_lint_anomaly` 行参照) |
| `n_lint_anomaly` | `0` | Phase 8.3 step 1 (ERROR 文字列検出) / step 3 (stdout 空) / step 4 (regex mismatch) で Lint 実行異常を検出するごとに +1。**`n_warnings` と同時に加算** する (`n_warnings += 1` と `n_lint_anomaly += 1` を並行実行)。Phase 9 完了レポート内訳で「Lint 異常経路」として表示され、`n_warnings` の内訳不整合を防ぐ指標 |
| `n_contradictions` | `0` | Phase 8.3 step 2 で group 1 として Lint stdout から抽出。**`auto_lint: false` 経路で Phase 8.3 が skip されても `0` が維持されるため Phase 9 完了レポート (「Wiki 品質警告」行 / 「未登録 raw」行) で placeholder 残留しない** |
| `n_stale` | `0` | Phase 8.3 step 2 で group 2 として抽出（同上） |
| `n_orphans` | `0` | Phase 8.3 step 2 で group 3 として抽出（同上） |
| `n_missing_concept` | `0` | Phase 8.3 step 2 で group 4 として抽出（同上） |
| `n_unregistered_raw` | `0` | Phase 8.3 step 2 で group 5 として抽出。**`auto_lint: false` 経路で Phase 8.3 が skip されても `0` が維持されるため Phase 9 完了レポートの「未登録 raw（skip 済）」行で placeholder 残留しない** (PR #564 cycle 4 HIGH 対応) |
| `n_broken_refs` | `0` | Phase 8.3 step 2 で group 6 として抽出（同上） |

これらの値は Phase 5 の commit message 生成時にリテラル整数として **必ず置換** すること (placeholder のまま commit してはならない)。

> **`auto_lint: false` 経路での Lint カウンタ扱い** (PR #564 cycle 4 HIGH 対応): Phase 8.1 で `auto_lint=false` を検出した場合、Phase 8.2-8.5 は skip されるが、Lint カウンタ 6 種 (`n_contradictions` / `n_stale` / `n_orphans` / `n_missing_concept` / `n_unregistered_raw` / `n_broken_refs`) は本 Phase 2.1 で `0` に初期化済みのため、Phase 9 完了レポート (「Wiki 品質警告」行 / 「未登録 raw（skip 済）」行) の placeholder はすべて `0` として展開される (literal `{n_unregistered_raw}` 残留は発生しない)。Phase 9 の「Wiki 品質警告」行は Phase 8.1「`auto_lint: false` の場合」の指示により「スキップ (auto_lint disabled)」に置換されるが、「未登録 raw」行は本初期化により `0` が展開される (詳細は Phase 8.1 の auto_lint: false 扱い参照)。

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
  # Issue #566 対応: canonical signal-specific trap (4 行 EXIT/INT/TERM/HUP) で find_err tempfile orphan 防止
  # (lint.md Phase 6.0 / 6.2 / 8.3 + ingest.md Phase 5.2 と対称化、../pr/references/bash-trap-patterns.md#signal-specific-trap-template 準拠)。
  # 旧実装は trap 未保護で mktemp 成功直後に SIGINT/SIGTERM/SIGHUP が来ると find_err tempfile が orphan 化していた。
  find_err=""
  _rite_wiki_ingest_phase22_cleanup() {
    # BSD variant に統一 (lint.md Phase 6.0 / 6.2 / 8.3 + ingest.md Phase 5.2 と対称化)。
    # bash-trap-patterns.md の『BSD/macOS rm の rm -f "" 対応 (空引数ガード variant)』規範に準拠。
    [ -n "${find_err:-}" ] && rm -f "$find_err"
  }
  trap 'rc=$?; _rite_wiki_ingest_phase22_cleanup; exit $rc' EXIT
  trap '_rite_wiki_ingest_phase22_cleanup; exit 130' INT
  trap '_rite_wiki_ingest_phase22_cleanup; exit 143' TERM
  trap '_rite_wiki_ingest_phase22_cleanup; exit 129' HUP

  # F-11 対応: 1 行 WARNING を 3 行 loud WARNING に拡張 (lint.md Phase 6.0 / 6.2 と対称化)。
  # find の stderr が握り潰されると raw source 候補が silent 脱落し、`n_raw_sources` の不正確な
  # initialization を起こすため、対処と影響を明示する。
  find_err=$(mktemp /tmp/rite-wiki-ingest-find-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: stderr 退避 tempfile (find_err) の mktemp に失敗しました。find の詳細エラー情報は失われます" >&2
    echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
    echo "  影響: find の stderr が握り潰されるため、permission denied で raw source が silent 脱落する可能性があります" >&2
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

# Issue #566 対応: canonical signal-specific trap (4 行 EXIT/INT/TERM/HUP) で cat_err tempfile orphan 防止
# (lint.md Phase 6.0 / 6.2 / 8.3 + ingest.md Phase 5.2 と対称化、../pr/references/bash-trap-patterns.md#signal-specific-trap-template 準拠)。
# 旧実装は trap 未保護で mktemp 成功直後に SIGINT/SIGTERM/SIGHUP が来ると cat_err tempfile が orphan 化していた。
# 本スニペットは for candidate ループ内で実行されるため、trap は反復ごとに再設定される (bash 仕様上 idempotent、overwrite 安全)。
cat_err=""
_rite_wiki_ingest_phase23_cleanup() {
  # BSD variant に統一 (lint.md Phase 6.0 / 6.2 / 8.3 + ingest.md Phase 5.2 と対称化)。
  # bash-trap-patterns.md の『BSD/macOS rm の rm -f "" 対応 (空引数ガード variant)』規範に準拠。
  [ -n "${cat_err:-}" ] && rm -f "$cat_err"
}
trap 'rc=$?; _rite_wiki_ingest_phase23_cleanup; exit $rc' EXIT
trap '_rite_wiki_ingest_phase23_cleanup; exit 130' INT
trap '_rite_wiki_ingest_phase23_cleanup; exit 143' TERM
trap '_rite_wiki_ingest_phase23_cleanup; exit 129' HUP

cat_err=$(mktemp /tmp/rite-wiki-ingest-cat-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避 tempfile (cat_err) の mktemp に失敗しました。cat の詳細エラー情報は失われます" >&2
  echo "  対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
  echo "  影響: file body 読取失敗の根本原因 (permission / IO error) が不可視になります" >&2
  cat_err=""
}
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

#### 5.0.c canonical commit message 契約 (F-04 単一真実源、PR #564 cycle 10 対応)

Phase 5.1 (separate_branch) と Phase 5.2 (same_branch) の両 bash block で使用する commit message の template と placeholder 残留 gate は以下を **唯一の真実源** とする。両 phase は独立した bash block (Bash tool 呼び出し間でシェル状態が継承されない) のため helper function / 変数経由の共有はできないが、両サイトで以下と literal 一致する実装を保持すること。drift 検出は /rite:lint が本 section と Phase 5.1 / Phase 5.2 の三者を grep で比較する (将来実装、現状は目視確認 + PR レビュー指摘で検出)。

**canonical template**:

```
docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})
```

**canonical placeholder-residue gate** (bash):

```bash
case "$commit_msg" in
  *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
    echo "ERROR: Phase 5.{X} の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
    echo "  対処: LLM は Phase 2.1 / Phase 4 / Phase 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する必要があります" >&2
    exit 1
    ;;
esac
```

**Phase 5.1 / Phase 5.2 内での実装ルール**:
- `commit_msg=` 行の文字列は上記 canonical template と **literal 一致** させる (カウンタ placeholder 4 個の順序・表記・スペース含む全一致)
- placeholder-residue gate は上記 canonical と同一の case pattern を使用し、エラーメッセージの `Phase 5.{X}` 部分のみをサイト識別子 (Phase 5.1 / Phase 5.2) で置換する
- 将来 template を変更する際は本 5.0.c の定義 + Phase 5.1 + Phase 5.2 の **3 箇所を必ず同時に更新** する (片方のみ更新すると separate_branch / same_branch で commit message が非対称になる silent drift のリスク)

**本重複を helper function 化しない理由**: Phase 5.1 / 5.2 は独立した bash tool invocation のため shell function / 変数の継承が効かない。shared reference file に helper を置く案も検討したが、(a) 現状 2 サイトのみの重複で reference 化のオーバーヘッドが見合わない、(b) branch_strategy による排他実行で同時実行はなく concurrency 懸念もない、(c) drift 検出を /rite:lint 側で後付け可能、という理由で「3 箇所 explicit sync + drift-check anchor」方針を採用する。

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
  # 初期化され Phase 4 / 5.0 step 5 で incrementate されたカウンター変数を整数値に substitute する。
  # >>> DRIFT-CHECK ANCHOR: Phase 5.0.c canonical commit message ({n_pages_created}/{n_pages_updated}/{n_raw_sources}/{n_skipped}) <<<
  # Downstream reference: same file:Phase 5.2 — sibling sync 契約相手。Wiki 経験則 patterns/high
  #   「DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）」の bidirectional
  #   backlink sub-pattern に準拠 (PR #605 / Issue #607)。
  # 本 commit_msg 文字列と直下の placeholder-residue gate は Phase 5.0.c canonical と Phase 5.2 の
  # 同一文字列と 3 箇所 explicit sync を契約。変更時は 3 箇所同時更新必須 (/rite:lint で drift 検出予定)。
  commit_msg="docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"

  # F-10 対応: commit_msg の placeholder 残留 fail-fast gate (lint.md Phase 8.3 {log_entry} gate と対称化)。
  # LLM が `{n_pages_created}` 等を literal substitute せずに残した場合、literal `{n_pages_created}` を含む
  # 意味不明な commit が landed する silent regression を防ぐ。
  # >>> DRIFT-CHECK ANCHOR: Phase 5.0.c canonical placeholder-residue gate <<<
  # Downstream reference: lint.md:Phase 8.3, same file:Phase 5.2 — sibling sync 契約相手。
  #   Wiki 経験則 patterns/high「DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）」の
  #   bidirectional backlink sub-pattern に準拠 (PR #605 / Issue #607)。
  case "$commit_msg" in
    *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
      echo "ERROR: Phase 5.1 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
      echo "  対処: LLM は Phase 2.1 / Phase 4 / Phase 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する必要があります" >&2
      exit 1
      ;;
  esac

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
  # F-06 対応: canonical signal-specific trap (4 行 EXIT/INT/TERM/HUP) で _reset_err tempfile orphan 防止
  # (lint.md Phase 8.3 same_branch block (`_rite_wiki_lint_phase83_cleanup` trap) と対称化、../pr/references/bash-trap-patterns.md#signal-specific-trap-template 準拠)。
  # 旧実装は trap 未保護で SIGINT/SIGTERM/SIGHUP が来ると _reset_err tempfile が orphan 化していた。
  _reset_err=""
  _rite_wiki_ingest_phase52_cleanup() {
    # F-06 (PR #564 cycle 8 F-06) 対応: BSD variant に統一 (lint.md Phase 6.0 / 6.2 / 8.3 と対称化)。
    # bash-trap-patterns.md の『BSD/macOS rm の rm -f "" 対応 (空引数ガード variant)』規範に準拠。
    [ -n "${_reset_err:-}" ] && rm -f "$_reset_err"
  }
  trap 'rc=$?; _rite_wiki_ingest_phase52_cleanup; exit $rc' EXIT
  trap '_rite_wiki_ingest_phase52_cleanup; exit 130' INT
  trap '_rite_wiki_ingest_phase52_cleanup; exit 143' TERM
  trap '_rite_wiki_ingest_phase52_cleanup; exit 129' HUP

  # Phase 5.0 step 2 / step 3-6 の Write/Edit はすでに完了している前提
  # F-05 対応 (PR #564 cycle 10): `.gitignore` の `.rite/wiki/` 除外が追加されたことで、same_branch 戦略では
  # `.gitignore` に `!.rite/wiki/` negation が設定されていない場合、git add が "paths are ignored" で hard fail する。
  # エラーメッセージに原因候補と対処手順を明示し、ユーザーが anchor marker (gitignore-wiki-section-start) へジャンプできるようにする。
  add_err=$(mktemp /tmp/rite-wiki-ingest-add-err-XXXXXX 2>/dev/null) || add_err=""
  if ! git add .rite/wiki/ 2>"${add_err:-/dev/null}"; then
    echo "ERROR: git add .rite/wiki/ failed" >&2
    if [ -n "$add_err" ] && [ -s "$add_err" ]; then
      echo "  詳細 (git add stderr 先頭 5 行):" >&2
      head -5 "$add_err" | sed 's/^/    /' >&2
    fi
    echo "  原因候補: same_branch 戦略で .gitignore に '!.rite/wiki/' negation が未設定の可能性あり" >&2
    echo "  対処:" >&2
    echo "    1. .gitignore の gitignore-wiki-section-start アンカーブロックを参照してください (grep -n 'gitignore-wiki-section-start' .gitignore で位置特定)" >&2
    echo "    2. 同ブロック内の手順に従い `!.rite/wiki/` negation エントリを追加し、git add --dry-run で verification してから再実行してください" >&2
    echo "    3. それ以外の原因 (permission / disk full / corrupt index 等) の場合は上記 stderr の詳細を確認してください" >&2
    [ -n "$add_err" ] && rm -f "$add_err"
    exit 1
  fi
  [ -n "$add_err" ] && rm -f "$add_err"

  # {n_pages_created} / {n_pages_updated} / {n_raw_sources} / {n_skipped} は整数値に substitute する。
  # >>> DRIFT-CHECK ANCHOR: Phase 5.0.c canonical commit message ({n_pages_created}/{n_pages_updated}/{n_raw_sources}/{n_skipped}) <<<
  # Downstream reference: same file:Phase 5.1 — sibling sync 契約相手。Wiki 経験則 patterns/high
  #   「DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）」の bidirectional
  #   backlink sub-pattern に準拠 (PR #605 / Issue #607)。
  # 本 commit_msg 文字列と直下の placeholder-residue gate は Phase 5.0.c canonical と Phase 5.1 の
  # 同一文字列と 3 箇所 explicit sync を契約。変更時は 3 箇所同時更新必須 (/rite:lint で drift 検出予定)。
  commit_msg="docs(wiki): ingest {n_pages_created} new / {n_pages_updated} updated pages from {n_raw_sources} raw source(s) (skipped: {n_skipped})"

  # F-10 対応: commit_msg placeholder 残留 fail-fast gate (Phase 5.1 と対称化、lint.md Phase 8.3 {log_entry} gate と同型)
  # >>> DRIFT-CHECK ANCHOR: Phase 5.0.c canonical placeholder-residue gate <<<
  # Downstream reference: lint.md:Phase 8.3, same file:Phase 5.1 — sibling sync 契約相手。
  #   Wiki 経験則 patterns/high「DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）」の
  #   bidirectional backlink sub-pattern に準拠 (PR #605 / Issue #607)。
  case "$commit_msg" in
    *"{n_pages_created}"*|*"{n_pages_updated}"*|*"{n_raw_sources}"*|*"{n_skipped}"*)
      echo "ERROR: Phase 5.2 の commit_msg placeholder が literal substitute されていません (値: '$commit_msg')" >&2
      echo "  対処: LLM は Phase 2.1 / Phase 4 / Phase 5.0 step 5 で incrementate したカウンタ値を本 bash block の commit_msg= 行で literal substitute する必要があります" >&2
      exit 1
      ;;
  esac

  if ! git commit -m "$commit_msg"; then
    echo "ERROR: git commit failed" >&2
    echo "  ロールバック: staging area の .rite/wiki/ 変更を unstage します" >&2
    # F-06 対応: mktemp 失敗時の loud WARNING (Pattern 3 規範準拠、Phase 2.2 / 2.3 と対称化)
    _reset_err=$(mktemp /tmp/rite-wiki-ingest-reset-err-XXXXXX 2>/dev/null) || {
      echo "  WARNING: stderr 退避 tempfile (_reset_err) の mktemp に失敗しました。git reset の詳細エラー情報は失われます" >&2
      echo "    対処: /tmp の容量 / permission / inode 枯渇を確認してください" >&2
      echo "    影響: git reset 失敗の根本原因 (index lock / permission denied 等) が不可視になります" >&2
      _reset_err=""
    }
    if ! git reset HEAD .rite/wiki/ 2>"${_reset_err:-/dev/null}"; then
      echo "  WARNING: git reset HEAD .rite/wiki/ に失敗。手動で unstage してください: git reset HEAD .rite/wiki/" >&2
      [ -n "${_reset_err:-}" ] && [ -s "${_reset_err:-}" ] && head -3 "$_reset_err" | sed 's/^/    /' >&2
    fi
    [ -n "${_reset_err:-}" ] && rm -f "$_reset_err"
    _reset_err=""
    echo "  注意: LLM が事前に Edit した ingested:true 化と index.md / log.md 変更はワークツリーに残っています" >&2
    echo "  対処: git status で変更内容を確認後、手動で commit するか git checkout で破棄してください" >&2
    exit 1
  fi
  # same_branch では raw cleanup は不要 (PR diff に含めるのが意図的な選択)
  trap - EXIT INT TERM HUP
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

Ingest 直後、Wiki 全体の品質チェックを `/rite:wiki:lint --auto` として実行します。矛盾・陳腐化・孤児ページ・欠落概念・壊れた相互参照の **5 ブロッキング観点**に加え、未登録 raw（`ingest:skip` 済み）を **1 informational 指標**として計上する合計 6 フィールドで検査します。

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

**`auto_lint: false` の場合**: Phase 8.2-8.5 をスキップし Phase 9 へ進みます。Phase 9 完了レポートの Lint カウンタ 6 種（`n_contradictions` / `n_stale` / `n_orphans` / `n_missing_concept` / `n_unregistered_raw` / `n_broken_refs`）は **Phase 2.1 の初期化表で `0` に初期化済み** (PR #564 cycle 4 HIGH 対応) のため、Phase 9 完了レポート内の「Wiki 品質警告」行および「未登録 raw（skip 済）」行の placeholder はすべて `0` として展開される。ただし「Wiki 品質警告」行は Lint 未実行を明示するため「Wiki 品質警告: スキップ (auto_lint disabled)」と表示し、「未登録 raw（skip 済）」行は `0` 件として表示する (placeholder 残留は発生しない)。

### 8.2 Lint エンジンの呼び出し

> **ブランチ状態の前提** (Issue #547 で更新): 本 Phase の呼び出し時点での CWD は常に dev ブランチです (Issue #547 以降、ingest 実行中は dev ブランチから一切離脱しない worktree ベース実装のため)。lint.md Phase 8.2 は `separate_branch` 戦略時に `.rite/wiki-worktree/` worktree 内で `log.md` の追記 → `wiki-worktree-commit.sh` 呼び出しを行います。dev ブランチ側で stash / checkout が発生することはありません。

> **flow-state ring** (Issue #618, supersedes #604 flow-state ownership): 本 Phase 8.2 は lint Skill invoke 直前に `.rite-flow-state.phase = ingest_pre_lint` (active=true) に patch します。caller 経由時は caller phase (例: `cleanup_pre_ingest`) を一時上書きし、sub-skill return 後 Mandatory After Auto-Lint Step 1 が `ingest_post_lint` に patch → caller Mandatory After が caller phase (`cleanup_post_ingest`) に書き戻す ring 構造です。単独実行時は flow-state 不在のため `--if-exists` で no-op (従来互換)。`stop-guard.sh` は `ingest_pre_lint` / `ingest_post_lint` phase で `end_turn` を block し `manual_fallback_adopted` workflow_incident sentinel を stderr に emit します。

**Pre-write** (before invoking `rite:wiki:lint --auto`, Issue #618 AC-2): Update `.rite-flow-state` to `ingest_pre_lint` so `stop-guard.sh` blocks premature `end_turn` during sub-skill execution. The `if ! cmd; then` rc capture is mandatory — silent patch failure here disables the stop-guard defence-in-depth (同 pattern: cleanup.md Phase 4.W.2 #608 follow-up):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "ingest_pre_lint" --active true \
    --next "After rite:wiki:lint --auto returns: run 🚨 Mandatory After Auto-Lint (Step 1: patch ingest_post_lint) → Phase 8.3-8.5 → Phase 9 (Completion Report + caller continuation HTML comment + <!-- [ingest:completed] --> sentinel as absolute last line) in the SAME response turn. Do NOT stop." \
    --if-exists; then
  echo "WARNING: flow-state-update.sh patch (ingest_pre_lint) failed — stop-guard defence-in-depth is disabled for this Phase 8.2 invocation. Sub-skill rite:wiki:lint --auto will still be invoked, but premature end_turn will not be blocked. Investigate the helper exit reason in stderr above before relying on this protection again." >&2
fi
# --active true 明示 (cleanup.md Phase 4.W.2 F-03 と同じ理由): 前段 patch が WARNING 続行した
# fail-safe path で active=false 残存状態のまま到達する可能性があるため defense-in-depth 完全化。
```

LLM は `skill: "rite:wiki:lint", args: "--auto"` 形式で `/rite:wiki:lint` を `--auto` モードで呼び出します。`--auto` モードでは:

- 出力が最小化される（`Lint: contradictions={n}, stale={n}, orphans={n}, missing_concept={n}, unregistered_raw={n}, broken_refs={n}` 形式の 1 行）
- 6 フィールドが全て 0 の場合も必ず 1 行 (`Lint: contradictions=0, stale=0, orphans=0, missing_concept=0, unregistered_raw=0, broken_refs=0`) を出力する（stdout 空は Phase 8.3 step 3 で Lint 実行失敗として扱われるため、0 件でも明示 emit が必須）
- log.md への追記は lint.md Phase 8.2 が自律的にブランチ状態を判定し実行する
- lint.md は常に exit 0（非ブロッキング）

### 🚨 Mandatory After Auto-Lint (Issue #604 / #618 — Defense-in-Depth)

> **⚠️ 同 turn 内で必ず実行すること (MUST execute in the SAME response turn)**: `rite:wiki:lint --auto` の return 直後、**応答を終了せずに** 以下の Step 1-3 を即座に実行する。Phase 8.3-8.5 / Phase 9 (Completion Report) は本セクションを経由してのみ実行される唯一の経路である。

> **Enforcement** (Issue #618): `stop-guard.sh` は `ingest_pre_lint` / `ingest_post_lint` phase で `end_turn` を block し、`manual_fallback_adopted` workflow_incident sentinel を stderr に echo する。protocol violation は次回 turn の Phase 5.4.4.1 (start.md 配下) で post-hoc 検出される。

> **Anti-pattern 警告**: Lint Skill return 直後に「Lint: 0 件の問題」のような短いサマリ 1 行で turn を閉じてはならない。これは Mode B 症状 (sub-skill return tag を turn 境界として誤認する LLM turn-boundary heuristic の誤発火) を再発させる既知パターンであり、Phase 9 完了レポート + caller 継続 HTML コメント + sentinel HTML コメントが欠落する。

<!-- >>> DRIFT-CHECK ANCHOR: 🚨 Mandatory After Auto-Lint ring (Issue #618) <<<
     本 section の **Self-check 構造**は cleanup.md `🚨 Mandatory After Wiki Ingest` Self-check と
     同型 (同じ Yes/No 分岐 + 同じ terminal 重複呼び出し防止 rationale)。**Step 数は非対称** — ingest.md
     は Step 1-3 (3 step)、cleanup.md は Step 1-2 (2 step)。ingest.md の Step 3 (terminal gate) は
     cleanup.md 側では Phase 5 内部で terminal state 処理が埋め込まれているため Step としては存在しない
     (配置先が異なる)。「同型 numbered list」と誤記しないこと (cycle 1 F3 対応、PR #624 で修正)。
     また stop-guard.sh `ingest_pre_lint` / `ingest_post_lint` case arm と phase-transition-whitelist.sh
     `ingest_pre_lint` entry は本 ring の enforcement 層を構成する。いずれかを変更する場合、以下 3 site を
     同時確認:
       - plugins/rite/commands/pr/cleanup.md `🚨 Mandatory After Wiki Ingest` Step 1 (Self-check 構造の source)
       - plugins/rite/hooks/stop-guard.sh `ingest_pre_lint` / `ingest_post_lint` case
       - plugins/rite/hooks/phase-transition-whitelist.sh `ingest_pre_lint` / `ingest_post_lint` array entries
     <<< END DRIFT-CHECK ANCHOR: 🚨 Mandatory After Auto-Lint ring (Issue #618) >>> -->

**Self-check and branching**:

1. **Has `<!-- [ingest:completed] -->` been output as the absolute last line of the response?**
   - **Yes** — **terminal 到達後の重複呼び出し防止のための例外経路 (re-entry 防御)**。本 Self-check の evaluation timing (lint Skill return 直後、Phase 8.3 開始前) では **No 分岐のみが真**となり、Yes 分岐は response が既に sentinel で閉じられた後に何らかの理由で本 section が**再 evaluate** された場合のみ到達する (通常フローでは到達不能)。再 evaluate 時の `.rite-flow-state.phase` は `ingest_completed` (単独実行時の terminal state) / `cleanup_post_ingest` (caller 経由時に caller Mandatory After が書き戻した後) / `cleanup_completed` (caller terminal state) のいずれか。Step 1-3 below MUST be skipped. 理由: terminal 後に Step 1 の `patch --phase ingest_post_lint --if-exists` を再実行すると phase を巻き戻して flow-state を破壊する (cleanup.md `🚨 Mandatory After Wiki Ingest` Self-check と同じ rationale)。
   - **No** — Phase 8.3 / 8.4 / 8.5 / 9 have NOT been completed yet (phase=`ingest_pre_lint` の非 terminal 状態、本 Self-check の正常 evaluation timing)。Steps 1-3 below are **critical** — execute immediately.

**Step 1**: Update `.rite-flow-state` to `ingest_post_lint` phase (atomic). The `if ! cmd; then` rc capture is mandatory — silent failure here means the next stop-guard evaluation observes the stale `ingest_pre_lint` state and the HINT shown to the LLM no longer matches the actual workflow position (Issue #618 / mirrors cleanup.md #608 follow-up pattern):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "ingest_post_lint" --active true \
    --next "rite:wiki:lint --auto completed. Proceed to Phase 8.3 (Lint result parse) → 8.4 (Ingest 完了レポートへの統合) → 8.5 (n_warnings カウンタへの加算) → Phase 9 (Completion Report + caller continuation HTML comment + <!-- [ingest:completed] --> sentinel as absolute last line) in the SAME response turn. Do NOT stop." \
    --if-exists; then
  echo "WARNING: flow-state-update.sh patch (ingest_post_lint) failed — flow-state may still report ingest_pre_lint. Phase 8.3-9 will still execute, but stop-guard HINTs surfaced after this point will reference the pre-lint phase. Investigate the helper exit reason in stderr above." >&2
fi
# --active true 明示 (cleanup.md Phase 4.W 同型): Pre-write 失敗 fail-safe path 経由で active=false 到達の
# edge case を防ぐ defense-in-depth。
```

**Step 2**: Proceed to Phase 8.3 (Lint result parse) → 8.4 (Ingest 完了レポートへの統合) → 8.5 (n_warnings カウンタへの加算) → Phase 9 (Completion Report) **without ending the turn**. Each phase boundary is a logical step, not a turn boundary.

**Step 3** (terminal gate): At Phase 9, output the user-visible completion message + caller continuation HTML comment (Phase 9.1 設計判断により実行経路を問わず常に出力) + `<!-- [ingest:completed] -->` HTML コメント sentinel as the absolute last line. Phase 9.1 Step 3 bash block (後述) は sentinel 出力後に実行され `ingest_completed` への deactivate patch を行う (caller 経由時は直後に caller Mandatory After が `cleanup_post_ingest` へ書き戻す)。

> **Caller-side coupling**: caller (cleanup/review/fix/close) は本 sub-skill return 後に caller の Mandatory After セクション (例: cleanup.md `🚨 Mandatory After Wiki Ingest`) を実行する責務を持つ。caller 継続 HTML コメントはその責務を grep-able 形式で表現したもの (`<!-- continuation: caller MUST proceed ... -->`)。`stop-guard.sh` の HINT で `ingest_pre_lint` / `ingest_post_lint` / caller phase 別の継続指示が出るため、本マーカーは defense-in-depth の多層防御として機能する。

### 8.3 Lint 実行結果の取得とパース

LLM は Lint Skill 呼び出し後の会話コンテキストから結果をパースします。Skill ツール経由の呼び出しはシェル exit code を返さないため、**Skill 応答テキスト（= `lint.md` Phase 9.2 の最終出力）の内容**で成否を判定します。以降の手順における「stdout」はすべてこの Skill 応答テキストを指し、`lint.md` 内部の Bash tool 呼び出しで echo される中間出力（`pages_list=` / `index_read_ok=` / `log_read_ok=` 等）のことではありません:

#### 判定順序 (F-07 / F-14 対応)

step number は **項目の論理的役割の名称** であり、**実行順とは異なる**。判定は以下の優先順位で実行する:

```
優先 1: step 2 (6 フィールド regex match) を試行
        ├─ match 成功 → 6 変数を抽出して continue (step 1 / 3 / 4 は skip)
        └─ match 失敗 → 優先 2 へ

優先 2: step 1 (narrow ERROR scan) を試行
        ├─ ERROR: 行検出 → n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
        └─ ERROR 行なし → 優先 3 へ

優先 3: step 3 (stdout 空 check) を試行
        ├─ stdout 空 → n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
        └─ stdout 非空 → 優先 4 へ

優先 4: step 4 (format mismatch fallback) を実行
        └─ n_warnings += 1, n_lint_anomaly += 1, 6 変数を 0 fallback
```

このフローにより、step 2 が成功した場合 step 1 / 3 / 4 は skip される。lint.md Phase 9.2 が必ず 6 フィールド 1 行を emit する契約のため、通常時は step 2 のみで完結する。

1. **ERROR 行の検出** (F-07 対応で narrow scope に縮小): step 2 が match しなかった場合に限り、Skill 応答テキストに以下の行が含まれるかを検査します:

   - `ERROR:` で始まる任意行 (例: `ERROR: 未知の branch_strategy 値を検出しました`)

   **検出時の処理** (step 3 / step 4 と対称、上の判定順序 ascii diagram と一致):

   - `n_warnings` に 1 を加算 + `n_lint_anomaly` に 1 を加算（実行失敗を品質警告 + Lint 異常経路として計上）
   - 6 変数 (`n_contradictions` 等) はすべて `0` に設定（fallback）
   - 以下を stderr に出力:

     ```
     WARNING: /rite:wiki:lint --auto の Skill 応答テキストに ERROR: 行を検出しました（Lint 実行失敗）。
       検出行: {error_line_first1line}
       考えられる原因: lint.md 内の `echo "ERROR: ..."` 経由の fail-fast 経路が発火（branch_strategy 不正 / git 操作失敗等）
       Ingest 完了レポートには「Lint 結果: 実行失敗」と表示します。
       対処: /rite:wiki:lint を手動実行してエラー内容を確認してください。
     ```

     `{error_line_first1line}` は `ERROR:` で始まった最初の 1 行を 4 スペース prefix 付きで展開する。

   - Phase 8.4 の完了レポート統合では `Lint 結果: 実行失敗（ERROR: 行検出のため詳細取得不可）` と表示する

   **F-07 対応の設計変更**: 旧実装の bullets 2-4 (Phase 6.0 の log.md 読取失敗 / Phase 2.2 主処理失敗 / Phase 6.2 per-page 読取失敗の WARNING regex) は **dead regex** だった。これらの WARNING は lint.md 内部の Bash tool 呼び出しの stderr に出力されるが、Skill 応答テキスト (= lint.md Phase 9.2 の最終 stdout 出力) には通常含まれないため、本 step 1 で検知不能だった。step 2 (6 フィールド format) と step 4 (format mismatch fallback) で同等の検知が可能なため、step 1 は ERROR: 行のみに簡素化した (dead path 排除)。

2. **stdout のパース** (優先 1、最初に試行): exit 0 の場合、stdout の **全行を上から scan し、最初に以下の正規表現にマッチした行から** 6 つの変数を抽出して会話コンテキストに保持します: `^Lint: contradictions=([0-9]+), stale=([0-9]+), orphans=([0-9]+), missing_concept=([0-9]+), unregistered_raw=([0-9]+), broken_refs=([0-9]+)$`

   **F-03 対応 — 全行 scan に変更した理由** (PR #564): 旧仕様は stdout の「1 行目」のみを評価していたが、lint.md Phase 9.2 の契約は「6 フィールド 1 行を stdout に出力する」のみで、`Lint:` 行が **1 行目である保証は明示的に契約化されていなかった**。将来 lint.md が preamble の `echo` を stdout に流す変更を加えた場合 (例: `set -x` debug / observability echo / informational banner)、1 行目固定だと silent に step 4 (format mismatch fallback) に流れ、n_warnings が誤加算される。全行 scan + 最初の match 採用であれば、lint.md 側の intermediate echo が混入しても決定論的に `Lint:` 行を拾える。不具合抑制ではなく **fail-fast の範囲を意図したパターンに限定する** 設計強化。

   | 変数 | 正規表現 group |
   |------|---------------|
   | `n_contradictions` | group 1 |
   | `n_stale` | group 2 |
   | `n_orphans` | group 3 |
   | `n_missing_concept` | group 4 |
   | `n_unregistered_raw` | group 5 |
   | `n_broken_refs` | group 6 |

3. **stdout が空の場合**: **Lint 実行失敗として扱います** (PR #564 レビュー MEDIUM #2 対応 — 旧仕様の「検出 0 件と見なして 6 変数すべて 0」は bash syntax error / 未捕捉 fatal error で stdout が空になる経路と区別できず silent に "clean" と誤認するため撤廃)。`lint.md` Phase 9.2 の契約では「0 件でも必ず `Lint: contradictions=0, stale=0, ..., broken_refs=0` の 1 行を出力する」ため、stdout 空は unreachable な異常経路です。以下の処理を実行します:

   - `n_warnings` に 1 を加算 + `n_lint_anomaly` に 1 を加算（実行失敗を品質警告 + Lint 異常経路として計上）
   - 6 変数 (`n_contradictions` 等) はすべて `0` に設定（fallback）
   - 以下を stderr に出力:

     ```
     WARNING: /rite:wiki:lint --auto の stdout が空でした（Lint 実行失敗）。
       期待される出力: Lint: contradictions=N, stale=N, orphans=N, missing_concept=N, unregistered_raw=N, broken_refs=N
       考えられる原因: lint.md の bash syntax error / 未捕捉 fatal error / SIGPIPE / OOM
       Ingest 完了レポートには「Lint 結果: 実行失敗」と表示します。
       対処: /rite:wiki:lint を手動実行してエラー内容を確認してください。
     ```

   - Phase 8.4 の完了レポート統合では `Lint 結果: 実行失敗（stdout が空のため詳細取得不可）` と表示する

4. **stdout のどの行も正規表現にマッチしない場合** (F-03 の all-line scan に対応): Lint 側のフォーマット変更を検出した警告として扱い、以下を stderr に出力してから全変数を `0` に設定し、`n_warnings` と `n_lint_anomaly` に各 1 を加算します（silent に 0 件と誤認することを防ぐ。step 1 / step 3 と対称に「Lint 異常経路」として計上）。旧 5 フィールド形式（`missing=N`）の stdout が流れてきた場合もここに fallback するため、ingest.md / lint.md の同期 merge を徹底すること。なお step 2 は全行 scan で「最初にマッチした行」を採用する semantics のため、本 step 4 の発動条件も「どの行もマッチしなかった」である必要がある（「1 行目のみ」判定だと step 2 が後方行で match 成功したケースに対して step 4 が別途 1 行目だけ評価して format drift WARNING を誤発火する silent regression 経路になる）:

   - `n_warnings` に 1 を加算 + `n_lint_anomaly` に 1 を加算（format drift を品質警告 + Lint 異常経路として計上）
   - 6 変数 (`n_contradictions` 等) はすべて `0` に設定（fallback）
   - 以下を stderr に出力:

     ```
     WARNING: /rite:wiki:lint --auto の出力形式が期待と異なります（stdout のいずれの行も 6 フィールド regex にマッチしませんでした）。
       stdout の先頭 3 行:
     {lint_stdout_first3lines}
       期待される形式: Lint: contradictions=N, stale=N, orphans=N, missing_concept=N, unregistered_raw=N, broken_refs=N
     ```

     `{lint_stdout_first3lines}` は stdout の先頭 3 行を `sed 's/^/    /'` で 4 スペース prefix 付きで展開する（空 stdout の場合は Phase 8.3 step 3 で先に捕捉されるため本 step には到達しない）。

### 8.4 Ingest 完了レポートへの統合

Phase 9 の完了レポートに以下のように埋め込みます:

```
Lint 結果: 矛盾 {n_contradictions} 件 / 陳腐化 {n_stale} 件 / 孤児 {n_orphans} 件 / 欠落 {n_missing_concept} 件（未登録 skip {n_unregistered_raw} 件）/ 壊れた相互参照 {n_broken_refs} 件
```

**全カテゴリが 0 件の場合** (`n_contradictions + n_stale + n_orphans + n_missing_concept + n_unregistered_raw + n_broken_refs == 0`): 「Lint 結果: 問題なし」とのみ表示します。**矛盾以外の 1 件以上が検出された場合は必ず全カテゴリを表示**します（旧「矛盾以外の検出が 0 件の場合」条件は論理エラーのため削除）。`n_unregistered_raw` は informational ですが、表示条件判定には含めることで「真の欠落は無いが skip 残高がある」状況も可視化します。

### 8.5 `n_warnings` カウンタへの加算

**⚠️ 発動条件** (F-07 対応、PR #564 cycle 8): 本 Phase は **Phase 8.3 step 2 (6 フィールド regex match 成功) 経路でのみ実行します**。step 1/3/4 (ERROR 文字列検出 / stdout 空 / regex mismatch) 経路では既に Phase 8.3 内で `n_warnings += 1` と `n_lint_anomaly += 1` が加算済み (Phase 2.1 テーブル参照) のため、本 Phase は skip します。現状は Lint カウンタ 6 種が 0 fallback されるため実害はありませんが、将来 fallback 値を変更する際の regression を防ぐため発動条件を明示します。

Phase 2.1 で初期化した `n_warnings` に、Lint の全検出件数の合計を加算します (step 2 経路のみ):

```
n_warnings += n_contradictions + n_stale + n_orphans + n_missing_concept + n_broken_refs
```

これにより Phase 9 の完了レポートの「Wiki 品質警告」欄に Lint 検出件数が反映されます。**`n_unregistered_raw` は加算しない**: ingest:skip 済み raw は意図的に経験則化しなかった件数（log.md に skip 理由が記録済み）であり、警告として数えると skip 運用が膨らむほど警告カウンタが無意味に肥大する。informational 指標として完了レポートの内訳にのみ表示する。

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
- Wiki 品質警告: {n_warnings} 件（内訳: 矛盾 {n_contradictions} / 陳腐化 {n_stale} / 孤児 {n_orphans} / 欠落 {n_missing_concept} / 壊れた相互参照 {n_broken_refs} / Lint 異常経路 {n_lint_anomaly}）
  - 注: `{n_lint_anomaly}` は Phase 8.3 step 1/3/4 (`ERROR 文字列検出` / `stdout 空` / `regex mismatch`) で加算された Lint 実行異常の件数。`n_lint_anomaly` は Phase 2.1 のカウンタに追加、step 1/3/4 で `n_warnings += 1` と同時に `n_lint_anomaly += 1` も加算すること。
    - **等式** (F-11 対応、PR #564 cycle 8): `n_warnings = n_contradictions + n_stale + n_orphans + n_missing_concept + n_broken_refs + n_lint_anomaly`。step 2 成功時は `n_lint_anomaly=0` のため 5 カテゴリ合計が `n_warnings` と一致。step 1/3/4 anomaly 経路では 5 カテゴリはすべて 0 fallback だが `n_lint_anomaly >= 1` のため `n_warnings >= 1` となる。
- 未登録 raw（skip 済、warnings 不加算）: {n_unregistered_raw} 件

新規/更新ページ:
- {path1} ({action1})
- {path2} ({action2})

次のステップ:
- /rite:wiki:query で経験則を参照
- 詳細な品質チェックは /rite:wiki:lint で確認してください（Phase 8 で自動実行済み）
```

**Conditional rendering rule — Phase 8.1 `auto_lint: false` 経路の整合性** (silent regression 防止):

上記 template の「Wiki 品質警告:」行の展開は `auto_lint` の値によって以下の通り分岐する（Phase 8.1 の prose 指示と本 template の乖離を防ぐため explicit 化）。lint.md Phase 9.1 の `{log_read_ok_warning}` enum table と設計対称:

| `auto_lint` | 「Wiki 品質警告:」行の展開 | 「未登録 raw」行の展開 | 根拠 |
|-------------|-------------------------|--------------------|------|
| `true` (Phase 8.2-8.5 実行済み) | `Wiki 品質警告: {n_warnings} 件（内訳: 矛盾 {n_contradictions} / 陳腐化 {n_stale} / 孤児 {n_orphans} / 欠落 {n_missing_concept} / 壊れた相互参照 {n_broken_refs} / Lint 異常経路 {n_lint_anomaly}）` | `未登録 raw（skip 済、warnings 不加算）: {n_unregistered_raw} 件` | 通常経路（6 フィールド Lint 結果あり） |
| `false` (Phase 8.2-8.5 を skip) | `Wiki 品質警告: スキップ (auto_lint disabled)` に **置換する** (内訳は表示しない) | `未登録 raw（skip 済、warnings 不加算）: 0 件` (Phase 2.1 で 0 初期化済み値のまま) | Lint 未実行を明示（「Lint を実行して 0 件だった」と「Lint を skip した」を混同させない）|

**置換実装方法** (Claude が Phase 9 レポートを生成する際の手順):
1. Phase 8.1 で `auto_lint` 値を会話コンテキストに retain する
2. Phase 9 template を展開する際、`auto_lint == "false"` の場合は「Wiki 品質警告:」行全体を `Wiki 品質警告: スキップ (auto_lint disabled)` に置き換え、`内訳:` 以降のテキストは展開しない
3. 「未登録 raw」行は `0` 件として展開する（`n_unregistered_raw` は Phase 2.1 の初期値 0 のまま、placeholder 残留ではない）

### 9.1 Terminal Completion (Issue #604)

> **⚠️ MUST NOT (#604, mirrors #561)**: 「ユーザー可視最終行 = `[ingest:completed]` の bare bracket 形式」で turn を終わらせてはならない。bare sentinel は LLM の turn-boundary heuristic を誤発火させ、Mode B 症状 (recap 出力後の implicit stop) を再発させる既知リスク (Issue #561 解消条件)。**HTML コメント形式 (`<!-- [ingest:completed] -->`) のみ許容**。
>
> **⚠️ MUST NOT (#621 reinforce — H1 primary root cause)**: (前段 1033 行の MUST NOT #604/#561 とは**別層の禁止事項** — あちらは「ユーザー可視最終行 = bare bracket 形式」の禁止で sentinel 形式に関する規約。本規約は「三点セット #2/#3 間への recap 挿入」の禁止で三点セット内部構造に関する規約。両者は同じ Mode B 症状を対策するが禁じる対象の layer が異なる。) 三点セット出力の #2 (caller 継続 HTML コメント) と #3 (sentinel) の間に recap / 「Phase 9 完了しました」等の追加 recap line を挿入してはならない。recap は Phase 9 完了レポート本体 (#1) 内で完結させること。#2 と #3 の間に追加行を挿入すると、LLM の turn-boundary heuristic が `<!-- continuation: ... -->` を見て「明示的な terminator」と誤認し、#3 を absolute last line として出力する前に turn を閉じる regression (Issue #621) を誘発する。caller 継続コメント直後に即 sentinel コメント、その間に空行のみ許容。
>
> **bash tool 実行 note** (#618 PR #624 cycle 1 F1/F2 対応): 本規約の禁止対象は **assistant response の markdown text content** への追加行のみ。Step 3 terminal patch の bash tool 呼び出しは Claude Code の実行モデル上 response markdown text には content を追加しない (bash output は Bash tool result として別枠表示) ため、Step 3 を #3 sentinel 出力後に実行することは本規約の対象外である。**Step 3 bash 実行は Output ordering の #1/#2/#3 のいずれにも属さない meta-step** (下記「設計メモ」参照)。Step 3 を「#2/#3 間への挿入」と誤解して Step 3 を廃止 or #1 前に移動する修正は silent regression 誘発のため禁止 (Option A を仮採用すると Step 3 execution timing が Phase 9 本体処理と分離できず、terminal state 保証のタイミング contract が壊れる)。
>
> <!-- >>> DRIFT-CHECK ANCHOR: Phase 9.1 三点セット #2/#3 間 recap 禁止 (Issue #621) <<<
>      本 anchor と下記「設計メモ (非レンダリング注釈)」の Step 1/2 ↔ Output ordering #2/#3 対応表は
>      semantic 双方向参照: 片方の構造変更 (Step 番号・Output ordering 順序の入れ替え等) は
>      必ず他方にも反映すること。行番号の変動では drift 判定しない (semantic name 参照)。
>      <<< END DRIFT-CHECK ANCHOR: Phase 9.1 三点セット #2/#3 間 recap 禁止 (Issue #621) >>> -->
>
> **Output ordering** (絶対遵守、三点セット、Phase 9.1 設計判断により実行経路を問わず常に 3 要素すべて出力):
> 1. Phase 9 完了レポート本体 (ユーザー可視メッセージ + 処理サマリー + 新規/更新ページ + 次のステップ)
> 2. Caller 継続 HTML コメント (caller の Mandatory After 起動を grep-able に表現。単独実行時も無害として常時出力)
> 3. `<!-- [ingest:completed] -->` HTML コメント (絶対最終行 — rendered view では不可視、grep 可能)

> **設計判断 — flow-state ring** (Issue #618, supersedes the former YAGNI stance): `ingest.md` は Phase 8.2 Pre-write (`ingest_pre_lint`)、🚨 Mandatory After Auto-Lint Step 1 (`ingest_post_lint`)、Phase 9.1 Step 3 (`ingest_completed`, active=false) の 3 箇所で flow-state-update.sh を呼ぶ。caller 経由時は caller phase を一時上書きし、sub-skill return 後 caller Mandatory After (例: cleanup.md `🚨 Mandatory After Wiki Ingest`) が caller phase (`cleanup_post_ingest`) に書き戻す ring 構造で完遂する。単独実行時は `--if-exists` により flow-state 不在なら no-op (従来互換)。本設計反転は Issue #618 (ingest→lint return 後の implicit stop を多層防御で防ぐ) の AC-2/AC-3 要件に対応。

<!-- 設計メモ (非レンダリング注釈):
     Step 番号と Output ordering の対応は以下の通り:
       - Step 0  : policy 宣言 (meta-step、非出力)
       - Step 1  : Output ordering #2 (caller 継続 HTML コメント、response text に出力)
       - Step 2  : Output ordering #3 (sentinel HTML コメント、response text absolute last line に出力)
       - Step 3  : terminal patch bash 実行 (meta-step、#618 で追加、output 行を持たない)
     Output ordering #1 (Phase 9 完了レポート本体) は本セクションに入る前の Phase 9 proper で既に出力済み。
     Step 0 と Step 3 は非出力 meta-step で、Step 1/2 のみが Output ordering の出力行に対応する。

     Step 3 の meta-step 特性 (#618 PR #624 cycle 1 F1/F2 対応):
     - Step 3 は bash tool 呼び出しで response markdown text に content を追加しない (別チャンネル)
     - したがって「Step 2 sentinel 出力後に Step 3 bash 実行」という document order は
       Output ordering #1/#2/#3 を壊さず、MUST NOT #621 reinforce の「#2/#3 間 recap 挿入禁止」にも
       該当しない (禁止対象は response text 追加行のみ)。
     - Step 3 を Output ordering 表に含めない理由: 表は「response text output 行の順序」を表現する契約で、
       非出力 meta-step は含めないことで「#1 → #2 → #3 は連続 3 行」invariant を維持する。

     >>> DRIFT-CHECK ANCHOR: Phase 9.1 三点セット #2/#3 間 recap 禁止 (Issue #621) <<<
     本 anchor は上記 MUST NOT (#621 reinforce) の DRIFT-CHECK ANCHOR と semantic 双方向参照 ペア。
     Step 番号と Output ordering #1/#2/#3 の対応表を変更する場合は上記 MUST NOT 本文も同時に見直す。
     Step 3 meta-step の扱いを変更する場合 (例: Step 3 に response text output を追加する改修) は
     MUST NOT #621 reinforce の「bash tool 実行 note」も同時に更新すること (3 site 対称)。
     以下の 3 site は semantic name で特定する (line 番号 literal は PR #617 規約違反となるため使わない):
       (a) Phase 9.1 Step 3 の prose 見出し「Step 3 (terminal patch — Issue #618, PR #624 cycle 1 F1 で clarify)」
       (b) MUST NOT #621 reinforce セクション内の blockquote 見出し「bash tool 実行 note」
       (c) 本設計メモ (非レンダリング注釈)
     <<< END DRIFT-CHECK ANCHOR: Phase 9.1 三点セット #2/#3 間 recap 禁止 (Issue #621) >>>
     -->

**Step 0 (policy / meta)**: 継続マーカーを **常に出力する** (シンプルさ優先のデフォルト動作)。実行経路を問わず下記 Step 1 の HTML コメントを Step 2 の `<!-- [ingest:completed] -->` の直前に出力する。本 Step は方針宣言のみで実 output 行を持たない (Step 番号と Output ordering を 1:1 対応させるため、output 行である Step 1/2 から分離)。

> **Informational — 実 caller の現状**: 現時点で本 skill を Skill ツール経由で invoke する caller は `pr/cleanup.md` Phase 4.W のみ (`cleanup_pre_ingest` / `cleanup_post_ingest` phase で active flow-state を持つ)。`pr/review.md` / `pr/fix.md` / `issue/close.md` の Wiki 関連 Phase は Issue #547 以降 `wiki-ingest-trigger.sh` + `wiki-ingest-commit.sh` の単一プロセス設計に移行済みで、Skill: `rite:wiki:ingest` を invoke しないため `phase5_*` 等の e2e phase で本 sentinel を消費するパスは存在しない。単独実行時に caller 継続コメントを出力しても無害 (該当する caller がいないため grep 結果が利用されないだけ) のため、判定 logic を持たず常に出力する設計を採用する。

**Step 1 (= Output ordering #2 — caller 継続 HTML コメント)**: Step 0 の policy に従い実行経路を問わず常に出力する:

```
<!-- continuation: caller MUST proceed to its own Mandatory After section (e.g. cleanup.md 🚨 Mandatory After Wiki Ingest) and then to its Phase 5/Phase X Completion Report. DO NOT stop. -->
```

**Step 2 (= Output ordering #3 — sentinel HTML コメント)**: HTML コメント sentinel を応答の **absolute last line** として出力する:

```
<!-- [ingest:completed] -->
```

**Step 3 (terminal patch — Issue #618, PR #624 cycle 1 F1 で clarify)**: Step 2 の sentinel (= Output ordering #3、assistant response **text** の absolute last line) を出力した**後**に、`.rite-flow-state` を `ingest_completed` (active=false) に patch する。本 step が **Step 2 の絶対最終行性を壊さない** 理由: Claude Code の実行モデル上、**bash tool の stdout/stderr は assistant response の markdown text content とは別チャンネル**であり、response 最終行の判定は markdown content (Step 1-2 の text output) に対して行われるため、Step 2 sentinel 出力後に bash block を実行しても response の絶対最終行は sentinel のまま保たれる (bash output は conversation 上 Bash tool result として別枠表示されるが response text の一部ではない)。したがって実行順序は document 記載順序と一致: Step 1 (caller 継続 HTML コメント出力) → Step 2 (sentinel 出力) → Step 3 (bash tool 実行)。本 Step 3 の bash 実行は MUST NOT #621 reinforce の「#2/#3 間への recap 挿入禁止」対象外 — 禁止されるのは #2 と #3 の間の response text 追加行であり、bash tool 呼び出しは response text content に相当しないため (同規約の下方 "bash tool 実行 note" 参照)。caller 経由時は直後に caller Mandatory After が `cleanup_post_ingest` に書き戻すため、本 deactivate は caller による書き戻しと衝突しない (whitelist で `ingest_completed → cleanup_post_ingest` 遷移を許可):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "ingest_completed" --active false \
    --next "rite:wiki:ingest completed. Single-session run terminated; caller (if any) MUST proceed to its own Mandatory After section to write back its own phase (e.g. cleanup_post_ingest). Do NOT stop only if a caller is pending continuation." \
    --if-exists; then
  echo "WARNING: flow-state-update.sh patch (ingest_completed) failed — flow-state may still report ingest_post_lint. Caller Mandatory After will still be able to write back its own phase via --if-exists. Investigate the helper exit reason in stderr above." >&2
fi
# --active false は単独実行時の terminal state 保証 (single-session の場合 caller が不在なので
# 本 skill が自ら deactivate する)。caller 経由時は caller Mandatory After Step 1 が --active true
# で再活性化するため、本 deactivate は transient state である (whitelist 遷移 ingest_completed →
# cleanup_post_ingest で許可)。
```

**Self-verification** (Pre-check Item 1-2 evaluation, 場面 (b) mode):
- Item 1: `grep -F '[ingest:completed]'` against the response output finds the HTML-commented sentinel? → MUST be YES
- Item 2: User-visible `Wiki Ingest が完了しました` block displayed? → MUST be YES

If both are YES, stop is allowed. If any is NO, return to the missing step and re-output before ending the turn.

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
