---
description: レビュー指摘への対応を支援
context: fork
---

# /rite:pr:fix

## Contract
**Input**: PR number, review findings from `/rite:pr:review`, `.rite-flow-state` with `phase: phase5_fix` (e2e flow)
**Output**: `[fix:pushed]` | `[fix:issues-created:{n}]` | `[fix:replied-only]` | `[fix:error]`

Retrieve and organize PR review comments to efficiently assist with addressing review feedback

## E2E Output Minimization

When called from the `/rite:issue:start` end-to-end flow, minimize output to reduce context window consumption:

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Fix implementation | Full output | Full output (needed for code changes) |
| Phase 7 (Completion) | Full report | Result pattern + 1-line summary only |
| Phase 8 (Work Memory) | Full update | Full update (no change) |

**E2E output format** (Phase 7, replaces full report):
```
[fix:{result}] — {fixed_count} fixed, {skipped_count} skipped, {files_changed} files changed
```

**Detection**: Reuse Phase 0.1 end-to-end flow determination.

---

Execute the following phases in order when this command is run.

**⚠️ Integration with `/rite:issue:start`:**

This command is automatically invoked within the review-fix loop of `/rite:issue:start` when the evaluation results in "not mergeable (issues found)" or "needs fixes". **All findings are targeted for fixes** regardless of severity or loop count. After completion, this command outputs a machine-readable output pattern and **returns control to the caller** (`/rite:issue:start`).

## Arguments

| Argument | Description |
|----------|-------------|
| `[pr_number]` | PR number (defaults to the PR for the current branch if omitted) |
| `[pr_url]` | PR URL (`https://github.com/{owner}/{repo}/pull/{N}`) |
| `[comment_url]` | PR comment URL (`https://github.com/{owner}/{repo}/pull/{N}#issuecomment-{ID}`) |

**Accepted formats**: すべての引数形式は Phase 1.0 (Argument Parsing Pre-flight) で正規化され、`{pr_number}` と（該当時のみ）`{target_comment_id}` が抽出される。`comment_url` を指定すると、その特定コメントから直接 findings をパースする（Phase 1.2 で分岐）。`pr_number` 単体または引数なしの既存挙動は完全に維持される。

---

## Phase 0: Load Work Memory (During End-to-End Flow)

When executed within the end-to-end flow, load required information from work memory (shared memory).

### 0.1 Determine End-to-End Flow

Determine the caller from the conversation context:

| Condition | Determination | Action |
|-----------|---------------|--------|
| Conversation history contains rich context from `/rite:pr:review` | Within end-to-end flow (review-fix loop) | PR number can be obtained from conversation context |
| `/rite:pr:fix` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

### 0.2 Load Work Memory

Extract the Issue number from the current branch and retrieve work memory:

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')

# リポジトリ情報を取得（1回で owner と repo を両方取得）
# 注: echo ... | jq -r はスタンドアロン jq コマンドに依存（GitHub CLI の --jq オプションとは別）
owner_repo=$(gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}')
owner=$(echo "$owner_repo" | jq -r '.owner')
repo=$(echo "$owner_repo" | jq -r '.repo')

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

## Phase 1: Retrieve and Organize Review Comments

### 1.0 Argument Parsing (Pre-flight)

> **Execution order**: 本サブフェーズは Phase 1.1 の `gh pr view` 呼び出しよりも**必ず先に**実行される。番号 `1.0` は Phase 1 の冒頭 (1.1 より先) を示しており、自然順で読み進める AI/人間どちらも順序通りに実行できる。

**Always run this sub-phase**. Phase 1.1 が `gh pr view` を実行する前に、引数形式を正規化して `{pr_number}` と（該当時のみ）`{target_comment_id}` を抽出する。bare integer (`^[0-9]+$`) や引数なしの場合でも本サブフェーズを実行し、Detection rules table の順序 1 / 順序 5 で pr_number を抽出した上で **`{target_comment_id} = null` を explicit set** する (undefined 参照防止)。

> **Why this ordering matters**: If you pass a PR URL or comment URL directly to `gh pr view {pr_number}`, the command will fail and Phase 1.1 will terminate with "PR not found". The Fast Path in Phase 1.2 cannot be reached. Always normalize first.

**Detection rules** (順序ベース判定 — bash POSIX ERE は negative lookahead 非対応のため、より特殊なパターンを先に試して fallthrough する):

| 順序 | Format | Regex (POSIX ERE 互換、lookaround なし) | Extracted |
|------|--------|------------------------------------------|-----------|
| 1 | 数字のみ (ASCII / 全角) | `^[0-9０-９]+$` | `pr_number` (全角数字は半角に正規化してから as-is 保持) |
| 2 | Comment URL (query string 任意) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)#issuecomment-([0-9]+)(\?.*)?$` | `pr_number` = group 1, `target_comment_id` = group 2 (末尾の `?notification_referrer_id=...` 等の query string は受け入れて無視) |
| 3 | PR URL (trailing slash あり/なし) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)/?$` | `pr_number` = group 1 |
| 4 | PR URL (trailing fragment、issuecomment 以外) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)#.*$` | `pr_number` = group 1 (順序 2 が先にマッチするため、ここに到達するのは `#discussion_r123` 等の非 issuecomment fragment のみ) |
| 5 | 引数なし | — | 既存ロジック (current branch から PR 検出) |

**重要 — bash 互換性**: 順序 4 の regex は **negative lookahead `(?!issuecomment-)` を使わない**。これは bash の `[[ =~ ]]` (POSIX ERE) や `grep -E` が POSIX BRE/ERE であり、lookaround 系の構文を一切サポートしないため (権威ある仕様根拠: [IEEE Std 1003.1 / The Open Group Chapter 9 — Regular Expressions](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html) と [regular-expressions.info: Lookahead and Lookbehind](https://www.regular-expressions.info/lookaround.html) で確認済み)。順序 2 を順序 4 より先に試すことで、issuecomment URL は順序 2 で先にマッチして抽出され、順序 4 に到達する時点で「issuecomment ではない fragment 付き PR URL」のみが残る。順序を保証することで lookaround 不要となる。

**全角数字の扱い** (順序 1): 日本語 IME の fullwidth モードで入力された `１２３` のような全角数字をユーザーが誤って投入するケースを救済する。マッチした場合は `tr '０-９' '0-9'` 相当の変換で半角に正規化してから `{pr_number}` として保持する。ASCII 数字のみの場合は変換せずそのまま使用。

**Behavior**:

1. 数字または引数なし → `{target_comment_id} = null`。Phase 1.2 は既存ロジックで最新の `📜 rite レビュー結果` コメントを対象とする (既存挙動と完全互換)
2. PR URL → `{target_comment_id} = null`。Phase 1.1 で `gh pr view {pr_number}` を実行し、Phase 1.2 は既存ロジック
3. Comment URL → `{target_comment_id}` を設定。Phase 1.1 で `gh pr view {pr_number}` を実行し、Phase 1.2 の target_comment_id 分岐で対象コメントを直接取得する

**Parsing failure**: いずれのパターンにもマッチしない場合、以下の手順で**機械的に処理を終了**する (silent fall-through 禁止):

1. **エラーメッセージを stderr に出力**:
   ```
   エラー: 引数の形式を認識できませんでした
   入力: {argument}
   受け付け可能な形式:
     - PR 番号（例: 123、全角 １２３ も可）
     - PR URL（例: https://github.com/owner/repo/pull/123）
     - PR コメント URL（例: https://github.com/owner/repo/pull/123#issuecomment-4567890、末尾の ?notification_referrer_id=... は自動的に無視）
   ヒント: もし Issue URL (/issues/123) を渡している場合、/rite:pr:fix は PR 専用です。Issue 対応は /rite:issue:start を使用してください。
   ```
2. **Context 変数を explicit set** (undefined 参照防止):
   - `{pr_number} = null`
   - `{target_comment_id} = null`
3. **`[fix:error]` output pattern を stdout に出力** し、**Phase 1.1 以降のすべてのサブフェーズを実行せずにコマンド全体を終了する**
4. **重要**: ここでの「Terminate processing」は Phase 1.1 への進入禁止を意味する。「Phase 1.0 で parse 失敗したから Phase 1.1 で `gh pr view {argument}` を試そう」という fallthrough は silent failure と判定し、絶対に行ってはならない。引数が未知の形式である以上、Phase 1.1 の `gh` コマンドに渡しても確実に失敗し、かつ同番号の別 Issue を誤認する危険がある

**Compatibility**: 既存の `pr_number` 単体挙動および引数なし挙動は一切変更されない。本 Phase は引数形式の判定のみを行い、Phase 1.1/1.2 の既存ロジックにはフラグ (`{target_comment_id}` の有無) を渡すだけである。

### 1.1 Identify the PR

After Phase 1.0 has extracted `{pr_number}` (and optionally `{target_comment_id}`), retrieve repository information:

- **Within end-to-end flow**: `{owner}` and `{repo}` are already available from Phase 0.2. Reuse them — no additional `gh repo view` call needed.
- **Standalone execution**: Phase 0 was not executed. Retrieve them here:

```bash
# Phase 0.2 と同一パターン（スタンドアロン実行時のみ使用。e2e フローでは Phase 0.2 の値を再利用）
owner_repo=$(gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}')
owner=$(echo "$owner_repo" | jq -r '.owner')
repo=$(echo "$owner_repo" | jq -r '.repo')
```

When PR number is specified as an argument:

```bash
gh pr view {pr_number} --json number,title,state,isDraft,headRefName,baseRefName,url,body
```

When argument is omitted, identify the PR from the current branch:

```bash
git branch --show-current
gh pr view --json number,title,state,isDraft,headRefName,baseRefName,url,body
```

**When PR is not found:**

```
エラー: 現在のブランチに関連する PR が見つかりません

現在のブランチ: {branch}

対処:
1. `/rite:pr:create` で PR を作成
2. PR 番号を直接指定して再実行
```

Terminate processing.

**When PR is closed or already merged:**

```
エラー: PR #{number} は既に{state}されています

レビュー指摘への対応は実行できません。
```

Terminate processing.

### 1.2 Retrieve Review Comments

**Branch by `{target_comment_id}`** (set in Phase 1.0): Phase 1.2 has two execution paths depending on whether a comment URL was passed. The sub-sections below (Target Comment Fast Path / Broad Comment Retrieval) are **h4-level branches within Phase 1.2** and are independent execution paths — they are **not** numbered sub-phases of Phase 1.2.1. The existing `### 1.2.1 Retrieve rite Review Results` is a separate, h3-level sub-phase that runs only when the Broad Comment Retrieval path is taken (i.e. when `{target_comment_id}` is NOT set).

#### Target Comment Fast Path — when `{target_comment_id}` is set

When `{target_comment_id}` has been extracted from a comment URL argument, retrieve that specific comment directly and skip the broad comment retrieval below:

> **Implementation note for Claude**:
>
> **本コードブロック単体**を単一の Bash ツール呼び出しで実行する。`$target_body`, `$target_author`, `$jq_err` はシェル変数であり、ブロック内で完結する。後続の Parsing rule (`## 📜 rite レビュー結果` 判定や best-effort parse) は自然言語指示と `AskUserQuestion` を含むため bash のみでは実行不可能であり、**同じ Bash 呼び出しで連続実行しない**。代わりに以下のハンドオフ方式を使う:
>
> 1. bash block 末尾で以下の **3 つ**のシェル変数を Claude 可読な一時ファイルに永続化する (ファイル名はセッション固有の `{pr_number}-{target_comment_id}` suffix 付き):
>    - `$target_body` → `/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt`
>    - `$target_author` → `/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt`
>    - `$target_author_mention_skip` → `/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt`
>
>    書き出しは **各 `printf` の exit code を check し、失敗時は exit 1 で abort** する (上記 bash block 内の実装を参照)。さらに書き出し後に `[ -s "<path>" ]` / `[ -f "<path>" ]` で post-condition を検証する。
> 2. bash 呼び出しから戻ったあと、Claude は Parsing rule を実行するために Read tool で上記 **3 ファイル**を読み直し、必要に応じて `$target_body` / `$target_author` / `$target_author_mention_skip` の中身をコンテキストに再注入する
> 3. Parsing rule / best-effort parse が完了したあと、Phase 1 の末尾で下記の **明示的 cleanup bash block** を**必ず実行**する (prose 指示ではなく実装ブロックとして存在する)。削除対象は specific path (`{pr_number}-{target_comment_id}` suffix 付き) のみとし、wildcard glob は**絶対に使わない** (並列 fix 実行時に他セッションの一時ファイルを silent に消す事故を防ぐ):
>    ```bash
>    # Phase 1 終端で実行する cleanup (Phase 1.4 末尾または Phase 2 遷移直前)
>    # 重要: wildcard `/tmp/rite-fix-target-body-*.txt` は絶対に使わない (他セッション破壊防止)
>    rm -f "/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
>          "/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
>          "/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt"
>    ```
>    Broad Comment Retrieval 経路 (Fast Path を通らない場合) ではこれらの一時ファイルが存在しないため、`rm -f` は silent no-op となり問題ない。
>
> **trap の上書きリスクに注意**: 本ブロックの `trap 'rm -f "$jq_err"' EXIT` は bash 仕様上 1 signal につき 1 trap しか持てないため、**後続の bash block (Phase 2.4 reply、Phase 4.2 report、Phase 4.3.4 Issue 作成、Phase 4.5.1 work memory 更新) が同一 bash 呼び出しに含まれる場合、それらの `trap ... EXIT` に上書きされて `$jq_err` のリークが起きる**。これは本ブロックを後続 phase と結合しないことで回避するほか、ブロック末尾で明示的に `rm -f "$jq_err"` を実行することで二重防御している (trap が動かなくても cleanup は完了する)。将来 `trap` を連携する必要が出た場合は `add_trap` idiom (`existing=$(trap -p EXIT | sed -n "s/.*'\(.*\)'.*/\1/p"); trap "rm -f \"$jq_err\"; $existing" EXIT`) の採用を検討。

```bash
# 対象コメントを直接取得
# gh api は 404 や認証エラー時に exit != 0 を返すため、exit code を直接チェックする
# (空文字列チェックではエラーを見逃す可能性がある)
#
# 注: stderr は gh api から直接呼び出し元へ流れる (2>&1 で stdout に混入させない)。
#     もし 2>&1 を付けると、成功時に gh が stderr に警告を出した場合
#     $target_comment が invalid JSON となり直後の jq が失敗する (Issue #349 Cycle 2 MEDIUM #20)
if ! target_comment=$(gh api repos/{owner}/{repo}/issues/comments/{target_comment_id}); then
  # gh api の stderr は既に呼び出し元に出力されている (上記 exec 時に直接流れる)
  echo "エラー: コメント #{target_comment_id} の取得に失敗しました" >&2
  echo "対処: コメント URL が正しいか、削除されていないかを確認してください" >&2
  exit 1
fi

# 空 stdout チェック (gh api が exit 0 でも空文字列を返すコーナーケース)
if [ -z "$target_comment" ] || [ "$target_comment" = "null" ]; then
  echo "エラー: コメント #{target_comment_id} の取得結果が空です (gh api exit 0 だが本文なし)" >&2
  echo "対処: コメント ID と権限を確認してください" >&2
  exit 1
fi

# jq 実行を明示的にエラーチェック (parse error, jq バイナリ不在等を捕捉)
# stderr を mktemp 経由の一時ファイルに逃がすことで、成功時の警告 (deprecation 等) が
# stdout に混入して $target_body を汚染することを防ぐ。失敗時のみ stderr ファイルを表示する。
jq_err=$(mktemp /tmp/rite-fix-jq-err-XXXXXX) || {
  echo "エラー: jq エラー一時ファイルの作成に失敗しました" >&2
  exit 1
}

# Fast Path ハンドオフ一時ファイルのパスを先に定義し、trap 対象に含める
# (書き出し前に変数を declare しておくことで、trap が早期 exit でも cleanup できる)
body_file="/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt"
author_file="/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt"
skip_file="/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt"

# 統合 trap: jq_err は常に削除、ハンドオフ 3 ファイルは「Fast Path 完了 = handoff_committed=1」
# 時のみ保護 (trap 内で条件分岐)。これにより:
#   - 書き出し前/書き出し中の exit 1 → 4 ファイル全削除 (orphan 防止)
#   - 全書き出し成功+post-condition pass 後 → handoff 3 ファイルは保護、jq_err のみ削除
#   - Phase 1.5 で明示的に cleanup を実行 (Fast Path 完了経路の正常 cleanup 経路)
#
# trap 対象シグナル: EXIT INT TERM HUP の 4 種類すべて
# - EXIT: 正常終了 / exit 1 等の意図的終了
# - INT: Ctrl+C 等の interrupt (非対話モードでも `kill -INT` で発火)
# - TERM: 外部からの `kill -TERM` (Claude Code Bash tool timeout / sprint team-execute の親プロセス kill 等)
# - HUP: 端末切断 / SIGHUP (hook timeout, セッション終了)
# bash の EXIT trap は SIGTERM を捕捉しないため、INT/TERM/HUP を明示的に追加する必要がある
handoff_committed=0
trap 'rc=$?; rm -f "$jq_err"; if [ "$handoff_committed" = "0" ]; then rm -f "$body_file" "$author_file" "$skip_file"; fi; exit $rc' EXIT INT TERM HUP

if ! target_body=$(printf '%s' "$target_comment" | jq -r '.body // empty' 2>"$jq_err"); then
  echo "エラー: gh api レスポンスの JSON パースに失敗しました (.body 抽出)" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  exit 1
fi
if [ -z "$target_body" ]; then
  echo "エラー: コメント #{target_comment_id} の body が空です" >&2
  exit 1
fi

# author も同じ pattern で抽出 (fail-fast: .body が成功した状況で .user.login が失敗するのは
# jq バイナリ異常または破損した JSON レスポンスの兆候なので、警告して exit するほうが安全)
if ! target_author=$(printf '%s' "$target_comment" | jq -r '.user.login // empty' 2>"$jq_err"); then
  echo "エラー: コメント #{target_comment_id} の author 抽出に失敗しました" >&2
  echo "詳細: $(cat "$jq_err")" >&2
  echo "対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  rm -f "$jq_err"
  exit 1
fi

# .user.login が empty (GitHub Apps bot / 削除済みユーザー等のコーナーケース) の場合、
# 空文字を保持して下流に mention 省略フラグとして伝達する (sentinel "unknown" は誤 mention の原因)
# 下流 phase では `{target_author_mention_skip} == "true"` を参照して mention を生成しない
target_author_mention_skip="false"
if [ -z "$target_author" ]; then
  target_author=""
  target_author_mention_skip="true"
  echo "WARNING: コメント #{target_comment_id} の .user.login が空です。" >&2
  echo "  下流 phase の mention 生成は target_author_mention_skip=true を参照して省略されます。" >&2
fi

# Parsing rule / 下流 phase へのハンドオフ (シェル変数は bash 呼び出しを抜けると失われるため、
# Claude 可読な一時ファイルに永続化する。後続 phase は Read tool でこれらを読み戻す)
#
# 重要 — 書き出しエラーは fail-fast で exit 1:
# disk full / /tmp read-only (Docker RO volume, SELinux/AppArmor deny) / inode 枯渇のケースで
# silent に空ファイルを残すと、後続 phase が空の target_body を Read して 0 件 finding で
# silent pass する事故になる。各 printf の exit code を明示的に check し、失敗時は詳細を stderr に出力する。
# 注: body_file / author_file / skip_file は trap セットアップ時に既に定義済み (trap 対象)
if ! printf '%s' "$target_body" > "$body_file"; then
  echo "エラー: target_body の一時ファイル書き出しに失敗しました: $body_file" >&2
  echo "対処: disk full / /tmp が read-only / inode 枯渇 / permission 拒否のいずれかを確認してください" >&2
  # exit 時に統合 trap が handoff_committed=0 のまま発火 → 書き出し済み body_file (もしあれば) も削除される
  exit 1
fi
if ! printf '%s' "$target_author" > "$author_file"; then
  echo "エラー: target_author の一時ファイル書き出しに失敗しました: $author_file" >&2
  exit 1
fi
if ! printf '%s' "$target_author_mention_skip" > "$skip_file"; then
  echo "エラー: target_author_mention_skip の一時ファイル書き出しに失敗しました: $skip_file" >&2
  exit 1
fi

# 書き出し後の post-condition check (non-empty かつ存在することを確認)
# target_author は空文字列でも許容 (target_author_mention_skip=true の sentinel として使う)
# target_author_mention_skip は必ず "true" or "false" の文字列なので必ず non-empty
if [ ! -s "$body_file" ]; then
  echo "エラー: body_file の post-condition check に失敗: $body_file が空または存在しません" >&2
  exit 1
fi
if [ ! -f "$author_file" ]; then
  echo "エラー: author_file の post-condition check に失敗: $author_file が存在しません" >&2
  exit 1
fi
if [ ! -s "$skip_file" ]; then
  echo "エラー: skip_file の post-condition check に失敗: $skip_file が空または存在しません" >&2
  exit 1
fi

# Fast Path 完了: ハンドオフ 3 ファイルを trap の cleanup 対象から外す (handoff_committed=1)
# これ以降、bash block 末尾に到達するか後続 phase でエラーが起きても、ハンドオフファイルは保護される
# 後続 phase の cleanup (Phase 1.5 / Fast Path Cancel exit / Step C error exit) で明示的に削除する
handoff_committed=1
```

> **Note — 下流 phase でのハンドオフ参照**: Fast Path 完了後、Claude は以下 **3 つ**の一時ファイルを Read tool で読み戻してコンテキストに再注入する:
>
> - `/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt` — Parsing rule で参照する finding 本文
> - `/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt` — Phase 2.1 / 3.2 / 4.3.4 で `{target_author}` として参照
> - `/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt` — `"true"` / `"false"` の文字列。下流 phase で mention を生成する前に必ずチェックする
>
> **下流 phase の mention 省略義務** (silent `@unknown` 誤記録の防止): Fast Path 経由で単一コメントを対象にしている場合、Phase 1.2 best-effort parse failure 警告、Phase 2.1 の `レビュアー` 表示、Phase 3.2 commit trailer の `Addresses review comments from` / `のレビューコメントに対応`、Phase 4.3.4 Issue 本文の `- **レビュアー**` のいずれにおいても、`target_author_mention_skip == "true"` の場合は mention (`@` prefix) を生成せず、代わりに以下の文字列を使用する:
>
> - 日本語出力: `(不明なレビュアー)` (コメント投稿者が特定できないため mention を省略)
> - 英語出力: `(unknown reviewer)` (mention omitted because the comment author could not be resolved)
>
> これにより GitHub 上に存在しない `@unknown` user への誤 mention を防ぐ。`jq_err` の cleanup は EXIT trap + 末尾の明示的 `rm -f` で二重防御されているため、異常終了・正常終了のいずれでも確実に削除される。ハンドオフ 3 ファイル (`body`, `author`, `author-skip`) は **Phase 1.4 末尾の明示的 cleanup bash block** (specific path 指定、wildcard glob は使用禁止) で削除する — 詳細は上記 Implementation note の手順 3 を参照。並列 fix 実行時の他セッション破壊を防ぐため `rm -f /tmp/rite-fix-target-body-*.txt` のような glob は絶対に使わない。

**Parsing rule**:

1. If `$target_body` contains `## 📜 rite レビュー結果`: **Phase 1.2.1 で定義された table パースロジック** (`### 全指摘事項` を起点に reviewer サブセクションごとの table を解析し `severity_map` を構築する手順) を `$target_body` に対して適用する。**Phase 1.2.1 のコメント取得処理 (broad retrieval) は実行しない** — 対象コメントは既に取得済みのため
2. Otherwise (外部ツール: `/verified-review` skill、`pr-review-toolkit:review-pr` plugin、手動コメント等): **best-effort parse**
   - **期待スキーマ**: 最低 **4 カラム** を持つ markdown table (`| severity | file:line | content | recommendation |` の順、またはヘッダー行から列順を推定)
   - **ヘッダー行検出 (正規キーワードセット)**: 表の 1 行目に以下のキーワードのいずれかを含む行を検出した場合、その列順を使用する。検出成否は必ずログに記録する:

     | 列名 | 認識キーワード (大文字小文字無視) |
     |------|-----------------------------------|
     | severity | `severity`, `重要度`, `sev`, `level`, `深刻度`, `priority` |
     | file:line | `file`, `ファイル`, `path`, `location`, `場所` |
     | content | `content`, `内容`, `message`, `description`, `指摘`, `issue` |
     | recommendation | `recommendation`, `推奨`, `fix`, `suggestion`, `対応`, `action` |

     **検出ログ**: 以下を **stderr に必ず出力** する。E2E Output Minimization の対象外とし、parse の健全性を後追いできるようにする:
     - ヘッダー検出成功: `Header detected: yes. Column order: [severity, file, content, recommendation]`
     - ヘッダー検出失敗: `Header detected: no. Using default column order [severity, file, content, recommendation]`
   - **ヘッダー行なし**: デフォルト列順 `severity | file:line | content | recommendation` を仮定する (上記の `Header detected: no` ログを stderr に必ず出力する)
   - **カラム数不足の扱い**:
     - **3 カラム以下**: そのテーブル行を "unparseable" として skip し、警告ログ (`WARNING: Skipping unparseable row (columns < 4): <row preview>`) に記録する
     - **4 カラム以上**: 最初の 4 カラムを severity / file:line / content / recommendation として抽出 (余分な列は無視)
   - **severity 別名マッピング**: CRITICAL/HIGH/MEDIUM/LOW 以外の値が出現した場合、以下の別名マッピングを試行する:

     | 認識される別名 | 正規化先 |
     |---------------|---------|
     | `BLOCKER`, `CRIT`, `🔴`, `重大`, `致命` | `CRITICAL` |
     | `MAJOR`, `HIGH`, `🟠`, `重要`, `高` | `HIGH` |
     | `MINOR`, `🟡`, `中`, `Normal` | `MEDIUM` |
     | `INFO`, `TRIVIAL`, `🔵`, `低`, `情報` | `LOW` |

     > **Note — 絵文字エイリアスの実運用検証状況**: 絵文字 (`🔴`/`🟠`/`🟡`/`🔵`) は将来の互換性のため列挙していますが、現時点で `/verified-review` skill (rite plugin 標準) は CRITICAL/HIGH/MEDIUM/LOW を plain text で出力します。絵文字を出力する具体的な外部レビューツールは未検証です。新しい外部レビューツールへの対応として絵文字エイリアスを追加した場合は、本 Note にツール名を追記してください。

     - 上記のいずれにもマッチしない場合、`MEDIUM` をデフォルトとし、**認識不能な severity 値の一覧をユーザーに必ず警告表示する** (silent fallback 禁止):
       ```
       警告: 認識不能な severity 値が {N} 件あります
       - 値: ['{val_1}', '{val_2}', ...]
       - すべて MEDIUM として扱いますが、適切な対応のため手動で再分類してください
       - 認識可能な severity: CRITICAL / HIGH / MEDIUM / LOW (または上記の別名)
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

     **`{reviewer_display}` の展開**: Phase 2.1 の `{reviewer_display}` 展開ルール表を参照する。Fast Path 経由で `target_author_mention_skip == "true"` の場合は `(不明なレビュアー)` / `(unknown reviewer)` に置換し、`@` prefix は絶対に生成しない (silent `@unknown` 誤記録防止)。通常時は `@{target_author}` を使用する。

   **選択肢の処理ルール (silent fall-through 禁止)**:

   | ユーザー応答 | 処理 |
   |-------------|------|
   | **手動で finding を入力** | Phase 1.4 (Display Comment List) で finding 手動入力モードに移行 (入力スキーマ: `severity \| file:line \| content \| recommendation` のテーブル) |
   | **別のコメント URL を指定** | **Fast Path ハンドオフ一時ファイルを cleanup してから** Phase 1.0 から再実行 (新しい argument を要求)。詳細は下記「Cancel/Re-run 経路でのハンドオフ cleanup 義務」参照 |
   | **キャンセル** | **Fast Path ハンドオフ一時ファイルを cleanup してから** `[fix:cancelled-by-user]` を出力して exit 0 |

   **Cancel/Re-run 経路でのハンドオフ cleanup 義務** (silent orphan ファイル防止):

   `[fix:cancelled-by-user]` exit 0 / `[fix:error]` exit 1 / Phase 1.0 再実行のいずれかへ進む直前に、Fast Path で作成した 3 ファイルを **明示的に削除する** bash 呼び出しを必ず実行する。これは Phase 1.5 cleanup を経由しないすべての終了経路における defense-in-depth であり、Phase 1.4 末尾の Phase 1.5 cleanup から到達しない経路をカバーする:

   ```bash
   # Cancel / Re-run / Step C error 共通: ハンドオフ 3 ファイルを削除してから exit する
   # Fast Path bash block 外なので body_file / author_file / skip_file 変数は失われている
   # → specific path で直接削除する (wildcard glob は並列セッション破壊のため絶対禁止)
   rm -f "/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt"
   ```

   この cleanup を実行する 3 つの経路:
   - Cancel 選択 → cleanup → `[fix:cancelled-by-user]` 出力 → exit 0
   - Re-run 選択 → cleanup → Phase 1.0 から新しい引数で再実行
   - Step C 「2 回目も解釈不能」→ cleanup → `[fix:error]` 出力 → exit 1

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

   **優先順位の変更理由**: 従来「キャンセルを最優先に置くことで安全側に倒す」という設計だったが、これはユーザーが明示的に「キャンセルせず〜」と述べた場合にも機械的にキャンセル側に倒してしまい、**ユーザー意図の逆転**を silent に引き起こす問題があった。上記の打ち消し集合による前処理を経た上で、option 2 (手動入力) と option 3 (別 URL) を入れ替えることで、否定形応答の正しい解釈と曖昧応答の再質問を両立させる。

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
   2. **再質問の応答も解釈不能の場合**: 上記「Cancel/Re-run 経路でのハンドオフ cleanup 義務」の bash block を実行して Fast Path 一時ファイル 3 本を削除してから、`[fix:error]` を出力して exit 1 (**parse 0 件のまま Phase 2 進入は禁止**)。エラーメッセージに「解釈不能な応答が 2 回続いたため処理を中止しました。fix loop を手動で再実行してください」を含める

   > **「無応答」について**: Claude Code の対話モデルでは「無応答」状態は通常発生しない (応答を待つ間ブロックされる) ため、上記から削除した。タイムアウト等で無応答が発生した場合は AskUserQuestion 自体のエラーとして扱われ、本ループには到達しない。

   **重要**: parse 0 件で Phase 2 (Categorization) に進入することは silent failure として禁止する。必ず上記の選択肢のいずれかを処理した上で次の Phase へ進むこと。
3. `{target_comment_id}` 経由で取得した finding のみを fix ループの対象とする。Phase 1.2 の「全コメント取得」はスキップされる

**外部ツール由来 finding の Confidence ゲート** (`feedback_review_zero_findings` / `feedback_review_quality.md` 準拠):

外部ツール (`/verified-review`, `pr-review-toolkit:review-pr`, 手動コメント等) のコメントは `📜 rite レビュー結果` と異なり、Confidence 列を持たない形式が多い。そのまま fix ループに投入すると hallucinated finding (Confidence < 80 相当) が修正対象になり、rite の「Confidence 80+ のみ取り込み」原則を破る。

**取り扱いルール**:

| 状況 | 処理 |
|------|------|
| テーブルに Confidence 列が存在し数値がある | そのまま Confidence として採用 (`< 80` は警告表示の上でスキップ、`>= 80` のみ取り込み) |
| Confidence 列がない、または数値が欠落 | **暫定値 Confidence=70 (< 80) を割り当て**、LOW に降格し、以下の警告を **stderr に必ず出力** する (silent pass 禁止): `WARNING: 外部ツール由来 finding {N} 件に Confidence 記載なし。暫定的に LOW/Confidence=70 として扱います。取り込み前にユーザー確認を求めます。` |
| severity 別名マッピングによる MEDIUM fallback (severity 不明) | 同様に Confidence=70 扱いとし、ユーザー確認を求める |

暫定 Confidence 値が割り当てられた finding については、`AskUserQuestion` で以下のいずれかを選択させる:
- **Confidence 70 のまま 80+ ゲートをバイパスして投入 (policy override)** — finding を fix ループに投入するが、Confidence は 70 のまま保持し、`confidence_override=true` フラグを finding metadata に記録する。昇格ではなくバイパスであることをユーザーに明示する
- **LOW として記録のみ** — fix ループには投入せず、後日レビュー対象として残す
- **スキップ** — Phase 4.3 で別 Issue 化する候補として扱う

**Confidence override の追跡義務** (silent 改竄防止): 「Confidence 70 のままバイパス」を選択した finding については、以下の出力箇所で明示的に可視化する:
- Phase 4.6 完了報告に `confidence_override: N 件` を追加
- Phase 4.5.3 work memory のレビュー対応履歴に `- confidence_override: {file:line} (外部ツール由来、ユーザーがバイパスを承認)` を記録
- Phase 4.3 で別 Issue 化される finding にも `confidence_override=true` の事実を Issue 本文に記載

**Retained context flags** (Phase 4.5.3 / 4.6 / 4.3.4 の placeholder 展開時に Read tool で会話履歴から読み戻す変数):

| Flag | 型 | 初期値 | 更新タイミング |
|------|---|--------|---------------|
| `confidence_override_count` | int | `0` | best-effort parse で 1 件の override が確定するたびに `+1` |
| `confidence_override_findings` | list[str] (`"file:line"` の配列) | `[]` | 同上、override が確定するたびに `append("{file}:{line}")` |

**Claude による retain と再注入の手順** (data flow の具体化):

1. Phase 1.2 best-effort parse で最初の override 候補が出現した時点で、上記 2 flag を会話コンテキストに明示宣言する (例: `[CONTEXT] confidence_override_count = 0; confidence_override_findings = []`)
2. AskUserQuestion で「Confidence 70 のままバイパス」が選択されるたびに、count を +1 し、findings に file:line を append。更新後の値も会話コンテキストに明示する (例: `[CONTEXT] confidence_override_count = 2; confidence_override_findings = ["src/foo.ts:42", "src/bar.ts:18"]`)
3. Phase 4.6 / 4.5.3 / 4.3.4 の placeholder 展開時、Claude は最新の `[CONTEXT]` 行を会話履歴から検索して値を読み戻す
4. fix ループ中に他のフェーズから上記 flag を変更しない (immutable な追加のみ)

**Phase 4.6 / 4.5.3 / 4.3.4 で参照する placeholder 一覧**:

| Phase | placeholder | 展開ルール |
|-------|-------------|----------|
| 4.6 (完了報告) | `{confidence_override_count}` | `confidence_override_count` の値をそのまま展開 (0 含む) |
| 4.6 (完了報告) | `{confidence_override_files_suffix}` | `confidence_override_count == 0` なら空文字列、`>= 1` なら ` (file_a.ts:10; file_b.ts:42; ...)` (先頭スペース付きカッコ + 配列を `; ` 区切り) |
| 4.5.3 (work memory) | `{confidence_override_section}` | `confidence_override_count == 0` なら `なし`、`>= 1` なら同一行に `; ` 区切りで `findings` を列挙 (改行不要、Markdown bullet 構造を壊さない) |
| 4.3.4 (Issue 本文) | `{confidence_value}` | finding 単位の値。rite review 由来なら finding の severity (CRITICAL/HIGH/MEDIUM/LOW)、外部ツール由来かつ Confidence 列なしなら literal `70 (暫定)` |
| 4.3.4 (Issue 本文) | `{confidence_override_value}` | finding 単位の boolean。`confidence_override_findings` に当該 file:line が含まれていれば `true (外部ツール由来、Confidence 70 のまま 80+ ゲートをバイパスする policy override、ユーザー承認済み)`、それ以外は `false` |

この手順により、外部レビューツールの信頼度を silent に無視することなく、かつ hallucinated finding の混入も防ぎ、かつ Confidence 80+ ゲート invariant の破壊を silent に起こさない (override は常に trackable)。

> **Fast Path と Broad Retrieval の責任境界**: Phase 1.2 配下には以下 3 つの要素がある:
>
> | 要素 | 責任範囲 | Fast Path での実行 |
> |------|---------|---------------------|
> | Phase 1.2 冒頭の "Broad Comment Retrieval" ブロック (line 375 付近の bash block) | PR の全コメントを取得 (`gh api pulls/{n}/comments`, `gh pr view --json comments` 等) | **実行しない** (対象コメントは Fast Path 冒頭で既に取得済み) |
> | `### 1.2.1 Retrieve rite Review Results` | (1) `$pr_comments` から `📜 rite レビュー結果` コメントをフィルタ選択、(2) 選択されたコメント本文に対して Markdown table parsing algorithm を適用して `severity_map` を構築 | **Markdown table parsing algorithm の部分のみを `$target_body` に対して再利用する**。フィルタ選択 (1) は Fast Path では不要 (対象コメントが既に決まっているため) |
>
> Fast Path 経由で `severity_map` を構築した場合、`pr_comments` 変数および関連する review thread 情報 (broad retrieval で取得されるデータ) は **未定義のまま**である。後続の Phase で `$pr_comments` や reviewThreads を参照しないこと (参照すると runtime error)。Fast Path はあくまで「単一コメントから finding を抽出する」フローであり、broad retrieval の結果には依存しない。

パース完了後、抽出した findings を持って直接 Phase 2 (Categorization) に進む。Phase 1.2 の Broad Comment Retrieval ブロックおよび Phase 1.2.1 のフィルタ選択処理は Fast Path では実行しない (対象コメントは既に取得済みのため)。Phase 1.2.1 の Markdown table parsing algorithm のみを `$target_body` に適用する。

#### Broad Comment Retrieval — when `{target_comment_id}` is NOT set

When the standard flow is active (no `target_comment_id`), retrieve PR review comments as before:

```bash
# レビューコメント（PR レビューに紐づくコメント）
# node_id はスレッド解決時の GraphQL mutation で必要
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --jq '.[] | {id, node_id, path, line, original_line, body, user: .user.login, created_at, in_reply_to_id, pull_request_review_id}'

# PR レビュー自体のコメント
gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews --jq '.[] | {id, node_id, state, body, user: .user.login, submitted_at}'

# 通常のコメント（PR コメント欄）を一括取得して保存（Phase 1.2.1 で再利用）
pr_comments=$(gh pr view {pr_number} --json comments --jq '.comments')
echo "$pr_comments" | jq '.[] | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'
```

**Implementation note for Claude**: `$pr_comments` はシェル変数ではなく、**会話コンテキスト内で保持するデータ**として扱うこと。Claude Code が各 bash コードブロックを個別の Bash ツール呼び出しで実行する場合、シェル変数はブロック間で引き継がれない。Phase 1.2.1 では、この値をコンテキストから読み直すか、Phase 1.2 のコードブロックと Phase 1.2.1 のコードブロックを単一の Bash ツール呼び出しとして結合して実行すること。

```bash
# スレッド情報と解決状態を取得（GraphQL）
# 注: first: 100 の制限があるため、100件を超える大規模 PR では取得漏れの可能性あり
gh api graphql -f query='
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
}' -f owner="{owner}" -f repo="{repo}" -F pr={pr_number}
```

### 1.2.1 Retrieve rite Review Results

Retrieve the `/rite:pr:review` results from PR comments and extract severity information:

1. Search PR comments for those containing `## 📜 rite レビュー結果`
2. Parse the tables for each reviewer type within the "all findings" section
3. Extract the severity (CRITICAL/HIGH/MEDIUM/LOW) for each finding
4. Map severity using file:line as the key

**Search method:**

```bash
# Phase 1.2 で取得済みの pr_comments から rite レビュー結果を検索（API 呼び出しなし）
# 注: $pr_comments はコンテキスト保持データ。Phase 1.2 と同一 Bash ツール呼び出しで実行するか、
#     コンテキストから値を再注入すること（各 bash ブロックを個別に実行する場合、シェル変数は引き継がれない）
echo "$pr_comments" | jq '[.[] | select(.body | contains("## 📜 rite レビュー結果"))] | sort_by(.createdAt) | last | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'
```

**Note**: When multiple rite review result comments exist (when review has been run multiple times), use the one with the most recent `createdAt`.

**Parsing the Markdown table:**

The rite review result comment (output format of `/rite:pr:review`) has the following structure:

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: {マージ可 / 条件付きマージ可 / 修正必要}

### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| CRITICAL | src/auth.ts:42 | エラーハンドリングが不足 | try-catch を追加 |
```

**Parsing algorithm:**

1. Identify the `### 全指摘事項` section from the comment body
2. Iterate through each reviewer section delimited by `#### {Reviewer Type}`
3. Parse the table rows within each section (split by `|`)
4. Extract severity (column 1), file:line (column 2), content (column 3), recommended action (column 4)
5. Retain as `severity_map` (consolidating findings from all reviewers):
   ```
   severity_map = {
     "src/auth.ts:42": "CRITICAL",
     "src/api.ts:18": "HIGH",
     "src/utils.ts:55": "MEDIUM",
     "src/config.ts:10": "LOW"
   }
   ```

**Note**: When multiple reviewers have flagged the same file:line, adopt the highest severity (CRITICAL > HIGH > MEDIUM > LOW).

**When rite review results are not found:**

When no rite review results exist in PR comments (manual review only, or `/rite:pr:review` was not run):
- Continue processing with an empty `severity_map`
- Phase 1.3 falls back to GitHub state-based classification

### 1.3 Classify Comments

Perform severity-based classification using the `severity_map` obtained in Phase 1.2.1.

**Classification table:**

| Classification | Criteria | Action |
|---------------|----------|--------|
| **Required fix** | CRITICAL/HIGH | Must fix |
| **Needs fix** | MEDIUM/LOW | Fix or separate Issue (action required) |
| **External review** | Findings from human reviewers | Action required |
| **Resolved** | Resolved threads | - |

**Classification logic:**

1. Thread is resolved (`isResolved: true`) -> Resolved (processing complete)
2. Contains only `LGTM`, `+1`, `👍`, etc. -> Informational (no action needed)
3. Check if the finding's file:line exists in `severity_map`
4. If it exists, classify based on severity:
   - `CRITICAL` or `HIGH` -> Required fix
   - `MEDIUM` or `LOW` -> Needs fix
5. Unresolved comments not in `severity_map` -> External review

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
| Within `/rite:issue:start` review-fix loop | **Skip** (auto-select) | All findings + external reviews |
| Manual `/rite:pr:fix` | Display | User-selected |

> **Automatic target selection**: Within the e2e loop, all findings are always blocking and targeted for fix. See [Fix Targeting Rules](./references/fix-relaxation-rules.md)

---

```
PR #{number} のレビューコメント

## 未対応の指摘 ({count}件)

### 必須修正（CRITICAL/HIGH）({count}件)
| # | 重要度 | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|-----|----------|------------|
| 1 | {severity} | {path} | {line} | {body_preview} | @{user} |

### 要修正（MEDIUM/LOW）({count}件)
| # | 重要度 | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|-----|----------|------------|
| 1 | {severity} | {path} | {line} | {body_preview} | @{user} |

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
| **すべての指摘に対応（推奨）** | All severities + external reviews | When full resolution is needed. Within `/rite:issue:start` loop, all findings are auto-selected |
| **CRITICAL/HIGH のみ対応** | CRITICAL + HIGH only | When addressing only urgent issues and deferring MEDIUM/LOW |
| **特定の指摘を選択** | Individual selection | When addressing only specific findings |
| **キャンセル** | - | Abort the process |

**When there are no comments:**

```
PR #{number} にはレビューコメントがありません

考えられる状況:
- まだレビューが実施されていない
- すべての指摘が解決済み

次のステップ:
- `/rite:pr:review` でセルフレビューを実行
- `/rite:pr:ready` でレビュー待ちに変更
```

Terminate processing.

### 1.5 Fast Path Handoff File Cleanup (Phase 1 終端)

**Execution condition**: Fast Path 経由で一時ファイル (`/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt` 等) を作成した場合のみ実行する。Broad Comment Retrieval 経路ではこれらのファイルは存在しないため、`rm -f` は silent no-op となる。

**Purpose**: Phase 1.2 Fast Path で作成したハンドオフ一時ファイル 3 本を明示的に削除する。Phase 1.4 の末尾 (Phase 2 遷移直前) で必ず実行し、`/tmp` 累積汚染と再実行時の stale data 参照を防ぐ。

**Important — specific path 必須** (並列 fix 実行の他セッション破壊防止):
- wildcard glob (`/tmp/rite-fix-target-body-*.txt` 等) は**絶対に使わない**。並行 terminal / sprint team-execute / 手動複数セッションで他セッションの一時ファイルも silent に消す事故になる
- 必ず `{pr_number}-{target_comment_id}` suffix を含む specific path で削除する

```bash
# Phase 1.5: Fast Path Handoff File Cleanup
# 実行条件: Fast Path 経由 (target_comment_id が set されている場合) のみ
# Broad Comment Retrieval 経路では silent no-op (ファイルが存在しないため rm -f が exit 0 で終わる)
# {pr_number} / {target_comment_id} は Claude が Phase 1.0 の parse 結果で事前置換済み
rm -f "/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt"
```

**Idempotency**: `rm -f` は対象ファイルが存在しない場合でも exit 0 で成功するため、Broad Retrieval 経路でも安全に実行できる。また再実行時 (同一 pr_number + target_comment_id で再度 /rite:pr:fix を実行) でも古いファイルが確実に削除される。

---

## Phase 2: Assist with Fixes

### 2.1 Confirm Fix Approach

Confirm the fix approach for each finding:

```
指摘 #{n}: {file}:{line}

レビュアー: {reviewer_display}
内容:
{comment_body}

この指摘への対応方針を選択してください:

オプション:
- コードを修正する
- 説明・返信のみ（修正不要）
- スキップ（後で対応）
```

**`{reviewer_display}` の展開ルール** (Fast Path 経由で `target_author_mention_skip == "true"` の場合の silent `@unknown` 誤記録防止):

| 条件 | 展開結果 (日本語) | 展開結果 (英語) |
|------|-----------------|----------------|
| Broad Comment Retrieval 経由 (通常の `{user}`) | `@{user}` | `@{user}` |
| Fast Path 経由 かつ `target_author_mention_skip == "false"` | `@{target_author}` | `@{target_author}` |
| Fast Path 経由 かつ `target_author_mention_skip == "true"` | `(不明なレビュアー)` | `(unknown reviewer)` |

Claude は Phase 1 末尾で `/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt` を Read tool で読み (specific path 必須、wildcard glob は並列セッション破壊のため絶対禁止)、`"true"` の場合は本 phase 以降のすべての mention 生成箇所で `@` prefix を生成しない。

**複数 reviewer 時の `{reviewer_display_N}` 展開ルール** (Phase 3.2 trailer / Phase 4.3.4 Issue 本文 / Phase 4.2 PR comment 報告で使用):

| reviewer 数 | trailer の展開 (日本語) | trailer の展開 (英語) |
|------------|-------------------------|----------------------|
| 0 (該当 reviewer なし) | trailer 行自体を**省略** | trailer 行自体を**省略** |
| 1 | `{reviewer_display_1} のレビューコメントに対応` | `Addresses review comments from {reviewer_display_1}` |
| 2 | `{reviewer_display_1}, {reviewer_display_2} のレビューコメントに対応` | `Addresses review comments from {reviewer_display_1}, {reviewer_display_2}` |
| 3+ | `{reviewer_display_1}, {reviewer_display_2}, {reviewer_display_3}, ... のレビューコメントに対応` (出現順カンマ区切り) | 同様 |

**`{reviewer_display_N}` の出現順序ルール**:
- **Broad Retrieval 経由**: PR コメントの `created_at` 昇順 (古い順) で `_1`, `_2`, ... を割り当て
- **Fast Path 経由**: 単一 author のみ (常に N=1)。`target_author_mention_skip == "true"` のときは `(不明なレビュアー)` で展開
- **混在ケース**: Broad Retrieval 経路は単一の Phase 1.2 で完結し Fast Path 経路と排他のため、混在は発生しない

**末尾カンマの省略**: reviewer 数が template 中の `{reviewer_display_N}` 個数より少ない場合、余った placeholder と直前のカンマ + スペース (`, `) を**まとめて削除**する (例: template が `_1, _2` で reviewer 1 名なら `_1` のみ生成、`, _2` 部分を削除)。

**When "スキップ（後で対応）" is selected:**

Prompt for skip reason:

```
スキップする理由を入力してください:

オプション:
- スコープ外（別 Issue 対応）
- 後日対応
- 理由を入力（Other を選択）
```

**Note**: The entered `skip_reason` is used in Phase 4.3 for determining separate Issue candidates.

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

### 2.4 Create Reply (Optional)

After completing the fix, propose a reply to the reviewer:

```
レビュアーへの返信を作成しますか？

提案される返信:
> {original_comment_preview}

修正しました。{brief_explanation}

オプション:
- この返信を投稿
- 返信を編集
- 返信しない
```

When posting the reply:

**Note**: The following code block is a template. When Claude executes it, `{reply_body}` should be replaced with the actual reply content. `cat <<'REPLYEOF'` is a **single-quoted HEREDOC**, so bash variable expansion does not occur. Claude should replace the placeholder as an LLM and then construct the command.

```bash
# PR レビューコメントへの返信（in_reply_to で元コメントを指定）
# jq --rawfile で安全に JSON を生成し、gh api に渡す
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'REPLYEOF' > "$tmpfile"
{reply_body}
REPLYEOF
jq -n --rawfile body "$tmpfile" --argjson in_reply_to "$comment_id" \
  '{"body": $body, "in_reply_to": $in_reply_to}' | gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  -X POST \
  --input -
```

**Implementation note for Claude**: When Claude generates commands, write the reply content to a temporary file via `mktemp` + HEREDOC, then use `jq -n --rawfile body "$tmpfile"` to safely construct the JSON payload. Use the REST API numeric ID directly for `$comment_id` via `--argjson`. `jq --rawfile` reads the file as a raw string and handles all JSON escaping automatically.

---

## Phase 3: Fix Commit

### 3.1 Verify Changes

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

### 3.2 Generate Commit Message

Generate a commit message based on the addressed findings.

**Commit message language:**

Before generating the commit message, check the `language` field in `rite-config.yml` using the Read tool to determine the language:

| Setting | Behavior |
|---------|----------|
| `auto` | Detect the user's input language and generate in the same language |
| `ja` | Generate commit message in Japanese |
| `en` | Generate commit message in English |

**Language determination logic for `auto` setting:**

1. **Determination timing**: At commit message generation time, detect the most recent user input
2. **Determination method**: Determine by the following priority

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Contains Japanese characters (hiragana, katakana, kanji) | Japanese |
| 2 | Otherwise | English |

> **⚠️ CRITICAL**: The `description` part of the commit message **MUST** follow the `language` setting in `rite-config.yml`. The examples below are for reference only — always generate the description in the language determined by the setting, not by copying the example language. The commit body and trailer also follow the same language setting.

**Examples by language:**

| Language setting | Commit message example |
|-----------------|----------------------|
| `en` or `auto` (English input) | `fix(review): address review feedback` |
| `ja` or `auto` (Japanese input) | `fix(review): レビュー指摘に対応` |

**Commit body:**

> **Reference**: [Contextual Commits Reference](../../skills/rite-workflow/references/contextual-commits.md) for action line specification, mapping tables, output rules, and scope derivation.

Check `commit.contextual` in `rite-config.yml` to determine the commit body format.

**When `commit.contextual: true` (default):**

Generate structured action lines in the commit body following the Contextual Commits format. Review-fix commits are rich in decisions, making action lines particularly valuable.

- Leave a blank line between the description line and the action lines
- Can be omitted for trivial changes (typo fixes, formatting, etc.)

**Generation procedure:**

1. **Read review findings**: Extract from the review findings being addressed — the review指摘 and chosen対応方針 are the primary source for `decision` (Priority 1 — highest reliability for review-fix commits)
2. **Read work memory**: Extract from `決定事項・メモ`, `計画逸脱ログ`, `要確認事項` sections (Priority 2)
3. **Infer from diff**: When the diff shows clear technical choices, infer `decision` (Priority 3 — use only when evident)
4. **Apply review-fix mapping table**: Map each extracted item to action types using the [Review-Fix Commit Mapping](../../skills/rite-workflow/references/contextual-commits.md#review-fix-commit-mapping-prfixmd) table:
   - レビュー指摘の対応方針 → `decision(scope)`
   - 対応しなかった指摘とその理由 → `rejected(scope)`
   - 対応中に発見した制約 → `constraint(scope)`
   - 対応中の発見事項 → `learned(scope)`
5. **Filter to 10-line limit**: If action lines exceed 10, trim in order: `learned` → `constraint` → `rejected` → `decision` → `intent` (intent is preserved last as the core "why")

**Output rules:**
- Action type names are always in English (`intent`, `decision`, `rejected`, `constraint`, `learned`)
- Description follows the `language` setting in `rite-config.yml`
- Do not repeat information already visible in the diff
- Do not fabricate action lines without evidence from review findings, work memory, or diff

**Example (language: ja):**

```
fix(review): レビュー指摘に対応

decision(validation): 入力バリデーションを追加（レビュー指摘: 未検証の入力がエラーを引き起こす可能性）
rejected(refactor): ハンドラー全体のリファクタリングは見送り — スコープ外、別 Issue で対応
learned(error-handling): エラーレスポンスのフォーマットは既存の middleware と統一する必要あり
```

**When `commit.contextual: false`:**

Use free-form commit body. Include the reason for the change ("why") in the commit body.

- Leave a blank line between the description line and the body
- Write in free-form — no specific prefix or template required
- Focus on "why" the change was needed, not "what" was changed (the description line already covers "what")
- Follow the same language setting as the description line
- Can be omitted for trivial changes (typo fixes, formatting, etc.)

**Trailer**: Generate in the configured language using the unified `{reviewer_display_N}` placeholder (展開ルールは Phase 2.1 の `{reviewer_display}` 展開ルール表を参照 — Broad Retrieval 経由で `@{user}`、Fast Path 経由 + `target_author_mention_skip == "true"` で `(不明なレビュアー)` / `(unknown reviewer)` に展開される):

- English: `Addresses review comments from {reviewer_display_1}, {reviewer_display_2}`
- Japanese: `{reviewer_display_1}, {reviewer_display_2} のレビューコメントに対応`

**展開ルールの単一源**: 本 phase と Phase 2.1 / Phase 4.3.4 の 3 箇所で同一の `{reviewer_display}` 展開ルール (Phase 2.1 の表) を参照する。mention 生成ロジックを書き直す場合は Phase 2.1 の表のみを更新し、本 phase の literal 記述は追加しない (drift 防止)。

```
コミットメッセージ案:

fix(review): {description}

{action_lines (when commit.contextual: true)}

{trailer}

このメッセージでコミットしますか？

オプション:
- このメッセージでコミット
- メッセージを編集
- 個別にコミット（複数コミットに分割）
```

### 3.3 Execute the Commit

```bash
git add {changed_files}
git commit -m "$(cat <<'EOF'
{commit_message}
EOF
)"
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
git push
```

---

## Phase 4: Report Completion

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
# 注: thread_id は GraphQL の Node ID を使用（Phase 1.2 で取得した reviewThreads.nodes[].id）
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
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'REPORT_EOF' > "$tmpfile"
{report_body}
REPORT_EOF
gh pr comment {pr_number} --body-file "$tmpfile"
```

### 4.3 Automatic Separate Issue Creation (Required)

**⚠️ Important**: The following findings **must** be created as separate Issues. This is a required step to satisfy the loop termination condition of `/rite:issue:start`.

- Findings where "スキップ（後で対応）" was selected in Phase 2.1

#### 4.3.1 Collect Separate Issue Candidates

Collect **all** of the following findings as separate Issue candidates:

| Condition | Description |
|-----------|-------------|
| **Manual skip** | "スキップ（後で対応）" was selected in Phase 2.1 |

**Note**: Collect all skipped findings regardless of severity or skip reason. This guarantees no unaddressed findings remain.

#### 4.3.2 When No Candidates Exist

If the collection result is 0 items (all findings addressed), skip this step and proceed to 4.5.

#### 4.3.3 Confirm Separate Issue Creation

When there are 1 or more candidates, behavior differs based on the caller:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains context from `/rite:issue:start` Phase 5 "review-fix loop" | Within loop -> Skip confirmation and auto-create Issues |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` | Within loop -> Skip confirmation and auto-create Issues |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution -> Confirm with `AskUserQuestion` |

---

**When called from within the `/rite:issue:start` loop:**

Automatically create Issues for all skipped findings without confirmation.

```
スキップされた指摘を別 Issue として自動作成します

{count} 件の指摘が別 Issue として作成されます:

| # | ファイル | 内容 | 重要度 | スキップ理由 |
|---|----------|------|--------|-------------|
| 1 | {file_line} | {content_preview} | {severity} | {skip_reason} |

Issue を作成中...
```

**Reason**: In the review-fix loop, the loop continues until all findings are "addressed" (fixed, replied to, or converted to Issues). If skipped findings are not converted to Issues, the loop termination condition cannot be met.

---

**When `/rite:pr:fix` is executed manually:**

Confirm with `AskUserQuestion`:

```
スキップされた指摘を別 Issue として管理します

{count} 件の指摘が別 Issue として作成されます:

| # | ファイル | 内容 | 重要度 | スキップ理由 |
|---|----------|------|--------|-------------|
| 1 | {file_line} | {content_preview} | {severity} | {skip_reason} |

オプション:
- すべて Issue 化する（推奨）: すべての指摘を別 Issue として作成
- キャンセル: Issue 作成を中止
```

#### 4.3.4 Create Issues

Create Issues directly using `gh issue create` and register them in GitHub Projects. Do **not** use the `/rite:issue:create` Skill tool.

**Step 1: Generate Issue title**

Generate the Issue title in the following format:

```
{type}: {summary}
```

| Element | Generation Method |
|---------|-------------------|
| `{type}` | Inferred from the original finding content (`fix`, `feat`, `refactor`, `docs`, etc.) |
| `{summary}` | Summarize the original finding's `description` (50 characters or less, starting with a verb) |

**Step 2: Create Issue via Common Script**

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

**Note**: The heredoc below contains `{placeholder}` markers. Claude substitutes these with actual values **before** generating the bash script — they are not shell variables.

**Important**: The entire script block must be executed in a **single Bash tool invocation**.

**Priority mapping**: `緊急`/`重大`/`urgent`/`critical` in skip reason → High, all others → Medium

**Complexity mapping**: XS: single-line/single-location fix. S: multi-line change within 1-2 files

**Placeholder value sources** (Claude はスクリプト生成前に必ず以下のソースから値を取得し、プレースホルダーを置換すること):

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `B16B1RD` |
| `{iteration_mode}` | `rite-config.yml` → `iteration.enabled` が `true` かつ `iteration.auto_assign` が `true` なら `"auto"`、それ以外は `"none"` | `"none"` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) | `/home/user/.claude/plugins/rite` |

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## 概要

{description}

## 背景

この Issue は PR #{pr_number} のレビュー指摘対応中に作成されました。

### 元のレビュー指摘
- **ファイル**: {file}:{line}
- **レビュアー**: {reviewer_display}
- **指摘内容**: {original_comment}
- **Confidence**: {confidence_value} (Confidence override: {confidence_override_value})

<!-- placeholder 展開ルール (Claude がスクリプト生成前に置換する):
     - {reviewer_display}: Broad Retrieval 経由なら "@{reviewer}"、Fast Path 経由で
       target_author_mention_skip == "true" なら "(不明なレビュアー)"。詳細は Phase 2.1 の展開ルール表を参照
     - {confidence_value}: finding が rite review 由来なら CRITICAL/HIGH/MEDIUM/LOW のいずれか。
       外部ツール由来で Confidence 列なしの場合は "70 (暫定)" を入れる
     - {confidence_override_value}:
         false (rite review 由来 / Confidence 列ありの外部ツール) → "false"
         true (外部ツール由来 + ユーザーがバイパスを承認) → "true (外部ツール由来、Confidence 70 のまま
         80+ ゲートをバイパスする policy override、ユーザー承認済み)" -->

<!-- 補足: confidence_override 行を Issue 本文に含める理由は fix.md 本文の Phase 1.2 best-effort
     parse セクション末尾「Confidence override の追跡義務」段落を参照すること。 -->

### 別 Issue 化の理由
{skip_reason}

## 関連

- 元の PR: #{pr_number}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue 本文の生成に失敗" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{type}: {summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "{priority}" \
  --arg complexity "{complexity}" \
  --arg iter_mode "{iteration_mode}" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "pr_fix", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Error handling:**

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` | Display warning with error details. If remaining candidates exist, continue creating others |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Issue creation itself succeeded |

**Behavior on error:**
- Even if one Issue creation fails, continue creating other candidates
- Projects registration failure does not block Issue creation or subsequent processing
- Only report successfully created Issues in 4.3.5

#### 4.3.5 Creation Report

When Issues are created:

```
別 Issue を作成しました:

| Issue | タイトル |
|-------|----------|
| #{issue_number} | {issue_title} |

合計: {count} 件
```

After Phase 4.3 is complete, proceed to Phase 4.5 (work memory update).

### 4.5 Automatic Work Memory Update

> Update work memory per `work-memory-format.md` (at `{plugin_root}/skills/rite-workflow/references/work-memory-format.md`). Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script).

> **⚠️ Caution**: Work memory is published as a comment on the Issue. In public repositories, it is viewable by third parties. Do not record confidential information (credentials, personal information, internal URLs, etc.) in work memory.

If a related Issue exists, automatically update the work memory.

#### 4.5.1 Identify Related Issue

Identify the related Issue from the PR or branch name.

**Extraction priority:**
1. Search for `Closes #XX`, `Fixes #XX`, `Resolves #XX` patterns in the **PR body** (priority)
2. If not found in the PR body, search for the `issue-{number}` pattern in the **branch name**

```bash
# 1. まず PR 本文から Closes #XX パターンを抽出（優先）
# Phase 1.1 で --json に body を含めて取得済みのため、再取得不要
# 保持している body フィールドから直接パターンマッチ
pr_body_tmp=$(mktemp)
trap 'rm -f "$pr_body_tmp"' EXIT
printf '%s' "{pr_body}" > "$pr_body_tmp"
issue_number=$(grep -oE '(Closes|Fixes|Resolves) #[0-9]+' "$pr_body_tmp" | head -1 | grep -oE '[0-9]+' || true)

# 2. PR 本文で見つからない場合、ブランチ名から抽出
if [[ -z "$issue_number" ]]; then
  issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' || true)
fi
```

> **Note**: `{pr_body}` is the `body` field from the Phase 1.1 result (retained in context). No additional `gh pr view` call is needed.

**Implementation note for Claude**: `{pr_body}` はドキュメントのプレースホルダ（Phase 4.3.4 の注記と同等）。Claude はスクリプト生成前に実際の PR body で置換する。body に改行・シングルクォート・`$` 記号等の特殊文字が含まれる場合は `echo "..."` への直接埋め込みを避け、`printf '%s' '{pr_body}'` または一時ファイル経由（`tmpfile=$(mktemp)` + HEREDOC）でパターンマッチを実行すること。

If no Issue number is found, display a warning and skip the work memory update:

```
⚠️ Issue 番号が特定できないため作業メモリ更新をスキップしました
PR 本文に Closes/Fixes/Resolves #XX が含まれていないか、ブランチ名に issue-{number} パターンがありません。
```

#### 4.5.2 Retrieve and Update Work Memory Comment

The work memory update performs **three operations** in a single Bash tool invocation:

1. **進捗サマリー更新**: Update the progress summary table to reflect implementation status
2. **変更ファイル更新**: Replace the changed files section with actual file changes from `git diff`
3. **レビュー対応履歴追記**: Append the review response history (4.5.3 content)

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
# comment_data の取得・更新内容の生成・PATCH を分割すると変数が失われる（Issue #693, #90）
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
current_body=$(echo "$comment_data" | jq -r '.body // empty')

if [[ -n "$comment_id" ]]; then
  if [[ -z "$current_body" ]]; then
    echo "ERROR: 作業メモリの本文取得に失敗。更新をスキップします。" >&2
  else
    backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
    printf '%s' "$current_body" > "$backup_file"
    original_length=$(printf '%s' "$current_body" | wc -c)

    # Step 1: 変更ファイル一覧を取得
    # 注: git diff --name-status の stderr を suppress せず、エラー時は明示的に WARNING を出す
    # shallow clone / base branch 未 fetch で "unknown revision" 等が出た場合、silent に空文字に落ちると
    # work memory の変更ファイル一覧が「まだ変更はありません」と誤記録される silent regression の原因になる

    # 共有 sentinel 文字列定数 (bash 側 fallback marker と Python 側 startswith 検出を完全一致比較)
    # 文言を変更する場合、bash 側と Python 側 (後の python3 -c 内) を必ず同時に変更すること
    GIT_DIFF_FAILED_SENTINEL="__RITE_FIX_CHANGED_FILES_GIT_DIFF_FAILED__"

    base_branch=$(grep -E '^\s*base:' rite-config.yml 2>/dev/null | head -1 | sed 's/.*base:\s*"\?\([^"]*\)"\?/\1/' || echo "develop")
    diff_stderr_tmp=$(mktemp /tmp/rite-fix-git-diff-err-XXXXXX) || {
      echo "ERROR: git diff stderr 一時ファイルの作成に失敗" >&2
      exit 1
    }
    if ! changed_files_raw=$(git diff --name-status "origin/${base_branch}...HEAD" 2>"$diff_stderr_tmp"); then
      echo "WARNING: git diff --name-status \"origin/${base_branch}...HEAD\" が失敗しました。" >&2
      echo "  詳細: $(cat "$diff_stderr_tmp")" >&2
      echo "  考えられる原因: shallow clone (base branch 未 fetch) / 無効な base branch 名 / git リポジトリ外で実行" >&2
      echo "  対処: git fetch origin ${base_branch} を実行後に再試行、または rite-config.yml の branch.base を確認" >&2
      # sentinel 文字列のみを fallback 値とする (Python 側で完全一致比較で検出される)
      changed_files_md="${GIT_DIFF_FAILED_SENTINEL}"
    else
      changed_files_md=$(printf '%s\n' "$changed_files_raw" | while read -r status file; do
        [ -z "$status" ] && continue
        case "$status" in
          A) echo "- \`${file}\` - 追加" ;;
          M) echo "- \`${file}\` - 変更" ;;
          D) echo "- \`${file}\` - 削除" ;;
          R*) echo "- \`${file}\` - 名前変更" ;;
          *) echo "- \`${file}\` - ${status}" ;;
        esac
      done)
      if [[ -z "$changed_files_md" ]]; then
        changed_files_md="_まだ変更はありません (git diff は成功したが変更なし)_"
      fi
    fi
    rm -f "$diff_stderr_tmp"

    # Step 2: Python で進捗サマリー・変更ファイルを更新 + レビュー対応履歴を追記
    body_tmp=$(mktemp)
    tmpfile=$(mktemp)
    files_tmp=$(mktemp)
    history_tmp=$(mktemp)
    # diff_stderr_tmp は通常 line 1526 で削除済みだが、SIGTERM/SIGINT で kill された場合に
    # 上記 rm に到達しないリスクがあるため、念のため trap 対象にも追加 (defensive)
    trap 'rm -f "$pr_body_tmp" "$body_tmp" "$tmpfile" "$files_tmp" "$history_tmp" "$diff_stderr_tmp"' EXIT INT TERM HUP
    printf '%s' "$current_body" > "$body_tmp"
    printf '%s' "$changed_files_md" > "$files_tmp"
    cat > "$history_tmp" << 'HISTORY_EOF'
{4.5.3 の内容を実際の値で置換して記述}
HISTORY_EOF

    python3 -c '
import sys, re

body_path, out_path = sys.argv[1], sys.argv[2]
impl_status, test_status, doc_status = sys.argv[3], sys.argv[4], sys.argv[5]
files_path = sys.argv[6]
history_path = sys.argv[7]
git_diff_failed_sentinel = sys.argv[8]

with open(body_path, "r") as f:
    body = f.read()
with open(files_path, "r") as f:
    file_list_markdown = f.read()
with open(history_path, "r") as f:
    history_entry = f.read().strip()

# git diff 失敗 fallback marker を完全一致比較で検出し、visible WARNING ブロックに置き換える
# (silent regression 防止: stderr WARNING は E2E flow / 自動 hook 経由では人間に見えないため、
#  work memory body に明示的な警告ブロックを残す必要がある)
# 比較は startswith ではなく == で完全一致 (sentinel 文字列のみが fallback 値)
if file_list_markdown == git_diff_failed_sentinel:
    print(
        "ERROR: changed_files_md fallback marker detected. "
        "Replacing with visible WARNING block in work memory and aborting with non-zero exit.",
        file=sys.stderr,
    )
    file_list_markdown = (
        "> ⚠️ **WARNING**: `git diff --name-status` が失敗したため変更ファイル一覧を取得できませんでした。\n"
        "> 上記 stderr の詳細を確認し、`git fetch origin <base_branch>` を実行後に再実行してください。\n"
        "> このセクションは正確ではなく、変更があったかどうかの追跡には使えません。\n"
    )
    # body に警告ブロックを差し込んでから書き出してから exit する (debug 用に出力ファイルは残す)
    pattern = r"(### 変更ファイル\n)(?:<!-- .*?-->\n)?.*?(?=\n### |\Z)"
    body = re.sub(pattern, lambda m: m.group(1) + file_list_markdown, body, count=1, flags=re.DOTALL)
    with open(out_path, "w") as f:
        f.write(body)
    # 後続の PATCH を silent に成功させないため non-zero exit
    # bash 側で `|| { echo "..." >&2; exit 1; }` でハンドルされる
    sys.exit(2)

# --- Progress summary update (v2 format: Markdown table) ---
v2_updated = False
for item, status in [("実装", impl_status), ("テスト", test_status), ("ドキュメント", doc_status)]:
    pattern = r"(\| " + re.escape(item) + r" \| )[^|]*( \|.*\|)"
    new_body = re.sub(pattern, lambda m: m.group(1) + status + m.group(2), body, count=1)
    if new_body != body:
        v2_updated = True
    body = new_body

# v1 format fallback: checkbox style
if not v2_updated:
    if "### 進捗" in body and "### 進捗サマリー" not in body:
        for item, status in [("実装", impl_status), ("テスト", test_status), ("ドキュメント", doc_status)]:
            if "完了" in status:
                body = re.sub(r"- \[ \] " + re.escape(item), "- [x] " + item, body, count=1)

# --- Changed files section update ---
pattern = r"(### 変更ファイル\n)(?:<!-- .*?-->\n)?.*?(?=\n### |\Z)"
body = re.sub(pattern, lambda m: m.group(1) + file_list_markdown, body, count=1, flags=re.DOTALL)

# --- Append review response history ---
# Find existing レビュー対応履歴 section and append; if not found, add before 次のステップ
if "### レビュー対応履歴" in body:
    # Append to existing section (before the next ### heading or end)
    pattern = r"(### レビュー対応履歴\n.*?)(?=\n### |\Z)"
    body = re.sub(pattern, lambda m: m.group(1).rstrip() + "\n\n" + history_entry, body, count=1, flags=re.DOTALL)
else:
    # Insert before 次のステップ
    body = re.sub(r"(### 次のステップ)", "### レビュー対応履歴\n" + history_entry + "\n\n" + r"\1", body, count=1)

with open(out_path, "w") as f:
    f.write(body)
' "$body_tmp" "$tmpfile" "{impl_status}" "{test_status}" "{doc_status}" "$files_tmp" "$history_tmp" "$GIT_DIFF_FAILED_SENTINEL"
    py_exit=$?
    if [ "$py_exit" -eq 2 ]; then
      echo "ERROR: Python script detected git diff failure marker and refused to PATCH work memory silently." >&2
      echo "  visible WARNING block was injected into the body file ($tmpfile) for debug." >&2
      echo "  Backup of original work memory: $backup_file" >&2
      echo "  Action: git diff の失敗原因を解決後、再実行してください (上記 stderr の git diff WARNING を参照)" >&2
      exit 1
    elif [ "$py_exit" -ne 0 ]; then
      echo "ERROR: Python script failed with unexpected exit code $py_exit. Backup: $backup_file" >&2
      exit 1
    fi

    # Safety checks before PATCH (see gh-cli-patterns.md)
    if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
      echo "ERROR: Updated body is empty or too short. Aborting PATCH. Backup: $backup_file" >&2
      exit 1
    fi
    if ! grep -q '📜 rite 作業メモリ' "$tmpfile"; then
      echo "ERROR: Updated body missing work memory header. Backup: $backup_file" >&2
      exit 1
    fi
    updated_length=$(wc -c < "$tmpfile")
    if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
      echo "ERROR: Updated body < 50% of original (${updated_length}/${original_length}). Aborting PATCH. Backup: $backup_file" >&2
      exit 1
    fi

    jq -n --rawfile body "$tmpfile" '{"body": $body}' \
      | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
        -X PATCH --input - || \
        echo "WARNING: PATCH failed. Backup: $backup_file" >&2
  fi
fi
```

**Placeholder descriptions for Claude**:

| Placeholder | Description | Determination |
|-------------|-------------|---------------|
| `{impl_status}` | 実装ステータス | 修正コミットがあれば `✅ 完了` or `🔄 進行中` |
| `{test_status}` | テストステータス | テストファイルの変更があれば `🔄 進行中` or `✅ 完了`、なければ `⬜ 未着手` |
| `{doc_status}` | ドキュメントステータス | ドキュメントファイルの変更があれば `🔄 進行中` or `✅ 完了`、なければ `⬜ 未着手` |
| `{4.5.3 の内容}` | レビュー対応履歴エントリ | Phase 4.5.3 のテンプレートから生成 |

**Status detection logic**: Claude determines each status by analyzing `git diff --name-status` output:
- 実装: Target code files have changes → `✅ 完了` (all planned changes done) or `🔄 進行中`
- テスト: Test files (`*.test.*`, `*.spec.*`) have changes → update accordingly
- ドキュメント: Documentation files (`*.md`, `docs/*`) have changes → update accordingly

**Note for Claude**: ⚠️ このブロック全体を**1つの Bash ツール呼び出し**で実行すること。`current_body` 取得・Python 更新スクリプト実行・PATCH を別の Bash ツール呼び出しに分割すると、前の呼び出しのシェル変数（`current_body` 等）が失われてヘッダーが消失する（Issue #693）。`{4.5.3 の内容を実際の値で置換して記述}` を 4.5.3 のテンプレートから生成した実際の追記内容で置換し、**すべてを1ブロックで**実行する。

#### 4.5.3 Update Content

Automatically append the following to work memory:

```markdown
### レビュー対応履歴

#### {timestamp}: /rite:pr:fix 実行
- **対応した指摘**: {count}件
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

**`{confidence_override_section}` の生成ルール** (Phase 1.2 best-effort parse の Confidence override 追跡義務):

| 状況 | 展開内容 |
|------|----------|
| `confidence_override_count == 0` | `なし` |
| `confidence_override_count >= 1` | 親 bullet と同一行に **`; ` 区切りで列挙** (改行なし、Markdown bullet 構造を壊さない) |

**`>= 1` のときの展開例** (`confidence_override_findings = ["src/foo.ts:42", "src/bar.ts:18"]` の場合):

```markdown
- **Confidence override**: src/foo.ts:42; src/bar.ts:18 (外部ツール由来、Confidence 70 のまま 80+ ゲートをバイパスする policy override、ユーザー承認済み)
```

**重要 — 改行禁止**: bullet item 内に改行と子箇条書きを入れる場合 Markdown は子側に 2 スペースインデントを要求するが、placeholder 展開時の自動インデント処理は脆弱で履歴の構造を壊しやすい。そのため `{confidence_override_section}` は **同一行に押し込める** 形式を厳格に採用する。

### 4.6 Completion Report

```
PR #{number} のレビュー指摘対応を完了しました

全指摘: {total_count}件
対応した指摘: {count}件
- 修正: {fix_count}件
- 返信: {reply_count}件
- スキップ → 別 Issue 化: {skip_count}件
コミット: {commit_sha}
プッシュ: 完了 / 未実行
別 Issue 作成: {issue_count}件
Confidence override (policy bypass): {confidence_override_count}件{confidence_override_files_suffix}

次のステップ:
- レビュアーの再レビューを待つ
- 追加の指摘があれば再度 `/rite:pr:fix` を実行
- すべて承認されたら `/rite:pr:ready` でマージ準備
```

**`{confidence_override_count}` / `{confidence_override_files_suffix}` の展開ルール** (Confidence policy override の追跡可視化):

| 状況 | `{confidence_override_count}` | `{confidence_override_files_suffix}` |
|------|------------------------------|--------------------------------------|
| 0 件 (override なし、通常時) | `0` | 空文字列 |
| 1 件以上 (override 適用あり) | `{N}` | ` ({file:line_1}, {file:line_2}, ...)` (先頭スペース付きカッコ内に一覧) |

**重要**: `confidence_override_count == 0` の場合でも本行は省略せず常に表示する (override が「なし」であることを明示し、silent な policy bypass の有無を可視化するため)。

**Field descriptions:**

| Field | Description | Calculation |
|-------|-------------|-------------|
| `全指摘: {total_count}件` | Total number of findings | Number of review comment findings retrieved in Phase 1 |
| `対応した指摘: {count}件` | Number of findings addressed | `fix_count + reply_count + skip_count` |
| `Confidence override (policy bypass): {N}件` | Number of findings imported via Confidence policy override | Phase 1.2 best-effort parse で「Confidence 70 のままバイパス」を選択した finding 数 (Confidence 80+ ゲート invariant の policy override 追跡義務)。0 件でも常時表示 |

**Note**: The review-fix loop of `/rite:issue:start` checks the content of this completion report to determine the next action:
- `プッシュ: 完了` -> Execute re-review (verify fix content)
- `別 Issue 作成: N件` (N >= 1) -> Execute re-review (confirm skipped findings are managed)
- `プッシュ: 未実行` and `別 Issue 作成: 0件` and `全指摘 == 対応指摘` -> Proceed to completion report (all addressed via replies)

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When PR is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When Comment Retrieval Fails | ネットワーク接続を確認; `gh auth status` で認証状態を確認 |
| Error During File Modification | この指摘をスキップして続行 / 手動で修正 |
| Commit Failure | `git status` で状態を確認; 問題を解決してから再度コミット |

## Phase 8: End-to-End Flow Continuation (Output Pattern)

> **This phase is executed only within the end-to-end flow (within the review-fix loop of `/rite:issue:start`). Skip for standalone execution.**

**Flow detection method:** Claude determines the caller from the conversation context using mechanical pattern matching:

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Conversation history contains a record of `Skill tool` invoking `rite:pr:fix` (recent message) | Within loop → Execute Phase 8 |
| 2 | Work memory contains `コマンド: /rite:issue:start` AND (`フェーズ: 実装作業中` OR `フェーズ: 品質検証`) | Within loop → Execute Phase 8 |
| 3 | Otherwise (user directly input `/rite:pr:fix`) | Standalone execution → Skip Phase 8 |

### 8.1 Output Pattern (Return Control to Caller)

Before outputting the pattern, update `.rite-flow-state` to `phase5_post_fix` (defense-in-depth, fixes #709). This prevents stop-guard `error_count` from accumulating when the flow continues after this skill returns:

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase5_post_fix" \
  --next "rite:pr:fix completed. Check recent result pattern in context: [fix:pushed]->Phase 5.4.1 (re-review). [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->Phase 5.5. Do NOT stop." \
  --if-exists
```

**Note on `error_count`**: `flow-state-update.sh` patch mode resets `error_count` to 0 on every phase transition (since #294). This prevents stale circuit breaker counts from one phase from poisoning subsequent phases.

**Also update local work memory** (`.rite-work-memory/issue-{n}.md`) with phase transition:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details and marketplace install notes.

```bash
WM_SOURCE="fix" \
  WM_PHASE="phase5_post_fix" \
  WM_PHASE_DETAIL="レビュー修正後処理" \
  WM_NEXT_ACTION="re-review or completion" \
  WM_BODY_TEXT="Post-fix sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

Then, based on the Phase 4.6 completion report content, output the corresponding machine-readable pattern:

| Condition | Output Pattern |
|-----------|---------------|
| Push completed (`プッシュ: 完了`) | `[fix:pushed]` |
| Separate Issues created (N >= 1) | `[fix:issues-created:{count}]` |
| All findings replied (no push, no separate Issues) | `[fix:replied-only]` |
| Unexpected state / error | `[fix:error]` |

**Important**:
- Do **NOT** invoke `rite:pr:review` via the Skill tool
- Return control to the caller (`/rite:issue:start`)
- The caller determines the next action based on this output pattern

**Example output:**
```
PR #123 のレビュー指摘対応を完了しました

全指摘: 5件
対応した指摘: 5件
- 修正: 3件
- 返信: 1件
- スキップ → 別 Issue 化: 1件
コミット: abc1234
プッシュ: 完了
別 Issue 作成: 1件

[fix:pushed]
```

---

### 8.2 Standalone Execution Behavior

For standalone execution, Phase 8 is not executed. The completion report from Phase 4.6 will guide the user.
