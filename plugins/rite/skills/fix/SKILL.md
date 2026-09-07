---
name: fix
description: |
  rite workflow のレビュー指摘対応 sub-skill: /rite:pr-review の指摘を解消するコミット/返信を行い PR を
  mergeable に近づける。/rite:iterate ループ内から programmatic に呼ばれる（ユーザーは直接起動しない）。
  汎用の「コードを修正」ヘルパーではなく、その語では auto-activate しない。
argument-hint: "<pr_number>"
user-invocable: false
---

# /rite:fix

> **質問規律**: すべての質問・fallback 判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。

PR レビューコメントを取得・整理し、指摘への対応を効率的に支援する。やることは以下のシーケンシャルなタスク列:

0. Work Memory のロード (E2E フロー時のみ)
1. レビューコメントの取得と整理
2. 修正支援
3. 修正のコミット
4. 完了報告
5. E2E フロー継続 (出力パターン)

途中で止まったら flow-state に `phase=fix` が残るので `/rite:recover` で再開する。

`/rite:iterate` の review-fix loop から「not mergeable」評価時に自動 invoke される。**fatal finding と未解決の外部レビューを修正対象とする**。fatal は実測済みの CRITICAL/HIGH かつ current-pr/follow-up のみ。完了後 machine-readable output pattern を emit し caller に制御返却。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number, review findings from `/rite:pr-review`, flow state with `phase: fix` (iterate fix side) or `phase: phase5_fix` (legacy resume)
**Output**: `[fix:pushed]` | `[fix:pushed-wm-stale]` | `[fix:non-fatal-only]` | `[fix:replied-only]` | `[fix:cancelled-by-user]` | `[fix:sweep-done]` | `[fix:error]`
rationale: references/design-rationale.md#contract-legacy-phase

## Inline Annotation Convention

本ファイル内の `verified-review` 注釈 (`H-N` / `M-N` / `C-3` 等の重要度プレフィックス + 通番、括弧内 `(M10)` 等の統合追跡 ID) はレビュー指摘の対応追跡用。詳細: [design-rationale.md#inline-annotation-convention](references/design-rationale.md#inline-annotation-convention)

## Prerequisites

bash 4.0+ 必須 (複数の bash block で `mapfile -t < <(...)` builtin を使用)。ステップ 1.0.1 の bash block 冒頭 (Step 0) に [bash-compat-guard.md](../../references/bash-compat-guard.md) の canonical guard を inline embed 済み (C-3 対応)。失敗時は `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=bash_version_incompatible` を emit して `[fix:error]` で exit する。

## E2E Output Minimization

E2E では完了報告の表示だけ minimize する。本体処理は standalone と同等 ([workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md))。
rationale: references/design-rationale.md#e2e-output-minimization-scope

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Fix implementation | Full output | Full output (needed for code changes) |
| ステップ 4 (Completion) | Full report | Result pattern + 1-line summary only |
| ステップ 4.5 (Work Memory) | Full update | Full update (no change) |

E2E output format (ステップ 4):

```
[fix:{result}] — {fixed_count} fixed, {skipped_count} skipped, {files_changed} files changed; non_fatal_moved={non_fatal_moved_count}; review_json={triage_review_path}
```

Detection: ステップ 0.1 end-to-end flow determination を再利用。

## Arguments

以下の **4 種類のうち 1 つ** (`pr_number` / `pr_url` / `comment_url` の 3 つは mutually exclusive、引数なしも許容):

| Argument (one of) | Description |
|-------------------|-------------|
| `[pr_number]` | PR number (省略時は現在ブランチの PR を auto-detect) |
| `[pr_url]` | PR URL (`https://github.com/{owner}/{repo}/pull/{N}`) |
| `[comment_url]` | PR comment URL (`https://github.com/{owner}/{repo}/pull/{N}#issuecomment-{ID}`) |
| (引数なし) | 現在のブランチに紐づく PR を自動検出 |

ステップ 1.0 が `{pr_number}` と (該当時) `{target_comment_id}` を抽出する。`comment_url` は対象コメント直読み (1.2)。複数引数は不可 (最初に解釈できた形式のみ)。

---

## ステップ 0: Work Memory のロード (E2E フロー時のみ)

E2E 時のみ work memory から必要情報を読む。

### 0.1 Determine End-to-End Flow

会話 context から caller を判定:

| Condition | Determination | Action |
|-----------|---------------|--------|
| Conversation history contains rich context from `/rite:pr-review` | Within end-to-end flow (review-fix loop) | PR number can be obtained from conversation context |
| `/rite:fix` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

### 0.2 Load Work Memory

ブランチから Issue 番号を取り work memory を取得:

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')

# リポジトリ情報を取得（SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback。
# canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe）
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}

# 作業メモリを取得
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .body'
```

### 0.3 Information to Retrieve

work memory から抽出し retain:

| Field | Extraction Pattern | Purpose |
|-------|-------------------|---------|
| Issue number | `issue-(\d+)` from branch name | Work memory update |
| PR number | `- **番号**: #(\d+)` | Retrieve review comments |
| Phase | `- **フェーズ**: (.+)` | Confirm flow position |
| Review result | `### レビュー対応履歴` section | Check previous state |

standalone: 引数なしなら現在ブランチの PR。work memory の関連 PR も参照可。

---

### 0.5.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki-query/SKILL.md) — `wiki-query-inject.sh` API

レビュー取得前に Wiki 経験則を注入する。条件: `wiki.enabled: true` かつ `wiki.auto_query: true`。それ以外は silent skip。

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_query=""
if [[ -n "$wiki_section" ]]; then
  auto_query=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_query:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_query:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # opt-out default
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
```

`wiki_enabled=false` または `auto_query=false` なら ステップ 1 へ。キーワードは指摘カテゴリ・対象パス・finding 種別。

```bash
# {plugin_root} はリテラル値で埋め込む
# {keywords} はレビュー指摘のカテゴリ + 対象ファイルパスをカンマ区切りで生成
# （他コーラー skills/issue-create/SKILL.md / skills/pr-review/SKILL.md /
#   skills/issue-implement/SKILL.md / skills/unknowns/SKILL.md と同形式）
wiki_context=$(bash {plugin_root}/hooks/wiki-query-inject.sh \
  --keywords "{keywords}" \
  --format compact 2>/dev/null) || wiki_context=""
if [ -n "$wiki_context" ]; then
  echo "$wiki_context"
else
  echo "(Wiki から関連経験則は見つかりませんでした)"
fi
```

非空なら context に残し、ステップ 2 の修正方針に使う。

---

## ステップ 1: レビューコメントの取得と整理


### 1.0 Argument Parsing (Pre-flight)


**Always run**。1.1 の `gh pr view` 前に正規化し `{pr_number}` / (該当時) `{target_comment_id}` を取る。数字のみ・引数なしでも実行し、順序 1 / 4 のあと **`{target_comment_id} = null` を explicit set** する。

**Detection rules** (特殊パターン先行。POSIX ERE は lookaround 非対応):

| 順序 | Format | Regex (POSIX ERE 互換、lookaround なし) | Extracted |
|------|--------|------------------------------------------|-----------|
| 1 | 数字のみ (ASCII / 全角) | `^[0-9０-９]+$` | `pr_number` (全角数字は半角に正規化してから as-is 保持) |
| 2 | Comment URL (`?query` は `#fragment` の前後どちらでも可) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)(\?[^#]*)?#issuecomment-([0-9]+)(\?.*)?$` | `pr_number` = group 1, `target_comment_id` = **group 3** (group 2 は `#fragment` 前の query string、group 4 は `#fragment` 後の query string で、いずれも受け入れて無視) |
| 3 | PR URL (trailing path / query / fragment 任意) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)(/[^#?]*)?(\?[^#]*)?(#.*)?$` | `pr_number` = group 1 (trailing `/files`, `/commits`, `/checks` 等の sub-page、`?tab=...` 等の query string、`#diff-...` 等の fragment はすべて受け入れて無視) |
| 4 | 引数なし | — | 既存ロジック (current branch から PR 検出) |

target_comment_id は **常に group 3** (`${BASH_REMATCH[3]}`)。**順序 2 を順序 3 より先に試す**。
rationale: references/design-rationale.md#argument-detection-rules

**全角数字** (順序 1): マッチしたら半角へ正規化して `{pr_number}` に保持。ASCII のみは無変換。
rationale: references/design-rationale.md#fullwidth-normalization

正規化が発火したら **stderr に必ず出力** (silent transformation 禁止):

```
INFO: 全角数字 '{original}' を半角 '{normalized}' として解釈しました
  正規化対象: 順序 1 のパターン (^[0-9０-９]+$) でマッチした入力
  対処: もし意図しない数値の場合、Ctrl+C で中断してから半角で再入力してください
```

ASCII のみでは INFO を出さない。

**Behavior**:

1. 数字または引数なし → `{target_comment_id} = null`。ステップ 1.2 は既存ロジックで最新の `📜 rite レビュー結果` コメントを対象とする (既存挙動と完全互換)
2. PR URL → `{target_comment_id} = null`。ステップ 1.1 で `gh pr view {pr_number}` を実行し、ステップ 1.2 は既存ロジック
3. Comment URL → `{target_comment_id}` を設定。ステップ 1.1 で `gh pr view {pr_number}` を実行し、ステップ 1.2 の target_comment_id 分岐で対象コメントを直接取得する

**Parsing failure**: いずれのパターンにもマッチしない場合、以下の手順で**機械的に処理を終了**する (silent fall-through 禁止):

1. **エラーメッセージを stderr に出力**:
   ```
   エラー: 引数の形式を認識できませんでした
   入力: {argument}
   受け付け可能な形式:
     - PR 番号（例: 123、全角 １２３ も可）
     - PR URL（例: https://github.com/owner/repo/pull/123、trailing /files や ?tab=... も可）
     - PR コメント URL（例: https://github.com/owner/repo/pull/123#issuecomment-4567890、末尾の ?notification_referrer_id=... は自動的に無視）
   ヒント: もし Issue URL (/issues/123) を渡している場合、/rite:fix は PR 専用です。Issue 対応は /rite:open を使用してください。
   ```
2. **Context 変数を explicit set** (undefined 参照防止):
   - `{pr_number} = null`
   - `{target_comment_id} = null`
3. **`[fix:error]` output pattern を stdout に出力** し、**ステップ 1.1 以降のすべてのサブフェーズを実行せずにコマンド全体を終了する**
4. **Terminate = 1.1 進入禁止**。parse 失敗を `gh pr view {argument}` へ fallthrough しない (同番号 Issue 誤認)。

既存の `pr_number` 単体 / 引数なしは不変。本 Phase は判定のみ、1.1/1.2 へは `{target_comment_id}` の有無を渡す。


#### 1.0.1 Flag Parsing — `--review-file` and pre-stripping

`/rite:fix --review-file <path>` を受け付けるため、以下の手順で `{review_file_path}` を抽出する。ステップ 1.2 のハイブリッド読取ロジック (Priority 0: 明示指定) で参照される。

**実行順**: Detection rules (1.0.B) より先 (1.0.A)。

**抽出手順** (bash 実装):

```bash
# ステップ 1.0.1: flag トークンを $ARGUMENTS から pre-strip
# {review_file_path} と remaining_args (pr_number / pr_url / comment_url) を分離する
# rationale: references/design-rationale.md#review-file-flag-parsing

# --- Step 0: bash 4+ compat guard (C-3: inlined from ../../references/bash-compat-guard.md) ---
# rationale: references/design-rationale.md#bash-compat-guard
if ! command -v mapfile >/dev/null 2>&1; then
  bash_version=$("$BASH" --version 2>/dev/null | head -1)
  echo "ERROR: bash 4.0+ が必要ですが、現在のシェルは mapfile builtin を持っていません" >&2
  echo "  検出: $bash_version" >&2
  echo "  対処: macOS では brew install bash で 4+ をインストールし、PATH の先頭に追加してください" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=bash_version_incompatible" >&2
  echo "[fix:error]"
  exit 1
fi

original_args="$ARGUMENTS"
review_file_path="__RITE_UNSET__"  # explicit set (undefined 参照防止、衝突安全な sentinel)
remaining_args="$original_args"
# flag style (equals / space) を別変数に保持してエラーメッセージで区別する
review_file_flag_style="none"

# Pattern 1: --review-file=<path> (GNU-long-option style)
# `[^[:space:]]*` (0+) は空値検出のため、境界 `([[:space:]]|$)` は prefix 誤検出防止のため変更禁止
# rationale: references/design-rationale.md#review-file-flag-parsing
if [[ "$remaining_args" =~ (^|[[:space:]])--review-file=([^[:space:]]*)([[:space:]]|$) ]]; then
  review_file_path="${BASH_REMATCH[2]}"
  review_file_flag_style="equals"
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--review-file=[^[:space:]]*//')
# Pattern 2: --review-file <path> (POSIX style with space/tab)
# Pattern 1 と対称に `[^[:space:]]*` (0+) + 末尾境界。変更禁止 (同上 rationale 参照)
elif [[ "$remaining_args" =~ (^|[[:space:]])--review-file([[:space:]]+([^[:space:]]*))?([[:space:]]|$) ]]; then
  review_file_path="${BASH_REMATCH[3]:-}"
  review_file_flag_style="space"
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--review-file([[:space:]]+[^[:space:]]*)?//')
fi

# remaining_args の前後 whitespace を trim
remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

# --nb-sweep (値なし)。iterate 5.S 専用。通常ループは非 set のまま。
nb_sweep=0
if [[ "$remaining_args" =~ (^|[[:space:]])--nb-sweep([[:space:]]|$) ]]; then
  nb_sweep=1
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--nb-sweep([[:space:]]|$)/\1\2/')
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
fi

# --review-file=<空> を明示エラー化 (fail-fast、ステップ 5.1 評価順 1 で [fix:error] へ昇格)
# flag_style == "none" のときは sentinel `__RITE_UNSET__` のままなのでこの分岐に来ない
if [ "$review_file_flag_style" != "none" ] && [ "$review_file_path" = "" ]; then
  case "$review_file_flag_style" in
    equals)
      echo "エラー: --review-file= に値がありません (style: equals — `--review-file=<path>` の `=` の右側にパスを指定してください)" >&2
      ;;
    space)
      echo "エラー: --review-file の後にパスがありません (style: space — `--review-file <path>` のように空白で区切ってパスを指定してください)" >&2
      ;;
  esac
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_file_path_empty_value; flag_style=$review_file_flag_style" >&2
  echo "[fix:error]"
  exit 1
fi

# [CONTEXT] emit は本ブロックの成功パス値も含め stderr に統一する (引数解析系の規約、ステップ 1.2.0 Priority 0/2/3・6.1.a・5.1 retained flags と統一。canonical: ../../references/common-error-handling.md#context-emit-stdout-stderr-convention-canonical)
echo "[CONTEXT] REVIEW_FILE_PATH=$review_file_path" >&2
echo "[CONTEXT] NB_SWEEP=$nb_sweep" >&2
echo "[CONTEXT] REMAINING_ARGS=$remaining_args" >&2
```

**`--nb-sweep` 入口**: `[CONTEXT] NB_SWEEP=1` のとき、ステップ 1.1 の PR 識別の後に **1.3.S へ進む**（1.2 コメント取得・1.3 分類・ステップ 2–4 は評価しない。AC-7: 通常ループの分類表は不変）。

**Validation**: 本 Phase では **パス存在確認をしない** (Priority 0)。`--review-file=` (値なし) だけは即 fail-fast。

**制約 — 空白を含むパスは未対応**: `[^[:space:]]*` のため空白パスは分割され PR 番号に誤認される。空白パスは 1.2.0.1 の「ファイルパス指定」(AskUserQuestion) で入れる。

Detection rules の入力は **必ず** `$ARGUMENTS` ではなく stderr の `remaining_args`。フラグなし呼び出しは不変。

### 1.1 Identify the PR

1.0 抽出後に owner/repo を取る:

- **Within end-to-end flow**: `{owner}` and `{repo}` are already available from ステップ 0.2. Reuse them — no additional owner/repo resolution needed.
- **Standalone execution**: ステップ 0 was not executed. Retrieve them here:

```bash
# ステップ 0.2 と同一パターン（スタンドアロン実行時のみ使用。e2e フローでは ステップ 0.2 の値を再利用）
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}
```

> 以降の実行スニペットの `-R {owner_repo}` は、上記（または ステップ 0.2）で解決した owner/repo を slash 形式（例: `myorg/myrepo`）でリテラル置換する（canonical: [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) の Propagation 小節。SSH host alias 環境対応）。

When PR number is specified as an argument:

```bash
gh pr view {pr_number} -R {owner_repo} --json number,title,state,isDraft,headRefName,baseRefName,url,body
```

When argument is omitted, identify the PR from the current branch:

```bash
git branch --show-current
# -R 指定時は selector が必須のため、現在のブランチ名を selector に渡す（従来どおり「現在ブランチの PR」を特定する）
gh pr view "$(git branch --show-current)" -R {owner_repo} --json number,title,state,isDraft,headRefName,baseRefName,url,body
```

**When PR is not found:**

```
エラー: 現在のブランチに関連する PR が見つかりません

現在のブランチ: {branch}

対処:
1. `/rite:pr-create` で PR を作成
2. PR 番号を直接指定して再実行
```

Terminate processing.

**When PR is closed or already merged:**

```
エラー: PR #{number} は既に{state}されています

レビュー指摘への対応は実行できません。
```

Terminate processing.

### 1.1.5 セッション worktree 健全性の保証（multi_session 有効時）

ステップ 2 の Edit/Write 前に session worktree を保証する。`{head_ref}` は 1.1 の `.headRefName`。helper: `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)）。
rationale: references/design-rationale.md#worktree-ensure-preamble

```bash
issue_number=$(printf '%s' "{head_ref}" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
if [ -n "$issue_number" ]; then
  bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_number" --branch "{head_ref}"
else
  # head_ref が issue ブランチでない（session worktree の対象外）→ 従来どおり単一ツリーで続行
  echo "[CONTEXT] WT_ENSURE=skip (head_ref が issue ブランチでないため worktree 対象外: {head_ref})"
fi
```

`[CONTEXT] WT_ENSURE=` は [recover Phase 3.1.5](../recover/SKILL.md) の **WT_ENSURE 分岐表（SoT）** に従う。**`branch_absent` / `failed` だけ caller 固有** — recover の AskUserQuestion に対し、fix は `[fix:error]` で機械停止:

- `disabled` / `already_in` / `skip` → no-op、ステップ 1.2 へ（`disabled` = `multi_session.enabled: false`。従来どおり単一ツリーで動作し挙動不変）。
- `reenter` / `reconstructed` → `EnterWorktree` ツールを `path: {path}`（marker の `path=` 値）で呼び出してからステップ 1.2 へ。`reconstructed` は helper が `git worktree add` 済み。EnterWorktree 失敗時の切り分けは recover.md Phase 3.1.5 / /rite:open Step 2.3-W と同じ（silent に新規扱いしない）。
- `residue` → AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` のパスを表示）。
- `branch_absent` → 誤再構築しない。**develop 上で続行せず** `[fix:error]`（Edit/Write へ進まない）。
- `failed` → **silent fallback せず `[fix:error]`**。

### 1.2 Retrieve Review Comments

#### 1.2.0 Hybrid Review Source Resolution <!-- AC-3 / AC-4 / AC-5 / D-01 -->


> AC-3/4/5: 会話 > ローカル JSON > PR コメント。
rationale: references/design-rationale.md#hybrid-source-priority

**Priority chain**:

| Priority | Source | Condition | Action |
|----------|--------|-----------|--------|
| 0 | `--review-file <path>` (explicit) | `{review_file_path}` set in ステップ 1.0.1 | Read and parse the specified file. On failure, go directly to Priority 4 (fallback) |
| 1 | Conversation context | Same session has a recent `/rite:pr-review` result in context | Parse conversation findings, then persist and run common triage (1.2.2) |
| 2 | Local JSON file | `.rite/review-results/{pr_number}-*.json` exists | Read latest timestamp file; parse per schema |
| 3 | PR comment (backward-compat) | PR has `## 📜 rite レビュー結果` comment | Extract Raw JSON from code fence if present; else parse Markdown table (legacy) |
| 4 | Interactive fallback | None of the above available | `AskUserQuestion` — prompt user for action (ステップ 1.2.0.1) |

**⚠️ Selection logic — Claude substitution required**:

Selection logic は `scripts/review-source-resolve.sh` に委譲。下記引数を **literal substitute**:

- `{pr_number}` — ステップ 1.0 で正規化された PR 番号 (数値)。非数値は「未 substitute」として `reason=pr_number_placeholder_residue` で fail-fast。
- `{review_file_path_from_phase_1_0_1}` — ステップ 1.0.1 の `[CONTEXT] REVIEW_FILE_PATH=...` 値を会話コンテキストから読み取る (未指定時は `__RITE_UNSET__`)。
- `{conversation_review_decision}` — **Priority 1 判定**: Priority 0 が未発火の前提で、同一 session の直前 assistant turn に `## 📜 rite レビュー結果` を含む `/rite:pr-review` 出力が残っていれば、その findings を会話コンテキストから読み取り `use` を渡す。なければ `none` を渡す。
- `{p1_scan_turns}` / `{p1_scan_found}` — Priority 1 receipt: scan した assistant turn 数 (use 時 1 以上) と発見有無 (`use`→`true` / `none`→`false`)。

helper は `[CONTEXT] REVIEW_SOURCE*` を **stderr** に出す。最終 marker `[CONTEXT] REVIEW_SOURCE=<source>; review_source_path=<path or empty>; pr_number=<n>` のフォーマットは不変。fatal は helper が `FIX_FALLBACK_FAILED` + 非ゼロ、caller が `[fix:error]` stdout (**stdout 分離**)。

**Selection logic**:

```bash
# ステップ 1.2.0 Hybrid Review Source Resolution — scripts/review-source-resolve.sh へ委譲
# ⚠️ Claude は以下4つの引数を ステップ 1.0 / 1.0.1 / Priority 1 会話判定に基づき literal substitute すること。
#   {pr_number}                          : ステップ 1.0 正規化済み PR 番号 (数値)
#   {review_file_path_from_phase_1_0_1}  : ステップ 1.0.1 の [CONTEXT] REVIEW_FILE_PATH=... 値 (未指定: __RITE_UNSET__)
#   {conversation_review_decision}       : Priority 1 — 直前 assistant turn に `## 📜 rite レビュー結果` があれば use、なければ none
#   {p1_scan_turns} / {p1_scan_found}    : Priority 1 receipt (use→turns>=1,found=true / none→found=false)
# {plugin_root} は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。
# caller guard: helper の非ゼロ exit で `[fix:error]` を stdout 出力する (helper 自身は [fix:error] を出さない = stdout 分離)。
# rationale: references/design-rationale.md#review-source-resolution
bash {plugin_root}/scripts/review-source-resolve.sh \
  --pr-number "{pr_number}" \
  --review-file-path "{review_file_path_from_phase_1_0_1}" \
  --conversation-decision "{conversation_review_decision}" \
  --p1-scan-turns "{p1_scan_turns}" \
  --p1-scan-found "{p1_scan_found}" || {
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_source_resolve_failed" >&2
  echo "[fix:error]"
  exit 1
}
```

**Gate application receipt (Priority 0 / 2 JSON)**: file-based JSON は実測必須ゲートの
適用記録を必須とする。選択直後、findings map を構築する前に次を実行する。記録欠落を
旧形式として読み進めてはならない。既存アーカイブの復旧経路は `/rite:pr-review` の再実行のみ。

```bash
review_source="{review_source}"
review_source_path="{review_source_path}"
case "$review_source" in
  explicit_file|local_file)
    if ! jq -e '
      (.measured_gate | type) == "object"
      and (.measured_gate.commit_sha | type) == "string"
      and (.measured_gate.commit_sha | length) > 0
      and (.measured_gate.applied_at | type) == "string"
      and (.measured_gate.applied_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
      and ([.measured_gate.blocking, .measured_gate.demoted, .measured_gate.anchor_undetermined]
           | all(type == "number" and . >= 0 and . == floor))
      and .measured_gate.commit_sha == .commit_sha
    ' "$review_source_path" >/dev/null 2>&1; then
      echo "ERROR: review-result JSON に実測必須ゲートの適用記録が無いか、commit_sha と一致しません。/rite:pr-review を再実行してください" >&2
      echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=gate_not_applied" >&2
      echo "[fix:error] reason=gate_not_applied"
      exit 1
    fi
    ;;
esac
```

**On Priority 0 failure**: `review_source="fallback"` → 1.2.0.1。`--review-file` 明示時に P1–P3 へ silent fallthrough しない。

**On Priority 0 / 2 success**: Skip "Target Comment Fast Path" and "Broad Comment Retrieval"。選択した JSON をステップ 1.2.2 に渡す。Priority 1 の会話結果も同じステップへ合流する。各経路で独自に map / fatal を判定しない。

**On Priority 3**: Broad Retrieval 後に `### 📄 Raw JSON` fence を読む。parser は当該 section 以降にスコープする。


```bash
# pr_review_comment_body を tempfile から読み出す (ステップ 1.2 Broad Retrieval bash block が
# ${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt に書き出している前提)。
# block 冒頭で pr_number を literal substitute してから ${pr_number} で参照する (置換忘れを fail-fast 検出)。
# rationale: references/design-rationale.md#pr-comment-raw-json-extraction
pr_number="{pr_number}"
pr_comment_body_file="${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt"
_rite_fix_p3_cleanup() {
  rm -f "${pr_comment_body_file:-}"
}
trap 'rc=$?; _rite_fix_p3_cleanup; exit $rc' EXIT
trap '_rite_fix_p3_cleanup; exit 130' INT
trap '_rite_fix_p3_cleanup; exit 143' TERM
trap '_rite_fix_p3_cleanup; exit 129' HUP
if [ -f "$pr_comment_body_file" ]; then
  if [ ! -s "$pr_comment_body_file" ]; then
    # tempfile は存在するが空 = Broad Retrieval が書き出そうとしたが本文取得が空だった
    # (rite review コメント本文の jq 抽出は成功したが本文 0 byte の異常経路)
    echo "ERROR: pr_review_comment_body tempfile が空です: $pr_comment_body_file" >&2
    echo "  原因候補:" >&2
    echo "    - Broad Retrieval bash block が異常終了した (gh api の 401/403/404/timeout/5xx 等)" >&2
    echo "    - PR コメント本文 jq 抽出は成功したが本文が完全に空だった" >&2
    echo "    - 並列 fix セッションが同一 PR に実行され、他セッションが tempfile を truncate した" >&2
    echo "      (low-probability。同一 pr_number で複数 terminal から /rite:fix を実行したケース)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=comment_body_tempfile_empty" >&2
    exit 1
  fi
  # cat の exit code を if-else で独立 capture する (IO エラーの silent 空文字列化を防ぐ)
  cat_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-cat-err-XXXXXX" 2>/dev/null) || cat_err=""
  if pr_review_comment_body=$(cat "$pr_comment_body_file" 2>"${cat_err:-/dev/null}"); then
    :
  else
    cat_pr_comment_body_rc=$?
    echo "WARNING: pr_comment_body_file の cat が失敗しました (rc=$cat_pr_comment_body_rc): $pr_comment_body_file" >&2
    [ -n "$cat_err" ] && [ -s "$cat_err" ] && head -3 "$cat_err" | sed 's/^/  /' >&2
    echo "  原因候補: permission 変更 / NFS timeout / TOCTOU truncate" >&2
    echo "  legacy Markdown parser に fallthrough します" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_tempfile_read_io_error; rc=$cat_pr_comment_body_rc" >&2
    pr_review_comment_body=""
  fi
  [ -n "$cat_err" ] && rm -f "$cat_err"
else
  # tempfile 不在の 2 ケース (legitimate な未作成 / Broad Retrieval skip の前提条件違反) を
  # [INFO] emit で可視化する (rationale: references/design-rationale.md#pr-comment-raw-json-extraction)
  echo "[INFO] pr_comment_body_file 不在 → legacy Markdown parser に fallthrough ($pr_comment_body_file)" >&2
  echo "       legitimate な経路: 新規 PR / /rite:pr-review 未実行 / コメント削除済み" >&2
  echo "       もし /rite:pr-review 実行直後にこのメッセージが出た場合、Claude が Priority 3 進入前に" >&2
  echo "       ステップ 1.2 Broad Retrieval bash block を呼び出し忘れた可能性があります (前提条件違反)" >&2
  echo "[CONTEXT] BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT=1" >&2
  pr_review_comment_body=""
fi

# Raw JSON section の抽出は helper (実ファイル) に委譲する。skill 本文の fenced bash に awk を
# 書くと Skill loader が位置パラメータを起動引数へ展開して行バッファが壊れる
# (静的検出: hooks/scripts/dollar-zero-check.sh)。どの section を採るかの規則は helper header 参照。
# here-string `<<<` は printf | awk の SIGPIPE 回避 (bash-defensive-patterns.md Pattern 5)。
# rationale: references/design-rationale.md#pr-comment-raw-json-extraction
raw_json=$(bash {plugin_root}/hooks/scripts/review-raw-json-extract.sh <<< "$pr_review_comment_body")
# 変数名は helper の rc であることを表す。reason 文字列 pr_comment_raw_json_awk_failed は
# reason 表と Eval-order enumeration に登録済の documented set のため改名しない。
raw_json_extract_rc=$?
# exit code を明示検査 (空出力と「Raw JSON section なし」の区別を保つ)
if [ "$raw_json_extract_rc" -ne 0 ]; then
  echo "WARNING: PR コメントからの Raw JSON 抽出 helper が失敗 (rc=$raw_json_extract_rc)" >&2
  echo "  原因候補: helper 解決不能 (rc=127) / awk バイナリ異常 / OOM (行バッファが大きすぎ) / SIGPIPE" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_raw_json_awk_failed; rc=$raw_json_extract_rc" >&2
  raw_json=""
fi

# raw_json="" だけが legitimate な legacy fallthrough。それ以外の壊れた新形式 JSON は
# 検証失敗を [fix:error] で停止する。新形式の metadata を legacy 表で補完しない。
if [ -z "$raw_json" ]; then
  # legitimate legacy format: PR コメントに Raw JSON section なし → 旧 Markdown table parser へ
  :
elif ! printf '%s' "$raw_json" | jq empty 2>/dev/null; then
  echo "WARNING: PR コメント内の Raw JSON が syntactically invalid です。[fix:error] で停止します。" >&2
  echo "  対処: PR コメントを再投稿するか、ローカル JSON ファイルを使用してください" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_raw_json_parse_failure" >&2
  echo "[fix:error] reason=pr_comment_raw_json_parse_failure"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  (.schema_version | type == "string" and length > 0)
  and (.pr_number | type == "number")
  and (.findings | type == "array")
' >/dev/null 2>&1; then
  # 明示型ガード (jq truthiness は false/null のみ falsy — 空文字列や型違反を silent pass させない)
  echo "WARNING: PR コメント内の Raw JSON が必須フィールドを欠いています。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_schema_required_fields_missing" >&2
  echo "[fix:error] reason=pr_comment_schema_required_fields_missing"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  (.measured_gate | type) == "object"
  and (.measured_gate.commit_sha | type) == "string"
  and (.measured_gate.commit_sha | length) > 0
  and (.measured_gate.applied_at | type) == "string"
  and (.measured_gate.applied_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
  and ([.measured_gate.blocking, .measured_gate.demoted, .measured_gate.anchor_undetermined]
       | all(type == "number" and . >= 0 and . == floor))
  and .measured_gate.commit_sha == .commit_sha
' >/dev/null 2>&1; then
  echo "ERROR: PR コメント内 Raw JSON に実測必須ゲートの適用記録が無いか、commit_sha と一致しません。/rite:pr-review を再実行してください" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=gate_not_applied" >&2
  echo "[fix:error] reason=gate_not_applied"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  (.overall_assessment != "mergeable")
  or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
' >/dev/null 2>&1; then
  # Cross-field invariant (review-result-schema.md): mergeable × open CRITICAL/HIGH は禁止。
  # 実測必須ゲートによる `measured == false` 除外は本経路に入れない — 同一 invariant は P0/P2
  # (`scripts/review-source-resolve.sh`) と SoT (review-result-schema.md invariant #2) にも実装があり、
  # P3 だけ緩めると同一 JSON が経路により受理/拒否に割れる。write 側が `verification` を出力する
  # 前提は で満たされたが、3 経路 + SoT の同時更新は依然として不要 — gated な
  # `measured == false` は `non_blocking_findings[]` へ移送されるため `findings[]` に残る非実測
  # finding は `scope == "nit-noted"` のみ。CRITICAL/HIGH × nit-noted は invariant #4 が禁じる
  # 組合せなので、CRITICAL/HIGH を見る本述語の判定対象に非実測 finding は現れない。
  echo "WARNING: PR コメント内の Raw JSON が cross-field invariant に違反しています (mergeable だが open な CRITICAL/HIGH finding あり)。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_comment_cross_field_invariant_violated" >&2
  echo "[fix:error] reason=pr_comment_cross_field_invariant_violated"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  [.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0
' >/dev/null 2>&1; then
  # Cross-field invariant #4: severity ∈ {CRITICAL, HIGH} × scope == "nit-noted" は禁止
  # (1.0/1.0.0 JSON では .scope 欠落のため規約的に発火しない — 後方互換)
  violation_count=$(printf '%s' "$raw_json" | jq '[.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' 2>/dev/null || echo "?")
  echo "WARNING: PR コメント内の Raw JSON が cross-field invariant #4 に違反しています (severity ∈ {CRITICAL, HIGH} で scope=\"nit-noted\" の finding が $violation_count 件)。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_comment_critical_high_scope_nit_noted; count=$violation_count" >&2
  echo "[fix:error] reason=pr_comment_critical_high_scope_nit_noted"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' >/dev/null 2>&1; then
  # overall_assessment enum validation (review-result-schema.md)
  oa_val=$(printf '%s' "$raw_json" | jq -r '.overall_assessment // "(null)"' 2>/dev/null)
  echo "WARNING: PR コメント内の Raw JSON の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
  echo "[fix:error] reason=overall_assessment_unknown_value"
  exit 1
else
  # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
  # exit code 捕捉は `if cmd; then :; else rc=$?; fi` 形式 (「!」否定は $? を反転するため使用禁止)
  if schema_version=$(printf '%s' "$raw_json" | jq -r '.schema_version // "unknown"' 2>/dev/null); then
    : # jq 成功
  else
    jq_sv_rc=$?
    echo "WARNING: PR コメント内 Raw JSON の schema_version 抽出で jq が失敗 (rc=$jq_sv_rc)" >&2
    echo "  原因候補: jq バイナリ異常 / OOM / pipe write error" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_schema_version_jq_failed; rc=$jq_sv_rc" >&2
    schema_version="unknown"
  fi
  case "$schema_version" in
    "1.0.0"|"1.0"|"1.1.0")
      # accept list 3 値は Priority 0/2/3 + hooks/scripts/review-trend-divergence.sh の 4 sites で完全同期 (review-result-schema.md Schema Version SoT 契約)
      # commit_sha stale detection: mismatch は WARNING のみで continue
      # rationale: references/design-rationale.md#schema-normalization-mirror
      json_commit_sha_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-p3-commit-sha-err-XXXXXX" 2>/dev/null) || json_commit_sha_err=""
      if json_commit_sha=$(printf '%s' "$raw_json" | jq -r '.commit_sha // empty' 2>"${json_commit_sha_err:-/dev/null}"); then
        :
      else
        jq_p3_commit_sha_rc=$?
        echo "WARNING: PR コメント内 Raw JSON の commit_sha 抽出で jq が失敗 (rc=$jq_p3_commit_sha_rc)" >&2
        [ -n "$json_commit_sha_err" ] && [ -s "$json_commit_sha_err" ] && head -3 "$json_commit_sha_err" | sed 's/^/  /' >&2
        echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=jq_error_on_commit_sha; priority=3" >&2
        json_commit_sha=""
      fi
      [ -n "$json_commit_sha_err" ] && rm -f "$json_commit_sha_err"
      if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
        echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2
        echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=git_rev_parse_head_failed" >&2
        head_sha=""
      fi
      if [ -n "$json_commit_sha" ] && [ -n "$head_sha" ] && [ "$json_commit_sha" != "$head_sha" ]; then
        echo "⚠️ WARNING: PR コメント内 Raw JSON の commit_sha ($json_commit_sha) が現 HEAD ($head_sha) と不一致です (stale)" >&2
        echo "  本 Raw JSON は古い commit に対して生成されました。既修正項目を再指摘する可能性があります。" >&2
        echo "  注意: Priority 2 (ローカルファイル) も stale だった場合、本 Priority 3 が stale のまま消費されます。" >&2
        echo "  対処: /rite:pr-review を再実行して PR コメントを更新してください。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_STALE=1; reason=pr_comment_commit_sha_mismatch; json_sha=$json_commit_sha; head_sha=$head_sha" >&2
      fi
      # Raw JSON の解析が成功したら全経路共通のステップ 1.2.2 へ。
      # raw_json を永続 JSON に保存し、helper による triage 後に reload する。
      # triage 失敗は [fix:error]。legacy Markdown parser への fallback 禁止。
      ;;
    *)
      echo "WARNING: PR コメント内の Raw JSON schema_version が未知: $schema_version" >&2
      echo "  [fix:error] で停止します。" >&2
      echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=pr_comment_schema_version_unknown" >&2
  echo "[fix:error] reason=pr_comment_schema_version_unknown"
  exit 1
      # Legacy Markdown table parser (ステップ 1.2.1) に fallthrough
      ;;
  esac
fi
```

`{review_source}` を later phase の provenance に使う。

#### 1.2.0.1 Interactive Fallback (when all sources missing) <!-- AC-6 -->

> **Acceptance Criteria anchor**: AC-6 (全ソース欠落時はレビューを 1 回自動再生成し、再度欠落した場合のみ `AskUserQuestion` で「ファイルパス指定 / 中止」を提示する)。

`{review_source}=fallback` (Priority 0-3 が全て不可) の場合、レビュー再実行は可逆かつ自己解決可能なので推奨として `/rite:pr-review {pr_number}` を 1 回自動実行し、その判断と欠落 source を既存 work memory の決定事項へ記録する。再実行後も source が得られない場合だけ、ユーザー固有の入力であるファイルパス指定または中止を `AskUserQuestion` で確認する:

```
レビュー結果が見つかりませんでした
  会話コンテキスト: なし
  ローカルファイル: .rite/review-results/{pr_number}-*.json なし
  PR コメント: 該当なし

どうしますか？

オプション:
- ファイルパス指定: 既存の JSON ファイルパスを入力する (Other で自由入力)
- 中止: /rite:fix の処理を終了する
```

**Per-option behavior** (one-shot — retry counter / state file による hard gate は廃止した。止まったら `/rite:recover`):

| User Choice | Action |
|-------------|--------|
| **ファイルパス指定** | ユーザー入力パスで ステップ 1.2.0 Priority 0 を **1 回だけ** 再実行する。再実行でも invalid なら `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_file_path_invalid` を emit して `[fix:error]` で terminate する (リトライループなし) |
| **中止** | `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_cancelled` を emit し `[fix:error]` を出力して terminate する。ステップ 2+ のロジックは一切実行しない |

**中止 / file-path invalid の bash 実装** (silent regression 防止 — ステップ 5.1 評価順 1 で `[fix:error]` に昇格):

```bash
# 中止が選択された場合:
echo "ユーザーが Interactive Fallback で「中止」を選択しました" >&2
echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_cancelled" >&2
echo "[fix:error]"
exit 1
```

```bash
# 「ファイルパス指定」の再実行でも invalid だった場合:
echo "エラー: 指定されたファイルパスでもレビュー結果を取得できませんでした" >&2
echo "  /rite:pr-review を実行してローカル JSON を生成するか、有効な JSON path を確認してください" >&2
echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_file_path_invalid" >&2
echo "[fix:error]"
exit 1
```

**ステップ 2+ 進入禁止**: `[fix:error]` 後は 2/3/4 の bash を呼ばない (`exit 1`。例外なし)。

**ステップ 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons**:

> Selection / P0–P2 map reason は各 helper。本表は 1.0.1 / caller guard / 1.2.0.1 / P3。

| reason | Description |
|--------|-------------|
| `overall_assessment_unknown_value` | Priority 0/2/3 で `overall_assessment` が受理値 (`mergeable` / `fix-needed`) 以外 (review-result-schema.md enum 違反、`REVIEW_SOURCE_ENUM_UNKNOWN` flag。P0: fallback、P2: Priority 3 routing、P3: legacy parser fallthrough) |
| `pr_comment_raw_json_parse_failure` | Priority 3 で取得した PR コメント Raw JSON が `jq empty` で syntax invalid (legacy Markdown parser へ fallthrough) |
| `pr_comment_raw_json_awk_failed` | Priority 3 で PR コメントからの Raw JSON 抽出 helper (`hooks/scripts/review-raw-json-extract.sh`) が失敗 (helper 解決不能 rc=127 / awk 異常 / OOM / SIGPIPE、`REVIEW_SOURCE_PARSE_FAILED` flag、legacy Markdown parser へ fallthrough)。reason 名の `awk` は helper 委譲前からの documented literal で、Eval-order enumeration の機械マッチ対象のため改名しない |
| `pr_comment_schema_required_fields_missing` | Priority 3 で取得した PR コメント Raw JSON が parse 可能だが必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) が欠落 (legacy Markdown parser へ fallthrough) |
| `pr_comment_cross_field_invariant_violated` | Priority 3 で取得した PR コメント Raw JSON の cross-field invariant 違反: `overall_assessment=="mergeable"` だが CRITICAL/HIGH かつ status==open の finding が存在 (legacy Markdown parser へ fallthrough、`REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED` flag) |
| `pr_comment_critical_high_scope_nit_noted` | Priority 3 で取得した PR コメント Raw JSON の cross-field invariant #4 違反: `severity ∈ {CRITICAL, HIGH}` × `scope == "nit-noted"` の finding が存在 (legacy Markdown parser へ fallthrough、`REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED` flag) |
| `pr_comment_schema_version_unknown` | Priority 3 で取得した PR コメント Raw JSON の schema_version が未知 (legacy Markdown parser へ fallthrough) |
| `user_cancelled` | Interactive fallback で「中止」option が選択された (ステップ 5.1 評価順 1 で `[fix:error]` に昇格) |
| `user_file_path_invalid` | Interactive fallback の「ファイルパス指定」で再実行した path でもレビュー結果を取得できなかった (one-shot、retry ループなし、`[fix:error]` 昇格) |
| `review_file_path_empty_value` | ステップ 1.0.1 で値を持たない `--review-file` が指定された。Pattern 1 (equals style: `--review-file=`) と Pattern 2 (space style: `--review-file <末尾>`) の両方で検出される。`flag_style=equals` / `flag_style=space` として retained flag に付記される |
| `comment_body_tempfile_empty` | ステップ 1.2.0 Priority 3 で `${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt` が存在するが空 (Broad Retrieval が異常終了したか PR コメント本文が完全に空) |
| `bash_version_incompatible` | Prerequisites の `command -v mapfile` チェックが失敗 (bash 3.2 等の旧バージョン) |
| `pr_comment_commit_sha_mismatch` | Priority 3 の PR コメント Raw JSON の `commit_sha` が現 HEAD と不一致 (stale detection、WARNING のみで continue) |
| `jq_error_on_commit_sha` | Priority 0/2/3 の `.commit_sha` 抽出 jq が IO/binary エラーで失敗 (I-4 対応。stale detection 無効化を silent にしない。`priority=0|2|3` として retained flag に付記される) |
| `pr_comment_tempfile_read_io_error` | Priority 3 で `pr_comment_body_file` の cat が IO エラーで失敗 (permission 変更 / NFS timeout / TOCTOU truncate) |
| `pr_number_placeholder_residue` | ステップ 1.2.0 冒頭の `pr_number="{pr_number}"` literal substitute が忘れられ、数値以外 (空文字 / placeholder 残留) のまま bash block に入った (cleanup.md ステップ 6 / pr-review.md ステップ 6.1.a と対称化、`[fix:error]` 昇格) |
| `review_source_resolve_failed` | ステップ 1.2.0 caller が `scripts/review-source-resolve.sh` の非ゼロ exit を検知した際の caller-side retained-flag (helper が具体 reason を `FIX_FALLBACK_FAILED` で stderr emit 済み、本 reason は drift Pattern 1 充足用の generic guard、`[fix:error]` 昇格) |
| `fatal_triage_failed` | ステップ 1.2.2 helper の非ゼロ終了。原因と finding ID を保持して `[fix:error]`、legacy fallback 禁止 |
| `pr_comment_schema_version_jq_failed` | Priority 3 で PR コメント Raw JSON の `schema_version` 抽出 jq が失敗 (jq バイナリ異常 / OOM / pipe write error、`schema_version="unknown"` で継続し legacy Markdown parser へ fallthrough、`REVIEW_SOURCE_PARSE_FAILED` flag) |
| `broad_retrieval_jq_extraction_failed` | ステップ 1.2.0 Priority 3 Broad Comment Retrieval で `pr_comments` からの rite review コメント抽出 jq が失敗 (jq バイナリ異常 / OOM / GitHub API レスポンスの JSON 破損、tempfile 不在として `BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT` へ routing、`REVIEW_SOURCE_PARSE_FAILED` flag) |
| `git_rev_parse_head_failed` | Priority 3 の commit_sha stale detection 用 `git rev-parse HEAD` が失敗 (stale 判定を skip し `head_sha=""` で継続、`REVIEW_SOURCE_STALE_CHECK_FAILED` flag。`jq_error_on_commit_sha` と同じ stale-check namespace) |

> P0/P2 map reason は helper docstring が SoT。委譲済は **table 行にせず bullet**。

**review-findings-maps.sh reasons**: 共通 triage (1.2.2) の helper が返す reason をそのまま報告する。measured 未判定、scope / severity 不正、map / persist / reload の失敗はいずれも `[fix:error]`。空 map・元 JSON・legacy parser で続行しない。


**Eval-order enumeration** (Pattern-2 documented-union): emit reasons sequence = (`bash_version_incompatible` / `pr_number_placeholder_residue` / `overall_assessment_unknown_value` / `pr_comment_raw_json_awk_failed` / `pr_comment_raw_json_parse_failure` / `pr_comment_schema_required_fields_missing` / `pr_comment_cross_field_invariant_violated` / `pr_comment_critical_high_scope_nit_noted` / `pr_comment_schema_version_unknown` / `user_cancelled` / `user_file_path_invalid` / `review_file_path_empty_value` / `comment_body_tempfile_empty` / `pr_comment_commit_sha_mismatch` / `jq_error_on_commit_sha` / `pr_comment_tempfile_read_io_error` / `review_source_resolve_failed` / `fatal_triage_failed`)

#### Legacy Branching (PR Comment Path Only)


**Branch by `{target_comment_id}`**: Fast Path / Broad Retrieval は本節内の独立 h4。`### 1.2.1` は Broad Retrieval 時のみ。

#### Target Comment Fast Path — when `{target_comment_id}` is set

`{target_comment_id}` が設定され、review source が PR コメントのときだけ [対象コメントの取得・解析・確認手順](references/target-comment.md) を読む。取得、所属 PR 検証、解析、confidence 確認、handoff と cleanup まで実行する。Broad Retrieval は実行しない。未設定時は次の Broad Retrieval へ進む。

#### Broad Comment Retrieval — when `{target_comment_id}` is NOT set

When the standard flow is active (no `target_comment_id`), retrieve PR review comments as before:

```bash
# confidence_override tempfile の orphan 防止: Fast Path 経路と同様、ステップ 1.2 進入時に
# **無条件 truncate** (specific path 必須 — wildcard glob は絶対に使わない)
: > "${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt" 2>/dev/null || \
  echo "WARNING: ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt の truncate に失敗しました (read-only / permission denied?)" >&2

# Broad Retrieval 経路の exit code check (Fast Path と同じ fail-fast + stderr 退避 + canonical 4 行 trap)
gh_api_err=""
_rite_fix_broad_retrieval_cleanup() {
  rm -f "${gh_api_err:-}"
}
trap 'rc=$?; _rite_fix_broad_retrieval_cleanup; exit $rc' EXIT
trap '_rite_fix_broad_retrieval_cleanup; exit 130' INT
trap '_rite_fix_broad_retrieval_cleanup; exit 143' TERM
trap '_rite_fix_broad_retrieval_cleanup; exit 129' HUP

gh_api_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-broad-retrieval-err-XXXXXX") || {
  echo "エラー: Broad Retrieval stderr 一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=mktemp_failed_gh_api_err" >&2
  exit 1
}

# レビューコメント（PR レビューに紐づくコメント）
# node_id はスレッド解決時の GraphQL mutation で必要
if ! gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --jq '.[] | {id, node_id, path, line, original_line, body, user: .user.login, created_at, in_reply_to_id, pull_request_review_id}' 2>"$gh_api_err"; then
  echo "エラー: レビューコメントの取得に失敗しました (gh api pulls/{pr_number}/comments)" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi

# PR レビュー自体のコメント
if ! gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews --jq '.[] | {id, node_id, state, body, user: .user.login, submitted_at}' 2>"$gh_api_err"; then
  echo "エラー: PR レビューの取得に失敗しました (gh api pulls/{pr_number}/reviews)" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi

# 通常のコメント（PR コメント欄）を一括取得して保存（ステップ 1.2.1 で再利用）
if ! pr_comments=$(gh pr view {pr_number} -R {owner_repo} --json comments --jq '.comments' 2>"$gh_api_err"); then
  echo "エラー: PR コメントの取得に失敗しました (gh pr view --json comments)" >&2
  echo "詳細 (gh pr view stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi
echo "$pr_comments" | jq '.[] | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'

# pr_review_comment_body は tempfile 経由で Priority 3 block へ hand-off する (specific path 必須)。
# 書き出し失敗時は WARNING で continue (tempfile が無ければ Priority 3 が fail-fast する)。
# rationale: references/design-rationale.md#pr-comment-raw-json-extraction
pr_comment_body_file="${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt"
jq_broad_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-broad-jq-err-XXXXXX" 2>/dev/null) || jq_broad_err=""
if rite_review_body=$(printf '%s' "$pr_comments" | jq -r '
  [.[] | select(.body | contains("## 📜 rite レビュー結果"))]
  | sort_by(.createdAt) | last | .body // empty
' 2>"${jq_broad_err:-/dev/null}"); then
  if [ -n "$rite_review_body" ]; then
    if ! printf '%s' "$rite_review_body" > "$pr_comment_body_file"; then
      echo "WARNING: pr_review_comment_body tempfile への書き出しに失敗: $pr_comment_body_file" >&2
      echo "  対処: /tmp の容量 / permission を確認してください" >&2
      echo "  影響: ステップ 1.2.0 Priority 3 が tempfile を読めず fail-fast する可能性があります" >&2
    else
      echo "[CONTEXT] PR_REVIEW_COMMENT_BODY_FILE=$pr_comment_body_file" >&2
    fi
  else
    # rite review result コメントが PR に存在しない (legitimate な legacy / 初回経路)
    # tempfile を作成しないことで、ステップ 1.2.0 Priority 3 は別のソース判定経路を辿る
    :
  fi
else
  jq_extract_rc=$?
  echo "WARNING: pr_comments から rite review コメント抽出 jq が失敗しました (rc=$jq_extract_rc)" >&2
  if [ -n "$jq_broad_err" ] && [ -s "$jq_broad_err" ]; then
    echo "  jq stderr (先頭 3 行):" >&2
    head -3 "$jq_broad_err" | sed 's/^/    /' >&2
  fi
  echo "  原因候補: jq バイナリ異常 / OOM / GitHub API レスポンスの JSON 破損" >&2
  echo "  影響: ステップ 1.2.0 Priority 3 が tempfile 不在として BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT に routing される" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=broad_retrieval_jq_extraction_failed; rc=$jq_extract_rc" >&2
fi
[ -n "$jq_broad_err" ] && rm -f "$jq_broad_err"
```

`$pr_comments` はシェル変数ではなく context 保持。1.2 と 1.2.1 は同一 Bash 呼び出しにするか、context から再注入する。

```bash
# スレッド情報と解決状態を取得（GraphQL）
# 注: first: 100 の制限があるため、100件を超える大規模 PR では取得漏れの可能性あり
gh_api_err=""
_rite_fix_broad_graphql_cleanup() {
  rm -f "${gh_api_err:-}"
}
trap 'rc=$?; _rite_fix_broad_graphql_cleanup; exit $rc' EXIT
trap '_rite_fix_broad_graphql_cleanup; exit 130' INT
trap '_rite_fix_broad_graphql_cleanup; exit 143' TERM
trap '_rite_fix_broad_graphql_cleanup; exit 129' HUP

gh_api_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-broad-retrieval-err-XXXXXX") || {
  echo "エラー: Broad Retrieval stderr 一時ファイルの作成に失敗しました" >&2
  exit 1
}

if ! gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              id
              body
              author { login }
              path
              line
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F pr={pr_number} 2>"$gh_api_err"; then
  echo "エラー: reviewThreads の取得に失敗しました (gh api graphql)" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi
```

### 1.2.1 Retrieve rite Review Results

Retrieve the `/rite:pr-review` results from PR comments and extract severity information:

1. Search PR comments for those containing `## 📜 rite レビュー結果`
2. Parse the tables for each reviewer type within the "all findings" section
3. Extract the severity (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) for each finding
4. Preserve each finding separately by ID; file:line is only a thread lookup hint

**Search method:**

```bash
# ステップ 1.2 で取得済みの pr_comments から rite レビュー結果を検索（API 呼び出しなし）
# 注: $pr_comments はコンテキスト保持データ。ステップ 1.2 と同一 Bash ツール呼び出しで実行するか、
#     コンテキストから値を再注入すること（各 bash ブロックを個別に実行する場合、シェル変数は引き継がれない）
echo "$pr_comments" | jq '[.[] | select(.body | contains("## 📜 rite レビュー結果"))] | sort_by(.createdAt) | last | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'
```

複数の rite 結果コメントがあるときは最新 `createdAt`。

**Parsing the Markdown table:**

The rite review result comment (output format of `/rite:pr-review`) has the following structure:

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: {マージ可 / 条件付きマージ可 / 修正必要}

### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}

| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| CRITICAL | current-pr | src/auth.ts:42 | エラーハンドリングが不足 | try-catch を追加 |
```

**Parsing algorithm (schema 1.1.0, 5-column format):**

1. Identify the `### 全指摘事項` section from the comment body
2. Iterate through each reviewer section delimited by `#### {Reviewer Type}`
3. Parse the table rows within each section (split by `|`)
4. Determine column count by header row to support both schema 1.0 (4-column) and 1.1.0 (5-column):
   - **5-column (schema 1.1.0)**: severity (column 1), **scope (column 2)**, file:line (column 3), content (column 4), recommended action (column 5)
   - **4-column (schema 1.0 backward compat)**: severity (column 1), file:line (column 2), content (column 3), recommended action (column 4) — `scope` is back-filled from severity using the default mapping in [`severity-levels.md` §自動 default mapping](../../references/severity-levels.md#自動-default-mapping-schema-10-後方互換)
5. finding ごとに元の ID、severity、scope、file、line、message、recommendation、verification、status、出自を保持する。ID が無い Markdown 行には reviewer と出現順から一意な ID を付け、同じ file:line の別指摘を統合しない。
6. `### 実測なし指摘 (non-blocking)` は前方一致で 6 列パースし、`non_blocking_findings[]` に保持する。gated な rite 出力の `### 全指摘事項` / `### 実測なし指摘 (non-blocking)` は既存のセクション契約に従い、それぞれ明示的な `verification.measured=true` / `false` として移す。元の JSON がある場合はその verification をそのまま使い、欠落を見出しから補わない。未検証の legacy 表・自由文には measured を推測で付けない。

rite 結果がない場合も空の `findings` / `non_blocking_findings` を持つ JSON を作成してステップ 1.2.2 を通す。人間・外部ツールのコメントは rite finding に変換せず、未解決の外部レビューとして保持する。

### 1.2.2 Common Fatal Triage and Recording

**全通常入力経路の合流点**。P0 明示ファイル、P1 会話、P2 ローカル JSON、P3 Raw JSON / legacy Markdown、Target Comment Fast Path は分類・選択・0 件終了の前に必ず本節を実行する。`--nb-sweep` の専用経路は変更しない。

1. P0/P2 は選択した元のファイルを `{triage_review_path}` とし、producer を変更しない。P1/P3 は解析結果を JSON オブジェクト（`findings[]` / `non_blocking_findings[]`、PR 番号、commit SHA、元の gate receipt と verification を保持）にし、`state-path-resolve.sh` が返すルートの `.rite/review-results/` に `{pr_number}-{timestamp}.json`（timestamp は `YYYYMMDDHHMMSS`、同名があれば一意になるまで新しい時刻を取得） として atomic write する。Write 失敗は `[fix:error]` で終了する。新規 JSON のトップレベルに `producer: "fix"` を設定する（元 JSON に producer があっても上書き）。元ソースの `{review_source}` は provenance として保持する。
2. P0 の helper source は `explicit_file`、それ以外は `local_file`。次を実行する。helper は **元 JSON に persist してから** ID-keyed `fatal_map` / `severity_map` / `scope_map` を返す。`fatal = verification.measured == true AND severity ∈ {CRITICAL, HIGH} AND scope ∈ {current-pr, follow-up}` の判定はこの helper だけが担い、LLM は再分類しない。gated な非 fatal を `demotion_reason: "non_fatal"` 付きで `non_blocking_findings[]` へ移送し、nit は保持する。

```bash
triage_review_path="{triage_review_path}"
if triage_maps=$(bash {plugin_root}/scripts/review-findings-maps.sh \
  --review-source "{triage_helper_source}" \
  --review-source-path "$triage_review_path"); then
  :
else
  printf '%s\n' "$triage_maps"
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_failed" >&2
  echo "[fix:error] reason=fatal_triage_failed"
  exit 1
fi
# 永続化された結果を reload。会話・raw_json の旧 findings を後続へ渡さない。
if ! triaged_review=$(jq -c '.' "$triage_review_path"); then
  echo "[fix:error] reason=triage_reload_failed"
  exit 1
fi
printf '%s\n' "$triage_maps"
echo "[CONTEXT] FIX_TRIAGE_REVIEW_PATH=$triage_review_path" >&2
```

helper の `[fix:error] reason=measured_undetermined; findings=...` は該当 ID をそのまま報告して停止する。scope / severity / IO の異常も停止する。**triage エラーから legacy parser / Interactive Fallback への遷移は禁止**。missing/null/string の measured を true や false に補完しない。

3. helper の `FIX_FATAL_TRIAGE=applied; fatal=N; moved=M` から `{fatal_count}=N` / `{non_fatal_moved_count}=M` を保持する。reload した `non_blocking_findings[]` の nit 以外の件数を `{non_blocking_count}` とし、全経路で同じ母集団を使う。P0 など元ファイルが `.rite/review-results/` 外の場合は、コピー側のトップレベルを `producer: "fix"` にした更新後 JSON を同ディレクトリに atomic copy し、そのパスを `{triage_review_path}` に更新する。後続 review / nb sweep が読める永続ファイルを残す。
4. [Non-fatal Record](references/non-fatal-record.md) を実行し、既存の関連 Issue コメントを更新する。JSON / Issue 記録 / 表示の non-blocking section / E2E 1 行の **4 経路**に同じ件数・JSON pointer を渡す。Issue 記録失敗時は fatal が 0 件でも `[fix:error]`。記録を終える前に 0 件扱いで return しない。
5. `.rite/fix-cycle-state/{pr_number}.json` の top-level `non_fatal_moved_count` / `review_json_path` に今回の値を atomic merge する（既存 `cycles` を保持、新規なら `cycles:[]`）。書込失敗は `[fix:error]`。修正コミットが無い cycle でも必須。ステップ 3.3.1 は同じ値を cycle entry にも記録する。

```bash
triage_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || {
  echo "[fix:error] reason=triage_state_root_failed"
  exit 1
}
triage_state_dir="$triage_state_root/.rite/fix-cycle-state"
mkdir -p "$triage_state_dir" || { echo "[fix:error] reason=triage_state_write_failed"; exit 1; }
triage_state_file="$triage_state_dir/{pr_number}.json"
triage_state_tmp=""
_rite_fix_triage_state_cleanup() {
  rm -f "${triage_state_tmp:-}"
}
trap 'rc=$?; _rite_fix_triage_state_cleanup; exit $rc' EXIT
trap '_rite_fix_triage_state_cleanup; exit 130' INT
trap '_rite_fix_triage_state_cleanup; exit 143' TERM
trap '_rite_fix_triage_state_cleanup; exit 129' HUP
triage_state_tmp=$(mktemp "$triage_state_dir/.triage-XXXXXX") || {
  echo "[fix:error] reason=triage_state_write_failed"
  exit 1
}
triage_existing='{"pr_number":{pr_number},"cycles":[]}'
if [ -f "$triage_state_file" ]; then
  triage_existing=$(cat "$triage_state_file") || {
    echo "[fix:error] reason=triage_state_read_failed"
    exit 1
  }
fi
if ! printf '%s\n' "$triage_existing" | jq \
  --argjson moved "{non_fatal_moved_count}" --arg pointer "{triage_review_path}" \
  '.non_fatal_moved_count = $moved | .review_json_path = $pointer' > "$triage_state_tmp" \
  || [ ! -s "$triage_state_tmp" ] \
  || ! mv "$triage_state_tmp" "$triage_state_file"; then
  echo "[fix:error] reason=triage_state_write_failed"
  exit 1
fi
```

### 1.3 Classify Comments

helper の ID-keyed `fatal_map` / `severity_map` / `scope_map` と reload 済み JSON を参照する。

| Classification | Criteria | Action |
|---------------|----------|--------|
| **Required fix** | `fatal_map[id] == true` | 修正対象 |
| **nit (認知のみ)** | `scope_map[id] == "nit-noted"` | PR reply / fix 対象外。`acknowledged_nit_count` に算入 |
| **non-blocking (非 fatal・実測なし)** | 永続 JSON の `non_blocking_findings[]`（nit 除外） | 記録・表示のみ。修正選択肢に出さない |
| **External review** | 未解決の人間・外部ツールのコメント | Action required |
| **Resolved** | `isResolved: true` | 対応済み |

1. Resolved thread は Resolved、`LGTM` / `+1` / `👍` のみは Informational。
2. **人間 thread の巻き添え防止**: rite finding 由来と確認できない未解決 thread は、同じ file:line の fatal / non-fatal / nit があっても **External review (blocking)**。出自確認は map / nit 参照より先に行う。判定不能も External review とする。振り替えがあれば `[CONTEXT] MEASURED_RECLASSIFIED_TO_EXTERNAL=1; count={n}; cause=provenance_unconfirmed` を stderr に emit する。
3. rite finding は ID で上表を適用する。file:line（null / 0 行は anchor）や ±3 行の近似一致は thread 対応候補にだけ使い、finding の集約や fatal 判定には使わない。
4. rite 結果が無い場合も未解決 thread / CHANGES_REQUESTED は External review として対応する。空 map を triage エラーの fallback に使わない。

### 1.3.S `--nb-sweep` consume（5.S 専用）

`--nb-sweep` が設定された場合だけ [NB sweep 手順](references/nb-sweep.md) を読み、分類・起票または記録・consume・未消化検査を実行する。正常時はステップ 5.1 で `[fix:sweep-done]` を返し、通常修正へ進まない。未設定ならステップ 1.4 へ進む。

### 1.4 Display Comment List

**Behavior branching based on caller:**

| Caller | Option Selection | Target |
|--------|-----------------|--------|
| Within `/rite:iterate` review-fix loop | **Skip** (auto-select) | Fatal findings + unresolved external reviews |
| Manual `/rite:fix` | Display | User-selected |


---

```
PR #{number} のレビューコメント

## 未対応の指摘 ({count}件)

### 必須修正（CRITICAL/HIGH）({count}件)
| # | 重要度 | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|-----|----------|------------|
| 1 | {severity} | {path} | {line} | {body_preview} | @{user} |

### nit (認知のみ) ({nit_noted_count}件)
<!-- scope == "nit-noted" の finding はサマリ表示のみ。
     ステップ 2.1 auto-select / ステップ 2.4 reply の対象外。PR に reply しない。
     fix commit 対象からも完全除外、ステップ 4.6 サマリで acknowledged_nit_count (= nit_noted_count) として独立カウント。 -->
| # | 重要度 | スコープ | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|----------|-----|----------|------------|
| 1 | {severity} | nit-noted | {path} | {line} | {body_preview} | @{user} |

### non-blocking (非 fatal・実測なし) ({non_blocking_count}件)
今回の移送: {non_fatal_moved_count}件。記録 JSON: {triage_review_path}
修正対象外の指摘は関連 Issue の記録コメントと上記 JSON に保持しています。

### 外部レビュー({count}件)
| # | ファイル | 行 | 内容 | レビュアー |
|---|----------|-----|------|------------|
| 1 | {path} | {line} | {body_preview} | @{user} |

## 対応済み ({count}件)
{resolved_count} 件の指摘が解決済みです

---

対応を開始しますか？

オプション:
- fatal 指摘と未解決の外部レビューに対応（推奨）
- fatal 指摘・外部レビューから個別選択
- キャンセル
```

**Option descriptions:**

| Option | Target | Use Case |
|--------|--------|----------|
| **fatal 指摘と未解決の外部レビューに対応（推奨）** | Fatal findings + unresolved external reviews | iterate 中は自動選択 |
| **fatal 指摘・外部レビューから個別選択** | 同じ対象集合から選択 | 特定指摘のみ対応 |
| **キャンセル** | - | Abort the process (Fast Path 経由の場合はハンドオフファイルを削除してから exit) |

**「キャンセル」選択時の Behavior** (silent orphan ファイル防止):

Fast Path 経由でキャンセルした場合、1.5 を通らないので **1.4 末尾で一時ファイル + confidence_override を削除**する。

```bash
# ステップ 1.4 「キャンセル」選択時の cleanup (silent orphan ファイル防止)
# Fast Path bash block 外なので変数は失われている → specific path で直接削除する
# (wildcard glob 絶対禁止。Broad Retrieval 経路ではファイル不在のため rm -f は silent no-op)
rm -f "${TMPDIR:-/tmp}/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-raw-{pr_number}-{target_comment_id}.json" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt"
```

**FINALIZE handoff (E2E のみ)**: `[fix:cancelled-by-user]` は 5.1 を通らないので**ここで**セット。standalone では実行しない (AC-4)。

```bash
# E2E flow 時のみ: FINALIZE 終了通知 handoff をセット (Stop hook が ステップ5 中断通知を 1 回だけ強制)
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix cancelled by user. caller (/rite:iterate ステップ5) で中断通知を出力する。Do NOT stop before 出力." \
  --handoff "FINALIZE:fix:cancelled-by-user:{pr_number}" \
  --if-exists
```

```bash
# cleanup + (E2E 時は handoff set) 後に exit
echo "[fix:cancelled-by-user]"
exit 0
```


**When there are no comments:**

本分岐も 1.2.2 の記録と state persistence 完了後だけ実行する。fatal / 外部レビューが 0 件で non-blocking が残る場合は「コメントなし」と表示せず、移送件数と JSON pointer を報告して 4.6 → 5.1 の通常完了へ進む。

```
PR #{number} にはレビューコメントがありません

考えられる状況:
- まだレビューが実施されていない
- すべての指摘が解決済み

次のステップ:
- `/rite:pr-review` でセルフレビューを実行
- `/rite:ready` でレビュー待ちに変更
```

E2E では 4.6 → 5.1 で終了 sentinel を返す。standalone は記録件数・JSON pointer を表示して終了する。

### 1.5 Fast Path Handoff File Cleanup (ステップ 1 終端)

**条件**: Fast Path で一時ファイルを作り、1.4 をキャンセル以外で完走したとき。他経路は `rm -f` no-op。

**specific path 必須** (wildcard 禁止)。`{pr_number}-{target_comment_id}` で消す。

```bash
# ステップ 1.5: Fast Path Handoff File Cleanup
# 実行条件: Fast Path 経由 (target_comment_id が set されている場合) のみ。
# Broad Comment Retrieval 経路では silent no-op (rm -f は idempotent)。
# {pr_number} / {target_comment_id} は Claude が ステップ 1.0 の parse 結果で事前置換済み。
# 注: confidence_override tempfile はここでは削除しない (fix ループ全体で参照。削除は ステップ 5.1 /
# ステップ 4.6 後)。
rm -f "${TMPDIR:-/tmp}/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-raw-{pr_number}-{target_comment_id}.json" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt"
```

`rm -f` は idempotent。

---

## ステップ 2: 修正支援

### Fail-Fast Response Principle

指摘に対する修正を決定する前に、以下のチェックリストを必ず通過させること:

- [ ] throw/raise で呼び出し元に伝播する選択肢を検討したか
- [ ] 既存の try/catch を新設するのではなく、既存のエラー境界に到達させる方が自然ではないか
- [ ] 追加しようとしている null チェック / optional chaining は、問題を修正するのではなく "隠蔽" していないか
- [ ] テストが throw を許さない形で書かれている場合、テスト側を修正する方が正しくないか

**fallback を追加する場合**、commit message に「なぜ throw ではなく fallback を選んだか」を明示すること。無思考な防御コード追加は ステップ 5 の re-review で再指摘される。

**fallback 推奨が正当化されるケース**:

- skill 側に明示された「fallback 許容条件」がある（例: UI の graceful degradation）
- 外部 API 呼び出しで、stale cache を返すことが requirement に明示されている
- ユーザー向けエラー表示で、技術的詳細を隠蔽する必要がある

該当しない fallback は Wiki で許容パターンを確認する。opt-out 不可。

### Simplification-First Response Principle（追加より削除を先に検討）

以下はすべての fix finding に適用する mandate であり、config で opt-out できない:

- **MUST**: finding が名指しした範囲の最小差分に留める。
- **MUST**: 削除で解消できる finding は削除で直す。原因が過剰構造ならその構造を除去する。
- **MUST NOT**: 新 guard / fallback / 説明コメントの追加は finding が新挙動・新契約を要求する場合のみに限定する。

指摘に対する修正方針を決定する前に、以下のチェックリストを必ず通過させること（Fail-Fast Response Principle と同様、config での opt-out は不可）:

- [ ] 機構の**追加**（新しい分岐・ガード・規約・注記・例外条項）ではなく、既存機構の**削除・単純化**（分岐の統合、規則の一般化、複製の一本化）で指摘を解消できないか検討したか。「規則の一般化」は機械が評価する規則（分岐・ガード・述語）に限る。文書の主張（契約文・確認手順など人が読む記述）の最小差分は削除・限定を先に取る。主張を広げる／述語化するなら、主張が名指しする集合を実装で列挙し一致を確認した上で書く
- [ ] 追加しようとしている分岐 / ガード / 規約は、指摘された 1 ケース専用になっていないか（1 ケース対応の追加は、次 cycle でその追加自体が新たなレビュー対象面となり指摘を再生産する）
- [ ] 修正 diff は指摘の解消に必要な最小か。指摘されていない「ついで」の防御・柔軟性・将来対応を含んでいないか

対象は**機構の追加**。テスト追加・複製同期は対象外。[coding-principles.md](../../skills/rite-workflow/references/coding-principles.md) の `no_speculative_structure` と対。

**Escalation trigger（パッチの重ね掛け停止）**: 対応中の finding が**同一 PR の前 cycle の fix が導入・変更した箇所**への指摘である場合（description が「cycle N で導入した」「前 cycle で追加した」等で当該 fix を名指しする場合を含む）、同じ機構への追加パッチを既定選択にしないこと。まず「当該機構ごと削除・単純化して指摘群を根から消せないか」を検討し、修正案の提示（ステップ 2.3）の前にその判断を chat へ 1 行明示する（例: `simplification-first: 削除 — 分岐機構を削除し行全体再生成へ単純化` / `simplification-first: 追加 — 理由: {なぜ削除ではないか}`。書式はステップ 3.2 の必須段落と同一）。

Escalation trigger 成立時は、この判断を commit body の `simplification-first:` 段落（ステップ 3.2）として書く。ステップ 3.2.1 Root Cause Gate が段落の有無を検査する。

rationale: references/design-rationale.md#simplification-first-rationale

### 2.1 Confirm Fix Approach

reviewer の推奨対応（`recommendation` 列）は候補であって設計ではない。文書の主張を書く／広げる修正案は、適用前に実装と突き合わせる（ステップ 2.3）。

**Entry routing — scope=nit-noted skip**:

**`scope == "nit-noted"` は 2.1 / 2.4 を skip**（PR reply しない。カウントは 2.4.N）:

1. 未解決の External review は通常通り対応する。rite finding の map で skip しない。
2. rite finding の `scope_map[id] == "nit-noted"` は 2.1 / 2.4 を skip し、2.4.N で認知件数に算入する。
3. `fatal_map[id] == true` のみ通常の修正・accept/rejection 判断へ進む。
4. `non_blocking_findings[]` は選択 UI / fix commit / reply の対象外。記録は 1.2.2 で完了済み。
5. map 欠落を blocking の代替条件にしない。必要な triage 結果が無ければ `[fix:error]`。


---

Confirm the fix approach for each finding (only for findings whose scope is NOT `nit-noted`):

```
指摘 #{n}: {file}:{line}

レビュアー: {reviewer_display}
内容:
{comment_body}

この指摘への対応方針を選択してください:

オプション:
- コードを修正する
- accept (認知のみ)
- 説明・返信のみ（修正不要）
```

**選択肢の意味論差** (accept を「説明・返信のみ」と区別):

| 選択肢 | finding 終着 | reply | commit trailer | 次 cycle 自動 suppression |
|--------|------------|-------|----------------|--------------------------|
| コードを修正する | status: `fixed` | 人間由来 thread のみ ステップ 2.4（rite 由来は skip） | （該当なし） | 該当なし (修正済) |
| accept (認知のみ) | status: **`acknowledged`** (scope を `nit-noted` に override) | "accepted, will not be fixed in this PR." | `Acknowledged-finding: F-NN (file:line) — reason` (ステップ 3.2) | **あり** (fingerprint 永続化) |
| 説明・返信のみ | status: `replied` | 説明 (修正不要の根拠) | （該当なし） | なし (次 cycle で再出現可) |


**`{reviewer_display}` の展開ルール** (Fast Path 経由で `target_author_mention_skip == "true"` の場合の silent `@unknown` 誤記録防止):

| 条件 | 展開結果 (日本語) | 展開結果 (英語) |
|------|-----------------|----------------|
| Broad Comment Retrieval 経由 (通常の `{user}`) | `@{user}` | `@{user}` |
| Fast Path 経由 かつ `target_author_mention_skip == "false"` | `@{target_author}` | `@{target_author}` |
| Fast Path 経由 かつ `target_author_mention_skip == "true"` | `(不明なレビュアー)` | `(unknown reviewer)` |

Claude は ステップ 1 末尾で skip_file を、`{target_author}` が必要な箇所では author_file を、それぞれ Read tool で読む (パスは Block C の `[CONTEXT] BLOCK_C_COMPLETE` marker の `skip_file=` / `author_file=` / `body_file=` 値をリテラル使用する — Read tool は `${TMPDIR:-/tmp}` を展開できないため、handoff 3 本すべて marker 値経由で読む。specific path 必須、wildcard glob は並列セッション破壊のため絶対禁止)。skip_file が `"true"` の場合は本 phase 以降のすべての mention 生成箇所で `@` prefix を生成しない。

**複数 reviewer 時の `{reviewer_display_N}` 展開ルール** (ステップ 3.2 trailer で使用):

| reviewer 数 | trailer の展開 (日本語) | trailer の展開 (英語) |
|------------|-------------------------|----------------------|
| 0 (該当 reviewer なし) | trailer 行自体を**省略** | trailer 行自体を**省略** |
| 1 | `{reviewer_display_1} のレビューコメントに対応` | `Addresses review comments from {reviewer_display_1}` |
| 2 | `{reviewer_display_1}, {reviewer_display_2} のレビューコメントに対応` | `Addresses review comments from {reviewer_display_1}, {reviewer_display_2}` |
| 3+ | `{reviewer_display_1}, {reviewer_display_2}, {reviewer_display_3}, ... のレビューコメントに対応` (出現順カンマ区切り) | 同様 |

**`{reviewer_display_N}` の出現順序ルール**:
- **Broad Retrieval 経由**: PR コメントの `created_at` 昇順 (古い順) で `_1`, `_2`, ... を割り当て
- **Fast Path 経由**: 単一 author のみ (常に N=1)。`target_author_mention_skip == "true"` のときは `(不明なレビュアー)` で展開
- **混在ケース**: Broad Retrieval 経路は単一の ステップ 1.2 で完結し Fast Path 経路と排他のため、混在は発生しない

**末尾カンマの省略**: reviewer 数が template 中の `{reviewer_display_N}` 個数より少ない場合、余った placeholder と直前のカンマ + スペース (`, `) を**まとめて削除**する (例: template が `_1, _2` で reviewer 1 名なら `_1` のみ生成、`, _2` 部分を削除)。

### 2.1.A accept (認知のみ)

対応方針が `accept` の場合だけ [認知のみの対応手順](references/accept-finding.md) を読み、理由付き返信と fingerprint の記録・上限警告を実行する。コード修正を選んだ場合はステップ 2.2 へ進む。

### 2.2 Identify Fix Location

When "コードを修正する" is selected:

1. Read the target file using Read tool
2. Display lines around the flagged location
3. Propose a fix

```
修正対象:
ファイル: {path}
行: {line}

現在のコード:
（{lang} のコードブロックで表示）
{code_context}

指摘内容:
{comment_body}

修正案を検討しています...
```

### 2.2.A Pre-Fix Impact Scan (全体俯瞰でデグレ・仕様ドリフト防止)

**Purpose**: 修正案を確定する前に必ず周辺の影響範囲 (caller / test / sibling / cross-file) を列挙する。 <!-- rationale: references/design-rationale.md#impact-scan-rationale -->

**Mandatory before applying any fix**:

1. **修正対象 symbol の `git grep` 列挙** (function / class / variable / constant /
   config key):

   ```bash
   # 修正対象 file から symbol を抽出 (Claude が静的に決定)
   # symbol 不在ケース (file:line のみの finding / Markdown rewording / config 値変更等) は
   # Step 1 末尾「symbol 不在ケースの fallback」を参照
   target_symbol="{symbol_name}"   # 例: "validate_input", "API_TIMEOUT", "UserRepo"

   # caller / test / sibling を全部列挙する。git grep の rc は `if cmd; then :; else rc=$?; fi`
   # 形式で捕捉する (bang pipeline は then-branch 内で $? が常に 0 を返すため使用禁止)
   if git grep -nE "\\b${target_symbol}\\b" -- \
     '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' \
     '*.sh' '*.bash' '*.md' '*.yml' '*.yaml' '*.json' > "${TMPDIR:-/tmp}/rite-fix-impact-scan-$$.txt" 2>"${TMPDIR:-/tmp}/rite-fix-impact-scan-err-$$.txt"; then
     :  # match あり (rc=0) — 結果は tmpfile に展開済、Step 2 へ
   else
     rc=$?
     case "$rc" in
       1) : ;; # match なし (期待動作)、空の影響範囲として Step 2 へ
       128|*)
         echo "WARNING: git grep failed (rc=$rc): $(cat "${TMPDIR:-/tmp}/rite-fix-impact-scan-err-$$.txt" 2>/dev/null)" >&2
         echo "[CONTEXT] IMPACT_SCAN_DEGRADED=1; reason=git_grep_rc_$rc" >&2
         echo "  Claude は grep 不可の影響範囲を手動確認し、確認結果と根拠を構造化出力すること" >&2
         ;;
     esac
   fi
   rm -f "${TMPDIR:-/tmp}/rite-fix-impact-scan-$$.txt" "${TMPDIR:-/tmp}/rite-fix-impact-scan-err-$$.txt"
   ```

   **symbol 不在ケースの fallback** (finding が file:line のみで symbol を含まない場合):
   - (a) 同ファイル内の関連シンボル列挙 → caller 探索を反復
   - (b) 複数 symbol を含む大規模 fix → 各 symbol について Step 1 を反復
   - (c) Markdown / config rewording → 該当 file 名で grep + CHANGELOG / docs 内の参照を確認

2. **影響範囲の確認結果を出力**: 修正案の前に必ず以下の確認結果と根拠を
   構造化して chat へ明示する (ユーザーが追跡できる形で):

   ```
   修正対象 symbol: {symbol_name}
   影響範囲:
   - caller: {file_path:line_range} ({n} 箇所)
   - test: {test_path:line_range} ({n} 箇所)
   - sibling (同一ファイル内の関連箇所): {n} 箇所
   - cross-file 参照: {他 file 名} ({n} 箇所)

   修正方針が影響範囲に与える影響:
   - {caller_file_1}: {影響の有無、必要な追従修正}
   - {test_file_1}: {test も更新が必要か、test の期待値は変わるか}
   - {他 file}: {同上}
   ```

3. **Markdown / config 文書化された参照** (`reference:` リンク / API 仕様書 / docs
   / CHANGELOG など) も grep 対象に含める。コード以外で型・仕様が宣言されている
   場合、修正がドキュメント側と drift しないか確認する。

4. **省略可能なケース** (極めて限定): 修正範囲が **typo 修正のみ** (文字列リテラル
   1 箇所の誤字、Markdown 内の typo、docstring 内の typo) と Claude が判断した
   場合に限り、step 1-3 を省略してよい。「コメント追加」「未参照 import 削除」
   「同一ファイル内の小規模変更」は省略対象から除外し、必ず step 1-3 を実行する
   (これらは過去 fix-introduced regression の主要発生源)。

   省略経路に入る場合も、判断根拠 (`local-only: typo-only: {対象文字列}`) を
   chat に明示出力する。確認結果と根拠の記録は省略不可。

   省略しない場合、「同一ファイル内のみ」と早期確定しない。grep 結果と影響範囲は必須。

### 2.3 Apply the Fix

修正案が文書の主張を書く／広げる／述語化するものなら、適用前に主張が名指しする集合（実装の経路・出力・判定値）を実装で列挙し、主張と一致するか確認する。列挙結果は修正案の提示に併記する。不一致なら修正案を適用せず、主張を限定するか削除する案に差し替える。

**MUST**: 生成するコメント / 散文に Issue/PR 番号・AC 番号を書かない。残す背景は現在形の制約文。ジャーナル/経緯文は禁止。

**MUST**: `action` は `fix` / `reply` / `accept` / `nit-noted` の 4 値に閉じる（他の値は ステップ 4.6 の gate が `map_missing` で停止させる）。`action: fix` の finding は 1 件以上の変更箇所を `path:line` または `path:start-end` で記録し、ステップ 3.3.1 の `findings_addressed[]` に `{id, action, changes}` として載せる。行番号は **HEAD の行**。ただし**行を削除しただけの箇所は HEAD に対応行が無い**ため、`commit_sha_before` の行で記録する（gate は純削除 hunk だけを削除前の行番号で突合する。行を書き換えた箇所は HEAD の行でしか通らない）。reply / accept / nit-noted は `changes: []` とし `diff_verified` を付けない。

Present the proposed fix and apply with Edit tool after confirmation:

```
修正案:
（{lang} のコードブロックで表示）
{suggested_fix}

この修正を適用しますか？

オプション:
- 適用する
- 修正案を変更
- スキップ
```

### 2.3.1 Propagation Scan

After applying a fix (ステップ 2.3), perform a mandatory scan for similar patterns to prevent distributed propagation failures.

Check if `review.loop.auto_propagation_scan` is enabled in `rite-config.yml` (default: `true`). If disabled, skip to ステップ 2.4.

**Step 1: Identify the fix pattern**

Characterize what was changed in ステップ 2.3:

| Fix Type | Description | Example |
|----------|-------------|---------|
| **Structural pattern** | Added error handling, retained flag emit, if-wrap, trap handler | `exit 1` の前に `[CONTEXT] *_FAILED=1` emit を追加 |
| **Content fix** | Corrected a value, updated a reference, renamed identifier | reason table のエントリを追加・修正 |
| **Configuration** | Changed config key, constant, or threshold | schema version 更新 |

**Step 2: Search for similar patterns**

Based on the fix type, determine the search scope and search:

| Fix Type | Search Scope | Method |
|----------|-------------|--------|
| Structural pattern (same file) | All code blocks in the same file | `Grep` for the unfixed version of the pattern in the same file |
| Structural pattern (cross-file) | Files in the same directory + files that reference the fixed file | `Grep` in related files |
| Content fix / Configuration | Files referencing the same key, table, or identifier | `Grep` across the codebase for the old/new value |

**Step 3: Apply propagation fixes**

For each similar location found where the fix has NOT been applied:
1. Apply the same fix pattern using the Edit tool
2. Log: `伝播修正: {file}:{line} — {pattern_description}`

**Step 4: Output propagation summary**

```
伝播スキャン結果:
- 修正パターン: {pattern_description}
- スキャン対象: {scope} ({file_count} files)
- 伝播適用: {propagated_count} 箇所
- 既に適用済み: {already_applied_count} 箇所
```

If `propagated_count == 0` and `already_applied_count == 0`, output a single line: `伝播スキャン: 類似パターンなし`


### 2.4 Create Reply (Optional)

**人間由来ゲート (MUST, POST 前)**: 対象 thread の root（なければ対象コメント本文）に次のいずれかを含む → 返信しない。
- `## 📜 rite レビュー結果`
- `## 📜 rite 非実測指摘の記録`
- `## レビュー指摘対応完了`
- `nit、認知済 (scope=nit-noted`
- `📜 rite 作業メモリ`

判定不能 → 人間由来として返信する。
skip 時は POST bash を実行せず `[CONTEXT] REPLY_SKIPPED=1; comment_id={comment_id}; reason=rite_origin` を stderr emit。
2.1.A accept reply も本ゲートを通す。
rationale: references/design-rationale.md#human-origin-reply-gate

**Reply 本文の SoT**: 返信は `templates/review/reply.md` の Why-only テンプレートに従う。
本文は **Why の 1〜3 文** で、Issue 番号 / PR 番号 / 修正履歴を記載しない。

**禁止句リスト SoT**:
`{plugin_root}/skills/rite-workflow/references/comment-best-practices.md` の
「禁止句リスト (SoT)」節 (原則 2 `no_journal_comment` 内) を唯一の SoT とする。
本 ステップ 2.4 (reply 本文) と ステップ 2.3 (in-source コメント) は **同一の禁止句リスト**
を共有する。reply.md は本 SoT への参照に簡略化済。

After completing the fix, propose a reply to the reviewer:

```
レビュアーへの返信を作成しますか？

提案される返信:

{why_only_explanation}

オプション:
- この返信を投稿
- 返信を編集
- 返信しない
```

`{why_only_explanation}` は「なぜそう直したか」を 1〜3 文で表現する。
**禁止句**: `{plugin_root}/skills/rite-workflow/references/comment-best-practices.md`
の「禁止句リスト (SoT)」節を参照 (in-source コメントと共通)。

When posting the reply:

**Note**: The following code block is a template. When Claude executes it, `{reply_body}` should be replaced with the actual reply content. `cat <<'REPLYEOF'` is a **single-quoted HEREDOC**, so bash variable expansion does not occur. Claude should replace the placeholder as an LLM and then construct the command.

```bash
# PR レビューコメントへの返信（in_reply_to で元コメントを指定）
# jq --rawfile で安全に JSON を生成し、gh api に渡す
# trap + cleanup パターンの canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
tmpfile=""
_rite_fix_phase24_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_fix_phase24_cleanup; exit $rc' EXIT
trap '_rite_fix_phase24_cleanup; exit 130' INT
trap '_rite_fix_phase24_cleanup; exit 143' TERM
trap '_rite_fix_phase24_cleanup; exit 129' HUP

tmpfile=$(mktemp) || {
  echo "ERROR: tmpfile mktemp 失敗 (/tmp が read-only / inode 枯渇 / permission 拒否)" >&2
  # mktemp 失敗経路にも retained flag を emit (rationale: references/design-rationale.md#retained-flag-emission)
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id; reason=mktemp_failed_reply_tmpfile" >&2
  exit 1
}

# cat HEREDOC の exit code を捕捉 (truncated tmpfile の silent POST 防止)
if ! cat <<'REPLYEOF' > "$tmpfile"
{reply_body}
REPLYEOF
then
  echo "ERROR: reply body の HEREDOC 書き込みに失敗 (/tmp full / permission 拒否 / inode 枯渇)" >&2
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id; reason=cat_redirection_failed" >&2
  exit 1
fi

# 追加 post-condition: HEREDOC 成功扱いだが空ファイル (seek race / quota 等) も捕捉
if [ ! -s "$tmpfile" ]; then
  echo "ERROR: reply body tmpfile が空です (HEREDOC 書き込み後 post-condition 違反)" >&2
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id; reason=reply_tmpfile_empty" >&2
  exit 1
fi

# pipefail を有効化して jq | gh api パイプの前段失敗を確実に検出
set -o pipefail
if ! jq -n --rawfile body "$tmpfile" --argjson in_reply_to "$comment_id" \
  '{"body": $body, "in_reply_to": $in_reply_to}' | gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  -X POST \
  --input -; then
  echo "ERROR: reply 投稿 (jq | gh api POST) に失敗しました" >&2
  echo "  対処: gh auth status / network 接続 / rate limit / PR #{pr_number} の存在を確認してください" >&2
  echo "  影響: レビュアーへの返信が PR に残らないまま fix loop が完了扱いになる silent regression のリスク" >&2
  # retained flag emit (ステップ 5.1 評価順テーブルで detect され [fix:error] へ昇格する)
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id" >&2
  set +o pipefail
  exit 1
fi
set +o pipefail
```

reply は `mktemp` + HEREDOC → `jq --rawfile`。`$comment_id` は `--argjson`。

### 2.4.N nit-noted-no-reply

`scope == "nit-noted"` は PR に reply しない。`acknowledged_nit_count = {nit_noted_count}`（ステップ 1.3 / 1.4）。Issue 化しない。commit しない。

rationale: references/design-rationale.md#nit-noted-no-reply-notes

---

## ステップ 3: 修正のコミット

> **Reference**: Apply [Comment Best Practices](../../skills/rite-workflow/references/comment-best-practices.md) when finalising fix commits — 生成コメント/散文に Issue/PR 番号・AC 番号を残さない。残す背景は現在形の制約文。ジャーナル/経緯文は禁止。file:line 参照と未検証ジャーゴンも diff に残さない。review/fix 履歴は commit message / PR description へ。

### 3.1 Verify Changes

**前置ガード**: working tree 無変更なら **ステップ 3 全体を skip** して 4.5 へ (全経路)。判定は **`git-status-filtered.sh`** (raw porcelain 禁止)。

```bash
# helper の rc 非 0 (mktemp 失敗等) は dirty 側 = ガード非発火 = 従来どおりステップ 3 実行 に倒す
# (working tree の状態が判定できないまま commit を skip すると、実際にあった変更を取りこぼすため)
dirty=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh) || dirty="__RITE_STATUS_UNKNOWN__"
if [ -z "$dirty" ]; then
  echo "[CONTEXT] FIX_COMMIT_GUARD=skip; reason=worktree_clean" >&2
elif [ "$dirty" = "__RITE_STATUS_UNKNOWN__" ]; then
  # helper が rc 非 0 (mktemp 失敗 / git repo 外 等)。安全側 = ステップ 3 実行 に倒すが、
  # 「本当に汚れている」と「検出不能だった」を機械可読チャネル上で区別する
  echo "[CONTEXT] FIX_COMMIT_GUARD=proceed; reason=status_unknown" >&2
else
  echo "[CONTEXT] FIX_COMMIT_GUARD=proceed; reason=worktree_dirty" >&2
fi
```

`FIX_COMMIT_GUARD=skip` ならステップ 3 の commit / push を skip して ステップ 4.5 へ進む。**skip でも `findings_addressed` は最新 cycle として永続化する**（4.6 の gate が `map_missing` に倒れるのを防ぐ）。commit が無いので `commit_sha_before` / `commit_sha_after` はともに HEAD、`files_changed_by_fix` は `[]`。既存 cycle の `findings_addressed` は上書きせず、新しい cycle entry を append する。`proceed` なら以下を通常どおり実行する。

```bash
# FIX_COMMIT_GUARD=skip のときだけ。{findings_addressed_json} は ステップ 2.3 で記録した配列
# （fix は path:line / path:start-end、reply/accept/nit-noted は changes: []。diff_verified は書かない）。
# JSON は single-quote に直接埋めず、HEREDOC + --rawfile で渡す（ステップ 2.4 の reply と同じ形）。
# trap + cleanup パターンの canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
mkdir -p "$_state_root/.rite/fix-cycle-state"
pr_number="{pr_number}"
state_file="$_state_root/.rite/fix-cycle-state/${pr_number}.json"
head_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
if [ -f "$state_file" ]; then
  existing=$(cat "$state_file")
else
  existing='{"pr_number":'"$pr_number"',"cycles":[]}'
fi
addressed_file=""
state_tmp=""
_rite_fix_skip_addressed_cleanup() {
  rm -f "${addressed_file:-}" "${state_tmp:-}"
}
trap 'rc=$?; _rite_fix_skip_addressed_cleanup; exit $rc' EXIT
trap '_rite_fix_skip_addressed_cleanup; exit 130' INT
trap '_rite_fix_skip_addressed_cleanup; exit 143' TERM
trap '_rite_fix_skip_addressed_cleanup; exit 129' HUP
addressed_file=$(mktemp "${TMPDIR:-/tmp}/rite-fix-addressed-XXXXXX") || {
  echo "ERROR: findings_addressed 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! cat <<'ADDRESSEDEOF' > "$addressed_file"
{findings_addressed_json}
ADDRESSEDEOF
then
  echo "ERROR: findings_addressed の HEREDOC 書き込みに失敗" >&2
  echo "[fix:error]"
  exit 1
fi
new_cycle=$(jq -n \
  --arg ts "$timestamp" \
  --arg head "$head_sha" \
  --rawfile addressed_raw "$addressed_file" \
  --argjson moved "{non_fatal_moved_count}" \
  --arg review_json "{triage_review_path}" \
  '{
    "cycle": 0,
    "timestamp": $ts,
    "commit_sha_before": $head,
    "commit_sha_after": $head,
    "findings_fixed": 0,
    "non_fatal_moved_count": $moved,
    "review_json_path": $review_json,
    "findings_new_from_fix": 0,
    "files_changed_by_fix": [],
    "lines_added": 0,
    "lines_deleted": 0,
    "propagation_applied": 0,
    "findings_addressed": ($addressed_raw | fromjson)
  }') || {
  echo "ERROR: cycle entry の生成に失敗 (findings_addressed が不正な JSON)" >&2
  echo "[fix:error]"
  exit 1
}
# 既存 state を直接開かない。生成に失敗したまま redirect すると履歴ごと truncate される。
# 既存 state が空だと jq は rc=0 のまま何も出さないため、空出力も -s で設置前に止める。
state_tmp=$(mktemp "${state_file%/*}/.cycle-XXXXXX") || {
  echo "ERROR: cycle state 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! printf '%s\n' "$existing" | jq --argjson entry "$new_cycle" '
  (.cycles | length) as $len |
  .cycles += [$entry | .cycle = ($len + 1)] |
  if (.cycles | length) > 20 then .cycles = .cycles[-20:] else . end
' > "$state_tmp" || [ ! -s "$state_tmp" ] || ! mv "$state_tmp" "$state_file"; then
  rm -f "$state_tmp"
  echo "ERROR: cycle state の書き込みに失敗 (jq 失敗 / 出力が空 / mv 失敗)" >&2
  echo "[fix:error]"
  exit 1
fi
printf '[CONTEXT] FIX_CYCLE_STATE_WRITTEN file=%s cycle=%d skip=1\n' "$state_file" "$(jq '.cycles | length' "$state_file")"
```

`proceed` なら commit 前 HEAD を marker に残し、3.3.1 が `{fix_cycle_base_sha_from_context}` に使う。

```bash
fix_cycle_base_sha=$(git rev-parse HEAD) || { echo "[fix:error]"; exit 1; }
printf '[CONTEXT] FIX_CYCLE_BASE_SHA=%s\n' "$fix_cycle_base_sha"
```

Once all findings have been addressed, verify the changes:

```bash
git status
git diff
```

```
修正内容の確認

変更ファイル:
| ファイル | 変更内容 |
|----------|----------|
| {path} | {change_summary} |

対応した指摘: {count}件
```

**番号参照 self-check**（`FIX_COMMIT_GUARD=proceed` のあと、3.1.1 の前）。`{base_branch}` は rite-config `branch.base`、無ければ PR base（ステップ 1.1 `.baseRefName`）。origin-first は lint Phase 2.2 と同じ。未追跡ファイルは `--diff` 直前に `git add -N` で差分へ載せる（母集合は 3.3 と同じ `{changed_files}`。worktree に残っているパスだけ。空なら skip）。

```bash
nref_base="origin/{base_branch}"
git rev-parse --verify "${nref_base}^{commit}" >/dev/null 2>&1 || nref_base="{base_branch}"
if [ -n "{changed_files}" ]; then
  nref_addn=""
  for f in {changed_files}; do
    [ -e "$f" ] && nref_addn="$nref_addn $f"
  done
  if [ -n "$nref_addn" ]; then
    nref_stage_rc=0
    git add -N -- $nref_addn || nref_stage_rc=$?
    if [ "$nref_stage_rc" -ne 0 ]; then
      echo "ERROR: intent-to-add に失敗しました (rc=$nref_stage_rc)。新規ファイルが検査されないため commit しません" >&2
      echo "[fix:error]"
      exit 1
    fi
  fi
fi
nref_rc=0
bash {plugin_root}/hooks/scripts/number-reference-check.sh --diff "$nref_base" || nref_rc=$?
case "$nref_rc" in
  0) ;;
  1)
    echo "ERROR: 追加行に Issue/PR 番号参照がある。コミットしない。ステップ 2.3 で書き直す。" >&2
    echo "[CONTEXT] NUMBER_REF_CHECK=hits" >&2
    ;;
  *)
    echo "ERROR: number-reference-check.sh failed (rc=$nref_rc)" >&2
    echo "[fix:error]"
    exit 1
    ;;
esac
```

| Exit | Action |
|------|--------|
| `0` | 3.1.1 へ |
| `1` | コミットしない。2.3 に戻り追加行を書き直す。書き直しでもヒットが残るなら `[fix:error]`。番号付き行をコミットする fallback は禁止 |
| `2` | `[fix:error]`（git / usage 失敗） |

### 3.1.1 Pre-Commit Schema Version Check

Before committing, verify that `.rite/review-results/*.json` schema versions are within the accepted list, mechanically. This prevents schema drift from entering the review cycle, saving an entire review-fix round trip.

1. Check if `review.loop.pre_commit_drift_check` is enabled in `rite-config.yml` (default: `true`). If disabled, skip to ステップ 3.2.

2. Run the check:

```bash
bash {plugin_root}/hooks/scripts/review-schema-version-check.sh --all --quiet
drift_exit=$?
printf '[CONTEXT] PRE_COMMIT_DRIFT_CHECK exit=%d\n' "$drift_exit"
```

3. Handle the exit code:

| Exit Code | Action |
|-----------|--------|
| `0` (clean) | Proceed to ステップ 3.2. |
| `1` (drift detected) | Re-run **without** `--quiet` to display findings. Return to ステップ 2 to fix the detected drifts. This is an **automated self-correction** — NOT a new review cycle. Do not increment `loop_count`. |
| `2` (invocation error) | Emit `[CONTEXT] PRE_COMMIT_DRIFT_CHECK_ERROR=1` as WARNING and proceed to ステップ 3.2. Do not block the commit. |


### 3.2 Generate Commit Message

Generate a commit message based on the addressed findings.

fallback を選んだら commit body に「なぜ throw ではないか」を書く。無注釈の防御コードは re-review で再指摘される。

**Commit message language:**

Before generating the commit message, check the `language` field in `rite-config.yml` using the Read tool to determine the language:

| Setting | Behavior |
|---------|----------|
| **`auto`** | Detect the user's input language and generate in the same language |
| **`ja`** | Generate commit message in Japanese |
| **`en`** | Generate commit message in English |

**Language determination logic for `auto` setting:**

1. **Determination timing**: At commit message generation time, detect the most recent user input
2. **Determination method**: Determine by the following priority

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Contains Japanese characters (hiragana, katakana, kanji) | Japanese |
| 2 | Otherwise | English |


**Examples by language:**

| Language setting | Commit message example |
|-----------------|----------------------|
| **`en`** or `auto` (English input) | `fix(review): address review feedback` |
| **`ja`** or `auto` (Japanese input) | `fix(review): レビュー指摘に対応` |

**Commit body:**

Use a free-form commit body. Review-fix commits **MUST** include:
- **対応方針** — 各 finding に対して何をしたか / なぜその方針か
- **`Root cause:` / `根本原因:` 段落** — ステップ 3.2.1 Root Cause Gate が検査する
- **`simplification-first:` 段落（Escalation trigger 成立時のみ）** — `simplification-first: 削除 — {何を削ったか}` または `simplification-first: 追加 — 理由: {なぜ削除ではないか}` の 1 段落。ステップ 3.2.1 Root Cause Gate が検査する。trigger 不成立の cycle では書かない

- Leave a blank line between the description line and the body
- Write in free-form — no specific prefix or template required
- Focus on "why" the change was needed, not "what" was changed (the description line already covers "what")
- Follow the same language setting as the description line
- Why は必須（省略経路なし）。review-fix の対応方針 / Root cause は省略しない

**Trailer**: Generate in the configured language using the unified `{reviewer_display_N}` placeholder (展開ルールは ステップ 2.1 の `{reviewer_display}` 展開ルール表を参照 — Broad Retrieval 経由で `@{user}`、Fast Path 経由 + `target_author_mention_skip == "true"` で `(不明なレビュアー)` / `(unknown reviewer)` に展開される):

- English: `Addresses review comments from {reviewer_display_1}, {reviewer_display_2}`
- Japanese: `{reviewer_display_1}, {reviewer_display_2} のレビューコメントに対応`

**展開ルールの単一源**: ステップ 2.1 の表。ここへ literal を複製しない。
rationale: references/design-rationale.md#reviewer-display-single-source

**Acknowledged-finding trailer (accept で `status: acknowledged` 化された finding 用)**:

ステップ 2.1 で `accept (認知のみ)` を選択した finding が 1 件以上含まれる commit では、commit message の trailer に以下の形式の行を **per-acknowledged-finding で反復生成** する (Co-Authored-By / Addresses review comments trailer と並存):

```
Acknowledged-finding: F-NN (file:line) — reason
```

- `F-NN`: review-result-schema.md の `findings[].id` (例: `F-01`、100 件以上は `F-100`)
- `file:line`: 当該 finding の対象ファイル:行 (ステップ 2.1 で表示されたもの)。**`line == null` (anchor finding) の場合は `(file:anchor)` 表記** に正規化する (ステップ 2.1.A bash block の line_no 正規化と統一)
- `reason`: ステップ 2.1.A Step 1 で生成した `accept_reason_rendered`。必ず `accept_reason_class` を含み、detail が空でも class 単独を記録する。`no reason given` / 空 reason 経路は禁止

**反復生成ルール**:

- 1 commit に複数の acknowledged finding が含まれる場合、`Acknowledged-finding:` 行を finding 数だけ繰り返す
- 同 commit に non-accept finding (修正 / 返信のみ) も含まれる場合、`Acknowledged-finding:` 行は他 trailer と blank line で区切らずに連続させる (grep 容易性のため):

```
fix(review): レビュー指摘に対応 (acknowledged 含む)

F-01 の入力バリデーションを追加。F-02 は reviewer の指摘範囲を本 PR scope 外と
判断し accept として受け流した。

Acknowledged-finding: F-02 (src/foo.ts:42) — out-of-scope: reviewer scope is outside the current PR
Acknowledged-finding: F-05 (src/bar.ts:88) — user-override

Addresses review comments from @reviewer1
```

**grep 可能性**: `Acknowledged-finding:` 行は厳密な literal で、`git log --grep='^Acknowledged-finding:'` で audit 検索可能。trailer 行の前に space / tab を入れてはいけない (行頭 anchor が崩れる)。

```
コミットメッセージ案:

fix(review): {description}

{free-form body — 対応方針 + `Root cause:` / `根本原因:` 段落 + (Escalation trigger 成立時) `simplification-first:` 段落}

{acknowledged_finding_lines (展開ルール: accept finding 0 件 → 完全省略 (前後 blank line も削除、conventional commits lint の連続空行 fail を防ぐ)。1 件以上 → 各 `Acknowledged-finding:` 行を `\n` 区切りで連結、末尾改行なし)}

{trailer}

このメッセージでコミットしますか？

オプション:
- このメッセージでコミット
- メッセージを編集
- 個別にコミット（複数コミットに分割）
```

### 3.2.1 Root Cause Gate

Before committing a fix, the commit body **MUST** include a root-cause explanation. This gate implements Quality Signal 2 (root-cause-missing fix detection) — see the Quality Signal 1-4 table in `skills/pr-review/references/finding-cycling.md`.

**Step 1**: 3.2 の commit body に `Root cause:` / `根本原因:` 段落があるか LLM が判定する (Bash 状態非依存)。Escalation trigger 成立時は `simplification-first:` 段落の有無も判定し、いずれかの欠落を `missing` とする。trigger 不成立の cycle では `simplification-first:` 段落を要求しない。

Emit one of the two context markers so downstream logic can route:

```bash
# LLM-side determination: examine the commit body generated in ステップ 3.2 and emit one of:
echo "[CONTEXT] ROOT_CAUSE_GATE=ok"
# or
echo "[CONTEXT] ROOT_CAUSE_GATE=missing"
```

**Step 2**: When `ROOT_CAUSE_GATE=missing`, warn the user via `AskUserQuestion` with exactly three options:

| Option | Action |
|--------|--------|
| 不足段落を追記して再コミット（推奨） | Ask the user for a short paragraph for whichever Step 1 found missing: prepend a `Root cause: {paragraph}` / `根本原因: {paragraph}` paragraph, or (Escalation trigger 成立時) a `simplification-first: {paragraph}` paragraph, to the commit body; re-invoke Step 1. The retry count is tracked in conversation context by the LLM — after one retry the LLM falls through to the second option to avoid an infinite prompt loop |
| 意図的な補足コミットとして通過 | Prepend a bypass paragraph for whichever Step 1 found missing — `Root cause (bypass): {理由}`, or (Escalation trigger 成立時) `simplification-first (bypass): {理由}` — to the commit body (the bypass rationale recorded alongside the commit for machine-traceability) AND append the same rationale to work memory `決定事項・メモ`. The bypass is still recorded |
| Abort | Skip this fix cycle; emit `[fix:error]` and return control to the caller |

cosmetic は option 2 可。bypass は記録必須。


### 3.3 Execute the Commit

```bash
git add {changed_files}
git commit -m "$(cat <<'EOF'
{commit_message}
EOF
)"
```

### 3.3.1 Fix-Cycle State Persistence

After committing, record the current fix cycle's data to `.rite/fix-cycle-state/{pr_number}.json` for convergence monitoring and cross-session context preservation.

```bash
# fix-cycle-state もリポジトリ共通 state ルート基準 (pr-review.md ステップ 5.3.8 の読取側と同一解決)
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
mkdir -p "$_state_root/.rite/fix-cycle-state"

pr_number="{pr_number}"
state_file="$_state_root/.rite/fix-cycle-state/${pr_number}.json"
commit_sha_after=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
commit_sha_before="{fix_cycle_base_sha_from_context}"
if ! git cat-file -e "${commit_sha_before}^{commit}" 2>/dev/null; then
  echo "ERROR: FIX_CYCLE_BASE_SHA が未展開または無効です: $commit_sha_before" >&2
  echo "[fix:error]"
  exit 1
fi
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
files_changed=$(git diff --name-only "$commit_sha_before"..HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
# 既存の cycle state に当該 fix cycle 全体の行数差分を記録する。バイナリの `-` は行数に含めない。
diff_stats=$(git diff --numstat "$commit_sha_before"..HEAD 2>/dev/null | awk '
  $1 ~ /^[0-9]+$/ { added += $1 }
  $2 ~ /^[0-9]+$/ { deleted += $2 }
  END { printf "%d %d", added, deleted }
')
lines_added=${diff_stats%% *}
lines_deleted=${diff_stats##* }

# Read existing state or initialize
if [ -f "$state_file" ]; then
  existing=$(cat "$state_file")
else
  existing='{"pr_number":'"$pr_number"',"cycles":[]}'
fi

# Append new cycle entry (propagation_applied is set by ステップ 2.3.1 context)
# {findings_addressed_json} は ステップ 2.3 で記録した配列（diff_verified は書かない。gate が書き戻す）
# JSON は single-quote に直接埋めず、HEREDOC + --rawfile で渡す（ステップ 2.4 の reply と同じ形）。
# trap + cleanup パターンの canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
addressed_file=""
state_tmp=""
_rite_fix_cycle_addressed_cleanup() {
  rm -f "${addressed_file:-}" "${state_tmp:-}"
}
trap 'rc=$?; _rite_fix_cycle_addressed_cleanup; exit $rc' EXIT
trap '_rite_fix_cycle_addressed_cleanup; exit 130' INT
trap '_rite_fix_cycle_addressed_cleanup; exit 143' TERM
trap '_rite_fix_cycle_addressed_cleanup; exit 129' HUP
addressed_file=$(mktemp "${TMPDIR:-/tmp}/rite-fix-addressed-XXXXXX") || {
  echo "ERROR: findings_addressed 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! cat <<'ADDRESSEDEOF' > "$addressed_file"
{findings_addressed_json}
ADDRESSEDEOF
then
  echo "ERROR: findings_addressed の HEREDOC 書き込みに失敗" >&2
  echo "[fix:error]"
  exit 1
fi
new_cycle=$(jq -n \
  --arg ts "$timestamp" \
  --arg before "$commit_sha_before" \
  --arg after "$commit_sha_after" \
  --argjson fixed "{findings_fixed_count}" \
  --argjson propagated "{propagation_applied_count}" \
  --argjson files "$files_changed" \
  --argjson added "$lines_added" \
  --argjson deleted "$lines_deleted" \
  --argjson moved "{non_fatal_moved_count}" \
  --arg review_json "{triage_review_path}" \
  --rawfile addressed_raw "$addressed_file" \
  '{
    "cycle": 0,
    "timestamp": $ts,
    "commit_sha_before": $before,
    "commit_sha_after": $after,
    "findings_fixed": $fixed,
    "non_fatal_moved_count": $moved,
    "review_json_path": $review_json,
    "findings_new_from_fix": 0,
    "files_changed_by_fix": $files,
    "lines_added": $added,
    "lines_deleted": $deleted,
    "propagation_applied": $propagated,
    "findings_addressed": ($addressed_raw | fromjson)
  }') || {
  echo "ERROR: cycle entry の生成に失敗 (findings_addressed が不正な JSON)" >&2
  echo "[fix:error]"
  exit 1
}

# Append and assign cycle number, enforce ring buffer (max 20 entries)
# 既存 state を直接開かない。生成に失敗したまま redirect すると履歴ごと truncate される。
# 既存 state が空だと jq は rc=0 のまま何も出さないため、空出力も -s で設置前に止める。
state_tmp=$(mktemp "${state_file%/*}/.cycle-XXXXXX") || {
  echo "ERROR: cycle state 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! printf '%s\n' "$existing" | jq --argjson entry "$new_cycle" '
  (.cycles | length) as $len |
  .cycles += [$entry | .cycle = ($len + 1)] |
  if (.cycles | length) > 20 then .cycles = .cycles[-20:] else . end
' > "$state_tmp" || [ ! -s "$state_tmp" ] || ! mv "$state_tmp" "$state_file"; then
  rm -f "$state_tmp"
  echo "ERROR: cycle state の書き込みに失敗 (jq 失敗 / 出力が空 / mv 失敗)" >&2
  echo "[fix:error]"
  exit 1
fi

printf '[CONTEXT] FIX_CYCLE_STATE_WRITTEN file=%s cycle=%d\n' "$state_file" "$(jq '.cycles | length' "$state_file")"
```


### 3.4 Confirm Push

```
変更をリモートにプッシュしますか？

オプション:
- プッシュする（推奨）
- 後でプッシュ
```

When pushing:

```bash
git push origin HEAD
```

> upstream 前提の bare `git push` は使わない。sandbox 有効環境では upstream tracking が未設定（open/pr-create が `-u` を使わなくなったため）で bare push が失敗する。

### 3.5 Cycle Branch Cleanup (Post-Push)

commit+push 後に reviewer の cycle worktree / branch を掃除する。non-blocking。

```bash
# {plugin_root} はリテラル値で埋め込む (詳細は ../../references/plugin-path-resolution.md)
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

---

## ステップ 4: 完了報告

### 4.1 Resolve Threads (Optional)

Confirm whether to resolve addressed threads:

```
対応したスレッドを解決済みにしますか？

対象: {count}件のスレッド

オプション:
- すべて解決済みにする
- 個別に選択
- スキップ（レビュアーに任せる）（推奨）

**注**: 多くのチームではレビュアーがスレッドを解決する慣習があります。
```

When resolving threads (GraphQL mutation):

```bash
# 注: thread_id は GraphQL の Node ID を使用（ステップ 1.2 で取得した reviewThreads.nodes[].id）
gh api graphql -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      isResolved
    }
  }
}' -f threadId="{thread_id}"
```

**When thread resolution fails:**

```
警告: スレッド {thread_id} の解決に失敗しました

考えられる原因:
- スレッドが既に解決済み
- 権限不足（レビュアーまたは PR 作成者のみ解決可能な場合）
- ネットワークエラー

オプション:
- この失敗を無視して続行
- 手動で解決（GitHub UI で操作）
- キャンセル
```

### 4.5 Automatic Work Memory Update


If a related Issue exists, automatically update the work memory.

#### 4.5.1 Identify Related Issue

`scripts/fix-work-memory-update.sh` が PR 本文の `Closes #XX` / `Fixes #XX` / `Resolves #XX` の先頭候補を優先し、通常の未一致だけでブランチの `issue-{number}` へ fallback する。未特定・I/O 失敗では更新せず `WM_UPDATE_FAILED=1` を emit する。
rationale: references/design-rationale.md#work-memory-update-rationale

#### 4.5.2 Retrieve and Update Work Memory Comment

進捗ステータスはステップ 3 の検証済み変更一覧から判断し、不足時は `rite-config.yml` の base（未設定時 `develop`）を解決し、helper と同じ `git diff --name-status "origin/{base_branch}...HEAD"` を取得する。履歴本文は 4.5.3 のテンプレートから生成する。本文をコードへ展開せず、Write ツールで下記の所有ファイルへ保存する（履歴は `### レビュー対応履歴` 見出しなし）。別 Bash のローカル変数は引き継がない。

1. `mktemp` で PR 本文ファイルを確保する。失敗時は `WM_UPDATE_FAILED=1; reason=mktemp_failed_pr_body_tmp` を stderr に出し、更新を実行せず 5.1 へ進む。取得済み PR 本文を保存し、空/書込失敗は空ファイルとして helper に渡す。
2. `mktemp` で履歴ファイルを確保し本文を保存する。準備失敗時は確保済みの履歴ファイルを削除してからパスを空文字にする。helper は進捗更新成功後にだけ `wm_sync_history_failed` と判定するため、この時点で失敗フラグを追加しない。
3. 以下を単一 Bash 呼び出しで実行する。`{pr_body_file}` / `{history_file}` は今回確保したパス（履歴準備失敗は空文字）、`{plugin_root}` は解決済みの絶対パスで置換する。helper が所有する一時ファイルは helper 自身が回収する。

```bash
pr_body_file="{pr_body_file}"
history_file="{history_file}"
trap 'rc=$?; rm -f "$pr_body_file" "$history_file"; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
wm_update_rc=0
wm_update_out=$(bash "{plugin_root}/scripts/fix-work-memory-update.sh" \
  --pr-body-file "$pr_body_file" --history-file "$history_file" \
  --impl-status "{impl_status}" --test-status "{test_status}" --doc-status "{doc_status}") || wm_update_rc=$?
printf '%s\n' "$wm_update_out"
if ! printf '%s\n' "$wm_update_out" | grep -qE '^\[CONTEXT\] FIX_WM_UPDATE=(success|skipped|failed); issue_number=[0-9]*$'; then
  echo "ERROR: work memory helper の結果を取得できませんでした (rc=$wm_update_rc)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_update_helper_failed" >&2
  [ "$wm_update_rc" -ne 0 ] || wm_update_rc=1
fi
if [ "$wm_update_rc" -ne 0 ]; then
  echo "ERROR: work memory helper が非ゼロ終了しました (rc=$wm_update_rc)" >&2
fi
exit "$wm_update_rc"
```

stdout の `FIX_WM_UPDATE` と `issue_number`、stderr の `WM_UPDATE_FAILED` / reason を会話 context に保持する。`FIX_WM_UPDATE=failed` の場合も `WM_UPDATE_FAILED=1` を保持し、5.1 の既存優先順位で最終結果を選ぶ。非ゼロ終了も成功扱いにしない。結果 marker 不在は起動・引数エラーを含む未実行として扱う。helper は `update-progress` → `append-section` の順に既存 WM helper を呼び、進捗失敗なら履歴を抑止し、`no_comment` は正常な省略として扱う。

**Placeholder descriptions for Claude**:

| Placeholder | Description | Determination |
|-------------|-------------|---------------|
| `{impl_status}` | 実装ステータス | 修正コミットがあれば `✅ 完了` or `🔄 進行中` |
| `{test_status}` | テストステータス | テストファイルの変更があれば `🔄 進行中` or `✅ 完了`、なければ `⬜ 未着手` |
| `{doc_status}` | ドキュメントステータス | ドキュメントファイルの変更があれば `🔄 進行中` or `✅ 完了`、なければ `⬜ 未着手` |
| `{4.5.3 のエントリ}` | レビュー対応履歴エントリ | ステップ 4.5.3 のテンプレートから生成 (先頭の `### レビュー対応履歴` 見出しは付けない) |

**Status detection logic**: Claude determines each status by analyzing `git diff --name-status` output:
- 実装: Target code files have changes → `✅ 完了` (all planned changes done) or `🔄 進行中`
- テスト: Test files (`*.test.*`, `*.spec.*`) have changes → update accordingly
- ドキュメント: Documentation files (`*.md`, `docs/*`) have changes → update accordingly

4.5.3 エントリは見出しなしで履歴ファイルへ保存する。

#### 4.5.3 Update Content

ステップ 4.5.2 の `append-section --section "レビュー対応履歴"` に渡す content-file へ、以下のエントリ本体を書き出す。先頭の `### レビュー対応履歴` 見出し行は **含めない** (helper が既存セクションを特定して末尾に追記するため):

```markdown
#### {timestamp}: /rite:fix 実行
- **対応した指摘**: {count}件
- **レビューソース**: {review_source} ({review_source_path_display})
- **対応内容**:
  | 指摘 | 対応 |
  |-----|------|
  | {comment_preview} | {response_type} |
  <!-- 変更箇所 / 差分確認は ステップ 4.6 完了報告の対応表に置く。本節の列は変えない -->
- **コミット**: {commit_sha}
- **プッシュ**: 完了 / 未実行
- **Confidence override**: {confidence_override_section}
```

**Response types:**
- `修正` - Code was fixed
- `返信` - Explanation/reply only
- `スキップ` - Deferred for later

**`{review_source}` / `{review_source_path_display}` の展開ルール** (schema.md `Priority 1 emit 義務の理由` に記載された provenance log 契約の履行):

ステップ 1.2.0 の `[CONTEXT] REVIEW_SOURCE=` emit が取る 5 つの値それぞれに対する展開ルールは以下の通り。

- Priority 0 (`--review-file <path>` 明示指定): review_source 値 = "explicit_file" / display = "path=${review_source_path}"
- Priority 1 (会話コンテキスト直接参照): review_source 値 = "conversation" / display = "p1_scan_turns=N, p1_scan_found=true/false"
- Priority 2 (`.rite/review-results/` 最新ファイル): review_source 値 = "local_file" / display = "path=${review_source_path}"
- Priority 3 (PR コメント Raw JSON / legacy Markdown): review_source 値 = "pr_comment" / display = "in-memory from PR comment"
- Priority 0 失敗 → Interactive Fallback 経路: review_source 値 = "fallback" / display = "interactive fallback"

Claude は ステップ 1.2.0 の bash block stderr から `[CONTEXT] REVIEW_SOURCE=...; review_source_path=...` を会話コンテキストで読み取り、本 placeholder 展開時に substitute する。

**`{confidence_override_section}` の生成ルール** (ステップ 1.2 best-effort parse の Confidence override 追跡義務):

| 状況 | 展開内容 |
|------|----------|
| `confidence_override_count == 0` | `なし` |
| `confidence_override_count >= 1` | 親 bullet と同一行に **`; ` 区切りで列挙** (改行なし、Markdown bullet 構造を壊さない) |

**`>= 1` のときの展開例** (`confidence_override_findings = ["src/foo.ts:42", "src/bar.ts:18"]` の場合):

```markdown
- **Confidence override**: src/foo.ts:42; src/bar.ts:18
```

`{confidence_override_section}` は findings 一覧のみ (`; ` 区切り、**同一行**)。説明文は 4.5.3 側。

### 4.6 Completion Report

完了報告の**直前**に gate を呼ぶ。最新 cycle の `findings_addressed` を `git diff -U0 {commit_sha_before}..HEAD` と突合し、`diff_verified` を書き戻す。

```bash
bash {plugin_root}/hooks/scripts/fix-report-diff-gate.sh --pr {pr_number}
```

| Marker | Action |
|--------|--------|
| `FIX_REPORT_DIFF_GATE=passed` | 続行。対応表は JSON の `diff_verified: true` |
| `FIX_REPORT_DIFF_GATE=unverified; ids=` | 停止しない。当該 ID を「未対応」に載せ、`対応した指摘` の件数から除外する |
| `FIX_REPORT_DIFF_GATE=error; reason=` | `[fix:error]`。`map_missing` / `state_unreadable` / `diff_failed` / `jq_missing` |

`unverified` / `passed` は ステップ 5.1 の fatal ではない。非 push と unverified を組み合わせても row 6 の `[fix:error]` に倒さない。
rationale: references/design-rationale.md#fix-report-diff-gate

```
PR #{number} のレビュー指摘対応を完了しました

全指摘: {total_count}件
対応した指摘: {count}件
- 修正: {fix_count}件
- 返信: {reply_count}件
- nit 認知 (scope=nit-noted、本 cycle): {acknowledged_nit_count}件
- non-blocking (非 fatal・実測なし、fix 対象外): {non_blocking_count}件
- 今回の非 fatal 移送: {non_fatal_moved_count}件
- 記録 JSON: {triage_review_path}
- accept 認知 (user decision、Issue 完了まで累計): {accept_count}件{accept_warning_suffix}
対応表:
| 指摘 | 対応 | 変更箇所 | 差分確認 |
| {id} | {fix\|reply\|accept\|nit-noted} | {path:line または -} | {✅ \| ❌ 未対応（差分に無い） \| 対象外} |
未対応: {unverified_count}件 ({unverified_ids})
コミット: {commit_sha}
プッシュ: 完了 / 未実行
レビューソース: {review_source} ({review_source_path_display})
Confidence override (policy bypass): {confidence_override_count}件{confidence_override_files_suffix}

次のステップ:
- レビュアーの再レビューを待つ
- 追加の指摘があれば再度 `/rite:fix` を実行
- すべて承認されたら `/rite:ready` でマージ準備
```

**`{accept_count}` / `{accept_warning_suffix}` の展開ルール**:

| 状況 | `{accept_count}` | `{accept_warning_suffix}` |
|------|------------------|--------------------------|
| 0 件 (accept なし) | `0` | 空文字列 |
| 1〜4 件 | `{N}` | 空文字列 |
| 5 件以上 (≥5 警告発火、AC-4) | `{N}` | ` ⚠️ reviewer の精度を疑うべき水準` |

**読み出し方法**: 本読み出しはステップ 2.1.A と別 Bash invocation で実行される可能性があるため、`_state_root` の解決を必ず同一 invocation 内に inline する (pr-review.md 5.1.2.A Step 2 の再 inline と同型。解決行なしで verbatim 実行すると `$_state_root` 未束縛 → `/.rite/state/...` の ENOENT が `2>/dev/null` で握り潰され accept_count が silent に 0 化する):

```bash
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
accept_count=$(wc -l < "$_state_root/.rite/state/accepted-fingerprints-{pr_number}.txt" 2>/dev/null | tr -d '[:space:]')
case "$accept_count" in ''|*[!0-9]*) accept_count=0 ;; esac
```

BSD wc 空白は剥がす (2.1.A Step 7 と対称)。不在/空は `0`。state は Issue 完了まで累積。

`acknowledged_nit_count` (reviewer nit、2.4.N = `{nit_noted_count}`) と `accept_count` (user accept、2.1.A) は独立。

**`{acknowledged_nit_count}` の展開ルール**: `{nit_noted_count}`（ステップ 1.3 / 1.4）をそのまま使う。0 件でも行は省略しない。

0 件でも行は省略しない。5.3 の mergeable 判定には使わない。nit-only の finalize 条件は 5.1 row 4/4.5/5。

**`{confidence_override_count}` / `{confidence_override_files_suffix}` の展開ルール** (Confidence policy override の追跡可視化):

| 状況 | `{confidence_override_count}` | `{confidence_override_files_suffix}` |
|------|------------------------------|--------------------------------------|
| 0 件 (override なし、通常時) | `0` | 空文字列 |
| 1 件以上 (override 適用あり) | `{N}` | ` ({file:line_1}; {file:line_2}; ...)` (先頭スペース付きカッコ内に `; ` 区切りで一覧、ステップ 1.2 の data flow 定義と統一) |

0 件でも行は省略しない。

**Field descriptions:**

| Field | Description | Calculation |
|-------|-------------|-------------|
| `全指摘: {total_count}件` | Total findings | reload 済み JSON の findings + non_blocking_findings（ID ごと、nit を含む）と未解決の外部レビューの件数。全経路共通 |
| `対応した指摘: {count}件` | Number of findings addressed | `fix_count + reply_count + skip_count + acknowledged_nit_count + non_blocking_count`。**`fix_count` は `diff_verified: true` の action:fix のみ**。`diff_verified: false` は「未対応」に載せ、この件数から除外する (nit-noted 分類と non-blocking 分類も「対応」に含めることで、nit-only / non-blocking-only PR でも `全指摘 == 対応指摘` 条件を満たし有限 cycle で収束する — `non_blocking_count` を式に含めないと非実測 finding が「未対応」として残り finalize 分岐が発火せず max_review_cycles まで空転する)。**各項は排他**: `skip_count` は ステップ 2.1 でユーザーが「スキップ」を選んだ finding のみを数え、**non-blocking 分類による ステップ 2.1 skip は含めない** (そちらは `non_blocking_count` が受け持つ)。`acknowledged_nit_count` との排他も同様 (nit-noted は scope による分類で、non-blocking は永続 JSON の別集合) |
| `non-blocking (非 fatal・実測なし): {non_blocking_count}件` | Recorded findings | reload 済み non_blocking_findings の nit 以外。0 件でも表示。今回の移送件数は non_fatal_moved_count、永続参照先は triage_review_path |
| `Confidence override (policy bypass): {N}件` | Number of findings imported via Confidence policy override | ステップ 1.2 best-effort parse で「Confidence 70 のままバイパス」を選択した finding 数 (Confidence 80+ ゲート invariant の policy override 追跡義務)。0 件でも常時表示 |
| `レビューソース: {review_source} (...)` | Provenance of the review findings consumed by this fix run | ステップ 1.2.0 Priority chain で決定された `review_source` 値 (schema.md Priority 1 emit 義務の provenance 契約を ステップ 4.6 で履行)。展開ルールは ステップ 4.5.3 の `{review_source}` / `{review_source_path_display}` 表を参照 |

iterate は本報告で次を決める:
- `プッシュ: 完了` → re-review (範囲は pr-review 1.2.4。fix 側で宣言しない)
- 本 cycle で accept 発生 → re-review
- `プッシュ: 未実行` かつ accept なし かつ `全指摘 == 対応指摘` → 完了

accept 発生の SoT は 5.1 row 4/4.5/5。
rationale: references/design-rationale.md#accept-cycle-markers


### 4.6.W Wiki Ingest Trigger (Conditional)

> **Reference**: [Wiki Ingest](../wiki-ingest/SKILL.md) — `wiki-ingest-trigger.sh` API

After outputting the completion report, trigger Wiki Ingest to capture fix patterns as experiential knowledge.


**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_ingest: true` in `rite-config.yml`. Configuration-based skip is the **only** legitimate skip path — it MUST emit a `WIKI_INGEST_SKIPPED=1` status line and `wiki_ingest_skipped` sentinel so the caller can detect and report (see ステップ 4.6.W.3 below).

**Step 1**: Check Wiki configuration (same pattern as ステップ 0.5.W Step 1, replacing `auto_query` with `auto_ingest`):

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_ingest=""
if [[ -n "$wiki_section" ]]; then
  auto_ingest=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_ingest:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_ingest:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # opt-out default
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest"
```

If `wiki_enabled=false` or `auto_ingest=false`, **emit a skip status line + sentinel and return** (do not silently skip — the caller relies on this signal for ステップ 5.6 reporting):

```bash
if [ "$wiki_enabled" = "false" ]; then
  reason="disabled"
elif [ "$auto_ingest" = "false" ]; then
  reason="auto_ingest_off"
else
  reason=""
fi
if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
  echo "WARNING: fix ステップ 4.6.W Wiki ingest skipped: $reason" >&2
fi
```

If `reason` is non-empty, skip Steps 2 and ステップ 4.6.W.2 and proceed to the end of fix flow. Otherwise continue to Step 2.

Wiki 記録が有効な場合だけ [Wiki 記録・raw commit 手順](references/wiki-recording.md) を読み、残りの ingest・commit・push 再試行を実行する。未完了時の通知まで適用してからステップ 5 へ進む。

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When PR is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When Comment Retrieval Fails | ネットワーク接続を確認; `gh auth status` で認証状態を確認 |
| Error During File Modification | この指摘をスキップして続行 / 手動で修正 (WARNING を stderr に出力) |
| Commit Failure | `git status` で状態を確認; 問題を解決してから再度コミット (WARNING を stderr に出力) |

## ステップ 5: E2E フロー継続 (出力パターン)


**用語**: **soft failure** / **hard fail-fast** / **stale** / **silent regression** を区別する。
rationale: references/design-rationale.md#output-pattern-notes

**Flow detection method:** Claude determines the caller from the conversation context using mechanical pattern matching:

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Conversation history contains a record of `Skill tool` invoking `rite:fix` (recent message) | Within loop → Execute ステップ 5 |
| 2 | Work memory contains `コマンド: /rite:open` (or legacy `rite:open` without prefix slash — writer hook が prefix なしで書く時期の互換) AND any `フェーズ:` value (具体値は writer 実装に依存。Priority 1 が catch しない context-compaction 経路の defensive fallback) | Within loop → Execute ステップ 5 |
| 3 | Otherwise (user directly input `/rite:fix`) | Standalone execution → Skip ステップ 5 |

### 5.0 W Phase Completion Gate (Defense-in-Depth)


**Condition**: Execute only when flow state file exists (indicating e2e flow) AND `wiki.enabled: true` in `rite-config.yml`. When wiki is disabled, W Phase is legitimately skipped (no sentinel expected) — pass the gate unconditionally.

**Check**: Search the conversation context for any of the following sentinel patterns:

- `[CONTEXT] WIKI_INGEST_DONE=1`
- `[CONTEXT] WIKI_INGEST_SKIPPED=1`
- `[CONTEXT] WIKI_INGEST_FAILED=1`
- `[CONTEXT] WIKI_INGEST_PUSH_FAILED=1`

**Routing**:

| Condition | Action |
|-----------|--------|
| At least one `WIKI_INGEST_` sentinel found | Gate passes — proceed to ステップ 5.1 |
| No sentinel found AND `wiki.enabled: true` | **ERROR**: W Phase was skipped. Execute the ACTION below |
| No sentinel found AND `wiki.enabled: false` | Gate passes — wiki disabled, no sentinel expected |

**On ERROR** (no sentinel found, wiki enabled):

```
ERROR: ステップ 5.0 W Phase completion gate failed.
No [CONTEXT] WIKI_INGEST_* sentinel found in conversation context.
This means ステップ 4.6.W (Wiki Ingest Trigger) was NOT executed.
ACTION: Return to ステップ 4.6.W and execute the Wiki Ingest Trigger before outputting the result pattern. Do NOT proceed to ステップ 5.1 without a WIKI_INGEST_* sentinel.
⚠️ LLM MUST NOT output [fix:pushed] or any other result pattern until ステップ 4.6.W has been executed.
```


### 5.1 Output Pattern (Return Control to Caller)

The `fix` flow-state write below records the v3 phase so a `/rite:recover` started after a fix iteration classifies the resume point correctly (`skills/recover/SKILL.md` Phase 5.3 の `fix` 行で `/rite:iterate {pr_number}` が invoke される):

**Handoff マーカー**: 結果に応じて 5 種類に分岐する (Stop hook による consume・再注入の機構解説: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism))。
- **継続** (`[fix:pushed]` / `[fix:pushed-wm-stale]`): `--handoff "/rite:pr-review {pr_number}"` で**ループ継続マーカー**をセットする。
- **正常終了** (`[fix:replied-only]`): `--handoff "FINALIZE:fix:replied-only:{pr_number}"` をセットする。caller の **5.S sweep 後も返信のみの終了理由を保持**する。
- **非 fatal のみ** (`[fix:non-fatal-only]`): `--handoff "FINALIZE:fix:non-fatal-only:{pr_number}"` をセットする。caller の **5.S sweep を経てから**完了通知へ進む。
- **sweep 完了** (`[fix:sweep-done]`): `--handoff "FINALIZE:fix:sweep-done:{pr_number}"` で**終了通知マーカー**をセットする。**ステップ 1 に戻らない**（再フルレビュー禁止）。
- **エラー** (`[fix:error]`): `--handoff` を**付けない** (handoff はデフォルトクリア)。`[fix:error]` は clean terminal ではなく caller (`/rite:iterate` ステップ4) で1回自動再試行し、再失敗時に停止するため、完了通知を強制してはならない。

判定入力は本ステップ時点で確定済み。**(push 完了 or 本 cycle accept) かつ fatal 未 set → 継続 handoff**。push 無しかつ accept なしかつ fatal 未 set → FINALIZE。fatal → `--handoff` なし。`WM_UPDATE_FAILED` は継続を打ち消さない。accept 条件の SoT は row 4/4.5/5 注記。

> `[fix:error]` 早期 exit では pr-review がセットした `/rite:fix` handoff を消さない。default-clear は iterate ステップ 3 の `--handoff` なし set。

```bash
# 継続 ([fix:pushed] / [fix:pushed-wm-stale]: push 完了 OR 本 cycle accept 発生 & fatal フラグ無し) の場合 (継続 handoff):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の iterate ステップ 5.S、成功後も replied-only で完了通知（mergeable へ昇格しない）. Do NOT stop." \
  --handoff "/rite:pr-review {pr_number}" \
  --if-exists

# 非 fatal のみ ([fix:non-fatal-only]: row 4.5) の場合 (FINALIZE。5.S が先):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. [fix:non-fatal-only]->caller の iterate ステップ 5.S NB digest sweep、成功後にステップ 5 完了通知. Do NOT re-enter /rite:pr-review." \
  --handoff "FINALIZE:fix:non-fatal-only:{pr_number}" \
  --if-exists

# 正常終了 ([fix:replied-only]: row 5。非 fatal 移送との混在も含む) の場合 (FINALIZE 終了通知 handoff):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の iterate ステップ 5.S、成功後も replied-only で完了通知（mergeable へ昇格しない）. Do NOT stop." \
  --handoff "FINALIZE:fix:replied-only:{pr_number}" \
  --if-exists

# sweep 完了 ([fix:sweep-done]: NB_SWEEP=1 かつ (NB_SWEEP_RESULT=done または NB_SWEEP_DONE_FILE=1)) の場合 (FINALIZE。ステップ 1 に戻らない):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. Check recent result pattern in context: [fix:sweep-done]->caller の iterate ステップ 5 完了通知. Do NOT re-enter /rite:pr-review." \
  --handoff "FINALIZE:fix:sweep-done:{pr_number}" \
  --if-exists

# エラー ([fix:error]: fatal フラグ有り) の場合 (--handoff 行を省略 = handoff クリア):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の iterate ステップ 5.S、成功後も replied-only で完了通知（mergeable へ昇格しない）. Do NOT stop." \
  --if-exists
```

**Note on `error_count`**: phase transition ごとに 0 リセット (`--preserve-error-count` で保持)。
rationale: references/design-rationale.md#output-pattern-notes

**Also update local work memory** (`.rite/work-memory/issue-{n}.md`) with phase transition:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md) for details and marketplace install notes.

```bash
# hook stderr を tempfile に退避し、lock failure と他 failure を区別して分岐する
# rationale: references/design-rationale.md#output-pattern-notes
hook_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-hook-err-XXXXXX") || {
  echo "WARNING: hook_err mktemp 失敗 — local work memory hook を skip します (E2E flow 続行)" >&2
  hook_err=""
}
if [ -n "$hook_err" ]; then
  # rc 捕捉は `if cmd; then :; else rc=$?; fi` の else 節形式 (「!」否定は $? を反転する)
  if WM_SOURCE="fix" \
      WM_PHASE="fix" \
      WM_PHASE_DETAIL="レビュー修正後処理" \
      WM_NEXT_ACTION="re-review or completion" \
      WM_BODY_TEXT="Post-fix sync." \
      WM_ISSUE_NUMBER="{issue_number}" \
      bash {plugin_root}/hooks/local-wm-update.sh 2>"$hook_err"; then
    : # success
  else
    hook_wm_update_rc=$?
    # exact phrase pattern (canonical: common-error-handling.md#hook-lock-contention-classification-canonical)
    if grep -qiE '(file is locked|lock contention|resource busy)' "$hook_err"; then
      # lock failure (best-effort skip 該当): WARNING のみで継続
      echo "WARNING: local work memory lock contention (best-effort skip, rc=$hook_wm_update_rc)" >&2
    else
      # 非 lock failure: hook 自体の障害 (script 不在 / permission / syntax / internal error)
      echo "WARNING: local work memory update hook failed (non-lock failure, rc=$hook_wm_update_rc):" >&2
      head -5 "$hook_err" | sed 's/^/  /' >&2
      echo "  対処: hooks/local-wm-update.sh の存在 / 実行権限 / 内容を確認してください" >&2
      echo "  影響: local .rite/work-memory/issue-*.md が GitHub comment 側と一時的に不整合になる (E2E flow は続行)" >&2
    fi
  fi
  rm -f "$hook_err"
else
  # hook_err mktemp 失敗時は 2>&1 + head -5 の簡易 fallback で WARNING を可視化する (silent skip 禁止)
  echo "WARNING: hook_err mktemp 失敗により local-wm-update.sh の stderr 詳細が取得できません" >&2
  if hook_combined=$(WM_SOURCE="fix" \
        WM_PHASE="fix" \
        WM_PHASE_DETAIL="レビュー修正後処理" \
        WM_NEXT_ACTION="re-review or completion" \
        WM_BODY_TEXT="Post-fix sync." \
        WM_ISSUE_NUMBER="{issue_number}" \
        bash {plugin_root}/hooks/local-wm-update.sh 2>&1); then
    : # success
  else
    hook_fallback_rc=$?
    echo "WARNING: local-wm-update.sh failed (fallback no-tempfile path, rc=$hook_fallback_rc):" >&2
    printf '%s\n' "$hook_combined" | head -5 | sed 's/^/  /' >&2
    echo "  対処: /tmp の空き容量と hooks/local-wm-update.sh の状態を確認してください" >&2
  fi
fi
```

lock failure は WARNING で継続。non-lock は WARNING + stderr 5 行で継続。分岐は exact phrase ([common-error-handling.md](../../references/common-error-handling.md#hook-lock-contention-classification-canonical))。

行 1.5/1.6 の `NB_SWEEP_DONE_FILE` は会話 marker 欠落時の代替。評価前に永続ファイルの有無を emit する（通常ループは行 1.5 が `NB_SWEEP=1` を要求するため本 marker だけでは分岐しない）:

```bash
_nb_done_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || _nb_done_root=""
if [ -n "$_nb_done_root" ] && [ -f "$_nb_done_root/.rite/state/nb-sweep-done-{pr_number}.txt" ]; then
  echo "[CONTEXT] NB_SWEEP_DONE_FILE=1" >&2
else
  echo "[CONTEXT] NB_SWEEP_DONE_FILE=0" >&2
fi
```

Then, based on the ステップ 4.6 completion report content **and the WM_UPDATE_FAILED context flag**, output the corresponding machine-readable pattern:

| 評価順 | Condition | Output Pattern |
|--------|-----------|---------------|
| 1 (最優先) | ステップ 1.0.1 / 1.2.0 / 1.2.0.1 で `[CONTEXT] FIX_FALLBACK_FAILED=1` を context に set した (`reason` の値は ステップ 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons table を **唯一の真実の源** として参照する。本セルでの固定列挙は drift 防止のため行わない) | `[fix:error]` (ステップ 1.0.1 / 1.2.0 / 1.2.0.1 のレビューソース解決失敗。fallback 経路が尽きたか、ユーザーが Interactive Fallback で中止を選んだか、ファイルパス指定の再実行でも有効なレビュー結果を取得できなかった状態のため caller は手動介入を促す) |
| 1.5 | `[CONTEXT] NB_SWEEP=1` かつ（`[CONTEXT] NB_SWEEP_RESULT=done` または `[CONTEXT] NB_SWEEP_DONE_FILE=1`） | `[fix:sweep-done]`（ステップ 1 に戻らない） |
| 1.6 | `[CONTEXT] NB_SWEEP=1` かつ `NB_SWEEP_RESULT=done 以外` かつ `NB_SWEEP_DONE_FILE` 非 1 | `[fix:error]` |
| 2 | ステップ 2.4 で `[CONTEXT] REPLY_POST_FAILED=1` を context に set した | `[fix:error]` (人間由来 thread への reply post が失敗。push 済みの可能性はあるが、レビュアー通知の責務を果たせていないため caller は次の iteration ではなく手動介入を促す) |
| 2.5 | ステップ 4.6 直前の gate が `[CONTEXT] FIX_REPORT_DIFF_GATE=error` を context に set した | `[fix:error]`（`map_missing` / `state_unreadable` / `diff_failed` / `jq_missing`。`unverified` / `passed` は本行にマッチしない） |
| 3 | ステップ 4.5 (4.5.1 または 4.5.2) で `[CONTEXT] WM_UPDATE_FAILED=1` を context に set した (`reason` の値は下記 reason 表のいずれか — 固定列挙は行わず、reason 表を唯一の真実の源とする) | `[fix:pushed-wm-stale]` (ステップ 4.5 で work memory 更新が silent skip された旨を caller に明示伝達。caller は work memory が stale であることを認識して fix loop を再実行するか手動介入する) |
| 4 | (Push completed (`プッシュ: 完了`) または 本 cycle 内で accept 決定が発生 [`[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED=1` または `[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1` が 1 回以上 context に出現]) かつ work memory 更新成功 | `[fix:pushed]` |
| 4.5 | Push なし かつ 本 cycle 内で accept 決定なし (上記 2 マーカーがいずれも非出現) かつ `{fatal_count}=0` かつ `{non_fatal_moved_count}>0` かつ All findings replied | `[fix:non-fatal-only]`（5.S sweep へ） |
| 5 | Push なし かつ 本 cycle 内で accept 決定なし (上記 2 マーカーがいずれも非出現) かつ All findings replied | `[fix:replied-only]`（5.S sweep 後も返信のみで終了） |
| 6 | Unexpected state / error | `[fix:error]` |

上から最初にマッチした pattern を採用。fatal 旗 (`FIX_FALLBACK_FAILED` / `REPLY_POST_FAILED` / `FIX_REPORT_DIFF_GATE=error`) → `[fix:error]`。次に `WM_UPDATE_FAILED` → `[fix:pushed-wm-stale]`。その後に通常終了。`FIX_REPORT_DIFF_GATE=unverified` / `passed` は fatal ではない。

**row 4/4.5/5 の accept 条件 — 唯一の真実の源**: iterate ステップ 4 が読む sentinel の決定箇所。Handoff 節と 4.6 Note は参照のみ。

「本 cycle 内で accept 決定が発生」= `ACCEPT_FINGERPRINT_PERSISTED=1` **または** `ACCEPT_FINGERPRINT_PERSIST_FAILED=1` の本 cycle 出現。`{accept_count}` (累計) は使わない。両マーカー欠落時は accept 無し。
rationale: references/design-rationale.md#accept-cycle-markers

`WM_UPDATE_FAILED=1` を会話から拾ったら `[fix:pushed-wm-stale]`。

emit される `WM_UPDATE_FAILED` reason は下表に存在する ( ⊆ 表)。検証:

```bash
bash {plugin_root}/hooks/scripts/fix-reason-coverage-check.sh
# → 空出力 + rc=0 (WM_UPDATE_FAILED reason はすべて表に存在)。
#   欠落があれば当該 reason を 1 行ずつ出力して rc=1 を返す。
#   rc=2 は emit を 1 件も抽出できなかった invocation error (emit 記法 drift の疑い)。
#   この場合も stdout は空になるため、空出力だけを見て pass と読まないこと —
#   網羅性は検証できていない。stderr の ERROR 行を確認する。
```

| reason | 発生 Phase | 発生条件 |
|--------|------------|----------|
| `mktemp_failed_pr_body_tmp` | ステップ 4.5.1 | PR body 退避用 tempfile の mktemp が失敗 (disk full / permission denied) |
| `pr_body_tmp_empty_or_missing` | ステップ 4.5.1 helper | PR 本文ファイルが空または存在しない |
| `mktemp_failed_pr_body_grep_err` | ステップ 4.5.1 | PR 本文 grep の stderr 退避 tempfile の mktemp が失敗 |
| `pr_body_grep_io_error` | ステップ 4.5.1 | PR 本文 grep が IO/権限/構文エラー (rc=2) で失敗 |
| `mktemp_failed_branch_grep_err` | ステップ 4.5.1 | branch 名抽出 grep の stderr 退避 tempfile の mktemp が失敗 |
| `branch_grep_io_error` | ステップ 4.5.1 | branch 名抽出 grep が IO/権限エラーで失敗 |
| `issue_number_not_found` | ステップ 4.5.1 | PR 本文に `Closes/Fixes/Resolves #N` がなく、ブランチ名にも `issue-N` がない |
| `mktemp_failed_gh_api_err` | ステップ 1.2 Fast Path / ステップ 2.x | `gh api` stderr 退避用 tempfile の mktemp が失敗 |
| `gh_api_comments_fetch_failed` | ステップ 1.2 Fast Path / ステップ 2.x | `gh api ... /comments` が exit != 0 で失敗 (401/403/404/timeout/5xx 等) |
| `mktemp_failed_jq_late_err` | ステップ 1.2 Fast Path | jq stderr 退避用 tempfile の mktemp が失敗 |
| `jq_comment_id_extract_failed` | ステップ 1.2 Fast Path | `jq -r '.id // empty'` が exit != 0 で失敗 (jq バイナリ異常 / OOM / parse error) |
| `jq_current_body_extract_failed` | ステップ 1.2 Fast Path | `jq -r '.body // empty'` が exit != 0 で失敗 (同上) |
| `current_body_empty` | ステップ 1.2 Fast Path | gh api 成功だが `.body` フィールド抽出が空 |
| `git_diff_failed` | ステップ 4.5.2 | changed-files-file 用 mktemp の失敗、または `git diff --name-status origin/{base_branch}...HEAD` の失敗 (shallow clone / 無効な base / git リポジトリ外)。helper を呼ばず work memory comment を不変に保つ (原実装が git diff 失敗時に PATCH 前で exit したのと等価) |
| `wm_sync_progress_failed` | ステップ 4.5.2 | `issue-comment-wm-sync.sh ... --transform update-progress` が no_comment 以外の skipped/error status を返した (body 取得失敗 / safety check 失敗 / transform 失敗 / PATCH 失敗を helper が内部処理し status= 行で通知) |
| `wm_update_helper_failed` | ステップ 4.5.2 caller | helper の結果 marker 不在（欠落・起動不能・引数不正等） |
| `wm_sync_history_failed` | ステップ 4.5.2 | `issue-comment-wm-sync.sh ... --transform append-section` (レビュー対応履歴) が no_comment 以外の skipped/error status を返した、または履歴 content-file の mktemp が失敗 |
| `cat_redirection_failed` | ステップ 2.4 / 4.5.x (heredoc redirection を使う任意箇所) | cat heredoc redirection の exit code が非ゼロ (disk full / write permission denied / IO error)。ステップ 4.5.1 / 4.5.2 の WM 更新経路など、heredoc を使う任意箇所で発火する可能性があるため、Phase 列は exhaustive な実 emit 箇所のリストではなく、典型的に発火する代表 phase の例示 |
| `empty_stdout` | ステップ 1.2 | gh api が exit 0 だが stdout が空または null |
| `missing_issue_url` | ステップ 1.2 | レスポンスに `.issue_url` フィールドが存在しない |
| `mktemp_failed_override_err` | ステップ 1.3 | confidence override stderr 退避用 tempfile の mktemp が失敗 |
| `mktemp_failed_reply_tmpfile` | ステップ 2.4 | reply body 用 tempfile の mktemp が失敗 |
| `paste_io_error` | ステップ 1.2 / 1.3 | printf / ファイル書き出しが IO エラーで失敗 |
| `pr_number_mismatch` | ステップ 1.2 | コメントの所属 PR と指定 pr_number が一致しない (silent misclassification) |
| `reply_tmpfile_empty` | ステップ 2.4 | reply body の tmpfile が cat 成功だが空 |
| `rite_origin` | ステップ 2.4 | `REPLY_SKIPPED` — 人間由来ゲートにより rite 由来 thread への reply を skip（POST bash 非実行） |
| `wc_io_error` | ステップ 1.3 | `wc -l` が IO エラーで失敗 |
| `raw_json_write_failed` | ステップ 1.2 Fast Path Block A | Block A の raw JSON 中間ファイル (`${TMPDIR:-/tmp}/rite-fix-raw-{pr}-{cid}.json`) への printf 書き出しが IO エラーで失敗 |
| `jq_author_extract_failed` | ステップ 1.2 Fast Path Block A | Block A の `jq -r '.user.login // empty'` が exit != 0 で失敗 (jq バイナリ異常 / OOM / parse error) |
| `raw_json_missing_at_block_b` | ステップ 1.2 Fast Path Block B | Block B 進入時に Block A の raw JSON 中間ファイルが存在しない or 空 (Block A 失敗 / 並列実行で削除 / orchestrator 異常終了で Block B 未到達) |
| `mktemp_failed_jq_block_b` | ステップ 1.2 Fast Path Block B | Block B の jq stderr 退避用 tempfile の mktemp が失敗 |
| `intermediate_missing_at_block_c` | ステップ 1.2 Fast Path Block C | Block C 進入時に Block A/B が作成したはずの intermediate ファイル (body/author/skip) または raw_json が存在しない or 空 |
| `intermediate_write_failed` | ステップ 1.2 Fast Path Block A | Block A の intermediate 3 ファイル (body/author/skip) への printf 書き出しが IO エラーで失敗 (disk full / read-only / inode 枯渇 / permission denied) |
| `author_file_missing_at_post_condition` | ステップ 1.2 Fast Path Block C | Block C の post-condition check で author_file が存在しない (`[ -f ]` 失敗、empty は許容) |
| `skip_file_empty_at_post_condition` | ステップ 1.2 Fast Path Block C | Block C の post-condition check で skip_file が空または存在しない (`[ -s ]` 失敗) |

`[fix:pushed-wm-stale]`: push 済だが WM stale。`[fix:pushed]` 扱い禁止。

**Important**:
- Do **NOT** invoke `rite:pr-review` via the Skill tool
- Return control to the caller (`/rite:iterate` 等)
- **re-review は `/rite:pr-review` 経由**。範囲は 1.2.4 が cycle に応じて決定。fix 側で範囲を宣言しない

**Confidence override tempfile cleanup** (silent orphan 防止):

ステップ 5.1 の output pattern emit 直後に、fix ループ全体で使用していた confidence_override tempfile を明示的に削除する。specific path 必須 (並列セッション破壊防止)。

```bash
# confidence_override + pr-comment tempfile の明示的 cleanup (E2E flow 経路)
# fix ループ全体で append されてきたファイルを終了時に削除する。
# rationale: references/design-rationale.md#confidence-gate-notes
# pr-comment tempfile も追加 (Broad Retrieval が書き出した
# ${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt の正常時 cleanup)。Fast Path 経路では存在しないため
# silent no-op となる。
rm -f "${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt"
```

> **Note (work memory backup)**: work memory body の backup (生成・成功時削除・失敗時 preserve) は `issue-comment-wm-sync.sh` が内部で完結させる (helper の Step 3/6 参照)。本コマンドの caller 側では backup を生成・cleanup しないため、ステップ 5.1 の output pattern に応じた手動 backup cleanup も行わない。

**Example output:**
```
PR #{pr_number} のレビュー指摘対応を完了しました

全指摘: 4件
対応した指摘: 4件
- 修正: 3件
- 返信: 1件
コミット: abc1234
プッシュ: 完了

[fix:pushed]
```

---

### 5.2 Standalone Execution Behavior

For standalone execution, ステップ 5 is not executed. The completion report from ステップ 4.6 will guide the user.

**Confidence override tempfile cleanup** (Standalone 経路の orphan 防止):

Standalone は ステップ 5 を skip するので、4.6 直後に confidence_override tempfile を消す。
rationale: references/design-rationale.md#confidence-gate-notes

```bash
# ステップ 5.2 Standalone 経路: confidence_override + pr-comment tempfile の明示的 cleanup
# 実行タイミング: ステップ 4.6 の completion report を表示した直後
# {pr_number} は Claude が ステップ 1.0 の parse 結果で事前置換済み
rm -f "${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt"
```

未作成なら `rm -f` は no-op。
