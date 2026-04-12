---
description: レビュー指摘への対応を支援
---

# /rite:pr:fix

## Contract
**Input**: PR number, review findings from `/rite:pr:review`, `.rite-flow-state` with `phase: phase5_fix` (e2e flow)
**Output**: `[fix:pushed]` | `[fix:pushed-wm-stale]` | `[fix:issues-created:{n}]` | `[fix:replied-only]` | `[fix:error]`

Retrieve and organize PR review comments to efficiently assist with addressing review feedback

## Inline Annotation Convention

本ファイル内の `verified-review` 注釈は `/verified-review` コマンドによるレビュー指摘の対応追跡に使用される。命名規則:

- `verified-review cycle N` — N 回目のレビュー・修正サイクル
- `H-N` / `M-N` / `L-N` / `S-N` / `I-N` / `C-N` — 重要度プレフィックス (High/Medium/Low/Suggestion/Important/Critical) + サイクル内通番
- 括弧内 `(M10)` 等 — サイクル横断の統合追跡 ID

これらの注釈は git history でも追跡可能だが、コード内で変更理由の文脈を保持するために残している。

## Prerequisites

**bash 4.0+ 必須**: 本コマンドは複数の bash block で `mapfile -t < <(...)` builtin を使用する (Phase 1.2.0 Priority 2 の `find ... | sort -r` 結果取得、Phase 4.5 doc-heavy 検証等)。Phase 1.0.1 の bash block 冒頭 (Step 0) に [bash-compat-guard.md](../../references/bash-compat-guard.md) の canonical guard を **inline embed 済み** (C-3 対応)。prose 参照ではなく実行可能な bash コードとして配置されており、Claude は Phase 1.0.1 bash block を実行するだけで guard が発火する。失敗時は `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=bash_version_incompatible` を emit して `[fix:error]` で exit する。

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

以下の **4 種類のうち 1 つ** (`pr_number` / `pr_url` / `comment_url` の 3 つは mutually exclusive、引数なしも許容)。現在は引数なしを含めて 4 種類すべてを 1 つの選択肢一覧として明示している:

| Argument (one of) | Description |
|-------------------|-------------|
| `[pr_number]` | PR number (defaults to the PR for the current branch if omitted) |
| `[pr_url]` | PR URL (`https://github.com/{owner}/{repo}/pull/{N}`) |
| `[comment_url]` | PR comment URL (`https://github.com/{owner}/{repo}/pull/{N}#issuecomment-{ID}`) |
| (引数なし) | 現在のブランチに紐づく PR を自動検出 |

**Accepted formats**: すべての引数形式は Phase 1.0 (Argument Parsing Pre-flight) で正規化され、`{pr_number}` と（該当時のみ）`{target_comment_id}` が抽出される。`comment_url` を指定すると、その特定コメントから直接 findings をパースする（Phase 1.2 で分岐）。`pr_number` 単体または引数なしの既存挙動は完全に維持される。**複数の引数を同時に渡すことはできない** (Phase 1.0 は最初に解釈成功した形式のみを採用する)。

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

> **Execution order**: 本サブフェーズは Phase 1.1 の `gh pr view` 呼び出しよりも**必ず先に**実行される pre-flight サブフェーズ。番号 `1.0` は「Phase 1 内の 0 番目 (Phase 1.1 より前)」の意で、自然順で読み進める AI/人間どちらも順序通りに実行できる。Phase 1.0 内部の実行順序と flag pre-stripping の詳細は下記「Flag pre-stripping for Detection rules」注記に集約されている (drift 防止のため 2 箇所で重複記述しない)。

> **⚠️ Phase 1.0 の 2 段構成 (Phase 1.0.A → Phase 1.0.B)** : 実行順を番号順に一致させるため、以下のラベルで明示する:
>
> - **Phase 1.0.A — Flag Parsing** (実装は後述の Phase 1.0.1 セクション): `--review-file <path>` 等のフラグトークンを `$ARGUMENTS` から pre-strip し、`remaining_args` に PR 番号候補だけを残す
> - **Phase 1.0.B — Detection rules** (本セクション直下): 上記 `remaining_args` に対して順序 1 / 2 / 3 / 4 の regex を適用して `{pr_number}` と `{target_comment_id}` を抽出
>
> Phase 1.0.A → Phase 1.0.B の順で実行する。Phase 1.0.1 セクションが Detection rules table より後に記述されているが、**実行は先に行う** (A before B — flags before detection)。

**Always run this sub-phase**. Phase 1.1 が `gh pr view` を実行する前に、引数形式を正規化して `{pr_number}` と（該当時のみ）`{target_comment_id}` を抽出する。bare integer (`^[0-9]+$`) や引数なしの場合でも本サブフェーズを実行し、Detection rules table の順序 1 / 順序 4 で pr_number を抽出した上で **`{target_comment_id} = null` を explicit set** する (undefined 参照防止)。

> **Why this ordering matters**: If you pass a PR URL or comment URL directly to `gh pr view {pr_number}`, the command will fail and Phase 1.1 will terminate with "PR not found". The Fast Path in Phase 1.2 cannot be reached. Always normalize first.

**Detection rules** (順序ベース判定 — bash POSIX ERE は negative lookahead 非対応のため、より特殊なパターンを先に試して fallthrough する):

| 順序 | Format | Regex (POSIX ERE 互換、lookaround なし) | Extracted |
|------|--------|------------------------------------------|-----------|
| 1 | 数字のみ (ASCII / 全角) | `^[0-9０-９]+$` | `pr_number` (全角数字は半角に正規化してから as-is 保持) |
| 2 | Comment URL (`?query` は `#fragment` の前後どちらでも可) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)(\?[^#]*)?#issuecomment-([0-9]+)(\?.*)?$` | `pr_number` = group 1, `target_comment_id` = **group 3** (group 2 は `#fragment` 前の query string、group 4 は `#fragment` 後の query string で、いずれも受け入れて無視) |
| 3 | PR URL (trailing path / query / fragment 任意) | `^https?://github\.com/[^/]+/[^/]+/pull/([0-9]+)(/[^#?]*)?(\?[^#]*)?(#.*)?$` | `pr_number` = group 1 (trailing `/files`, `/commits`, `/checks` 等の sub-page、`?tab=...` 等の query string、`#diff-...` 等の fragment はすべて受け入れて無視) |
| 4 | 引数なし | — | 既存ロジック (current branch から PR 検出) |

**重要 — RFC 3986 順序対応**: 順序 2 の regex は `?query` を `#fragment` の **前後どちらでも許容** する。RFC 3986 §3 ABNF (`URI = scheme ":" hier-part [ "?" query ] [ "#" fragment ]`) の規定では `?query` が `#fragment` より先に来るのが正規順序だが、GitHub UI で生成されるコメント URL は両方の順序で出現しうる:

- `https://github.com/owner/repo/pull/123?notification_referrer_id=NT_abc#issuecomment-456` (RFC 準拠 / 通知メール / Copy link / Slack 連携経由) — group 2 で query を吸収
- `https://github.com/owner/repo/pull/123#issuecomment-456?notification_referrer_id=NT_abc` (旧 GitHub UI / 一部の bot) — group 4 で query を吸収
- `https://github.com/owner/repo/pull/123#issuecomment-456` (基本形) — group 2/4 ともに空

target_comment_id は **常に group 3** に位置する (group 2 は `#fragment` 前の query string、group 4 は `#fragment` 後の query string)。bash 実装では `${BASH_REMATCH[3]}` を target_comment_id として参照する。

**重要 — bash 互換性と順序保証**: 順序 2/3 の regex は **negative lookahead `(?!issuecomment-)` を使わない**。これは bash の `[[ =~ ]]` (POSIX ERE) や `grep -E` が POSIX BRE/ERE であり lookaround 系の構文をサポートしないため。**順序 2 (issuecomment URL) を順序 3 (一般 PR URL) より先に試す**ことで、issuecomment URL は順序 2 でマッチして target_comment_id が抽出される。順序を保証することで lookaround 不要となる。Source: [IEEE Std 1003.1 Chapter 9 — Regular Expressions](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html)。

**順序 3 の受理範囲**: GitHub の "Files changed" タブから URL をコピーすると `pull/123/files` や `pull/123?tab=files` が返るため、`(/[^#?]*)?(\?[^#]*)?(#.*)?$` 形式で trailing path / query / fragment をすべて optional で受理する (`/files`, `/commits`, `/checks`, `?tab=files`, `?notification_referrer_id=...`, `#diff-{sha256}` 等)。pr_number のみ抽出。

**全角数字の扱い** (順序 1): 日本語 IME の fullwidth モードで入力された `１２３` のような全角数字をユーザーが誤って投入するケースを救済する。マッチした場合は `tr '０-９' '0-9'` 相当の変換で半角に正規化してから `{pr_number}` として保持する。ASCII 数字のみの場合は変換せずそのまま使用。

**正規化発火時の通知** (silent transformation 防止): 全角→半角の正規化が発火した場合、以下を **stderr に必ず出力** する。これにより `１２３` を渡したつもりが別 PR `123` を fix する結果になっても、ユーザーは何が起きたか即座に理解できる:

```
INFO: 全角数字 '{original}' を半角 '{normalized}' として解釈しました
  正規化対象: 順序 1 のパターン (^[0-9０-９]+$) でマッチした入力
  対処: もし意図しない数値の場合、Ctrl+C で中断してから半角で再入力してください
```

ASCII 数字のみの入力 (`123` → `123`) では本 INFO は出力しない (no-op の冗長表示を避けるため)。

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
     - PR URL（例: https://github.com/owner/repo/pull/123、trailing /files や ?tab=... も可）
     - PR コメント URL（例: https://github.com/owner/repo/pull/123#issuecomment-4567890、末尾の ?notification_referrer_id=... は自動的に無視）
   ヒント: もし Issue URL (/issues/123) を渡している場合、/rite:pr:fix は PR 専用です。Issue 対応は /rite:issue:start を使用してください。
   ```
2. **Context 変数を explicit set** (undefined 参照防止):
   - `{pr_number} = null`
   - `{target_comment_id} = null`
3. **`[fix:error]` output pattern を stdout に出力** し、**Phase 1.1 以降のすべてのサブフェーズを実行せずにコマンド全体を終了する**
4. **重要**: ここでの「Terminate processing」は Phase 1.1 への進入禁止を意味する。「Phase 1.0 で parse 失敗したから Phase 1.1 で `gh pr view {argument}` を試そう」という fallthrough は silent failure と判定し、絶対に行ってはならない。引数が未知の形式である以上、Phase 1.1 の `gh` コマンドに渡しても確実に失敗し、かつ同番号の別 Issue を誤認する危険がある

**Compatibility**: 既存の `pr_number` 単体挙動および引数なし挙動は一切変更されない。本 Phase は引数形式の判定のみを行い、Phase 1.1/1.2 の既存ロジックにはフラグ (`{target_comment_id}` の有無) を渡すだけである。

> **⚠️ Flag pre-stripping for Detection rules**: 上記 Detection rules table は `$ARGUMENTS` ではなく **Phase 1.0.1 で flag トークンを除去した `remaining_args`** に対して適用すること。これにより `/rite:pr:fix 123 --review-file foo.json` のように PR 番号とフラグが混在しても `123` だけが残り、order 1 regex にマッチする。

#### 1.0.1 Flag Parsing — `--review-file` and pre-stripping (#443)

`/rite:pr:fix --review-file <path>` を受け付けるため、以下の手順で `{review_file_path}` を抽出する。Phase 1.2 のハイブリッド読取ロジック (Priority 0: 明示指定) で参照される。

**実行順**: Phase 1.0 冒頭の Phase 1.0.A/1.0.B 説明を参照 (本サブフェーズは Phase 1.0.A = Detection rules (Phase 1.0.B) よりも先に実行される)。

**抽出手順** (bash 実装):

```bash
# Phase 1.0.1: flag トークンを $ARGUMENTS から pre-strip
# {review_file_path} と remaining_args (pr_number / pr_url / comment_url) を分離する
#
# Rationale:
# - sed regex は `[[:space:]]` を使い tab 区切りも処理する
# - printf '%s' を使用する理由: echo は -n/-e/-E で始まるトークンを option として誤解釈するため

# --- Step 0: bash 4+ compat guard (C-3: inlined from references/bash-compat-guard.md) ---
# mapfile builtin は bash 4.0 で導入されたため、bash 3.2 (macOS default) では
# Phase 1.2.0 Priority 2 の `mapfile -t files_arr < <(find ...)` が silent 失敗し
# silent に Priority 3 へ routing する regression を起こす。本 guard で fail-fast させる。
# prose 参照ではなく inline 実行可能コードとして配置 (C-3 対応)。
# Source: GNU Bash 4.0 NEWS (https://tiswww.case.edu/php/chet/bash/NEWS)
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
# sentinel を `null` から `__RITE_UNSET__` に変更
# (旧実装は `--review-file null` を渡したユーザーが「`null` という名前のファイル」を意図した場合と
# 衝突する。`__RITE_UNSET__` は legitimate な file path として現実に存在しないため衝突しない)
review_file_path="__RITE_UNSET__"  # explicit set (undefined 参照防止、衝突安全な sentinel)
remaining_args="$original_args"
# flag style を別変数に保持してエラーメッセージで区別する
# (Pattern 1 = `--review-file=` 等号スタイル、Pattern 2 = `--review-file <space>` POSIX スタイル)
review_file_flag_style="none"

# Pattern 1: --review-file=<path> (GNU-long-option style)
# `[^[:space:]]*` (0 文字以上) にすることで `--review-file=` (値なし) も match させ、
# 空値を empty-path エラーとして明示的に検出できるようにする (silent parse failure 防止)。
# 境界マッチャー `([[:space:]]|$)` を追加して `--review-file=foo` が
# `--review-files` や `--review-file-bogus` の prefix として誤検出される経路を塞ぐ。
if [[ "$remaining_args" =~ (^|[[:space:]])--review-file=([^[:space:]]*)([[:space:]]|$) ]]; then
  review_file_path="${BASH_REMATCH[2]}"
  review_file_flag_style="equals"
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--review-file=[^[:space:]]*//')
# Pattern 2: --review-file <path> (POSIX style with space/tab)
# Pattern 1 と対称に、`--review-file` 単独 (末尾空) も match させる。
# 旧実装 `[^[:space:]]+` (1+) では `/rite:pr:fix 123 --review-file` のような末尾空指定が
# regex non-match で silent fallthrough する問題があった。`[^[:space:]]*` (0+) に変更し、
# 末尾フラグ単独の場合は空文字列を capture して下流の `review_file_path_empty_value` 検出に流す。
# 末尾境界 `([[:space:]]|$)` を追加して `--review-file` 本体の
# trailing prefix match (`--review-files` / `--review-file-foo` 等) を排除する。
# sed 側は「detection 側で既に境界 guard が効いた後にのみ実行される」ため、境界追加は不要
# (else branch は detection regex が match した時のみ到達するので、prefix match の懸念なし)。
elif [[ "$remaining_args" =~ (^|[[:space:]])--review-file([[:space:]]+([^[:space:]]*))?([[:space:]]|$) ]]; then
  review_file_path="${BASH_REMATCH[3]:-}"
  review_file_flag_style="space"
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--review-file([[:space:]]+[^[:space:]]*)?//')
fi

# remaining_args の前後 whitespace を trim
remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

# --review-file=<空> を明示エラー化: Pattern 1/2 が match しても review_file_path が空文字の場合は fail-fast
# (Phase 8.1 評価順 1 で FIX_FALLBACK_FAILED を検出し [fix:error] へ昇格させる)
# 注: review_file_flag_style != "none" のときに空文字 (= match したがパスなし) を判定する。
# review_file_flag_style == "none" のときは sentinel `__RITE_UNSET__` のままなのでこの分岐に来ない。
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

# [CONTEXT] emit は **必ず stderr** に出力する (同 PR 内の [CONTEXT] emit 規約統一)。
# 本 PR の他の [CONTEXT] emit (Phase 1.2.0 Priority 0/2/3、Phase 6.1.a、Phase 8.1 retained flags) は
# すべて >&2 を付与しているため、本箇所もそれに揃える。Claude は stderr (Bash tool output に
# 両方含まれる) から会話コンテキストで値を読み取る。
echo "[CONTEXT] REVIEW_FILE_PATH=$review_file_path" >&2
echo "[CONTEXT] REMAINING_ARGS=$remaining_args" >&2
```

**Validation**: この Phase では **パスの存在確認は行わない**。存在確認は Phase 1.2 のハイブリッド読取ロジック Priority 0 で実施し、失敗時は Phase 1.2.0.1 Interactive Fallback に誘導する ([review-result-schema.md 読取優先順位セクション](../../references/review-result-schema.md#読取優先順位-prfix) 参照)。ただし `--review-file=` (値なし) のみは上記 bash block 内で即 fail-fast する (後段で silent fallback に流れないため)。

**制約 — 空白を含むパスは未対応**: `--review-file` の regex parsing は `[^[:space:]]*` で値を capture するため、`/Users/name/Google Drive/foo.json` のような**空白を含むパスは正しくパースされない** (空白位置でトークン分割され、PR 番号候補として誤認される)。この制約は Claude Code の `$ARGUMENTS` が単一文字列として渡される仕様に起因し、真の argv 復元は不可能。空白を含むパスを使いたい場合は Phase 1.2.0.1 Interactive Fallback の「ファイルパス指定」option で入力すること (AskUserQuestion は単一文字列として受け取るため空白を含むパスも受理される)。

**Claude data flow**: Claude は上記 bash block の **stderr** から `[CONTEXT] REVIEW_FILE_PATH=...` と `[CONTEXT] REMAINING_ARGS=...` を会話コンテキストで読み取り、以後 Phase 1.0 Detection rules を `remaining_args` に対して適用する。Detection rules 側の regex は **必ず** `$ARGUMENTS` ではなく `remaining_args` を入力とすること。Claude Code の Bash tool は stdout/stderr 両方をコンテキストに取り込むため、stderr 読取で支障はない。

**Compatibility**: `--review-file` を使わない既存呼び出し (`/rite:pr:fix 123` 等) は一切挙動変更なし — `remaining_args = original_args` となり既存ロジックと等価。本フラグは Phase 1.2 冒頭の読取優先順位決定にのみ影響する。

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

#### 1.2.0 Hybrid Review Source Resolution (#443) <!-- AC-3 / AC-4 / AC-5 / D-01 -->

> **⚠️ MANDATORY**: This sub-phase runs **first** in Phase 1.2, before any of the existing Fast Path / Broad Retrieval branches below. It implements the "会話 > ローカルファイル > PR コメント" priority chain defined in [review-result-schema.md](../../references/review-result-schema.md#読取優先順位-prfix) and sets `{review_source}` to indicate which path was selected. Subsequent sub-sections execute conditionally based on `{review_source}`.

> **Acceptance Criteria anchor**: AC-3 (Priority 1: 同一セッション内の会話コンテキストを最優先で使用)。AC-4 (Priority 2: 会話になければ最新 timestamp のローカルファイルを使用)。AC-5 (Priority 3: 既存 PR コメントの `📜 rite レビュー結果` を後方互換 fallback として読取)。D-01 (会話 > ローカルファイル > PR コメントのハイブリッド方式を採用した理由: セッション横断作業と即時連携の両立)。

**Priority chain**:

| Priority | Source | Condition | Action |
|----------|--------|-----------|--------|
| 0 | `--review-file <path>` (explicit) | `{review_file_path}` set in Phase 1.0.1 | Read and parse the specified file. On failure, go directly to Priority 4 (fallback) |
| 1 | Conversation context | Same session has a recent `/rite:pr:review` result in context | Use conversation-context findings directly; skip API/file access |
| 2 | Local JSON file | `.rite/review-results/{pr_number}-*.json` exists | Read latest timestamp file; parse per schema |
| 3 | PR comment (backward-compat) | PR has `## 📜 rite レビュー結果` comment | Extract Raw JSON from code fence if present; else parse Markdown table (legacy) |
| 4 | Interactive fallback | None of the above available | `AskUserQuestion` — prompt user for action (Phase 1.2.0.1) |

**⚠️ Selection logic — Claude substitution required**:

下記 bash block は Phase 1.0.1 の別 Bash tool invocation で stderr に emit された `[CONTEXT] REVIEW_FILE_PATH=...` 値を参照する必要がある。シェル変数は Bash tool 呼び出し間で継承されないため、Claude は下記 bash block を生成する前に **会話コンテキストから `[CONTEXT] REVIEW_FILE_PATH=...` の値を読み取り、`review_file_path="<実値>"` の literal 代入文として bash 冒頭に埋め込む** こと。もし Phase 1.0.1 で `review_file_path="__RITE_UNSET__"` だった場合は `review_file_path="__RITE_UNSET__"` を literal に埋め込む。

**Selection logic**:

> **pipefail scope note**: 下記 bash block は **単一 Bash tool invocation 内で閉じる前提**で設計されており、冒頭で `set -o pipefail` を有効化する。Bash tool 呼び出し間でシェル state は継承されないため、block 外への伝播はない。末尾の `set +o pipefail` は block 内後続コマンドが pipefail を避けたい箇所に備えるための restore だが、早期 exit パス (`exit 1` 等) では restore を経由せず直接終了する。これは Bash tool 隔離により問題にならない (各 Bash tool invocation は独立したシェルプロセスで実行されるため、exit 時の pipefail state は次回呼び出しに継承されない)。

```bash
# ⚠️ Claude は以下の literal 代入を Phase 1.0 / 1.0.1 の値に基づいて substitute すること
# pr_number は本 block 内で `find -name "${pr_number}-*.json"` 等で参照されるため、placeholder の
# まま substitute 漏れすると find が literal `{pr_number}-*.json` を探して常に 0 件を返す
# silent fallthrough を起こす。block 冒頭で明示的に literal substitute する。
pr_number="{pr_number}"

# pr_number の数値 fail-fast gate。
# cleanup.md Phase 2.5 の pr_number guard および review.md Phase 6.1.a と対称化。
# Claude が literal substitute を忘れた場合、find が literal `{pr_number}-*.json` を探して常に
# 0 件を返し Priority 2 が silent fallthrough する経路を早期に閉じる。retained flag
# FIX_FALLBACK_FAILED を emit して Phase 8.1 が `[fix:error]` を出力するように昇格させる。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: Phase 1.2.0 の pr_number が literal substitute されていません (値: '$pr_number', 期待: 数値のみ非空)" >&2
    echo "  Claude は Phase 1.0 で正規化された pr_number を本 bash block 冒頭で literal substitute する必要があります" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=pr_number_placeholder_residue" >&2
    echo "[fix:error]"
    exit 1
    ;;
esac
# sentinel が `null` から `__RITE_UNSET__` に変更された
# (`null` という名前のファイルを literal に渡された場合の衝突を回避するため)
# 例: [CONTEXT] REVIEW_FILE_PATH=__RITE_UNSET__ → `review_file_path="__RITE_UNSET__"`
# 例: [CONTEXT] REVIEW_FILE_PATH=./foo.json → `review_file_path="./foo.json"`
# 例: [CONTEXT] REVIEW_FILE_PATH=null → `review_file_path="null"` (literal "null" file name、Priority 0 で読み込まれる)
review_file_path="{review_file_path_from_phase_1_0_1}"
review_source=""
review_source_path=""

# review_file_path placeholder 残留の fail-fast。
# Claude が literal substitute を忘れて `{review_file_path_from_phase_1_0_1}` のまま残ると、
# `-f "{review_file_path_from_phase_1_0_1}"` 試行 → ENOENT → `explicit_file_not_found` で
# fallback に流れる誤診断を起こす (真因は substitution 忘れ)。
# 完全一致で placeholder 文字列を検出し、`{` `}` を含む legitimate path (Template 系プロジェクト
# 等で `{{var}}` を含むファイル名が作成可能) の誤検出を防ぐ。
case "$review_file_path" in
  "{review_file_path_from_phase_1_0_1}")
    echo "ERROR: review_file_path placeholder が literal substitute されていません: '$review_file_path'" >&2
    echo "  Claude は Phase 1.0.1 の [CONTEXT] REVIEW_FILE_PATH=... 値を会話コンテキストから" >&2
    echo "  読み取り、この bash block 冒頭の review_file_path=... 行を実際の値で置換する必要があります。" >&2
    echo "  substitute 値の例: __RITE_UNSET__ (default) / ./foo.json / /abs/path/bar.json" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_file_path_placeholder_residue" >&2
    echo "[fix:error]"
    exit 1
    ;;
esac

# signal-specific trap を block 冒頭で設置する (find_err tempfile の orphan 防止)。
# canonical pattern: references/bash-trap-patterns.md#signal-specific-trap-template を参照。
# Block 全体の scope を cover するため Priority 2 のネスト内ではなく block 冒頭に配置する。
#
# 旧実装の `local _saved_rc=$?; rm -f ...; return $_saved_rc` は
# 意図と実挙動が乖離していた。trap handler が `'rc=$?; _rite_fix_p120_cleanup; exit $rc'` 形式で
# 関数を呼ぶとき、関数入場時の `$?` は trap handler 内の直前 assignment `rc=$?` の exit code
# (= 0) であり、真のエラーコードは既に trap handler 側の `rc` 変数に捕捉されている。したがって
# 関数内で `$?` を保存しても常に 0 となり、`return $_saved_rc` は常に 0 を返していた (コメントと
# 実挙動の乖離)。trap handler が最終 `exit $rc` で outer rc を使うため運用上は無害だが、将来
# 関数を直接呼び出す拡張で silent regression する罠を残していた。簡素化して trap handler の
# rc 捕捉に一本化する。
find_err=""
jq_val_err_p0=""
jq_val_err_p2=""
_rite_fix_p120_cleanup() {
  rm -f "${find_err:-}" "${jq_val_err_p0:-}" "${jq_val_err_p2:-}"
}
trap 'rc=$?; _rite_fix_p120_cleanup; exit $rc' EXIT
trap '_rite_fix_p120_cleanup; exit 130' INT
trap '_rite_fix_p120_cleanup; exit 143' TERM
trap '_rite_fix_p120_cleanup; exit 129' HUP

# pipefail を有効化して pipeline 末尾以外のコマンド失敗も捕捉する
set -o pipefail

# Priority 0: Explicit --review-file (from Phase 1.0.1)
# sentinel `__RITE_UNSET__` (旧 `null` から変更) 以外で
# かつ非空の場合に Priority 0 を発火させる。`null` という literal 文字列を持つファイル名
# (`./null` ではない `null` 単独) も legitimate な path として処理される。
if [ -n "$review_file_path" ] && [ "$review_file_path" != "__RITE_UNSET__" ]; then
  if [ ! -f "$review_file_path" ]; then
    echo "エラー: --review-file で指定されたパスが存在しません: $review_file_path" >&2
    echo "[CONTEXT] REVIEW_SOURCE_MISSING=1; reason=explicit_file_not_found" >&2
    review_source="fallback"
    review_source_path=""
  elif jq_val_err_p0=$(mktemp /tmp/rite-jq-val-err-p0-XXXXXX 2>/dev/null) || true; ! jq empty "$review_file_path" 2>"${jq_val_err_p0:-/dev/null}"; then
    echo "エラー: --review-file で指定されたファイルが有効な JSON ではありません: $review_file_path" >&2
    [ -n "${jq_val_err_p0:-}" ] && [ -s "$jq_val_err_p0" ] && head -3 "$jq_val_err_p0" | sed 's/^/  /' >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_parse" >&2
    rm -f "${jq_val_err_p0:-}"
    review_source="fallback"
    review_source_path=""
  elif ! jq -e '
    (.schema_version | type == "string" and length > 0)
    and (.pr_number | type == "number")
    and (.findings | type == "array")
  ' "$review_file_path" >/dev/null 2>&1; then
    # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
    echo "エラー: --review-file の必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) が欠落: $review_file_path" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_schema_required_fields_missing" >&2
    review_source="fallback"
    review_source_path=""
  elif ! jq -e '
    (.overall_assessment != "mergeable")
    or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
  ' "$review_file_path" >/dev/null 2>&1; then
    # Cross-field invariant (review-result-schema.md): overall_assessment=="mergeable" のときは
    # CRITICAL/HIGH かつ status==open の finding が存在してはならない。違反時は手書き JSON で
    # fix ループを silent に 0 件脱出させる bypass になるため fallback 経路に route する。
    echo "エラー: --review-file の cross-field invariant 違反: overall_assessment=\"mergeable\" だが CRITICAL/HIGH で status=\"open\" の finding が存在します" >&2
    echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=mergeable_has_open_blockers" >&2
    review_source="fallback"
    review_source_path=""
  elif ! jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' "$review_file_path" >/dev/null 2>&1; then
    # overall_assessment enum validation (review-result-schema.md)
    oa_val=$(jq -r '.overall_assessment // "(null)"' "$review_file_path" 2>/dev/null)
    echo "WARNING: --review-file の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)" >&2
    echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
    review_source="fallback"
    review_source_path=""
  else
    # Priority 0: schema_version も Priority 2 と同じく検証するが、失敗時は直接 fallback へ
    # (ユーザーの明示意図を尊重 — Priority 1-3 に silent fall-through しない)
    # jq exit code を明示捕捉 (commit_sha 抽出と対称化)
    # `if ! var=$(cmd); then rc=$?` では `!` 演算子が cmd の exit code を反転するため、
    # then ブランチ内の `$?` は `!` の結果 (= 0) を返す。`if cmd; then :; else rc=$?; fi` で取得する。
    if schema_version=$(jq -r '.schema_version // "unknown"' "$review_file_path" 2>/dev/null); then
      : # jq 成功
    else
      jq_sv_rc=$?
      echo "WARNING: --review-file の schema_version 抽出で jq が失敗 (rc=$jq_sv_rc)" >&2
      echo "  原因候補: jq バイナリ異常 / OOM / ファイル IO エラー" >&2
      echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_schema_version_jq_failed; rc=$jq_sv_rc" >&2
      schema_version="unknown"
    fi
    case "$schema_version" in
      "1.0.0"|"1.0")
        # commit_sha stale detection (verified-review silent-failure C-1)
        # schema で `commit_sha` が required field として記録されているため、現 HEAD との比較で
        # stale file を検出する。mismatch 時は Priority 4 Interactive Fallback へ routing する
        # (ユーザーは「レビュー実行 / 別ファイル指定 / 中止」を選択可能)。
        # [CONTEXT] REVIEW_SOURCE_STALE=1 を emit して observability は維持する。
        # jq バイナリ異常 / I/O エラーと「.commit_sha フィールド不在 (legacy schema)」を区別する。
        # 旧実装 `2>/dev/null || echo ""` はこの 2 ケースを silent に融合させ、stale detection を silent 無効化していた。
        json_commit_sha_err=$(mktemp /tmp/rite-fix-p0-commit-sha-err-XXXXXX 2>/dev/null) || json_commit_sha_err=""
        if json_commit_sha=$(jq -r '.commit_sha // empty' "$review_file_path" 2>"${json_commit_sha_err:-/dev/null}"); then
          : # jq 成功 (空 or 非空)
        else
          jq_rc=$?
          echo "WARNING: --review-file の commit_sha 抽出で jq が失敗 (rc=$jq_rc)" >&2
          [ -n "$json_commit_sha_err" ] && [ -s "$json_commit_sha_err" ] && head -3 "$json_commit_sha_err" | sed 's/^/  /' >&2
          echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=jq_error_on_commit_sha; priority=0" >&2
          json_commit_sha=""
        fi
        [ -n "$json_commit_sha_err" ] && rm -f "$json_commit_sha_err"
        if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
          echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2
          echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=git_rev_parse_head_failed" >&2
          head_sha=""
        fi
        if [ -n "$json_commit_sha" ] && [ -n "$head_sha" ] && [ "$json_commit_sha" != "$head_sha" ]; then
          # stale file 検出時は fallback 経路に route する。旧実装は `RITE_FIX_ACKNOWLEDGE_STALE=1` 環境変数による
          # opt-in 続行経路を持っていたが、Claude Code Bash tool は呼び出し境界で env var を継承しないため
          # (anthropics/claude-code#2508)、ユーザーが env var を set する手段がなく dead code だった。
          # stale を承知で続行したいユーザーは Priority 4 Interactive fallback の「レビュー実行」or「別ファイル指定」
          # を選択する。stale な検出結果を無視したい特殊ケースは Priority 4 で「別ファイル指定」に同じ path を
          # 再入力することで実質的に対応可能 (ただし再度 stale warning が出る — 設計意図通り)。
          echo "⛔ ERROR: --review-file の commit_sha ($json_commit_sha) が現 HEAD ($head_sha) と不一致です" >&2
          echo "  このファイルは古い commit に対して生成されました。既修正項目を再指摘する可能性があります。" >&2
          echo "  対処 (いずれかを選択):" >&2
          echo "    1. /rite:pr:review を再実行して新しい review を生成する (推奨)" >&2
          echo "    2. 生成時点の commit ($json_commit_sha) に git checkout してから /rite:pr:fix を実行する" >&2
          echo "[CONTEXT] REVIEW_SOURCE_STALE=1; reason=explicit_file_commit_sha_mismatch; json_sha=$json_commit_sha; head_sha=$head_sha" >&2
          echo "  fallback 経路に route します (Priority 4 Interactive fallback)" >&2
          review_source="fallback"
          review_source_path=""
        else
          review_source="explicit_file"
          review_source_path="$review_file_path"
        fi
        ;;
      *)
        echo "エラー: --review-file で指定されたファイルの schema_version が未知です: $schema_version" >&2
        echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=explicit_file_schema_version_unknown" >&2
        review_source="fallback"
        review_source_path=""
        ;;
    esac
  fi
fi

# Priority 1: Conversation context (Claude が判断)
# ⚠️ Claude への指示: Priority 0 が未発火 (review_source="") の状態で、
# 同一 session 内の直前 assistant turn に `## 📜 rite レビュー結果` セクションを含む
# /rite:pr:review の出力が残っている場合、下記 bash block を実行する前に会話コンテキストから
# findings を読み取り、`conversation_review_decision="use"` を literal substitute すること。
# 会話コンテキストに review 結果がない場合は `conversation_review_decision="none"` を substitute する。
#
# 旧実装は noop `:` のみで、Claude が「使う」と判断したのに
# substitute を忘れた場合と「使わない」と判断した場合が区別できず silent fallthrough する穴があった。
# Priority 0/3 と対称な defensive check を追加し、literal placeholder のままなら fail-fast する。
#
# verified-review H-3 / M-2 (M6) 対応: Phase 1.2.0.1 からの retry 経由で Phase 1.2.0 を再入した場合、
# 上流の retry counter (.rite/state/fix-fallback-retry-{pr_number}.count) が >= 1 であれば、
# 前 iteration で Claude が substitute した conversation_review_decision="use" が stale
# な可能性がある (Phase 1.2.0.1 がファイルパスを変更した後、Priority 0 を再発火させたいのに
# 前回の "use" が残ったまま Priority 1 が発火して stale conversation source に silent route する
# Intent Hijack のリスク)。retry counter >= 1 の場合は Claude の substitute に関わらず強制 skip する。
if [ -z "$review_source" ]; then
  # verified-review H-3 / M-2 対応: retry counter が >= 1 の場合は Priority 1 を強制 skip する
  retry_state_file=".rite/state/fix-fallback-retry-${pr_number}.count"
  retry_current=0
  if [ -f "$retry_state_file" ]; then
    # cat の IO エラー (permission denied / inode 破損 / NFS timeout) を
    # silent に counter=0 にフォールバックさせない。
    # 真の IO エラーは「未知の状態」として safe side に倒し、retry_current を 999 にして
    # hard gate を強制発火させる (machine-enforced hard gate 原則)。
    cat_err=$(mktemp /tmp/rite-fix-retry-cat-err-XXXXXX 2>/dev/null) || cat_err=""
    if retry_raw=$(cat "$retry_state_file" 2>"${cat_err:-/dev/null}"); then
      case "$retry_raw" in
        ''|*[!0-9]*) retry_current=0 ;;
        *) retry_current=$retry_raw ;;
      esac
    else
      cat_rc=$?
      echo "WARNING: retry state file の読取に失敗 (rc=$cat_rc, path=$retry_state_file)" >&2
      if [ -n "$cat_err" ] && [ -s "$cat_err" ]; then
        head -3 "$cat_err" | sed 's/^/  /' >&2
      fi
      echo "  対処: $retry_state_file の permission / filesystem 健全性を確認してください" >&2
      echo "[CONTEXT] FIX_FALLBACK_RETRY_READ_FAILED=1; reason=state_file_read_io_error" >&2
      # IO エラーは「未知の状態」として safe side に倒す: hard gate を確実に発火させる
      retry_current=999
    fi
    [ -n "$cat_err" ] && rm -f "$cat_err"
  fi
  # 「レビュー実行」option で新鮮な review が会話コンテキストに乗った経路を識別するため、
  # Phase 1.2.0.1 Interactive fallback の「レビュー実行」ハンドラは **state file を明示 rm してから**
  # Phase 1.2 を再入する (下記 "State file cleanup on review_execute" 参照)。state file が削除されていれば
  # retry_current=0 となり Priority 1 scan が発火する。一方「ファイルパス指定」retry 経路は state file を
  # 保持したまま Phase 1.2.0 を再入するため、retry_current >= 1 で Priority 1 は強制 skip される。
  #
  # 旧実装は `RITE_FIX_P1_BYPASS_COUNTER=1` 環境変数による bypass gate を使っていたが、Claude Code Bash tool は
  # 呼び出し境界を跨いで env var を継承しないため (anthropics/claude-code#2508)、「レビュー実行」ハンドラが
  # 環境変数を set しても次の Phase 1.2 bash block には届かず、設計された silent regression になっていた。
  # state file 自体の明示削除に一元化することで、Bash tool 境界を跨いでも確実に動作する。
  if [ "$retry_current" -ge 1 ]; then
    echo "[CONTEXT] P1_SCAN_SKIPPED=1; reason=retry_re_entry; retry_count=$retry_current" >&2
  else
    # ⚠️ Claude は以下の literal を Phase 1.2 進入時の判断に基づいて substitute すること
    #   - 会話に最新の /rite:pr:review 結果あり → `conversation_review_decision="use"`
    #   - 会話に該当 review 結果なし → `conversation_review_decision="none"`
    # sentinel は `[A-Z_]` のみで構成し、bash case pattern matching の glob 特殊文字
    # (`{`, `}`, `*`, `?`, `[]`) を含まない形式とする (review_file_path sentinel と同方針)
    conversation_review_decision="__RITE_CONVERSATION_DECISION_UNSET__"
    # machine-readable receipt を必須化する。
    # Claude は substitute 時に下記 P1_SCAN_TURNS / P1_SCAN_FOUND も同時に substitute すること:
    #   - use: p1_scan_turns=<N> (scan した assistant turn 数、最低 1)、p1_scan_found="true"
    #   - none: p1_scan_turns=<N> (scan した assistant turn 数、0 以上)、p1_scan_found="false"
    # receipt 欠落 (literal placeholder 残留) は silent P1 hijack を起こすため fail-fast する。
    p1_scan_turns="__RITE_P1_SCAN_TURNS_UNSET__"
    p1_scan_found="__RITE_P1_SCAN_FOUND_UNSET__"
    case "$conversation_review_decision" in
      use)
        # receipt validation: P1_SCAN_TURNS / FOUND が literal の場合 fail-fast
        case "$p1_scan_turns" in
          __RITE_P1_SCAN_TURNS_UNSET__|"")
            echo "ERROR: Priority 1 receipt p1_scan_turns が literal substitute されていません (decision=use)" >&2
            echo "  Claude は 'use' を substitute する場合、同時に p1_scan_turns (整数) を substitute する必要があります" >&2
            echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_receipt_missing" >&2
            exit 1
            ;;
          *[!0-9]*)
            echo "ERROR: Priority 1 receipt p1_scan_turns が数値ではありません: '$p1_scan_turns'" >&2
            echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_receipt_invalid" >&2
            exit 1
            ;;
        esac
        if [ "$p1_scan_found" != "true" ]; then
          echo "ERROR: Priority 1 decision=use だが p1_scan_found!=true ('$p1_scan_found')" >&2
          echo "  Claude は conversation に review 結果を見つけた場合のみ 'use' を substitute し、同時に p1_scan_found='true' も substitute する必要があります" >&2
          echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_receipt_inconsistent" >&2
          exit 1
        fi
        review_source="conversation"
        echo "[CONTEXT] REVIEW_SOURCE=conversation; pr_number=${pr_number}; p1_scan_turns=$p1_scan_turns; p1_scan_found=$p1_scan_found" >&2
        ;;
      none)
        # decision=none でも receipt は substitute される想定 (p1_scan_found=false でよい)
        # literal 残留は observability 欠落のため WARNING のみ (fail-fast はしない)
        case "$p1_scan_turns" in
          __RITE_P1_SCAN_TURNS_UNSET__|"")
            echo "WARNING: Priority 1 decision=none だが receipt p1_scan_turns が未設定 (observability 欠落)" >&2
            ;;
          *[!0-9]*)
            echo "WARNING: Priority 1 decision=none だが p1_scan_turns が非数値 ('$p1_scan_turns')" >&2
            ;;
        esac
        # `use` branch は p1_scan_turns と p1_scan_found を
        # 両方検証し receipt 整合性で fail-fast するが、`none` branch は p1_scan_turns のみ WARNING
        # で p1_scan_found の sentinel 残留 / 不正値を一切検知しない非対称があった。cycle 8 H-3 で
        # 追加した receipt 必須化の趣旨 (Claude substitute 漏れを machine-enforced gate で検出) を
        # `none` 経路にも展開する。fail-fast はせず WARNING のみに留めるのは、decision=none は
        # legitimate な「会話コンテキストに review 結果なし」経路であり observability loss は許容
        # できるため (Priority 2 以降に fallthrough して別経路で finding を取得する)。
        case "$p1_scan_found" in
          true|false) ;;  # 正常値
          __RITE_P1_SCAN_FOUND_UNSET__|"")
            echo "WARNING: Priority 1 decision=none だが p1_scan_found が sentinel 残留/未設定 (observability 欠落)" >&2
            ;;
          *)
            echo "WARNING: Priority 1 decision=none だが p1_scan_found が不正値: '$p1_scan_found' (許容値: true / false)" >&2
            ;;
        esac
        :  # Priority 2 以降に fallthrough
        ;;
      __RITE_CONVERSATION_DECISION_UNSET__)
        # sentinel のまま → Claude が substitute を忘れた
        echo "ERROR: Priority 1 conversation_review_decision が literal substitute されていません" >&2
        echo "  Claude は会話コンテキストの review 結果有無を判断し、'use' または 'none' を substitute する必要があります" >&2
        echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_decision_unset" >&2
        exit 1
        ;;
      *)
        echo "ERROR: Priority 1 conversation_review_decision に未知の値: '$conversation_review_decision'" >&2
        echo "  許容値: use / none" >&2
        echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=priority1_decision_invalid" >&2
        exit 1
        ;;
    esac
  fi
fi

# Priority 2: Local file — lexicographic sort で最新 timestamp を選択
# ファイル名は {pr_number}-YYYYMMDDHHMMSS.json 形式で timestamp が zero-padded のため
# 文字列 sort = 時系列 sort が成立する。BSD find 非互換の -printf を回避し portable に。
#
# SIGPIPE 対策: `find | sort -r | head -1` は pipefail 有効下で
# `head -1` 早期終了により `sort` が SIGPIPE (rc=141) を受け pipeline 失敗扱いとなる
# (bash-defensive-patterns.md Pattern 5 で禁止された anti-pattern)。
# mapfile + process substitution で pipeline を分離し、配列経由で先頭要素を取得する。
if [ -z "$review_source" ]; then
  # .rite/review-results/ dir 不在を初回実行の正常経路として silent pass-through する
  # (初回 fix / fresh clone で確実に再現する UX bug の修正)。cleanup.md Phase 2.5 と対称。
  if [ ! -d .rite/review-results ]; then
    # dir 不在 = 正常経路。Priority 3 へ silent fall-through。
    :
  else
    # mktemp 失敗時も WARNING を emit (cleanup.md Phase 2.5 / Phase 6.1.a と対称化)。
    # 旧実装は `|| find_err=""` で silent fallback し、find の IO エラー詳細を失う経路があった。
    if ! find_err=$(mktemp /tmp/rite-fix-find-err-XXXXXX); then
      echo "WARNING: find stderr 退避用 tempfile の mktemp に失敗しました。find の IO エラー詳細は失われます" >&2
      echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
      echo "[CONTEXT] REVIEW_SOURCE_FIND_FAILED=1; reason=mktemp_failure_find_err" >&2
      find_err=""
    fi

    # mapfile + process substitution で SIGPIPE 経路を断ち、pipefail 下でも安全に動作する
    # sort の stderr も find_err に append して捕捉する (sort OOM / /tmp full を検出)。
    files_arr=()
    mapfile -t files_arr < <(find .rite/review-results -maxdepth 1 -type f -name "${pr_number}-*.json" 2>"${find_err:-/dev/null}" | sort -r 2>>"${find_err:-/dev/null}")
    latest_file="${files_arr[0]:-}"

    if [ -n "$find_err" ] && [ -s "$find_err" ]; then
      echo "WARNING: .rite/review-results/ 検索時にエラー発生:" >&2
      head -3 "$find_err" | sed 's/^/  /' >&2
      echo "  Priority 2 を IO エラーにより skip し、Priority 3 (PR コメント) に明示 routing します" >&2
      echo "[CONTEXT] REVIEW_SOURCE_FIND_FAILED=1; reason=local_file_find_io_error" >&2
      review_source="pr_comment"
      review_source_path=""
    fi
    # process substitution では内部コマンドの exit code が親に伝播しない。
    # ファイルが存在するのに配列が空の場合は sort/find failure を疑い WARNING を emit する。
    if [ ${#files_arr[@]} -eq 0 ] && [ -d .rite/review-results ]; then
      _p2_glob_check=(.rite/review-results/"${pr_number}"-*.json)
      if [ -e "${_p2_glob_check[0]:-}" ]; then
        echo "WARNING: .rite/review-results/ にマッチするファイルが存在しますが mapfile 結果が空です (sort/find failure の可能性)" >&2
        echo "[CONTEXT] REVIEW_SOURCE_FIND_FAILED=1; reason=sort_or_mapfile_failure" >&2
      fi
      unset _p2_glob_check
    fi
    # 旧 `[ -n "$find_err" ] && rm -f && find_err=""` の short-circuit は
    # rm 失敗時に find_err="" 代入に到達せず、後続の trap cleanup が同じ rm を再実行する重複処理になっていた
    # (実害は軽微だが、rm 失敗が silent 抑制される問題は本 PR 全体の指摘事項と矛盾する)。
    # 改行 + rm 失敗時 WARNING + find_err="" を独立 statement で実行する。
    if [ -n "$find_err" ]; then
      if ! rm -f "$find_err"; then
        echo "WARNING: find_err tempfile の削除に失敗 ($find_err)。trap cleanup が後で再試行します" >&2
      fi
      find_err=""
    fi

    # find で見つかった latest_file が -f check で脱落した経路を silent にしない。
    # permission denied / symlink 破壊 / TOCTOU で stat 不能な場合、ユーザーは Priority 3 routing 理由を debug できない。
    if [ -n "$latest_file" ] && [ ! -f "$latest_file" ]; then
      echo "WARNING: find で発見した latest_file が -f check で失敗 ($latest_file)。permission / symlink 破壊の可能性" >&2
      echo "[CONTEXT] REVIEW_SOURCE_STAT_FAILED=1; reason=latest_file_stat_failure" >&2
      # Priority 2 stat failure branch で review_source を
      # 明示 set する (他の Priority 2 failure branch 〈jq parse / schema / commit_sha mismatch〉は
      # 全て `review_source="pr_comment"; review_source_path=""` を明示 set するが、stat failure
      # のみ最終強制昇格経路に依存していた非対称を解消)。
      review_source="pr_comment"
      review_source_path=""
    fi
    if [ -z "$review_source" ] && [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
      # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
      jq_val_err_p2=$(mktemp /tmp/rite-jq-val-err-p2-XXXXXX 2>/dev/null) || jq_val_err_p2=""
      if ! jq empty "$latest_file" 2>"${jq_val_err_p2:-/dev/null}"; then
        echo "WARNING: $latest_file は有効な JSON ではありません。Priority 3 (PR コメント) に routing します。" >&2
        [ -n "${jq_val_err_p2:-}" ] && [ -s "$jq_val_err_p2" ] && head -3 "$jq_val_err_p2" | sed 's/^/  /' >&2
        echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_json_parse_failure" >&2
        # verified-review M-6 (M10) 対応: corrupted file を .corrupt-{epoch} にリネームし、
        # 次回の lexicographic sort で選ばれないようにする。旧実装は WARNING を出すだけで
        # corrupted file を残していたため、次回呼び出し時も同じファイルが最新 timestamp として
        # 選ばれ、同一 WARNING が繰り返される無限 ring を起こしていた。
        # ⚠️ corrupt file rename ロジック (Instance 1/2 — jq parse failure path)
        # 同一ロジックが下の schema_required_fields_missing path (Instance 2/2) にも複製されている。
        # 変更時は両方を同時に更新すること (ドリフト防止)。
        # mv の stderr を tempfile に退避し、失敗時に原因を可視化する。
        corrupt_epoch=$(date +%s 2>/dev/null || printf '%s-%04x' "unknown" "$((RANDOM & 0xffff))")
        corrupt_suffix=".corrupt-${corrupt_epoch}"
        mv_err=$(mktemp /tmp/rite-fix-corrupt-mv-err-XXXXXX 2>/dev/null) || mv_err=""
        if mv "$latest_file" "${latest_file}${corrupt_suffix}" 2>"${mv_err:-/dev/null}"; then
          echo "  corrupted file をリネームしました: ${latest_file}${corrupt_suffix}" >&2
          echo "  対処: 内容を確認後、手動で削除するか新しい review を生成してください" >&2
        else
          mv_rc=$?
          echo "  WARNING: corrupted file の rename に失敗 (rc=$mv_rc)。次回 fix で同じ WARNING が再発します" >&2
          if [ -n "$mv_err" ] && [ -s "$mv_err" ]; then
            echo "    詳細 (mv stderr):" >&2
            head -3 "$mv_err" | sed 's/^/      /' >&2
          fi
          echo "    対処: permission denied / read-only filesystem / cross-filesystem / target exists のいずれかを確認" >&2
          echo "    手動削除: rm \"$latest_file\"" >&2
        fi
        [ -n "$mv_err" ] && rm -f "$mv_err"
        review_source="pr_comment"
        review_source_path=""
      elif ! jq -e '
        (.schema_version | type == "string" and length > 0)
        and (.pr_number | type == "number")
        and (.findings | type == "array")
      ' "$latest_file" >/dev/null 2>&1; then
        # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
        echo "WARNING: $latest_file の必須フィールドが欠落。Priority 3 (PR コメント) に routing します。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_schema_required_fields_missing" >&2
        corrupt_epoch=$(date +%s 2>/dev/null || printf '%s-%04x' "unknown" "$((RANDOM & 0xffff))")
        corrupt_suffix=".corrupt-${corrupt_epoch}"
        mv_err=$(mktemp /tmp/rite-fix-corrupt-mv-err-XXXXXX 2>/dev/null) || mv_err=""
        if mv "$latest_file" "${latest_file}${corrupt_suffix}" 2>"${mv_err:-/dev/null}"; then
          echo "  schema-invalid file をリネームしました: ${latest_file}${corrupt_suffix}" >&2
        else
          mv_rc=$?
          echo "  WARNING: schema-invalid file の rename に失敗 (rc=$mv_rc)。次回 fix で同じ WARNING が再発します" >&2
          if [ -n "$mv_err" ] && [ -s "$mv_err" ]; then
            head -3 "$mv_err" | sed 's/^/    /' >&2
          fi
          echo "    手動削除: rm \"$latest_file\"" >&2
        fi
        [ -n "$mv_err" ] && rm -f "$mv_err"
        review_source="pr_comment"
        review_source_path=""
      elif ! jq -e '
        (.overall_assessment != "mergeable")
        or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
      ' "$latest_file" >/dev/null 2>&1; then
        # Cross-field invariant (review-result-schema.md): overall_assessment=="mergeable" のときは
        # CRITICAL/HIGH かつ status==open の finding が存在してはならない。
        # corrupt rename はしない (データは構造的に valid、ビジネスルール違反のみ)。
        echo "WARNING: $latest_file の cross-field invariant 違反 (mergeable だが open の CRITICAL/HIGH finding あり)。Priority 3 に routing します。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=local_file_cross_field_invariant_violated" >&2
        review_source="pr_comment"
        review_source_path=""
      elif ! jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' "$latest_file" >/dev/null 2>&1; then
        # overall_assessment enum validation (review-result-schema.md)
        oa_val=$(jq -r '.overall_assessment // "(null)"' "$latest_file" 2>/dev/null)
        echo "WARNING: $latest_file の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)。Priority 3 に routing します。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
        review_source="pr_comment"
        review_source_path=""
      else
        # schema_version 検証 (Priority 2 success 内で実施)
        # jq exit code を明示捕捉 (commit_sha 抽出と対称化)
        # `if ! var=$(cmd); then rc=$?` では `!` 演算子が cmd の exit code を反転するため、
        # then ブランチ内の `$?` は `!` の結果 (= 0) を返す。`if cmd; then :; else rc=$?; fi` で取得する。
        if schema_version=$(jq -r '.schema_version // "unknown"' "$latest_file" 2>/dev/null); then
          : # jq 成功
        else
          jq_sv_rc=$?
          echo "WARNING: $latest_file の schema_version 抽出で jq が失敗 (rc=$jq_sv_rc)" >&2
          echo "  原因候補: jq バイナリ異常 / OOM / ファイル IO エラー" >&2
          echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_schema_version_jq_failed; rc=$jq_sv_rc" >&2
          schema_version="unknown"
        fi
        case "$schema_version" in
          "1.0.0"|"1.0")
            # commit_sha stale detection (verified-review silent-failure C-1)
            # Priority 2 は lexicographic 最新ファイルを機械的に選ぶため、古い commit に対する
            # review 結果を silent に使用するリスクがある。現 HEAD と比較し、mismatch 時は Priority 3
            # (PR コメント) に routing する (Priority 2 の他の失敗経路と同じ扱い)。
            # 古い local file には fallback しない (Priority 2 schema doc の設計判断と整合)。
            # jq IO エラーを silent 化しない。
            json_commit_sha_err=$(mktemp /tmp/rite-fix-p2-commit-sha-err-XXXXXX 2>/dev/null) || json_commit_sha_err=""
            if json_commit_sha=$(jq -r '.commit_sha // empty' "$latest_file" 2>"${json_commit_sha_err:-/dev/null}"); then
              :
            else
              jq_rc=$?
              echo "WARNING: $latest_file の commit_sha 抽出で jq が失敗 (rc=$jq_rc)" >&2
              [ -n "$json_commit_sha_err" ] && [ -s "$json_commit_sha_err" ] && head -3 "$json_commit_sha_err" | sed 's/^/  /' >&2
              echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=jq_error_on_commit_sha; priority=2" >&2
              json_commit_sha=""
            fi
            [ -n "$json_commit_sha_err" ] && rm -f "$json_commit_sha_err"
            if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
              echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2
              echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=git_rev_parse_head_failed" >&2
              head_sha=""
            fi
            if [ -n "$json_commit_sha" ] && [ -n "$head_sha" ] && [ "$json_commit_sha" != "$head_sha" ]; then
              echo "WARNING: $latest_file の commit_sha ($json_commit_sha) が現 HEAD ($head_sha) と不一致です (stale)" >&2
              echo "  本ファイルは古い commit に対して生成されました。Priority 3 (PR コメント) に routing します。" >&2
              echo "  対処: /rite:pr:review を再実行すれば新しい timestamp + 現 HEAD の commit_sha を持つファイルが生成されます。" >&2
              echo "[CONTEXT] REVIEW_SOURCE_STALE=1; reason=local_file_commit_sha_mismatch; json_sha=$json_commit_sha; head_sha=$head_sha" >&2
              review_source="pr_comment"
              review_source_path=""
            else
              review_source="local_file"
              review_source_path="$latest_file"
              # 成功メッセージも stderr に統一する
              # ([CONTEXT] emit と stdout/stderr 規約を揃え、observability ログ専用ストリームを stderr に集約)
              echo "✅ ローカルファイルからレビュー結果を読み込みます: $latest_file" >&2
            fi
            ;;
          *)
            echo "WARNING: 未知の schema_version: $schema_version ($latest_file)" >&2
            echo "  対処: schema 定義は plugins/rite/references/review-result-schema.md を参照" >&2
            echo "  本ファイルをスキップし、次の優先順位のソース (Priority 3) を試行します。" >&2
            echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=local_file_schema_version_unknown" >&2
            # 明示的に Priority 3 (pr_comment) に routing する (dead state 防止)
            review_source="pr_comment"
            review_source_path=""
            ;;
        esac
      fi
    fi
  fi
fi

# Priority 3: PR comment (fall through to existing Broad Retrieval path if still unresolved)
if [ -z "$review_source" ]; then
  review_source="pr_comment"  # Existing Phase 1.2 Broad Retrieval / Fast Path handles this
fi

# verified-review M-1 (M3) 対応: happy path で state file を unconditional clear する。
# Priority 0-3 のいずれかが成功して review_source が fallback 以外に set された場合、
# 前セッションで Phase 1.2.0.1 が残した stale retry counter をクリーンアップする
# (count==3 で永久 block される経路を防ぐ)。fallback 経路 (review_source="fallback") では
# Phase 1.2.0.1 の retry カウンタ動作を妨げないため rm を skip する。
if [ -n "$review_source" ] && [ "$review_source" != "fallback" ]; then
  # rm 失敗を silent に握り潰さず、失敗時には retained flag を emit する (cleanup.md Phase 2.5 と対称)。
  # pr_number が空だと state_path=".rite/state/fix-fallback-retry-.count" となり、実在しないので
  # `[ -f ]` で false → silent skip する経路があった。cleanup.md Phase 2.5 の pr_number guard
  # と対称に、数値 validation で早期 fail する。
  case "$pr_number" in
    ''|*[!0-9]*)
      echo "WARNING: Phase 1.2.0 happy path cleanup: pr_number が空 or 非数値 ('$pr_number')。state file 削除を skip します" >&2
      echo "[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1; reason=invalid_pr_number_at_happy_cleanup" >&2
      ;;
    *)
      state_path=".rite/state/fix-fallback-retry-${pr_number}.count"
      if [ -f "$state_path" ]; then
        if ! rm -f "$state_path"; then
          echo "WARNING: happy path の retry state file 削除に失敗 ($state_path)" >&2
          echo "  対処: 次回 fallback 経路で stale counter により AskUserQuestion が誤動作する可能性があります。手動削除してください" >&2
          echo "[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1; reason=happy_path_rm_failure" >&2
        fi
      fi
      ;;
  esac
fi

# Priority 0/2/3/fallback の最終 review_source 値を
# machine-readable marker として emit する。旧実装は Priority 1 `use` branch のみが
# `[CONTEXT] REVIEW_SOURCE=conversation` を emit しており、他 4 経路は observability 欠落だった。
# schema.md `読取優先順位` セクションは「Phase 4.5.3 / 4.6 で `{review_source}` を log に出すため
# conversation 経由で取り込んだ場合も他の Priority と同様に provenance を残す必要がある」と
# 明記するが、実装は Priority 1 のみで契約違反。本修正で全経路に展開する。
# 対象: explicit_file (Priority 0)、conversation (Priority 1、既存 emit は残し defense-in-depth
# として後段でも emit)、local_file (Priority 2)、pr_comment (Priority 3)、fallback (Priority 0
# 失敗 → Interactive Fallback 経路)。
case "${review_source:-}" in
  explicit_file|local_file|pr_comment|conversation|fallback)
    echo "[CONTEXT] REVIEW_SOURCE=${review_source}; review_source_path=${review_source_path:-}; pr_number=${pr_number}" >&2
    ;;
  "")
    echo "ERROR: review_source が Phase 1.2.0 終了時に空です (Priority chain の設計契約違反)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_source_unset_post_chain" >&2
    exit 1
    ;;
  *)
    echo "ERROR: review_source に未知の値: '$review_source' (Priority chain の設計契約違反)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_source_invalid_post_chain" >&2
    exit 1
    ;;
esac

set +o pipefail
```

**`review_source` state transitions within pr_comment path**: `review_source="pr_comment"` に設定された後、Priority 3 処理 (下記 awk block) で (a) Raw JSON 抽出に成功した場合は `review_source` は `pr_comment` のまま維持、(b) Raw JSON が無い / schema_unknown で legacy Markdown parser に fallthrough した場合も `pr_comment` のまま。つまり Priority 3 内部での format (new / legacy) 切り替えは `review_source` では表現せず、後続 Phase は両 format を同じ code path で処理する。`review_source_path=""` は Priority 3 が PR コメント (in-memory data) を参照することを示すマーカーで、`"$review_source_path"` を読もうとする後続 code は Priority 3 で実行されない (下記 Phase 1.2.0 の `=== severity_map build (local_file/explicit_file only ...) ===` grep anchor でマーキングされた bash block の `if` 条件で local_file / explicit_file のみに限定済み。verified-review cycle 9 I-8 対応でハードコード行番号 L423 から grep anchor 参照に置換済み)。

**On Priority 0 failure** (explicit file missing/invalid/schema_unknown): `review_source="fallback"` triggers Phase 1.2.0.1 interactive fallback. Do NOT fall through to Priority 1-3 silently when `--review-file` was explicitly requested but unusable — the user's intent was to use that specific file.

**On Priority 2 success**: Skip the existing "Target Comment Fast Path" and "Broad Comment Retrieval" sub-sections below. Parse the JSON file per [review-result-schema.md](../../references/review-result-schema.md#json-schema) and construct `severity_map` directly from `findings[]`:

```bash
# Build severity_map from JSON findings array (schema_version 検証は Selection logic 内で既に完了済み)
#
# 重複 file:line 検出: jq の from_entries は同一 key を後勝ちで畳み込むため、
# (例: src/auth.ts:42 に code_quality HIGH と security CRITICAL の 2 件) では
# 後者のみを保持し前者の severity が silent に消失する (silent data loss)。
# 重複が検出された場合は WARNING を emit して可視化し、後段で人間が判断できるようにする。
# Source: jq manual (https://jqlang.github.io/jq/manual/) — from_entries duplicate key behavior
# === severity_map build (local_file/explicit_file only — referenced by pr_comment state transitions note) ===
if [ "$review_source" = "local_file" ] || [ "$review_source" = "explicit_file" ]; then
  # verified-review H-1/H-2 対応: jq の exit code を明示捕捉する。
  # 旧実装 `duplicate_keys=$(jq ...)` / `severity_map_json=$(jq -c ...)` は exit code を一切
  # check せず、jq バイナリ異常 / OOM / TOCTOU (別プロセスが file を rm / truncate) で
  # silent に空文字になっていた。重複警告が silent skip し、severity_map 構築が無音で空にな
  # る regression を防ぐため、if-else で exit code を独立 capture する。
  jq_err=$(mktemp /tmp/rite-fix-jq-err-XXXXXX 2>/dev/null) || jq_err=""

  # line フィールドの nullable sentinel 正規化
  # review-result-schema.md L92 で line は `integer | null` (null が行非依存指摘の sentinel) に変更。
  # 旧実装は `(.line | tostring)` で `null` が `"null"` 文字列に変換される (jq `tostring` の仕様) ため
  # `src/foo.ts:null` のような key が生成され、従来の `line: 0` legacy と混在すると key 衝突するリスクがあった。
  # 後方互換で `line == 0` / `line == null` の両方を `"anchor"` sentinel に正規化することで、
  # 同一ファイル複数の行非依存指摘が key 衝突で silent に畳み込まれるのを防ぐ。
  if duplicate_keys=$(jq -r '[.findings[] | (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end))] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
    if [ -n "$duplicate_keys" ]; then
      echo "WARNING: 重複 file:line を持つ finding を検出しました (severity 上書きの可能性):" >&2
      printf '%s\n' "$duplicate_keys" | sed 's/^/  - /' >&2
      echo "  jq from_entries は同一 key を後勝ちで畳み込みます。重複行に対する severity は最後の finding の値が採用されます。" >&2
      echo "  対処: review-result JSON 内の重複 file:line を手動確認してください。" >&2
    fi
  else
    jq_dup_rc=$?
    echo "WARNING: 重複 file:line 検出用 jq が失敗しました (rc=$jq_dup_rc) — silent data loss 検出を skip します" >&2
    [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | sed 's/^/  /' >&2
    echo "  影響: 同一 file:line の重複 severity 警告が出ないため、後段で最後勝ち畳み込みが silent に発生する可能性があります" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=jq_duplicate_check_failed; rc=$jq_dup_rc" >&2
    # severity_map 構築は続行する (重複警告の喪失は non-blocking 失敗として扱う)
  fi

  # duplicate_keys と同じ nullable sentinel 正規化を適用
  if severity_map_json=$(jq -c '[.findings[] | {key: (.file + ":" + (if .line == null or .line == 0 then "anchor" else (.line | tostring) end)), value: .severity}] | from_entries' "$review_source_path" 2>"${jq_err:-/dev/null}"); then
    :
  else
    jq_smap_rc=$?
    echo "ERROR: severity_map 構築用 jq が失敗しました (rc=$jq_smap_rc)" >&2
    [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | sed 's/^/  /' >&2
    echo "  対処: review-result JSON ($review_source_path) の内容と jq バイナリを確認してください" >&2
    echo "  影響: severity_map が空のまま後段に流れ、指摘 0 件と誤認される silent regression を防ぐため fail-fast します" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=severity_map_build_failed; rc=$jq_smap_rc" >&2
    [ -n "$jq_err" ] && rm -f "$jq_err"
    echo "[fix:error]"
    exit 1
  fi
  [ -n "$jq_err" ] && rm -f "$jq_err"
fi
```

**On Priority 3 (PR comment, backward-compat)**: After the existing Broad Retrieval retrieves the comment body, check for a `### 📄 Raw JSON` section with code fence. Scope the awk parser to after the `### 📄 Raw JSON` section marker so that sample JSON blocks in findings' suggestion columns (which appear earlier in the comment) are not mistakenly captured.

> **⚠️ Tempfile-based hand-off**: 下記 bash block は Phase 1.2 Broad Retrieval bash block が `/tmp/rite-fix-pr-comment-{pr_number}.txt` に書き出した PR コメント本文を `cat` で直接読み出す。旧実装は Claude が HEREDOC literal にコメント本文全体を埋め込む方式で、large multi-line text + 特殊文字 (シングルクォート / バッククォート / `$()` 等) の escape 漏れ・truncate リスクが大きかった。tempfile 経由化により Claude は path 文字列だけを literal 埋め込みすればよくなり、本文の整合性は `gh pr view --json comments | jq -r` の出力にそのまま依存する。
>
> **前提**: Phase 1.2.0 Priority 3 に到達するためには Phase 1.2 Broad Retrieval bash block が **必ず先に実行されている** こと。Claude は Priority 3 経路に進む前に Broad Retrieval bash block を呼び出す責務がある。ただし tempfile 不在は必ずしも異常ではなく、Broad Retrieval が `📜 rite レビュー結果` コメントを発見しなかった legitimate な経路 (新規 PR / `/rite:pr:review` 未実行 / コメント削除済み) も含む。下記 bash block は **tempfile 不在 = empty body (legacy fallthrough)**、**tempfile 空 = fail-fast (`comment_body_tempfile_empty`)** という非対称な扱いをする (空ファイルが作成された場合は Broad Retrieval が異常終了したか本文取得が空である異常経路のため)。

```bash
# pr_review_comment_body を tempfile から読み出す
# (旧 literal substitute hand-off 方式を廃止。Phase 1.2 Broad Retrieval bash block が
# /tmp/rite-fix-pr-comment-${pr_number}.txt に書き出している前提)
# Phase 1.2.0 全体の canonical pattern に統一: block 冒頭で pr_number を literal substitute してから
# ${pr_number} で参照する (path 内 placeholder 直埋めを排除、Claude の置換忘れを fail-fast で検出)
# verified-review cycle 15 F-6 対応: pr_comment_body_file を trap 保護する。
# Phase 1.2 Broad Retrieval が書き出した tempfile を Priority 3 block で消費するが、
# Phase 8.1 までの間に異常終了すると orphan 化する。trap で cleanup を保証する。
pr_number="{pr_number}"
pr_comment_body_file="/tmp/rite-fix-pr-comment-${pr_number}.txt"
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
    echo "      (low-probability。同一 pr_number で複数 terminal から /rite:pr:fix を実行したケース)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=comment_body_tempfile_empty" >&2
    exit 1
  fi
  # cat の exit code を明示捕捉する。
  # 旧実装 `pr_review_comment_body=$(cat "$pr_comment_body_file")` は cat の exit code を
  # 一切 check せず、permission 変更 / NFS timeout / TOCTOU truncate で silent に空文字列
  # になっていた。後段の awk parser は no-match → raw_json="" → legacy fallthrough に
  # silent 合流する。if-else で cat の exit code を独立 capture する。
  cat_err=$(mktemp /tmp/rite-fix-cat-err-XXXXXX 2>/dev/null) || cat_err=""
  if pr_review_comment_body=$(cat "$pr_comment_body_file" 2>"${cat_err:-/dev/null}"); then
    :
  else
    cat_rc=$?
    echo "WARNING: pr_comment_body_file の cat が失敗しました (rc=$cat_rc): $pr_comment_body_file" >&2
    [ -n "$cat_err" ] && [ -s "$cat_err" ] && head -3 "$cat_err" | sed 's/^/  /' >&2
    echo "  原因候補: permission 変更 / NFS timeout / TOCTOU truncate" >&2
    echo "  legacy Markdown parser に fallthrough します" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_tempfile_read_io_error; rc=$cat_rc" >&2
    pr_review_comment_body=""
  fi
  [ -n "$cat_err" ] && rm -f "$cat_err"
else
  # tempfile 不在時に [INFO] emit を追加し、以下 2 ケースを可視化する:
  #   (a) Broad Retrieval が `📜 rite レビュー結果` コメントを発見せず tempfile を作成しなかった
  #       legitimate な経路 (新規 PR / rite:pr:review 未実行 / 既に削除済み等)
  #   (b) Claude が Priority 3 進入時に Broad Retrieval bash block を skip した前提条件違反経路
  # 旧実装は (b) を検出する guard が無く silent fallthrough に落ちていた。本 [INFO] emit により、
  # Phase 1.2 Broad Retrieval が本当に実行されたかを後から trace できるようにする。
  # 機械的 enforcement (Broad Retrieval 呼出フラグの参照) は複雑で scope 外のため、
  # 最低限 observability を確保する対症療法として [INFO] を stderr に emit する。
  echo "[INFO] pr_comment_body_file 不在 → legacy Markdown parser に fallthrough ($pr_comment_body_file)" >&2
  echo "       legitimate な経路: 新規 PR / /rite:pr:review 未実行 / コメント削除済み" >&2
  echo "       もし /rite:pr:review 実行直後にこのメッセージが出た場合、Claude が Priority 3 進入前に" >&2
  echo "       Phase 1.2 Broad Retrieval bash block を呼び出し忘れた可能性があります (前提条件違反)" >&2
  echo "[CONTEXT] BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT=1" >&2
  pr_review_comment_body=""
fi

# Extract JSON from the Raw JSON section (scoped by section marker to avoid capturing
# sample JSON fences in findings' suggestion columns).
# Rationale: here-string `<<<` を使う理由 — `printf | awk` 形式は awk の `exit` による
# stdin 早期終了で printf が SIGPIPE を受ける経路がある (bash-defensive-patterns.md Pattern 5)。
#
# findings の description / suggestion 列内に
# 「### 📄 Raw JSON」リテラル文字列が含まれる場合 (本 PR 自体がまさにそういう文字列を生成する)、
# 旧実装は finding 内の literal を `### 📄 Raw JSON` 行頭マッチとして誤検出して in_section を
# 早期に立ててしまい、誤った JSON 抽出を招く。Phase 6.1.b の Raw JSON section は必ず
# `---\n\n### 📄 Raw JSON\n\n```json` の構造を持つため、`---` separator の後に出現する
# **最後** の `### 📄 Raw JSON` のみを採用する。
#
# 旧実装は「`---` 後の最初の `### 📄 Raw JSON`」で `in_section` を
# 立てる構造で、コメントと実装が乖離していた (本 PR の review.md / fix.md 自体が finding 列に
# `### 📄 Raw JSON` literal を含むため、本来の Raw JSON section より早く誤検出される反例)。
# 1-pass で末尾の section start を tracking し、END 内で逆方向スキャンして「最後」を確実に採用する。
# 以下の実装は POSIX awk のみで動作し、tac (GNU coreutils 専用) や 2-pass 読み込みを必要としない。
raw_json=$(awk '
  /^---$/ { past_separator=1; next }
  past_separator && /^### 📄 Raw JSON/ { last_section_start=NR; next }
  past_separator { lines[NR]=$0 }
  END {
    if (last_section_start > 0) {
      flag=0
      for (i = last_section_start + 1; i <= NR; i++) {
        if (lines[i] ~ /^```json$/) { flag=1; continue }
        if (flag && lines[i] ~ /^```$/) { exit }
        if (flag) print lines[i]
      }
    }
  }
' <<< "$pr_review_comment_body")
awk_rc=$?
# verified-review cycle 15 F-5 対応: awk exit code を明示検査。
# awk OOM / binary 異常で空出力が「Raw JSON section なし (legacy format)」と区別不能になり、
# legacy parser が新形式コメントを garble する silent regression を防ぐ。
if [ "$awk_rc" -ne 0 ]; then
  echo "WARNING: PR コメントからの Raw JSON 抽出 awk が失敗 (rc=$awk_rc)" >&2
  echo "  原因候補: awk バイナリ異常 / OOM (lines[] 配列が大きすぎ) / SIGPIPE" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_raw_json_awk_failed; rc=$awk_rc" >&2
  raw_json=""
fi

# 旧実装は「raw_json なし」「raw_json あるが jq empty 失敗」
# 「raw_json あるが必須 fields 欠落」の 3 ケースをまとめて else の no-op に流していた。
# raw_json="" だけが legitimate な legacy fallthrough であり、それ以外は壊れた新形式 JSON を
# 検出して WARNING + reason emit してから legacy parser に流すべき (silent regression 防止)。
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
  # jq の and / truthiness 仕様 (false / null のみ falsy) のため
  # 空文字列 schema_version や型違反の pr_number を silent pass させない明示型ガード。
  echo "WARNING: PR コメント内の Raw JSON が必須フィールドを欠いています。legacy parser に fallthrough します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_schema_required_fields_missing" >&2
elif ! printf '%s' "$raw_json" | jq -e '
  (.overall_assessment != "mergeable")
  or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
' >/dev/null 2>&1; then
  # Cross-field invariant (review-result-schema.md): overall_assessment=="mergeable" のときは
  # CRITICAL/HIGH かつ status==open の finding が存在してはならない (手書き JSON bypass 防止)。
  # Priority 0/2 と対称に独立 elif で分離し、reason code を区別する。
  echo "WARNING: PR コメント内の Raw JSON が cross-field invariant に違反しています (mergeable だが open な CRITICAL/HIGH finding あり)。legacy parser に fallthrough します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_comment_cross_field_invariant_violated" >&2
elif ! printf '%s' "$raw_json" | jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' >/dev/null 2>&1; then
  # overall_assessment enum validation (review-result-schema.md)
  oa_val=$(printf '%s' "$raw_json" | jq -r '.overall_assessment // "(null)"' 2>/dev/null)
  echo "WARNING: PR コメント内の Raw JSON の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)。legacy parser に fallthrough します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
else
  # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
  # jq exit code を明示捕捉 (Priority 0/2 の commit_sha 抽出と対称化)
  # `if ! var=$(cmd); then rc=$?` では `!` 演算子が cmd の exit code を反転するため、
  # then ブランチ内の `$?` は `!` の結果 (= 0) を返す。cmd 自身の非 0 exit code を
  # 取得するには `if cmd; then :; else rc=$?; fi` 形式を使う。
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
    "1.0.0"|"1.0")
      # commit_sha stale detection (verified-review silent-failure C-1)
      # Priority 3 Raw JSON も Priority 0/2 と同じ guard を適用する。
      # mismatch 時は WARNING のみで continue する (PR コメントは最新の push 後に投稿される
      # 可能性が高く、legacy Markdown parser への fallthrough はむしろ情報損失になるため)。
      # jq IO エラーを silent 化しない。
      json_commit_sha_err=$(mktemp /tmp/rite-fix-p3-commit-sha-err-XXXXXX 2>/dev/null) || json_commit_sha_err=""
      if json_commit_sha=$(printf '%s' "$raw_json" | jq -r '.commit_sha // empty' 2>"${json_commit_sha_err:-/dev/null}"); then
        :
      else
        jq_rc=$?
        echo "WARNING: PR コメント内 Raw JSON の commit_sha 抽出で jq が失敗 (rc=$jq_rc)" >&2
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
        echo "  対処: /rite:pr:review を再実行して PR コメントを更新してください。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_STALE=1; reason=pr_comment_commit_sha_mismatch; json_sha=$json_commit_sha; head_sha=$head_sha" >&2
      fi
      # jq exit code を明示捕捉する。
      # 旧実装は `severity_map_json=$(printf | jq -c ...)` で jq の exit code を一切 check せず、
      # 失敗時は severity_map_json="" のまま後段に流れ「0 件で正常終了」に見える silent regression
      # を起こしていた。if-else で exit code を独立 capture し、失敗時は明示 fallthrough する
      # (legacy Markdown parser に flow を移す — review_source は pr_comment のまま維持)。
      p3_jq_err=$(mktemp /tmp/rite-fix-p3-smap-err-XXXXXX 2>/dev/null) || p3_jq_err=""
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
      [ -n "$p3_jq_err" ] && rm -f "$p3_jq_err"
      ;;
    *)
      echo "WARNING: PR コメント内の Raw JSON schema_version が未知: $schema_version" >&2
      echo "  legacy Markdown table parsing に fallthrough します。" >&2
      echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=pr_comment_schema_version_unknown" >&2
      # Legacy Markdown table parser (Phase 1.2.1) に fallthrough
      ;;
  esac
fi
```

**Retain in context**: `{review_source}` (`explicit_file` / `conversation` / `local_file` / `pr_comment` / `fallback`) is used by later phases to log provenance in the fix commit message and work memory.

#### 1.2.0.1 Interactive Fallback (when all sources missing — #443) <!-- AC-6 -->

> **Acceptance Criteria anchor**: AC-6 (全ソース欠落時に `AskUserQuestion` で「レビュー実行 / ファイルパス指定 / 中止」を提示。ファイルパス指定は最大 3 回リトライ、state file による hard gate で強制終了)。

When `{review_source}=fallback` (all Priority 0-3 sources unavailable or invalid), present a 3-option interactive prompt via `AskUserQuestion`:

```
レビュー結果が見つかりませんでした
  会話コンテキスト: なし
  ローカルファイル: .rite/review-results/{pr_number}-*.json なし
  PR コメント: 該当なし

どうしますか？

オプション:
- レビュー実行: /rite:pr:review を起動してレビュー結果を生成する
- ファイルパス指定: 既存の JSON ファイルパスを入力する (Other で自由入力)
- 中止: /rite:pr:fix の処理を終了する
```

**Per-option behavior**:

| User Choice | Action |
|-------------|--------|
| **レビュー実行** (Recommended) | **State file を削除してから** `skill: "rite:pr:review", args: "{pr_number}"` を invoke し、Phase 1.2 を再入する。state file を削除することで retry counter が 0 に戻り、Priority 1 の conversation context scan が発火する (下記 "State file cleanup on review_execute" の bash block 参照) |
| **ファイルパス指定** | Re-run Phase 1.2.0 Priority 0 with the user-provided path. If invalid, re-prompt (max 3 attempts, hard gate enforced via state file). state file は保持したまま Phase 1.2.0 を再入するため、retry_current >= 1 で Priority 1 scan は自動的に skip される |
| **中止** | Emit `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_cancelled`, then output `[fix:error]` result pattern and terminate. Do NOT invoke any Phase 2+ logic |

**State file cleanup on review_execute** (「レビュー実行」option 選択時の必須 bash 実装):

```bash
# 「レビュー実行」option 選択時: state file を明示削除してから Phase 1.2 を再入する。
# これにより next Phase 1.2 bash block の retry_current が 0 になり、Priority 1 scan が発火する。
pr_number="{pr_number}"
if ! rm -f ".rite/state/fix-fallback-retry-${pr_number}.count"; then
  echo "WARNING: retry counter state file の削除に失敗: .rite/state/fix-fallback-retry-${pr_number}.count" >&2
  echo "  影響: Priority 1 scan が強制 skip される可能性があります" >&2
fi
echo "ℹ️  retry counter state file を削除しました。/rite:pr:review を起動して新しいレビューを生成します" >&2
# この後 Claude は `skill: "rite:pr:review", args: "{pr_number}"` を invoke し、
# 完了後に Phase 1.2 を最初から再入する (Priority 1 で新鮮な conversation review を採用)。
```

**Retry cap for ファイルパス指定**: **最大 3 回まで AskUserQuestion が発火する** (1 回目, 2 回目, 3 回目)。3 回目の応答も invalid だった場合、4 回目の AskUserQuestion は発火せず、`[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_file_path_retries` を emit して `[fix:error]` で terminate する。retry counter は **state file** (`.rite/state/fix-fallback-retry-{pr_number}.count`) で管理し、Claude の自然言語判断に依存しない machine-enforced hard gate として動作する。

> **数え方の正規化**: bash gate (下記) は `current >= 3` で fail する。AskUserQuestion 発火直前に `current` を increment するため、increment 後の値が「これから発火する回数」を表す。`current=0` → increment → `current=1` → 1 回目発火 → `current=1` → increment → `current=2` → 2 回目発火 → `current=2` → increment → `current=3` → 3 回目発火 → `current=3` で 4 回目の gate check が fail。すなわち AskUserQuestion 発火は最大 3 回まで。

**⚠️ Retry counter hard gate — 機械的強制ルール** (state file 方式):

Claude の自然言語判断 / 会話履歴 grep に依存すると、長 context での history truncation / hallucination で無限ループ化するリスクがある。本仕様では retry counter を **ローカル state file** に persistent 保存し、bash レベルで hard gate を強制する。

**State file path**: `.rite/state/fix-fallback-retry-{pr_number}.count` ({pr_number} は Phase 1.0 で正規化済み)

> **State file path は固定** (`fix-fallback-retry-${pr_number}.count`、PID suffix なし)。
>
> **背景**: 過去の cycle では「並列 fix race 回避」のため `$$` (bash PID) を suffix に追加していたが、Claude Code Bash tool は各呼び出しで別の bash プロセスを起動する (実証: `echo $$` を 3 回連続呼出 → PID が毎回異なる)。`$$` を含む path では retry 毎に別ファイルを参照し counter が永遠に 1 止まりで hard gate が機能しなかった。並列 race については単一 session 内では Bash tool 呼び出しが逐次実行されるため発生しない (sprint team-execute でも同一 issue を 2 セッションで並列実装することはない)。万一の race 懸念は別 Issue で `mkdir` ロック等の defense-in-depth で対応する。

> **⚠️ Counter semantics — Priority 0 と Priority 4 の共有** (verified-review M-2 / M4 対応):
>
> 本 state file (`fix-fallback-retry-{pr_number}.count`) の counter は **Priority 0 の明示失敗** と **Priority 4 の interactive fallback** で共有される。これは意図的な設計で、両者は「user が valid review path を提供できなかった」という同一の UX 状態を表現する:
>
> - `/rite:pr:fix --review-file a.json` (invalid) → Priority 0 fail → Phase 1.2.0.1 interactive fallback → 「ファイルパス指定」→ b.json (invalid) → retry 1 → c.json (invalid) → retry 2 → ...
>
> この経路で counter は 0 → 1 → 2 → 3 と incrementate され、3 で hard gate が発火する。Priority 0 の初回失敗は counter を increment せず (Phase 1.2.0.1 に routing されるだけ)、Phase 1.2.0.1 の retry 発火時にのみ increment される。つまり「Priority 0 失敗 + Phase 1.2.0.1 で 3 回失敗 = 合計 4 回の path 試行」が上限となる (Priority 0 の 1 回はカウント対象外)。
>
> 別 counter に分ける選択肢 (例: `explicit.count` / `interactive.count`) も検討したが、(a) UX 的には同一の「user がファイルパスを提供する試行」であり分ける必要性が薄い、(b) 分けると lifecycle 管理と state file 命名が複雑化する、(c) 別分岐 retry は Priority 0 初回失敗後に「Priority 0 でも Priority 4 でも counter が incrementate される」とは限らないため既存ユーザーの混乱を招く、という理由で共有を選択した。

**State file lifecycle**:

- **作成**: 「ファイルパス指定」option が初めて選択された時点で `mkdir -p .rite/state && echo 0 > "$state_file"`
- **増分**: AskUserQuestion 呼び出し**前**に `current=$(cat ...); echo $((current + 1)) > $state_file`
- **読み出し**: 上記増分前に、cat の **exit code を明示 check して IO エラーとファイル不在を区別** する。cat 成功時は `current=<read value>`、IO エラー時は `current=999` (safe side = hard gate を確実発火、verified-review cycle 9 C-2 対応)、ファイル不在 (初回) は `current=0`。詳細は下記 bash gate 参照 (Priority 1 skip の I-1 pattern と対称)
- **削除**: Phase 2+ 進入時 / `[fix:error]` 出力前 / fix loop 終了時 / **AskUserQuestion runtime error 時** (cycle 10 S-3 対応、下記「AskUserQuestion failure / abort 経路の state cleanup」参照) のいずれかで `rm -f "$state_file"`

**AskUserQuestion failure / abort 経路の state cleanup**:

AskUserQuestion 自体が runtime error / signal 中断した場合の retry counter state file は、次回 `/rite:pr:fix` 起動時に残留していても hard gate が自動的に発火する方向 (counter >= 3) にしか作用しない。つまり「orphan state file が次回実行で hard gate を skip させる silent regression」は原理的に発生しない (counter は monotonic に増加するのみ)。したがって Phase 1.2.0.1 に独立した trap cleanup は設けない — 状態遷移が不明瞭になり hard gate を誤破壊するリスクの方が高いため。

正常経路での state file 削除は以下の 3 箇所に一元化される:
1. 「ファイルパス指定」retry が成功した時点 (下記「State file cleanup on success」参照)
2. 「中止」option が選択された時点 (下記「中止 option の bash 実装」参照)
3. hard gate が発火 (counter >= 3) した時点 (下記 bash gate 参照)

**1. AskUserQuestion 呼び出し前の必須 bash gate**: 「ファイルパス指定」retry を実行する際、`AskUserQuestion` を呼び出す**直前**に必ず以下の bash を実行する:

```bash
# Retry hard gate: state file による machine-enforced 強制
# state file は specific path (pr_number suffix 必須、wildcard glob 禁止)
# pr_number は Claude が Phase 1.0 の値で literal substitute する。block 冒頭で束縛することで、
# 後続の参照が `${pr_number}` 形式に統一され、placeholder 残留 silent bug を防ぐ。
pr_number="{pr_number}"
state_dir=".rite/state"
# state_file の path は固定 (PID suffix なし)。Claude Code Bash tool は各呼び出しで別 bash
# プロセスを起動するため、PID suffix を入れると retry 毎に別ファイルを参照し counter が
# 永遠に 1 止まりで hard gate が機能しない。並列 race については単一 session 内では Bash
# tool 呼び出しが逐次実行されるため発生しない。
state_file="${state_dir}/fix-fallback-retry-${pr_number}.count"
mkdir_err=$(mktemp /tmp/rite-fix-p1201-mkdir-err-XXXXXX 2>/dev/null) || mkdir_err=""
if ! mkdir -p "$state_dir" 2>"${mkdir_err:-/dev/null}"; then
  echo "ERROR: $state_dir の作成に失敗しました" >&2
  if [ -n "$mkdir_err" ] && [ -s "$mkdir_err" ]; then
    head -3 "$mkdir_err" | sed 's/^/  /' >&2
  fi
  echo "  対処: permission denied / read-only filesystem / .rite が通常ファイルでないか確認してください" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=state_dir_mkdir_failed" >&2
  [ -n "$mkdir_err" ] && rm -f "$mkdir_err"
  echo "[fix:error]"
  exit 1
fi
[ -n "$mkdir_err" ] && rm -f "$mkdir_err"

# cat の exit code を明示 check することで、IO エラー (permission denied / NFS timeout / inode 破損 等)
# を silent に `current=0` に倒す silent regression を防ぐ。Phase 1.2.0 Priority 1 の retry_state_file
# 読取ブロック (IO エラー時 `retry_current=999` で safe-side 倒し) と対称に、IO エラー時は `current=999`
# で hard gate を確実発火させる。
cat_err=$(mktemp /tmp/rite-fix-p1201-cat-err-XXXXXX 2>/dev/null) || cat_err=""
if [ -f "$state_file" ]; then
  if current=$(cat "$state_file" 2>"${cat_err:-/dev/null}"); then
    # cat 成功: 数値 validation (state file 改竄 / 異常値の防御)
    case "$current" in
      ''|*[!0-9]*) current=0 ;;
    esac
  else
    cat_rc=$?
    echo "ERROR: retry state file の読取に失敗 (rc=$cat_rc)" >&2
    if [ -n "$cat_err" ] && [ -s "$cat_err" ]; then
      echo "  詳細 (cat stderr):" >&2
      head -3 "$cat_err" | sed 's/^/  /' >&2
    fi
    echo "  影響: safe side に倒して hard gate を確実発火させます (counter=999)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=state_file_read_io_error_gate" >&2
    current=999  # safe side: hard gate を確実発火 (Priority 1 skip I-1 と対称)
  fi
else
  # 初回実行 (ファイル不在) は legitimate な 0 開始
  current=0
fi
[ -n "$cat_err" ] && rm -f "$cat_err"

if [ "$current" -ge 3 ]; then
  echo "エラー: ファイルパス指定のリトライが 3 回続けて失敗しました" >&2
  echo "  [CONTEXT] retry counter=$current/3 (state file: $state_file)" >&2
  echo "" >&2
  echo "次の対処を検討してください:" >&2
  echo "  1. /rite:pr:review を実行してローカル JSON を新規生成する (recommended)" >&2
  echo "  2. .rite/review-results/ ディレクトリに既存ファイルが存在するか確認する:" >&2
  echo "       ls -la .rite/review-results/${pr_number}-*.json" >&2
  echo "  3. 既存 JSON の必須フィールド (schema_version, pr_number, findings) をエディタで検証する" >&2
  echo "  4. schema 定義を参照する: plugins/rite/references/review-result-schema.md" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_file_path_retries" >&2
  # rm 失敗を可視化 (旧実装は silent)。
  # Phase 1.2.0 happy path state file rm (I-2 対応) と対称化する。失敗時は
  # retained flag を追加 emit し、state file が counter=3 のまま残留する silent 経路を防ぐ。
  # Non-blocking Contract 準拠: rm 失敗でも `[fix:error]` は既に emit 済みなので hard exit は継続。
  if ! rm -f "$state_file"; then
    echo "WARNING: hard gate 発火後の state file 削除に失敗: $state_file" >&2
    echo "  影響: 次回 fix 起動時に stale counter=3 が残留し Priority 1 skip が発動し続ける可能性があります" >&2
    echo "  手動削除: rm \"$state_file\"" >&2
    echo "[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1; reason=hard_gate_rm_failure" >&2
  fi
  echo "[fix:error]"
  exit 1
fi

new_count=$((current + 1))
echo "$new_count" > "$state_file" || {
  echo "ERROR: state file への書き込みに失敗 (disk full / permission)" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=state_file_write_failed" >&2
  echo "[fix:error]"
  exit 1
}
echo "[CONTEXT] FIX_FALLBACK_RETRY=$new_count/3" >&2
```

**2. Phase 2+ 進入禁止**: retry_count >= 3 で `[fix:error]` が emit された時点で Claude は **以降の Phase (Phase 2 Categorization, Phase 3 Commit, Phase 4 Report) への bash tool 呼び出しを一切行ってはならない**。これは bash の `exit 1` と state file による機械的強制ルールであり、自然言語判断による例外を認めない。

**3. State file cleanup on success**: 「ファイルパス指定」が成功 (= valid JSON file が見つかり Phase 1.2.0 Priority 0 が成功) した時点で:

```bash
pr_number="{pr_number}"
# 成功時 cleanup の rm 失敗を可視化 (I-2 と対称化)。
# 旧実装は silent で、失敗時に次回 fix が起動した時点で stale counter が残留し Priority 1 skip が
# 誤発動する経路があった。
if ! rm -f ".rite/state/fix-fallback-retry-${pr_number}.count"; then
  echo "WARNING: 成功時 cleanup の state file 削除に失敗: .rite/state/fix-fallback-retry-${pr_number}.count" >&2
  echo "  影響: 次回 fix 起動時に stale counter が残留し Priority 1 skip が誤発動する可能性があります" >&2
  echo "  手動削除: rm \".rite/state/fix-fallback-retry-${pr_number}.count\"" >&2
  echo "[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1; reason=success_cleanup_rm_failure" >&2
fi
```

これにより次回の Interactive Fallback 起動時に counter が clean state から始まる。

**「中止」option の bash 実装**: 「中止」が選択された場合は以下を実行する (silent regression 防止 — Phase 8.1 評価順 1 で `[fix:error]` に昇格させる):

```bash
pr_number="{pr_number}"
echo "ユーザーが Interactive Fallback で「中止」を選択しました" >&2
echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_cancelled" >&2
# 中止時 cleanup の rm 失敗を可視化 (I-2 と対称化)。
if ! rm -f ".rite/state/fix-fallback-retry-${pr_number}.count"; then
  echo "WARNING: 中止時 cleanup の state file 削除に失敗: .rite/state/fix-fallback-retry-${pr_number}.count" >&2
  echo "[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1; reason=user_cancel_rm_failure" >&2
fi
echo "[fix:error]"
exit 1
```

**Phase 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons** (reason table drift prevention — see [distributed-fix-drift-check](../../hooks/scripts/distributed-fix-drift-check.sh) Pattern-2 / Pattern-5):

| reason | Description |
|--------|-------------|
| `explicit_file_not_found` | `--review-file` で指定されたパスが存在しない (Priority 0, triggers fallback) |
| `explicit_file_parse` | `--review-file` で指定されたファイルが valid JSON ではない (Priority 0, triggers fallback) |
| `explicit_file_schema_required_fields_missing` | `--review-file` で指定されたファイルが parse 可能だが必須フィールド (schema_version / pr_number / findings[] 配列型) が欠落 (Priority 0, triggers fallback) |
| `mergeable_has_open_blockers` | Priority 0 で指定されたファイルの cross-field invariant 違反: `overall_assessment=="mergeable"` だが CRITICAL/HIGH かつ status==open の finding が存在 (Priority 0, `REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED` flag, triggers fallback) |
| `overall_assessment_unknown_value` | Priority 0/2/3 で `overall_assessment` が受理値 (`mergeable` / `fix-needed`) 以外 (review-result-schema.md enum 違反、`REVIEW_SOURCE_ENUM_UNKNOWN` flag。P0: fallback、P2: Priority 3 routing、P3: legacy parser fallthrough) |
| `explicit_file_schema_version_unknown` | `--review-file` で指定されたファイルの schema_version が未知 (Priority 0, triggers fallback) |
| `local_file_json_parse_failure` | Priority 2 で選ばれた最新 local file が `jq empty` で syntax invalid (Priority 3 pr_comment へ routing) |
| `local_file_schema_required_fields_missing` | Priority 2 で選ばれた最新 local file が parse 可能だが必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) が欠落 (Priority 3 pr_comment へ routing) |
| `local_file_cross_field_invariant_violated` | Priority 2 で選ばれた最新 local file の cross-field invariant 違反: `overall_assessment=="mergeable"` だが CRITICAL/HIGH かつ status==open の finding が存在 (Priority 3 pr_comment へ routing、`REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED` flag) |
| `sort_or_mapfile_failure` | Priority 2 の `find ... | sort -r` pipeline が process substitution 内で失敗 (OOM / IO エラー、`REVIEW_SOURCE_FIND_FAILED` flag) |
| `local_file_schema_version_unknown` | Priority 2 で選ばれた最新 local file の schema_version が未知 (Priority 3 pr_comment へ routing) |
| `pr_comment_raw_json_parse_failure` | Priority 3 で取得した PR コメント Raw JSON が `jq empty` で syntax invalid (legacy Markdown parser へ fallthrough) |
| `pr_comment_raw_json_awk_failed` | Priority 3 で PR コメントからの Raw JSON 抽出 awk が失敗 (rc 非 0、`REVIEW_SOURCE_PARSE_FAILED` flag、legacy Markdown parser へ fallthrough) |
| `pr_comment_schema_required_fields_missing` | Priority 3 で取得した PR コメント Raw JSON が parse 可能だが必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) が欠落 (legacy Markdown parser へ fallthrough) |
| `pr_comment_cross_field_invariant_violated` | Priority 3 で取得した PR コメント Raw JSON の cross-field invariant 違反: `overall_assessment=="mergeable"` だが CRITICAL/HIGH かつ status==open の finding が存在 (legacy Markdown parser へ fallthrough、`REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED` flag) |
| `pr_comment_schema_version_unknown` | Priority 3 で取得した PR コメント Raw JSON の schema_version が未知 (legacy Markdown parser へ fallthrough) |
| `user_file_path_retries` | Interactive fallback の「ファイルパス指定」が 3 回連続で失敗 (terminate with `[fix:error]`) |
| `user_cancelled` | Interactive fallback で「中止」option が選択された (Phase 8.1 評価順 1 で `[fix:error]` に昇格) |
| `state_dir_mkdir_failed` | retry hard gate state directory `.rite/state/` の作成失敗 (permission denied / read-only filesystem) |
| `state_file_write_failed` | retry hard gate state file への書き込み失敗 (disk full / permission denied) |
| `state_file_read_io_error_gate` | Phase 1.2.0.1 retry hard gate の state file 読取が IO エラーで失敗 (permission denied / NFS timeout / inode 破損 等)。safe side に倒して counter=999 で hard gate を確実発火させる (verified-review cycle 9 C-2 対応、Priority 1 skip の I-1 pattern と対称) |
| `review_source_unset_post_chain` | Phase 1.2.0 Priority chain 終了時に `review_source` が空 (未設定) のまま block 末尾に到達 (verified-review cycle 9 I-1 対応、設計契約違反、Priority chain の routing bug) |
| `review_source_invalid_post_chain` | Phase 1.2.0 Priority chain 終了時に `review_source` に未知の値が設定されている (verified-review cycle 9 I-1 対応、許容値: `explicit_file` / `conversation` / `local_file` / `pr_comment` / `fallback`) |
| `invalid_pr_number_at_happy_cleanup` | Phase 1.2.0 happy path state cleanup 時に pr_number が空 / 非数値 (verified-review cycle 9 M-3 対応、cleanup.md Phase 2.5 numeric guard と対称、`[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1` flag を併設) |
| `hard_gate_rm_failure` | Phase 1.2.0.1 retry hard gate 発火後の state file `rm -f` が失敗 (verified-review cycle 9 I-5 対応、`[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1` flag を併設、stale counter=3 残留のリスクを WARNING で可視化) |
| `success_cleanup_rm_failure` | Phase 1.2.0.1 ファイルパス指定成功時 state file `rm -f` が失敗 (verified-review cycle 9 I-5 対応、`[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1` flag を併設、stale state 残留のリスクを WARNING で可視化) |
| `user_cancel_rm_failure` | Phase 1.2.0.1 中止選択時 state file `rm -f` が失敗 (verified-review cycle 9 I-5 対応、`[CONTEXT] FIX_FALLBACK_STATE_CLEAR_FAILED=1` flag を併設) |
| `review_file_path_empty_value` | Phase 1.0.1 で値を持たない `--review-file` が指定された。Pattern 1 (equals style: `--review-file=`) と Pattern 2 (space style: `--review-file <末尾>`) の両方で検出される。`flag_style=equals` / `flag_style=space` として retained flag に付記される |
| `comment_body_tempfile_empty` | Phase 1.2.0 Priority 3 で `/tmp/rite-fix-pr-comment-{pr_number}.txt` が存在するが空 (Broad Retrieval が異常終了したか PR コメント本文が完全に空) |
| `bash_version_incompatible` | Prerequisites の `command -v mapfile` チェックが失敗 (bash 3.2 等の旧バージョン) |
| `priority1_decision_unset` | Phase 1.2.0 Priority 1 で `conversation_review_decision` が literal substitute されていない (silent fallthrough 防止) |
| `priority1_decision_invalid` | Phase 1.2.0 Priority 1 で `conversation_review_decision` に許容値 (`use` / `none`) 以外が指定された |
| `priority1_receipt_missing` | Phase 1.2.0 Priority 1 で decision=use だが machine-readable receipt (`p1_scan_turns`) が literal substitute されていない (verified-review H-3 対応) |
| `priority1_receipt_invalid` | Phase 1.2.0 Priority 1 で `p1_scan_turns` が数値ではない (verified-review H-3 対応) |
| `priority1_receipt_inconsistent` | Phase 1.2.0 Priority 1 で decision=use だが `p1_scan_found != "true"` (receipt 整合性違反、verified-review H-3 対応) |
| `explicit_file_commit_sha_mismatch` | Priority 0 で指定された file の `commit_sha` が現 HEAD と不一致 (stale detection、Priority 4 Interactive Fallback へ routing) |
| `local_file_commit_sha_mismatch` | Priority 2 で選ばれた最新 local file の `commit_sha` が現 HEAD と不一致 (stale detection、Priority 3 へ routing) |
| `pr_comment_commit_sha_mismatch` | Priority 3 の PR コメント Raw JSON の `commit_sha` が現 HEAD と不一致 (stale detection、WARNING のみで continue) |
| `jq_error_on_commit_sha` | Priority 0/2/3 の `.commit_sha` 抽出 jq が IO/binary エラーで失敗 (I-4 対応。stale detection 無効化を silent にしない。`priority=0|2|3` として retained flag に付記される) |
| `local_file_find_io_error` | Priority 2 の `find .rite/review-results/` が IO エラーで failed (L-3 対応) |
| `mktemp_failure_find_err` | Priority 2 の find stderr 退避用 tempfile の mktemp が失敗 (C-5 対応、cleanup.md Phase 2.5 と対称) |
| `latest_file_stat_failure` | Priority 2 で find が見つけた `latest_file` が `-f` check で脱落 (M-4 対応、permission denied / symlink 破壊) |
| `state_file_read_io_error` | Phase 1.2.0 Priority 1 の retry state file `cat` が IO エラーで失敗 (I-1 対応、hard gate を safe side に倒すため `retry_current=999`) |
| `happy_path_rm_failure` | Phase 1.2.0 happy path の retry state file 削除が失敗 (I-2 対応、cleanup.md Phase 2.5 と対称) |
| `retry_re_entry` | Phase 1.2.0 Priority 1 が retry counter >= 1 のため強制 skip された (verified-review H-3 / M-2 対応、stale conversation source の silent route を防ぐ。`P1_SCAN_SKIPPED` flag 専用の reason で fix loop を中断しない) |
| `jq_duplicate_check_failed` | Priority 0/2 で重複 file:line 検出用 jq が失敗 (cycle 8 H-1 対応、silent data loss 検出を skip、非ブロッキング) |
| `severity_map_build_failed` | Priority 0/2 で severity_map 構築用 jq が失敗 (cycle 8 H-2 対応、0 件で正常終了する silent regression 防止、`[fix:error]` 昇格) |
| `pr_comment_severity_map_build_failed` | Priority 3 で PR コメント Raw JSON からの severity_map 構築用 jq が失敗 (cycle 8 H-3 対応、legacy Markdown parser へ fallthrough) |
| `pr_comment_tempfile_read_io_error` | Priority 3 で `pr_comment_body_file` の cat が IO エラーで失敗 (cycle 8 M-3 対応、permission 変更 / NFS timeout / TOCTOU truncate) |
| `review_file_path_placeholder_residue` | Priority 0 で `review_file_path="{review_file_path_from_phase_1_0_1}"` placeholder が literal substitute されていない (cycle 8 M-7 対応、fail-fast) |
| `pr_number_placeholder_residue` | Phase 1.2.0 冒頭の `pr_number="{pr_number}"` literal substitute が忘れられ、数値以外 (空文字 / placeholder 残留) のまま bash block に入った (cycle 10 I-B 対応、cleanup.md Phase 2.5 / review.md Phase 6.1.a と対称化、`[fix:error]` 昇格) |

**Eval-order enumeration** (for Pattern-5 drift check): 本 enumeration は Pattern-5 drift check の **唯一の入力源** であり、上の Phase 1.2.0 / 1.2.0.1 reason 表と必ず同期させること。reason を追加・削除する際は表と本 enumeration の両方を同時に更新する。emit reasons sequence = (`bash_version_incompatible` / `pr_number_placeholder_residue` / `explicit_file_not_found` / `explicit_file_parse` / `explicit_file_schema_required_fields_missing` / `mergeable_has_open_blockers` / `overall_assessment_unknown_value` / `explicit_file_schema_version_unknown` / `priority1_decision_unset` / `priority1_decision_invalid` / `priority1_receipt_missing` / `priority1_receipt_invalid` / `priority1_receipt_inconsistent` / `sort_or_mapfile_failure` / `local_file_json_parse_failure` / `local_file_schema_required_fields_missing` / `local_file_cross_field_invariant_violated` / `local_file_schema_version_unknown` / `pr_comment_raw_json_awk_failed` / `pr_comment_raw_json_parse_failure` / `pr_comment_schema_required_fields_missing` / `pr_comment_cross_field_invariant_violated` / `pr_comment_schema_version_unknown` / `user_file_path_retries` / `user_cancelled` / `state_dir_mkdir_failed` / `state_file_write_failed` / `state_file_read_io_error_gate` / `review_source_unset_post_chain` / `review_source_invalid_post_chain` / `invalid_pr_number_at_happy_cleanup` / `hard_gate_rm_failure` / `success_cleanup_rm_failure` / `user_cancel_rm_failure` / `review_file_path_empty_value` / `comment_body_tempfile_empty` / `explicit_file_commit_sha_mismatch` / `local_file_commit_sha_mismatch` / `pr_comment_commit_sha_mismatch` / `jq_error_on_commit_sha` / `local_file_find_io_error` / `mktemp_failure_find_err` / `latest_file_stat_failure` / `state_file_read_io_error` / `happy_path_rm_failure` / `retry_re_entry` / `jq_duplicate_check_failed` / `severity_map_build_failed` / `pr_comment_severity_map_build_failed` / `pr_comment_tempfile_read_io_error` / `review_file_path_placeholder_residue`)

#### Legacy Branching (PR Comment Path Only)

> **Execution condition**: The sub-sections below (Target Comment Fast Path / Broad Comment Retrieval) execute **only** when `{review_source}=pr_comment`. When `{review_source}` is `local_file`, `explicit_file`, or `conversation`, skip directly to Phase 1.3.

**Branch by `{target_comment_id}`** (set in Phase 1.0): the Legacy Branching (PR Comment Path Only) section has two execution paths depending on whether a comment URL was passed. The sub-sections below (Target Comment Fast Path / Broad Comment Retrieval) are **h4-level branches within the Legacy Branching section** and are independent execution paths — they are **not** numbered sub-phases of Phase 1.2.1. The existing `### 1.2.1 Retrieve rite Review Results` is a separate, h3-level sub-phase that runs only when the Broad Comment Retrieval path is taken (i.e. when `{target_comment_id}` is NOT set).

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
> 3. Parsing rule / best-effort parse が完了したあと、**Phase 1.5 (Fast Path Handoff File Cleanup) で下記の明示的 cleanup bash block を必ず実行する** (prose 指示ではなく実装ブロックとして存在する)。Phase 1.5 は Phase 1 の最終サブフェーズとして独立に実行され、Phase 2 遷移直前のタイミングで発火する。削除対象は specific path (`{pr_number}-{target_comment_id}` suffix 付き) のみとし、wildcard glob は**絶対に使わない** (並列 fix 実行時に他セッションの一時ファイルを silent に消す事故を防ぐ):
>    ```bash
>    # Phase 1.5 (Fast Path Handoff File Cleanup) で実行する cleanup
>    # 重要: wildcard `/tmp/rite-fix-target-body-*.txt` は絶対に使わない (他セッション破壊防止)
>    rm -f "/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
>          "/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
>          "/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt"
>    ```
>    Broad Comment Retrieval 経路 (Fast Path を通らない場合) ではこれらの一時ファイルが存在しないため、`rm -f` は silent no-op となり問題ない。**Phase 1.4 「キャンセル」経路は Phase 1.5 を通らないため、Phase 1.4 内の独立した cleanup block (defense-in-depth 経路) で削除される**。
>
> **trap の上書きリスクに注意**: 本ブロックの `trap 'rm -f "$jq_err"' EXIT` は bash 仕様上 1 signal につき 1 trap しか持てないため、**後続の bash block (Phase 2.4 reply、Phase 4.2 report、Phase 4.3.4 Issue 作成、Phase 4.5.1 work memory 更新) が同一 bash 呼び出しに含まれる場合、それらの `trap ... EXIT` に上書きされて `$jq_err` のリークが起きる**。これは本ブロックを後続 phase と結合しないことで回避するほか、ブロック末尾で明示的に `rm -f "$jq_err"` を実行することで二重防御している (trap が動かなくても cleanup は完了する)。
>
> **将来 `trap` を連携する必要が出た場合**: bash の `trap -p` 出力は POSIX 仕様上「shell に reinput 可能なフォーマット (proper quoting 込み)」を保証しており ([POSIX `trap`](https://pubs.opengroup.org/onlinepubs/009604599/utilities/trap.html), [`trap(1p)`](https://man7.org/linux/man-pages/man1/trap.1p.html))、reinput には `eval "$(trap -p EXIT)"` を使うのが正規イディオム。**sed で trap action を抽出する idiom (`sed -n "s/.*'\(.*\)'.*/\1/p"` 等) は trap action 内のシングルクォート `'\''` 埋め込みを誤抽出するため使ってはならない**。代替として bash 配列で trap 登録を管理するパターンを使う:
>
> ```bash
> # 配列で trap action を蓄積し、EXIT 時にループ実行
> _rite_trap_actions=()
> _rite_run_trap_actions() {
>   for _action in "${_rite_trap_actions[@]}"; do
>     eval "$_action"
>   done
> }
> trap '_rite_run_trap_actions' EXIT
> # 新たな action を追加するときは push するだけ
> _rite_trap_actions+=('rm -f "$jq_err"')
> _rite_trap_actions+=('rm -f "$body_file"')
> ```
>
> この方式は `trap -p` 出力のパースに依存しないため quote エスケープ問題を回避できる。

> **Issue #390: 3-block split** — 旧実装 (#350 で追加) は 11 ステップを単一 bash block (約 230 行) に詰め込んでいた。破綻時の再実行コスト・保守性・レビュー性を改善するため、以下 3 ブロックに分割する:
>
> - **Block A**: 統合 trap + API fetch + jq `.body`/`.user.login` 抽出 → `raw_json` + intermediate 3 ファイル (`intermediate_body` + `intermediate_author` + `intermediate_skip`、合計 4 ファイル) に永続化
> - **Block B**: `raw_json` を再読込して jq `.issue_url` 抽出 → pr_number regex + URL suffix validate (silent misclassification 防止)
> - **Block C**: intermediate → final handoff 3 ファイル (`body_file`/`author_file`/`skip_file`) 書き出し → post-condition check → 常に `raw_json`/intermediate を削除
>
> ブロック間は **一時ファイル経由のみ** で値を引き継ぐ (シェル変数は bash 呼び出しを跨ぐと失われる)。各ブロックは独立した signal 別 trap を持ち、各ブロック scope での 2-state commit pattern (Block A の `blockA_committed`、Block C の `handoff_committed`) で orphan を防ぐ。Block B は新規 output がないため commit flag を持たず、validation 失敗時は upstream (raw_json + intermediate) を明示的に rm で invalidate する。加えて Block B の EXIT trap は **rc=$?** で非 0 exit を捕捉し、syntax error / subshell OOM / SIGPIPE / 将来の `set -e` 導入などの非期待終了経路でも upstream を invalidate することで、Block C の「raw_json 未検査で pass してしまう silent misclassification」を二重に防ぐ。
>
> **命名ポリシー** (`blockA_committed` vs `handoff_committed` の非対称について): Block A の flag は **block scope 名** (`blockA_committed`) で、Block A 内部の intermediate artifact をまだ後続 phase が参照しない段階の protection を表現する。Block C の flag は **artifact semantic 名** (`handoff_committed`) で、下流 phase (Parsing rule, Phase 2.1 以降) から参照される handoff contract の commitment を表現するため敢えて semantic name を維持する。Block B は新規 output を持たないため flag なし。命名を対称化するなら `intermediate_committed` / `handoff_committed` または `blockA_committed` / `blockC_committed` のどちらかに統一できるが、`handoff_committed` の「handoff 完了」という semantic 情報を下流参照時に失う不利益を避けるため現状の非対称を採用する。
>
> **⚠️ verified-review (cycle 8) H-8 対応 — Single-Bash-tool-call contract**: 各 Block は **必ず 1 つの Bash tool invocation で完結** させる (複数 Block を 1 回の bash 呼び出しに merge してはならない)。理由:
>
> 1. **Trap 上書き**: 各 Block は独立した `trap ... EXIT` を設定する。Block A+B を同一 bash block に merge すると Block A の trap が Block B の trap 定義で上書きされ、Block A の artifacts が trap cleanup から外れる経路がある (現状の commit flag 設計で多くはカバーされるが、設計上の fragility は残る)
> 2. **エラー境界**: Block A 失敗 (gh api 404 等) で exit した場合、merge 状態では Block B/C の trap handler 準備コードも実行されずに tempfile が orphan する経路が発生しうる
> 3. **再実行コスト**: 単一の巨大 block が失敗すると全 step やり直しになり、3-block 分割の目的 (破綻時の再実行コスト削減) が失われる
>
> **Block 境界 sentinel** (observability 用、cycle 8 H-8 で追加): 各 Block 末尾で `[CONTEXT] BLOCK_<NAME>_COMPLETE=1` を emit する。これは machine-enforced gate ではなく debugging trail 用の marker であり、Claude が後続 Block 実行前に会話履歴を grep することで「前の Block が正常完了したか」を確認できる。tempfile 存在 check (現行の防御) と併用し、Block 失敗の root cause を早期に特定できるようにする。

**Block A — trap セットアップ + API fetch + jq 抽出 + intermediate 書き出し**

```bash
# Block A (Issue #390): trap + gh api + jq .body / .user.login 抽出 + raw_json + intermediate 3 ファイル (合計 4 ファイル) 書き出し
#
# 設計: パス先行宣言 → trap 先行設定 → mktemp → gh api の順序で orphan race window を排除する。
# Phase 4.5.1 / Phase 4.5.2 / Fast Path で同型の「パス先行宣言 → trap 先行設定 → mktemp」パターンに統一。
#
# H-1 継承 (#350 検証付きレビュー H-1): confidence_override tempfile の orphan 防止 truncate。
# Phase 1.2 進入時に **無条件 truncate** を実行し、SIGINT/SIGTERM/SIGHUP で前セッションの
# /tmp/rite-fix-confidence-override-{pr_number}.txt が orphan として残った場合でも、
# 次回起動時の混入を決定論的に防ぐ。specific path 必須 (並列セッション破壊防止)。
# truncate 失敗 (read-only / permission denied) は warning のみで継続する。
#
# 注: 本 truncate は Block A の統合 trap setup (下記の _rite_fix_blockA_cleanup + trap EXIT/INT/TERM/HUP)
# **より前**に実行される。これは意図的な配置で、confidence_override tempfile は fix ループ全体で
# 参照される orphan-by-design なファイルであり (前セッションの残留を許容する設計)、
# truncate 自体が失敗しても fix loop 全体の破綻ではないため trap 保護は不要。
# 対照的に Block A の raw_json / intermediate は本 session 内限定の artifact であり、trap 保護が必須。
: > "/tmp/rite-fix-confidence-override-{pr_number}.txt" 2>/dev/null || \
  echo "WARNING: /tmp/rite-fix-confidence-override-{pr_number}.txt の truncate に失敗しました (read-only / permission denied?)" >&2

# Block A outputs (後続 Block B/C が一時ファイル経由で読み出す):
#   - raw_json:            gh api レスポンス全体 (Block B が .issue_url を再抽出、Block C は不使用)
#   - intermediate_body:   jq .body の抽出結果 (Block C が final body_file にコピー)
#   - intermediate_author: jq .user.login の抽出結果 (Block C が final author_file にコピー)
#   - intermediate_skip:   target_author_mention_skip の計算結果 (Block C が final skip_file にコピー)
raw_json="/tmp/rite-fix-raw-{pr_number}-{target_comment_id}.json"
intermediate_body="/tmp/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt"
intermediate_author="/tmp/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt"
intermediate_skip="/tmp/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt"

gh_api_err=""
jq_err=""

# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code 130/143/129、race window 回避、rc=$? capture、${var:-} safety、関数契約)
#
# Block A scope の 2-state commit pattern (blockA_committed):
# - blockA_committed=0 (初期値): 書き出し前/書き出し中の exit → raw_json + intermediate 3 ファイル全削除 (orphan 防止)
# - blockA_committed=1 (全書き出し成功後): raw_json と intermediate は保護、err files のみ削除
# 用語統一: 本 Block で「intermediate」と呼ぶのは body/author/skip の 3 ファイルを指す。
# raw_json (gh api レスポンス永続化ファイル) は intermediate とは別カテゴリとして扱い、
# 常に「raw_json + intermediate 3 ファイル」という表現で合計 4 ファイルを指す (drift 防止)。
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
# 注: stderr は gh api から専用一時ファイルに退避する (2>&1 で stdout に混入させない)。
#     もし 2>&1 を付けると、成功時に gh が stderr に警告を出した場合 $target_comment が invalid JSON となり
#     直後の jq が失敗する (過去の deprecation warning 事案の教訓)。stderr を独立ファイルに分離することで、
#     404 / 403 / 5xx などの gh api 詳細メッセージを失敗時に添付できる。
gh_api_err=$(mktemp /tmp/rite-fix-gh-api-err-XXXXXX) || {
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
jq_err=$(mktemp /tmp/rite-fix-jq-err-XXXXXX) || {
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

# jq .user.login 抽出 (fail-fast: .body が成功した状況で .user.login が失敗するのは
# jq バイナリ異常または破損した JSON レスポンスの兆候なので、警告して exit するほうが安全)
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

# intermediate body/author/skip の 3 ファイルに書き出し (raw_json は既に上で書き出し済み)。
# シェル変数は Block A 終了で失われるため、Block C が読み出せるよう永続化する。
# disk full / /tmp read-only (Docker RO volume, SELinux/AppArmor deny) / inode 枯渇 / permission denied の
# コーナーケースで silent に空ファイルを残さないよう、各 printf の exit code を明示的に check し fail-fast する。
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

# verified-review (cycle 8) H-8: Block 境界 sentinel emit (observability / debugging trail)
# Block B 進入前に Claude がこの [CONTEXT] を grep することで Block A 正常完了を確認できる
echo "[CONTEXT] BLOCK_A_COMPLETE=1; pr_number={pr_number}; target_comment_id={target_comment_id}" >&2
```

**Block B — post-condition 検証 (`.issue_url` 所属 check + `pr_number` validate)**

```bash
# Block B (Issue #390): raw JSON 再読込 + .issue_url 抽出 + pr_number / URL suffix validate
#
# 背景 (silent misclassification 防止): GitHub REST API `/repos/{owner}/{repo}/issues/comments/{id}` は
# PR/Issue を区別しない単一エンドポイント (PR は内部的に Issue でもある)。PR と Issue の issue comment は
# 同じ ID space を共有するため、ユーザーが `pull/123#issuecomment-456` を渡したつもりが 456 が
# **別 PR/Issue のコメント**だった場合、gh api は exit 0 で別の comment body を返してしまう (silent failure)。
# これを防ぐため、レスポンスの .issue_url フィールドを抽出して /pull/{pr_number} または
# /issues/{pr_number} を含むかを post-condition で検証する。
#
# Block B は新規 output を持たないため commit flag を持たない。validation 失敗時は upstream
# (raw_json + intermediate 3 ファイル) を _rite_fix_blockB_invalidate_upstream で明示的に rm する。

raw_json="/tmp/rite-fix-raw-{pr_number}-{target_comment_id}.json"
intermediate_body="/tmp/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt"
intermediate_author="/tmp/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt"
intermediate_skip="/tmp/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt"

jq_err=""

_rite_fix_blockB_cleanup() {
  rm -f "${jq_err:-}"
}
_rite_fix_blockB_invalidate_upstream() {
  rm -f "${raw_json:-}" "${intermediate_body:-}" "${intermediate_author:-}" "${intermediate_skip:-}"
}
# signal 別 trap:
# - 正常 exit (rc=0) では upstream (Block C が使う intermediate) を保持する
# - 非 0 exit (rc != 0) では upstream を明示 invalidate する — syntax error / subshell OOM / SIGPIPE /
#   将来の `set -e` 導入 / その他 shell-level 非期待終了で validation を skip した状態で intermediate が
#   残留し、Block C が raw_json を検査せず pass してしまう silent misclassification を防ぐ
# - signal 強制終了 (INT/TERM/HUP) でも invalidate する
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

jq_err=$(mktemp /tmp/rite-fix-jq-err-XXXXXX) || {
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

# pr_number を grep regex に直接埋め込む際の defense-in-depth:
# (1) literal `/pull/` / `/issues/` を直書きして括弧グループ内のバリエーションを減らす
# (2) pr_number 自体が数字のみであることを事前に validate (Phase 1.0 で normalize 済みだが defense-in-depth)
# これにより将来 pr_number に他の文字が混入する拡張がなされた場合の silent false positive を防ぐ。
# SIGPIPE 防止 (#398): printf | grep パターンを here-string に置換。
if ! grep -qE '^[0-9]+$' <<< "{pr_number}"; then
  echo "エラー: pr_number が数字以外を含んでいます: '{pr_number}'" >&2
  echo "  Phase 1.0 で正規化された pr_number は数字のみのはずですが、何らかの経路で異常値が混入しました" >&2
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

# verified-review (cycle 8) H-8: Block 境界 sentinel emit (observability / debugging trail)
echo "[CONTEXT] BLOCK_B_COMPLETE=1; pr_number={pr_number}; target_comment_id={target_comment_id}" >&2
```

**Block C — intermediate → final handoff 書き出し + post-condition + raw/intermediate cleanup**

```bash
# Block C (Issue #390): intermediate → final handoff 3 ファイル書き出し + post-condition + raw/intermediate 削除
#
# Block A が生成した intermediate 3 ファイル (body/author/skip) を読み出し、
# final handoff 3 ファイル (body_file/author_file/skip_file) に書き出す。
# raw_json は Block A が生成し Block B が jq の入力として使用する。Block C は Block A/B 成功確認の
# ための存在 check (下記 fail-fast check の defense-in-depth) のみ参照し、内容を consume することは
# ないが、trap cleanup の対象には含めて常に削除する。
# post-condition で handoff 3 ファイルの存在と非空を確認し、成功時は handoff_committed=1 を立てる。
# trap は常に raw_json と intermediate 3 ファイルを削除する (後続 phase では不要)。
# handoff_committed=0 (mid-write / post-condition fail) の場合は handoff 3 ファイルも削除する。

raw_json="/tmp/rite-fix-raw-{pr_number}-{target_comment_id}.json"
intermediate_body="/tmp/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt"
intermediate_author="/tmp/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt"
intermediate_skip="/tmp/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt"

body_file="/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt"
author_file="/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt"
skip_file="/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt"

# Block C scope の 2-state commit pattern (handoff_committed):
# - handoff_committed=0 (初期値): 書き出し前/書き出し中の exit → handoff 3 ファイルも削除 (orphan 防止)
# - handoff_committed=1 (全書き出し+post-condition pass 後): handoff 3 ファイルは保護される
# raw_json + intermediate 3 ファイル (合計 4 ファイル) は成功/失敗問わず常に削除する (後続 phase では使わない)。
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

# intermediate + raw_json 存在確認 (Block A/B がスキップされた / 失敗したケースの fail-fast)
# intermediate_author は空文字列でも許容 (target_author_mention_skip=true の sentinel として使う) のため -f のみ検査
# raw_json は Block B validation 失敗経路で invalidate される対象のため、Block C 進入時に存在していれば
# Block A/B が正常完了したことの defense-in-depth な確認になる (Block B EXIT trap 非 0 exit 経路との二重防御)
if [ ! -s "$intermediate_body" ] || [ ! -f "$intermediate_author" ] || [ ! -s "$intermediate_skip" ] || [ ! -s "$raw_json" ]; then
  echo "エラー: Block A/B の intermediate ファイルが存在しないか空です" >&2
  echo "  body=$intermediate_body ($([ -s "$intermediate_body" ] && echo ok || echo empty_or_missing))" >&2
  echo "  author=$intermediate_author ($([ -f "$intermediate_author" ] && echo ok || echo missing))" >&2
  echo "  skip=$intermediate_skip ($([ -s "$intermediate_skip" ] && echo ok || echo empty_or_missing))" >&2
  echo "  raw_json=$raw_json ($([ -s "$raw_json" ] && echo ok || echo empty_or_missing))" >&2
  echo "[CONTEXT] FASTPATH_HANDOFF_FAILED=1; reason=intermediate_missing_at_block_c" >&2
  exit 1
fi

# intermediate → final handoff コピー。cat の exit code を check することで disk full / read-only / inode 枯渇
# / permission 拒否のコーナーケースを捕捉し、silent に空ファイルを残さない。
# Block 識別子 (Block C) をエラーメッセージに含めることで、Block A の intermediate 書き出し失敗と区別する。
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

# Block C 完了: handoff 3 ファイルを trap の cleanup 対象から外す (handoff_committed=1)
# trap は raw_json + intermediate 3 ファイル (合計 4 ファイル) を常に削除する (後続 phase では使わない)。
# これ以降、bash block 末尾に到達するか後続 phase でエラーが起きても、handoff 3 ファイルは保護される。
# 後続 phase の cleanup (Phase 1.5 / Fast Path Cancel exit / Step C error exit) で明示的に削除する。
handoff_committed=1

# verified-review (cycle 8) H-8: Block 境界 sentinel emit (observability / debugging trail)
echo "[CONTEXT] BLOCK_C_COMPLETE=1; pr_number={pr_number}; target_comment_id={target_comment_id}" >&2
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
> これにより GitHub 上に存在しない `@unknown` user への誤 mention を防ぐ。`jq_err` の cleanup は `jq_err` を作成する Block A / Block B の EXIT/INT/TERM/HUP trap が呼び出す `_rite_fix_blockA_cleanup` / `_rite_fix_blockB_cleanup` 関数で保証され、異常終了・正常終了のいずれでも確実に削除される (Block C は `jq_err` tempfile を作成しないため該当なし。旧実装の末尾明示 `rm -f` は refactor で trap 経路に一元化された。Issue #390 / PR #449)。ハンドオフ 3 ファイル (`body`, `author`, `author-skip`) は **Phase 1.4 末尾の明示的 cleanup bash block** (specific path 指定、wildcard glob は使用禁止) で削除する — 詳細は上記 Implementation note の手順 3 を参照。並列 fix 実行時の他セッション破壊を防ぐため `rm -f /tmp/rite-fix-target-body-*.txt` のような glob は絶対に使わない。

**Parsing rule**:

1. If `$target_body` contains `## 📜 rite レビュー結果`: **Phase 1.2.1 で定義された table パースロジック** (`### 全指摘事項` を起点に reviewer サブセクションごとの table を解析し `severity_map` を構築する手順) を `$target_body` に対して適用する。**Phase 1.2.1 のコメント取得処理 (broad retrieval) は実行しない** — 対象コメントは既に取得済みのため
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
   - **severity 別名マッピング** (大文字小文字無視で完全一致を試行する。Title Case や lower case の値も正規化対象): CRITICAL/HIGH/MEDIUM/LOW 以外の値が出現した場合、以下の別名マッピングを試行する。**比較は必ず case-insensitive** で行うこと (例: `Critical` / `critical` / `CRITICAL` はいずれも `CRITICAL` にマッチ):

     | 認識される別名 (case-insensitive 比較) | 正規化先 |
     |---------------------------------------|---------|
     | `Critical`, `BLOCKER`, `CRIT`, `🔴`, `重大`, `致命` | `CRITICAL` |
     | `Important`, `MAJOR`, `HIGH`, `🟠`, `重要`, `高` | `HIGH` |
     | `Minor`, `MEDIUM`, `🟡`, `中`, `Normal` | `MEDIUM` |
     | `Low`, `INFO`, `TRIVIAL`, `🔵`, `低`, `情報` | `LOW` |

     > **Note — 既知の外部ツール出力形式**: rite plugin 配下に `/verified-review` は存在しない (実体はユーザーレベルの `~/.claude/commands/verified-review.md` にある独立コマンドで、rite plugin が提供するものではない)。同コマンドが出力するレビュー結果テーブルは `重要度` 列に **Title Case の `Critical` / `Important`** を使うため、上記マッピング表ではこれらを HIGH / CRITICAL に正規化する経路を必須としている。`pr-review-toolkit:review-pr` も同様に Title Case を使う場合があり、同じ経路で吸収される。
     >
     > **絵文字エイリアスの実運用検証状況**: 絵文字 (`🔴`/`🟠`/`🟡`/`🔵`) は将来の互換性のため列挙しているが、上記 2 ツールが絵文字を出力する事例は未検証。新しい外部レビューツールへの対応として絵文字エイリアスを追加した場合は、本 Note にツール名を追記すること。

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

   `[fix:cancelled-by-user]` exit 0 / `[fix:error]` exit 1 / Phase 1.0 再実行のいずれかへ進む直前に、Fast Path で作成した一時ファイル (ハンドオフ 3 + raw_json + intermediate 3 + confidence_override、合計 8 本) を **明示的に削除する** bash 呼び出しを必ず実行する。これは Phase 1.5 cleanup を経由しないすべての終了経路における defense-in-depth であり、Phase 1.4 末尾の Phase 1.5 cleanup から到達しない経路をカバーする:

   ```bash
   # Cancel / Re-run / Step C error 共通: ハンドオフ 3 + raw_json + intermediate 3 + confidence_override + pr-comment tempfile (合計 9 本) を削除してから exit する
   # Fast Path bash block 外なので body_file / author_file / skip_file 変数は失われている
   # → specific path で直接削除する (wildcard glob は並列セッション破壊のため絶対禁止)
   # confidence_override tempfile の lifecycle 管理
   # Issue #390: Block A/B/C 分割で raw_json + intermediate 3 ファイル (合計 4 ファイル) も cleanup 対象に追加
   # pr-comment tempfile も cleanup 対象に追加 (Broad Retrieval が
   # 書き出した /tmp/rite-fix-pr-comment-{pr_number}.txt を Fast Path 経路でも defense-in-depth で削除)
   # (Block C の trap が常に削除するが、Block A 成功後 orchestrator が異常終了して Block B/C 未到達の経路でも
   #  orphan を残さないための defense-in-depth。rm -f は idempotent なので二重削除でも副作用なし)
   rm -f "/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-confidence-override-{pr_number}.txt" \
         "/tmp/rite-fix-raw-{pr_number}-{target_comment_id}.json" \
         "/tmp/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt" \
         "/tmp/rite-fix-pr-comment-{pr_number}.txt"
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
   2. **再質問の応答も解釈不能の場合**: 上記「Cancel/Re-run 経路でのハンドオフ cleanup 義務」の bash block を実行して Fast Path の全一時ファイル (合計 8 本) を削除してから、`[fix:error]` を出力して exit 1 (**parse 0 件のまま Phase 2 進入は禁止**)。エラーメッセージに「解釈不能な応答が 2 回続いたため処理を中止しました。fix loop を手動で再実行してください」を含める

   > **「無応答」について**: Claude Code の対話モデルでは「無応答」状態は通常発生しない (応答を待つ間ブロックされる) ため、上記から削除した。タイムアウト等で無応答が発生した場合は AskUserQuestion 自体のエラーとして扱われ、本ループには到達しない。

   **重要**: parse 0 件で Phase 2 (Categorization) に進入することは silent failure として禁止する。必ず上記の選択肢のいずれかを処理した上で次の Phase へ進むこと。
3. `{target_comment_id}` 経由で取得した finding のみを fix ループの対象とする。Phase 1.2 の「全コメント取得」はスキップされる

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
- **スキップ** — Phase 4.3 で別 Issue 化する候補として扱う

**Confidence override の追跡義務** (silent 改竄防止): 「Confidence 70 のままバイパス」を選択した finding については、以下の出力箇所で明示的に可視化する:
- Phase 4.6 完了報告に `confidence_override: N 件` を追加
- Phase 4.5.3 work memory のレビュー対応履歴に `- confidence_override: {file:line} (外部ツール由来、ユーザーがバイパスを承認)` を記録
- Phase 4.3 で別 Issue 化される finding にも `confidence_override=true` の事実を Issue 本文に記載

**Retained context flags + tempfile-based persistence** (Phase 4.5.3 / 4.6 / 4.3.4 の placeholder 展開時に参照する変数):

> 旧仕様は会話履歴の `[CONTEXT]` 行を Claude が grep する方式だったが、長い conversation history で `[CONTEXT]` 行が複数あると順序依存 / 重複参照のリスクがあり silent drop の原因になっていた。本仕様では **specific path の一時ファイルへの append** に切り替え、bash で件数取得と本文取得を一貫化する。

| Flag | 型 | 初期値 | 永続化先 |
|------|---|--------|---------|
| **`confidence_override_count`** | int | `0` | `wc -l < /tmp/rite-fix-confidence-override-{pr_number}.txt` の出力 (空ファイル → `0`) |
| **`confidence_override_findings`** | list[str] (`"file:line"` の配列) | `[]` | `/tmp/rite-fix-confidence-override-{pr_number}.txt` の各行 (1 行 1 finding) |

**Tempfile lifecycle** (specific path 必須、wildcard glob 禁止):

- **Path**: `/tmp/rite-fix-confidence-override-{pr_number}.txt` ({pr_number} は Phase 1.0 で正規化済み)
- **作成タイミング**: Phase 1.2 best-effort parse で最初の override 候補が出現した時点で **truncate 付きで作成** (`: > {path}` または `printf '' > {path}`)。旧仕様の `touch` は POSIX 仕様上既存ファイルを truncate しない ([POSIX touch(1p)](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/touch.html) — 既存ファイルには `utimensat()` のみで content は変更されない) ため、前セッションの stale データに追記してしまう silent regression の原因になる。必ず `: > {path}` で truncate すること。
- **追記タイミング**: AskUserQuestion で「Confidence 70 のままバイパス」が選択されるたびに `printf '%s\n' "{file}:{line}" >> {path}`
- **読み出しタイミング**: Phase 4.6 / 4.5.3 / 4.3.4 で `wc -l < {path}` (件数) / `cat {path}` (本文) で取得
- **削除タイミング**: 以下の **すべての終了経路** で明示的に削除する (orphan 防止、specific path 必須):
  - **E2E flow**: Phase 8.1 の output pattern emit 直後
  - **Standalone flow**: Phase 8 は skip されるため、Phase 4.6 の completion report 出力後に明示的 cleanup bash block を実行する
  - **Phase 1.4 cancel 経路**: 既存の Fast Path 一時ファイル cleanup bash block に追加 (同一 block 内で削除)
  - **Phase 1.2 best-effort parse error 経路**: Cancel/Re-run cleanup に追加
- **並列セッション分離**: `{pr_number}` suffix で specific path とすることで、並列 fix 実行時の他セッション破壊を防ぐ。`/tmp/rite-fix-confidence-override-*.txt` のような wildcard glob は **絶対に使わない**

**Claude による retain と再注入の手順** (data flow の具体化、ファイル永続化版):

1. **H-1 修正**: Phase 1.2 進入時 (Fast Path / Broad Retrieval bash block 冒頭の両方) で `: > /tmp/rite-fix-confidence-override-{pr_number}.txt` を **無条件 truncate** する。これにより、SIGINT/SIGTERM/SIGHUP で前セッションの override file が orphan として残った場合でも、次回起動時の混入を決定論的に防ぐ。また、Phase 1.2 best-effort parse で最初の override 候補が出現した時点でも追加で truncate してよい (defense-in-depth、害なし)
2. AskUserQuestion で「Confidence 70 のままバイパス」が選択されるたびに、bash block 内で `printf '%s\n' "{file}:{line}" >> /tmp/rite-fix-confidence-override-{pr_number}.txt` を実行 (追記、`>>` で append)
3. Phase 4.6 / 4.5.3 / 4.3.4 の placeholder 展開時、bash block で以下を実行して値を取得 (会話履歴 grep に依存しない、`2>/dev/null` の silent IO suppression も撤廃):
   ```bash
   override_path="/tmp/rite-fix-confidence-override-{pr_number}.txt"
   if [ -f "$override_path" ]; then
     # wc -l の stderr を独立退避ファイルに分離:
     # 旧実装 `wc -l < "$override_path" 2>/dev/null` は read permission 拒否 / inode 破損 /
     # ファイル内容破壊などの IO エラーで silent に空文字列 → count=0 に落ちて
     # policy override の監査トレースが完成報告から silent drop する。
     override_err=$(mktemp /tmp/rite-fix-confidence-override-err-XXXXXX) || {
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
   - **E2E flow (Phase 8.1)**: `rm -f /tmp/rite-fix-confidence-override-{pr_number}.txt`
   - **Standalone flow (Phase 8.2)**: Phase 4.6 の completion report 出力後に明示的 cleanup bash block で削除
   - **Phase 1.4 cancel 経路**: Fast Path ハンドオフ cleanup bash block 内で同時に削除 (下記 Cancel cleanup block 参照)
   - **Phase 1.2 best-effort parse cancel/error 経路**: 「Cancel/Re-run 経路でのハンドオフ cleanup 義務」bash block 内で同時に削除

**互換性**: 旧 `[CONTEXT] confidence_override_count = N; confidence_override_findings = [...]` 行の emit は、debug 補助として **継続して併用してよい** (人間が tail で見えるケースのため)。ただし機械的な値の取得は必ずファイル経由とし、`[CONTEXT]` 行の grep には依存しない。

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
> | Phase 1.2 後半の `#### Broad Comment Retrieval` セクション (本ファイル内の同名 h4 heading) | PR の全コメントを取得 (`gh api pulls/{n}/comments`, `gh pr view --json comments` 等) | **実行しない** (対象コメントは Fast Path 冒頭で既に取得済み) |
> | `### 1.2.1 Retrieve rite Review Results` | (1) `$pr_comments` から `📜 rite レビュー結果` コメントをフィルタ選択、(2) 選択されたコメント本文に対して Markdown table parsing algorithm を適用して `severity_map` を構築 | **Markdown table parsing algorithm の部分のみを `$target_body` に対して再利用する**。フィルタ選択 (1) は Fast Path では不要 (対象コメントが既に決まっているため) |
>
> Fast Path 経由で `severity_map` を構築した場合、`pr_comments` 変数および関連する review thread 情報 (broad retrieval で取得されるデータ) は **未定義のまま**である。後続の Phase で `$pr_comments` や reviewThreads を参照しないこと (参照すると runtime error)。Fast Path はあくまで「単一コメントから finding を抽出する」フローであり、broad retrieval の結果には依存しない。

パース完了後、抽出した findings を持って直接 Phase 2 (Categorization) に進む。Phase 1.2 の Broad Comment Retrieval ブロックおよび Phase 1.2.1 のフィルタ選択処理は Fast Path では実行しない (対象コメントは既に取得済みのため)。Phase 1.2.1 の Markdown table parsing algorithm のみを `$target_body` に適用する。

#### Broad Comment Retrieval — when `{target_comment_id}` is NOT set

When the standard flow is active (no `target_comment_id`), retrieve PR review comments as before:

```bash
# confidence_override tempfile の orphan 防止
# Fast Path 経路と同様に、Broad Retrieval 経路でも Phase 1.2 進入時に **無条件 truncate** を実行する。
# SIGINT/SIGTERM/SIGHUP で前セッションの /tmp/rite-fix-confidence-override-{pr_number}.txt が orphan
# として残った場合でも、次回起動時の混入を決定論的に防ぐ。
# specific path 必須 (並列セッション破壊防止) — wildcard glob は絶対に使わない。
: > "/tmp/rite-fix-confidence-override-{pr_number}.txt" 2>/dev/null || \
  echo "WARNING: /tmp/rite-fix-confidence-override-{pr_number}.txt の truncate に失敗しました (read-only / permission denied?)" >&2

# Broad Retrieval 経路の exit code check (#354):
# Fast Path の if-bang exit code check pattern を適用し、
# HTTP error / network failure / auth error 時に fail-fast する。
# stderr を独立ファイルに退避し、失敗時に詳細を表示する。
# trap は Fast Path と同じ canonical 4 行パターン (EXIT/INT/TERM/HUP) で統一。
gh_api_err=""
_rite_fix_broad_retrieval_cleanup() {
  rm -f "${gh_api_err:-}"
}
trap 'rc=$?; _rite_fix_broad_retrieval_cleanup; exit $rc' EXIT
trap '_rite_fix_broad_retrieval_cleanup; exit 130' INT
trap '_rite_fix_broad_retrieval_cleanup; exit 143' TERM
trap '_rite_fix_broad_retrieval_cleanup; exit 129' HUP

gh_api_err=$(mktemp /tmp/rite-fix-broad-retrieval-err-XXXXXX) || {
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

# 通常のコメント（PR コメント欄）を一括取得して保存（Phase 1.2.1 で再利用）
if ! pr_comments=$(gh pr view {pr_number} --json comments --jq '.comments' 2>"$gh_api_err"); then
  echo "エラー: PR コメントの取得に失敗しました (gh pr view --json comments)" >&2
  echo "詳細 (gh pr view stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi
echo "$pr_comments" | jq '.[] | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'

# pr_review_comment_body の literal substitute hand-off を tempfile 経由化
# (大きい multi-line PR コメント本文を Claude が HEREDOC literal に埋め込む際の escape 漏れ・truncate
# リスクを排除する。Phase 1.2.0 Priority 3 bash block が specific path から直接読み出す)
#
# specific path 必須 ({pr_number} suffix で並列セッション分離、wildcard glob 禁止)。
# 書き出し失敗時は WARNING を出して continue する (literal substitute fallback 経路は廃止されたため、
# tempfile が無ければ Phase 1.2.0 Priority 3 が fail-fast する)。
pr_comment_body_file="/tmp/rite-fix-pr-comment-{pr_number}.txt"
jq_broad_err=$(mktemp /tmp/rite-fix-broad-jq-err-XXXXXX 2>/dev/null) || jq_broad_err=""
if rite_review_body=$(printf '%s' "$pr_comments" | jq -r '
  [.[] | select(.body | contains("## 📜 rite レビュー結果"))]
  | sort_by(.createdAt) | last | .body // empty
' 2>"${jq_broad_err:-/dev/null}"); then
  if [ -n "$rite_review_body" ]; then
    if ! printf '%s' "$rite_review_body" > "$pr_comment_body_file"; then
      echo "WARNING: pr_review_comment_body tempfile への書き出しに失敗: $pr_comment_body_file" >&2
      echo "  対処: /tmp の容量 / permission を確認してください" >&2
      echo "  影響: Phase 1.2.0 Priority 3 が tempfile を読めず fail-fast する可能性があります" >&2
    else
      echo "[CONTEXT] PR_REVIEW_COMMENT_BODY_FILE=$pr_comment_body_file" >&2
    fi
  else
    # rite review result コメントが PR に存在しない (legitimate な legacy / 初回経路)
    # tempfile を作成しないことで、Phase 1.2.0 Priority 3 は別のソース判定経路を辿る
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
  echo "  影響: Phase 1.2.0 Priority 3 が tempfile 不在として BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT に routing される" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=broad_retrieval_jq_extraction_failed; rc=$jq_extract_rc" >&2
fi
[ -n "$jq_broad_err" ] && rm -f "$jq_broad_err"
```

**Implementation note for Claude**: `$pr_comments` はシェル変数ではなく、**会話コンテキスト内で保持するデータ**として扱うこと。Claude Code が各 bash コードブロックを個別の Bash ツール呼び出しで実行する場合、シェル変数はブロック間で引き継がれない。Phase 1.2.1 では、この値をコンテキストから読み直すか、Phase 1.2 のコードブロックと Phase 1.2.1 のコードブロックを単一の Bash ツール呼び出しとして結合して実行すること。

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

gh_api_err=$(mktemp /tmp/rite-fix-broad-retrieval-err-XXXXXX) || {
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
| **キャンセル** | - | Abort the process (Fast Path 経由の場合はハンドオフファイルを削除してから exit) |

**「キャンセル」選択時の Behavior** (silent orphan ファイル防止):

`/rite:pr:fix` 実行時に Fast Path (Phase 1.2 Target Comment Fast Path) を経由して Fast Path 一時ファイル (ハンドオフ 3 + raw_json + intermediate 3、合計 7 本) を作成した状態で「キャンセル」が選択された場合、Phase 1.5 cleanup を経由しないため、**Phase 1.4 末尾でも明示的に Fast Path の全一時ファイル + confidence_override (合計 8 本) を削除する**。これは Phase 1.2 best-effort parse の「Cancel/Re-run 経路でのハンドオフ cleanup 義務」段落と同じ defense-in-depth 原則に従う。

```bash
# Phase 1.4 「キャンセル」選択時の cleanup (silent orphan ファイル防止)
# Fast Path bash block 外なので body_file / author_file / skip_file 変数は失われている
# → specific path で直接削除する (wildcard glob は並列セッション破壊のため絶対禁止)
# Broad Comment Retrieval 経路ではこれらのファイルが存在しないため rm -f は silent no-op となる
# confidence_override tempfile の lifecycle 管理
# Issue #390: Block A/B/C 分割で raw_json + intermediate 3 ファイル
# (合計 4 ファイル) も cleanup 対象に追加 (Block C の trap が常に削除するが、Block A/B 成功後に本
# cancel 経路に到達した場合の defense-in-depth。rm -f は idempotent なので二重削除でも副作用なし)
rm -f "/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-confidence-override-{pr_number}.txt" \
      "/tmp/rite-fix-raw-{pr_number}-{target_comment_id}.json" \
      "/tmp/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-pr-comment-{pr_number}.txt"
# pr-comment tempfile も cleanup 対象に追加

# cleanup 後に exit
echo "[fix:cancelled-by-user]"
exit 0
```

> **Phase 1.5 との関係**: Phase 1.5 は「Phase 1.4 を完走して Phase 2 遷移直前」に発火する正常 cleanup 経路。「キャンセル」選択は Phase 1.4 から Phase 2 に遷移しないため Phase 1.5 に到達しない。本 cleanup は Phase 1.5 の代替経路として動作し、Phase 1 終端での 100% cleanup 保証を担う。

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

**Execution condition**: Fast Path 経由で一時ファイル (`/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt` 等) を作成し、かつ Phase 1.4 を「キャンセル以外」(= 「すべての指摘に対応」「CRITICAL/HIGH のみ対応」「特定の指摘を選択」のいずれか) で完走した場合のみ実行する。Broad Comment Retrieval 経路 (Fast Path 未経由) や Phase 1.4 「キャンセル」経路ではこれらのファイルは存在しないか別経路 (Phase 1.4 「キャンセル」Behavior block) で削除済みのため、`rm -f` は silent no-op となる。

**Purpose**: Phase 1.2 Fast Path で作成した一時ファイル (ハンドオフ 3 + raw_json + intermediate 3、合計 7 本) を明示的に削除する。**Phase 1.5 として独立に実行する** (Phase 1 の最終サブフェーズ、Phase 2 遷移直前のタイミング)。これにより `/tmp` 累積汚染と再実行時の stale data 参照を防ぐ。

**Important — specific path 必須** (並列 fix 実行の他セッション破壊防止):
- wildcard glob (`/tmp/rite-fix-target-body-*.txt` 等) は**絶対に使わない**。並行 terminal / sprint team-execute / 手動複数セッションで他セッションの一時ファイルも silent に消す事故になる
- 必ず `{pr_number}-{target_comment_id}` suffix を含む specific path で削除する

```bash
# Phase 1.5: Fast Path Handoff File Cleanup
# 実行条件: Fast Path 経由 (target_comment_id が set されている場合) のみ
# Broad Comment Retrieval 経路では silent no-op (ファイルが存在しないため rm -f が exit 0 で終わる)
# {pr_number} / {target_comment_id} は Claude が Phase 1.0 の parse 結果で事前置換済み
# 注: confidence_override tempfile は Phase 1.5 では削除しない。fix ループ全体で参照されるため、
# Phase 8.1 (E2E flow) または Phase 4.6 後 (Standalone flow) で削除する (H-2 対応)。
# Issue #390: Block A/B/C 分割で raw_json + intermediate 3 ファイル (合計 4 ファイル) も cleanup 対象に追加
# (Block C の trap が常に削除するが、Block A/B 成功後に orchestrator が異常終了して Block C 未到達の経路でも
#  orphan を残さないための defense-in-depth。rm -f は idempotent なので二重削除でも副作用なし)
rm -f "/tmp/rite-fix-target-body-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-target-author-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-target-author-skip-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-raw-{pr_number}-{target_comment_id}.json" \
      "/tmp/rite-fix-intermediate-body-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-intermediate-author-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-intermediate-skip-{pr_number}-{target_comment_id}.txt" \
      "/tmp/rite-fix-pr-comment-{pr_number}.txt"
# pr-comment tempfile も cleanup 対象に追加
# (Broad Retrieval 経路で書き出された場合の正常時 cleanup。Fast Path 経路では存在しないため
# rm -f は silent no-op となる)
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

### 2.3.1 Propagation Scan (#453 Component B)

After applying a fix (Phase 2.3), perform a mandatory scan for similar patterns to prevent distributed propagation failures (Pattern-1 from `fix-cycle-pattern-analysis.md`).

Check if `review.loop.auto_propagation_scan` is enabled in `rite-config.yml` (default: `true`). If disabled, skip to Phase 2.4.

**Step 1: Identify the fix pattern**

Characterize what was changed in Phase 2.3:

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

> **Scope limitation**: To avoid excessive scanning, limit the search to the same file + files in the same directory. For cross-directory searches, only follow explicit references (e.g., `reference:` links in Markdown, `source` imports in code).

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
#
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: 「パス先行宣言 → trap 先行設定 → mktemp」の順序、signal 別 exit code、${var:-} safety)
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
  # mktemp 失敗経路にも retained flag を emit
  # (bash の `exit 1` は Claude のフロー制御にならず、Phase 8.1 が REPLY_POST_FAILED を検出しないと
  # silent に [fix:replied-only] / [fix:pushed] と判定される。Phase 4.2 / 4.3.4 と対称にする)
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id; reason=mktemp_failed_reply_tmpfile" >&2
  exit 1
}

# cat HEREDOC の exit code を捕捉
# (Phase 4.2 / 4.3.4 の L-7 修正パターンと統一)
# disk full / permission 拒否で HEREDOC 書き込みが中断した場合、jq --rawfile は truncated な
# tmpfile を silent に成功扱いし、空/truncated な reply body が POST される regression を防ぐ
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
  echo "  対処: gh auth status / network 接続 / rate limit / PR #{pr_number} の存在 を確認してください" >&2
  echo "  影響: レビュアーへの返信が PR に残らないまま fix loop が完了扱いになる silent regression のリスク" >&2
  # Rationale: bash の `exit 1` は Claude のフロー制御にならず、Phase 8.1 が REPLY_POST_FAILED を
  # 検出しないと silent に [fix:replied-only] / [fix:pushed] と判定される。retained flag を
  # context に明示宣言することで Phase 8.1 評価順テーブルで detect され [fix:error] へ昇格する。
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id" >&2
  set +o pipefail
  exit 1
fi
set +o pipefail
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

### 3.1.1 Pre-Commit Drift Lint Gate (#453 Component C)

Before committing, run the distributed fix drift check to catch known propagation failure patterns (Pattern 1-5) mechanically. This prevents drift from entering the review cycle, saving an entire review-fix round trip.

1. Check if `review.loop.pre_commit_drift_check` is enabled in `rite-config.yml` (default: `true`). If disabled, skip to Phase 3.2.

2. Run the drift check on files changed by the current fix:

```bash
# Get changed files that are in the default target set
changed_files=$(git diff --name-only HEAD 2>/dev/null | grep -E '^plugins/rite/commands/pr/(fix|review)\.md$|^plugins/rite/agents/tech-writer\.md$' || true)

if [ -n "$changed_files" ]; then
  target_args=""
  while IFS= read -r f; do
    target_args="$target_args --target $f"
  done <<< "$changed_files"
  bash {plugin_root}/hooks/scripts/distributed-fix-drift-check.sh $target_args --quiet
  drift_exit=$?
else
  drift_exit=0
fi
printf '[CONTEXT] PRE_COMMIT_DRIFT_CHECK exit=%d changed_targets=%d\n' "$drift_exit" "$(echo "$changed_files" | grep -c . || echo 0)"
```

3. Handle the exit code:

| Exit Code | Action |
|-----------|--------|
| `0` (clean) | Proceed to Phase 3.2. |
| `1` (drift detected) | Re-run **without** `--quiet` to display findings. Return to Phase 2 to fix the detected drifts. This is an **automated self-correction** — NOT a new review cycle. Do not increment `loop_count`. |
| `2` (invocation error) | Emit `[CONTEXT] PRE_COMMIT_DRIFT_CHECK_ERROR=1` as WARNING and proceed to Phase 3.2. Do not block the commit. |

> **Note**: If drift is detected, the fix loop is expected to self-correct within 1-2 iterations of this inner gate. If the same drift is detected 3 times consecutively, skip the gate and proceed to Phase 3.2 to avoid an inner infinite loop.

### 3.2 Generate Commit Message

Generate a commit message based on the addressed findings.

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

> **⚠️ CRITICAL**: The `description` part of the commit message **MUST** follow the `language` setting in `rite-config.yml`. The examples below are for reference only — always generate the description in the language determined by the setting, not by copying the example language. The commit body and trailer also follow the same language setting.

**Examples by language:**

| Language setting | Commit message example |
|-----------------|----------------------|
| **`en`** or `auto` (English input) | `fix(review): address review feedback` |
| **`ja`** or `auto` (Japanese input) | `fix(review): レビュー指摘に対応` |

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
4. **Apply review-fix mapping table**: Map each extracted item to action types using the [Review-Fix Commit Mapping](../../skills/rite-workflow/references/contextual-commits.md) table:
   - レビュー指摘の対応方針 → `decision(scope)`
   - 対応しなかった指摘とその理由 → `rejected(scope)`
   - 対応中に発見した制約 → `constraint(scope)`
   - 対応中の発見事項 → `learned(scope)`
   - **レビューソースの provenance** → `decision(review-source): {review_source}` (verified-review cycle 9 I-1 対応、Phase 1.2.0 Priority chain で決定された `review_source` 値を commit body に記録。schema.md Priority 1 emit 義務の provenance 契約を Phase 3.2 commit message でも履行する)
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

### 3.3.1 Fix-Cycle State Persistence (#453 Component D)

After committing, record the current fix cycle's data to `.rite/fix-cycle-state/{pr_number}.json` for convergence monitoring and cross-session context preservation.

```bash
# Ensure directory exists
mkdir -p .rite/fix-cycle-state

pr_number="{pr_number}"
state_file=".rite/fix-cycle-state/${pr_number}.json"
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

# Append new cycle entry (propagation_applied is set by Phase 2.3.1 context)
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
  .cycles += [$entry | .cycle = (.cycles | length) + 1] |
  if (.cycles | length) > 20 then .cycles = .cycles[-20:] else . end
' > "$state_file"

printf '[CONTEXT] FIX_CYCLE_STATE_WRITTEN file=%s cycle=%d\n' "$state_file" "$(jq '.cycles | length' "$state_file")"
```

> **Placeholder resolution**: `{findings_fixed_count}` is the number of findings addressed in Phase 2 (count of fix iterations). `{propagation_applied_count}` is from Phase 2.3.1 propagation summary. If Phase 2.3.1 was skipped, use `0`. `{pr_number}` is from Phase 1.0 argument parsing.
>
> **Ring buffer**: The state file is capped at 20 cycle entries. Older entries beyond the cap are silently dropped. This prevents unbounded growth for long-running PRs.

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
#
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: 「パス先行宣言 → trap 先行設定 → mktemp」の順序、signal 別 exit code、${var:-} safety)
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
  # mktemp 失敗経路にも retained flag を emit
  # (bash の `exit 1` は Claude のフロー制御にならず、Phase 8.1 が REPORT_POST_FAILED を検出
  # しないと silent に [fix:pushed] と判定される。成功経路の L-7 修正と対称にする)
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
if ! gh pr comment {pr_number} --body-file "$tmpfile"; then
  echo "ERROR: gh pr comment による報告投稿に失敗しました" >&2
  echo "  対処: gh auth status / network 接続 / PR #{pr_number} の存在 を確認してください" >&2
  echo "  影響: 対応完了報告コメントが PR に残らないまま fix loop が完了扱いになる silent regression のリスク" >&2
  # Rationale: Phase 8.1 で REPORT_POST_FAILED=1 を検出し [fix:error] へ昇格させる。
  # bash の `exit 1` だけでは Claude のフロー制御にならないため、retained flag を併用する。
  echo "[CONTEXT] REPORT_POST_FAILED=1; pr_number={pr_number}" >&2
  exit 1
fi
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
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md) | `/home/user/.claude/plugins/rite` |

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

```bash
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code、race window 回避、rc=$? capture、${var:-} safety、関数契約)
#
# 本 site 固有: 2-state commit pattern (issue_created) — Fast Path の handoff_committed と同型
# - issue_created=0 (初期値): cleanup は tmpfile を preserve (Issue 作成失敗時に debug 用本文を残す)
# - issue_created=1 (gh issue create 成功後): cleanup は tmpfile を削除 (debug 不要)
#
# 短命変数も統合 trap で保護する (M-4): mktemp 成功〜直後の rm -f までの race window で
# SIGINT/SIGTERM/SIGHUP 到達時の orphan を防ぐため、warnings_jq_err / project_reg_jq_err も
# cleanup 対象に含める。bash block 後段で warnings_jq_err を追加するため、cleanup は関数にまとめて
# 1 つの trap で全変数をカバーする (trap 再定義による前段 cleanup 上書き防止)。
issue_created=0
tmpfile=""
warnings_jq_err=""
project_reg_jq_err=""
_rite_fix_issue_create_cleanup() {
  if [ "$issue_created" = "1" ]; then
    rm -f "${tmpfile:-}"
  else
    if [ -n "${tmpfile:-}" ] && [ -f "${tmpfile:-}" ]; then
      echo "  [debug preserved] Issue 本文 tmpfile: $tmpfile" >&2
    fi
  fi
  rm -f "${warnings_jq_err:-}" "${project_reg_jq_err:-}"
}
trap 'rc=$?; _rite_fix_issue_create_cleanup; exit $rc' EXIT
trap '_rite_fix_issue_create_cleanup; exit 130' INT
trap '_rite_fix_issue_create_cleanup; exit 143' TERM
trap '_rite_fix_issue_create_cleanup; exit 129' HUP

tmpfile=$(mktemp) || {
  echo "ERROR: tmpfile mktemp 失敗 (/tmp が read-only / inode 枯渇 / permission 拒否)" >&2
  # mktemp 失敗経路にも retained flag を emit
  # (bash の `exit 1` は Claude のフロー制御にならず、Phase 8.1 が ISSUE_CREATE_FAILED を検出
  # しないと silent に issues-created:0 と判定され scope 外 finding の追跡が失われる)
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; finding={file}:{line}; reason=mktemp_failed_issue_body_tmpfile" >&2
  exit 1
}

# cat redirection の exit code を明示 check
# 旧実装は cat heredoc redirection 単独で exit code を check していなかった。
# 直後の `[ ! -s "$tmpfile" ]` は size 0 のみ検出するが、disk full mid-write で
# truncated body が書き込まれた場合 (size > 0 だが body 不完全) を検出できない。
# `if ! ...` で wrap し、cat 自体の exit code を check する。
if ! cat <<'BODY_EOF' > "$tmpfile"
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
then
  echo "ERROR: Issue 本文の cat redirection に失敗 (disk full / write permission denied / IO error の可能性)" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / disk space を確認してください" >&2
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=cat_redirection_failed" >&2
  exit 1
fi

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue 本文の生成に失敗 (cat 成功だが tmpfile が空)" >&2
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=pr_body_tmp_empty_or_missing" >&2
  exit 1
fi

# exit code を明示 check (silent failure 防止):
# 旧実装は `result=$(...)` の後に `[ -z "$result" ]` で空チェックのみ。
# しかし script が exit 1 で早期終了しつつ stdout に partial JSON を出力した場合、
# (a) `result` は非空、(b) jq で `.issue_url` が抽出可能、(c) `.project_registration` が null
# となり、後続の `jq '.warnings[]' 2>/dev/null` が stderr suppress により jq parse error も
# 隠蔽し silent に「warnings 0 件」と誤認する。これを防ぐため exit code を捕捉する。
#
# 旧 `if ! result=$(cmd); then script_exit=$?` パターンは bash 仕様上
# `$?` が常に 0 を返す (`!` 否定の結果が then 節に伝播)。command substitution + 明示的 rc 捕捉
# (`result=$(cmd); script_exit=$?`) に変更し、cmd 自身の exit code を正しく取得する。
# 実証: `bash -c 'if ! result=$(exit 42); then echo $?; fi'` → `0`
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
script_exit=$?
if [ "$script_exit" -ne 0 ]; then
  echo "ERROR: create-issue-with-projects.sh exit=$script_exit" >&2
  echo "  Partial result (preserved for debug, not parsed): $result" >&2
  echo "  対処: scripts/create-issue-with-projects.sh のログを確認し、根本原因を解決してから再実行してください。" >&2
  echo "  本 finding は別 Issue 化されず、手動対応が必要です。" >&2
  echo "  影響: scope 外 finding の追跡が完全に失われる silent regression のリスク" >&2
  # Rationale: Phase 8.1 で ISSUE_CREATE_FAILED=1 を検出し [fix:error] へ昇格させる。
  # bash の `exit 1` だけでは Claude のフロー制御にならず、silent に [fix:pushed] / [fix:replied-only]
  # として完了判定され、scope 外 finding の追跡が失われる。retained flag を併用する。
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; finding={file}:{line}; reason=script_exit_$script_exit" >&2
  exit 1
fi

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result (exit 0 だが stdout が空)" >&2
  echo "  Debug: Issue 本文 tmpfile が debug 用に preserved されています (issue_created=0 のため)" >&2
  echo "    tmpfile path: $tmpfile" >&2
  echo "  影響: scope 外 finding の追跡が完全に失われる silent regression のリスク" >&2
  # retained flag emit (空 stdout 経路)
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; finding={file}:{line}; reason=empty_stdout" >&2
  exit 1
fi
# .issue_url が空文字や null でないことも検証 (script が成功したのに JSON schema が壊れているケース)
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url // empty')
if [ -z "$created_issue_url" ]; then
  echo "ERROR: create-issue-with-projects.sh の結果に .issue_url が含まれていません" >&2
  echo "  Raw result: $result" >&2
  echo "  Debug: Issue 本文 tmpfile が debug 用に preserved されています (issue_created=0 のため)" >&2
  echo "    tmpfile path: $tmpfile" >&2
  echo "  影響: scope 外 finding の追跡が完全に失われる silent regression のリスク" >&2
  # retained flag emit (.issue_url 抽出失敗経路)
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; finding={file}:{line}; reason=missing_issue_url" >&2
  exit 1
fi

# Issue 作成成功: preserve 義務が果たされたため tmpfile を削除対象に切り替える (issue_created=1)
# 状態遷移 (line 1581-1589 の説明と一致):
#   - issue_created=0: cleanup 関数は tmpfile を preserve (debug 用)
#   - issue_created=1: cleanup 関数は tmpfile を rm -f (debug 不要、正常完了)
# 以降、EXIT trap 発火時に `_rite_fix_issue_create_cleanup` (line 1593-1602) が
# `if [ "$issue_created" = "1" ]` 分岐で tmpfile を削除する。
# Phase 4.3.5 は {issue_number} / {issue_title} のみを参照し tmpfile path は使わないため
# preserve 不要 (Phase 4.3.5 の表示テンプレートは line 1808 付近を参照)。
issue_created=1

# .project_registration の jq 抽出 + partial / failed 警告 (silent drop 防止):
# `.warnings[]` 経由の警告とは独立に、`.project_registration` 自体の値も検査する。
# `.warnings` が空で `.project_registration == "failed"` のスキーマ差分ケースで、Projects 登録失敗が
# 完全に silent drop する経路を防ぐ。
project_reg_jq_err=$(mktemp /tmp/rite-fix-project-reg-jq-err-XXXXXX) || {
  echo "ERROR: project_reg_jq_err 一時ファイルの作成に失敗" >&2
  echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=mktemp_failed_issue_body_tmpfile" >&2
  exit 1
}
# project_reg_jq_err は統合 trap でも保護される (上記 cleanup 関数参照)。
# 本 if-else 直後の明示 rm は通常経路の早期削除 (tempfile lifetime 短縮) で、trap は SIGINT/SIGTERM/SIGHUP 到達時の defense-in-depth。
if ! project_reg=$(printf '%s' "$result" | jq -r '.project_registration // empty' 2>"$project_reg_jq_err"); then
  echo "WARNING: .project_registration の jq 抽出に失敗 (schema 破損の可能性)" >&2
  echo "  jq stderr: $(cat "$project_reg_jq_err")" >&2
  echo "  Raw result (preserved for debug): $result" >&2
  project_reg=""  # 後続 case 文を空文字 fallback で安全に通す
fi
rm -f "$project_reg_jq_err"

case "$project_reg" in
  partial|failed)
    echo "⚠️ Projects 登録が完全に完了しませんでした (status: $project_reg)" >&2
    echo "  Issue は作成済み: $created_issue_url" >&2
    echo "  手動登録: gh project item-add {project_number} --owner {owner} --url $created_issue_url" >&2
    ;;
  ""|completed)
    # 通常時 (空 = .project_registration フィールド未設定 / completed = 正常完了) は no-op
    :
    ;;
  *)
    # 未知の値が入った場合は警告 (schema 拡張時に silent に握りつぶさない)
    echo "WARNING: .project_registration に未知の値: '$project_reg' (Raw result: $result)" >&2
    ;;
esac

# .warnings の jq 抽出を明示エラーチェック (`2>/dev/null` で隠蔽しない):
# jq の stderr を一時ファイルに退避し、parse 失敗時は WARNING を出して詳細を表示する。
# silent に「warnings 0 件」と誤認することを防ぐ
#
# 重要: warnings_jq_err は bash block 冒頭で定義した統合 cleanup 関数
# `_rite_fix_issue_create_cleanup` の `rm -f` 対象に既に含まれている (`${warnings_jq_err:-}`)。
# ここで trap を再定義すると前段の `$tmpfile` cleanup を上書きで失い silent orphan を引き起こす
# trap 再定義は禁止 — 統合 trap がカバーする。
warnings_jq_err=$(mktemp /tmp/rite-fix-warnings-jq-err-XXXXXX) || {
  echo "ERROR: warnings_jq_err 一時ファイルの作成に失敗" >&2
  exit 1
}

if warnings_output=$(printf '%s' "$result" | jq -r '.warnings[]?' 2>"$warnings_jq_err"); then
  if [ -n "$warnings_output" ]; then
    # warnings 出力を stderr に統一
    # 旧実装は stdout に出力していたが、Phase 8.1 が stdout の `[fix:` pattern を機械パースする
    # ため、warnings の `⚠️` prefix が将来 grep の regression を生むリスクがあった。
    # 他の WARNING はすべて stderr (`>&2`) で出力されているのに対し、本箇所のみ非対称だった。
    printf '%s\n' "$warnings_output" | while read -r w; do echo "⚠️ $w" >&2; done
  fi
else
  echo "WARNING: .warnings フィールドの jq 抽出に失敗 (script schema 不整合の可能性)" >&2
  echo "  jq stderr: $(cat "$warnings_jq_err")" >&2
  echo "  Raw result: $result" >&2
  echo "  対処: create-issue-with-projects.sh の出力 schema を確認してください。" >&2
fi
# 統合 cleanup 関数が EXIT trap で warnings_jq_err も削除するため、ここでの明示的 rm は冗長だが
# 二重防御として残す (Fast Path の jq_err 末尾 rm と同じパターン)
rm -f "$warnings_jq_err"
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

> Update work memory per `work-memory-format.md` (at `{plugin_root}/skills/rite-workflow/references/work-memory-format.md`). Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md).

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
#
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: 「パス先行宣言 → trap 先行設定 → mktemp」の順序、signal 別 exit code、${var:-} safety)
#
# 本 site 固有: mktemp 失敗時の exit code を check しないと、$pr_body_tmp が空文字列になり後続の
# `printf > ""` が silent redirection error で空ファイルを参照し、issue_number が silent empty に落ちる。
# M-1 で 2>&1 撤廃に伴い pr_body_grep_err / branch_grep_err も独立 stderr 退避ファイルとして統合 trap で保護。
pr_body_tmp=""
pr_body_grep_err=""
branch_grep_err=""
# wm_emit_done フラグ (M-4 / M-5 対応): retained flag が 1 度 emit されたら、以降の経路で
# 重複 emit と branch fallback 誤起動を防ぐための gate。Phase 8.1 の reason 表で「最初に emit された
# reason を採用」としたくても、複数 emit が混在すると debug UX が悪化し root cause 特定が遅れる。
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
# HEREDOC 経由で pr_body を書き出す (single-quoted delimiter で shell expansion を完全抑制)。
# double-quoted printf 形式は PR body 内の `"` でクォート閉じが起きるとシェル parser が
# 後続テキストをコマンドラインとして解釈する構文エラーになり、さらに `$(...)` 形式の
# command substitution が literal 展開時に実行される command injection リスクを生む。
# PR body は外部入力 (PR 投稿者) であるため、 'PRBODY_EOF' (single-quote 付き delimiter)
# で expansion を完全に抑制することが必須。
cat > "$pr_body_tmp" <<'PRBODY_EOF'
{pr_body}
PRBODY_EOF
if [ ! -s "$pr_body_tmp" ]; then
  echo "ERROR: pr_body_tmp が空または存在しません: $pr_body_tmp" >&2
  echo "対処: PR body 自体が空であった可能性があります (gh pr view --json body の出力を確認)" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  # 他の WM_UPDATE_FAILED emit と一貫性を保つため
  # issue_number suffix を追加 (この経路では {issue_number} 抽出が完了前だが、上流 Phase 0.1
  # の作業メモリ由来値が placeholder 置換で入る。literal `{issue_number}` が残る場合でも
  # reason 表との invariant 維持の方を優先する)
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=pr_body_tmp_empty_or_missing; issue_number={issue_number}" >&2
  exit 1
fi

# grep の exit code を明示的に区別 (IO エラーと「マッチなし」を融合させない):
#   exit 0: マッチあり (期待動作)
#   exit 1: マッチなし (期待動作、no-op として fallback に進む)
#   exit 2: IO/権限/構文エラー (真のエラー、silent に握りつぶしてはならない)
#
# 重要 — 2 段 pipeline → 1 段独立 capture に変更:
# 旧実装 `grep -oE '...' "$pr_body_tmp" 2>"$err" | head -1 | grep -oE '[0-9]+'` は pipefail 下でも
# 先頭 grep の rc=2 (IO エラー) を捕捉できなかった。bash pipefail は **rightmost non-zero** を返すため、
# 末尾 grep が空入力に対し rc=1 (no match) を返すと pipeline 全体の rc は **1** になり、
# `case "$rc" in *) ...) reason=pr_body_grep_io_error` 分岐は到達不能 (実証: `(exit 2)|(exit 0)|(exit 1)` → rc=1)。
# M-1 で導入した defense-in-depth (`2>&1` 撤廃 + 独立 stderr 退避 + IO error は `*)` で捕捉) はその土台ごと
# 崩壊していた。本修正で先頭 grep を独立 if-else で実行し、grep の終了コードを直接 case 分岐する。
# 数字抽出は後続の sed -n に移譲 (sed の失敗は無害な空文字結果を返すため pipeline 化しても safe)。
# Source: bash man page / [Baeldung — Exit Status of Piped Processes](https://www.baeldung.com/linux/exit-status-piped-processes)
pr_body_grep_err=$(mktemp /tmp/rite-fix-pr-body-grep-err-XXXXXX) || {
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
      # IO/権限/構文エラー: H-2 で fail-fast から soft failure に統一:
      # 旧実装は `exit 1` で fix.md 全体を異常終了させる意図だったが、bash の `exit 1` は Bash tool の
      # exit code に変換されるだけで Claude のフロー制御にはならない (line 1868 に明記)。Claude は次の Phase
      # に進み、Phase 8.1 が会話履歴で `[CONTEXT] WM_UPDATE_FAILED=1` を検出して `[fix:pushed-wm-stale]` を
      # 出力する。コメント宣言 (`[fix:error]` 相当) と実動作の矛盾を解消するため、soft failure (exit 1 削除)
      # に統一する。これにより:
      # - retained flag の伝達経路が一貫する (Phase 4.5 の失敗は全て [fix:pushed-wm-stale] 経路)
      # - コミット済み fix の損失を防ぐ
      # - caller (review-fix loop) は AskUserQuestion で続行/中断を判断できる
      echo "ERROR: PR 本文の grep が IO/権限/構文エラーで失敗しました (rc=$pr_body_grep_rc)" >&2
      echo "詳細 (stderr 先頭 5 行):" >&2
      head -5 "$pr_body_grep_err" | sed 's/^/  /' >&2
      echo "  対処: 環境の grep バイナリと権限を確認後、再実行してください" >&2
      echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=pr_body_grep_io_error; rc=$pr_body_grep_rc" >&2
      # exit 1 を削除: soft failure として retained flag のみ emit、Phase 8.1 が [fix:pushed-wm-stale] を出力する
      # wm_emit_done=1 にすることで (M-5 対応):
      #   - 下流の branch fallback if 文が skip され、IO error 後に branch grep が誤起動しない
      #   - 下流の `if [[ -z "$issue_number" ]]` retained flag block も skip され、M-4 の 2 回連続 emit を防ぐ
      wm_emit_done=1
      issue_number=""  # branch fallback も skip して下流の WM_UPDATE_FAILED 経路に流す (M-5 対応)
      ;;
  esac
fi

# 2. PR 本文で見つからない場合、ブランチ名から抽出
# 同様に IO error と「マッチなし」を融合させない。
#
# 旧実装は
# `git branch --show-current 2>"$err" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+'`
# の 3 段 pipeline で、`git branch` の rc を末尾 grep の rc=1 (空入力) が隠蔽する
# pipefail 罠を持っていた。git branch の終了コードを直接 if-else で捕捉し、
# issue 番号抽出は sed -n に移譲する形に分解する。
# wm_emit_done guard (M-5 対応): pr_body grep IO error 経路で既に retained flag emit 済みの場合、
# branch fallback を実行せず skip する。旧実装は issue_number="" にするだけで直後の
# `if [[ -z "$issue_number" ]]` が常に true になり、branch grep が誤起動して意図しない
# 「IO error 経路なのに issue_number が設定される」semantics 破壊を引き起こしていた。
if [[ -z "$issue_number" ]] && [ "$wm_emit_done" = "0" ]; then
  branch_grep_err=$(mktemp /tmp/rite-fix-branch-grep-err-XXXXXX) || {
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
    branch_rc=$?
    # pr_body_grep_io_error と同根: H-2 修正で fail-fast から soft failure に統一
    # (exit 1 は Claude のフロー制御にならず Phase 8.1 の [fix:pushed-wm-stale] 経路に
    # 流れるため、retained flag のみ emit してコミット済み fix を保護する)
    echo "ERROR: branch 名取得 (git branch --show-current) が IO/権限エラーで失敗しました (rc=$branch_rc)" >&2
    echo "詳細 (stderr 先頭 5 行):" >&2
    head -5 "$branch_grep_err" | sed 's/^/  /' >&2
    echo "  対処: 環境の git バイナリと権限、cwd が git repo であることを確認後、再実行してください" >&2
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=branch_grep_io_error; rc=$branch_rc" >&2
    # exit 1 を削除: soft failure として retained flag のみ emit
    # wm_emit_done=1 により下流の retained flag block が skip される (M-4 対応: 2 回 emit 防止)
    wm_emit_done=1
    issue_number=""  # 下流 block は wm_emit_done guard で skip されるため stale WM 経路へ流れる
  fi
fi
# 注: set -o pipefail / set +o pipefail のペアは C-2 修正で削除済み。
# pipefail 仕様 (rightmost non-zero) による IO error 隠蔽を回避するため、grep / git branch を独立 if-else
# で実行し終了コードを直接捕捉する設計に切り替えた。pipefail 依存は不要。
```

> **Note**: `{pr_body}` is the `body` field from the Phase 1.1 result (retained in context). No additional `gh pr view` call is needed.

**Implementation note for Claude**: `{pr_body}` はドキュメントのプレースホルダ（Phase 4.3.4 の注記と同等）。Claude はスクリプト生成前に実際の PR body で置換する。**必ず single-quoted HEREDOC delimiter (`<<'PRBODY_EOF'`) を使う**こと — double-quoted printf 形式 (`printf '%s' "{pr_body}"`) は PR body 内の `"` でクォート閉じが起きると bash parser が後続テキストをコマンドラインとして解釈する構文エラーになり、さらに `$(...)` 形式の command substitution が literal 展開時に実行される **command injection リスク** を生む。PR body は外部入力 (PR 投稿者) であるため、shell expansion を完全抑制する HEREDOC が必須。

If no Issue number is found, display a warning **and emit a `WM_UPDATE_FAILED=1` retained flag** so the caller (`/rite:issue:start` review-fix loop) treats the result as `[fix:pushed-wm-stale]` instead of silently treating it as `[fix:pushed]`:

```bash
# Phase 4.5.1 で issue_number 抽出に失敗した場合の silent regression 防止 (HIGH-2 対応):
# 単に WARNING を出すだけだと、E2E flow / hook 経由実行で人間の目に見えず、
# `/rite:issue:start` review-fix loop が「work memory 更新失敗」を一切認識しないまま
# `[fix:pushed]` を silent 出力 → 次の loop iteration が stale work memory のまま続行する
# silent regression になる。これを防ぐため:
#   1. WARNING を stderr に出す (人間が tail で見えるケースのため)
#   2. retained flag `WM_UPDATE_FAILED=1` を context に明示宣言 (Phase 8 が読む)
# Phase 8.1 では `[CONTEXT] WM_UPDATE_FAILED=1` を検出した場合、`[fix:pushed]` ではなく
# `[fix:pushed-wm-stale]` を出力するルールを採用する (Phase 8.1 のテーブル参照)
#
# wm_emit_done guard (M-4 対応): 上流の pr_body_grep_io_error / branch_grep_io_error 経路で
# 既に retained flag が emit されている場合、ここでの重複 emit を防ぐ。
# 重複 emit は Phase 8.1 の reason 解釈が非決定的になり debug UX を悪化させる。
if [[ -z "$issue_number" ]] && [ "$wm_emit_done" = "0" ]; then
  echo "⚠️ Issue 番号が特定できないため作業メモリ更新をスキップしました" >&2
  echo "  PR 本文に Closes/Fixes/Resolves #XX が含まれていないか、ブランチ名に issue-{number} パターンがありません。" >&2
  echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
  echo "  対処: Phase 8.1 で WM_UPDATE_FAILED=1 を context に set し、[fix:pushed-wm-stale] を出力する" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=issue_number_not_found" >&2
  wm_emit_done=1
fi
# 注: set -o pipefail は C-2 修正で削除済み。
# pipefail rightmost non-zero 仕様により 2 段 grep pipeline の IO error が末尾 grep の rc=1 に
# 隠蔽される罠を避けるため、grep / git branch の終了コードを独立 if-else で直接捕捉する設計に
# 切り替えた。pipefail 依存は不要になったため arming/disarm のペアごと撤廃した。
```

> **⚠️ 重要 — Phase 4.5.2 を skip すること** (silent regression 防止):
>
> 上記 if ブロックで `[CONTEXT] WM_UPDATE_FAILED=1; reason=issue_number_not_found` が出力された場合、Claude は **Phase 4.5.2 の bash block を実行せず**、Phase 4.5.3 / Phase 4.6 / Phase 8 へ直接進むこと。
>
> **理由**: Phase 4.5.2 の bash block は `{issue_number}` placeholder を含む `gh api repos/{owner}/{repo}/issues/{issue_number}/comments` を呼ぶ。issue_number が空 (または未展開の literal `{issue_number}`) のまま実行すると、`repos/owner/repo/issues//comments` のような不正 URL を生成し、別の silent failure (gh api 404 / cryptic error) を引き起こす。WM_UPDATE_FAILED retained flag は既に設定済みなので、Phase 8.1 が `[fix:pushed-wm-stale]` を正しく出力する。
>
> bash の `return`/`exit` では Claude のフロー制御にはならない (各 phase は独立した Bash tool invocation のため) ため、ここでは prose 指示として明示する。

#### 4.5.2 Retrieve and Update Work Memory Comment

The work memory update performs **three operations** in a single Bash tool invocation:

1. **進捗サマリー更新**: Update the progress summary table to reflect implementation status
2. **変更ファイル更新**: Replace the changed files section with actual file changes from `git diff`
3. **レビュー対応履歴追記**: Append the review response history (4.5.3 content)

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
# comment_data の取得・更新内容の生成・PATCH を分割すると変数が失われる（Issue #693, #90）
#
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: 「パス先行宣言 → trap 先行設定 → mktemp」の順序、signal 別 exit code、${var:-} safety、関数契約)
#
# 本 site 固有: 統合 trap で保護する対象 (Phase 4.5.2 で作成される全一時ファイル)
# - gh_api_err: gh api の stderr 退避用 (H-1 で新設)
# - base_branch_grep_err: rite-config.yml grep の stderr 退避用 (M-3 で新設)
# - diff_stderr_tmp: git diff の stderr 退避用
# - body_tmp / tmpfile / files_tmp / history_tmp: Python 入出力用
# - pr_body_tmp: H-7 — Phase 4.5.1 と 4.5.2 が同一 Bash invocation で連結された場合の
#   trap 上書きによる orphan を defense-in-depth として防止
gh_api_err=""
base_branch_grep_err=""
diff_stderr_tmp=""
body_tmp=""
tmpfile=""
files_tmp=""
history_tmp=""
pr_body_tmp=""
_rite_fix_phase452_cleanup() {
  rm -f "${gh_api_err:-}" "${base_branch_grep_err:-}" "${diff_stderr_tmp:-}" \
        "${body_tmp:-}" "${tmpfile:-}" "${files_tmp:-}" "${history_tmp:-}" \
        "${pr_body_tmp:-}"
}
trap 'rc=$?; _rite_fix_phase452_cleanup; exit $rc' EXIT
trap '_rite_fix_phase452_cleanup; exit 130' INT
trap '_rite_fix_phase452_cleanup; exit 143' TERM
trap '_rite_fix_phase452_cleanup; exit 129' HUP

# gh api の stderr 退避ファイル (失敗時に 詳細を表示するため)
# mktemp 失敗時も retained flag を必ず emit (silent [fix:pushed] 防止):
# bash の `exit 1` は Claude のフロー制御にならず Phase 8.1 は retained flag 未検出で
# silent `[fix:pushed]` を出力するため、exit 前に `[CONTEXT] WM_UPDATE_FAILED=1` を必須で emit する。
gh_api_err=$(mktemp /tmp/rite-fix-gh-api-comments-err-XXXXXX) || {
  echo "ERROR: gh_api_err 一時ファイルの作成に失敗" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_gh_api_err; issue_number={issue_number}" >&2
  exit 1
}

# gh api 呼び出しに exit code check を追加:
# 旧実装 `comment_data=$(gh api ...)` は exit code を一切 check せず、
# 401/403/404/timeout/5xx で failure すると `$comment_data` が空 → `$comment_id` も空 →
# 外側の `if [[ -n "$comment_id" ]]` が false → else 分岐を持たないため全処理が silent no-op となり、
# Phase 8.1 が `[fix:pushed]` を出力する silent regression を起こす。
# `if ! ...` で exit code を捕捉し、失敗時は WM_UPDATE_FAILED を emit してから soft failure として進む
# (exit 1 はしない: 既にコミット/プッシュ済みの fix を保護するため、Phase 8.1 が
# `[fix:pushed-wm-stale]` を出力できるよう retained flag だけ set する)。
gh_api_failed=0
if ! comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
    --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}' \
    2>"$gh_api_err"); then
  echo "ERROR: gh api による作業メモリコメント取得に失敗 (HTTP error / network / auth)" >&2
  echo "  詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | sed 's/^/  /' >&2
  echo "  対処: gh auth status / network / Issue #{issue_number} の存在を確認後、再実行してください" >&2
  echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=gh_api_comments_fetch_failed; issue_number={issue_number}" >&2
  gh_api_failed=1
  comment_data=""  # 後続の jq 抽出を空文字 fallback で安全に通す
fi

# M-1/L-4 修正:
# (a) jq の exit code を独立 if-else で捕捉する (旧実装は exit code 未 check で jq バイナリ異常を
#     `comment_id=""` の silent 空文字化として隠蔽していた)
# (b) `echo "$comment_data"` を `printf '%s'` に統一する (echo は -e/-n prefixed 値で
#     implementation-defined behavior があり、他の jq 呼び出し全 41 箇所と統一性が崩れていた)
# gh_api_failed=1 経路では comment_data="" のため jq は exit 0 で empty を返す (legitimate no-op)
jq_late_err=$(mktemp /tmp/rite-fix-jq-late-err-XXXXXX) || {
  echo "ERROR: jq_late_err mktemp 失敗" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_jq_late_err; issue_number={issue_number}" >&2
  exit 1
}
if ! comment_id=$(printf '%s' "$comment_data" | jq -r '.id // empty' 2>"$jq_late_err"); then
  echo "ERROR: jq による .id 抽出に失敗: $(cat "$jq_late_err")" >&2
  echo "  対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=jq_comment_id_extract_failed; issue_number={issue_number}" >&2
  rm -f "$jq_late_err"
  exit 1
fi
if ! current_body=$(printf '%s' "$comment_data" | jq -r '.body // empty' 2>"$jq_late_err"); then
  echo "ERROR: jq による .body 抽出に失敗: $(cat "$jq_late_err")" >&2
  echo "  対処: jq バージョン (jq --version) と gh api の生レスポンスを確認してください" >&2
  echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=jq_current_body_extract_failed; issue_number={issue_number}" >&2
  rm -f "$jq_late_err"
  exit 1
fi
rm -f "$jq_late_err"

# comment_id 空ケースの分岐 (silent misclassification 防止):
# - gh_api_failed=1 → 既に上で WM_UPDATE_FAILED emit 済み → ここでは何もしない
# - gh_api_failed=0 かつ comment_id 空 → gh api 成功だが該当コメントなし (初回 fix / コメント削除済み)
#   → INFO log のみ、WM_UPDATE_FAILED は set しない (PATCH 不要のため stale ではない legitimate no-op)
if [[ -z "$comment_id" ]] && [ "$gh_api_failed" = "0" ]; then
  echo "INFO: 作業メモリコメント (📜 rite 作業メモリ) が PR/Issue 内に未検出 (legitimate no-op)" >&2
  echo "  原因候補: 初回 fix / コメント削除済み / 該当 Issue にまだ rite 作業メモリが投稿されていない" >&2
  echo "  この経路では PATCH 不要のため WM_UPDATE_FAILED は set せず通常終了します" >&2
fi

if [[ -n "$comment_id" ]]; then
  if [[ -z "$current_body" ]]; then
    # current_body 空時の silent fall-through 防止:
    # 単に stderr WARNING を出すだけだと、E2E flow (hook 経由実行) で人間に見えず、
    # `/rite:issue:start` review-fix loop が「work memory 更新失敗」を一切認識しないまま
    # `[fix:pushed]` を silent 出力 → 次の loop iteration が stale work memory のまま続行する
    # silent regression になる。これを防ぐため:
    #   1. ERROR を stderr に出す (人間が tail で見えるケースのため)
    #   2. retained flag `WM_UPDATE_FAILED=1` を context に明示宣言 (Phase 8 が読む)
    #   3. backup file path を提示 (debug 用)
    # Phase 8.1 では `[CONTEXT] WM_UPDATE_FAILED=1` を検出した場合、`[fix:pushed]` ではなく
    # `[fix:pushed-wm-stale]` を出力するルールを採用する (Phase 8.1 のテーブル参照)
    echo "ERROR: 作業メモリの本文取得に失敗 (current_body が empty)。更新をスキップします。" >&2
    echo "  原因: gh api comments の応答に body フィールドが欠落、または jq 抽出失敗の可能性" >&2
    echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
    echo "  対処: Phase 8.1 で WM_UPDATE_FAILED=1 を context に set し、[fix:pushed-wm-stale] を出力する" >&2
    echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=current_body_empty; comment_id=$comment_id" >&2
  else
    backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
    printf '%s' "$current_body" > "$backup_file"
    original_length=$(printf '%s' "$current_body" | wc -c)

    # Step 1: 変更ファイル一覧を取得
    # 注: git diff --name-status の stderr を suppress せず、エラー時は明示的に WARNING を出す
    # shallow clone / base branch 未 fetch で "unknown revision" 等が出た場合、silent に空文字に落ちると
    # work memory の変更ファイル一覧が「まだ変更はありません」と誤記録される silent regression の原因になる

    # 共有 sentinel 文字列定数 (bash 側 fallback marker と Python 側で文字列完全一致比較)
    # 文言を変更する場合、bash 側と Python 側 (後の python3 -c 内) を必ず同時に変更すること
    GIT_DIFF_FAILED_SENTINEL="__RITE_FIX_CHANGED_FILES_GIT_DIFF_FAILED__"

    # base_branch の解決 (silent fallback 防止):
    # 旧実装 `grep -E ... 2>/dev/null | head -1 | sed ... || echo "develop"` は以下を silent 化:
    #   - rite-config.yml 不在 (2>/dev/null で suppress)
    #   - permission denied / IO error (2>/dev/null で suppress)
    #   - `base:` キーなし (grep exit 1 → || echo "develop" で fallback)
    #   - sed 抽出失敗 (空文字 → || echo "develop" で fallback)
    # main / master を base にしているプロジェクトで silent に develop 誤使用 →
    # 下流 git diff origin/develop...HEAD が失敗 → sentinel 経路に落ちる連鎖 silent failure を起こす。
    # 対処: ファイル存在 check と grep の exit 1 / 2 区別を分離し、fallback 理由を WARNING で明示する。
    base_branch=""
    if [ ! -f rite-config.yml ]; then
      echo "WARNING: rite-config.yml が存在しないため base_branch を 'develop' に fallback します" >&2
      echo "  対処: rite plugin が正しくセットアップされていない可能性があります (/rite:init を実行)" >&2
      base_branch="develop"
    else
      # grep の exit 1 (no match) と exit 2 (IO error) を分離 (silent IO suppression 防止)
      base_branch_grep_err=$(mktemp /tmp/rite-fix-base-grep-err-XXXXXX) || {
        echo "ERROR: base_branch_grep_err 一時ファイルの作成に失敗" >&2
        echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
        echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_base_branch_grep_err; issue_number={issue_number}" >&2
        exit 1
      }
      # 旧 `if ! cmd; then rc=$?` パターンは bash 仕様上 `$?` が常に 0 を返すため、
      # command substitution + 明示的 rc 捕捉に変更して grep 自身の exit code を正しく取得する。
      base_branch_raw=$(grep -E '^\s*base:' rite-config.yml 2>"$base_branch_grep_err")
      base_branch_grep_rc=$?
      if [ "$base_branch_grep_rc" -ne 0 ]; then
        if [ "$base_branch_grep_rc" = "1" ]; then
          # exit 1: rite-config.yml に `base:` キーがない
          echo "WARNING: rite-config.yml に 'base:' キーが存在しないため base_branch を 'develop' に fallback します" >&2
          echo "  対処: rite-config.yml の branch.base を明示的に設定してください" >&2
          base_branch="develop"
        else
          # exit 2 以上: IO エラー / 権限エラー / 構文エラー — fail-fast
          echo "ERROR: rite-config.yml の grep が IO/権限エラーで失敗しました (rc=$base_branch_grep_rc)" >&2
          echo "  詳細: $(cat "$base_branch_grep_err")" >&2
          echo "  対処: rite-config.yml の権限を確認後、再実行してください" >&2
          echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
          echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=base_branch_grep_io_error; rc=$base_branch_grep_rc; issue_number={issue_number}" >&2
          rm -f "$base_branch_grep_err"
          exit 1
        fi
      else
        # grep 成功 — sed で値を抽出
        # sed の exit code を独立 capture
        # 旧実装は `base_branch=$(... | sed ...)` で sed 失敗を「値が空」fallback に隠蔽していた。
        # sed バイナリ異常 / pipe write error / signal 中断などの IO 系失敗を「キー値空」と区別するため、
        # sed のみを独立変数に capture し、`if ! ...` で exit code を判定する。
        # 「値が空」(sed 成功 + 抽出空) は legitimate fallback として develop に降格する。
        sed_err=$(mktemp /tmp/rite-fix-base-sed-err-XXXXXX) || {
          echo "ERROR: sed_err 一時ファイルの作成に失敗" >&2
          echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
          echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_sed_err; issue_number={issue_number}" >&2
          rm -f "$base_branch_grep_err"
          exit 1
        }
        base_branch_first_line=$(printf '%s' "$base_branch_raw" | head -1)
        # 同上の `if ! cmd; then rc=$?` パターン bash バグ修正
        base_branch_extracted=$(printf '%s' "$base_branch_first_line" | sed 's/.*base:\s*"\?\([^"]*\)"\?/\1/' 2>"$sed_err")
        sed_rc=$?
        if [ "$sed_rc" -ne 0 ]; then
          echo "ERROR: base_branch の sed 抽出が IO/binary エラーで失敗しました (rc=$sed_rc)" >&2
          echo "  詳細: $(cat "$sed_err")" >&2
          echo "  対処: 環境の sed バイナリと権限を確認後、再実行してください" >&2
          echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
          echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=sed_extract_base_branch_failed; rc=$sed_rc; issue_number={issue_number}" >&2
          rm -f "$sed_err" "$base_branch_grep_err"
          exit 1
        fi
        rm -f "$sed_err"
        base_branch="$base_branch_extracted"
        if [ -z "$base_branch" ]; then
          # legitimate fallback: sed 成功だが値が空 (`base:` のみで値なし、quote だけ、コメントアウト等)
          echo "WARNING: rite-config.yml の 'base:' キーから値を抽出できなかったため 'develop' に fallback します" >&2
          echo "  生値: $base_branch_raw" >&2
          base_branch="develop"
        fi
      fi
      rm -f "$base_branch_grep_err"
    fi

    diff_stderr_tmp=$(mktemp /tmp/rite-fix-git-diff-err-XXXXXX) || {
      echo "ERROR: git diff stderr 一時ファイルの作成に失敗" >&2
      echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_diff_stderr_tmp; issue_number={issue_number}" >&2
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
    #
    # 注: 統合 trap (`_rite_fix_phase452_cleanup`) は本 bash block 冒頭で既に設定済み。
    # body_tmp / tmpfile / files_tmp / history_tmp は冒頭で空文字宣言済みで cleanup 対象に
    # 含まれているため、ここでは mktemp のみを実行する (パス先行宣言 → trap 先行設定 → mktemp の
    # 順序が成立しており、race window は存在しない)。
    # mktemp 失敗経路も retained flag 必須 (silent [fix:pushed] 防止):
    body_tmp=$(mktemp) || {
      echo "ERROR: body_tmp mktemp 失敗" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_body_tmp; issue_number={issue_number}" >&2
      exit 1
    }
    tmpfile=$(mktemp) || {
      echo "ERROR: tmpfile mktemp 失敗" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_tmpfile; issue_number={issue_number}" >&2
      exit 1
    }
    files_tmp=$(mktemp) || {
      echo "ERROR: files_tmp mktemp 失敗" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_files_tmp; issue_number={issue_number}" >&2
      exit 1
    }
    history_tmp=$(mktemp) || {
      echo "ERROR: history_tmp mktemp 失敗" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=mktemp_failed_history_tmp; issue_number={issue_number}" >&2
      exit 1
    }
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
    # Python script の exit code semantics
    #
    # | py_exit | 意味 | bash 側の対応 |
    # |---------|------|---------------|
    # | 0 | Python script 正常終了 (body 更新成功) | 後続の Safety check + PATCH に進む |
    # | 2 | git diff failure marker を検出した (silent PATCH 拒否) | WM_UPDATE_FAILED=python_sentinel_detected emit + exit 1 |
    # | その他非 0 | Python 内部例外 / 致命的エラー (未捕捉例外、SyntaxError 等) | WM_UPDATE_FAILED=python_unexpected_exit_$py_exit emit + exit 1 |
    #
    # 規約: Python 側で `sys.exit(2)` は **GIT_DIFF_FAILED_SENTINEL マッチ専用** に予約されている。
    # 他の致命的エラーで Python が `sys.exit(2)` を返してはならない (bash 側が誤分類するため)。
    # 新しい sentinel を追加する場合は exit code を別の値 (3 以上) にし、本テーブルにも追加する。
    # この規約は Phase 4.5.2 のみで使用され、他 phase の Python script (現状なし) には適用されない。
    if [ "$py_exit" -eq 2 ]; then
      echo "ERROR: Python script detected git diff failure marker and refused to PATCH work memory silently." >&2
      # tmpfile の debug 参照を提供するため、exit 前に trap から tmpfile を除外して削除を防ぐ
      # (exit 時に trap が発火して tmpfile が消えると、下記の debug 案内が嘘になる)
      #
      # trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
      # (rationale: signal 別 exit code 130/143/129、関数契約、${var:-} safety)
      #
      # 本 site 固有: pr_body_tmp は通常 unset (別 bash invocation のスコープ変数) だが、Phase 4.5.1 と
      # Phase 4.5.2 が誤って同一 invocation に統合された場合の defense-in-depth として cleanup 対象に含める
      # (L-9 / H-7 同根)。tmpfile は debug 参照用に preserve する。
      _rite_fix_py_exit2_cleanup() {
        rm -f "${pr_body_tmp:-}" "${body_tmp:-}" "${files_tmp:-}" "${history_tmp:-}" \
              "${diff_stderr_tmp:-}" "${gh_api_err:-}" "${base_branch_grep_err:-}"
        # tmpfile は preserved for debug
      }
      trap 'rc=$?; _rite_fix_py_exit2_cleanup; exit $rc' EXIT
      trap '_rite_fix_py_exit2_cleanup; exit 130' INT
      trap '_rite_fix_py_exit2_cleanup; exit 143' TERM
      trap '_rite_fix_py_exit2_cleanup; exit 129' HUP
      echo "  Debug: visible WARNING block was injected into the body file and preserved at: $tmpfile" >&2
      echo "  Backup of original work memory: $backup_file" >&2
      echo "  Action: git diff の失敗原因を解決後、再実行してください (上記 stderr の git diff WARNING を参照)" >&2
      echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=python_sentinel_detected; backup=$backup_file; issue_number={issue_number}" >&2
      exit 1
    elif [ "$py_exit" -ne 0 ]; then
      echo "ERROR: Python script failed with unexpected exit code $py_exit. Backup: $backup_file" >&2
      echo "  影響: work memory 更新不可 (silent regression 防止のため retained flag を emit)" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=python_unexpected_exit_$py_exit; backup=$backup_file; issue_number={issue_number}" >&2
      exit 1
    fi

    # Safety checks before PATCH (see gh-cli-patterns.md)
    # 各 safety check failure でも retained flag を emit (silent [fix:pushed] 防止):
    # Python が body を書き出したが内容が壊れていた場合、PATCH を silent に skip すると
    # work memory が stale のまま fix loop が完走する。retained flag で Phase 8.1 に通知する。
    if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
      echo "ERROR: Updated body is empty or too short. Aborting PATCH. Backup: $backup_file" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_body_empty_or_too_short; backup=$backup_file; issue_number={issue_number}" >&2
      exit 1
    fi
    if ! grep -q '📜 rite 作業メモリ' "$tmpfile"; then
      echo "ERROR: Updated body missing work memory header. Backup: $backup_file" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_header_missing; backup=$backup_file; issue_number={issue_number}" >&2
      exit 1
    fi
    updated_length=$(wc -c < "$tmpfile")
    if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
      echo "ERROR: Updated body < 50% of original (${updated_length}/${original_length}). Aborting PATCH. Backup: $backup_file" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_body_too_small; updated=${updated_length}; original=${original_length}; backup=$backup_file; issue_number={issue_number}" >&2
      exit 1
    fi

    # PATCH 失敗時の silent regression 防止:
    # 従来の `|| echo "WARNING: PATCH failed"` は右辺 echo が exit 0 で pipeline 全体を成功扱いにし、
    # PATCH 失敗時に WM_UPDATE_FAILED が set されないまま `[fix:pushed]` 出力に流れる silent regression
    # の根本原因だった。`if !; ... fi` で囲み、失敗時に明示的に WM_UPDATE_FAILED retained flag を
    # 出力して Phase 8.1 が `[fix:pushed-wm-stale]` を出力できるようにする。
    #
    # `set -o pipefail` が必須: pipefail なしの `if ! jq | gh api` は pipeline 末尾 (`gh api`) の
    # exit code のみを判定するため、jq が失敗 (--rawfile error / 構文エラー) して空 stdout を返した場合に
    # gh api が空 body を受信して 422 等を返したかどうかが silent に握りつぶされる経路がある。
    # pipefail を有効化して pipe 全体の rc を捕捉する (block 終了時に元の状態へ戻す)。
    #
    # pipefail スコープの明文化
    # 本箇所の pipefail は **PATCH pipeline (jq | gh api PATCH) 周辺のみに限定** する設計選択である。
    # 他の `gh api` 呼び出し (Phase 4.5.2 line 2163 の `gh api .../comments` 等) は `if ! ...` で gh api 自体の
    # exit code を捕捉済みで、`--jq` filter は gh の内部処理により exit code が伝播するため独立 pipeline
    # 化していない (gh CLI 内部で `--jq` filter 失敗を gh の exit code に正しく反映する仕様、確認済み)。
    # 将来 gh CLI の `--jq` filter exit code 伝播仕様に regression が発生した場合は、defense-in-depth で
    # `--jq` を外して独立 jq pipeline + pipefail に分解することを検討する (本 PR 範囲外、Issue #354 等で追跡)。
    set -o pipefail
    if ! jq -n --rawfile body "$tmpfile" '{"body": $body}' \
        | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
          -X PATCH --input -; then
      echo "ERROR: work memory PATCH failed (gh api PATCH exit != 0)" >&2
      echo "  Backup: $backup_file" >&2
      echo "  影響: work memory が stale のまま fix loop が継続する silent regression のリスク" >&2
      echo "  対処: Phase 8.1 で WM_UPDATE_FAILED=1 を context に set し、[fix:pushed-wm-stale] を出力する" >&2
      echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=patch_failed; comment_id=$comment_id; backup=$backup_file" >&2
      # PATCH 失敗は致命的だが exit 1 はしない: caller (Phase 8.1) が WM_UPDATE_FAILED フラグを
      # 検出して [fix:pushed-wm-stale] を出力すれば、review-fix loop は stale 状態を認識した上で
      # AskUserQuestion 経由で続行/中断を判断できる。bash exit 1 で fix.md 全体を kill すると
      # コミット済みの fix 結果まで失われるため、retained flag による soft failure を採用する。
    fi
    set +o pipefail
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

**`{review_source}` / `{review_source_path_display}` の展開ルール** (verified-review cycle 9 I-1 対応、schema.md `Priority 1 emit 義務の理由` に記載された provenance log 契約の履行):

Phase 1.2.0 の `[CONTEXT] REVIEW_SOURCE=` emit が取る 5 つの値それぞれに対する展開ルールは以下の通り。

- Priority 0 (`--review-file <path>` 明示指定): review_source 値 = "explicit_file" / display = "path=${review_source_path}"
- Priority 1 (会話コンテキスト直接参照): review_source 値 = "conversation" / display = "p1_scan_turns=N, p1_scan_found=true/false"
- Priority 2 (`.rite/review-results/` 最新ファイル): review_source 値 = "local_file" / display = "path=${review_source_path}"
- Priority 3 (PR コメント Raw JSON / legacy Markdown): review_source 値 = "pr_comment" / display = "in-memory from PR comment"
- Priority 0 失敗 → Interactive Fallback 経路: review_source 値 = "fallback" / display = "interactive fallback"

Claude は Phase 1.2.0 の bash block stderr から `[CONTEXT] REVIEW_SOURCE=...; review_source_path=...` を会話コンテキストで読み取り、本 placeholder 展開時に substitute する。

**`{confidence_override_section}` の生成ルール** (Phase 1.2 best-effort parse の Confidence override 追跡義務):

| 状況 | 展開内容 |
|------|----------|
| `confidence_override_count == 0` | `なし` |
| `confidence_override_count >= 1` | 親 bullet と同一行に **`; ` 区切りで列挙** (改行なし、Markdown bullet 構造を壊さない) |

**`>= 1` のときの展開例** (`confidence_override_findings = ["src/foo.ts:42", "src/bar.ts:18"]` の場合):

```markdown
- **Confidence override**: src/foo.ts:42; src/bar.ts:18
```

**placeholder 責務分離**: `{confidence_override_section}` には **純粋に findings 一覧のみ** (`; ` 区切り) を入れる。policy override の説明文 (`外部ツール由来、Confidence 70 のまま 80+ ゲートをバイパスする policy override、ユーザー承認済み`) は Phase 4.3.4 の `{confidence_override_value}` placeholder の展開ルール (Phase 1.2 data flow 表参照) にのみ含まれる。

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
レビューソース: {review_source} ({review_source_path_display})
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
| 1 件以上 (override 適用あり) | `{N}` | ` ({file:line_1}; {file:line_2}; ...)` (先頭スペース付きカッコ内に `; ` 区切りで一覧、Phase 1.2 の data flow 定義と統一) |

**重要**: `confidence_override_count == 0` の場合でも本行は省略せず常に表示する (override が「なし」であることを明示し、silent な policy bypass の有無を可視化するため)。

**Field descriptions:**

| Field | Description | Calculation |
|-------|-------------|-------------|
| `全指摘: {total_count}件` | Total number of findings | Number of review comment findings retrieved in Phase 1 |
| `対応した指摘: {count}件` | Number of findings addressed | `fix_count + reply_count + skip_count` |
| `Confidence override (policy bypass): {N}件` | Number of findings imported via Confidence policy override | Phase 1.2 best-effort parse で「Confidence 70 のままバイパス」を選択した finding 数 (Confidence 80+ ゲート invariant の policy override 追跡義務)。0 件でも常時表示 |
| `レビューソース: {review_source} (...)` | Provenance of the review findings consumed by this fix run | Phase 1.2.0 Priority chain で決定された `review_source` 値 (verified-review cycle 9 I-1 対応、schema.md Priority 1 emit 義務の provenance 契約を Phase 4.6 で履行)。展開ルールは Phase 4.5.3 の `{review_source}` / `{review_source_path_display}` 表を参照 |

**Note**: The review-fix loop of `/rite:issue:start` checks the content of this completion report to determine the next action:
- `プッシュ: 完了` -> Execute re-review (verify fix content)
- `別 Issue 作成: N件` (N >= 1) -> Execute re-review (confirm skipped findings are managed)
- `プッシュ: 未実行` and `別 Issue 作成: 0件` and `全指摘 == 対応指摘` -> Proceed to completion report (all addressed via replies)

---

## Workflow Incident Emit Helper (#366)

> **Reference**: See [workflow-incident-emit-protocol.md](../../references/workflow-incident-emit-protocol.md) for the emit protocol and Sentinel Visibility Rule.

This skill emits sentinels for the following failure paths:

| Failure Path | Sentinel Type | Details |
|--------------|---------------|---------|
| File modification error in Phase 2 (Edit/Write tool returns error and fix is skipped) | `hook_abnormal_exit` | `rite:pr:fix file modification skipped: {file_path}` |
| Work memory PATCH retry exhausted in Phase 4.5 | `hook_abnormal_exit` | `rite:pr:fix work memory PATCH failed after retries` |
| Commit failure that cannot be auto-resolved in Phase 3.3 | `hook_abnormal_exit` | `rite:pr:fix commit failure` |

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When PR is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When Comment Retrieval Fails | ネットワーク接続を確認; `gh auth status` で認証状態を確認 |
| Error During File Modification | この指摘をスキップして続行 / 手動で修正 (sentinel emit via Workflow Incident Emit Helper above) |
| Commit Failure | `git status` で状態を確認; 問題を解決してから再度コミット (sentinel emit via Workflow Incident Emit Helper above) |

## Phase 8: End-to-End Flow Continuation (Output Pattern)

> **This phase is executed only within the end-to-end flow (within the review-fix loop of `/rite:issue:start`). Skip for standalone execution.**

**用語定義**:

本 fix.md 内では以下の用語を厳密に区別して使う:

| 用語 | 定義 | 対応する fix.md の挙動 |
|------|------|----------------------|
| **soft failure** | 致命的だが exit 1 で fix loop を kill せず、retained flag (`[CONTEXT] WM_UPDATE_FAILED=1` 等) を emit してから caller に判断を委ねる失敗 | Phase 4.5 の grep IO エラー / current_body 空 / PATCH 失敗 / Issue create 失敗 等。Phase 8.1 評価順テーブル (現行値) で `[fix:error]` または `[fix:pushed-wm-stale]` に昇格する。詳細な行番号は Phase 8.1 のテーブルを参照すること (literal 行参照は drift 防止のため意図的に省略)。 |
| **silent regression** | soft failure を caller が silent に handle した結果 (例: `[fix:pushed]` と誤判定して次の iteration に進む)。本 PR で防止対象とする root cause | 本 PR 全体の防止対象。retained flag 機構と Phase 8.1 評価順により caller に必ず通知される |
| **stale (work memory stale)** | work memory comment が最新の fix 内容を反映していない状態 | `[fix:pushed-wm-stale]` 出力時の semantics。caller は AskUserQuestion で続行/中断を選択 |
| **hard fail-fast** | 即座に exit 1 で fix loop を kill し、コミット済み fix も含めて全停止する失敗 | Phase 1.0 引数 parse 失敗 / mktemp 失敗 / git diff 失敗 (Python sentinel 経路) 等。bash の `exit 1` だけでは Claude flow control にならないため retained flag も併用する |

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
  --next "rite:pr:fix completed. Check recent result pattern in context: [fix:pushed]->Phase 5.4.1 (re-review). [fix:pushed-wm-stale]->Phase 5.4.1 with WM stale warning (work memory was not updated, manual intervention recommended). [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->Phase 5.5. Do NOT stop." \
  --if-exists
```

**Note on `error_count`**: `flow-state-update.sh` patch mode resets `error_count` to 0 on every phase transition (since #294). This prevents stale circuit breaker counts from one phase from poisoning subsequent phases.

**Also update local work memory** (`.rite-work-memory/issue-{n}.md`) with phase transition:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md) for details and marketplace install notes.

```bash
# hook stderr を退避して lock failure と他 failure を区別する
# 旧実装 `2>/dev/null || true` は hook の lock contention だけでなく
# permission denied / script 不在 / bash syntax error / 内部致命的エラー もすべて silent suppress していた。
# stderr を tempfile に退避し、失敗時に lock 系メッセージを含むかを check して 2 ケースに分岐する。
hook_err=$(mktemp /tmp/rite-fix-hook-err-XXXXXX) || {
  echo "WARNING: hook_err mktemp 失敗 — local work memory hook を skip します (E2E flow 続行)" >&2
  hook_err=""
}
if [ -n "$hook_err" ]; then
  # 旧 `if ! cmd; then hook_rc=$?` パターンは bash 仕様上 `$?` が常に 0 を返す。
  # `if cmd; then :; else rc=$?; fi` の else 節形式に切り替えて hook 自身の exit code を正しく取得する。
  if WM_SOURCE="fix" \
      WM_PHASE="phase5_post_fix" \
      WM_PHASE_DETAIL="レビュー修正後処理" \
      WM_NEXT_ACTION="re-review or completion" \
      WM_BODY_TEXT="Post-fix sync." \
      WM_ISSUE_NUMBER="{issue_number}" \
      bash {plugin_root}/hooks/local-wm-update.sh 2>"$hook_err"; then
    : # success
  else
    hook_rc=$?
    # cycle 10 S-1 の exact phrase pattern に統一 (旧 `lock|contention|busy` は
    # permission denied / device busy / resource busy 等を silent suppress する欠陥パターン。
    # canonical helper を common-error-handling.md#hook-lock-contention-classification-canonical で定義)
    if grep -qiE '(file is locked|lock contention|resource busy)' "$hook_err"; then
      # lock failure (best-effort skip 該当): WARNING のみで継続
      echo "WARNING: local work memory lock contention (best-effort skip, rc=$hook_rc)" >&2
    else
      # 非 lock failure: hook 自体の障害 (script 不在 / permission / syntax / internal error)
      echo "WARNING: local work memory update hook failed (non-lock failure, rc=$hook_rc):" >&2
      head -5 "$hook_err" | sed 's/^/  /' >&2
      echo "  対処: hooks/local-wm-update.sh の存在 / 実行権限 / 内容を確認してください" >&2
      echo "  影響: local .rite-work-memory/issue-*.md が GitHub comment 側と一時的に不整合になる (E2E flow は続行)" >&2
    fi
  fi
  rm -f "$hook_err"
else
  # hook_err mktemp に失敗した場合は stderr を単一行退避経路に切り替えて WARNING を可視化する。
  # 旧実装 `2>/dev/null || true` は L-5 修正の意図と矛盾し、
  # mktemp 失敗時に silent skip に戻る非対称な経路だった。stderr を一時的に 2>&1 経由で stdout 統合し、
  # head -5 で上位 5 行のみ保持する簡易 fallback に変更する。
  echo "WARNING: hook_err mktemp 失敗により local-wm-update.sh の stderr 詳細が取得できません" >&2
  if hook_combined=$(WM_SOURCE="fix" \
        WM_PHASE="phase5_post_fix" \
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

Then, based on the Phase 4.6 completion report content **and the WM_UPDATE_FAILED context flag**, output the corresponding machine-readable pattern:

| 評価順 | Condition | Output Pattern |
|--------|-----------|---------------|
| 1 (最優先) | Phase 1.0.1 / 1.2.0 / 1.2.0.1 で `[CONTEXT] FIX_FALLBACK_FAILED=1` を context に set した (`reason` の値は Phase 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons table を **唯一の真実の源** として参照する。本セルでの固定列挙は drift 防止のため行わない) | `[fix:error]` (Phase 1.0.1 / 1.2.0 / 1.2.0.1 のレビューソース解決失敗。fallback 経路が尽きたか、ユーザーが Interactive Fallback で中止を選んだか、ファイルパス指定が 3 回連続で失敗した状態のため caller は手動介入を促す) |
| 2 | Phase 2.4 / 4.2 / 4.3.4 で `[CONTEXT] REPLY_POST_FAILED=1` / `[CONTEXT] REPORT_POST_FAILED=1` / `[CONTEXT] ISSUE_CREATE_FAILED=1` のいずれかを context に set した | `[fix:error]` (reply post / report post / Issue 化のいずれかが失敗。push 済みの可能性はあるが、レビュアー通知 / 完了報告 / 別 Issue 追跡の責務を果たせていないため caller は次の iteration ではなく手動介入を促す) |
| 3 | Phase 4.5 (4.5.1 または 4.5.2) で `[CONTEXT] WM_UPDATE_FAILED=1` を context に set した (`reason` の値は下記 reason 表のいずれか — 固定列挙は行わず、reason 表を唯一の真実の源とする) | `[fix:pushed-wm-stale]` (Phase 4.5 で work memory 更新が silent skip された旨を caller に明示伝達。caller は work memory が stale であることを認識して fix loop を再実行するか手動介入する) |
| 4 | Push completed (`プッシュ: 完了`) かつ work memory 更新成功 | `[fix:pushed]` |
| 5 | Separate Issues created (N >= 1) | `[fix:issues-created:{count}]` |
| 6 | All findings replied (no push, no separate Issues) | `[fix:replied-only]` |
| 7 | Unexpected state / error | `[fix:error]` |

**評価順序の重要性**: 上から順に評価し、最初にマッチした条件の output pattern を採用する。`FIX_FALLBACK_FAILED=1` / `REPLY_POST_FAILED=1` / `REPORT_POST_FAILED=1` / `ISSUE_CREATE_FAILED=1` の検出は最優先で、これらが set された場合は `[fix:error]` に昇格する。次に `WM_UPDATE_FAILED=1` を評価し、set されていれば `[fix:pushed-wm-stale]` に昇格する (silent regression 防止のため `[fix:pushed]` よりも先に判定する)。これらの retained flag をすべて評価した後に push 成功 / Issue 作成 / 返信のみ などの通常終了状態を判定する。

**`[CONTEXT] WM_UPDATE_FAILED=1` の検出方法** (Claude による retain と再注入):

Phase 4.5.1 または Phase 4.5.2 の bash block が stdout に `[CONTEXT] WM_UPDATE_FAILED=1; reason=...; ...` を出力した場合、Claude は会話履歴からこの行を検索し、検出された場合は本 phase の Output Pattern 評価で `[fix:pushed-wm-stale]` を採用する。検出されなかった場合は通常の評価順序 (条件 2 以降) に従う。

**`reason` フィールドの取りうる値** (Phase 4.5.1 / 4.5.2 で発火する経路の網羅):

> **完全性保証**: 本表は fix.md 内で `echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=..."` として emit されるすべての reason を網羅する。DoD 検証スクリプト (手動実行、実測空出力で一致確認済み):
> ```bash
> comm -3 \
>   <(grep -oE 'WM_UPDATE_FAILED=1; reason=[a-z_][a-z_0-9]*' plugins/rite/commands/pr/fix.md \
>     | sed 's/.*reason=//' | sort -u) \
>   <(awk '/^\*\*`reason` フィールド/{in_table=1; next} in_table && /^\*\*/{in_table=0} in_table && /^\| `[a-z_]/{match($0, /`[a-z_][a-z_0-9]*[^`]*`/); print substr($0, RSTART+1, RLENGTH-2)}' plugins/rite/commands/pr/fix.md \
>     | sed 's/\$.*//' | sort -u)
> # → 空出力 (完全一致)
> ```
>
> **設計上の要点**:
> - `grep` 側は `WM_UPDATE_FAILED=1; reason=` で prefix を絞り、`CONFIDENCE_OVERRIDE_READ_FAILED` / `REPLY_POST_FAILED` / `REPORT_POST_FAILED` / `ISSUE_CREATE_FAILED` の別 context flag を自動除外する (前方一致による一発フィルタ)
> - `awk` 側は `**\`reason\` フィールド` セクションから次の `**` heading までを `in_table=1` 範囲とし、fix.md 内の他テーブル (`auto` / `en` / `ja` / `confidence_override_count` / `confidence_override_findings` / `project_registration` 等) を拾わない
> - `sed 's/\$.*//'` で `python_unexpected_exit_$py_exit` のような shell 変数展開部分を切り落とし、両側で同じ prefix (`python_unexpected_exit_`) として比較する

| reason | 発生 Phase | 発生条件 |
|--------|------------|----------|
| `mktemp_failed_pr_body_tmp` | Phase 4.5.1 | PR body 退避用 tempfile の mktemp が失敗 (disk full / permission denied) |
| `pr_body_tmp_empty_or_missing` | Phase 4.5.1 | `cat <<PRBODY_EOF > pr_body_tmp` 後の `[ -s pr_body_tmp ]` 検査が失敗 (PR body が空 or write 失敗) |
| `mktemp_failed_pr_body_grep_err` | Phase 4.5.1 | PR 本文 grep の stderr 退避 tempfile の mktemp が失敗 |
| `pr_body_grep_io_error` | Phase 4.5.1 | PR 本文 grep が IO/権限/構文エラー (rc=2) で失敗 |
| `mktemp_failed_branch_grep_err` | Phase 4.5.1 | branch 名抽出 grep の stderr 退避 tempfile の mktemp が失敗 |
| `branch_grep_io_error` | Phase 4.5.1 | branch 名抽出 grep が IO/権限エラーで失敗 |
| `issue_number_not_found` | Phase 4.5.1 | PR 本文に `Closes/Fixes/Resolves #N` がなく、ブランチ名にも `issue-N` がない |
| `mktemp_failed_gh_api_err` | Phase 4.5.2 | `gh api` stderr 退避用 tempfile の mktemp が失敗 |
| `gh_api_comments_fetch_failed` | Phase 4.5.2 | `gh api ... /issues/{issue_number}/comments` が exit != 0 で失敗 (401/403/404/timeout/5xx 等) |
| `mktemp_failed_jq_late_err` | Phase 4.5.2 | jq stderr 退避用 tempfile の mktemp が失敗 (M-1/L-4 対応) |
| `jq_comment_id_extract_failed` | Phase 4.5.2 | `jq -r '.id // empty'` が exit != 0 で失敗 (jq バイナリ異常 / OOM / parse error) |
| `jq_current_body_extract_failed` | Phase 4.5.2 | `jq -r '.body // empty'` が exit != 0 で失敗 (同上) |
| `current_body_empty` | Phase 4.5.2 | gh api 成功だが `.body` フィールド抽出が空 |
| `mktemp_failed_base_branch_grep_err` | Phase 4.5.2 | base_branch 抽出 grep の stderr 退避 tempfile の mktemp が失敗 |
| `base_branch_grep_io_error` | Phase 4.5.2 | rite-config.yml `base:` 値の grep 抽出が IO/権限エラーで失敗 |
| `mktemp_failed_sed_err` | Phase 4.5.2 | base_branch 抽出 sed の stderr 退避 tempfile の mktemp が失敗 (M-3 対応) |
| `sed_extract_base_branch_failed` | Phase 4.5.2 | rite-config.yml `base:` 値の sed 抽出が IO/binary エラーで失敗 (sed 成功で値が空の場合は legitimate develop fallback で WM_UPDATE_FAILED は emit しない) |
| `mktemp_failed_diff_stderr_tmp` | Phase 4.5.2 | `git diff` stderr 退避用 tempfile の mktemp が失敗 |
| `mktemp_failed_body_tmp` | Phase 4.5.2 | 更新後 body 保存用 tempfile の mktemp が失敗 |
| `mktemp_failed_tmpfile` | Phase 4.5.2 | 汎用 tempfile の mktemp が失敗 (Python scratch 等) |
| `mktemp_failed_files_tmp` | Phase 4.5.2 | 変更ファイル一覧退避用 tempfile の mktemp が失敗 |
| `mktemp_failed_history_tmp` | Phase 4.5.2 | 履歴退避用 tempfile の mktemp が失敗 |
| `python_sentinel_detected` | Phase 4.5.2 | Python スクリプトが `GIT_DIFF_FAILED_SENTINEL` を検出し `sys.exit(2)` で異常終了 (`git diff` 失敗による silent PATCH 拒否専用。`python_unexpected_exit_$py_exit` と異なり、この label は git diff 失敗経路に**予約**されている。詳細は fix.md 内 "`sys.exit(2)` は GIT_DIFF_FAILED_SENTINEL マッチ専用に予約" 段落を参照) |
| `python_unexpected_exit_$py_exit` | Phase 4.5.2 | Python スクリプトが非ゼロ exit code で異常終了 (`$py_exit` は実測 exit code に展開) |
| `wm_body_empty_or_too_short` | Phase 4.5.2 | 更新後 work memory body が空 or 最小長 (10 bytes) 未満で棄却 |
| `wm_header_missing` | Phase 4.5.2 | 更新後 work memory body に `📜 rite 作業メモリ` header が欠落 |
| `wm_body_too_small` | Phase 4.5.2 | 更新後 work memory body が元サイズの 50% 未満で棄却 (大量削除検出) |
| `patch_failed` | Phase 4.5.2 | `jq \| gh api PATCH` pipeline が失敗 |
| `cat_redirection_failed` | Phase 2.4 / 4.2 / 4.3.4 | cat heredoc redirection の exit code が非ゼロ (disk full / write permission denied / IO error) |
| `empty_stdout` | Phase 1.2 / 4.3.4 | gh api が exit 0 だが stdout が空または null |
| `missing_issue_url` | Phase 1.2 / 4.3.4 | レスポンスに `.issue_url` フィールドが存在しない |
| `mktemp_failed_issue_body_tmpfile` | Phase 4.3.4 | Issue body 用 tempfile の mktemp が失敗 |
| `mktemp_failed_override_err` | Phase 1.3 | confidence override stderr 退避用 tempfile の mktemp が失敗 |
| `mktemp_failed_reply_tmpfile` | Phase 2.4 | reply body 用 tempfile の mktemp が失敗 |
| `mktemp_failed_report_tmpfile` | Phase 4.2 | report body 用 tempfile の mktemp が失敗 |
| `paste_io_error` | Phase 1.2 / 1.3 | printf / ファイル書き出しが IO エラーで失敗 |
| `pr_number_mismatch` | Phase 1.2 | コメントの所属 PR と指定 pr_number が一致しない (silent misclassification) |
| `python_unexpected_exit_` | Phase 4.5.2 | Python スクリプトが非ゼロ exit code で異常終了 (suffix は実測 exit code) |
| `reply_tmpfile_empty` | Phase 2.4 | reply body の tmpfile が cat 成功だが空 |
| `script_exit_` | Phase 4.3.4 | Issue 作成スクリプトが非ゼロ exit code で終了 (suffix は実測 exit code) |
| `wc_io_error` | Phase 1.3 | `wc -l` が IO エラーで失敗 |
| `raw_json_write_failed` | Phase 1.2 Fast Path Block A | Block A の raw JSON 中間ファイル (`/tmp/rite-fix-raw-{pr}-{cid}.json`) への printf 書き出しが IO エラーで失敗 (Issue #390) |
| `jq_author_extract_failed` | Phase 1.2 Fast Path Block A | Block A の `jq -r '.user.login // empty'` が exit != 0 で失敗 (jq バイナリ異常 / OOM / parse error) |
| `raw_json_missing_at_block_b` | Phase 1.2 Fast Path Block B | Block B 進入時に Block A の raw JSON 中間ファイルが存在しない or 空 (Block A 失敗 / 並列実行で削除 / orchestrator 異常終了で Block B 未到達) |
| `mktemp_failed_jq_block_b` | Phase 1.2 Fast Path Block B | Block B の jq stderr 退避用 tempfile の mktemp が失敗 |
| `intermediate_missing_at_block_c` | Phase 1.2 Fast Path Block C | Block C 進入時に Block A/B が作成したはずの intermediate ファイル (body/author/skip) または raw_json が存在しない or 空 |
| `intermediate_write_failed` | Phase 1.2 Fast Path Block A | Block A の intermediate 3 ファイル (body/author/skip) への printf 書き出しが IO エラーで失敗 (disk full / read-only / inode 枯渇 / permission denied) |
| `author_file_missing_at_post_condition` | Phase 1.2 Fast Path Block C | Block C の post-condition check で author_file が存在しない (`[ -f ]` 失敗、empty は許容) |
| `skip_file_empty_at_post_condition` | Phase 1.2 Fast Path Block C | Block C の post-condition check で skip_file が空または存在しない (`[ -s ]` 失敗) |

> **全 reason 値の完全列挙** (drift-check P5 用): (`author_file_missing_at_post_condition` / `base_branch_grep_io_error` / `branch_grep_io_error` / `cat_redirection_failed` / `current_body_empty` / `empty_stdout` / `gh_api_comments_fetch_failed` / `intermediate_missing_at_block_c` / `intermediate_write_failed` / `issue_number_not_found` / `jq_author_extract_failed` / `jq_comment_id_extract_failed` / `jq_current_body_extract_failed` / `missing_issue_url` / `mktemp_failed_base_branch_grep_err` / `mktemp_failed_body_tmp` / `mktemp_failed_branch_grep_err` / `mktemp_failed_diff_stderr_tmp` / `mktemp_failed_files_tmp` / `mktemp_failed_gh_api_err` / `mktemp_failed_history_tmp` / `mktemp_failed_issue_body_tmpfile` / `mktemp_failed_jq_block_b` / `mktemp_failed_jq_late_err` / `mktemp_failed_override_err` / `mktemp_failed_pr_body_grep_err` / `mktemp_failed_pr_body_tmp` / `mktemp_failed_reply_tmpfile` / `mktemp_failed_report_tmpfile` / `mktemp_failed_sed_err` / `mktemp_failed_tmpfile` / `paste_io_error` / `patch_failed` / `pr_body_grep_io_error` / `pr_body_tmp_empty_or_missing` / `pr_number_mismatch` / `python_sentinel_detected` / `python_unexpected_exit_` / `raw_json_missing_at_block_b` / `raw_json_write_failed` / `reply_tmpfile_empty` / `script_exit_` / `sed_extract_base_branch_failed` / `skip_file_empty_at_post_condition` / `wc_io_error` / `wm_body_empty_or_too_short` / `wm_body_too_small` / `wm_header_missing`)

**`[fix:pushed-wm-stale]` の caller 側 semantics**: `/rite:issue:start` review-fix loop は本 pattern を受け取った場合、push 自体は完了しているが work memory が stale であることを認識し、次のいずれかを実行する: (a) 手動介入を促す (推奨)、(b) 警告ログを出した上で次の iteration に進む (loop 継続)。silent に `[fix:pushed]` 扱いしてはならない。

**Important**:
- Do **NOT** invoke `rite:pr:review` via the Skill tool
- Return control to the caller (`/rite:issue:start`)
- The caller determines the next action based on this output pattern

**Confidence override tempfile cleanup** (silent orphan 防止):

Phase 8.1 の output pattern emit 直後に、fix ループ全体で使用していた confidence_override tempfile を明示的に削除する。specific path 必須 (並列セッション破壊防止)。

```bash
# confidence_override + pr-comment tempfile の明示的 cleanup (E2E flow 経路)
# fix ループ全体で append されてきたファイルを終了時に削除する。
# 削除しないと次回実行時の truncate (`: >`) に依存するが、truncate 忘れの経路があった場合に
# 前セッションの stale データが混入する silent regression のリスクがあるため defense-in-depth で削除する。
# pr-comment tempfile も追加 (Broad Retrieval が書き出した
# /tmp/rite-fix-pr-comment-{pr_number}.txt の正常時 cleanup)。Fast Path 経路では存在しないため
# silent no-op となる。
rm -f "/tmp/rite-fix-confidence-override-{pr_number}.txt" \
      "/tmp/rite-fix-pr-comment-{pr_number}.txt"
```

**Work memory backup_file cleanup** (累積汚染防止 / C1 で恒久 no-op 修正):

Phase 4.5.2 で `current_body` を `/tmp/rite-wm-backup-{issue_number}-{epoch}.md` に backup している (failed PATCH 時の debug 用)。Phase 8.1 で output pattern が `[fix:pushed]` または `[fix:issues-created:N]` (= 成功経路) の場合、backup_file は debug に不要なため明示削除する。失敗経路 (`[fix:pushed-wm-stale]` / `[fix:error]`) では debug 用に preserve する。

**Claude の実行ルール** (C1 修正: 旧 `case "$output_pattern"` 版は変数未定義で恒久 no-op だったため撤去):

Phase 8.1 で output pattern を決定した直後、Claude は自分が emit した output pattern を記憶し、以下の判定に基づいて bash コマンドを実行する or skip する:

- **成功経路** (`[fix:pushed]` または `[fix:issues-created:N]`): 以下の `rm -f` を実行する
- **失敗経路** (`[fix:pushed-wm-stale]` または `[fix:error]` または `[fix:replied-only]`): backup_file を debug 用に preserve するため **bash コマンドを skip する** (実行しない)

```bash
rm -f /tmp/rite-wm-backup-{issue_number}-*.md
```

**Note**:
- wildcard glob は同一 `{issue_number}` prefix に絞られているため並列セッション破壊リスクは限定的 (同一 issue を 2 セッションで同時 fix するケースが現実的に存在しないため)。`backup_file` の specific path 化は Issue #355 Phase A の drift cleanup scope で追加改善する。
- `2>/dev/null || true` は silent failure 抑制に該当するため撤廃済み (`rm -f` は non-existent file に対して exit 0 で、実在ファイルでも permission 違反以外はエラーにならない)。permission 違反が発生した場合は stderr に出力されて可視化される方が debug しやすい。

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

**Confidence override tempfile cleanup** (Standalone 経路の orphan 防止):

Standalone 実行では Phase 8 が skip されるため、Phase 4.6 の completion report 出力**直後**に明示的な cleanup bash block を実行して confidence_override tempfile を削除する。これを忘れると `/tmp/rite-fix-confidence-override-{pr_number}.txt` が orphan として永続残留し、次回同 PR 実行時に `touch` ではなく `: >` truncate を入れていても、何らかの経路で truncate 呼び出しが skip された場合に stale データが混入するリスクがある (defense-in-depth)。

```bash
# Phase 8.2 Standalone 経路: confidence_override + pr-comment tempfile の明示的 cleanup
# 実行タイミング: Phase 4.6 の completion report を表示した直後
# {pr_number} は Claude が Phase 1.0 の parse 結果で事前置換済み
# pr-comment tempfile も追加
rm -f "/tmp/rite-fix-confidence-override-{pr_number}.txt" \
      "/tmp/rite-fix-pr-comment-{pr_number}.txt"
```

**Idempotency**: override tempfile が作成されなかった経路 (confidence override 発動なし) では `rm -f` は silent no-op となり安全。
