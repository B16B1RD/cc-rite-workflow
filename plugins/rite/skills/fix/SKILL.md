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

PR レビューコメントを取得・整理し、指摘への対応を効率的に支援する。やることは以下のシーケンシャルなタスク列:

0. Work Memory のロード (E2E フロー時のみ)
1. レビューコメントの取得と整理
2. 修正支援
3. 修正のコミット
4. 完了報告
5. E2E フロー継続 (出力パターン)

途中で止まったら flow-state に `phase=fix` が残るので `/rite:recover` で再開する。

`/rite:iterate` の review-fix loop から「not mergeable」評価時に自動 invoke される。**All findings are targeted for fixes** (severity / loop count に関係なく)。完了後 machine-readable output pattern を emit し caller に制御返却。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number, review findings from `/rite:pr-review`, flow state with `phase: fix` (written by `skills/iterate/SKILL.md` fix side) or `phase: phase5_fix` (legacy compat — sub-skill still patches the old name so resume from an interrupted earlier session keeps working until every writer migrates off the legacy name)
**Output**: `[fix:pushed]` | `[fix:pushed-wm-stale]` | `[fix:replied-only]` | `[fix:cancelled-by-user]` | `[fix:error]`

## Inline Annotation Convention

本ファイル内の `verified-review` 注釈 (`H-N` / `M-N` / `C-3` 等の重要度プレフィックス + 通番、括弧内 `(M10)` 等の統合追跡 ID) はレビュー指摘の対応追跡用。詳細: [design-rationale.md#inline-annotation-convention](references/design-rationale.md#inline-annotation-convention)

## Prerequisites

bash 4.0+ 必須 (複数の bash block で `mapfile -t < <(...)` builtin を使用)。ステップ 1.0.1 の bash block 冒頭 (Step 0) に [bash-compat-guard.md](../../references/bash-compat-guard.md) の canonical guard を inline embed 済み (C-3 対応)。失敗時は `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=bash_version_incompatible` を emit して `[fix:error]` で exit する。

## E2E Output Minimization

`/rite:iterate` E2E flow から呼ばれた時、出力のみ minimize する。fix implementation / commit/push / work memory 更新等の処理本体は standalone と同等に実行する (時間・context を理由にした修正内容省略・commit 分割省略は identity 違反; [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md))。

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Fix implementation | Full output | Full output (needed for code changes) |
| ステップ 4 (Completion) | Full report | Result pattern + 1-line summary only |
| ステップ 4.5 (Work Memory) | Full update | Full update (no change) |

E2E output format (ステップ 4):

```
[fix:{result}] — {fixed_count} fixed, {skipped_count} skipped, {files_changed} files changed
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

すべての引数形式は ステップ 1.0 (Argument Parsing Pre-flight) で正規化され、`{pr_number}` と (該当時のみ) `{target_comment_id}` が抽出される。`comment_url` を指定すると、その特定コメントから直接 findings をパースする (ステップ 1.2 で分岐)。**複数の引数を同時に渡すことはできない** (ステップ 1.0 は最初に解釈成功した形式のみを採用する)。

---

## ステップ 0: Work Memory のロード (E2E フロー時のみ)

When executed within the end-to-end flow, load required information from work memory (shared memory).

### 0.1 Determine End-to-End Flow

Determine the caller from the conversation context:

| Condition | Determination | Action |
|-----------|---------------|--------|
| Conversation history contains rich context from `/rite:pr-review` | Within end-to-end flow (review-fix loop) | PR number can be obtained from conversation context |
| `/rite:fix` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

### 0.2 Load Work Memory

Extract the Issue number from the current branch and retrieve work memory:

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

Extract the following information from work memory and retain in context:

| Field | Extraction Pattern | Purpose |
|-------|-------------------|---------|
| Issue number | `issue-(\d+)` from branch name | Work memory update |
| PR number | `- **番号**: #(\d+)` | Retrieve review comments |
| Phase | `- **フェーズ**: (.+)` | Confirm flow position |
| Review result | `### レビュー対応履歴` section | Check previous state |

**For standalone execution:**
- If no PR number is specified as an argument, obtain from the current branch's PR
- The "related PR" section in work memory can also be referenced

---

### 0.5.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki-query/SKILL.md) — `wiki-query-inject.sh` API

Before retrieving review comments, inject relevant experiential knowledge from the Wiki to inform the fix approach.

**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_query: true` in `rite-config.yml`. Skip silently otherwise.

**Step 1**: Check Wiki configuration:

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

If `wiki_enabled=false` or `auto_query=false`, skip this section and proceed to ステップ 1.

**Step 2**: Generate keywords from the review context and invoke the query:

Keywords are derived from: review finding categories (from conversation context if available), target file paths, and finding types (e.g., `security`, `performance`, `error-handling`).

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

**Step 3**: If `wiki_context` is non-empty, retain it in conversation context and reference it during fix application (ステップ 2). The injected experiential knowledge may inform: effective fix strategies for similar findings, common overcorrection patterns to avoid, and proven fix approaches.

---

## ステップ 1: レビューコメントの取得と整理


### 1.0 Argument Parsing (Pre-flight)


**Always run this sub-phase**. ステップ 1.1 が `gh pr view` を実行する前に、引数形式を正規化して `{pr_number}` と（該当時のみ）`{target_comment_id}` を抽出する。bare integer (`^[0-9]+$`) や引数なしの場合でも本サブフェーズを実行し、Detection rules table の順序 1 / 順序 4 で pr_number を抽出した上で **`{target_comment_id} = null` を explicit set** する (undefined 参照防止)。


**Detection rules** (順序ベース判定 — bash POSIX ERE は negative lookahead 非対応のため、より特殊なパターンを先に試して fallthrough する):

| 順序 | Format | Regex (POSIX ERE 互換、lookaround なし) | Extracted |
|------|--------|------------------------------------------|-----------|
| 1 | 数字のみ (ASCII / 全角) | `^[0-9０-９]+$` | `pr_number` (全角数字は半角に正規化してから as-is 保持) |
| 2 | Comment URL (`?query` は `#fragment` の前後どちらでも可) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)(\?[^#]*)?#issuecomment-([0-9]+)(\?.*)?$` | `pr_number` = group 1, `target_comment_id` = **group 3** (group 2 は `#fragment` 前の query string、group 4 は `#fragment` 後の query string で、いずれも受け入れて無視) |
| 3 | PR URL (trailing path / query / fragment 任意) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)(/[^#?]*)?(\?[^#]*)?(#.*)?$` | `pr_number` = group 1 (trailing `/files`, `/commits`, `/checks` 等の sub-page、`?tab=...` 等の query string、`#diff-...` 等の fragment はすべて受け入れて無視) |
| 4 | 引数なし | — | 既存ロジック (current branch から PR 検出) |

target_comment_id は **常に group 3** に位置する (group 2 は `#fragment` 前の query string、group 4 は `#fragment` 後の query string)。bash 実装では `${BASH_REMATCH[3]}` を target_comment_id として参照する。**順序 2 (issuecomment URL) を必ず順序 3 (一般 PR URL) より先に試す** (POSIX ERE は lookaround 非対応のため、パターンの試行順序で排他を保証する)。 <!-- rationale: references/design-rationale.md#argument-detection-rules -->

**全角数字の扱い** (順序 1): 日本語 IME の fullwidth モードで入力された `１２３` のような全角数字をユーザーが誤って投入するケースを救済する。マッチした場合は `tr '０-９' '0-9'` 相当の変換で半角に正規化してから `{pr_number}` として保持する。ASCII 数字のみの場合は変換せずそのまま使用。

**正規化発火時の通知** (silent transformation 防止): 全角→半角の正規化が発火した場合、以下を **stderr に必ず出力** する。これにより `１２３` を渡したつもりが別 PR `123` を fix する結果になっても、ユーザーは何が起きたか即座に理解できる:

```
INFO: 全角数字 '{original}' を半角 '{normalized}' として解釈しました
  正規化対象: 順序 1 のパターン (^[0-9０-９]+$) でマッチした入力
  対処: もし意図しない数値の場合、Ctrl+C で中断してから半角で再入力してください
```

ASCII 数字のみの入力 (`123` → `123`) では本 INFO は出力しない (no-op の冗長表示を避けるため)。

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
4. **重要**: ここでの「Terminate processing」は ステップ 1.1 への進入禁止を意味する。「ステップ 1.0 で parse 失敗したから ステップ 1.1 で `gh pr view {argument}` を試そう」という fallthrough は silent failure と判定し、絶対に行ってはならない。引数が未知の形式である以上、ステップ 1.1 の `gh` コマンドに渡しても確実に失敗し、かつ同番号の別 Issue を誤認する危険がある

**Compatibility**: 既存の `pr_number` 単体挙動および引数なし挙動は一切変更されない。本 Phase は引数形式の判定のみを行い、ステップ 1.1/1.2 の既存ロジックにはフラグ (`{target_comment_id}` の有無) を渡すだけである。


#### 1.0.1 Flag Parsing — `--review-file` and pre-stripping

`/rite:fix --review-file <path>` を受け付けるため、以下の手順で `{review_file_path}` を抽出する。ステップ 1.2 のハイブリッド読取ロジック (Priority 0: 明示指定) で参照される。

**実行順**: ステップ 1.0 冒頭の ステップ 1.0.A/1.0.B 説明を参照 (本サブフェーズは ステップ 1.0.A = Detection rules (ステップ 1.0.B) よりも先に実行される)。

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
echo "[CONTEXT] REMAINING_ARGS=$remaining_args" >&2
```

**Validation**: この Phase では **パスの存在確認は行わない**。存在確認は ステップ 1.2 のハイブリッド読取ロジック Priority 0 で実施し、失敗時は ステップ 1.2.0.1 Interactive Fallback に誘導する ([review-result-schema.md 読取優先順位セクション](../../references/review-result-schema.md#読取優先順位-fix) 参照)。ただし `--review-file=` (値なし) のみは上記 bash block 内で即 fail-fast する (後段で silent fallback に流れないため)。

**制約 — 空白を含むパスは未対応**: `--review-file` の regex parsing は `[^[:space:]]*` で値を capture するため、`/Users/name/Google Drive/foo.json` のような**空白を含むパスは正しくパースされない** (空白位置でトークン分割され、PR 番号候補として誤認される)。この制約は Claude Code の `$ARGUMENTS` が単一文字列として渡される仕様に起因し、真の argv 復元は不可能。空白を含むパスを使いたい場合は ステップ 1.2.0.1 Interactive Fallback の「ファイルパス指定」option で入力すること (AskUserQuestion は単一文字列として受け取るため空白を含むパスも受理される)。

**Claude data flow**: Claude は上記 bash block の **stderr** から `[CONTEXT] REVIEW_FILE_PATH=...` と `[CONTEXT] REMAINING_ARGS=...` を会話コンテキストで読み取り、以後 ステップ 1.0 Detection rules を `remaining_args` に対して適用する。Detection rules 側の regex は **必ず** `$ARGUMENTS` ではなく `remaining_args` を入力とすること。Claude Code の Bash tool は stdout/stderr 両方をコンテキストに取り込むため、stderr 読取で支障はない。

**Compatibility**: `--review-file` を使わない既存呼び出し (`/rite:fix 123` 等) は一切挙動変更なし — `remaining_args = original_args` となり既存ロジックと等価。本フラグは ステップ 1.2 冒頭の読取優先順位決定にのみ影響する。

### 1.1 Identify the PR

After ステップ 1.0 has extracted `{pr_number}` (and optionally `{target_comment_id}`), retrieve repository information:

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

### 1.1.5 セッション worktree 健全性の保証（multi_session 有効時 / #1676）

fix は ステップ 2 以降で **作業ツリーのファイルを Edit / Write で修正**する。その前に対象 PR の作業ブランチに対応する session worktree を保証する。これがないと、worktree 不在（resume / context 圧縮 / 別セッション跨ぎで欠落）のとき fix がメインツリー（develop）上で実行され、`git branch --show-current` が develop を返して issue 番号抽出が空になり、最悪 **develop の作業ツリーへ修正を書き込む**（§4.4 MUST / MUST NOT）。

ステップ 1.1 で取得した PR の `headRefName`（作業ブランチ）から issue 番号を抽出し、共通ヘルパー `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)、検出 + 再構築を bash 側で完結し `[CONTEXT] WT_ENSURE=` を emit）で検出・再構築する（`{head_ref}` は ステップ 1.1 の `gh pr view` が返した `.headRefName`）:

```bash
issue_number=$(printf '%s' "{head_ref}" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
if [ -n "$issue_number" ]; then
  bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_number" --branch "{head_ref}"
else
  # head_ref が issue ブランチでない（session worktree の対象外）→ 従来どおり単一ツリーで続行
  echo "[CONTEXT] WT_ENSURE=skip (head_ref が issue ブランチでないため worktree 対象外: {head_ref})"
fi
```

`[CONTEXT] WT_ENSURE=` marker の分岐は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 3.1.5 の **WT_ENSURE 分岐表（SoT）** に従う（`disabled`〜`reconstructed` の共通 case は SoT 表と同一。**終端の `branch_absent` / `failed` のみ caller 固有**で、recover の AskUserQuestion / 停止に対し、非対話サブ起動の fix は機械的に `[fix:error]` 停止する — 下記）:

- `disabled` / `already_in` / `skip` → no-op、ステップ 1.2 へ（`disabled` = `multi_session.enabled: false`。従来どおり単一ツリーで動作し挙動不変）。
- `reenter` / `reconstructed` → `EnterWorktree` ツールを `path: {path}`（marker の `path=` 値）で呼び出してからステップ 1.2 へ。`reconstructed` は helper が `git worktree add` 済み。EnterWorktree 失敗時の切り分けは recover.md Phase 3.1.5 / /rite:open Step 2.3-W と同じ（silent に新規扱いしない）。
- `residue` → AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` のパスを表示）。
- `branch_absent` → 対象ブランチがローカル・リモートどこにも実在しない。誤再構築しない。ただし ステップ 1.1 で `gh pr view {pr_number}` が成功している以上、PR の head ブランチは本来 remote に存在するはずで、`branch_absent` の到達は PR 状態との不整合を意味する。**develop 上で fix を続行せず**、`[fix:error]` を emit して明示停止する（`failed` と同じ機械的停止。ステップ 2 以降の Edit/Write へ進まない＝develop の作業ツリーへ書かない）。
- `failed` → 再構築失敗（helper rc=1, stderr に原因 + 復旧手順）。**silent fallback せず `[fix:error]` を emit して明示停止**する（develop の作業ツリーへ修正を書かない）。

### 1.2 Retrieve Review Comments

#### 1.2.0 Hybrid Review Source Resolution <!-- AC-3 / AC-4 / AC-5 / D-01 -->


> **Acceptance Criteria anchor**: AC-3 (Priority 1: 同一セッション内の会話コンテキストを最優先で使用)。AC-4 (Priority 2: 会話になければ最新 timestamp のローカルファイルを使用)。AC-5 (Priority 3: 既存 PR コメントの `📜 rite レビュー結果` を後方互換 fallback として読取)。D-01 (会話 > ローカルファイル > PR コメントのハイブリッド方式を採用した理由: セッション横断作業と即時連携の両立)。

**Priority chain**:

| Priority | Source | Condition | Action |
|----------|--------|-----------|--------|
| 0 | `--review-file <path>` (explicit) | `{review_file_path}` set in ステップ 1.0.1 | Read and parse the specified file. On failure, go directly to Priority 4 (fallback) |
| 1 | Conversation context | Same session has a recent `/rite:pr-review` result in context | Use conversation-context findings directly; skip API/file access |
| 2 | Local JSON file | `.rite/review-results/{pr_number}-*.json` exists | Read latest timestamp file; parse per schema |
| 3 | PR comment (backward-compat) | PR has `## 📜 rite レビュー結果` comment | Extract Raw JSON from code fence if present; else parse Markdown table (legacy) |
| 4 | Interactive fallback | None of the above available | `AskUserQuestion` — prompt user for action (ステップ 1.2.0.1) |

**⚠️ Selection logic — Claude substitution required**:

ステップ 1.2.0 の Selection logic (Priority 0/1/2/3 + fallback の解決) は `scripts/review-source-resolve.sh` に委譲する。シェル変数は Bash tool 呼び出し間で継承されないため、Claude は下記 bash block を生成する前に、ステップ 1.0 / 1.0.1 の値と Priority 1 会話判定を **helper の引数として literal substitute** すること:

- `{pr_number}` — ステップ 1.0 で正規化された PR 番号 (数値)。非数値は「未 substitute」として `reason=pr_number_placeholder_residue` で fail-fast。
- `{review_file_path_from_phase_1_0_1}` — ステップ 1.0.1 の `[CONTEXT] REVIEW_FILE_PATH=...` 値を会話コンテキストから読み取る (未指定時は `__RITE_UNSET__`)。
- `{conversation_review_decision}` — **Priority 1 判定**: Priority 0 が未発火の前提で、同一 session の直前 assistant turn に `## 📜 rite レビュー結果` を含む `/rite:pr-review` 出力が残っていれば、その findings を会話コンテキストから読み取り `use` を渡す。なければ `none` を渡す。
- `{p1_scan_turns}` / `{p1_scan_found}` — Priority 1 receipt: scan した assistant turn 数 (use 時 1 以上) と発見有無 (`use`→`true` / `none`→`false`)。

helper は全 `[CONTEXT] REVIEW_SOURCE*` marker を **stderr** に emit し、解決完了時に最終 marker `[CONTEXT] REVIEW_SOURCE=<source>; review_source_path=<path or empty>; pr_number=<n>` を emit する。下流の severity_map build ブロックはこの marker を読んで `review_source` / `review_source_path` を literal 置換する (**marker フォーマット不変が hard constraint**)。fatal 時は helper が `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=...` を stderr emit + 非ゼロ exit し、caller が `[fix:error]` を stdout 出力する (**[fix:error] stdout 分離**)。helper の Priority chain / 各 `REVIEW_SOURCE_*` reason / corrupt-file rename 副作用 / trap cleanup は旧 inline block から verbatim 移設済み。

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

**`review_source` state transitions within pr_comment path**: `review_source="pr_comment"` に設定された後、Priority 3 処理 (下記 awk block) における state 遷移と意味論は以下の通り:


**On Priority 0 failure** (explicit file missing/invalid/schema_unknown): `review_source="fallback"` triggers ステップ 1.2.0.1 interactive fallback. Do NOT fall through to Priority 1-3 silently when `--review-file` was explicitly requested but unusable — the user's intent was to use that specific file.

**On Priority 2 success**: Skip the existing "Target Comment Fast Path" and "Broad Comment Retrieval" sub-sections below. `severity_map` / `scope_map` の構築 + schema 1.1.0 normalization は `scripts/review-findings-maps.sh` に委譲する。helper は schema 1.0/1.0.0 の scope default mapping (a)・invariant #5 auto-correct (b)・auto_demote_low 降格 (e, `rite-config.yml` 読込含む)・重複 file:line 検出・line null/0 の `anchor` sentinel 正規化・severity_map/scope_map 構築検証・normalized tempfile の trap 削除をすべて内包し、`[CONTEXT] REVIEW_SOURCE_*` retained flag を **stderr** に旧 inline block から verbatim emit する (reason SoT は helper docstring。fix.md 側は下記 bullet 列挙で参照)。file-based source (local_file / explicit_file) 以外を渡した場合は no-op exit 0 (旧 if guard と同一)。

`{review_source}` / `{review_source_path}` は ステップ 1.2.0 の最終 marker `[CONTEXT] REVIEW_SOURCE=...` から literal substitute する。severity_map 構築失敗時のみ helper が非ゼロ exit し、caller が `[fix:error]` を stdout 出力する (**[fix:error] stdout 分離** — 上記 review-source-resolve.sh caller と同型):

```bash
# ステップ 1.2.0 severity_map/scope_map build — scripts/review-findings-maps.sh へ委譲
bash {plugin_root}/scripts/review-findings-maps.sh \
  --review-source "{review_source}" \
  --review-source-path "{review_source_path}" || {
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=findings_maps_build_failed" >&2
  echo "[fix:error]"
  exit 1
}
```

**On Priority 3 (PR comment, backward-compat)**: After the existing Broad Retrieval retrieves the comment body, check for a `### 📄 Raw JSON` section with code fence. Scope the awk parser to after the `### 📄 Raw JSON` section marker so that sample JSON blocks in findings' suggestion columns (which appear earlier in the comment) are not mistakenly captured.


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
# WARNING + reason emit してから legacy parser に流す (ケース融合は silent regression)
if [ -z "$raw_json" ]; then
  # legitimate legacy format: PR コメントに Raw JSON section なし → 旧 Markdown table parser へ
  :
elif ! printf '%s' "$raw_json" | jq empty 2>/dev/null; then
  echo "WARNING: PR コメント内の Raw JSON が syntactically invalid です。legacy parser に fallthrough します。" >&2
  echo "  対処: PR コメントを再投稿するか、ローカル JSON ファイルを使用してください" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_raw_json_parse_failure" >&2
elif ! printf '%s' "$raw_json" | jq -e '
  (.schema_version | type == "string" and length > 0)
  and (.pr_number | type == "number")
  and (.findings | type == "array")
' >/dev/null 2>&1; then
  # 明示型ガード (jq truthiness は false/null のみ falsy — 空文字列や型違反を silent pass させない)
  echo "WARNING: PR コメント内の Raw JSON が必須フィールドを欠いています。legacy parser に fallthrough します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_schema_required_fields_missing" >&2
elif ! printf '%s' "$raw_json" | jq -e '
  (.overall_assessment != "mergeable")
  or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
' >/dev/null 2>&1; then
  # Cross-field invariant (review-result-schema.md): mergeable × open CRITICAL/HIGH は禁止。
  # 実測必須ゲートによる `measured == false` 除外は本経路に入れない — 同一 invariant は P0/P2
  # (`scripts/review-source-resolve.sh`) と SoT (review-result-schema.md invariant #2) にも実装があり、
  # P3 だけ緩めると同一 JSON が経路により受理/拒否に割れる。write 側が `verification` を出力する
  # 前提は #2072 で満たされたが、3 経路 + SoT の同時更新は依然として不要 — gated な
  # `measured == false` は `non_blocking_findings[]` へ移送されるため `findings[]` に残る非実測
  # finding は `scope == "nit-noted"` のみ。CRITICAL/HIGH × nit-noted は invariant #4 が禁じる
  # 組合せなので、CRITICAL/HIGH を見る本述語の判定対象に非実測 finding は現れない。
  echo "WARNING: PR コメント内の Raw JSON が cross-field invariant に違反しています (mergeable だが open な CRITICAL/HIGH finding あり)。legacy parser に fallthrough します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_comment_cross_field_invariant_violated" >&2
elif ! printf '%s' "$raw_json" | jq -e '
  [.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0
' >/dev/null 2>&1; then
  # Cross-field invariant #4: severity ∈ {CRITICAL, HIGH} × scope == "nit-noted" は禁止
  # (1.0/1.0.0 JSON では .scope 欠落のため規約的に発火しない — 後方互換)
  violation_count=$(printf '%s' "$raw_json" | jq '[.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' 2>/dev/null || echo "?")
  echo "WARNING: PR コメント内の Raw JSON が cross-field invariant #4 に違反しています (severity ∈ {CRITICAL, HIGH} で scope=\"nit-noted\" の finding が $violation_count 件)。legacy parser に fallthrough します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_comment_critical_high_scope_nit_noted; count=$violation_count" >&2
elif ! printf '%s' "$raw_json" | jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' >/dev/null 2>&1; then
  # overall_assessment enum validation (review-result-schema.md)
  oa_val=$(printf '%s' "$raw_json" | jq -r '.overall_assessment // "(null)"' 2>/dev/null)
  echo "WARNING: PR コメント内の Raw JSON の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)。legacy parser に fallthrough します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
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
      # schema 1.1.0 後方互換 normalization (scope default mapping + invariant #5 auto-correct + auto_demote_low)。
      # 本 step は Priority 3 (pr_comment) 用で、Priority 0/2 (file-based) の scripts/review-findings-maps.sh と
      # 同 logic の鏡像。jq filter / normalization 動作を変更する際は helper と本 block の両方を同期すること。
      # 動作 (a)-(e) の詳細: references/design-rationale.md#schema-normalization-mirror
      norm_defaulted_count_p3=0
      norm_corrected_count_p3=0
      norm_demoted_low_count_p3=0
      # auto_demote_low config 読込 (Priority 0/2 経路と対称)
      auto_demote_low_p3=$(awk '/^review:/{r=1;next} r && /^  scope_assignment:/{s=1;next} s && /^    auto_demote_low:/{print $2; exit}' rite-config.yml 2>/dev/null | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')
      case "$auto_demote_low_p3" in false|no|0) auto_demote_low_p3=false ;; *) auto_demote_low_p3=true ;; esac
      case "$schema_version" in
        "1.0.0"|"1.0")
          norm_defaulted_count_p3=$(printf '%s' "$raw_json" | jq '[.findings[]? | select(has("scope") | not)] | length' 2>/dev/null || echo 0)
          ;;
      esac
      norm_corrected_count_p3=$(printf '%s' "$raw_json" | jq '[.findings[]? | select(.pre_existing == false and .scope == "nit-noted")] | length' 2>/dev/null || echo 0)
      if [ "$auto_demote_low_p3" = "true" ]; then
        norm_demoted_low_count_p3=$(printf '%s' "$raw_json" | jq '[.findings[]? | select(.severity == "LOW" and .scope == "current-pr")] | length' 2>/dev/null || echo 0)
      fi
      if [ "${norm_defaulted_count_p3:-0}" -gt 0 ] || [ "${norm_corrected_count_p3:-0}" -gt 0 ] || [ "${norm_demoted_low_count_p3:-0}" -gt 0 ]; then
        if normalized_raw_json=$(printf '%s' "$raw_json" | jq --arg demote_low "$auto_demote_low_p3" -c '
          .findings |= map(
            (if has("scope") then . else .scope = (
              if .severity == "CRITICAL" or .severity == "HIGH" or .severity == "MEDIUM" then "current-pr"
              else "nit-noted"
              end
            ) end)
            | (if .pre_existing == false and .scope == "nit-noted" then .scope = "current-pr" else . end)
            | (if $demote_low == "true" and .severity == "LOW" and .scope == "current-pr" then .scope = "nit-noted" else . end)
          )
        ' 2>/dev/null); then
          if [ "${norm_defaulted_count_p3:-0}" -gt 0 ]; then
            echo "WARNING: $norm_defaulted_count_p3 findings の scope を schema 1.0 後方互換で severity-based default mapping により補完しました" >&2
            echo "[CONTEXT] REVIEW_SOURCE_SCOPE_DEFAULTED=1; reason=scope_omitted_in_v1_0; count=$norm_defaulted_count_p3; schema_version=$schema_version" >&2
          fi
          if [ "${norm_corrected_count_p3:-0}" -gt 0 ]; then
            echo "WARNING: $norm_corrected_count_p3 findings が invariant #5 違反 (pre_existing=false × scope=nit-noted) のため scope を current-pr に auto-correct しました" >&2
            echo "[CONTEXT] REVIEW_SOURCE_AUTO_CORRECTED=1; reason=pre_existing_false_scope_nit_noted; count=$norm_corrected_count_p3" >&2
          fi
          if [ "${norm_demoted_low_count_p3:-0}" -gt 0 ]; then
            echo "WARNING: $norm_demoted_low_count_p3 findings (LOW × current-pr) を auto_demote_low により scope=nit-noted に降格しました" >&2
            echo "[CONTEXT] REVIEW_SOURCE_AUTO_DEMOTED_LOW=1; reason=low_current_pr_demoted_to_nit_noted; count=$norm_demoted_low_count_p3" >&2
          fi
          raw_json="$normalized_raw_json"
        else
          echo "WARNING: schema 1.1.0 normalization jq が失敗 — 原 Raw JSON のまま続行します" >&2
          echo "[CONTEXT] REVIEW_SOURCE_NORMALIZATION_FAILED=1; reason=jq_mutation_failed" >&2
        fi
      fi

      # jq exit code を if-else で明示捕捉 (失敗時は legacy Markdown parser へ明示 fallthrough)
      p3_jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-p3-smap-err-XXXXXX" 2>/dev/null) || p3_jq_err=""
      # line nullable sentinel 正規化 (Priority 2 severity_map と同じ処理)
      if severity_map_json=$(printf '%s' "$raw_json" | jq -c '[.findings[] | {key: (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end)), value: .severity}] | from_entries' 2>"${p3_jq_err:-/dev/null}"); then
        :
      else
        p3_jq_rc=$?
        echo "WARNING: PR コメント内 Raw JSON からの severity_map 構築 jq が失敗しました (rc=$p3_jq_rc)" >&2
        [ -n "$p3_jq_err" ] && [ -s "$p3_jq_err" ] && head -3 "$p3_jq_err" | sed 's/^/  /' >&2
        echo "  legacy Markdown table parser に fallthrough します (review_source は pr_comment のまま)" >&2
        echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_severity_map_build_failed; rc=$p3_jq_rc" >&2
        severity_map_json=""  # 明示的に空文字にして後段 legacy parser が起動する
      fi
      # scope_map_json を severity_map_json と並行構築 (Priority 0/2 と対称)
      if scope_map_json=$(printf '%s' "$raw_json" | jq -c '[.findings[] | {key: (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end)), value: .scope}] | from_entries' 2>"${p3_jq_err:-/dev/null}"); then
        :
      else
        p3_jq_scmap_rc=$?
        echo "WARNING: PR コメント内 Raw JSON からの scope_map 構築 jq が失敗しました (rc=$p3_jq_scmap_rc) — scope-based routing が無効化されます" >&2
        # jq stderr 抽出 (Priority 0/2 経路 + Priority 3 severity_map と対称化、code-quality reviewer 指摘対応)
        [ -n "$p3_jq_err" ] && [ -s "$p3_jq_err" ] && head -3 "$p3_jq_err" | sed 's/^/  /' >&2
        echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_scope_map_build_failed; rc=$p3_jq_scmap_rc" >&2
        scope_map_json="{}"
      fi
      [ -n "$p3_jq_err" ] && rm -f "$p3_jq_err"
      ;;
    *)
      echo "WARNING: PR コメント内の Raw JSON schema_version が未知: $schema_version" >&2
      echo "  legacy Markdown table parsing に fallthrough します。" >&2
      echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=pr_comment_schema_version_unknown" >&2
      # Legacy Markdown table parser (ステップ 1.2.1) に fallthrough
      ;;
  esac
fi
```

**Retain in context**: `{review_source}` (`explicit_file` / `conversation` / `local_file` / `pr_comment` / `fallback`) is used by later phases to log provenance in the fix commit message and work memory.

#### 1.2.0.1 Interactive Fallback (when all sources missing) <!-- AC-6 -->

> **Acceptance Criteria anchor**: AC-6 (全ソース欠落時に `AskUserQuestion` で「レビュー実行 / ファイルパス指定 / 中止」を提示する)。

`{review_source}=fallback` (Priority 0-3 が全て不可) の場合、`AskUserQuestion` で 3 択を提示する:

```
レビュー結果が見つかりませんでした
  会話コンテキスト: なし
  ローカルファイル: .rite/review-results/{pr_number}-*.json なし
  PR コメント: 該当なし

どうしますか？

オプション:
- レビュー実行: /rite:pr-review を起動してレビュー結果を生成する
- ファイルパス指定: 既存の JSON ファイルパスを入力する (Other で自由入力)
- 中止: /rite:fix の処理を終了する
```

**Per-option behavior** (one-shot — retry counter / state file による hard gate は廃止した。止まったら `/rite:recover`):

| User Choice | Action |
|-------------|--------|
| **レビュー実行** (Recommended) | `skill: "rite:pr-review", args: "{pr_number}"` を invoke し、完了後 ステップ 1.2 を再入する。再入時は会話コンテキストに新鮮な review があるため Priority 1 が `use` で発火する |
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

**ステップ 2+ 進入禁止**: `[fix:error]` が emit された時点で Claude は以降の Phase (ステップ 2 Categorization, ステップ 3 Commit, ステップ 4 Report) への bash tool 呼び出しを一切行ってはならない。bash の `exit 1` による機械的強制ルールであり、自然言語判断による例外を認めない。

**ステップ 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons**:

> **注**: ステップ 1.2.0 Selection logic (Priority 0/1/2/3 + fallback) の reason は `scripts/review-source-resolve.sh` へ移設済み。Priority 0/2 (file-based) の severity_map build / normalization の reason は `scripts/review-findings-maps.sh` へ移設済み (下記 bullet 列挙)。本表は ステップ 1.0.1 / 1.2.0 caller guard / 1.2.0.1 Interactive Fallback / Priority 3 pr_comment (string-based 鏡像含む) の reason を扱う。

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
| `pr_comment_severity_map_build_failed` | Priority 3 で PR コメント Raw JSON からの severity_map 構築用 jq が失敗 (legacy Markdown parser へ fallthrough) |
| `pr_comment_tempfile_read_io_error` | Priority 3 で `pr_comment_body_file` の cat が IO エラーで失敗 (permission 変更 / NFS timeout / TOCTOU truncate) |
| `pr_number_placeholder_residue` | ステップ 1.2.0 冒頭の `pr_number="{pr_number}"` literal substitute が忘れられ、数値以外 (空文字 / placeholder 残留) のまま bash block に入った (cleanup.md ステップ 6 / pr-review.md ステップ 6.1.a と対称化、`[fix:error]` 昇格) |
| `scope_omitted_in_v1_0` | schema 1.0/1.0.0 受信時に findings[].scope が欠落しているため severity ベースの default mapping で補完した (`REVIEW_SOURCE_SCOPE_DEFAULTED` flag、非ブロッキング、observability のみ)。本表の emit 元は Priority 3 string-based 鏡像 (ステップ 1.2.0.s)。file-based 版は `review-findings-maps.sh` が同名 reason を emit する (下記 bullet 参照) |
| `pre_existing_false_scope_nit_noted` | cross-field invariant #5 違反 — `pre_existing == false` × `scope == "nit-noted"` の finding を検出し、scope を `current-pr` に auto-correct した (`REVIEW_SOURCE_AUTO_CORRECTED` flag、非ブロッキング)。emit 元は Priority 3 鏡像 + `review-findings-maps.sh` の dual (下記 bullet 参照) |
| `jq_mutation_failed` | schema 1.1.0 normalization (default mapping + invariant #5 auto-correct) を行う jq mutation が失敗 (`REVIEW_SOURCE_NORMALIZATION_FAILED` flag、非ブロッキング、原 JSON のまま続行)。emit 元は Priority 3 鏡像 + `review-findings-maps.sh` の dual (下記 bullet 参照) |
| `low_current_pr_demoted_to_nit_noted` | `review.scope_assignment.auto_demote_low: true` (default) で `severity == "LOW"` ∧ `scope == "current-pr"` の finding scope を `nit-noted` に自動降格した (`REVIEW_SOURCE_AUTO_DEMOTED_LOW` flag、非ブロッキング)。`auto_demote_low: false` で opt-out 可。emit 元は Priority 3 鏡像 + `review-findings-maps.sh` の dual (下記 bullet 参照) |
| `pr_comment_scope_map_build_failed` | Priority 3 (pr_comment Raw JSON) で scope_map_json 構築用 jq が失敗 (`REVIEW_SOURCE_PARSE_FAILED` flag、非ブロッキング、`scope_map_json="{}"` で legacy blocking 扱いに fallback) |
| `review_source_resolve_failed` | ステップ 1.2.0 caller が `scripts/review-source-resolve.sh` の非ゼロ exit を検知した際の caller-side retained-flag (helper が具体 reason を `FIX_FALLBACK_FAILED` で stderr emit 済み、本 reason は drift Pattern 1 充足用の generic guard、`[fix:error]` 昇格) |
| `findings_maps_build_failed` | ステップ 1.2.0 caller が `scripts/review-findings-maps.sh` の非ゼロ exit を検知した際の caller-side retained-flag (helper が具体 reason — 典型は `severity_map_build_failed` — を `FIX_FALLBACK_FAILED` で stderr emit 済み、本 reason は drift Pattern 1 充足用の generic guard、`[fix:error]` 昇格。`review_source_resolve_failed` と同型) |
| `pr_comment_schema_version_jq_failed` | Priority 3 で PR コメント Raw JSON の `schema_version` 抽出 jq が失敗 (jq バイナリ異常 / OOM / pipe write error、`schema_version="unknown"` で継続し legacy Markdown parser へ fallthrough、`REVIEW_SOURCE_PARSE_FAILED` flag) |
| `broad_retrieval_jq_extraction_failed` | ステップ 1.2.0 Priority 3 Broad Comment Retrieval で `pr_comments` からの rite review コメント抽出 jq が失敗 (jq バイナリ異常 / OOM / GitHub API レスポンスの JSON 破損、tempfile 不在として `BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT` へ routing、`REVIEW_SOURCE_PARSE_FAILED` flag) |
| `git_rev_parse_head_failed` | Priority 3 の commit_sha stale detection 用 `git rev-parse HEAD` が失敗 (stale 判定を skip し `head_sha=""` で継続、`REVIEW_SOURCE_STALE_CHECK_FAILED` flag。`jq_error_on_commit_sha` と同じ stale-check namespace) |

> **Note**: Priority 0/2 (file-based) の severity_map build / normalization の reason は委譲先 helper `scripts/review-findings-maps.sh` が emit する (SoT は helper docstring)。委譲済 reason は「この SKILL.md 自身が emit する reason」と区別できるよう **markdown table 行にせず bullet 形式**で列挙し、本文 prose でも bare backtick 名で参照する。helper の stderr `[CONTEXT]` emit は caller の bash 出力として LLM コンテキストに surface するため、下記 reason は fix flow 上で従来どおり観測される。

**review-findings-maps.sh reasons** (helper が `[CONTEXT] REVIEW_SOURCE_*` / `FIX_FALLBACK_FAILED` を emit。normalization 系 4 reason — `scope_omitted_in_v1_0` / `pre_existing_false_scope_nit_noted` / `low_current_pr_demoted_to_nit_noted` / `jq_mutation_failed` — は Priority 3 鏡像も同名 emit するため上の table 行にも存在する):
- `mktemp_failure_norm_tmp`: schema 1.1.0 normalization 用 tempfile (`${TMPDIR:-/tmp}/rite-fix-normalized-XXXXXX`) の mktemp が失敗 (disk full / inode 枯渇 / read-only filesystem / permission denied、`REVIEW_SOURCE_NORMALIZATION_FAILED` flag、非ブロッキング、原 JSON のまま続行)。silent skip 防止のため WARNING + retained flag を必ず emit する
- `jq_duplicate_check_failed`: Priority 0/2 で重複 file:line 検出用 jq が失敗 (silent data loss 検出を skip、非ブロッキング)
- `severity_map_build_failed`: Priority 0/2 で severity_map 構築用 jq が失敗 (0 件で正常終了する silent regression 防止、helper exit 1 → caller が `findings_maps_build_failed` + `[fix:error]` に昇格)
- `scope_map_build_failed`: Priority 0/2 (file-based) で scope_map_json 構築用 jq が失敗 (`FIX_FALLBACK_FAILED` flag、非ブロッキング、`scope_map_json="{}"` で legacy blocking 扱いに fallback)

**Eval-order enumeration** (Pattern-2 documented-union input): 本 enumeration の reason は fix.md に対する Pattern-2 forward check の **documented set（reason 表 ∪ enumeration）** に寄与する。reason 表と本 enumeration は人間可読性のため同期させること（Pattern 2 はどちらか一方に存在すれば documented とみなすため、両者の厳密な同期や enumeration 側の reverse staleness — 列挙済だが emit されない reason — は機械検証されない）。reason を追加・削除する際は表と本 enumeration の両方を更新する (`scripts/review-findings-maps.sh` へ委譲済の reason は helper docstring 側の enumeration に記載するため本 enumeration には含めない)。emit reasons sequence = (`bash_version_incompatible` / `pr_number_placeholder_residue` / `overall_assessment_unknown_value` / `pr_comment_raw_json_awk_failed` / `pr_comment_raw_json_parse_failure` / `pr_comment_schema_required_fields_missing` / `pr_comment_cross_field_invariant_violated` / `pr_comment_critical_high_scope_nit_noted` / `pr_comment_schema_version_unknown` / `user_cancelled` / `user_file_path_invalid` / `review_file_path_empty_value` / `comment_body_tempfile_empty` / `pr_comment_commit_sha_mismatch` / `jq_error_on_commit_sha` / `pr_comment_severity_map_build_failed` / `pr_comment_tempfile_read_io_error` / `scope_omitted_in_v1_0` / `pre_existing_false_scope_nit_noted` / `jq_mutation_failed` / `low_current_pr_demoted_to_nit_noted` / `pr_comment_scope_map_build_failed` / `review_source_resolve_failed` / `findings_maps_build_failed`)

#### Legacy Branching (PR Comment Path Only)


**Branch by `{target_comment_id}`** (set in ステップ 1.0): the Legacy Branching (PR Comment Path Only) section has two execution paths depending on whether a comment URL was passed. The sub-sections below (Target Comment Fast Path / Broad Comment Retrieval) are **h4-level branches within the Legacy Branching section** and are independent execution paths — they are **not** numbered sub-phases of ステップ 1.2.1. The existing `### 1.2.1 Retrieve rite Review Results` is a separate, h3-level sub-phase that runs only when the Broad Comment Retrieval path is taken (i.e. when `{target_comment_id}` is NOT set).

#### Target Comment Fast Path — when `{target_comment_id}` is set

When `{target_comment_id}` has been extracted from a comment URL argument, retrieve that specific comment directly and skip the broad comment retrieval below:


**Block A — trap セットアップ + API fetch + jq 抽出 + intermediate 書き出し**

```bash
# Block A: trap + gh api + jq .body / .user.login 抽出 + raw_json + intermediate 3 ファイル (合計 4 ファイル) 書き出し
# 設計順序 (パス先行宣言 → trap 先行設定 → mktemp → gh api) と confidence_override 無条件 truncate の配置
# (統合 trap setup より前、trap 保護対象外) の理由: references/design-rationale.md#fast-path-block-design
# specific path 必須 (並列セッション破壊防止)。truncate 失敗は warning のみで継続。
: > "${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt" 2>/dev/null || \
  echo "WARNING: ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt の truncate に失敗しました (read-only / permission denied?)" >&2

raw_json="${TMPDIR:-/tmp}/rite-fix-raw-{pr_number}-{target_comment_id}.json"
intermediate_body="${TMPDIR:-/tmp}/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt"
intermediate_author="${TMPDIR:-/tmp}/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt"
intermediate_skip="${TMPDIR:-/tmp}/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt"

gh_api_err=""
jq_err=""

# trap + cleanup パターンの canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
blockA_committed=0
_rite_fix_blockA_cleanup() {
  rm -f "${gh_api_err:-}" "${jq_err:-}"
  if [ "$blockA_committed" = "0" ]; then
    rm -f "${raw_json:-}" "${intermediate_body:-}" "${intermediate_author:-}" "${intermediate_skip:-}"
  fi
}
trap 'rc=$?; _rite_fix_blockA_cleanup; exit $rc' EXIT
trap '_rite_fix_blockA_cleanup; exit 130' INT
trap '_rite_fix_blockA_cleanup; exit 143' TERM
trap '_rite_fix_blockA_cleanup; exit 129' HUP

# mktemp で gh_api_err を作成 (trap セットアップ後)
# 注: gh api の stderr は専用一時ファイルに退避し 2>&1 で stdout に混入させない (invalid JSON 化防止)
# rationale: references/design-rationale.md#fast-path-block-design
gh_api_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-gh-api-err-XXXXXX") || {
  echo "エラー: gh_api_err 一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=mktemp_failed_gh_api_err" >&2
  exit 1
}

# 対象コメントを直接取得 (gh api は 404 や認証エラー時に exit != 0 を返すため exit code を直接チェックする)
if ! target_comment=$(gh api repos/{owner}/{repo}/issues/comments/{target_comment_id} 2>"$gh_api_err"); then
  echo "エラー: コメント #{target_comment_id} の取得に失敗しました" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | sed 's/^/  /' >&2
  echo "対処: コメント URL が正しいか、削除されていないか、認証 (gh auth status) を確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi

# 空 stdout チェック (gh api が exit 0 でも空文字列を返すコーナーケース)
if [ -z "$target_comment" ] || [ "$target_comment" = "null" ]; then
  echo "エラー: コメント #{target_comment_id} の取得結果が空です (gh api exit 0 だが本文なし)" >&2
  echo "対処: コメント ID と権限を確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=empty_stdout" >&2
  exit 1
fi

# raw JSON を Block B 用に永続化 (Block B が .issue_url を jq で再抽出するため)
if ! printf '%s' "$target_comment" > "$raw_json"; then
  echo "エラー: raw JSON 一時ファイルの書き出しに失敗しました: $raw_json" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=raw_json_write_failed" >&2
  exit 1
fi

# jq_err mktemp (jq stderr 退避用)
jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-jq-err-XXXXXX") || {
  echo "エラー: jq エラー一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=mktemp_failed_jq_late_err" >&2
  exit 1
}

# jq .body 抽出 (parse error, jq バイナリ不在等を捕捉)
if ! target_body=$(printf '%s' "$target_comment" | jq -r '.body // empty' 2>"$jq_err"); then
  echo "エラー: gh api レスポンスの JSON パースに失敗しました (.body 抽出)" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=jq_current_body_extract_failed" >&2
  exit 1
fi
if [ -z "$target_body" ]; then
  echo "エラー: コメント #{target_comment_id} の body が空です" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=current_body_empty" >&2
  exit 1
fi

# jq .user.login 抽出 (fail-fast: .body 成功後の失敗は jq バイナリ異常 / 破損レスポンスの兆候)
if ! target_author=$(printf '%s' "$target_comment" | jq -r '.user.login // empty' 2>"$jq_err"); then
  echo "エラー: コメント #{target_comment_id} の author 抽出に失敗しました" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=jq_author_extract_failed" >&2
  exit 1
fi

# .user.login が empty (GitHub Apps bot / 削除済みユーザー等のコーナーケース) の場合、
# 空文字を保持して下流に mention 省略フラグとして伝達する (sentinel "unknown" は誤 mention の原因)。
# 下流 phase では `{target_author_mention_skip} == "true"` を参照して mention を生成しない。
target_author_mention_skip="false"
if [ -z "$target_author" ]; then
  target_author=""
  target_author_mention_skip="true"
  echo "WARNING: コメント #{target_comment_id} の .user.login が空です。" >&2
  echo "  下流 phase の mention 生成は target_author_mention_skip=true を参照して省略されます。" >&2
fi

# intermediate body/author/skip の 3 ファイルに書き出し (シェル変数は Block A 終了で失われるため永続化)。
# 各 printf の exit code を明示 check し fail-fast する (silent 空ファイル防止)。
if ! printf '%s' "$target_body" > "$intermediate_body"; then
  echo "エラー: Block A: intermediate_body の一時ファイル書き出しに失敗しました: $intermediate_body" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=intermediate_write_failed" >&2
  exit 1
fi
if ! printf '%s' "$target_author" > "$intermediate_author"; then
  echo "エラー: Block A: intermediate_author の一時ファイル書き出しに失敗しました: $intermediate_author" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=intermediate_write_failed" >&2
  exit 1
fi
if ! printf '%s' "$target_author_mention_skip" > "$intermediate_skip"; then
  echo "エラー: Block A: intermediate_skip の一時ファイル書き出しに失敗しました: $intermediate_skip" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=intermediate_write_failed" >&2
  exit 1
fi

# Block A 完了: raw_json + intermediate 3 ファイルを trap cleanup の対象から外す (blockA_committed=1)
# これ以降、Block A 末尾に到達しても trap は err files のみ削除する。
blockA_committed=1

# Block 境界 sentinel emit (observability / debugging trail)
# Block B 進入前に Claude がこの [CONTEXT] を grep することで Block A 正常完了を確認できる
echo "[CONTEXT] BLOCK_A_COMPLETE=1; pr_number={pr_number}; target_comment_id={target_comment_id}" >&2
```

**Block B — post-condition 検証 (`.issue_url` 所属 check + `pr_number` validate)**

```bash
# Block B: raw JSON 再読込 + .issue_url 抽出 + pr_number / URL suffix validate
# .issue_url post-condition で「コメント ID が別 PR/Issue に属する」silent misclassification を検出する
# (背景: references/design-rationale.md#fast-path-block-design)。

raw_json="${TMPDIR:-/tmp}/rite-fix-raw-{pr_number}-{target_comment_id}.json"
intermediate_body="${TMPDIR:-/tmp}/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt"
intermediate_author="${TMPDIR:-/tmp}/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt"
intermediate_skip="${TMPDIR:-/tmp}/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt"

jq_err=""

_rite_fix_blockB_cleanup() {
  rm -f "${jq_err:-}"
}
_rite_fix_blockB_invalidate_upstream() {
  rm -f "${raw_json:-}" "${intermediate_body:-}" "${intermediate_author:-}" "${intermediate_skip:-}"
}
# signal 別 trap: 正常 exit (rc=0) は upstream 保持 / 非 0 exit・signal (INT/TERM/HUP) は
# upstream を明示 invalidate する (validation skip 状態の intermediate 残留防止)
trap 'rc=$?; _rite_fix_blockB_cleanup; if [ "$rc" -ne 0 ]; then _rite_fix_blockB_invalidate_upstream; fi; exit $rc' EXIT
trap '_rite_fix_blockB_cleanup; _rite_fix_blockB_invalidate_upstream; exit 130' INT
trap '_rite_fix_blockB_cleanup; _rite_fix_blockB_invalidate_upstream; exit 143' TERM
trap '_rite_fix_blockB_cleanup; _rite_fix_blockB_invalidate_upstream; exit 129' HUP

# Block A の outputs が存在することを確認 (Block A がスキップされたケースの fail-fast)
if [ ! -s "$raw_json" ]; then
  echo "エラー: Block A の raw JSON 一時ファイルが存在しないか空です: $raw_json" >&2
  echo "  Block A が失敗しているか、並列実行で削除された可能性があります" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=raw_json_missing_at_block_b" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

jq_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-jq-err-XXXXXX") || {
  echo "エラー: jq エラー一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=mktemp_failed_jq_block_b" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
}

# raw JSON から .issue_url を再抽出 (jq -r でファイル入力を直接読む; pipe 不要)
if ! comment_issue_url=$(jq -r '.issue_url // empty' "$raw_json" 2>"$jq_err"); then
  echo "エラー: gh api レスポンスから .issue_url の抽出に失敗しました" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=jq_comment_id_extract_failed" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi
if [ -z "$comment_issue_url" ]; then
  echo "エラー: コメント #{target_comment_id} のレスポンスに .issue_url フィールドがありません" >&2
  echo "対処: gh api の生レスポンスを確認してください (GitHub API のスキーマ変更の可能性)" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=missing_issue_url" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

# pr_number が数字のみであることを事前 validate (defense-in-depth)。here-string は SIGPIPE 防止
if ! grep -qE '^[0-9]+$' <<< "{pr_number}"; then
  echo "エラー: pr_number が数字以外を含んでいます: '{pr_number}'" >&2
  echo "  ステップ 1.0 で正規化された pr_number は数字のみのはずですが、何らかの経路で異常値が混入しました" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=issue_number_not_found" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

# /pull/{pr_number} または /issues/{pr_number} を末尾に含むことを確認
# (GitHub では PR は内部的に Issue でもあるため、/issues/{N} と /pull/{N} のいずれかが返る)
if ! grep -qE "/(pull|issues)/{pr_number}$" <<< "$comment_issue_url"; then
  echo "エラー: コメント #{target_comment_id} は PR #{pr_number} に属していません (silent misclassification 検出)" >&2
  echo "  実際の所属: $comment_issue_url" >&2
  echo "  期待値: /pull/{pr_number} または /issues/{pr_number} で終わる URL" >&2
  echo "  対処: comment URL の pull/{N} 部分と #issuecomment-{ID} の整合性を確認してください。" >&2
  echo "         GitHub UI で comment URL を再コピーすることを推奨します。" >&2
  echo "[CONTEXT] FASTPATH_FETCH_FAILED=1; reason=pr_number_mismatch" >&2
  _rite_fix_blockB_invalidate_upstream
  exit 1
fi

# Block 境界 sentinel emit (observability / debugging trail)
echo "[CONTEXT] BLOCK_B_COMPLETE=1; pr_number={pr_number}; target_comment_id={target_comment_id}" >&2
```

**Block C — intermediate → final handoff 書き出し + post-condition + raw/intermediate cleanup**

```bash
# Block C: intermediate → final handoff 3 ファイル (body_file/author_file/skip_file) 書き出し +
# post-condition + raw/intermediate 削除。成功時は handoff_committed=1 を立てる。
# raw_json は存在 check のみ参照し内容は consume しない (trap cleanup 対象には含める)。
# rationale: references/design-rationale.md#fast-path-block-design

raw_json="${TMPDIR:-/tmp}/rite-fix-raw-{pr_number}-{target_comment_id}.json"
intermediate_body="${TMPDIR:-/tmp}/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt"
intermediate_author="${TMPDIR:-/tmp}/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt"
intermediate_skip="${TMPDIR:-/tmp}/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt"

body_file="${TMPDIR:-/tmp}/rite-fix-target-body-{pr_number}-{target_comment_id}.txt"
author_file="${TMPDIR:-/tmp}/rite-fix-target-author-{pr_number}-{target_comment_id}.txt"
skip_file="${TMPDIR:-/tmp}/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt"

handoff_committed=0
_rite_fix_blockC_cleanup() {
  if [ "$handoff_committed" = "0" ]; then
    rm -f "${body_file:-}" "${author_file:-}" "${skip_file:-}"
  fi
  rm -f "${raw_json:-}" "${intermediate_body:-}" "${intermediate_author:-}" "${intermediate_skip:-}"
}
trap 'rc=$?; _rite_fix_blockC_cleanup; exit $rc' EXIT
trap '_rite_fix_blockC_cleanup; exit 130' INT
trap '_rite_fix_blockC_cleanup; exit 143' TERM
trap '_rite_fix_blockC_cleanup; exit 129' HUP

# intermediate + raw_json 存在確認 (Block A/B skip / 失敗ケースの fail-fast)
# intermediate_author は空文字列でも許容 (mention_skip=true の sentinel) のため -f のみ検査
if [ ! -s "$intermediate_body" ] || [ ! -f "$intermediate_author" ] || [ ! -s "$intermediate_skip" ] || [ ! -s "$raw_json" ]; then
  echo "エラー: Block A/B の intermediate ファイルが存在しないか空です" >&2
  echo "  body=$intermediate_body ($([ -s "$intermediate_body" ] && echo ok || echo empty_or_missing))" >&2
  echo "  author=$intermediate_author ($([ -f "$intermediate_author" ] && echo ok || echo missing))" >&2
  echo "  skip=$intermediate_skip ($([ -s "$intermediate_skip" ] && echo ok || echo empty_or_missing))" >&2
  echo "  raw_json=$raw_json ($([ -s "$raw_json" ] && echo ok || echo empty_or_missing))" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=intermediate_missing_at_block_c" >&2
  exit 1
fi

# intermediate → final handoff コピー。cat の exit code を check し silent 空ファイルを防ぐ。
# エラーメッセージの Block 識別子 (Block C) は Block A の書き出し失敗との区別のため必須
if ! cat "$intermediate_body" > "$body_file"; then
  echo "エラー: Block C: handoff コピーに失敗しました (intermediate_body → body_file): $body_file" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=paste_io_error" >&2
  exit 1
fi
if ! cat "$intermediate_author" > "$author_file"; then
  echo "エラー: Block C: handoff コピーに失敗しました (intermediate_author → author_file): $author_file" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=paste_io_error" >&2
  exit 1
fi
if ! cat "$intermediate_skip" > "$skip_file"; then
  echo "エラー: Block C: handoff コピーに失敗しました (intermediate_skip → skip_file): $skip_file" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=paste_io_error" >&2
  exit 1
fi

# 書き出し後の post-condition check (non-empty かつ存在することを確認)
# body_file / skip_file は必ず non-empty (intermediate_body / intermediate_skip が non-empty だったため)
# author_file は空文字列でも許容 (target_author_mention_skip=true の sentinel として使う)
if [ ! -s "$body_file" ]; then
  echo "エラー: body_file の post-condition check に失敗: $body_file が空または存在しません" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=pr_body_tmp_empty_or_missing" >&2
  exit 1
fi
if [ ! -f "$author_file" ]; then
  echo "エラー: author_file の post-condition check に失敗: $author_file が存在しません" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=author_file_missing_at_post_condition" >&2
  exit 1
fi
if [ ! -s "$skip_file" ]; then
  echo "エラー: skip_file の post-condition check に失敗: $skip_file が空または存在しません" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=skip_file_empty_at_post_condition" >&2
  exit 1
fi

# Block C 完了: handoff 3 ファイルを trap cleanup 対象から外す (以降は後続 phase の cleanup —
# ステップ 1.5 / Fast Path Cancel exit / Step C error exit — で明示的に削除する)
handoff_committed=1

# Block 境界 sentinel emit (observability / debugging trail)。body_file= / author_file= /
# skip_file= は後続 phase の Read tool 参照用の実パス (sandbox 環境で $TMPDIR 配下となるため、
# リテラル /tmp 前提で読めない。handoff 3 本すべてを surface する — 片方だけの marker 化は
# sibling の取り残しになる)
echo "[CONTEXT] BLOCK_C_COMPLETE=1; pr_number={pr_number}; target_comment_id={target_comment_id}; body_file=$body_file; author_file=$author_file; skip_file=$skip_file" >&2
```


**Parsing rule**:

> `$target_body` の実体は Block C が書き出した body_file であり、Claude は **Block C の `[CONTEXT] BLOCK_C_COMPLETE` marker の `body_file=` 値をリテラル使用して Read tool で読む**（Read tool は `${TMPDIR:-/tmp}` を展開できないため documented path 形式では読めない。specific path 必須、wildcard glob 禁止）。

1. If `$target_body` contains `## 📜 rite レビュー結果`: **ステップ 1.2.1 で定義された table パースロジック** (`### 全指摘事項` を起点に reviewer サブセクションごとの table を解析し `severity_map` を構築する手順) を `$target_body` に対して適用する。**ステップ 1.2.1 のコメント取得処理 (broad retrieval) は実行しない** — 対象コメントは既に取得済みのため
2. Otherwise (外部ツール: `/verified-review` skill、`pr-review-toolkit:review-pr` plugin、手動コメント等): **best-effort parse**
   - **期待スキーマ**: 最低 **4 カラム** または **5 カラム** を持つ markdown table。デフォルト列順は `| severity | file:line | content | recommendation [| confidence] |` (5 列目の confidence は optional)。ヘッダー行が存在する場合はそこから列順を推定する
   - **ヘッダー行検出 (正規キーワードセット)**: 表の 1 行目に以下のキーワードのいずれかを含む行を検出した場合、その列順を使用する。検出成否は必ずログに記録する:

     | 列名 | 認識キーワード (大文字小文字無視) | 必須/任意 |
     |------|-----------------------------------|----------|
     | severity | `severity`, `重要度`, `sev`, `level`, `深刻度`, `priority` | 必須 |
     | file:line | `file`, `ファイル`, `path`, `location`, `場所` | 必須 |
     | content | `content`, `内容`, `message`, `description`, `指摘`, `issue` | 必須 |
     | recommendation | `recommendation`, `推奨`, `fix`, `suggestion`, `対応`, `action` | 必須 |
     | confidence | `confidence`, `信頼度`, `conf`, `score`, `確信度` | **任意** (5 列目) |

     **検出ログ**: 以下を **stderr に必ず出力** する。E2E Output Minimization の対象外とし、parse の健全性を後追いできるようにする:
     - ヘッダー検出成功 (4 列): `Header detected: yes (4 columns). Column order: [severity, file, content, recommendation]. Confidence column: not found (will use Confidence=70 暫定値)`
     - ヘッダー検出成功 (5 列): `Header detected: yes (5 columns). Column order: [severity, file, content, recommendation, confidence]. Confidence column: found at index {N}`
     - ヘッダー検出失敗: `Header detected: no. Using default column order [severity, file, content, recommendation]. Confidence column: not assumed`
   - **ヘッダー行なし**: デフォルト列順 `severity | file:line | content | recommendation` を仮定する (上記の `Header detected: no` ログを stderr に必ず出力する)。Confidence 列はヘッダーなしの場合は仮定しない (ユーザーが明示的にヘッダー行を書いた場合のみ confidence 列を尊重する)
   - **カラム数不足の扱い**:
     - **3 カラム以下**: そのテーブル行を "unparseable" として skip し、警告ログ (`WARNING: Skipping unparseable row (columns < 4): <row preview>`) に記録する
     - **4 カラム**: severity / file:line / content / recommendation として抽出 (Confidence 列なし → Confidence=70 暫定値、後述の取り扱いルール参照)
     - **5 カラム以上**: ヘッダー行で confidence 列が検出された場合はその index から抽出。検出されなかった場合は最初の 4 カラムを使用し、5 列目以降は **silent 破棄せず WARNING で通知する**:
       ```
       WARNING: 5 列以上のテーブルですが、ヘッダー行から confidence 列を特定できませんでした。
       5 列目以降の値は破棄されます。Confidence 列を使うにはヘッダー行に
       'confidence' / '信頼度' / 'conf' / 'score' / '確信度' のいずれかを含めてください。
       ```
   - **severity 別名マッピング** (大文字小文字無視で完全一致を試行する。Title Case や lower case の値も正規化対象): CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW 以外の値が出現した場合、以下の別名マッピングを試行する。**比較は必ず case-insensitive** で行うこと (例: `Critical` / `critical` / `CRITICAL` はいずれも `CRITICAL` にマッチ):

     | 認識される別名 (case-insensitive 比較) | 正規化先 |
     |---------------------------------------|---------|
     | `Critical`, `BLOCKER`, `CRIT`, `🔴`, `重大`, `致命` | `CRITICAL` |
     | `Important`, `MAJOR`, `HIGH`, `🟠`, `重要`, `高` | `HIGH` |
     | `Minor`, `MEDIUM`, `🟡`, `中`, `Normal` | `MEDIUM` |
     | `Low-Medium`, `LowMedium`, `low_medium`, `中低`, `軽中` | `LOW-MEDIUM` |
     | `Low`, `INFO`, `TRIVIAL`, `🔵`, `低`, `情報` | `LOW` |

     > **Note — 既知の外部ツール出力形式**: rite plugin 配下に `/verified-review` は存在しない (実体はユーザーレベルの `~/.claude/commands/verified-review.md` にある独立コマンドで、rite plugin が提供するものではない)。同コマンドが出力するレビュー結果テーブルは `重要度` 列に **Title Case の `Critical` / `Important`** を使うため、上記マッピング表ではこれらを HIGH / CRITICAL に正規化する経路を必須としている。`pr-review-toolkit:review-pr` も同様に Title Case を使う場合があり、同じ経路で吸収される。
     >
     > **絵文字エイリアスの実運用検証状況**: 絵文字 (`🔴`/`🟠`/`🟡`/`🔵`) は将来の互換性のため列挙しているが、上記 2 ツールが絵文字を出力する事例は未検証。新しい外部レビューツールへの対応として絵文字エイリアスを追加した場合は、本 Note にツール名を追記すること。

     - 上記のいずれにもマッチしない場合、`MEDIUM` をデフォルトとし、**認識不能な severity 値の一覧をユーザーに必ず警告表示する** (silent fallback 禁止):
       ```
       警告: 認識不能な severity 値が {N} 件あります
       - 値: ['{val_1}', '{val_2}', ...]
       - すべて MEDIUM として扱いますが、適切な対応のため手動で再分類してください
       - 認識可能な severity: CRITICAL / HIGH / MEDIUM / LOW-MEDIUM / LOW (または上記の別名)
       ```
   - **全テーブル行がパース不能** または **抽出結果 0 件** の場合、警告を表示してユーザーに確認を求める (silent failure 回避):
     ```
     警告: コメント #{target_comment_id} ({reviewer_display}) から finding をパースできませんでした
     - スキップした行: {N} 行 (4 カラム未満)
     - 認識された行: 0 件
     内容プレビュー: {target_body の先頭 300 文字}
     オプション:
       - 手動で finding を入力
       - 別のコメント URL を指定
       - キャンセル
     ```

     **`{reviewer_display}` の展開**: ステップ 2.1 の `{reviewer_display}` 展開ルール表を参照する。Fast Path 経由で `target_author_mention_skip == "true"` の場合は `(不明なレビュアー)` / `(unknown reviewer)` に置換し、`@` prefix は絶対に生成しない (silent `@unknown` 誤記録防止)。通常時は `@{target_author}` を使用する。

   **選択肢の処理ルール (silent fall-through 禁止)**:

   | ユーザー応答 | 処理 |
   |-------------|------|
   | **手動で finding を入力** | ステップ 1.4 (Display Comment List) で finding 手動入力モードに移行 (入力スキーマ: `severity \| file:line \| content \| recommendation` のテーブル) |
   | **別のコメント URL を指定** | **Fast Path ハンドオフ一時ファイルを cleanup してから** ステップ 1.0 から再実行 (新しい argument を要求)。詳細は下記「Cancel/Re-run 経路でのハンドオフ cleanup 義務」参照 |
   | **キャンセル** | **Fast Path ハンドオフ一時ファイルを cleanup してから** `[fix:cancelled-by-user]` を出力して exit 0 |

   **Cancel/Re-run 経路でのハンドオフ cleanup 義務** (silent orphan ファイル防止):

   `[fix:cancelled-by-user]` exit 0 / `[fix:error]` exit 1 / ステップ 1.0 再実行のいずれかへ進む直前に、Fast Path で作成した一時ファイル (ハンドオフ 3 + raw_json + intermediate 3 + confidence_override、合計 8 本) を **明示的に削除する** bash 呼び出しを必ず実行する。これは ステップ 1.5 cleanup を経由しないすべての終了経路における defense-in-depth であり、ステップ 1.4 末尾の ステップ 1.5 cleanup から到達しない経路をカバーする:

   ```bash
   # Cancel / Re-run / Step C error 共通: ハンドオフ 3 + raw_json + intermediate 3 + confidence_override + pr-comment tempfile (合計 9 本) を削除してから exit する
   # Fast Path bash block 外なので変数は失われている → specific path で直接削除する
   # (wildcard glob は並列セッション破壊のため絶対禁止。rm -f は idempotent なので二重削除でも副作用なし)
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

   この cleanup を実行する 3 つの経路:
   - Cancel 選択 → cleanup → **(E2E flow 時) FINALIZE handoff set** → `[fix:cancelled-by-user]` 出力 → exit 0。FINALIZE handoff (`FINALIZE:fix:cancelled-by-user:{pr_number}`) は ステップ 1.4 cancel と同一 — ステップ 1.4 の「FINALIZE handoff の設定 (E2E flow 時のみ)」bash を参照し、standalone では実行しない (AC-4)
   - Re-run 選択 → cleanup → ステップ 1.0 から新しい引数で再実行 (handoff は set しない — 終了ではなく再実行のため)
   - Step C 「2 回目も解釈不能」→ cleanup → `[fix:error]` 出力 → exit 1 (handoff は set しない — `[fix:error]` は clean terminal ではないため)

   **解釈不能の判定基準と再質問ループ** (silent fall-through 防止):

   **Step A — option ID 完全一致の厳格判定** (最優先):

   まず、ユーザー応答を trim + lowercase した文字列が以下の option ID 集合のいずれかに**完全一致**するかを判定する:

   | Option ID | 対応する選択肢 |
   |-----------|----------------|
   | `1`, `a`, `手動`, `manual` | 手動で finding を入力 |
   | `2`, `b`, `url`, `link` | 別のコメント URL を指定 |
   | `3`, `c`, `cancel`, `キャンセル` | キャンセル |

   完全一致が成立した場合、それを採用する。**これにより「キャンセルせず手動で入力する」のような否定形文は Step A では完全一致しないため次の Step B に進む**。

   **Step B — 否定語前処理を伴う部分マッチ判定** (Step A で完全一致しなかった場合):

   1. **否定語前処理**: ユーザー応答に否定語 (`せず`, `しないで`, `ではなく`, `なしで`, `without`, `not`) が含まれる場合、否定語**直前**のキーワードを打ち消し集合に加える。例: 「キャンセルせず手動で」 → 否定語「せず」の直前「キャンセル」を打ち消し集合 `{キャンセル}` に加える
   2. **キーワード判定表** (打ち消し集合を除外した上で、優先順位順に**最初にマッチした option を選択**):

      | 優先 | Option | マッチ条件 (大文字小文字無視、OR) |
      |------|--------|----------------------------------|
      | 1 | キャンセル | `キャンセル`, `cancel`, `中止`, `やめ`, `abort`（打ち消し集合に含まれる語はスキップ） |
      | 2 | 手動で finding を入力 | `手動`, `入力`, `manual` |
      | 3 | 別のコメント URL を指定 | `別`, `url`, `link`, `新しい`, `別の URL`, `another`（「コメント」単独は誤マッチが多いため削除。Step A の Option 2 と語彙を揃える） |

   <!-- rationale: references/design-rationale.md#interpretation-priority -->

   **Step C — Step A も Step B も決着しない場合**: 以下のいずれかに該当すれば**解釈不能**と判定する:

   - Step A で完全一致せず、Step B でもマッチキーワードが 1 つもない応答 (例: 「さあ...」「どうしよう」)
   - 空文字列 / whitespace のみの応答
   - 打ち消し集合により Step B の全 option がスキップされた結果、マッチが 0 件になった応答

   解釈不能を検出した場合の処理:

   1. **1 回だけ再質問**: 以下のメッセージを表示し、もう 1 度同じ AskUserQuestion を発行する。**「これは 2 回目の質問です」を必ず明示**する:
      ```
      ⚠️ これは 2 回目の質問です。応答を解釈できませんでした。
      3 つの option のいずれかを明確に選択してください (番号 1/2/3 または略語 a/b/c も可):

      1. 手動で finding を入力
      2. 別のコメント URL を指定
      3. キャンセル

      次回も解釈不能な応答の場合、処理を中止します。
      ```
   2. **再質問の応答も解釈不能の場合**: 上記「Cancel/Re-run 経路でのハンドオフ cleanup 義務」の bash block を実行して Fast Path の全一時ファイル (合計 8 本) を削除してから、`[fix:error]` を出力して exit 1 (**parse 0 件のまま ステップ 2 進入は禁止**)。エラーメッセージに「解釈不能な応答が 2 回続いたため処理を中止しました。fix loop を手動で再実行してください」を含める

   **重要**: parse 0 件で ステップ 2 (Categorization) に進入することは silent failure として禁止する。必ず上記の選択肢のいずれかを処理した上で次の Phase へ進むこと。
3. `{target_comment_id}` 経由で取得した finding のみを fix ループの対象とする。ステップ 1.2 の「全コメント取得」はスキップされる

**外部ツール由来 finding の Confidence ゲート** (`feedback_review_zero_findings` / `feedback_review_quality.md` 準拠):

外部ツール (`/verified-review`, `pr-review-toolkit:review-pr`, 手動コメント等) のコメントは `📜 rite レビュー結果` と異なり、Confidence 列を持たない形式が多い。そのまま fix ループに投入すると hallucinated finding (Confidence < 80 相当) が修正対象になり、rite の「Confidence 80+ のみ取り込み」原則を破る。

**取り扱いルール**:

| 状況 | 処理 | `confidence_override_findings` 追跡 |
|------|------|------------------------------------|
| テーブルに Confidence 列が存在し数値がある (`>= 80`) | そのまま Confidence として採用、取り込み | 不要 (override ではない通常の取り込み) |
| テーブルに Confidence 列が存在し数値がある (`< 80`) | 警告表示の上でスキップ | 不要 (取り込まないため) |
| Confidence 列がない、または数値が欠落 | **暫定値 Confidence=70 (< 80) を割り当て**、LOW に降格し、以下の警告を **stderr に必ず出力** する (silent pass 禁止): `WARNING: 外部ツール由来 finding {N} 件に Confidence 記載なし。暫定的に LOW/Confidence=70 として扱います。取り込み前にユーザー確認を求めます。` | **必須**: ユーザーが「Confidence 70 のままバイパス」を選択した finding を `confidence_override_findings` に append |
| severity 別名マッピングによる MEDIUM fallback (severity 不明) | 同様に Confidence=70 扱いとし、ユーザー確認を求める | **必須**: 上記と同じく override が確定した finding を append (severity 不明 fallback も Confidence override の追跡対象として扱う) |

暫定 Confidence 値が割り当てられた finding については、`AskUserQuestion` で以下のいずれかを選択させる:
- **Confidence 70 のまま 80+ ゲートをバイパスして投入 (policy override)** — finding を fix ループに投入するが、Confidence は 70 のまま保持し、`confidence_override=true` フラグを finding metadata に記録する。昇格ではなくバイパスであることをユーザーに明示する
- **LOW として記録のみ** — fix ループには投入せず、後日レビュー対象として残す

**Confidence override の追跡義務** (silent 改竄防止): 「Confidence 70 のままバイパス」を選択した finding については、以下の出力箇所で明示的に可視化する:
- ステップ 4.6 完了報告に `confidence_override: N 件` を追加
- ステップ 4.5.3 work memory のレビュー対応履歴に `- confidence_override: {file:line} (外部ツール由来、ユーザーがバイパスを承認)` を記録

**Retained context flags + tempfile-based persistence** (ステップ 4.5.3 / 4.6 / 4.3.4 の placeholder 展開時に参照する変数):


| Flag | 型 | 初期値 | 永続化先 |
|------|---|--------|---------|
| **`confidence_override_count`** | int | `0` | `wc -l < ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` の出力 (空ファイル → `0`) |
| **`confidence_override_findings`** | list[str] (`"file:line"` の配列) | `[]` | `${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` の各行 (1 行 1 finding) |

**Tempfile lifecycle** (specific path 必須、wildcard glob 禁止):

- **Path**: `${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` ({pr_number} は ステップ 1.0 で正規化済み)
- **作成タイミング**: ステップ 1.2 best-effort parse で最初の override 候補が出現した時点で **truncate 付きで作成** (`: > {path}` または `printf '' > {path}`)。`touch` は既存ファイルを truncate しないため使用禁止 (理由: [design-rationale.md#confidence-gate-notes](references/design-rationale.md#confidence-gate-notes))。
- **追記タイミング**: AskUserQuestion で「Confidence 70 のままバイパス」が選択されるたびに `printf '%s\n' "{file}:{line}" >> {path}`
- **読み出しタイミング**: ステップ 4.6 / 4.5.3 / 4.3.4 で `wc -l < {path}` (件数) / `cat {path}` (本文) で取得
- **削除タイミング**: 以下の **すべての終了経路** で明示的に削除する (orphan 防止、specific path 必須):
  - **E2E flow**: ステップ 5.1 の output pattern emit 直後
  - **Standalone flow**: ステップ 5 は skip されるため、ステップ 4.6 の completion report 出力後に明示的 cleanup bash block を実行する
  - **ステップ 1.4 cancel 経路**: 既存の Fast Path 一時ファイル cleanup bash block に追加 (同一 block 内で削除)
  - **ステップ 1.2 best-effort parse error 経路**: Cancel/Re-run cleanup に追加
- **並列セッション分離**: `{pr_number}` suffix で specific path とすることで、並列 fix 実行時の他セッション破壊を防ぐ。`${TMPDIR:-/tmp}/rite-fix-confidence-override-*.txt` のような wildcard glob は **絶対に使わない**

**Claude による retain と再注入の手順** (data flow の具体化、ファイル永続化版):

1. **H-1 修正**: ステップ 1.2 進入時 (Fast Path / Broad Retrieval bash block 冒頭の両方) で `: > ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` を **無条件 truncate** する。これにより、SIGINT/SIGTERM/SIGHUP で前セッションの override file が orphan として残った場合でも、次回起動時の混入を決定論的に防ぐ。また、ステップ 1.2 best-effort parse で最初の override 候補が出現した時点でも追加で truncate してよい (defense-in-depth、害なし)
2. AskUserQuestion で「Confidence 70 のままバイパス」が選択されるたびに、bash block 内で `printf '%s\n' "{file}:{line}" >> ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` を実行 (追記、`>>` で append)
3. ステップ 4.6 / 4.5.3 / 4.3.4 の placeholder 展開時、bash block で以下を実行して値を取得 (会話履歴 grep に依存しない、`2>/dev/null` の silent IO suppression も撤廃):
   ```bash
   override_path="${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt"
   if [ -f "$override_path" ]; then
     # wc -l の stderr を独立退避 (IO エラーの silent count=0 化で監査トレースが drop するのを防ぐ)
     override_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-confidence-override-err-XXXXXX") || {
       echo "ERROR: override_err mktemp 失敗" >&2
       echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=mktemp_failed_override_err" >&2
       exit 1
     }
     if ! confidence_override_count_raw=$(wc -l < "$override_path" 2>"$override_err"); then
       echo "ERROR: wc -l による override_path 読み出し失敗: $(cat "$override_err")" >&2
       echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=wc_io_error; path=$override_path" >&2
       rm -f "$override_err"
       exit 1
     fi
     confidence_override_count=$(printf '%s' "$confidence_override_count_raw" | tr -d ' ')
     # findings 一覧 (1 行 1 finding) は paste で "; " 区切りに変換
     if ! confidence_override_findings_raw=$(paste -sd ';' "$override_path" 2>"$override_err"); then
       echo "ERROR: paste による override_path 読み出し失敗: $(cat "$override_err")" >&2
       echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=paste_io_error; path=$override_path" >&2
       rm -f "$override_err"
       exit 1
     fi
     confidence_override_findings_str=$(printf '%s' "$confidence_override_findings_raw" | sed 's/;/; /g')
     rm -f "$override_err"
   else
     confidence_override_count=0
     confidence_override_findings_str=""
   fi
   ```
4. fix ループ中に他のフェーズから上記ファイルを上書きしない (append-only)
5. 終了経路の明示的削除:
   - **E2E flow (ステップ 5.1)**: `rm -f ${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt`
   - **Standalone flow (ステップ 5.2)**: ステップ 4.6 の completion report 出力後に明示的 cleanup bash block で削除
   - **ステップ 1.4 cancel 経路**: Fast Path ハンドオフ cleanup bash block 内で同時に削除 (下記 Cancel cleanup block 参照)
   - **ステップ 1.2 best-effort parse cancel/error 経路**: 「Cancel/Re-run 経路でのハンドオフ cleanup 義務」bash block 内で同時に削除

**互換性**: 旧 `[CONTEXT] confidence_override_count = N; confidence_override_findings = [...]` 行の emit は、debug 補助として **継続して併用してよい** (人間が tail で見えるケースのため)。ただし機械的な値の取得は必ずファイル経由とし、`[CONTEXT]` 行の grep には依存しない。

**ステップ 4.6 / 4.5.3 / 4.3.4 で参照する placeholder 一覧**:

| Phase | placeholder | 展開ルール |
|-------|-------------|----------|
| 4.6 (完了報告) | `{confidence_override_count}` | `confidence_override_count` の値をそのまま展開 (0 含む) |
| 4.6 (完了報告) | `{confidence_override_files_suffix}` | `confidence_override_count == 0` なら空文字列、`>= 1` なら ` (file_a.ts:10; file_b.ts:42; ...)` (先頭スペース付きカッコ + 配列を `; ` 区切り) |
| 4.5.3 (work memory) | `{confidence_override_section}` | `confidence_override_count == 0` なら `なし`、`>= 1` なら同一行に `; ` 区切りで `findings` を列挙 (改行不要、Markdown bullet 構造を壊さない) |
| 4.3.4 (Issue 本文) | `{confidence_value}` | finding 単位の値。rite review 由来なら finding の severity (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW)、外部ツール由来かつ Confidence 列なしなら literal `70 (暫定)` |
| 4.3.4 (Issue 本文) | `{confidence_override_value}` | finding 単位の boolean。`confidence_override_findings` に当該 file:line が含まれていれば `true (外部ツール由来、Confidence 70 のまま 80+ ゲートをバイパスする policy override、ユーザー承認済み)`、それ以外は `false` |

この手順により、外部レビューツールの信頼度を silent に無視することなく、かつ hallucinated finding の混入も防ぎ、かつ Confidence 80+ ゲート invariant の破壊を silent に起こさない (override は常に trackable)。


パース完了後、抽出した findings を持って直接 ステップ 2 (Categorization) に進む。ステップ 1.2 の Broad Comment Retrieval ブロックおよび ステップ 1.2.1 のフィルタ選択処理は Fast Path では実行しない (対象コメントは既に取得済みのため)。ステップ 1.2.1 の Markdown table parsing algorithm のみを `$target_body` に適用する。

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

**Implementation note for Claude**: `$pr_comments` はシェル変数ではなく、**会話コンテキスト内で保持するデータ**として扱うこと。Claude Code が各 bash コードブロックを個別の Bash ツール呼び出しで実行する場合、シェル変数はブロック間で引き継がれない。ステップ 1.2.1 では、この値をコンテキストから読み直すか、ステップ 1.2 のコードブロックと ステップ 1.2.1 のコードブロックを単一の Bash ツール呼び出しとして結合して実行すること。

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
4. Map severity using file:line as the key

**Search method:**

```bash
# ステップ 1.2 で取得済みの pr_comments から rite レビュー結果を検索（API 呼び出しなし）
# 注: $pr_comments はコンテキスト保持データ。ステップ 1.2 と同一 Bash ツール呼び出しで実行するか、
#     コンテキストから値を再注入すること（各 bash ブロックを個別に実行する場合、シェル変数は引き継がれない）
echo "$pr_comments" | jq '[.[] | select(.body | contains("## 📜 rite レビュー結果"))] | sort_by(.createdAt) | last | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'
```

**Note**: When multiple rite review result comments exist (when review has been run multiple times), use the one with the most recent `createdAt`.

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
5. Retain as `severity_map` (consolidating findings from all reviewers):
   ```
   severity_map = {
     "src/auth.ts:42": "CRITICAL",
     "src/api.ts:18": "HIGH",
     "src/utils.ts:55": "MEDIUM",
     "src/config.ts:10": "LOW"
   }
   ```

6. **`### 実測なし指摘 (non-blocking)` セクションの抽出 + `measured_map` 構築 (実測必須ゲート)**: コメント本文に `### 実測なし指摘 (non-blocking)` で**前方一致**する見出し (テンプレート実体は「（該当がある場合のみ）」等の注記が付く) のセクションが存在する場合、その配下の表 (**6 列**: レビュアー | 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 — `全指摘事項` の 5 列と列数が異なる点に注意。列ズレ防止のため本セクション専用の 6 列パースを適用する) の各行を `non_blocking_findings` として retain し、**severity_map / scope_map にも通常どおり投入した上で** `measured_map[file:line] = false` として登録する (母集団を severity_map に統一 — 除外すると 1.3 step 4 に到達できず、rite finding 由来の co-located thread まで一律 External review へ落ちて measured 判定を受けられない。非 rite thread を意図的に External review へ振り替えるのは step 4 の出自確認の役割で、両者は別物)。`### 全指摘事項` 由来の行は `measured_map[file:line] = true` として登録する。

   **measured_map 構築の共通規則 (JSON / Markdown / 会話の全経路に適用)**:
   - (a) **scope による登録除外はしない — 全 finding を `measured_map` に登録する**。nit-noted の除外は登録時ではなく**参照時に正規化後の `scope_map` を引いて**行う (1.3 step 4 の nit 分岐が measured lookup より先に評価される)。理由: `measured_map` は正規化**前**の原ファイル (`{review_source_path}`) から構築されるのに対し `scope_map` は `review-findings-maps.sh` の正規化 (auto_demote_low / invariant #5 auto-correct) **後** tempfile 由来のため、登録条件に原ファイルの scope を使うと 2 つの map が別 scope を見て「auto-demote された finding の二重計上 (finalize 等式破綻)」と「auto-correct された finding の未登録 = 未判定扱いによるゲート bypass」の両方向に破綻する。**なお本破綻シナリオが成立するのは、`false` を持つ finding の scope が正規化で書き換わるときに限る** (ゲート配線後の JSON 経路に入る `false` は `scope == "nit-noted"` の非実測 finding 由来のみ — gated な `measured=false` は `non_blocking_findings[]` へ移送され `findings[]` に残らない。現行世代の JSON は `pre_existing` を持たず invariant #5 が発火しないため、この scope は正規化後も nit-noted のまま)。規則自体は fail-safe として無害なため先行して固定しておく。
   - (b) **key 正規化は severity_map と同一** (`line == null || line == 0` → `{file}:anchor`)。
   - (c) **同一 key の衝突は `true` (blocking) 優先** — false で上書きしない (blocking-biased fail-safe: 複数 reviewer が同一 file:line を指摘し一方のみ実測付きの場合、実測済み blocking 指摘の silent skip を防ぐ)。
   - (d) **3 値を潰さない** — 登録するのは「実測の有無を判定できた finding」のみ。判定する構造が無い finding (外部ツール / 人間レビュー由来、および JSON に `verification` が無い finding) は**未登録のまま残す** (= 未判定)。未判定を `false` に畳んではならない (実測必須ゲートの対象外 = 従来どおり blocking。SoT は [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) の「適用範囲 (measured は 3 値)」)。

   件数 `non_blocking_count` は **`measured_map` の `false` のうち `scope_map[key] != "nit-noted"` の件数** (正規化後 scope による nit 除外 — `acknowledged_nit_count` との二重計上を参照時に遮断) として導出し、ステップ 1.4 表示・ステップ 4.6 集計に使う (ステップ 1.3 の non-blocking 分類条件と同一フィルタ。ただし step 4 の**出自確認で External review へ振り替えた key は分類数から外れる**ため、その分だけ「分類数 < カウント」になる — **振り替えた key のみ**を導出時に減算する (対応する GitHub thread が存在しない key は減算対象ではない — rite は per-line thread を作らないため既定構成では大半がこれに該当する))。セクション不在時は当該登録なし (`non_blocking_count = 0`)。**経路間で値は一致しない**: `/rite:pr-review` ステップ 5.3.0.M の `review-measured-gate.sh` が gated な非実測 finding を `findings[]` から `non_blocking_findings[]` へ移送する契約のため、JSON 経路 (Priority 0/2/3) の `measured_map` に入る `false` は `scope == "nit-noted"` の非実測 finding 由来のみで、上記の nit 除外フィルタに掛かるため `non_blocking_count` は 0 になる。N 件が入るのは `### 実測なし指摘 (non-blocking)` section を読める Markdown / 会話経路のみ。write 側が `verification` を出力する前提は #2072 で満たされたが、5.3.0.M の移送契約は現行のままのため、全経路一致は未成立。

**Note**: When multiple reviewers have flagged the same file:line, adopt the highest severity (CRITICAL > HIGH > MEDIUM > LOW-MEDIUM > LOW). The `scope` column is consumed downstream by `/rite:fix` ステップ 2 (nit-noted 受け流し経路) to determine acknowledge vs. fix-required handling.

**When rite review results are not found:**

When no rite review results exist in PR comments (manual review only, or `/rite:pr-review` was not run):
- Continue processing with an empty `severity_map`
- ステップ 1.3 falls back to GitHub state-based classification

### 1.3 Classify Comments

Perform classification using `severity_map` AND `scope_map`. The scope_map enables `nit-noted` findings to be routed away from the blocking fix loop into the reply-only acknowledge track.

**Classification table:**

| Classification | Criteria | Action |
|---------------|----------|--------|
| **Required fix** | severity ∈ {CRITICAL, HIGH} AND scope ∈ {current-pr, follow-up} AND measured ∈ {true, 未判定} | Must fix in this PR |
| **Needs fix** | severity ∈ {MEDIUM, LOW-MEDIUM, LOW} AND scope ∈ {current-pr, follow-up} AND measured ∈ {true, 未判定} | Must fix in this PR (action required) |
| **nit (認知のみ)** | scope == "nit-noted" | Reply-only via ステップ 2.4 `nit-noted-reply`; NOT a fix target |
| **non-blocking (実測なし)** | scope ∈ {current-pr, follow-up} AND measured == false (`measured_map` に明示的に `false` で登録されたもののみ — 経路別判定は下記 measured lookup 参照) | 表示のみ; NOT a fix target (実測必須ゲート — 記録は `/rite:pr-review` ステップ 5.4 の「実測なし指摘」section が担う) |
| **External review** | severity_map に登録されていない未対応コメント (人間レビュアーの指摘等)、**および step 4 の出自確認で rite finding 由来と確認できなかった thread** (severity_map 登録済みでも本分類へ振り替える)。実測必須ゲートの**対象外** — `Verification:` アンカーを構造的に持てないため measured 未判定でも non-blocking に落とさない | Action required |
| **Resolved** | Resolved threads | - |

**Classification logic:**

1. Thread is resolved (`isResolved: true`) -> Resolved (processing complete)
2. Contains only `LGTM`, `+1`, `👍`, etc. -> Informational (no action needed)
3. Check if the finding's file:line exists in `severity_map`
4. If it exists, look up the corresponding entry in `scope_map`:
   - **`scope == "nit-noted"`** -> **nit (認知のみ)**; route directly to ステップ 2.4 `nit-noted-reply` (skip ステップ 2.1 selection、fix commit 対象外)
   - **measured lookup (実測必須ゲート)**: 判定は **`measured_map[file:line]` の参照に統一**する (母集団は severity_map と同一 — **scope による登録除外なし**。nit-noted は本分岐に到達する前に上の nit 分岐 (正規化後 `scope_map` 参照) が先取するため lookup 対象にならない。key 正規化・tie-break・3 値保持を含む構築共通規則はステップ 1.2.1 step 6 が単一定義。**3 値**: `false` = non-blocking / `true` = blocking / **未登録** = 未判定 (実測の有無を判定する構造が無い) → blocking)。`measured_map` の構築は経路別:
     - **JSON 経路 (Priority 0/2/3 Raw JSON)**: finding が `verification` を object として持ち、かつ `verification.measured` が boolean のときに限り `measured_map[file:line] = .verification.measured` を登録する。**`verification` 欠落 / `verification.measured` 欠落の finding は登録しない (= 未判定 → blocking)**。`(.verification.measured // false)` で畳んではならない — `//` は欠落と `false` を同一視するため、write 側が `verification` を出力しない世代の JSON (旧形式、および本ゲート配線前に生成されたもの) を読むと**全 finding が non-blocking になり fix が 0 件で完了し、レビューループが指摘を 1 件も解消しないまま `safety.max_review_cycles` まで空転する**。**欠落は現行世代の JSON でも発生する** — `scripts/review-measured-gate.sh` は形式崩れアンカー (アンカー文字列と `=>` はあるが検出 regex に match しない) の finding に対し、`measured=false` と確定させずに `verification` を設定しないことで「未判定」を表現するため。したがって本経路の「欠落 = 未判定 → blocking」は後方互換のためだけの規定ではなく、**現行フローの主経路の 1 つ**である。`review-result-schema.md` §verification の default mapping (「欠落時は `measured=false` 扱い」) は `measured` が判定に使われない記録専用フィールドだった時点の規定であり、本ゲートで判定入力になった以降は同節の「3 値モデル」注記が優先する
     - **会話コンテキスト経路 (Priority 1)**: integrated report の `### 全指摘事項` の行を `true`、`### 実測なし指摘 (non-blocking)` section の行を `false` として登録する。**Markdown 経路と同様に、`### 実測なし指摘` の行も `severity_map` / `scope_map` へ投入する** (ステップ 1.2.1 step 6 と同一規則。投入しないと `total_count` の母集団 = severity_map から非実測指摘が抜け、ステップ 4.6 の `全指摘 == 対応指摘` が成立せず reply-only cycle で不要な re-review が 1 サイクル余分に走る)
     - **Markdown パース経路 (Target Comment Fast Path の rite レビュー結果 / Priority 3 legacy Markdown fallthrough)**: ステップ 1.2.1 step 6 の構築規則に従う — `### 全指摘事項` の行は `true` (5.3.0.M 通過済み blocking 集合。5.3.0.M 導入前の旧コメントも全件 blocking 前提で描画されているため true が後方互換上も正しい)、`### 実測なし指摘 (non-blocking)` section の行は `false`
     - **外部ツール / best-effort parse 経路 (手動コメント / verified-review 等)**: `Verification:` アンカーを構造的に持てないため `measured_map` に**登録しない** (= 未判定)。実測必須ゲートの対象外 — 未判定を non-blocking と解釈せず、従来どおり External review (Action required = blocking) として扱う

     判定の結果 **`measured_map[file:line] == false`** -> **non-blocking (実測なし)**; skip ステップ 2.1 selection、fix commit 対象外 (記録は `/rite:pr-review` の 4 経路 — 永続 JSON の `non_blocking_findings[]` / ステップ 6.1.d の PR 記録コメント / ステップ 5.4 の「実測なし指摘」section / E2E output line — が担う)

     > **人間 thread の巻き添え防止 (MUST)**: `measured_map` は file:line を key にするため、非実測 finding と**同一 file:line にある人間レビュアーの未解決 thread** が本分岐に巻き込まれ、fix も reply もされないまま `non_blocking_count` に「対応済み」として計上されうる。これを防ぐため、本分岐に落とす前に **thread の出自を確認する**: thread 本文が当該 rite finding の description と対応しない (= rite review 由来と確認できない) 場合は non-blocking に落とさず、**step 5 の External review (Action required = blocking)** として扱う。出自が判定できない場合も External review 側 (安全側) に倒す。rite finding 由来と確認できた thread のみが non-blocking になる。
     >
     > **振り替え時の marker (MUST)**: 本例外で External review へ振り替えた key が 1 件以上あれば、以下を bash で実行して痕跡を残す (`MEASURED_DEMOTED_ON_ANCHOR` と同じ observability marker。reason 表への登録は不要)。分類を変える唯一の例外分岐であり、かつ後述の `non_blocking_count` 減算を伴うため、無痕跡だと減算漏れによる finalize 等式の永久不成立 (`max_review_cycles` まで空転) の原因が追えない:
     >
     > ```bash
     > echo "[CONTEXT] MEASURED_RECLASSIFIED_TO_EXTERNAL=1; count={n}; cause=provenance_unconfirmed" >&2
     > ```
   - `scope ∈ {current-pr, follow-up}` AND measured ∈ {true, 未判定} AND severity ∈ {CRITICAL, HIGH} -> Required fix
   - `scope ∈ {current-pr, follow-up}` AND measured ∈ {true, 未判定} AND severity ∈ {MEDIUM, LOW-MEDIUM, LOW} -> Needs fix

   **step 4 は severity_map 登録済み finding の終端 (1 例外あり)**: 本 step で分類が確定した finding を step 5 (External review) へ落としてはならない。外部ツール / best-effort parse 由来で severity_map に**登録済み**の finding (Confidence override 取込分を含む) は `measured_map` 未登録 = 未判定として上記 2 分岐に入り Required fix / Needs fix になる (blocking という結論は External review と同じで、二重計上のみを避ける)。**唯一の例外は measured lookup の出自確認**で、`measured_map[key] == false` かつ thread が rite finding 由来と確認できない場合のみ step 5 へ振り替える (下記 MUST 参照)。step 5 の対象は severity_map に**登録されていない**未対応コメント、および本例外で振り替えられた thread。
5. Unresolved comments not in `severity_map`、**または step 4 の出自確認で振り替えられた thread** -> External review (Action required = blocking)


**Mapping method with `severity_map`:**

Map GitHub review comments (REST API) with rite review results (Markdown table) using:

| Mapping Condition | Determination Method |
|-------------------|---------------------|
| **Exact match of file path and line number** | GitHub review comment's `path:line` matches the `severity_map` key |
| **Approximate line number match (+-3 lines)** | If no exact match, attempt approximate match within +-3 lines |

**Fallback (when `severity_map` is empty):**

When rite review results were not found, use conventional GitHub state-based classification:

| Classification | Criteria |
|---------------|----------|
| **Unaddressed (needs fix)** | `CHANGES_REQUESTED` in review or unresolved threads |
| **Unaddressed (suggestion)** | Improvement suggestions or questions without replies |
| **Resolved** | Resolved threads or replied |
| **Informational** | FYI, supplementary explanations, no action needed |

### 1.4 Display Comment List

**Behavior branching based on caller:**

| Caller | Option Selection | Target |
|--------|-----------------|--------|
| Within `/rite:iterate` review-fix loop | **Skip** (auto-select) | All findings + external reviews |
| Manual `/rite:fix` | Display | User-selected |


---

```
PR #{number} のレビューコメント

## 未対応の指摘 ({count}件)

### 必須修正（CRITICAL/HIGH）({count}件)
| # | 重要度 | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|-----|----------|------------|
| 1 | {severity} | {path} | {line} | {body_preview} | @{user} |

### 要修正（MEDIUM/LOW-MEDIUM/LOW）({count}件)
| # | 重要度 | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|-----|----------|------------|
| 1 | {severity} | {path} | {line} | {body_preview} | @{user} |

### nit (認知のみ) ({nit_noted_count}件)
<!-- scope == "nit-noted" の finding はサマリ表示のみ。
     ステップ 2.1 auto-select 対象から除外され、ステップ 2.4 nit-noted-reply で「nit、認知済」reply を投稿する。
     fix commit 対象からも完全除外、ステップ 4.6 サマリで acknowledged_nit_count として独立カウント。 -->
| # | 重要度 | スコープ | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|----------|-----|----------|------------|
| 1 | {severity} | nit-noted | {path} | {line} | {body_preview} | @{user} |

### non-blocking (実測なし) ({non_blocking_count}件)
<!-- measured_map に明示的に false で登録された finding はサマリ表示のみ (0 件なら本セクション省略)。
     {non_blocking_count} の導出: **measured_map の false のうち scope_map[key] != "nit-noted" の件数** (単一定義。nit-noted は
     ステップ 1.2.1 step 6 共通規則 (a) の参照時除外 (正規化後 scope_map) で本カウントに含まれず、acknowledged_nit_count と二重計上しない。
     JSON 経路は pr-review ステップ 6.1.a の除外契約により非実測 finding を受け取らないため常に 0、
     Markdown / 会話経路は ステップ 1.2.1 step 6 のセクション別登録から N 件を数える (経路間で値は一致しない — step 6 共通規則の注記参照)。
     ステップ 1.3 の non-blocking 分類条件 (scope ∈ {current-pr, follow-up}) と同一フィルタ。step 4 の出自確認で External review へ振り替えた key は減算する。
     外部ツール / best-effort parse 経路、および verification を持たない JSON の finding は measured_map 未登録 = 未判定のため
     本カウント対象外 = blocking のまま)。
     ステップ 4.6 completion report の同名 placeholder と同一値で、「対応した指摘」計算式にも算入される。
     実測必須ゲート (severity-levels.md §実測必須ゲート) により fix 対象外 — ステップ 2.1 auto-select 対象から除外、
     fix commit 対象からも完全除外、reply も投稿しない (記録は /rite:pr-review ステップ 5.4 の「実測なし指摘」section が担う)。 -->
| # | 重要度 | スコープ | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|----------|-----|----------|------------|
| 1 | {severity} | {scope} | {path} | {line} | {body_preview} | @{user} |


### 外部レビュー({count}件)
| # | ファイル | 行 | 内容 | レビュアー |
|---|----------|-----|------|------------|
| 1 | {path} | {line} | {body_preview} | @{user} |

## 対応済み ({count}件)
{resolved_count} 件の指摘が解決済みです

---

対応を開始しますか？

オプション:
- すべての指摘に対応（推奨）
- CRITICAL/HIGH のみ対応
- 特定の指摘を選択
- キャンセル
```

**Option descriptions:**

| Option | Target | Use Case |
|--------|--------|----------|
| **すべての指摘に対応（推奨）** | All severities + external reviews | When full resolution is needed. Within `/rite:iterate` loop, all findings are auto-selected |
| **CRITICAL/HIGH のみ対応** | CRITICAL + HIGH only | When addressing only urgent issues and deferring MEDIUM/LOW-MEDIUM/LOW |
| **特定の指摘を選択** | Individual selection | When addressing only specific findings |
| **キャンセル** | - | Abort the process (Fast Path 経由の場合はハンドオフファイルを削除してから exit) |

**「キャンセル」選択時の Behavior** (silent orphan ファイル防止):

`/rite:fix` 実行時に Fast Path (ステップ 1.2 Target Comment Fast Path) を経由して Fast Path 一時ファイル (ハンドオフ 3 + raw_json + intermediate 3、合計 7 本) を作成した状態で「キャンセル」が選択された場合、ステップ 1.5 cleanup を経由しないため、**ステップ 1.4 末尾でも明示的に Fast Path の全一時ファイル + confidence_override (合計 8 本) を削除する**。これは ステップ 1.2 best-effort parse の「Cancel/Re-run 経路でのハンドオフ cleanup 義務」段落と同じ defense-in-depth 原則に従う。

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

**FINALIZE handoff の設定 (E2E flow 時のみ)**: `[fix:cancelled-by-user]` は終了 sentinel のため、`/rite:iterate` ステップ5 中断通知を構造的に強制する FINALIZE handoff をセットする。`[fix:cancelled-by-user]` は本ステップ (ステップ 1.4 cancel) の早期 exit で emit され Step 5.1 を経由しないため、handoff は**ここで**セットする。**E2E flow の場合のみ** (ステップ 5 Flow detection 表と同一判定: `rite:fix` が Skill 経由で invoke された / work memory に `コマンド: /rite:open`) 下記 bash を `[fix:cancelled-by-user]` 出力の直前に実行する。standalone 実行 (ユーザーが `/rite:fix` を直接入力) では実行しない (`--if-exists` も二次的に gate するが、prose 判定が primary = AC-4)。

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

```
PR #{number} にはレビューコメントがありません

考えられる状況:
- まだレビューが実施されていない
- すべての指摘が解決済み

次のステップ:
- `/rite:pr-review` でセルフレビューを実行
- `/rite:ready` でレビュー待ちに変更
```

Terminate processing.

### 1.5 Fast Path Handoff File Cleanup (ステップ 1 終端)

**Execution condition**: Fast Path 経由で一時ファイル (`${TMPDIR:-/tmp}/rite-fix-target-body-{pr_number}-{target_comment_id}.txt` 等) を作成し、かつ ステップ 1.4 を「キャンセル以外」(= 「すべての指摘に対応」「CRITICAL/HIGH のみ対応」「特定の指摘を選択」のいずれか) で完走した場合のみ実行する。Broad Comment Retrieval 経路 (Fast Path 未経由) や ステップ 1.4 「キャンセル」経路ではこれらのファイルは存在しないか別経路 (ステップ 1.4 「キャンセル」Behavior block) で削除済みのため、`rm -f` は silent no-op となる。

**Purpose**: ステップ 1.2 Fast Path で作成した一時ファイル (ハンドオフ 3 + raw_json + intermediate 3、合計 7 本) を明示的に削除する。**ステップ 1.5 として独立に実行する** (ステップ 1 の最終サブフェーズ、ステップ 2 遷移直前のタイミング)。これにより `/tmp` 累積汚染と再実行時の stale data 参照を防ぐ。

**Important — specific path 必須** (並列 fix 実行の他セッション破壊防止):
- wildcard glob (`${TMPDIR:-/tmp}/rite-fix-target-body-*.txt` 等) は**絶対に使わない**。並行 terminal / 手動複数セッションで他セッションの一時ファイルも silent に消す事故になる
- 必ず `{pr_number}-{target_comment_id}` suffix を含む specific path で削除する

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

**Idempotency**: `rm -f` は対象ファイルが存在しない場合でも exit 0 で成功するため、Broad Retrieval 経路でも安全に実行できる。また再実行時 (同一 pr_number + target_comment_id で再度 /rite:fix を実行) でも古いファイルが確実に削除される。

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

これらに該当しない修正を採用する場合、Wiki (`/rite:wiki-query`) で project-specific な許容パターンを事前確認すること。本原則は fix.md の手順として常時適用される（config での opt-out は不可）。

### Simplification-First Response Principle（追加より削除を先に検討）

指摘に対する修正方針を決定する前に、以下のチェックリストを必ず通過させること（Fail-Fast Response Principle と同様、config での opt-out は不可）:

- [ ] 機構の**追加**（新しい分岐・ガード・規約・注記・例外条項）ではなく、既存機構の**削除・単純化**（分岐の統合、規則の一般化、複製の一本化）で指摘を解消できないか検討したか
- [ ] 追加しようとしている分岐 / ガード / 規約は、指摘された 1 ケース専用になっていないか（1 ケース対応の追加は、次 cycle でその追加自体が新たなレビュー対象面となり指摘を再生産する）
- [ ] 修正 diff は指摘の解消に必要な最小か。指摘されていない「ついで」の防御・柔軟性・将来対応を含んでいないか

本原則の対象は**機構の追加**（分岐・ガード・規約・注記・例外条項）である。テストケースの追加や既存複製の同期更新は対象外（それらは通常それ自体が正しい修正であり、削除で代替しない）。

本原則は生成側の `no_speculative_structure`（[coding-principles.md](../../skills/rite-workflow/references/coding-principles.md)）と対をなす。

**Escalation trigger（パッチの重ね掛け停止）**: 対応中の finding が**同一 PR の前 cycle の fix が導入・変更した箇所**への指摘である場合（description が「cycle N で導入した」「前 cycle で追加した」等で当該 fix を名指しする場合を含む）、同じ機構への追加パッチを既定選択にしないこと。まず「当該機構ごと削除・単純化して指摘群を根から消せないか」を検討し、修正案の提示（ステップ 2.3）の前にその判断を chat へ 1 行明示する（例: `simplification-first: 分岐機構を削除し行全体再生成へ単純化` / `simplification-first: 追加パッチを選択 — 理由: {reason}`）。

**追加で修正する場合**、commit message に「なぜ削除・単純化ではなく追加を選んだか」を明示すること（Fail-Fast の fallback 明示義務と同型）。

rationale: references/design-rationale.md#simplification-first-rationale

### 2.1 Confirm Fix Approach

**Entry routing — scope=nit-noted skip**:

各 finding を ステップ 2.1 で処理する前に `scope_map` を look up し、**`scope == "nit-noted"` の finding は ステップ 2.1 を完全に skip して ステップ 2.4 `nit-noted-reply` サブステップに直行する**。これは nit-noted 受け流し経路の核となる routing 分岐:

1. scope_map[file:line] を look up
2. `scope == "nit-noted"` → ステップ 2.1 (本セクション) を skip、ステップ 2.4 `nit-noted-reply` サブステップで「nit、認知済」reply を 1 件投稿
3. **measured lookup (実測必須ゲート)**: ステップ 1.3 で **non-blocking (実測なし)** に分類された finding (`measured_map[file:line] == false`) → ステップ 2.1 (本セクション) を **skip** し、ステップ 2.4 の reply も投稿しない (fix commit 対象外。記録は `/rite:pr-review` ステップ 5.4 の「実測なし指摘」section が担う)
4. `scope ∈ {current-pr, follow-up}` かつ **measured != false** (= `measured_map` で `true`、または未登録 = **未判定** — ステップ 1.3 step 4 の measured lookup 参照)、または scope 未登録 (legacy / fallback) → 本セクション以降を通常通り実行 (Confidence override で取り込んだ外部ツール finding は severity_map 登録済みのため ステップ 1.3 step 4 でここに合流し、silent skip されない)
5. nit-noted / non-blocking skip 経路では「コードを修正する / accept (認知のみ) / 説明・返信のみ」の選択 UI は **表示しない** (ユーザー判断不要)。nit-noted reply の冪等性は ステップ 2.4 サブステップ内で comment ID 単位で管理される


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
| コードを修正する | status: `fixed` | 修正報告 (ステップ 2.4) | （該当なし） | 該当なし (修正済) |
| accept (認知のみ) | status: **`acknowledged`** (scope を `nit-noted` に override) | "accepted, will not be fixed in this PR." | `Acknowledged-finding: F-NN (file:line) — reason` (ステップ 3.2) | **あり** (fingerprint 永続化) |
| 説明・返信のみ | status: `replied` | 説明 (修正不要の根拠) | （該当なし） | なし (次 cycle で再出現可) |


**`{reviewer_display}` の展開ルール** (Fast Path 経由で `target_author_mention_skip == "true"` の場合の silent `@unknown` 誤記録防止):

| 条件 | 展開結果 (日本語) | 展開結果 (英語) |
|------|-----------------|----------------|
| Broad Comment Retrieval 経由 (通常の `{user}`) | `@{user}` | `@{user}` |
| Fast Path 経由 かつ `target_author_mention_skip == "false"` | `@{target_author}` | `@{target_author}` |
| Fast Path 経由 かつ `target_author_mention_skip == "true"` | `(不明なレビュアー)` | `(unknown reviewer)` |

Claude は ステップ 1 末尾で skip_file を、`{target_author}` が必要な箇所では author_file を、それぞれ Read tool で読む (パスは Block C の `[CONTEXT] BLOCK_C_COMPLETE` marker の `skip_file=` / `author_file=` / `body_file=` 値をリテラル使用する — Read tool は `${TMPDIR:-/tmp}` を展開できないため、handoff 3 本すべて marker 値経由で読む。specific path 必須、wildcard glob は並列セッション破壊のため絶対禁止)。skip_file が `"true"` の場合は本 phase 以降のすべての mention 生成箇所で `@` prefix を生成しない。

**複数 reviewer 時の `{reviewer_display_N}` 展開ルール** (ステップ 3.2 trailer / ステップ 4.2 PR comment 報告で使用):

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

**Owner**: ステップ 2.1 内の `accept (認知のみ)` 選択時 sub-flow。**Trigger**: ユーザーが ステップ 2.1 で「accept (認知のみ)」を選択した finding。**Purpose**: 「reviewer の指摘は理解したが本 PR では修正しない」決着を `acknowledged` 状態として記録し、次 cycle で同一 finding が再出現しても fingerprint で自動 suppression する受け流し経路の核。本 PR 外への先延ばし手段は提供しない (別 Issue 化禁止ポリシー)。

**accept 選択時の処理 (4 つを同期実行)**:

1. **accept reason 入力 (任意、AskUserQuestion)**: Other 経由で自由記入を許容する option-based 構造で以下 2 択を提示する:
   - **「理由を入力 (Other で自由記入)」**: ユーザーが Other 選択時に free-text を入力 → `accept_reason` として retain
   - **「reason なしで accept」**: `accept_reason = ""` (空文字列、デフォルト)
   入力値は ステップ 3.2 commit trailer の `reason` 欄に展開される (`accept_reason` が空なら `user decision: accept (no reason given)`、非空なら `{accept_reason}; user decision: accept`)
2. **finding state の override**:
   - `status = "acknowledged"` を設定
   - `scope` を `nit-noted` に override (元 scope は `original_scope` として retain — reply 文言で参照)
3. **reply 投稿**: ステップ 2.4 既存 reply 機構を再利用し、固定文言で投稿:
   ```
   accepted, will not be fixed in this PR. (reviewer scope: {original_scope}; user decision: accept{reason_suffix})
   ```
   `{reason_suffix}` は `accept_reason` が非空なら `; reason: {accept_reason}`、空なら空文字列
4. **accept fingerprint 永続化**: `.rite/state/accepted-fingerprints-{pr_number}.txt` に当該 finding の fingerprint を append (詳細は下記 bash block)

**fingerprint 計算式 (ステップ 2.1.A 独自仕様 — accept 抑止専用。cycle 間比較は `pr-review/references/finding-cycling.md` の semantic 判断であり、本 hash はそれとは独立の機械契約)**:

```
fingerprint = sha1(normalize(file_path) + ":" + category + ":" + normalize(message))
```

- `normalize(file_path)`: `./` prefix のみ collapse (case-sensitive filesystem 保護のため lowercase 化・空白除去はしない)
- `category`: review-result-schema.md の `findings[].category` フィールド値 (例: `code_quality`)
- `normalize(message)`: trim + whitespace collapse (lowercase + 行番号除去等は行わない)


**Placeholder data flow** (`{file}` / `{line}` / `{category}` / `{description}` の取得元):

| Placeholder | 取得元 | ステップ 1.2.0 構築有無 |
|-------------|--------|---------------------|
| `{file}` | `findings[].file` (schema 1.1.0) | ステップ 1.2.0 で `severity_map` key (`file:line`) 経由でアクセス可能。Claude は finding context から直接置換 |
| `{line}` | `findings[].line` (`integer \| null`、null は anchor sentinel) | 同上 |
| `{category}` | `findings[].category` (schema 1.1.0、例: `code_quality`) | ステップ 1.2.0 では `category_map` 未構築 — Claude は会話コンテキストの finding object から直接置換する責務を持つ |
| `{description}` | `findings[].description` | 同上 |
| `{pr_number}` | ステップ 1.0 正規化値 | bash block 冒頭で literal substitute |

**`{line}` が null の場合**: `Acknowledged-finding:` commit trailer / `[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED` retained flag emit / fingerprint normalize すべてで `null` literal を避け、`anchor` sentinel (ステップ 1.2.0 severity_map key 規約と統一) に正規化する。

**accept 永続化 bash block** (per accepted finding、単一 Bash tool invocation 内で実行 — `{file}` / `{line}` / `{category}` / `{description}` / `{pr_number}` は Claude が事前 substitute):

```bash
# ステップ 2.1.A accept fingerprint 永続化
# canonical trap pattern は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: パス先行宣言 → trap 先行設定 → mktemp の順序、signal 別 exit code、関数契約)

# Step 1: placeholder の literal substitution + numeric/empty gate
pr_number="{pr_number}"
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: ステップ 2.1.A の pr_number が literal substitute されていません (値: '$pr_number')" >&2
    echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 1  # fix.md 内 8 site の placeholder gate と対称化 (ステップ 2.4.N 等と blocking 統一)
    ;;
esac
file_path="{file}"
line_no="{line}"
category="{category}"
description="{description}"
# line=null → anchor sentinel に正規化 (ステップ 1.2.0 severity_map key 規約と統一)
case "$line_no" in
  ''|null|0) line_no="anchor" ;;
esac

# Step 2: パス先行宣言 → cleanup 関数定義 → 4 行 trap 設置 → mktemp の順 (canonical pattern)
tmpfile=""
# state ファイルはリポジトリ共通の state ルート基準 (state-path-resolve.sh)。セッション worktree /
# main checkout のどちらから実行しても同一パスに解決される (pr-review.md ステップ 5.1.2.A の
# 読取側と同一解決。解決失敗時は cwd fallback)
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
state_dir="$_state_root/.rite/state"
state_file="${state_dir}/accepted-fingerprints-${pr_number}.txt"
_rite_fix_phase21A_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_fix_phase21A_cleanup; exit $rc' EXIT
trap '_rite_fix_phase21A_cleanup; exit 130' INT
trap '_rite_fix_phase21A_cleanup; exit 143' TERM
trap '_rite_fix_phase21A_cleanup; exit 129' HUP

# Step 3: fingerprint 計算 (ステップ 2.1.A 独自 simplified normalize — accept 抑止専用)
# normalize(file_path): `./` prefix のみ collapse、case-sensitive path 保護のため lowercase 化しない
# normalize(message): trim + whitespace collapse、identifier mask しない (audit log の human readability 重視)
norm_file=$(printf '%s' "$file_path" | sed 's@^\./@@')
norm_cat="$category"
norm_msg=$(printf '%s' "$description" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')

# portable SHA-1 helper (BSD shasum / GNU sha1sum 両対応)
if command -v sha1sum >/dev/null 2>&1; then
  fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | sha1sum | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | shasum -a 1 | awk '{print $1}')
else
  echo "WARNING: sha1sum / shasum が見つかりません — fingerprint 永続化を skip します" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=sha1_helper_missing" >&2
  exit 0  # non-blocking: accept reply 投稿は完了済、suppression は諦めるだけ
fi

# Step 4: state directory + tempfile
if ! mkdir -p "$state_dir" 2>/dev/null; then
  echo "WARNING: .rite/state/ ディレクトリ作成に失敗しました — fingerprint 永続化を skip します" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mkdir_failed" >&2
  exit 0
fi

if ! tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-fix-accept-fp-${pr_number}-XXXXXX" 2>/dev/null); then
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mktemp_failed" >&2
  exit 0
fi

# Step 5: idempotent append (sort -u で重複排除) + atomic mv
{ [ -f "$state_file" ] && cat "$state_file"; printf '%s\n' "$fingerprint"; } | sort -u > "$tmpfile"
if ! mv "$tmpfile" "$state_file" 2>/dev/null; then
  echo "WARNING: accepted-fingerprints state file の atomic mv に失敗しました ($state_file)" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mv_failed" >&2
  exit 0
fi
tmpfile=""  # mv 成功後は trap cleanup 対象から外す (二重 rm 回避)

# Step 6: 成功時 retained flag (bash 変数経由で placeholder 残留を防ぐ)
echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED=1; fingerprint=$fingerprint; pr=$pr_number; file=$file_path; line=$line_no" >&2

# Step 7: accept ≥5 件警告 (AC-4)
# wc -l 出力に platform 依存の空白が含まれるため tr -d で剥がす (BSD wc は 先頭に空白を付ける)
accept_count=$(wc -l < "$state_file" 2>/dev/null | tr -d '[:space:]')
case "$accept_count" in ''|*[!0-9]*) accept_count=0 ;; esac
if [ "$accept_count" -ge 5 ]; then
  echo "⚠️ WARNING: 本 PR で accept (認知のみ) 累計件数が 5 件以上 (${accept_count} 件) に達しました。reviewer の精度を疑うべき水準です。" >&2
  echo "  対処: reviewer agent の prompt / scope assignment / pattern check ロジックを見直すか、本 PR を別 Issue に分割することを検討してください。" >&2
  echo "[CONTEXT] ACCEPT_LIMIT_EXCEEDED=1; pr=$pr_number; accept_count=$accept_count" >&2
fi
```

**Revocability (AC-5)**: accept は **revocable**。state file (`.rite/state/accepted-fingerprints-{pr_number}.txt`) を手動削除すれば、次 review cycle で当該 finding が再出現した際に suppression が解除され、通常の ステップ 2.1 選択 UI に戻る。手動編集で特定行 (fingerprint) のみ削除しても部分的に revoke 可能。

**fix 対象除外との関係**: accept で `status == "acknowledged"` となった finding は **ステップ 3 (commit) の対象から完全除外** される。これにより accept された finding は fix commit 対象にならない (本 PR で先延ばしの記録だけが残る)。

**Rejection Evidence Gate**: accept 理由が `scope-creep` / `out-of-scope` / `minor` のいずれかなら、fingerprint 永続化より前に [promotion-audit-2091.md](../pr-review/references/promotion-audit-2091.md#rejection-evidence-gate) を適用する。別 reviewer の cross-validation と、reject 対象 scenario の empirical counterfactual/revert test の両方を Decision Log に記録できない限り `acknowledged` へ遷移してはならず、`ACCEPT_FINGERPRINT_PERSISTED` も commit trailer も生成しない。不足時は finding を修正対象へ戻すか AskUserQuestion でユーザー判断へ上げる。

**ステップ 3.2 commit trailer**: 1 commit に複数の accept finding が含まれる場合、commit trailer に `Acknowledged-finding: F-NN (file:line) — reason` 行を **反復生成** する (詳細は ステップ 3.2 セクション参照)。

**`acknowledged` retained flag namespace** (ステップ 2.1.A 独立、ステップ 1.2.0 reason 表とは別 namespace):

| Flag | reason | Description |
|------|--------|-------------|
| `ACCEPT_FINGERPRINT_PERSISTED` | (success marker) | fingerprint state file への append が成功。`fingerprint=<sha1>; pr=<num>; file=<path>; line=<num\|anchor>` を含む (`line` は null/0/空のとき `anchor` sentinel に正規化される。ステップ 2.1.A bash block の line_no 正規化と統一) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `pr_number_placeholder_residue` | `pr_number` placeholder が literal substitute されていない (空文字 / placeholder 残留 / 非数値) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `sha1_helper_missing` | sha1sum / shasum のいずれも環境に存在しない (極稀、CI 環境異常) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mkdir_failed` | `.rite/state/` directory 作成失敗 (permission denied / read-only filesystem) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mktemp_failed` | tmpfile 作成失敗 (disk full / inode 枯渇) |
| `ACCEPT_FINGERPRINT_PERSIST_FAILED` | `mv_failed` | tmpfile から state file への atomic mv 失敗 |
| `ACCEPT_LIMIT_EXCEEDED` | (warning marker) | 同一 PR 内 accept 件数が 5 件以上に達した警告 (AC-4) |

**Non-blocking contract**: 上記 `ACCEPT_FINGERPRINT_PERSIST_FAILED` reason はすべて WARNING + retained flag emit で続行する。accept 自体は ステップ 2.4 reply 投稿で完了しており、永続化失敗は次 cycle での auto-suppression を諦めるだけで fix loop 自体は止めない。

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
         echo "  Claude は thought-process verbalize 義務を継続し、grep 不可の影響範囲を手動推定すること" >&2
         ;;
     esac
   fi
   rm -f "${TMPDIR:-/tmp}/rite-fix-impact-scan-$$.txt" "${TMPDIR:-/tmp}/rite-fix-impact-scan-err-$$.txt"
   ```

   **symbol 不在ケースの fallback** (finding が file:line のみで symbol を含まない場合):
   - (a) 同ファイル内の関連シンボル列挙 → caller 探索を反復
   - (b) 複数 symbol を含む大規模 fix → 各 symbol について Step 1 を反復
   - (c) Markdown / config rewording → 該当 file 名で grep + CHANGELOG / docs 内の参照を確認

2. **影響範囲の thought process 出力**: 修正案の前に必ず以下を Claude 側で
   verbalize する (chat への明示出力 - ユーザーが追跡できる形で):

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
   chat に明示出力する。判断根拠の verbalize は省略不可。

   省略しなかった場合 (= step 1-3 を実行する場合) も、「同一ファイル内のみで影響なし」
   と早期確定するのは禁止。step 1 の grep 結果と step 2 の影響範囲 verbalize は
   **同一ファイル内変更であっても必須**。これは scope_discipline と
   no_journal_comment の前提条件 (修正の影響を caller / test / sibling まで追える
   状態にしてから Apply する) を満たすために必要。

### 2.3 Apply the Fix


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

**Implementation note for Claude**: When Claude generates commands, write the reply content to a temporary file via `mktemp` + HEREDOC, then use `jq -n --rawfile body "$tmpfile"` to safely construct the JSON payload. Use the REST API numeric ID directly for `$comment_id` via `--argjson`. `jq --rawfile` reads the file as a raw string and handles all JSON escaping automatically.

### 2.4.N nit-noted-reply

**Owner**: `/rite:fix` ステップ 2.4 内サブステップ。**Trigger**: ステップ 2.1 entry routing で `scope == "nit-noted"` と判定された finding 群すべてに対し、本サブステップで「nit、認知済」reply を per-finding で投稿する。**Purpose**: scope=nit-noted finding を「PR コメント返信のみで決着、Issue 化しない」受け流し経路として `acknowledged` 状態化する。

**Pre-condition**:
- ステップ 1.2.0 で `scope_map_json` が構築済 (空 `{}` も含む)
- ステップ 1.3 Classification で `nit (認知のみ)` セクションに分類された finding 群が `nit_noted_findings` として retain されている
- ステップ 1.4 Display で `{nit_noted_count}` が決定済

**Loop body** (per nit-noted finding):

各 finding について ステップ 2.4 既存の reply 機構 (上記 bash block) を **再利用** し、`{reply_body}` を以下の固定文言で置き換えて投稿する:

```
nit、認知済 (scope=nit-noted, 受け流し経路)


このご指摘は scope=nit-noted の informational 指摘として認識しました。本 PR での修正は行いません (受け流し経路)。
```

**冪等性 (Replied-only respect)**:

- 同一 `comment_id` に対する同一 cycle 内での重複 reply は禁止 (Wiki 経験則「Replied-only respect」)
- 既に「nit、認知済」reply が投稿済みのコメント (本 PR の `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments` レスポンスで `body` に literal `nit、認知済 (scope=nit-noted` を含むものが検出された場合) は **skip**
- 並列 cycle (review-fix loop の N 回目で同一 nit が再指摘された場合) も同様に skip し、`[CONTEXT] NIT_NOTED_REPLY_SKIPPED=1; reason=already_replied; comment_id=$comment_id` を emit

**Counter accumulation**:

各成功投稿で `acknowledged_nit_count` counter を +1 する (ステップ 4.6 サマリで使用)。本サブステップは **単一 Bash tool invocation** で実行され、`pr_number` placeholder の literal substitution、defense-in-depth truncate、既投稿 ID set 生成、per-finding loop、append までを 1 block に集約する:

```bash
# ステップ 2.4.N nit-noted-reply 全体
# 単一 Bash tool invocation で完結させる (shell state は invocation 間で継承されないため)

# Step 1: pr_number placeholder の literal substitution + numeric gate (ステップ 6.1.a 等と対称)
pr_number="{pr_number}"
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: ステップ 2.4.N の pr_number が literal substitute されていません (値: '$pr_number')" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 1
    ;;
esac

# Step 2: acknowledged_nit_count tempfile の defense-in-depth truncate (confidence-override tempfile と同型)
nit_count_file="${TMPDIR:-/tmp}/rite-fix-acknowledged-nit-${pr_number}.txt"
: > "$nit_count_file" 2>/dev/null || echo "WARNING: nit_count_file の truncate に失敗しました ($nit_count_file)" >&2

# Step 3: 既投稿 reply の comment_id set を生成 (冪等性 — Replied-only respect)
# 本 PR の既存 review comment から body に literal "nit、認知済 (scope=nit-noted" を含むものを抽出
# in_reply_to を取って既存 reply 対象の元 comment_id set を作る (gh api PR review comments)
already_replied_ids=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" \
  --jq '[.[] | select(.body | contains("nit、認知済 (scope=nit-noted")) | .in_reply_to_id] | unique | .[]' \
  2>/dev/null || echo "")

# Step 4: scope_map_json から scope=="nit-noted" の finding を per-finding loop で処理
# nit_noted_findings は ステップ 1.3 で classified された finding 一覧で、各要素は {comment_id, file, line, body} を持つ
# Claude が会話コンテキストから iteration する (bash 配列として渡せないため LLM responsibility)
# 以下は per-finding template (Claude は finding ごとに本 bash block を生成・実行する):

for_each_nit_noted_finding() {
  local comment_id="$1"
  local original_body_preview="$2"

  # 既投稿 skip check (Replied-only respect doctrine)
  if printf '%s\n' "$already_replied_ids" | grep -qx "$comment_id"; then
    echo "[CONTEXT] NIT_NOTED_REPLY_SKIPPED=1; reason=already_replied; comment_id=$comment_id" >&2
    return 0
  fi

  # Step 4a: reply body 構築 (固定文言 + 元コメント preview)
  local reply_tmpfile
  reply_tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nit-reply-${pr_number}-${comment_id}-XXXXXX.md") || {
    echo "[CONTEXT] NIT_NOTED_REPLY_FAILED=1; comment_id=$comment_id; reason=mktemp_failed" >&2
    return 1
  }
  cat > "$reply_tmpfile" <<EOF
nit、認知済 (scope=nit-noted, 受け流し経路)


このご指摘は scope=nit-noted の informational 指摘として認識しました。本 PR での修正は行いません (受け流し経路)。
EOF

  # Step 4b: gh api POST で reply 投稿
  # pipefail を local scope で有効化 (jq 段の失敗の silent 吸収防止、ステップ 2.4 既存 reply 機構と対称)
  local _saved_pipefail
  _saved_pipefail=$(set +o | grep pipefail || echo "set +o pipefail")
  set -o pipefail
  if jq -n --rawfile body "$reply_tmpfile" --argjson in_reply_to "$comment_id" \
       '{"body": $body, "in_reply_to": $in_reply_to}' \
     | gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" -X POST --input - >/dev/null 2>&1; then
    # Step 4c: 成功時のみ comment_id を nit_count_file に append (ステップ 4.6 で wc -l 集計)
    echo "$comment_id" >> "$nit_count_file"
    rm -f "$reply_tmpfile"
    eval "$_saved_pipefail"
    return 0
  else
    echo "[CONTEXT] NIT_NOTED_REPLY_FAILED=1; comment_id=$comment_id; reason=gh_api_post_failure" >&2
    rm -f "$reply_tmpfile"
    eval "$_saved_pipefail"
    return 1
  fi
}

# Claude は scope_map_json の nit-noted エントリを iterate して上記関数を呼ぶ:
# for each (comment_id, body_preview) in nit_noted_findings:
#   for_each_nit_noted_finding "$comment_id" "$body_preview"
```

**Loop termination**:

- すべての nit-noted finding を処理し終えたら本サブステップ終了
- 投稿失敗 (gh api POST 失敗 / rate limit / network error) は `[CONTEXT] NIT_NOTED_REPLY_FAILED=1; comment_id=$comment_id; reason=...` を emit し、当該 finding は skip して次へ進む (non-blocking、`acknowledged_nit_count` 集計対象外)
- すべての投稿が完了したら次の Phase へ進む:
  - **fix commit 不要 PR**: 判定と skip の実体は **ステップ 3.1 冒頭の前置ガード**を参照 (working tree 無変更ならステップ 3 全体を skip し 4.2 へ直行。判定は `git-status-filtered.sh` 経由)。前置ガードは 2.4.N を経由しない non-blocking-only 経路でも評価される全経路共通の単一定義であり、本 bullet はその参照のみ (二重定義しない)
  - **mixed PR** (nit-noted + non-nit findings 混在): non-nit findings は通常通り ステップ 2.2/2.3 経由で ステップ 3 (commit) へ進む。nit-noted reply は parallel に投稿済の状態で commit に embed される

**Why no commit**: [design-rationale.md#nit-noted-reply-notes](references/design-rationale.md#nit-noted-reply-notes)

#### ステップ 2.4.N reasons (NIT_NOTED_REPLY_* retained flags)

ステップ 2.4.N が emit する `[CONTEXT] NIT_NOTED_REPLY_*` retained flag の reason 値 (ステップ 1.2.0 reason 表とは別の observability namespace):

| Flag | reason | Description |
|------|--------|-------------|
| `NIT_NOTED_REPLY_SKIPPED` | `already_replied` | 既に `nit、認知済 (scope=nit-noted` を含む reply が当該 comment に投稿済 (冪等性 — Replied-only respect)。`acknowledged_nit_count` 集計対象外 |
| `NIT_NOTED_REPLY_FAILED` | `mktemp_failed` | reply body 用 tempfile (`${TMPDIR:-/tmp}/rite-fix-nit-reply-${pr_number}-${comment_id}-XXXXXX.md`) の mktemp が失敗 (disk full / inode 枯渇 / permission denied)。non-blocking、当該 finding は skip して次へ進む |
| `NIT_NOTED_REPLY_FAILED` | `gh_api_post_failure` | `jq -n --rawfile body | gh api POST` の pipe が pipefail で exit 非ゼロ (network / auth / rate-limit / `in_reply_to` 不正値)。non-blocking、当該 finding は skip して次へ進む |

**Eval-order enumeration** (ステップ 2.4.N 独立 namespace、ステップ 1.2.0 enumeration とは別): emit reasons sequence = (`already_replied` / `mktemp_failed` / `gh_api_post_failure`)

これらの reason は ステップ 1.2.0 の `FIX_FALLBACK_FAILED` / `REVIEW_SOURCE_*` 系列とは独立した namespace で、`/rite:iterate` 側の ステップ 4 (fix sentinel 判定) では情報提示のみに使われる (ステップ 4.6 の `acknowledged_nit_count > 0` を超える詳細 routing には参加しない)。

---

## ステップ 3: 修正のコミット

> **Reference**: Apply [Comment Best Practices](../../skills/rite-workflow/references/comment-best-practices.md) when finalising fix commits — verify that journal comments (`cycle X F-Y`, PR/Issue numbers), file:line references, and unverified jargon are not left in the diff. The goal is WHY-only inline comments; review/fix history belongs in commit messages and PR descriptions.

### 3.1 Verify Changes

**前置ガード — fix commit 不要 PR の skip (全経路共通)**: ステップ 3 に入る前に必ず評価する。**working tree が無変更**の場合 — nit-only / **non-blocking (実測なし) のみ** / reply-only、およびこれらの混在 — は**ステップ 3 全体 (3.1〜3.5) を skip** し、ステップ 4.2 (完了報告系) へ直行する (空 `git commit` の失敗と、3.3.1 が `HEAD~1..HEAD` = 前 cycle の commit を「本 cycle の fix」として fix-cycle-state に誤記録するのを防ぐ)。本ガードはステップ 2 の出口に相当し、2.4.N を経由しない non-blocking-only 経路でも必ず評価される (ステップ 2.4.N Loop termination の分岐は本ガードへの参照)。

判定には **`git-status-filtered.sh` を使う** (raw `git status --porcelain` を使ってはならない — sandbox 内の Bash 呼び出しでは write-block bind mount が `??` エントリとして必ず現れるため raw 版は恒に非空になり、**ガードが一度も発火しない**。本 helper はその ghost-mount エントリを除去する。同型の理由で `pr-review/SKILL.md` ステップ 4.0.A も helper 経由にしている):

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

`FIX_COMMIT_GUARD=skip` ならステップ 3 全体を skip して ステップ 4.2 へ、`proceed` なら以下を通常どおり実行する。

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

**Fail-Fast Response Principle linkage**: If the fix adopted a **fallback** path (rather than throw/raise propagation) after passing the ステップ 2 Fail-Fast Response checklist, the commit body MUST state the reason the fallback was adopted. LLM: when you detect that any finding's fix introduced defensive code (null check / try-catch wrap / optional chaining / default return), add an explicit sentence naming the skill exception clause or requirement that justified the fallback. Unannotated fallbacks will be re-flagged in ステップ 5 re-review.

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

Use a free-form commit body. Include the reason for the change ("why") in the commit body. For review-fix commits, state the chosen対応方針 and, when a fix addresses a root cause, name that root cause explicitly (the ステップ 3.2.1 Root Cause Gate looks for a `Root cause:` / `根本原因:` paragraph).

- Leave a blank line between the description line and the body
- Write in free-form — no specific prefix or template required
- Focus on "why" the change was needed, not "what" was changed (the description line already covers "what")
- Follow the same language setting as the description line
- Can be omitted for trivial changes (typo fixes, formatting, etc.)

**Trailer**: Generate in the configured language using the unified `{reviewer_display_N}` placeholder (展開ルールは ステップ 2.1 の `{reviewer_display}` 展開ルール表を参照 — Broad Retrieval 経由で `@{user}`、Fast Path 経由 + `target_author_mention_skip == "true"` で `(不明なレビュアー)` / `(unknown reviewer)` に展開される):

- English: `Addresses review comments from {reviewer_display_1}, {reviewer_display_2}`
- Japanese: `{reviewer_display_1}, {reviewer_display_2} のレビューコメントに対応`

**展開ルールの単一源**: 本 phase と ステップ 2.1 の 2 箇所で同一の `{reviewer_display}` 展開ルール (ステップ 2.1 の表) を参照する。mention 生成ロジックを書き直す場合は ステップ 2.1 の表のみを更新し、本 phase の literal 記述は追加しない (drift 防止)。

**Acknowledged-finding trailer (accept で `status: acknowledged` 化された finding 用)**:

ステップ 2.1 で `accept (認知のみ)` を選択した finding が 1 件以上含まれる commit では、commit message の trailer に以下の形式の行を **per-acknowledged-finding で反復生成** する (Co-Authored-By / Addresses review comments trailer と並存):

```
Acknowledged-finding: F-NN (file:line) — reason
```

- `F-NN`: review-result-schema.md の `findings[].id` (例: `F-01`、100 件以上は `F-100`)
- `file:line`: 当該 finding の対象ファイル:行 (ステップ 2.1 で表示されたもの)。**`line == null` (anchor finding) の場合は `(file:anchor)` 表記** に正規化する (ステップ 2.1.A bash block の line_no 正規化と統一)
- `reason`: ステップ 2.1.A Step 1 で取得した `accept_reason` (非空時)、または `user decision: accept (no reason given)` (accept_reason が空の場合) のいずれか。書式例は下記参照

**反復生成ルール**:

- 1 commit に複数の acknowledged finding が含まれる場合、`Acknowledged-finding:` 行を finding 数だけ繰り返す
- 同 commit に non-accept finding (修正 / 返信のみ) も含まれる場合、`Acknowledged-finding:` 行は他 trailer と blank line で区切らずに連続させる (grep 容易性のため):

```
fix(review): レビュー指摘に対応 (acknowledged 含む)

F-01 の入力バリデーションを追加。F-02 は reviewer の指摘範囲を本 PR scope 外と
判断し accept として受け流した。

Acknowledged-finding: F-02 (src/foo.ts:42) — reviewer scope: out-of-current-pr; user decision: accept
Acknowledged-finding: F-05 (src/bar.ts:88) — user decision: accept (no reason given)

Addresses review comments from @reviewer1
```

**grep 可能性**: `Acknowledged-finding:` 行は厳密な literal で、`git log --grep='^Acknowledged-finding:'` で audit 検索可能。trailer 行の前に space / tab を入れてはいけない (行頭 anchor が崩れる)。

```
コミットメッセージ案:

fix(review): {description}

{free-form body — "why" + Root cause paragraph when applicable}

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

**Step 1 — Semantic LLM check (no shell variable dependency)**: The LLM examines the commit body it generated in ステップ 3.2 and determines whether a root-cause explanation is present. Because shell variables do not persist across Bash tool invocations, this gate is intentionally LLM-semantic rather than bash-automated.

A commit body passes the gate when it contains a `Root cause:` / `根本原因:` prefix paragraph that explicitly names the root cause (not just the symptom fixed).

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
| Root cause を追記して再コミット（推奨） | Ask the user for a short root-cause paragraph; prepend a `Root cause: {paragraph}` / `根本原因: {paragraph}` paragraph to the commit body; re-invoke Step 1. The retry count is tracked in conversation context by the LLM — after one retry the LLM falls through to the second option to avoid an infinite prompt loop |
| 意図的な補足コミットとして通過 | Prepend a `Root cause (bypass): {理由}` paragraph to the commit body (the bypass rationale recorded alongside the commit for machine-traceability) AND append the same rationale to work memory `決定事項・メモ`. The bypass is still recorded |
| Abort | Skip this fix cycle; emit `[fix:error]` and return control to the caller |

**Step 3**: Purely cosmetic fixes (typo in a docstring with no functional change) may legitimately select option 2. The bypass MUST be recorded so a later auditor can distinguish "no root cause needed" from "author forgot to identify root cause".


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
commit_sha_before=$(git rev-parse HEAD~1 2>/dev/null || echo "unknown")
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
files_changed=$(git diff --name-only HEAD~1..HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')

# Read existing state or initialize
if [ -f "$state_file" ]; then
  existing=$(cat "$state_file")
else
  existing='{"pr_number":'"$pr_number"',"cycles":[]}'
fi

# Append new cycle entry (propagation_applied is set by ステップ 2.3.1 context)
new_cycle=$(jq -n \
  --arg ts "$timestamp" \
  --arg before "$commit_sha_before" \
  --arg after "$commit_sha_after" \
  --argjson fixed "{findings_fixed_count}" \
  --argjson propagated "{propagation_applied_count}" \
  --argjson files "$files_changed" \
  '{
    "cycle": 0,
    "timestamp": $ts,
    "commit_sha_before": $before,
    "commit_sha_after": $after,
    "findings_fixed": $fixed,
    "findings_new_from_fix": 0,
    "files_changed_by_fix": $files,
    "propagation_applied": $propagated
  }')

# Append and assign cycle number, enforce ring buffer (max 20 entries)
echo "$existing" | jq --argjson entry "$new_cycle" '
  (.cycles | length) as $len |
  .cycles += [$entry | .cycle = ($len + 1)] |
  if (.cycles | length) > 20 then .cycles = .cycles[-20:] else . end
' > "$state_file"

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

> upstream 前提の bare `git push` は使わない。sandbox 有効環境では upstream tracking が未設定（open/pr-create が `-u` を使わなくなったため）で bare push が失敗する（Issue #1894）。

### 3.5 Cycle Branch Cleanup (Post-Push)

After commit + push completes for the current fix cycle, run cleanup so reviewer-created `pr-{N}-cycle{X}` worktrees / branches do not accumulate across cycles. Reviewers run under READ-ONLY enforcement and cannot self-clean (`agents/_reviewer-base.md` § READ-ONLY Enforcement). Cleanup is non-blocking — its failure must not halt the workflow.

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

### 4.2 Report via PR Comment (Optional)

Confirm whether to report completion via PR comment:

```
レビュー指摘への対応を PR コメントで報告しますか？

報告内容案:
---
## レビュー指摘対応完了

以下の指摘に対応しました:

| 指摘 | 対応内容 |
|------|----------|
| {comment_preview} | {response_summary} |

コミット: {commit_sha}

ご確認をお願いします。
---

オプション:
- 報告を投稿
- 報告を編集
- スキップ
```

When posting the report:

```bash
# ✅ SAFE: --body-file for dynamic report content
# trap + cleanup パターンの canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
tmpfile=""
_rite_fix_phase42_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_fix_phase42_cleanup; exit $rc' EXIT
trap '_rite_fix_phase42_cleanup; exit 130' INT
trap '_rite_fix_phase42_cleanup; exit 143' TERM
trap '_rite_fix_phase42_cleanup; exit 129' HUP

tmpfile=$(mktemp) || {
  echo "ERROR: report tmpfile mktemp に失敗しました" >&2
  # mktemp 失敗経路にも retained flag を emit (rationale: references/design-rationale.md#retained-flag-emission)
  echo "[CONTEXT] REPORT_POST_FAILED=1; pr_number={pr_number}; reason=mktemp_failed_report_tmpfile" >&2
  exit 1
}

if ! cat <<'REPORT_EOF' > "$tmpfile"
{report_body}
REPORT_EOF
then
  echo "ERROR: report body の tmpfile 書き込みに失敗しました: $tmpfile" >&2
  echo "[CONTEXT] REPORT_POST_FAILED=1; reason=cat_redirection_failed" >&2
  exit 1
fi

# gh pr comment の exit code を明示的にチェック (silent failure 防止):
# 投稿失敗が silent に発生すると、レビュアーには通知されないまま fix loop が完了と判定される
if ! gh pr comment {pr_number} -R {owner_repo} --body-file "$tmpfile"; then
  echo "ERROR: gh pr comment による報告投稿に失敗しました" >&2
  echo "  対処: gh auth status / network 接続 / PR #{pr_number} の存在を確認してください" >&2
  echo "  影響: 対応完了報告コメントが PR に残らないまま fix loop が完了扱いになる silent regression のリスク" >&2
  # retained flag emit (ステップ 5.1 で detect され [fix:error] へ昇格)
  echo "[CONTEXT] REPORT_POST_FAILED=1; pr_number={pr_number}" >&2
  exit 1
fi
```


### 4.5 Automatic Work Memory Update


If a related Issue exists, automatically update the work memory.

#### 4.5.1 Identify Related Issue

Identify the related Issue from the PR or branch name.

**Extraction priority:**
1. Search for `Closes #XX`, `Fixes #XX`, `Resolves #XX` patterns in the **PR body** (priority)
2. If not found in the PR body, search for the `issue-{number}` pattern in the **branch name**

```bash
# 1. まず PR 本文から Closes #XX パターンを抽出（優先）
# ステップ 1.1 で --json に body を含めて取得済みのため、再取得不要
# trap + cleanup パターンの canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
# rationale: references/design-rationale.md#work-memory-update-rationale
pr_body_tmp=""
pr_body_grep_err=""
branch_grep_err=""
# wm_emit_done フラグ: retained flag の重複 emit と branch fallback 誤起動を防ぐ gate
# 0: まだ emit していない / 1: 既に emit 済み → 以降の retained flag emit と issue_number 依存処理を skip
wm_emit_done=0
_rite_fix_phase451_cleanup() {
  rm -f "${pr_body_tmp:-}" "${pr_body_grep_err:-}" "${branch_grep_err:-}"
}
trap 'rc=$?; _rite_fix_phase451_cleanup; exit $rc' EXIT
trap '_rite_fix_phase451_cleanup; exit 130' INT
trap '_rite_fix_phase451_cleanup; exit 143' TERM
trap '_rite_fix_phase451_cleanup; exit 129' HUP

pr_body_tmp=$(mktemp) || {
  echo "ERROR: pr_body_tmp の mktemp に失敗しました" >&2
  echo "対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_pr_body_tmp" >&2
  exit 1
}
# HEREDOC 経由で pr_body を書き出す。PR body は外部入力のため 'PRBODY_EOF' (single-quote 付き
# delimiter) で shell expansion を完全抑制することが必須 (command injection 防止)
cat > "$pr_body_tmp" <<'PRBODY_EOF'
{pr_body}
PRBODY_EOF
if [ ! -s "$pr_body_tmp" ]; then
  echo "ERROR: pr_body_tmp が空または存在しません: $pr_body_tmp" >&2
  echo "対処: PR body 自体が空であった可能性があります (gh pr view --json body の出力を確認)" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=pr_body_tmp_empty_or_missing; issue_number={issue_number}" >&2
  exit 1
fi

# grep の exit code を明示的に区別 (exit 0: マッチあり / 1: マッチなし → fallback / 2: IO エラー)。
# grep は pipeline 化せず独立 if-else で実行し rc を直接 case 分岐すること
# (pipefail は rightmost non-zero を返すため先頭 grep の rc=2 を捕捉できない)。
# rationale: references/design-rationale.md#work-memory-update-rationale
pr_body_grep_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-pr-body-grep-err-XXXXXX") || {
  echo "ERROR: pr_body_grep_err 一時ファイルの作成に失敗" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_pr_body_grep_err" >&2
  exit 1
}
issue_number=""
if closes_raw=$(grep -oE '(Closes|Fixes|Resolves) #[0-9]+' "$pr_body_tmp" 2>"$pr_body_grep_err"); then
  # マッチあり: 先頭 1 件から数字部分を抽出 (sed -n の失敗は空文字結果として安全)
  issue_number=$(printf '%s\n' "$closes_raw" | head -1 | sed -n 's/.*#\([0-9][0-9]*\).*/\1/p')
else
  pr_body_grep_rc=$?
  case "$pr_body_grep_rc" in
    1)
      # PR 本文に Closes/Fixes/Resolves パターンなし — fallback (ブランチ名抽出) へ
      # 注: stderr ファイルが空でない場合 (grep が warning を出した等) は念のため WARNING 表示
      if [ -s "$pr_body_grep_err" ]; then
        echo "WARNING: pr_body grep が exit 1 (no match) で完了しましたが stderr に出力がありました:" >&2
        head -3 "$pr_body_grep_err" | sed 's/^/  /' >&2
      fi
      :
      ;;
    *)
      # IO/権限/構文エラー: soft failure (exit 1 しない — retained flag のみ emit し、
      # ステップ 5.1 が [fix:pushed-wm-stale] を出力する)。
      # rationale: references/design-rationale.md#work-memory-update-rationale
      echo "ERROR: PR 本文の grep が IO/権限/構文エラーで失敗しました (rc=$pr_body_grep_rc)" >&2
      echo "詳細 (stderr 先頭 5 行):" >&2
      head -5 "$pr_body_grep_err" | sed 's/^/  /' >&2
      echo "  対処: 環境の grep バイナリと権限を確認後、再実行してください" >&2
      echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=pr_body_grep_io_error; rc=$pr_body_grep_rc" >&2
      # wm_emit_done=1: 下流の branch fallback 誤起動と retained flag の 2 回連続 emit を防ぐ
      wm_emit_done=1
      issue_number=""  # branch fallback も skip して下流の WM_UPDATE_FAILED 経路に流す (M-5 対応)
      ;;
  esac
fi

# 2. PR 本文で見つからない場合、ブランチ名から抽出。
# git branch は pipeline 化せず if-else で rc を直接捕捉する (pipefail 罠回避、同上 rationale)。
# wm_emit_done guard: IO error 経路で emit 済みなら branch fallback を skip する
if [[ -z "$issue_number" ]] && [ "$wm_emit_done" = "0" ]; then
  branch_grep_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-branch-grep-err-XXXXXX") || {
    echo "ERROR: branch_grep_err 一時ファイルの作成に失敗" >&2
    echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_branch_grep_err" >&2
    exit 1
  }
  if branch_name=$(git branch --show-current 2>"$branch_grep_err"); then
    # branch 取得成功: issue-N パターンを抽出 (sed -n の失敗は空文字結果として安全)
    issue_number=$(printf '%s\n' "$branch_name" | sed -n 's/.*issue-\([0-9][0-9]*\).*/\1/p')
    # ブランチ名にも issue-N パターンがない場合は issue_number は空のまま (下流で WM_UPDATE_FAILED emit)
  else
    branch_show_current_rc=$?
    # pr_body_grep_io_error と同根の soft failure (retained flag のみ emit しコミット済み fix を保護)
    echo "ERROR: branch 名取得 (git branch --show-current) が IO/権限エラーで失敗しました (rc=$branch_show_current_rc)" >&2
    echo "詳細 (stderr 先頭 5 行):" >&2
    head -5 "$branch_grep_err" | sed 's/^/  /' >&2
    echo "  対処: 環境の git バイナリと権限、cwd が git repo であることを確認後、再実行してください" >&2
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=branch_grep_io_error; rc=$branch_show_current_rc" >&2
    wm_emit_done=1
    issue_number=""  # 下流 block は wm_emit_done guard で skip されるため stale WM 経路へ流れる
  fi
fi
```


**Implementation note for Claude**: `{pr_body}` はドキュメントのプレースホルダ。Claude はスクリプト生成前に実際の PR body で置換する。**必ず single-quoted HEREDOC delimiter (`<<'PRBODY_EOF'`) を使う**こと — double-quoted printf 形式 (`printf '%s' "{pr_body}"`) は PR body 内の `"` でクォート閉じが起きると bash parser が後続テキストをコマンドラインとして解釈する構文エラーになり、さらに `$(...)` 形式の command substitution が literal 展開時に実行される **command injection リスク** を生む。PR body は外部入力 (PR 投稿者) であるため、shell expansion を完全抑制する HEREDOC が必須。

If no Issue number is found, display a warning **and emit a `WM_UPDATE_FAILED=1` retained flag** so the caller (`/rite:iterate` review-fix loop) treats the result as `[fix:pushed-wm-stale]` instead of silently treating it as `[fix:pushed]`:

```bash
# issue_number 抽出失敗時: WARNING + retained flag emit (ステップ 5.1 が [fix:pushed-wm-stale] を出力)。
# wm_emit_done guard で重複 emit を防ぐ。
# rationale: references/design-rationale.md#work-memory-update-rationale
if [[ -z "$issue_number" ]] && [ "$wm_emit_done" = "0" ]; then
  echo "⚠️ Issue 番号が特定できないため作業メモリ更新をスキップしました" >&2
  echo "  PR 本文に Closes/Fixes/Resolves #XX が含まれていないか、ブランチ名に issue-{number} パターンがありません。" >&2
  echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
  echo "  対処: ステップ 5.1 で WM_UPDATE_FAILED=1 を context に set し、[fix:pushed-wm-stale] を出力する" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=issue_number_not_found" >&2
  wm_emit_done=1
fi
```


#### 4.5.2 Retrieve and Update Work Memory Comment

The work memory comment update is delegated to `issue-comment-wm-sync.sh` (canonical caller: `skills/issue-implement/SKILL.md` 5.1.1.2) via **two transforms**, with a thin shim that maps helper failures to the `WM_UPDATE_FAILED` retained flag:

1. **`update-progress`**: 進捗サマリーテーブル + 変更ファイルセクションを更新
2. **`append-section`**: レビュー対応履歴 (4.5.3 の内容) を `### レビュー対応履歴` セクションへ追記

委譲後に caller が担うのは base_branch 解決と `git diff` による変更ファイル markdown 生成のみ。comment 取得・body 変換・safety check・PATCH・backup は helper 内部で完結する。helper の機械可読な `status=...; reason=...` 行を shim が読み、`no_comment` (legitimate no-op) 以外の skipped/error を `[CONTEXT] WM_UPDATE_FAILED=1` にマップする。これにより ステップ 5.1 が `[fix:pushed-wm-stale]` を出力し、原 inline 実装が持っていた silent-regression guard (work memory 更新失敗を `[fix:pushed]` に潰さない) を維持する。

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること。
# shim は同一 invocation 内で helper の status= 出力を読み取る。{plugin_root} はリテラル値で埋め込む。
# trap + cleanup の canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
changed_files_tmp=""
history_tmp=""
diff_err=""
wm_sync_err=""
_rite_fix_phase452_cleanup() { rm -f "${changed_files_tmp:-}" "${history_tmp:-}" "${diff_err:-}" "${wm_sync_err:-}"; }
trap 'rc=$?; _rite_fix_phase452_cleanup; exit $rc' EXIT
trap '_rite_fix_phase452_cleanup; exit 130' INT
trap '_rite_fix_phase452_cleanup; exit 143' TERM
trap '_rite_fix_phase452_cleanup; exit 129' HUP

# base_branch 解決 (簡素化): grep+sed で抽出、空なら develop に fallback。
# 誤解決しても git diff 失敗として表面化する (silent fallback にならない)
base_branch=$(grep -E '^\s*base:' rite-config.yml 2>/dev/null | head -1 \
  | sed 's/.*base:[[:space:]]*"\?\([^"]*\)"\?.*/\1/')
[ -z "$base_branch" ] && base_branch="develop"

# 変更ファイル markdown を changed-files-file に生成する。
# changed-files-file 作成 or git diff が失敗 → git_diff_failed を emit し helper を呼ばない
# (comment 不変 = 原実装が git diff 失敗時に PATCH 前で exit した挙動と等価)。
git_diff_failed=0
if ! changed_files_tmp=$(mktemp); then
  echo "ERROR: changed-files-file の mktemp に失敗 (git diff 不能)" >&2
  echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=git_diff_failed; issue_number={issue_number}" >&2
  git_diff_failed=1
fi
if [ "$git_diff_failed" -eq 0 ]; then
  diff_err=$(mktemp 2>/dev/null) || diff_err=""
  if changed_files_raw=$(git diff --name-status "origin/${base_branch}...HEAD" 2>"${diff_err:-/dev/null}"); then
    printf '%s\n' "$changed_files_raw" | while IFS=$'\t' read -r status file; do
      [ -z "$status" ] && continue
      case "$status" in
        A) echo "- \`${file}\` - 追加" ;;
        M) echo "- \`${file}\` - 変更" ;;
        D) echo "- \`${file}\` - 削除" ;;
        R*) echo "- \`${file}\` - 名前変更" ;;
        *) echo "- \`${file}\` - ${status}" ;;
      esac
    done > "$changed_files_tmp"
  else
    echo "WARNING: git diff --name-status \"origin/${base_branch}...HEAD\" が失敗しました。" >&2
    [ -n "$diff_err" ] && [ -s "$diff_err" ] && head -3 "$diff_err" | sed 's/^/  /' >&2
    echo "  考えられる原因: shallow clone (base branch 未 fetch) / 無効な base branch 名 / git リポジトリ外" >&2
    echo "  対処: git fetch origin ${base_branch} を実行後に再試行、または rite-config.yml の branch.base を確認" >&2
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=git_diff_failed; issue_number={issue_number}" >&2
    git_diff_failed=1
  fi
  [ -n "$diff_err" ] && rm -f "$diff_err"
fi

# helper の status= 行から state (success/skipped/error) と reason を抽出するヘルパ。
# sed を `reason=\(...` 形式で書くことで、drift-check P2/P5 が helper 由来の reason (no_comment 等)
# を fix.md の emit として誤検出しないようにする (`reason=` の直後が `[a-z_]` でないと両 awk/grep
# の抽出パターンにマッチしない)。
wm_state_of() { printf '%s\n' "$1" | sed -n 's/^status=\([a-z]*\).*/\1/p' | head -1; }
wm_reason_of() { printf '%s\n' "$1" | sed -n 's/.*reason=\([a-z_]*\).*/\1/p' | head -1; }

if [ "$git_diff_failed" -eq 0 ]; then
  # helper の stderr (root-cause 診断) を退避する (pr-review.md ステップ 6.2 と同じ stderr-capture 規約)。
  # mktemp 失敗時は /dev/null に fallback する。
  wm_sync_err=$(mktemp 2>/dev/null) || wm_sync_err=""
  # --- transform 1: 進捗サマリー + 変更ファイル更新 ---
  # {impl_status} / {test_status} / {doc_status} は Claude が git diff 結果から判定して substitute する。
  wm_progress_out=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
    --issue {issue_number} \
    --transform update-progress \
    --impl-status "{impl_status}" --test-status "{test_status}" --doc-status "{doc_status}" \
    --changed-files-file "$changed_files_tmp" 2>"${wm_sync_err:-/dev/null}")
  wm_p_state=$(wm_state_of "$wm_progress_out")
  wm_p_reason=$(wm_reason_of "$wm_progress_out")

  if [ "$wm_p_state" != "success" ] && [ "$wm_p_reason" != "no_comment" ]; then
    # update-progress が no_comment 以外の skipped/error (body 取得失敗 / safety check 失敗 /
    # transform 失敗 / PATCH 失敗を helper が内部処理し status= で通知) → stale guard。
    echo "ERROR: 進捗サマリー更新 (issue-comment-wm-sync update-progress) が失敗 (helper status: $wm_progress_out)" >&2
    [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | sed 's/^/    /' >&2; }
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_progress_failed; issue_number={issue_number}" >&2
  elif [ "$wm_p_reason" = "no_comment" ]; then
    # work memory comment が未投稿 (初回 fix / 削除済み) の legitimate no-op。
    # PATCH 対象が無いため append-section も skip する (WM_UPDATE_FAILED は立てない)。
    echo "INFO: work memory comment が未検出のため WM 更新を skip (legitimate no-op)" >&2
  else
    # --- transform 2: レビュー対応履歴の追記 ---
    # content-file には 4.5.3 のエントリ本体のみを書く (先頭の `### レビュー対応履歴` 見出しは
    # append-section が既存セクションを特定して追記するため含めない)。
    if history_tmp=$(mktemp); then
      cat > "$history_tmp" << 'HISTORY_EOF'
{4.5.3 のエントリを実際の値で置換して記述。先頭に `### レビュー対応履歴` 見出しは付けない}
HISTORY_EOF
      wm_history_out=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
        --issue {issue_number} \
        --transform append-section --section "レビュー対応履歴" --content-file "$history_tmp" 2>"${wm_sync_err:-/dev/null}")
      wm_h_state=$(wm_state_of "$wm_history_out")
      wm_h_reason=$(wm_reason_of "$wm_history_out")
      if [ "$wm_h_state" != "success" ] && [ "$wm_h_reason" != "no_comment" ]; then
        echo "ERROR: レビュー対応履歴の追記 (issue-comment-wm-sync append-section) が失敗 (helper status: $wm_history_out)" >&2
        [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | sed 's/^/    /' >&2; }
        echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
        echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_history_failed; issue_number={issue_number}" >&2
      fi
    else
      echo "ERROR: レビュー対応履歴 content-file の mktemp に失敗。追記できません" >&2
      echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_sync_history_failed; issue_number={issue_number}" >&2
    fi
  fi
fi
```

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

**Note for Claude**: ⚠️ このブロック全体を**1つの Bash ツール呼び出し**で実行すること。`git diff` による変更ファイル生成・helper の `update-progress` / `append-section` 呼び出し・各 status= の shim 判定を別の Bash 呼び出しに分割すると、`git_diff_failed` フラグや `changed_files_tmp` パス等のシェル変数が失われる。`{4.5.3 のエントリを実際の値で置換して記述...}` を 4.5.3 のテンプレートから生成した実際の追記内容 (見出し行を除く) で置換し、**すべてを1ブロックで**実行する。

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

**placeholder 責務分離**: `{confidence_override_section}` には **純粋に findings 一覧のみ** (`; ` 区切り) を入れる。policy override の説明文 (`外部ツール由来、Confidence 70 のまま 80+ ゲートをバイパスする policy override、ユーザー承認済み`) は work memory レビュー対応履歴側 (ステップ 4.5.3) で展開される。

**重要 — 改行禁止**: bullet item 内に改行と子箇条書きを入れる場合 Markdown は子側に 2 スペースインデントを要求するが、placeholder 展開時の自動インデント処理は脆弱で履歴の構造を壊しやすい。そのため `{confidence_override_section}` は **同一行に押し込める** 形式を厳格に採用する。

### 4.6 Completion Report

```
PR #{number} のレビュー指摘対応を完了しました

全指摘: {total_count}件
対応した指摘: {count}件
- 修正: {fix_count}件
- 返信: {reply_count}件
- nit 認知 (scope=nit-noted、reply-only、本 cycle): {acknowledged_nit_count}件
- non-blocking (実測なし、fix 対象外): {non_blocking_count}件
- accept 認知 (user decision、Issue 完了まで累計): {accept_count}件{accept_warning_suffix}
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

数値正規化 (BSD wc は出力先頭に空白を付ける platform 依存問題を回避、ステップ 2.1.A Step 7 と bit-exact 対称)。ファイル不在時 / 空ファイル時は `0`。state file は cycle を跨いで永続化される (Issue 完了まで保持) ため、本 cycle で新規 accept が 0 件でも累積件数が表示される。

**`acknowledged_nit_count` との関係**: 両者は **独立したカウンタ**。`acknowledged_nit_count` は reviewer の scope 判定 (`scope == "nit-noted"`) で reply-only 経路に流れた finding 数 (ステップ 2.4.N)、`accept_count` は user が ステップ 2.1 で「accept (認知のみ)」を選択した finding 数 (ステップ 2.1.A)。両方とも最終的に `status == "acknowledged"` になるが、エントリ経路 (reviewer 判定 vs user 判定) と永続化方法 (ステップ 2.4.N tempfile vs `.rite/state/accepted-fingerprints-*.txt`) が異なる。

**`{acknowledged_nit_count}` の展開ルール**:

| 状況 | `{acknowledged_nit_count}` |
|------|----------------------------|
| ステップ 2.4.N nit-noted-reply で 0 件投稿 (scope=nit-noted finding なし、または全件 already_replied skip) | `0` |
| ステップ 2.4.N nit-noted-reply で N 件投稿成功 | `{N}` |

**読み出し方法**: `nit_count_file="${TMPDIR:-/tmp}/rite-fix-acknowledged-nit-{pr_number}.txt"` の行数を `wc -l < "$nit_count_file"` で取得する (ステップ 2.4.N で各成功投稿で `echo "$comment_id" >> "$nit_count_file"` により append されている)。tempfile 不在の場合は `0` を表示。ステップ 5.1 cleanup で本 tempfile も削除する。

**重要**: `acknowledged_nit_count == 0` の場合でも本行は省略せず常に表示する (M2 受け流し経路の動作観測のため、ゼロ件であることを明示)。本 metric は `/rite:pr-review` ステップ 5.3 評価では使われない (nit-noted は `overall_assessment` に影響せず、mergeable 判定の countdown 対象外 — [`assessment-rules.md`](./references/assessment-rules.md) §5.3.1 参照)。fix loop 内で `acknowledged_nit_count > 0` の場合、`プッシュ: 未実行` かつ 本 cycle 内で accept 決定なし (判定条件はステップ 5.1 Output Pattern テーブル row 4/5 参照) かつ `全指摘 == 対応指摘` であれば re-review はトリガーされず、本 cycle で finalize する (AC-1: nit-only PR の 2 cycle 即収束)。

**`{confidence_override_count}` / `{confidence_override_files_suffix}` の展開ルール** (Confidence policy override の追跡可視化):

| 状況 | `{confidence_override_count}` | `{confidence_override_files_suffix}` |
|------|------------------------------|--------------------------------------|
| 0 件 (override なし、通常時) | `0` | 空文字列 |
| 1 件以上 (override 適用あり) | `{N}` | ` ({file:line_1}; {file:line_2}; ...)` (先頭スペース付きカッコ内に `; ` 区切りで一覧、ステップ 1.2 の data flow 定義と統一) |

**重要**: `confidence_override_count == 0` の場合でも本行は省略せず常に表示する (override が「なし」であることを明示し、silent な policy bypass の有無を可視化するため)。

**Field descriptions:**

| Field | Description | Calculation |
|-------|-------------|-------------|
| `全指摘: {total_count}件` | Total number of findings | ステップ 1 で取得した finding 数 (**Markdown / 会話経路では `non_blocking_findings` を含む。JSON 経路は pr-review ステップ 6.1.a の除外契約により `findings[]` のみを読むため含まない** — ステップ 1.2.1 step 6 の「経路間で値は一致しない」注記と同一の非対称)。母集団 = **severity_map ∪ ステップ 1.3 fallback (GitHub state ベース) で分類された未対応コメント** — rite レビュー結果を読めた経路では `total_count = |severity_map|`、severity_map が空の fallback 経路 (手動レビューのみ / pr-review 未実行) では fallback 分類の件数を用いる。4.6 の `対応した指摘` 式と同一母集団であることが finalize 条件 `全指摘 == 対応指摘` の前提。なお pr-review 側の `total_findings` (blocking 集合のみの件数 — assessment-rules.md §5.3.3) とは**別概念** |
| `対応した指摘: {count}件` | Number of findings addressed | `fix_count + reply_count + skip_count + acknowledged_nit_count + non_blocking_count` (nit-noted reply 投稿と non-blocking 分類も「対応」に含めることで、nit-only / non-blocking-only PR でも `全指摘 == 対応指摘` 条件を満たし有限 cycle で収束する — `non_blocking_count` を式に含めないと非実測 finding が「未対応」として残り finalize 分岐が発火せず max_review_cycles まで空転する)。**各項は排他**: `skip_count` は ステップ 2.1 でユーザーが「スキップ」を選んだ finding のみを数え、**non-blocking 分類による ステップ 2.1 skip は含めない** (そちらは `non_blocking_count` が受け持つ)。`acknowledged_nit_count` との排他も同様 (nit-noted は scope による分類で、non-blocking は measured による分類) |
| `non-blocking (実測なし): {non_blocking_count}件` | Number of findings classified as non-blocking by the measured gate | **measured_map の false のうち `scope_map[key] != "nit-noted"` の件数** (単一定義 — ステップ 1.2.1 step 6 / 1.4 表示テンプレートと同一。nit-noted は正規化後 scope_map による参照時除外で含まれず `acknowledged_nit_count` と二重計上しない。ステップ 1.3 の non-blocking 分類条件と同一フィルタ。step 4 の出自確認で振り替えた key は減算する)。fix commit / reply の対象外だが「対応済み」に算入する (記録は `/rite:pr-review` ステップ 5.4 の「実測なし指摘」section が担う)。0 件でも常時表示 |
| `Confidence override (policy bypass): {N}件` | Number of findings imported via Confidence policy override | ステップ 1.2 best-effort parse で「Confidence 70 のままバイパス」を選択した finding 数 (Confidence 80+ ゲート invariant の policy override 追跡義務)。0 件でも常時表示 |
| `レビューソース: {review_source} (...)` | Provenance of the review findings consumed by this fix run | ステップ 1.2.0 Priority chain で決定された `review_source` 値 (schema.md Priority 1 emit 義務の provenance 契約を ステップ 4.6 で履行)。展開ルールは ステップ 4.5.3 の `{review_source}` / `{review_source_path_display}` 表を参照 |

**Note**: The review-fix loop of `/rite:iterate` checks the content of this completion report to determine the next action:
- `プッシュ: 完了` -> Execute re-review (`/rite:pr-review` を起動。範囲は同 skill の ステップ 1.2.4 が cycle に応じて決める — fix 側で範囲を宣言しない)
- 本 cycle 内で accept 決定が発生 -> Execute re-review (同上。accept は fingerprint 永続化のみを行い、実際の suppression 適用は次回 `/rite:pr-review` ステップ 5.1.2.A [Non-Target] が担うため、re-review せずに終端すると suppression の成否が未確認のまま loop が終わる — Issue #1811)
- `プッシュ: 未実行` and 本 cycle 内で accept 決定なし and `全指摘 == 対応指摘` -> Proceed to completion report (all addressed via replies)

「本 cycle 内で accept 決定が発生」の**唯一の真実の源**（判定に使う具体的な context マーカー）は ステップ 5.1 Output Pattern テーブル row 4/5 (下記) を参照すること。本 Note では条件を重複記述しない（Issue #1811 cycle 2 で「別Issue作成: N件」という commit `0dee5b22` で削除済みの旧 Phase 4.3 の残骸フィールドを条件として複製していたことが判明したため、以後は複製ではなく参照に統一する）。


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

**Step 2**: Generate a fix Raw Source from the fix results:

The fix content includes: PR number, findings addressed, fix strategies used, and patterns of overcorrection or effective approaches.

```bash
# {plugin_root} はリテラル値で埋め込む
# ⚠️ wiki-ingest-trigger.sh は --content-file に $PWD 配下・/tmp/rite-*・$TMPDIR/rite-* prefix のみを受容する
# mktemp デフォルトの ${TMPDIR:-/tmp}/tmp.* では trigger が exit 1 で silent fail する
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-content-XXXXXX")
trigger_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-trigger-err-XXXXXX") || trigger_stderr=/dev/null
# rm -f /dev/null は EPERM (exit 1) を返すため trap で条件分岐する (F-07 対応)
trap 'rm -f "$tmpfile"; [ "$trigger_stderr" != "/dev/null" ] && rm -f "$trigger_stderr"' EXIT
content_write_failed=0  # heredoc write 失敗フラグ (Step 3 で genuine trigger 失敗と区別するため carry-forward)

# heredoc 書き込みの exit code を捕捉 (disk full / permission 拒否で truncated content が
# silent に ingest される regression を防ぐ。wiki ingest は非ブロッキングのため write 失敗時は ingest をスキップ)
if ! cat <<'FIX_EOF' > "$tmpfile"
## Fix Results

- **PR**: #{pr_number}
- **Type**: fix
- **Fixed at**: {timestamp}

### Fix Patterns
{fix_summary — 修正パターン、過剰反応の傾向、効果的な修正戦略を LLM が修正結果から要約して埋め込む}

### Statistics
- Total findings: {total_count}
- Fixed: {fix_count}
- Replied: {reply_count}
FIX_EOF
then
  echo "[CONTEXT] WIKI_CONTENT_WRITE_FAILED=1; reason=cat_redirection_failed" >&2
  echo "WARNING: fix ステップ 4.6.W: tmpfile への heredoc 書き込みに失敗 (/tmp full / permission 拒否 / inode 枯渇)。wiki ingest を非ブロッキングにスキップ。" >&2
  trigger_exit=1
  content_write_failed=1
  echo "trigger_exit=$trigger_exit"
else
  bash {plugin_root}/hooks/wiki-ingest-trigger.sh \
    --type fixes \
    --source-ref "pr-{pr_number}" \
    --content-file "$tmpfile" \
    --pr-number {pr_number} \
    --title "PR #{pr_number} fix results" \
    2>"$trigger_stderr"
  trigger_exit=$?
  echo "trigger_exit=$trigger_exit"
  if [ "$trigger_exit" -ne 0 ] && [ "$trigger_stderr" != "/dev/null" ] && [ -s "$trigger_stderr" ]; then
    # UTF-8 multi-byte 境界を safe にする (head -c 500 で切れた invalid sequence を drop)
    # (F-09 対応) iconv 不在環境 (Alpine 等) では LC_ALL=C tr で ASCII-only fallback
    if command -v iconv >/dev/null 2>&1; then
      _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
    else
      _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | LC_ALL=C tr -cd '\11\12\15\40-\176')
    fi
    echo "[CONTEXT] WIKI_TRIGGER_STDERR=${_wiki_err_snippet}" >&2
  fi
fi
echo "content_write_failed=$content_write_failed"
```

**Non-blocking**: `wiki-ingest-trigger.sh` exit 2 (Wiki disabled/uninitialized) and other errors are captured in `trigger_exit` and do not halt the workflow. The LLM reads `trigger_exit` from stdout and skips ステップ 4.6.W.2 when it is non-zero. The LLM **also reads `content_write_failed` from the prior Step 2 stdout** (`echo "content_write_failed=$content_write_failed"`) and re-establishes it before evaluating Step 3 — a separate bash invocation does not inherit shell state, so the carry-forward of `content_write_failed` is required exactly as for `trigger_exit`. `content_write_failed=1` means the heredoc content write failed and the trigger was never invoked. Ingest failure does not block the fix workflow.

**Step 3 — Failure surfacing**: 2 つの失敗経路を区別して surface する。

- **(a) content write 失敗** (`content_write_failed=1`): trigger は**起動していない**ため `trigger_exit` の値 (1) を reason にすると誤帰属になる。root cause は Step 2 の `WIKI_CONTENT_WRITE_FAILED` で既出だが、W Phase Completion Gate (ステップ 5.0) は `WIKI_INGEST_*` 接頭辞の sentinel しか認識しないため、gate-visible な `WIKI_INGEST_FAILED` を `reason=content_write_failed` で emit する。
- **(b) genuine trigger 失敗** (`trigger_exit != 0` AND `trigger_exit != 2`、exit 2 = Wiki disabled/uninitialized = legitimate skip は Step 1 で既出): `wiki-ingest-trigger.sh` が実際に非ゼロ終了したので `reason=trigger_exit_$trigger_exit` で emit する。

```bash
if [ "${content_write_failed:-0}" -eq 1 ]; then
  # write 失敗経路: trigger は未起動。gate (ステップ 5.0) は WIKI_INGEST_* のみ認識するため
  # accurate な reason を付けて WIKI_INGEST_FAILED を emit する (trigger_exit_1 への誤帰属を防ぐ)。
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=content_write_failed; exit_code=1"
  echo "WARNING: fix ステップ 4.6.W: content write 失敗のため wiki ingest をスキップ (trigger は未起動)。" >&2
elif [ "${trigger_exit:-1}" -ne 0 ] && [ "${trigger_exit:-1}" -ne 2 ]; then
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
  echo "WARNING: wiki-ingest-trigger.sh exited $trigger_exit during skills/fix/SKILL.md ステップ 4.6.W" >&2
fi
```

**ステップ 4.6.W Step 3 failure surfacing reason** (`WIKI_INGEST_FAILED` flag の reason 値):

| reason | Description |
|--------|-------------|
| `content_write_failed` | tmpfile への heredoc write 失敗 (`content_write_failed=1`)。trigger は未起動。root cause の `WIKI_CONTENT_WRITE_FAILED` とは別に、gate-visible な `WIKI_INGEST_FAILED` を accurate reason で surface する (`trigger_exit_*` への誤帰属を防ぐ) |
| `trigger_exit_<n>` | `wiki-ingest-trigger.sh` が exit `<n>` (≠0, ≠2) で終了した genuine trigger 失敗 |

### 4.6.W.2 Wiki Raw Commit (Shell — deterministic path)


**Responsibility scope**: this block commits **raw sources only**. LLM-driven Wiki **page** integration is deferred to `/rite:wiki-ingest`, which is idempotent over accumulated raw sources and can be invoked later. The split guarantees raw sources are never lost even when page integration is skipped or fails.

**Condition**: Execute only when **all** of the following are true (read from prior ステップ 4.6.W stdout):

- `wiki_enabled=true`
- `auto_ingest=true`
- `trigger_exit=0` (the trigger ran successfully — non-zero means Wiki disabled/uninitialized, so there is nothing to commit)

When the condition is not satisfied, skip this block.

```bash
# {plugin_root} はリテラル値で埋め込む
#
# commit_err の signal trap 登録を block 冒頭で行う。
commit_err=""
trap 'rm -f "${commit_err:-}"' EXIT INT TERM HUP

# mktemp failure must NOT silently swallow wiki-ingest-commit.sh stderr (review / fix / close で対称)。
# rc 捕捉は `if cmd; then :; else rc=$?; fi` 形式 (「!」否定は $? を反転するため使用禁止)
# rationale: references/design-rationale.md#wiki-ingest-notes
if commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-commit-err-XXXXXX" 2>/dev/null); then
  : # mktemp 成功 — commit_err は valid path
else
  mktemp_commit_err_rc=$?
  echo "WARNING: mktemp failed for wiki-ingest-commit stderr capture (rc=$mktemp_commit_err_rc) — script stderr will be suppressed" >&2
  echo "  hint: check /tmp permission / disk space / inode exhaustion" >&2
  commit_err="/dev/null"
fi
wiki_ingest_commit_rc=0
if commit_out=$(bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh 2>"${commit_err}"); then
  # Success — the script prints exactly one status line to stdout, e.g.
  #   [wiki-ingest-commit] committed=1; branch=wiki; head=<sha>; push=ok
  #   [wiki-ingest-commit] committed=0; branch=wiki; reason=no-pending
  echo "$commit_out"
  echo "[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}; type=fixes"
else
  wiki_ingest_commit_rc=$?
  if [ "$commit_err" != "/dev/null" ] && [ -s "$commit_err" ]; then
    head -5 "$commit_err" | sed 's/^/  /' >&2
  fi
  # exit 2 = legitimate skip / exit 4 = commit landed but push failed (observable に surface する)
  case "$wiki_ingest_commit_rc" in
    2)
      echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing; exit_code=$wiki_ingest_commit_rc"
      echo "WARNING: wiki-ingest-commit.sh exited 2 (wiki branch missing / disabled) during skills/fix/SKILL.md ステップ 4.6.W.2" >&2
      ;;
    4)
      echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; exit_code=$wiki_ingest_commit_rc"
      if [ -n "${commit_out:-}" ]; then
        echo "$commit_out"
      fi
      echo "WARNING: wiki-ingest-commit.sh exited 4 (commit landed locally, push failed) during skills/fix/SKILL.md ステップ 4.6.W.2" >&2
      ;;
    *)
      echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=commit_rc_$wiki_ingest_commit_rc; exit_code=$wiki_ingest_commit_rc"
      echo "WARNING: wiki-ingest-commit.sh exited $wiki_ingest_commit_rc during skills/fix/SKILL.md ステップ 4.6.W.2" >&2
      ;;
  esac
fi
[ "$commit_err" != "/dev/null" ] && rm -f "$commit_err"
commit_err=""
trap - EXIT INT TERM HUP
```

**Non-blocking**: failures do not halt the fix workflow. `wiki-ingest-commit.sh` restores raw source files on failure via its cleanup trap, so the next invocation can retry them.

**ステップ 4.6.W.2 Wiki Raw Commit failure reasons** (reason table drift prevention — `wiki-ingest-commit.sh` の exit code を `[CONTEXT] WIKI_INGEST_*` flag の reason 値として surface する):

| reason | Description |
|--------|-------------|
| `commit_branch_missing` | `wiki-ingest-commit.sh` が exit 2 (wiki branch 不在 / 無効) で終了 (`WIKI_INGEST_SKIPPED` flag、非ブロッキング) |
| `commit_rc_4` | `wiki-ingest-commit.sh` が exit 4 (commit はローカルに landed したが push 失敗) で終了 (`WIKI_INGEST_PUSH_FAILED` flag、非ブロッキング)。その他の非ゼロ exit は `commit_rc_$wiki_ingest_commit_rc` 動的 reason として `WIKI_INGEST_FAILED` flag で emit される |

**Position rationale**: ステップ 4.6.W (and therefore 4.6.W.2) runs after the review-fix loop has exited. Raw sources written mid-loop would reflect unsettled fix state, so the placement is intentional.

**Responsibility boundary**: `wiki-ingest-trigger.sh` writes a raw source file into the dev branch working tree; `wiki-ingest-commit.sh` moves that file onto the `wiki` branch and commits it. LLM-driven page integration is the exclusive responsibility of `/rite:wiki-ingest` at a later time.

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When PR is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When Comment Retrieval Fails | ネットワーク接続を確認; `gh auth status` で認証状態を確認 |
| Error During File Modification | この指摘をスキップして続行 / 手動で修正 (WARNING を stderr に出力) |
| Commit Failure | `git status` で状態を確認; 問題を解決してから再度コミット (WARNING を stderr に出力) |

## ステップ 5: E2E フロー継続 (出力パターン)


**用語定義**: 本 fix.md では **soft failure** (retained flag を emit して caller に判断を委ねる — ステップ 5.1 で `[fix:error]` / `[fix:pushed-wm-stale]` に昇格) / **hard fail-fast** (即 exit 1 + retained flag 併用) / **stale** (work memory が最新 fix 未反映 = `[fix:pushed-wm-stale]`) / **silent regression** (soft failure の silent handle) を厳密に区別する。 <!-- rationale: references/design-rationale.md#output-pattern-notes -->

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

**Handoff マーカー**: 結果に応じて 3 種類に分岐する (Stop hook による consume・再注入の機構解説: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism))。
- **継続** (`[fix:pushed]` / `[fix:pushed-wm-stale]`): `--handoff "/rite:pr-review {pr_number}"` で**ループ継続マーカー**をセットする。
- **正常終了** (`[fix:replied-only]`): `--handoff "FINALIZE:fix:replied-only:{pr_number}"` で**終了通知マーカー (FINALIZE handoff)** をセットする。
- **エラー** (`[fix:error]`): `--handoff` を**付けない** (handoff はデフォルトクリア)。`[fix:error]` は clean terminal ではなく caller (`/rite:iterate` ステップ4) で AskUserQuestion (再試行/中止) に分岐するため、完了通知を強制してはならない。

判定は本ステップ時点で**既に確定している入力**で行う (sentinel 評価テーブルより前だが、push 状態・fatal フラグ・本 cycle 内の accept 発生有無は ステップ 4.6 / 4.5 / 2.4 / 2.1.A / 1.0.1 で既知): **(`プッシュ: 完了` または 本 cycle 内で accept 決定が発生) かつ fatal フラグ (`FIX_FALLBACK_FAILED` / `REPLY_POST_FAILED` / `REPORT_POST_FAILED`) が context に未 set なら継続 = `--handoff "/rite:pr-review {pr_number}"`**。push 無し かつ 本 cycle 内で accept 決定なし かつ fatal フラグ未 set なら正常終了 = `--handoff "FINALIZE:fix:replied-only:{pr_number}"`。fatal フラグ有り (`[fix:error]`) なら `--handoff` なし。`WM_UPDATE_FAILED` は `[fix:pushed-wm-stale]` (= 継続) に縮退するため継続 handoff を打ち消さない。「本 cycle 内で accept 決定が発生」の判定条件（具体的な context マーカー、および累計値を使ってはならない理由）は ステップ 5.1 Output Pattern テーブル row 4/5 の直後の注記を**唯一の真実の源**として参照すること（Issue #1811。重複記述はしない）。

> **Note (review がセットした handoff の消去経路)**: 上記の判定が責務とするのは fix.md が**自身でセットする** handoff (継続 `/rite:pr-review` / 終了 `FINALIZE:fix:replied-only`) のみ。pr-review.md Step 8.0 が**セットした** `/rite:fix` handoff は `[fix:error]` 早期 exit (本 Step 5.1 不到達) では fix.md 側で消去されず、その default-clear は iterate.md ステップ3 の clearing set (`flow-state.sh set --phase fix` を `--handoff` なしで実行) にのみ依存する。iterate.md ステップ3 の set を変更/削除すると stale な `/rite:fix` handoff が残存し誤った再注入を招きうるため、そちらを触る際は本依存に注意すること。

```bash
# 継続 ([fix:pushed] / [fix:pushed-wm-stale]: push 完了 OR 本 cycle accept 発生 & fatal フラグ無し) の場合 (継続 handoff):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上 after AskUserQuestion) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の Ready & 完結 step. Do NOT stop." \
  --handoff "/rite:pr-review {pr_number}" \
  --if-exists

# 正常終了 ([fix:replied-only]: push 無し & 本 cycle accept 発生なし & fatal フラグ無し) の場合 (FINALIZE 終了通知 handoff):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上 after AskUserQuestion) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の Ready & 完結 step. Do NOT stop." \
  --handoff "FINALIZE:fix:replied-only:{pr_number}" \
  --if-exists

# エラー ([fix:error]: fatal フラグ有り) の場合 (--handoff 行を省略 = handoff クリア):
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "fix" \
  --active true \
  --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上 after AskUserQuestion) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の Ready & 完結 step. Do NOT stop." \
  --if-exists
```

**Note on `error_count`**: `flow-state.sh set` は phase transition ごとに error_count を 0 にリセットする (`--preserve-error-count` 指定時のみ保持)。 <!-- rationale: references/design-rationale.md#output-pattern-notes -->

**Also update local work memory** (`.rite-work-memory/issue-{n}.md`) with phase transition:

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
      echo "  影響: local .rite-work-memory/issue-*.md が GitHub comment 側と一時的に不整合になる (E2E flow は続行)" >&2
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

**On lock failure**: Log a warning and continue — local work memory update is best-effort. **Non-lock failure** (script 不在 / permission denied / bash syntax error / 内部致命的エラー) は WARNING + stderr 5 行を表示してから継続する (E2E flow を block しない)。両者は stderr の exact phrase pattern `(file is locked|lock contention|resource busy)` で分岐される (H-1 で canonical helper に集約、詳細は [common-error-handling.md#hook-lock-contention-classification-canonical](../../references/common-error-handling.md#hook-lock-contention-classification-canonical) 参照)。

Then, based on the ステップ 4.6 completion report content **and the WM_UPDATE_FAILED context flag**, output the corresponding machine-readable pattern:

| 評価順 | Condition | Output Pattern |
|--------|-----------|---------------|
| 1 (最優先) | ステップ 1.0.1 / 1.2.0 / 1.2.0.1 で `[CONTEXT] FIX_FALLBACK_FAILED=1` を context に set した (`reason` の値は ステップ 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons table を **唯一の真実の源** として参照する。本セルでの固定列挙は drift 防止のため行わない) | `[fix:error]` (ステップ 1.0.1 / 1.2.0 / 1.2.0.1 のレビューソース解決失敗。fallback 経路が尽きたか、ユーザーが Interactive Fallback で中止を選んだか、ファイルパス指定の再実行でも有効なレビュー結果を取得できなかった状態のため caller は手動介入を促す) |
| 2 | ステップ 2.4 / 4.2 で `[CONTEXT] REPLY_POST_FAILED=1` / `[CONTEXT] REPORT_POST_FAILED=1` のいずれかを context に set した | `[fix:error]` (reply post / report post のいずれかが失敗。push 済みの可能性はあるが、レビュアー通知 / 完了報告の責務を果たせていないため caller は次の iteration ではなく手動介入を促す) |
| 3 | ステップ 4.5 (4.5.1 または 4.5.2) で `[CONTEXT] WM_UPDATE_FAILED=1` を context に set した (`reason` の値は下記 reason 表のいずれか — 固定列挙は行わず、reason 表を唯一の真実の源とする) | `[fix:pushed-wm-stale]` (ステップ 4.5 で work memory 更新が silent skip された旨を caller に明示伝達。caller は work memory が stale であることを認識して fix loop を再実行するか手動介入する) |
| 4 | (Push completed (`プッシュ: 完了`) または 本 cycle 内で accept 決定が発生 [`[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED=1` または `[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1` が 1 回以上 context に出現]) かつ work memory 更新成功 | `[fix:pushed]` |
| 5 | Push なし かつ 本 cycle 内で accept 決定なし (上記 2 マーカーがいずれも非出現) かつ All findings replied | `[fix:replied-only]` |
| 6 | Unexpected state / error | `[fix:error]` |

**評価順序の重要性**: 上から順に評価し、最初にマッチした条件の output pattern を採用する。`FIX_FALLBACK_FAILED=1` / `REPLY_POST_FAILED=1` / `REPORT_POST_FAILED=1` の検出は最優先で、これらが set された場合は `[fix:error]` に昇格する。次に `WM_UPDATE_FAILED=1` を評価し、set されていれば `[fix:pushed-wm-stale]` に昇格する (silent regression 防止のため `[fix:pushed]` よりも先に判定する)。これらの retained flag をすべて評価した後に push 成功 / 返信のみ などの通常終了状態を判定する。

**row 4/5 の accept 条件 — 唯一の真実の源 (Issue #1811)**: 本 output pattern テーブルは `/rite:iterate` ステップ4 が実際に分岐する **literal な sentinel 文字列** (`[fix:pushed]` / `[fix:replied-only]`) の唯一の決定箇所であり、上記の「Handoff マーカー」節 (5.1 冒頭) や ステップ 4.6 completion report の Note はここを**参照するのみ**で、条件を重複記述しない (bit-exact 手動同期に頼らない)。

「本 cycle 内で accept 決定が発生」の判定は `ACCEPT_FINGERPRINT_PERSISTED=1`（fingerprint 永続化成功）と `ACCEPT_FINGERPRINT_PERSIST_FAILED=1`（ステップ 2.1.A の `pr_number_placeholder_residue` / `sha1_helper_missing` / `mkdir_failed` / `mktemp_failed` / `mv_failed` いずれかの理由による永続化失敗）の**両方をトリガーとする**。理由: accept 選択時、reply 投稿 (ステップ 2.1.A item 3) は fingerprint 永続化 (item 4) の成否に関わらず既に完了しており、永続化に失敗した場合は次回 review で suppression が**確実に効かない** (`pr-review.md` ステップ 5.1.2.A の suppression は当該 fingerprint の状態ファイル登録に依存する)。ここで re-review を発火させなければ、suppression が絶対に効かないことが確定しているにもかかわらず `[fix:replied-only]` で正常終了してしまい、Issue #1811 がまさに解消しようとしていた「suppression 未確認のまま loop 終了」というバグ型をこの経路だけ再現する。

判定材料は両マーカー (ステップ 2.1.A が本 cycle 内で emit 済み、同一 Bash tool 呼び出し境界を跨いでも会話コンテキストに残る) の**本 cycle 内での出現有無**であり、`{accept_count}` (Issue 完了まで累計、4.6 completion report 参照) を使ってはならない — 過去 cycle の累計が 1 件でもあれば恒久的に継続扱いになり無限 re-review を招くため。いずれのマーカーも判定できない場合 (context 圧縮等で欠落) は accept 無しとして扱い、従来ロジック (push 有無のみ) にフォールバックする。

**`[CONTEXT] WM_UPDATE_FAILED=1` の検出方法** (Claude による retain と再注入):

ステップ 4.5.1 または ステップ 4.5.2 の bash block が stdout に `[CONTEXT] WM_UPDATE_FAILED=1; reason=...; ...` を出力した場合、Claude は会話履歴からこの行を検索し、検出された場合は本 phase の Output Pattern 評価で `[fix:pushed-wm-stale]` を採用する。検出されなかった場合は通常の評価順序 (WM_UPDATE_FAILED 以降の条件) に従う。

**`reason` フィールドの取りうる値** (ステップ 4.5.1 / 4.5.2 で発火する経路の網羅):

**完全性保証** — fix.md 内で `echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=..."` として emit されるすべての reason は、下記 reason 表に行として存在する (WM_UPDATE_FAILED reason ⊆ 表。表は他フラグの reason も併記する superset のため逆方向は保証しない)。DoD 検証スクリプト (手動実行、空出力 + rc=0 で網羅性を確認。設計上の要点は [design-rationale.md#output-pattern-notes](references/design-rationale.md#output-pattern-notes) 参照):

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
| `pr_body_tmp_empty_or_missing` | ステップ 4.5.1 | `cat <<PRBODY_EOF > pr_body_tmp` 後の `[ -s pr_body_tmp ]` 検査が失敗 (PR body が空 or write 失敗) |
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
| `wm_sync_history_failed` | ステップ 4.5.2 | `issue-comment-wm-sync.sh ... --transform append-section` (レビュー対応履歴) が no_comment 以外の skipped/error status を返した、または履歴 content-file の mktemp が失敗 |
| `cat_redirection_failed` | ステップ 2.4 / 4.2 / 4.5.x (heredoc redirection を使う任意箇所) | cat heredoc redirection の exit code が非ゼロ (disk full / write permission denied / IO error)。ステップ 4.5.1 / 4.5.2 の WM 更新経路など、heredoc を使う任意箇所で発火する可能性があるため、Phase 列は exhaustive な実 emit 箇所のリストではなく、典型的に発火する代表 phase の例示 |
| `empty_stdout` | ステップ 1.2 | gh api が exit 0 だが stdout が空または null |
| `missing_issue_url` | ステップ 1.2 | レスポンスに `.issue_url` フィールドが存在しない |
| `mktemp_failed_override_err` | ステップ 1.3 | confidence override stderr 退避用 tempfile の mktemp が失敗 |
| `mktemp_failed_reply_tmpfile` | ステップ 2.4 | reply body 用 tempfile の mktemp が失敗 |
| `mktemp_failed_report_tmpfile` | ステップ 4.2 | report body 用 tempfile の mktemp が失敗 |
| `paste_io_error` | ステップ 1.2 / 1.3 | printf / ファイル書き出しが IO エラーで失敗 |
| `pr_number_mismatch` | ステップ 1.2 | コメントの所属 PR と指定 pr_number が一致しない (silent misclassification) |
| `reply_tmpfile_empty` | ステップ 2.4 | reply body の tmpfile が cat 成功だが空 |
| `wc_io_error` | ステップ 1.3 | `wc -l` が IO エラーで失敗 |
| `raw_json_write_failed` | ステップ 1.2 Fast Path Block A | Block A の raw JSON 中間ファイル (`${TMPDIR:-/tmp}/rite-fix-raw-{pr}-{cid}.json`) への printf 書き出しが IO エラーで失敗 |
| `jq_author_extract_failed` | ステップ 1.2 Fast Path Block A | Block A の `jq -r '.user.login // empty'` が exit != 0 で失敗 (jq バイナリ異常 / OOM / parse error) |
| `raw_json_missing_at_block_b` | ステップ 1.2 Fast Path Block B | Block B 進入時に Block A の raw JSON 中間ファイルが存在しない or 空 (Block A 失敗 / 並列実行で削除 / orchestrator 異常終了で Block B 未到達) |
| `mktemp_failed_jq_block_b` | ステップ 1.2 Fast Path Block B | Block B の jq stderr 退避用 tempfile の mktemp が失敗 |
| `intermediate_missing_at_block_c` | ステップ 1.2 Fast Path Block C | Block C 進入時に Block A/B が作成したはずの intermediate ファイル (body/author/skip) または raw_json が存在しない or 空 |
| `intermediate_write_failed` | ステップ 1.2 Fast Path Block A | Block A の intermediate 3 ファイル (body/author/skip) への printf 書き出しが IO エラーで失敗 (disk full / read-only / inode 枯渇 / permission denied) |
| `author_file_missing_at_post_condition` | ステップ 1.2 Fast Path Block C | Block C の post-condition check で author_file が存在しない (`[ -f ]` 失敗、empty は許容) |
| `skip_file_empty_at_post_condition` | ステップ 1.2 Fast Path Block C | Block C の post-condition check で skip_file が空または存在しない (`[ -s ]` 失敗) |

**`[fix:pushed-wm-stale]` の caller 側 semantics**: caller の review-fix loop (`/rite:iterate` 等) は本 pattern を受け取った場合、push 自体は完了しているが work memory が stale であることを認識し、次のいずれかを実行する: (a) 手動介入を促す (推奨)、(b) 警告ログを出した上で次の iteration に進む (loop 継続)。silent に `[fix:pushed]` 扱いしてはならない。

**Important**:
- Do **NOT** invoke `rite:pr-review` via the Skill tool
- Return control to the caller (`/rite:iterate` 等)
- The caller determines the next action based on this output pattern
- **re-review は必ず `/rite:pr-review` を通すこと**: caller が `[fix:pushed]` / `[fix:pushed-wm-stale]` を受けて re-review を実行する際、レビュー範囲の決定は同 skill の ステップ 1.2.4 に委ね、**fix 側で範囲を宣言しない**（「前回指摘の修正確認のみ」「context 効率のため範囲限定」等を fix 側から指示するのは一切禁止）。ステップ 1.2.4 が決めた範囲を全レビュアーのサブエージェント並列起動で審査し、指摘の採否基準は初回と完全に同等に保つこと

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
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-acknowledged-nit-{pr_number}.txt"
```

> **Note (work memory backup)**: work memory body の backup (生成・成功時削除・失敗時 preserve) は `issue-comment-wm-sync.sh` が内部で完結させる (helper の Step 3/6 参照)。本コマンドの caller 側では backup を生成・cleanup しないため、ステップ 5.1 の output pattern に応じた手動 backup cleanup も行わない。

**Example output:**
```
PR #123 のレビュー指摘対応を完了しました

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

Standalone 実行では ステップ 5 が skip されるため、ステップ 4.6 の completion report 出力**直後**に明示的な cleanup bash block を実行して confidence_override tempfile を削除する。これを忘れると `${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt` が orphan として永続残留し、次回同 PR 実行時に `touch` ではなく `: >` truncate を入れていても、何らかの経路で truncate 呼び出しが skip された場合に stale データが混入するリスクがある (defense-in-depth)。

```bash
# ステップ 5.2 Standalone 経路: confidence_override + pr-comment + acknowledged-nit tempfile の明示的 cleanup
# 実行タイミング: ステップ 4.6 の completion report を表示した直後
# {pr_number} は Claude が ステップ 1.0 の parse 結果で事前置換済み
# pr-comment tempfile + acknowledged-nit tempfile も追加
rm -f "${TMPDIR:-/tmp}/rite-fix-confidence-override-{pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-acknowledged-nit-{pr_number}.txt"
```

**Idempotency**: override tempfile が作成されなかった経路 (confidence override 発動なし) では `rm -f` は silent no-op となり安全。
