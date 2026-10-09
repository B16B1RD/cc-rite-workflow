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

> 実行入口と工程境界は [Host Runtime Contract](../../references/host-runtime-contract.md#入口と工程境界)、native Skill / Task がない場合の実行は [Host workflow operations](../../references/host-workflow-operations.md) に従う。nested 呼出しは caller の runtime 選択を引き継ぐ。

> セッション worktree 入場後にシェルブロックがホストの隔離ガードに拒否されたら、[共通作業先契約](../../references/git-worktree-patterns.md#host-worktree-execution) の「入場後のガード拒否の退路」に従う。

> **質問規律**: すべての質問・fallback 判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。

PR レビューコメントを取得・整理し、指摘への対応を効率的に支援する。やることは以下のシーケンシャルなタスク列:

0. Work Memory のロード (E2E フロー時のみ)
1. レビューコメントの取得と整理
2. 修正支援
3. 修正のコミット
4. 完了報告
5. E2E フロー継続 (出力パターン)

途中で止まったら flow-state に `phase=fix` が残るので `/rite:recover` で再開する。

`/rite:iterate` の review-fix loop から「not mergeable」評価時に自動 invoke される。**fatal finding と未解決の外部レビューを修正対象とする**。fatal は実測済みの current-pr/follow-up のうち、CRITICAL/HIGH か、class A・降格の除外判別子が付いた class B のうち PR 起因（`pre_existing: true` でない）のもののみ。完了後 machine-readable output pattern を emit し caller に制御返却。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number, review findings from `/rite:pr-review`, flow state with `phase: fix` (iterate fix side) or `phase: phase5_fix` (legacy resume)
**Output**: `[fix:pushed]` | `[fix:pushed-wm-stale]` | `[fix:non-fatal-only]` | `[fix:replied-only]` | `[fix:cancelled-by-user]` | `[fix:sweep-done]` | `[fix:error]`
rationale: references/design-rationale.md#contract-legacy-phase

## Inline Annotation Convention

本ファイル内の `verified-review` 注釈 (`H-N` / `M-N` / `C-3` 等の重要度プレフィックス + 通番、括弧内 `(M10)` 等の統合追跡 ID) はレビュー指摘の対応追跡用。詳細: [design-rationale.md#inline-annotation-convention](references/design-rationale.md#inline-annotation-convention)

## Prerequisites

bash 4.0+ 必須 (複数の bash block で `mapfile -t < <(...)` builtin を使用)。ステップ 1.0.1 が呼ぶ `scripts/fix-step.sh parse-args` の冒頭 (Step 0) に [bash-compat-guard.md](../../references/bash-compat-guard.md) の canonical guard を置いている (C-3 対応)。失敗時は `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=bash_version_incompatible` を emit して `[fix:error]` で exit する。

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
[fix:{result}] — {fixed_count} fixed, {files_changed} files changed; non_fatal_moved={non_fatal_moved_count}; review_json={triage_review_path}
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
bash {plugin_root}/scripts/fix-step.sh load-work-memory
```

### 0.3 Information to Retrieve

work memory から抽出し retain:

| Field | Extraction Pattern | Purpose |
|-------|-------------------|---------|
| Issue number | `issue-(\d+)` from branch name | Work memory update |
| PR number | `- **番号**[:：] ?#(\d+)` | Retrieve review comments |
| Phase | `- **フェーズ**[:：] ?(.+)` | Confirm flow position |
| Review result | `### レビュー対応履歴` section | Check previous state |

standalone: 引数なしなら現在ブランチの PR。work memory の関連 PR も参照可。

---

### 0.5.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki-query/SKILL.md) — `wiki-query-inject.sh` API

レビュー取得前に Wiki 経験則を注入する。会話へ注入するのは `wiki.enabled: true` かつ `wiki.auto_query: true` のとき。設定が false でもこの節は飛ばさず、capture を呼ぶ。

```bash
bash {plugin_root}/scripts/fix-step.sh wiki-query-config
```

`{keywords}` は指摘カテゴリ、対象パス、失敗内容。`{changed_paths}` は存在する対象パスのカンマ区切りで、空なら空文字を渡す（helper が capture の `--paths` を省く）。値は単一引用符で渡すため `'` を含めない。契約は [wiki-apply-contract.md](../../references/wiki-apply-contract.md)。

```bash
bash {plugin_root}/scripts/fix-step.sh wiki-capture --keywords '{keywords}' --changed-paths '{changed_paths}'
```

status が ok の各ページは rev の本文を読み、excerpt、判断、applied なら evidence と result を証跡に書く。`body: read` だけでは commit しない。ゲートが deny なら commit しない。commit 後の head はステップ 3.3 の `fix-wiki-apply-head` が新しい HEAD へ進める。進められないとき、または blob がファイルと違うときは capture からやり直す。

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
bash {plugin_root}/scripts/fix-step.sh parse-args --arguments '$ARGUMENTS'
```

`$ARGUMENTS` は Skill loader が起動引数へ展開する。展開されないまま届いた値は helper が exit 2 で止める。

**`--nb-sweep` 入口**: `[CONTEXT] NB_SWEEP=1` のとき、ステップ 1.1 の PR 識別の後に **1.3.S へ進む**（1.2 コメント取得・1.3 分類・ステップ 2–4 は評価しない。通常ループの分類表は不変）。

**Validation**: 本 Phase では **パス存在確認をしない** (Priority 0)。`--review-file=` (値なし) だけは即 fail-fast。

**制約 — 空白を含むパスは未対応**: `[^[:space:]]*` のため空白パスは分割され PR 番号に誤認される。空白パスは 1.2.0.1 の「ファイルパス指定」(AskUserQuestion) で入れる。

Detection rules の入力は **必ず** `$ARGUMENTS` ではなく stderr の `remaining_args`。フラグなし呼び出しは不変。

### 1.1 Identify the PR

1.0 抽出後に owner/repo を取る:

- **Within end-to-end flow**: `{owner}` and `{repo}` are already available from ステップ 0.2. Reuse them — no additional owner/repo resolution needed.
- **Standalone execution**: ステップ 0 was not executed. Retrieve them here:

```bash
bash {plugin_root}/scripts/fix-step.sh resolve-owner-repo
```

> 以降の実行スニペットの `{owner_repo}` / `{owner}` / `{repo}` は、上記（または ステップ 0.2）が `[CONTEXT] FIX_OWNER_REPO=` に出した owner/repo を slash 形式（例: `myorg/myrepo`）でリテラル置換する（canonical: [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) の Propagation 小節。SSH host alias 環境対応）。

When PR number is specified as an argument:

```bash
bash {plugin_root}/scripts/fix-step.sh pr-view --owner-repo {owner_repo} --pr {pr_number}
```

When argument is omitted, identify the PR from the current branch:

```bash
bash {plugin_root}/scripts/fix-step.sh pr-view --owner-repo {owner_repo}
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
bash {plugin_root}/scripts/fix-step.sh ensure-worktree --head-ref '{head_ref}'
```

`[CONTEXT] WT_ENSURE=` は [recover Phase 3.1.5](../recover/SKILL.md) の **WT_ENSURE 分岐表（SoT）** に従う。**`branch_absent` / `failed` だけ caller 固有** — recover の AskUserQuestion に対し、fix は `[fix:error]` で機械停止:

- `disabled` / `skip` → no-op、ステップ 1.2 へ（`disabled` = `multi_session.enabled: false`。従来どおり単一ツリーで動作し挙動不変）。
共通作業先契約には `entry_phase=fix` / `pr_number={pr_number}` を渡す。state 不在時は実体・claim の照合後に初回記録してから厳密検証する。既存 state の不一致は上書きせず停止する。

- `already_in` → 共通作業先契約の所有権・branch・変更前検証を通し、同じ作業先で続行する。
- `reenter` / `reconstructed` → recover Phase 3.1.5 と[共通作業先契約](../../references/git-worktree-patterns.md#host-worktree-execution) に従い、marker の `path=` へ native / 検証済み代替で入場し、所有権・branch・変更前検証を通してステップ 1.2 へ。後続の全 shell・編集・検証・委譲をこの作業先に固定する。
- `residue` → [残骸の確認](../../references/git-worktree-patterns.md#5-残骸ディレクトリの削除確認)で中身を調べ、その結果を添えて AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` のパスを表示）。
- `branch_in_main_checkout` → 中止（branch が main checkout に残り、helper が解放できなかった。`other=` と stderr の原因を表示し、未コミット変更の commit または退避後に再実行を案内。recover Phase 3.1.5 の表が SoT）。
- `branch_absent` → 誤再構築しない。**develop 上で続行せず** `[fix:error]`（Edit/Write へ進まない）。
- `failed` → **silent fallback せず `[fix:error]`**。

### 1.2 Retrieve Review Comments

#### 1.2.0 Hybrid Review Source Resolution <!-- D-01 -->


> 取得元の優先順位: コメント URL の指定（`--review-file` との併用はエラー）> 明示ファイル > 会話 > ローカル JSON > PR コメント。
rationale: references/design-rationale.md#hybrid-source-priority

**Priority chain**:

| Priority | Source | Condition | Action |
|----------|--------|-----------|--------|
| T | Target comment (comment URL) | `{target_comment_id}` set in ステップ 1.0 | P0〜P2 を評価せず `review_source=pr_comment` に確定し、Target Comment Fast Path で指定コメントを読む。`--review-file` との同時指定は `[fix:error]`（`reason=target_comment_conflicts_review_file`） |
| 0 | `--review-file <path>` (explicit) | `{review_file_path}` set in ステップ 1.0.1 | Read and parse the specified file. On failure, go directly to Priority 4 (fallback) |
| 1 | Conversation context | Same session has a recent `/rite:pr-review` result in context | Parse conversation findings, then persist and run common triage (1.2.2) |
| 2 | Local JSON file | `.rite/review-results/{pr_number}-*.json` exists | Read latest timestamp file; parse per schema |
| 3 | PR comment (backward-compat) | PR has `## 📜 rite レビュー結果` comment | Extract Raw JSON from code fence if present; else parse Markdown table (legacy) |
| 4 | Interactive fallback | None of the above available | `AskUserQuestion` — prompt user for action (ステップ 1.2.0.1) |

**⚠️ Selection logic — Claude substitution required**:

Selection logic は `scripts/review-source-resolve.sh` に委譲。下記引数を **literal substitute**:

- `{pr_number}` — ステップ 1.0 で正規化された PR 番号 (数値)。非数値は `fix-step.sh` が exit 2 で止める（Error Handling）。
- `{review_file_path_from_phase_1_0_1}` — ステップ 1.0.1 の `[CONTEXT] REVIEW_FILE_PATH=...` 値を会話コンテキストから読み取る (未指定時は `__RITE_UNSET__`)。
- `{conversation_review_decision}` — **Priority 1 判定**: 値の検証は取得元の評価より前に行われるため、コメント URL / `--review-file` 指定時も含めて常に `use` / `none` のいずれかを渡す。同一 session の直前 assistant turn に `## 📜 rite レビュー結果` を含む `/rite:pr-review` 出力が残っていれば、その findings を会話コンテキストから読み取り `use` を渡す。なければ `none` を渡す。
- `{p1_scan_turns}` / `{p1_scan_found}` — Priority 1 receipt: scan した assistant turn 数 (use 時 1 以上) と発見有無 (`use`→`true` / `none`→`false`)。
- `{target_comment_id}` — ステップ 1.0 がコメント URL から取り出したコメント ID (数値)。`{target_comment_id} = null` の経路（PR 番号・PR URL・引数なし）は `__RITE_UNSET__` を渡す。空・未置換・非数値は helper が fail-loud で止める。

helper は `[CONTEXT] REVIEW_SOURCE*` を **stderr** に出す。最終 marker `[CONTEXT] REVIEW_SOURCE=<source>; review_source_path=<path or empty>; pr_number=<n>` のフォーマットは不変。fatal は helper が `FIX_FALLBACK_FAILED` + 非ゼロ、caller が `[fix:error]` stdout (**stdout 分離**)。

**Selection logic**:

```bash
bash {plugin_root}/scripts/fix-step.sh resolve-review-source --pr {pr_number} \
  --review-file-path '{review_file_path_from_phase_1_0_1}' \
  --conversation-decision {conversation_review_decision} \
  --p1-scan-turns {p1_scan_turns} --p1-scan-found {p1_scan_found} \
  --target-comment-id {target_comment_id}
```

**Gate application receipt (Priority 0 / 2 JSON)**: file-based JSON は実測必須ゲートの
適用記録を必須とする。選択直後、findings map を構築する前に次を実行する。記録欠落を
旧形式として読み進めてはならない。既存アーカイブの復旧経路は `/rite:pr-review` の再実行のみ。

```bash
bash {plugin_root}/scripts/fix-step.sh gate-receipt --review-source {review_source} --review-source-path '{review_source_path}'
```

**On target comment** (`[CONTEXT] REVIEW_SOURCE_TARGET_COMMENT=1`): `review_source=pr_comment` として Target Comment Fast Path へ進む。会話の結果と、コメントがレビューした commit 以外のローカル JSON は読まない。Broad Retrieval は実行しない。

**On Priority 0 failure**: `review_source="fallback"` → 1.2.0.1。`--review-file` 明示時に P1–P3 へ silent fallthrough しない。

**On Priority 0 / 2 success**: Skip "Broad Comment Retrieval"（コメント指定時には起きない組合せのため "Target Comment Fast Path" は言及しない）。選択した JSON をステップ 1.2.2 に渡す。Priority 1 の会話結果も同じステップへ合流する。各経路で独自に map / fatal を判定しない。

**On Priority 3**: `[CONTEXT] REVIEW_SOURCE_TARGET_COMMENT=1` marker が出ている場合は本 block を実行しない。Broad Retrieval 後に `### 📄 Raw JSON` fence を読む。parser は当該 section 以降にスコープする。


```bash
bash {plugin_root}/scripts/fix-step.sh p3-raw-json --pr {pr_number}
```

`{review_source}` を later phase の provenance に使う。

#### 1.2.0.1 Interactive Fallback (when all sources missing)

> **契約**: 全ソース欠落時はレビューを 1 回自動再生成し、再度欠落した場合のみ `AskUserQuestion` で「ファイルパス指定 / 中止」を提示する。

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
bash {plugin_root}/scripts/fix-step.sh fallback-abort --reason user_cancelled
```

```bash
# 「ファイルパス指定」の再実行でも invalid だった場合:
bash {plugin_root}/scripts/fix-step.sh fallback-abort --reason user_file_path_invalid
```

**ステップ 2+ 進入禁止**: `[fix:error]` 後は 2/3/4 の bash を呼ばない (`exit 1`。例外なし)。

**ステップ 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons**:

> Selection / P0–P2 map reason は各 helper。本表は 1.0.1 / caller guard / 1.2.0.1 / P3。

| reason | Description |
|--------|-------------|
| `overall_assessment_unknown_value` | Priority 0/2/3 で `overall_assessment` が受理値 (`mergeable` / `fix-needed`) 以外 (review-result-schema.md enum 違反、`REVIEW_SOURCE_ENUM_UNKNOWN` flag。P0: fallback、P2: Priority 3 routing、P3: `[fix:error]` で停止) |
| `pr_comment_raw_json_parse_failure` | Priority 3 で取得した PR コメント Raw JSON が `jq empty` で syntax invalid (`[fix:error]` で停止) |
| `pr_comment_raw_json_awk_failed` | Priority 3 で PR コメントからの Raw JSON 抽出 helper (`hooks/scripts/review-raw-json-extract.sh`) が失敗 (helper 解決不能 rc=127 / awk 異常 / OOM / SIGPIPE、`REVIEW_SOURCE_PARSE_FAILED` flag、legacy Markdown parser へ fallthrough)。reason 名の `awk` は helper 委譲前からの documented literal で、Eval-order enumeration の機械マッチ対象のため改名しない |
| `pr_comment_schema_required_fields_missing` | Priority 3 で取得した PR コメント Raw JSON が parse 可能だが必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) が欠落 (`[fix:error]` で停止) |
| `pr_comment_cross_field_invariant_violated` | Priority 3 で取得した PR コメント Raw JSON の cross-field invariant 違反: `overall_assessment=="mergeable"` だが CRITICAL/HIGH かつ status==open の finding が存在 (`[fix:error]` で停止、`REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED` flag) |
| `pr_comment_critical_high_scope_nit_noted` | Priority 3 で取得した PR コメント Raw JSON の cross-field invariant #4 違反: `severity ∈ {CRITICAL, HIGH}` × `scope == "nit-noted"` の finding が存在 (`[fix:error]` で停止、`REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED` flag) |
| `pr_comment_schema_version_unknown` | Priority 3 で取得した PR コメント Raw JSON の schema_version が未知 (`[fix:error]` で停止) |
| `user_cancelled` | Interactive fallback で「中止」option が選択された (ステップ 5.1 評価順 1 で `[fix:error]` に昇格) |
| `user_file_path_invalid` | Interactive fallback の「ファイルパス指定」で再実行した path でもレビュー結果を取得できなかった (one-shot、retry ループなし、`[fix:error]` 昇格) |
| `review_file_path_empty_value` | ステップ 1.0.1 で値を持たない `--review-file` が指定された。Pattern 1 (equals style: `--review-file=`) と Pattern 2 (space style: `--review-file <末尾>`) の両方で検出される。`flag_style=equals` / `flag_style=space` として retained flag に付記される |
| `comment_body_tempfile_empty` | ステップ 1.2.0 Priority 3 で `${TMPDIR:-/tmp}/rite-fix-pr-comment-{pr_number}.txt` が存在するが空 (Broad Retrieval が異常終了したか PR コメント本文が完全に空) |
| `bash_version_incompatible` | Prerequisites の `command -v mapfile` チェックが失敗 (bash 3.2 等の旧バージョン) |
| `pr_comment_commit_sha_mismatch` | Priority 3 の PR コメント Raw JSON の `commit_sha` が現 HEAD と不一致 (stale detection、WARNING のみで continue) |
| `jq_error_on_commit_sha` | Priority 0/2/3 の `.commit_sha` 抽出 jq が IO/binary エラーで失敗 (I-4 対応。stale detection 無効化を silent にしない。`priority=0|2|3` として retained flag に付記される) |
| `pr_comment_tempfile_read_io_error` | Priority 3 で `pr_comment_body_file` の cat が IO エラーで失敗 (permission 変更 / NFS timeout / TOCTOU truncate) |
| `pr_number_placeholder_residue` | `scripts/review-source-resolve.sh` を `fix-step.sh` を介さず直接呼び、`--pr-number` が数値以外 (空文字 / placeholder 残留) だった (`[fix:error]` 昇格)。`fix-step.sh` 経由では dispatcher が先に exit 2 で止める |
| `review_source_resolve_failed` | ステップ 1.2.0 caller が `scripts/review-source-resolve.sh` の非ゼロ exit を検知した際の caller-side retained-flag (helper が具体 reason を `FIX_FALLBACK_FAILED` で stderr emit 済み、本 reason は drift Pattern 1 充足用の generic guard、`[fix:error]` 昇格) |
| `conversation_json_verify_failed` | ステップ 1.2.2 step 1（会話・外部ファイル経路）の `review-save-json-verify.sh` が「該当なし」（`save_result_json_absent`）以外で終わった（helper 不在・異常終了・判定不能・receipt 不整合）。表からの組み立てや外部ファイルの複写へ倒さず `[fix:error]` |
| `conversation_json_resolve_failed` | ステップ 1.2.2 step 1（会話・外部ファイル経路）で、HEAD の保存済み JSON は特定できたが、そのパス（state root）を解決できなかった。表からの組み立てや外部ファイルの複写へ倒さず `[fix:error]` |
| `conversation_json_not_original` | ステップ 1.2.2 step 1 で特定した HEAD の保存済み JSON が `producer: "fix"`（fix が作った別名ファイル）だった。receipt ではないファイルを triage しないため `[fix:error]`。`state-path-resolve.sh` が返すルートの `.rite/review-results/` にある同じ commit の `producer: "fix"` のファイルを削除してから fix をやり直す（残った元の保存済み JSON が triage される） |
| `explicit_json_differs_from_saved` | ステップ 1.2.2 step 1 で、外部ファイルと HEAD の保存済み JSON の `findings` / `non_blocking_findings` / `measured_gate` が一致しなかった（保存済み JSON が既に triage 済みの場合を含む）。指定したファイルと違う内容を triage しないため `[fix:error]`。`--review-file` を外して再実行すると保存済み JSON が読まれる |
| `explicit_json_compare_failed` | ステップ 1.2.2 step 1 の外部ファイルと保存済み JSON の比較で jq が失敗した（ファイルを読めない、JSON として解析できない）。一致とみなさず `[fix:error]` |
| `fatal_triage_failed` | ステップ 1.2.2 helper の非ゼロ終了。原因と finding ID を保持して `[fix:error]`、legacy fallback 禁止 |
| `pr_comment_schema_version_jq_failed` | Priority 3 で PR コメント Raw JSON の `schema_version` 抽出 jq が失敗 (jq バイナリ異常 / OOM / pipe write error、`schema_version="unknown"` で継続し未知の schema_version として `[fix:error]` で停止、`REVIEW_SOURCE_PARSE_FAILED` flag) |
| `broad_retrieval_jq_extraction_failed` | ステップ 1.2.0 Priority 3 Broad Comment Retrieval で `pr_comments` からの rite review コメント抽出 jq が失敗 (jq バイナリ異常 / OOM / GitHub API レスポンスの JSON 破損、tempfile 不在として `BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT` へ routing、`REVIEW_SOURCE_PARSE_FAILED` flag) |
| `git_rev_parse_head_failed` | Priority 3 の commit_sha stale detection 用 `git rev-parse HEAD` が失敗 (stale 判定を skip し `head_sha=""` で継続、`REVIEW_SOURCE_STALE_CHECK_FAILED` flag。`jq_error_on_commit_sha` と同じ stale-check namespace) |

> P0/P2 map reason は helper docstring が SoT。委譲済は **table 行にせず bullet**。

**review-findings-maps.sh reasons**: 共通 triage (1.2.2) の helper が返す reason をそのまま報告する。measured 未判定、class 未判定（`class_undetermined`）、scope / severity 不正、map / persist / reload の失敗はいずれも `[fix:error]`。空 map・元 JSON・legacy parser で続行しない。


**Eval-order enumeration** (Pattern-2 documented-union): emit reasons sequence = (`bash_version_incompatible` / `pr_number_placeholder_residue` / `overall_assessment_unknown_value` / `pr_comment_raw_json_awk_failed` / `pr_comment_raw_json_parse_failure` / `pr_comment_schema_required_fields_missing` / `pr_comment_cross_field_invariant_violated` / `pr_comment_critical_high_scope_nit_noted` / `pr_comment_schema_version_unknown` / `user_cancelled` / `user_file_path_invalid` / `review_file_path_empty_value` / `comment_body_tempfile_empty` / `pr_comment_commit_sha_mismatch` / `jq_error_on_commit_sha` / `pr_comment_tempfile_read_io_error` / `review_source_resolve_failed` / `conversation_json_verify_failed` / `conversation_json_resolve_failed` / `conversation_json_not_original` / `explicit_json_differs_from_saved` / `explicit_json_compare_failed` / `fatal_triage_failed`)

#### Legacy Branching (PR Comment Path Only)


**Branch by `{target_comment_id}`**: Fast Path / Broad Retrieval は本節内の独立 h4。`### 1.2.1` は Broad Retrieval 時のみ。

#### Target Comment Fast Path — when `{target_comment_id}` is set

`{target_comment_id}` が設定され、review source が PR コメントのときだけ [対象コメントの取得・解析・確認手順](references/target-comment.md) を読む。取得、所属 PR 検証、解析、confidence 確認、handoff と cleanup まで実行する。Broad Retrieval は実行しない。未設定時は次の Broad Retrieval へ進む。

#### Broad Comment Retrieval — when `{target_comment_id}` is NOT set

When the standard flow is active (no `target_comment_id`), retrieve PR review comments as before:

```bash
bash {plugin_root}/scripts/fix-step.sh broad-retrieval --pr {pr_number} --owner {owner} --repo {repo} --owner-repo {owner_repo}
```

PR コメント一覧はこの呼び出しのシェル変数にしか残らない。1.2.1 の検索は同じ呼び出しの末尾で実行し、最新の rite レビュー結果コメントを出力する。

```bash
bash {plugin_root}/scripts/fix-step.sh review-threads --pr {pr_number} --owner {owner} --repo {repo}
```

### 1.2.1 Retrieve rite Review Results

Retrieve the `/rite:pr-review` results from PR comments and extract severity information:

1. Search PR comments for those containing `## 📜 rite レビュー結果`
2. Parse the tables for each reviewer type within the "all findings" section
3. Extract the severity (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) for each finding
4. Preserve each finding separately by ID; file:line is only a thread lookup hint

**Search method:** ステップ 1.2 の `broad-retrieval` が、取得した PR コメントから `## 📜 rite レビュー結果` を含むものを API 呼び出しなしで検索し、`{id, body, author, createdAt}` を出力する。

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
5. finding ごとに元の ID、severity、scope、file、line、message、recommendation、verification、status、出自を保持する。`consequence_class` / `consequence_exclusion` / `pre_existing` は元 JSON にある値だけを複写し、新たに書かない。ID が無い Markdown 行には reviewer と出現順から一意な ID を付け、同じ file:line の別指摘を統合しない。
6. `### 実測なし指摘 (non-blocking)` は前方一致で 6 列パースし、`non_blocking_findings[]` に保持する。gated な rite 出力の `### 全指摘事項` / `### 実測なし指摘 (non-blocking)` は既存のセクション契約に従い、それぞれ明示的な `verification.measured=true` / `false` として移す。元の JSON がある場合はその verification をそのまま使い、欠落を見出しから補わない。未検証の legacy 表・自由文には measured を推測で付けない。

rite 結果がない場合も空の `findings` / `non_blocking_findings` を持つ JSON を作成してステップ 1.2.2 を通す。人間・外部ツールのコメントは rite finding に変換せず、未解決の外部レビューとして保持する。

### 1.2.2 Common Fatal Triage and Recording

**全通常入力経路の合流点**。P0 明示ファイル、P1 会話、P2 ローカル JSON、P3 Raw JSON / legacy Markdown、Target Comment Fast Path は分類・選択・0 件終了の前に必ず本節を実行する。`--nb-sweep` の専用経路は変更しない。

1. P0（`.rite/review-results/` の中のファイル）/P2 は選択した元のファイルを `{triage_review_path}` とし、producer を変更しない。P0 で選んだファイルが `.rite/review-results/` の外にある（外部ファイル）ときは、下の bash で HEAD の保存済み JSON を特定する。`{reviewed_commit_sha}` は外部ファイルの `commit_sha` とする。`FIX_MATERIALIZED_JSON=` が空でなければ、続く比較の bash を通してからそのファイルを `{triage_review_path}` とし、複写しない。空のときだけ外部ファイルを `{triage_review_path}` とし、step 3 で複写する。P1、Raw JSON の無い P3、rite レビュー結果コメントを表パースした Target Comment Fast Path は表から組み立て直さず、下の bash で作業ツリー HEAD の保存済み JSON を特定し、`FIX_MATERIALIZED_JSON=` の値（その元のファイル）を `{triage_review_path}` とする（表には `consequence_class` が無い）。P0/P2 と同じく元のファイルを triage し、複写も producer / `review_source` の書き込みもしない。特定したファイルが `producer: "fix"` なら元のファイルではないので停止する。`{reviewed_commit_sha}` は表の出所（統合レポートまたはコメント）末尾の `📎 reviewed_commit` の値で、HEAD と一致するときだけ保存済み JSON を使う。helper が見つかった・該当なしのどちらでもない結果で終わったら停止する。値が空（commit が一致しない、または HEAD の保存済み JSON が無い）のときだけ、および P3 の Raw JSON は、解析結果を JSON オブジェクト（`findings[]` / `non_blocking_findings[]`、PR 番号、commit SHA、元の gate receipt と verification、`acceptance_criteria` を保持）にし、`state-path-resolve.sh` が返すルートの `.rite/review-results/` に `{pr_number}-{timestamp}.json`（timestamp は `YYYYMMDDHHMMSS`、同名があれば一意になるまで新しい時刻を取得） として atomic write する。Write 失敗は `[fix:error]` で終了する。新規 JSON のトップレベルに `producer: "fix"` を設定する（元 JSON に producer があっても上書き）。元ソースの `{review_source}` は provenance として保持する。

```bash
# fix-conversation-review-json
bash {plugin_root}/scripts/fix-step.sh conversation-review-json --pr {pr_number} --reviewed-commit-sha {reviewed_commit_sha}
```

外部ファイルで保存済み JSON を特定できたときだけ、次を実行する（`{review_source_path}` は 1.2.0 の `[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=` の値、`{materialized_json}` は `FIX_MATERIALIZED_JSON=` の値）。指定したファイルと違う内容を黙って triage しないため、指摘と gate 記録が一致しなければ止める。

```bash
# fix-explicit-review-json
bash {plugin_root}/scripts/fix-step.sh explicit-review-json --review-source-path '{review_source_path}' \
  --materialized-json '{materialized_json}'
```

2. P0 の helper source は `explicit_file`、それ以外は `local_file`。次を実行する。helper は **元 JSON に persist してから** ID-keyed `fatal_map` / `severity_map` / `scope_map` を返す。`fatal = verification.measured == true AND scope ∈ {current-pr, follow-up} AND (severity ∈ {CRITICAL, HIGH} OR ((consequence_class == "A" OR (consequence_class == "B" AND consequence_exclusion が空でない文字列)) AND pre_existing != true))` の判定はこの helper だけが担い、LLM は再分類しない。MEDIUM 以下の実測済み gated finding に class A/B が無ければ `class_undetermined` で停止する。gated な非 fatal を `demotion_reason: "non_fatal"` 付きで `non_blocking_findings[]` へ移送し、nit は保持する。

```bash
bash {plugin_root}/scripts/fix-step.sh triage --triage-review-path '{triage_review_path}' --triage-helper-source {triage_helper_source}
```

helper の `[fix:error] reason=measured_undetermined; findings=...` / `reason=class_undetermined; findings=...` は該当 ID をそのまま報告して停止する。`class_undetermined` は表から組み立てた入力（表の `📎 reviewed_commit` が HEAD と違う、または HEAD の保存済み JSON が無い）で起きる。class を補わず、`/rite:pr-review` を再実行して HEAD の結果を保存してから fix をやり直す。scope / severity / IO の異常も停止する。**triage エラーから legacy parser / Interactive Fallback への遷移は禁止**。missing/null/string の measured を true や false に補完しない。

3. helper の `FIX_FATAL_TRIAGE=applied; fatal=N; moved=M` から `{fatal_count}=N` / `{non_fatal_moved_count}=M` を保持する。reload した `non_blocking_findings[]` の nit 以外の件数を `{non_blocking_count}` とし、全経路で同じ母集団を使う。P0 の外部ファイルで HEAD の保存済み JSON が無かった場合だけ、新しいファイルのトップレベルを `producer: "fix"` にした更新後 JSON を `.rite/review-results/` に atomic copy し、そのパスを `{triage_review_path}` に更新する。後続 review / nb sweep が読める永続ファイルを残す。
4. [Non-fatal Record](references/non-fatal-record.md) を実行し、既存の関連 Issue コメントを更新する。既存記録の `### 却下台帳` は新本文へ引き継いでから helper に渡す（全文置換で消さない）。JSON / Issue 記録 / 表示の non-blocking section / E2E 1 行の **4 経路**に同じ件数・JSON pointer を渡す。Issue 記録失敗時は fatal が 0 件でも `[fix:error]`。記録を終える前に 0 件扱いで return しない。
5. `.rite/fix-cycle-state/{pr_number}.json` の top-level `non_fatal_moved_count` / `review_json_path` に今回の値を atomic merge する（既存 `cycles` を保持、新規なら `cycles:[]`）。書込失敗は `[fix:error]`。修正コミットが無い cycle でも必須。ステップ 3.3.1 は同じ値を cycle entry にも記録する。

```bash
bash {plugin_root}/scripts/fix-step.sh triage-state --pr {pr_number} --non-fatal-moved-count {non_fatal_moved_count} \
  --triage-review-path '{triage_review_path}'
```

### 1.3 Classify Comments

helper の ID-keyed `fatal_map` / `severity_map` / `scope_map` と reload 済み JSON を参照する。PR 内推奨は review JSON に載らないので、次の出力（2 行目の JSON 配列）を読む。非ゼロ終了なら `[fix:error]` で停止する。

```bash
bash {plugin_root}/scripts/review-pr-recommendations.sh list --pr {pr_number} --review-result '{triage_review_path}'
```

| Classification | Criteria | Action |
|---------------|----------|--------|
| **Required fix** | `fatal_map[id] == true` | 修正対象 |
| **PR 内推奨** | 上の `list` の `R-NN`（pr-review 7.2 が `/rite:iterate` 経由の review（mergeable と受入条件未検証の停止）で、採否の出口 ADOPT・`origin=pr` の根因をレビュー済み commit に登録したもの） | 修正対象。map には載らないので ID で直接扱う |
| **完了前確認の逸脱** | flow-state の `review_run.deviations[]` のうち現在の review context のもの（`D-NN`。iterate の完了前確認が `review-deviate` で記録） | 修正対象。PR 内推奨と同じく ID で直接扱う |
| **nit (認知のみ)** | `scope_map[id] == "nit-noted"` | PR reply / fix 対象外。`acknowledged_nit_count` に算入 |
| **non-blocking（fix 対象外）** | 永続 JSON の `non_blocking_findings[]`（nit 除外） | 記録・表示のみ。修正選択肢に出さない |
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
| Within `/rite:iterate` review-fix loop | **Skip** (auto-select) | Fatal findings + PR 内推奨 + 完了前確認の逸脱 + unresolved external reviews |
| Manual `/rite:fix` | Display | User-selected |


---

```
PR #{number} のレビューコメント

## 未対応の指摘 ({count}件)

### 必須修正（fatal）({count}件)
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

### non-blocking（fix 対象外） ({non_blocking_count}件)
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
bash {plugin_root}/scripts/fix-step.sh cancel-cleanup --pr {pr_number} --target-comment-id '{target_comment_id}'
```

**FINALIZE handoff (E2E のみ)**: `[fix:cancelled-by-user]` は 5.1 を通らないので**ここで**セット。standalone では実行しない。

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
bash {plugin_root}/scripts/fix-step.sh cancelled-by-user
```


**When there are no comments:**

本分岐も 1.2.2 の記録と state persistence 完了後だけ実行する。fatal / PR 内推奨 / 完了前確認の逸脱 / 外部レビューが 0 件のときだけ本分岐に入る。fatal / 外部レビューが 0 件で non-blocking が残る場合は「コメントなし」と表示せず、移送件数と JSON pointer を報告して 4.6 → 5.1 の通常完了へ進む。

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
bash {plugin_root}/scripts/fix-step.sh fast-path-cleanup --pr {pr_number} --target-comment-id '{target_comment_id}'
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
- [ ] 保存済み対象 finding は元 Issue の目的・非対象とファイルの読者/役割で配置したか。証拠は既存 PR details、恒久契約は規約、保守の Why はソース、再現はテスト。作業日誌を規約や判断文書へ残していないか
- [ ] 恒久規約が凍結予定の作業文書を規範として指していないか。複数の正が衝突していないか。非規範の有用な資料参照・Why・不変条件は保持したか
- [ ] 行順・見出し階層・表示パス等の新制約は元要求から必要か。前 cycle の規約やテスト一致だけでは根拠にしない。親発見と `non_blocking_findings[]` は対象外（1.3 は記録のみ。schema 受理は自動 fix ではない）

対象は**機構の追加**。テスト追加・複製同期は対象外。[coding-principles.md](../../skills/rite-workflow/references/coding-principles.md) の `no_speculative_structure` と対。

**Escalation trigger（パッチの重ね掛け停止）**: 対応中の finding が**同一 PR の前 cycle の fix が導入・変更した箇所**への指摘である場合（description が「cycle N で導入した」「前 cycle で追加した」等で当該 fix を名指しする場合を含む）、同じ機構への追加パッチを既定選択にしないこと。まず「当該機構ごと削除・単純化して指摘群を根から消せないか」を検討し、修正案の提示（ステップ 2.3）の前にその判断を chat へ 1 行明示する（例: `simplification-first: 削除 — 分岐機構を削除し行全体再生成へ単純化` / `simplification-first: 追加 — 理由: {なぜ削除ではないか}`。書式はステップ 3.2 の必須段落と同一）。

Escalation trigger 成立時は、この判断を commit body の `simplification-first:` 段落（ステップ 3.2）として書く。本文禁止時は 3.2.1 の溢れ先へ移す。ステップ 3.2.1 Root Cause Gate が段落の有無を検査する。

rationale: references/design-rationale.md#simplification-first-rationale

### 2.1 Confirm Fix Approach

全指摘の処置を編集前に一括で決める。個別指摘の読み取り・impact scan は先に行ってよいが、最初の編集前に [一括計画と検証](references/fix-plan.md) を読み、同一 HEAD の全員回収済み保存結果・最新 Issue 本文から `{fix_plan_file}` と `{fix_issue_file}`（絶対 JSON パス）を作る。root cause ごとに重複を関連付け、全 blocking 指摘へ処置と検証を割り当てる。人間由来の未解決指摘も計画へ記録し、既存の対応義務を維持する。対象は 1.3 の Required fix（`fatal_map[id] == true`）、PR 内推奨（1.3 の `list` の `R-NN`。scope gate が各 ID に 1 つの処置を要求する）、完了前確認の逸脱（現在の review context の `D-NN`。同じく処置を要求する）と未解決 External review。親の完了前発見を未保存 ID として計画へ足さない（`review-deviate` で記録した `D-NN` は保存済み）。`non_blocking_findings[]` が schema 上受理されていても 2.1 の修正対象ではない。各 `groups[].rationale`（または既存 PR details）に、初回 finding でも元要求との対応と、追加／削除／差し戻し／移動から選んだ処置の理由を短く書く。`simplification-first:` 段落は Escalation trigger 専用であり、この記録の代用にしない。新 schema は足さない。

`review_run.current_decision.action=replan` なら、[停滞診断](../../references/review-stagnation.md) の契約で全指摘と仕様を再照合し、代替案・選択理由・棄却理由・再発防止検証を同じ計画の `replan` に記録する。範囲内の選択は通常の承認待ちを挟まない。以下の保存後に通常の scope gate を通す。時計は同参照の共有ブロック `review-clock-open`（Bash ブロック名。時計の CLI 動詞は `review-clock` だけ）を `clock_kind=work` で実行し、外部待機は別区分にする。

時計の open / close は `review_run` がある場合だけ実行する。中断からの再入場では既存区間を同参照の `recover` モードで閉じてから、新しい作業区間を開く。

```bash
# fix-stagnation-replan
bash {plugin_root}/scripts/fix-step.sh stagnation-replan --fix-plan-file '{fix_plan_file}' --fix-issue-file '{fix_issue_file}'
```

登録済み replan の検証コマンドの誤りは、[停滞診断の訂正契約](../../references/review-stagnation.md#登録した検証コマンドの訂正) に従い `review-replan --amend --reason "訂正理由"` と同じ plan / issue 引数で訂正する。旧証跡を保持したまま、scope check と全検証を再実行する。

解決不能は検討した範囲内代替と契約上の理由を保存して `stop` とする。保存・権限・証跡の失敗は `[fix:error]` のまま保持し、解決不能という判断へ変換しない。

```bash
# fix-scope-before-edit
bash {plugin_root}/scripts/fix-step.sh scope-check --fix-plan-file '{fix_plan_file}' --fix-issue-file '{fix_issue_file}'
```

失敗時は編集せず、診断・計画・途中成果を保持する。範囲内代替を検討して同じ計画を修正し再検査する。代替不能なら Issue 仕様を変更せず理由を work memory に残して `[fix:error]`。パス通過だけでは意味的承認にしない。計画外の変更先が必要になったら、編集前に計画と根拠を更新し本ゲートへ戻る。各編集は検査済み `groups[].paths` 内に限定する。typo-only の impact scan 省略も本ゲートを省略しない。

reviewer の推奨対応（`recommendation` 列）は候補であって設計ではない。文書の主張を書く／広げる修正案は、適用前に実装と突き合わせる（ステップ 2.3）。

**Entry routing — scope=nit-noted skip**:

**`scope == "nit-noted"` は 2.1 / 2.4 を skip**（PR reply しない。カウントは 2.4.N）:

1. 未解決の External review は通常通り対応する。rite finding の map で skip しない。
2. rite finding の `scope_map[id] == "nit-noted"` は 2.1 / 2.4 を skip し、2.4.N で認知件数に算入する。
3. `fatal_map[id] == true`、PR 内推奨の `R-NN`、現在の review context の `D-NN` だけが通常の修正・accept/rejection 判断へ進む。
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
   bash {plugin_root}/scripts/fix-step.sh impact-scan --symbol '{symbol_name}'
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

修正案を chat に示し（これが修正案の提示）、確認を挟まずに Edit tool で適用する。修正が正しいかは、ステップ 3 の検証（`scope-verify`）の実行結果で判断する（AI が書いた修正を人間に確認させない — [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) 規則 5）。

**PR 本文の行への指摘**: `category == "claim_source"` で出所が `PR本文:N` の指摘は、PR 本文の N 行目を直す（`file` は PR の変更ファイルの先頭で、直す対象ではない）。本文を取得して該当行を出典に合う主張へ直し、作業 worktree 外の `{edited_pr_body_file}` へ Write してから次を実行する。PR本文:N の指摘が複数あれば、1 回取得した本文に全件を反映してから（N はレビュー時の本文の行番号）次を 1 回だけ実行する。`[CONTEXT] FIX_PR_BODY_EDITED=1` が出た指摘だけを `findings_addressed[]` に `changes: []` の `reply` として載せる（差分ゲートはコードの差分だけを照合する）。marker があれば 5.1 は push と同じく再レビューへ戻し、同じ commit の再レビューが直した本文を照合し直す。非 0 終了（`FIX_PR_BODY_EDIT_FAILED=1`）なら本文は直っておらず、5.1 は `[fix:error]` を返す。

```bash
bash {plugin_root}/scripts/fix-step.sh pr-body-edit --pr {pr_number} --owner-repo {owner_repo} --body-file '{edited_pr_body_file}'
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

先に返信本文を Write ツールで作業 worktree 外の一時ファイル `{reply_body_file}` へ保存する（本文をコマンドへ展開しない）。`{comment_id}` は返信先コメントの数値 ID。

```bash
bash {plugin_root}/scripts/fix-step.sh reply-post --pr {pr_number} --owner {owner} --repo {repo} --comment-id {comment_id} \
  --reply-body-file '{reply_body_file}'
```

reply は本文ファイル → `mktemp` への写し → `jq --rawfile`。`comment_id` は `--argjson`。

### 2.4.N nit-noted-no-reply

`scope == "nit-noted"` は PR に reply しない。`acknowledged_nit_count = {nit_noted_count}`（ステップ 1.3 / 1.4）。Issue 化しない。commit しない。

rationale: references/design-rationale.md#nit-noted-no-reply-notes

---

## ステップ 3: 修正のコミット

> **Reference**: Apply [Comment Best Practices](../../skills/rite-workflow/references/comment-best-practices.md) when finalising fix commits — 生成コメント/散文に Issue/PR 番号・AC 番号を残さない。残す背景は現在形の制約文。ジャーナル/経緯文は禁止。file:line 参照と未検証ジャーゴンも diff に残さない。review/fix 履歴は commit message / PR description へ。

一括修正完了後、最新 Issue を再取得し、検査済み計画に対して次を実行する。関連結果の鮮度確認後に、必要な全体検証を全件実行・記録する。失敗または保存不能なら commit / push / 次レビューへ進まない。既存の差分・schema・AC ゲートは引き続き実行する。成功後に [停滞診断](../../references/review-stagnation.md) の共有ブロック `review-clock-close` を `clock_close_mode=normal` で実行して修正区間を保存する。検証済み修正は run 履歴へ結び付き、次の review-start が異なる HEAD と検証済み内容を照合して修正回数を確定する。

```bash
# fix-scope-final-verification
bash {plugin_root}/scripts/fix-step.sh scope-verify --fix-plan-file '{fix_plan_file}' --fix-issue-file '{fix_issue_file}'
```

コミットを直接実行する Bash 呼び出しも、実行前 hook が未完了 cycle と保存済み計画・全件検証の鮮度を確認する。拒否された場合は理由に従って次を行う。凍結 HEAD を戻して検査を通してはならない。

- 未完了 cycle: `review-finish` で結果を保存してから commit を別 Bash 呼び出しで再実行する
- 計画・検証の鮮度: 上記の `fix-step.sh scope-check` と `fix-step.sh scope-verify`（同じ `{fix_plan_file}` / `{fix_issue_file}`）を完了してから commit する
- `unplanned changed path`: `review-finish` と `scope-verify` では解消しない。不要なら削除する。必要なら `groups[].paths` へ追加して `scope-check` と `scope-verify` からやり直す。計画内の新規ファイルを明示パスで stage する手順は 3.1 にある。stage だけではこの拒否は消えない

commit は作業 worktree で `git commit`（必要なら literal な `git -C <path> commit`）を直接呼ぶ。検証・編集・commit を同じ Bash 呼び出しにまとめない。hook は直接コマンドと既存 heredoc 除去後の表面を検査し、スクリプト内部・alias・動的に組み立てた subcommand は解釈しない。これらの間接実行を commit 手順に使わない。メッセージファイル `{commit_message_file}` は作業 worktree 外の絶対パスにする。

### 3.1 Verify Changes

**前置ガード**: 修正で作成した新規ファイルは対象パスを明示して `git add -- <path>` で stage してから判定する。tracked 差分が無ければ **ステップ 3 全体を skip** して 4.5 へ (全経路)。判定は **`git-status-filtered.sh --tracked-only`** (raw porcelain 禁止)。untracked は件数・名前を WARNING に残し、commit 対象の判定から除外する。

```bash
bash {plugin_root}/scripts/fix-step.sh commit-guard
```

`FIX_COMMIT_GUARD=skip` ならステップ 3 の commit / push を skip して ステップ 4.5 へ進む。**skip でも `findings_addressed` は最新 cycle として永続化する**（4.6 の gate が `map_missing` に倒れるのを防ぐ）。commit が無いので `commit_sha_before` / `commit_sha_after` はともに HEAD、`files_changed_by_fix` は `[]`。既存 cycle の `findings_addressed` は上書きせず、新しい cycle entry を append する。`proceed` なら次のブロックを飛ばし、以降を通常どおり実行する。

`skip` のときだけ次を実行する。`{findings_addressed_file}` は ステップ 2.3 で記録した配列（fix は path:line / path:start-end、reply/accept/nit-noted は `changes: []`。`diff_verified` は書かない）を Write ツールで保存した作業 worktree 外の JSON ファイル。

```bash
bash {plugin_root}/scripts/fix-step.sh skip-cycle-state --pr {pr_number} --findings-addressed-file '{findings_addressed_file}' \
  --non-fatal-moved-count {non_fatal_moved_count} --triage-review-path '{triage_review_path}'
```

`proceed` なら commit 前 HEAD を marker に残し、3.3.1 が `{fix_cycle_base_sha_from_context}` に使う。

```bash
bash {plugin_root}/scripts/fix-step.sh cycle-base-sha
```

Once all findings have been addressed, verify the changes:

```bash
bash {plugin_root}/scripts/fix-step.sh show-changes
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
bash {plugin_root}/scripts/fix-step.sh number-ref-check --base-branch {base_branch} --changed-files '{changed_files}'
```

| Marker | Action |
|--------|--------|
| `NUMBER_REF_CHECK=clean` | 3.1.1 へ |
| `NUMBER_REF_CHECK=hits` | コミットしない。2.3 に戻り追加行を書き直す。書き直しでもヒットが残るなら `[fix:error]`。番号付き行をコミットする fallback は禁止 |
| `[fix:error]` | 停止（checker / intent-to-add の失敗） |
| いずれも無い（usage 失敗など） | `[fix:error]` |

### 3.1.1 Pre-Commit Schema Version Check

Before committing, verify that `.rite/review-results/*.json` schema versions are within the accepted list, mechanically. This prevents schema drift from entering the review cycle, saving an entire review-fix round trip.

1. Check if `review.loop.pre_commit_drift_check` is enabled in `rite-config.yml` (default: `true`). If disabled, skip to ステップ 3.2.

2. Run the check:

```bash
bash {plugin_root}/scripts/fix-step.sh schema-drift-check
```

3. Handle the exit code:

| Exit Code | Action |
|-----------|--------|
| `0` (clean) | Proceed to ステップ 3.2. |
| `1` (drift detected) | Read the `[CONTEXT] REVIEW_SCHEMA_VERSION_DRIFT=1; file=` lines printed above for the drifted files. Return to ステップ 2 to fix the detected drifts. This is an **automated self-correction** — NOT a new review cycle. Do not increment `loop_count`. |
| `2` (invocation error) | Emit `[CONTEXT] PRE_COMMIT_DRIFT_CHECK_ERROR=1` as WARNING and proceed to ステップ 3.2. Do not block the commit. |


### 3.2 Generate Commit Message

Generate a commit message based on the addressed findings.

fallback を選んだら commit body に「なぜ throw ではないか」を書く。無注釈の防御コードは re-review で再指摘される。

**Commit message language:**

生成直前に [commit-convention.md](../../references/commit-convention.md) を適用する（locate + Read。結果は flow-state に残さない）。規約が言語・形式を指定していればそれに従う。未指定項目だけ下記の `language` 既定と Conventional Commits を使う。

Before generating the commit message, check the `language` field in `rite-config.yml` using the Read tool to determine the language (規約未指定時のみ):

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

規約が本文を禁じない限り、free-form の commit body を使う。Review-fix commits は次を **MUST** で残す（本文へ書くか、本文禁止なら 3.2.1 の前に overflow へ移す。body へ prepend しない）:
- **対応方針** — 各 finding に対して何をしたか / なぜその方針か
- **`Root cause:` / `根本原因:` 段落** — ステップ 3.2.1 Root Cause Gate が検査する（本文禁止時は `{overflow_store}`）
- **`simplification-first:` 段落（Escalation trigger 成立時のみ）** — `simplification-first: 削除 — {何を削ったか}` または `simplification-first: 追加 — 理由: {なぜ削除ではないか}` の 1 段落。ステップ 3.2.1 Root Cause Gate が検査する（本文禁止時は `{overflow_store}`）。trigger 不成立の cycle では書かない

- Leave a blank line between the description line and the body
- Write in free-form — no specific prefix or template required
- Focus on "why" the change was needed, not "what" was changed (the description line already covers "what")
- Follow the same language setting as the description line
- Why は、規約が本文を禁じない限り必須（省略経路なし）。review-fix の対応方針 / Root cause は省略せず、本文禁止時は overflow へ移す

**Trailer**: Generate in the configured language using the unified `{reviewer_display_N}` placeholder (展開ルールは ステップ 2.1 の `{reviewer_display}` 展開ルール表を参照 — Broad Retrieval 経由で `@{user}`、Fast Path 経由 + `target_author_mention_skip == "true"` で `(不明なレビュアー)` / `(unknown reviewer)` に展開される):

- English: `Addresses review comments from {reviewer_display_1}, {reviewer_display_2}`
- Japanese: `{reviewer_display_1}, {reviewer_display_2} のレビューコメントに対応`

**展開ルールの単一源**: ステップ 2.1 の表。ここへ literal を複製しない。
rationale: references/design-rationale.md#reviewer-display-single-source

**Acknowledged-finding trailer (accept で `status: acknowledged` 化された finding 用)**:

規約が trailer を禁じるときはコミットに付けず、[commit-convention.md 必須記録](../../references/commit-convention.md#必須記録が規約に収まらないとき) の手順で節 `Acknowledged-finding` へ移し、検査も同じ節を読む。

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
```

### 3.2.1 Root Cause Gate

Before committing a fix, a root-cause explanation **MUST** be in the commit body when the convention allows a body, or in the convention's overflow store when the body is forbidden. This gate implements Quality Signal 2 (root-cause-missing fix detection) — see the Quality Signal 1-4 table in `skills/pr-review/references/finding-cycling.md`.

**Step 1**: 規約が本文を禁じるときは、3.2 の body へ Root cause を書かず、必須記録の保存・検査手順の正本 [commit-convention.md](../../references/commit-convention.md#必須記録が規約に収まらないとき) に従う。必要な節は `Root cause`。Escalation trigger 成立時は `simplification-first` も同じ手順で足す。検査は正本どおり同じ各節の helper `read`。helper は絶対パスのローカルファイルだけを受け取り、PR 本文や work-memory へは書かない。

規約が本文を禁じないときは 3.2 の commit body に `Root cause:` / `根本原因:` 段落があるか LLM が判定する (Bash 状態非依存)。規約が本文・trailer を禁じて溢れさせた場合は、正本の保存先から同じ節を読む。どちらにも無ければ `missing`。検査を外して通過させない。Escalation trigger 成立時は `simplification-first:` 段落の有無も同じ規則で判定し、いずれかの欠落を `missing` とする。trigger 不成立の cycle では `simplification-first:` 段落を要求しない。正本の view / edit / write / read 失敗はコミットしない。body へ prepend しない。work-memory を溢れ先にしない。

Emit one of the two context markers so downstream logic can route (`{root_cause_gate}` is the LLM-side determination above: `ok` or `missing`):

```bash
bash {plugin_root}/scripts/fix-step.sh root-cause-gate --status {root_cause_gate}
```

**Step 2**: When `ROOT_CAUSE_GATE=missing`, warn the user via `AskUserQuestion` with exactly three options:

| Option | Action |
|--------|--------|
| 不足段落を追記して再コミット（推奨） | Draft a short paragraph from the diff and the finding for whichever Step 1 found missing, and ask the user for it only when neither shows the cause ([question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) rule 5): prepend a `Root cause: {paragraph}` / `根本原因: {paragraph}` paragraph, or (Escalation trigger 成立時) a `simplification-first: {paragraph}` paragraph, to the commit body when the convention allows a body; if the convention forbids a body, write the missing paragraphs via the canonical overflow procedure with those section names (`Root cause` and, when the trigger holds, `simplification-first`). Do not prepend to the commit. Do not use work-memory as the overflow store. 正本の失敗はコミットしない。re-invoke Step 1. The retry count is tracked in conversation context by the LLM — after one retry the LLM falls through to the second option to avoid an infinite prompt loop |
| 意図的な補足コミットとして通過 | Prepend a bypass paragraph for whichever Step 1 found missing — `Root cause (bypass): {理由}`, or (Escalation trigger 成立時) `simplification-first (bypass): {理由}` — to the commit body when the convention allows a body (the bypass rationale recorded alongside the commit for machine-traceability). If the convention forbids a body, write the same rationale via the canonical overflow procedure with the missing section names. AND append the same rationale to work memory `決定事項・メモ`. The bypass is still recorded. 正本の失敗はコミットしない |
| Abort | Skip this fix cycle; emit `[fix:error]` and return control to the caller |

cosmetic は option 2 可。bypass は記録必須。


### 3.3 Execute the Commit

先に Write ツールで作業 worktree 外の一時ファイル `{commit_message_file}` へメッセージを保存する。次の commit は別の Bash 呼び出しで実行し、成功後にメッセージファイルを削除する。commit は実行前 hook がコマンド文字列の `git commit` を検査するため、helper へ移さず literal のまま実行する。

```bash
# fix-commit-execute
git add {changed_files}
git commit -F "{commit_message_file}"
```

各 commit が成功するたびに、別の Bash 呼び出しで Wiki 適用証跡の head を commit 前の HEAD から新しい HEAD へ進める。進めないと次の commit と次のレビューのゲートが `stale_head` で拒否する。

```bash
# fix-wiki-apply-head
bash {plugin_root}/hooks/scripts/wiki-apply-advance-head.sh --from HEAD^
```

`WIKI_APPLY_HEAD=advanced` または `=current` なら 3.3.1 へ進む。非 0 終了では証跡は変わっていない。冒頭の Wiki 手順の capture からやり直し、証跡を書き直してから 3.3.1 へ進む。

### 3.3.1 Fix-Cycle State Persistence

After committing, record the current fix cycle's data to `.rite/fix-cycle-state/{pr_number}.json` for convergence monitoring and cross-session context preservation. `{findings_addressed_file}` is the JSON file of the ステップ 2.3 `findings_addressed` array written with the Write tool outside the work tree (`diff_verified` は書かない。gate が書き戻す). `{propagation_applied_count}` comes from ステップ 2.3.1.

```bash
bash {plugin_root}/scripts/fix-step.sh cycle-state --pr {pr_number} --fix-cycle-base-sha {fix_cycle_base_sha_from_context} \
  --findings-addressed-file '{findings_addressed_file}' \
  --findings-fixed-count {findings_fixed_count} --propagation-applied-count {propagation_applied_count} \
  --non-fatal-moved-count {non_fatal_moved_count} --triage-review-path '{triage_review_path}'
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
bash {plugin_root}/scripts/fix-step.sh push
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
bash {plugin_root}/scripts/fix-step.sh resolve-thread --thread-id '{thread_id}'
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

進捗ステータスはステップ 3 の検証済み変更一覧から判断し、不足時は `rite-config.yml` の `branch.base`（未設定なら helper は `base_branch_unresolved` で停止）を解決し、helper と同じ `git diff --name-status "origin/{base_branch}...HEAD"` を取得する。履歴本文は 4.5.3 のテンプレートから生成する。本文をコードへ展開せず、Write ツールで下記の所有ファイルへ保存する（履歴は `### レビュー対応履歴` 見出しなし）。別 Bash のローカル変数は引き継がない。

1. `mktemp` で PR 本文ファイルを確保する。失敗時は `WM_UPDATE_FAILED=1; reason=mktemp_failed_pr_body_tmp` を stderr に出し、更新を実行せず 5.1 へ進む。取得済み PR 本文を保存し、空/書込失敗は空ファイルとして helper に渡す。
2. `mktemp` で履歴ファイルを確保し本文を保存する。準備失敗時は確保済みの履歴ファイルを削除してからパスを空文字にする。helper は進捗更新成功後にだけ `wm_sync_history_failed` と判定するため、この時点で失敗フラグを追加しない。
3. 以下を単一 Bash 呼び出しで実行する。`{pr_body_file}` / `{history_file}` は今回確保したパス（履歴準備失敗は空文字）、`{plugin_root}` は解決済みの絶対パスで置換する。helper が所有する一時ファイルは helper 自身が回収する。

```bash
bash {plugin_root}/scripts/fix-step.sh wm-update --pr-body-file '{pr_body_file}' --history-file '{history_file}' \
  --impl-status '{impl_status}' --test-status '{test_status}' --doc-status '{doc_status}'
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
- non-blocking（fix 対象外）: {non_blocking_count}件
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
| 5 件以上 (≥5 警告発火) | `{N}` | ` ⚠️ reviewer の精度を疑うべき水準` |

**読み出し方法**: 本読み出しはステップ 2.1.A と別 Bash invocation で実行される可能性があるため、helper が `_state_root` の解決を同一 invocation 内で行い、`accept_count=N` を出す (pr-review.md 5.1.2.A Step 2 の再 inline と同型。解決なしで読むと `/.rite/state/...` の ENOENT が `2>/dev/null` で握り潰され accept_count が silent に 0 化する):

```bash
bash {plugin_root}/scripts/fix-step.sh accept-count --pr {pr_number}
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
| `対応した指摘: {count}件` | Number of findings addressed | `fix_count + reply_count + acknowledged_nit_count + non_blocking_count`。**`fix_count` は `diff_verified: true` の action:fix のみ**。`diff_verified: false` は「未対応」に載せ、この件数から除外する (nit-noted 分類と non-blocking 分類も「対応」に含めることで、nit-only / non-blocking-only PR でも `全指摘 == 対応指摘` 条件を満たし有限 cycle で収束する — `non_blocking_count` を式に含めないと非実測 finding が「未対応」として残り finalize 分岐が発火せず max_review_cycles まで空転する)。**各項は排他**: `acknowledged_nit_count` と `non_blocking_count` は重ならない (nit-noted は scope による分類で、non-blocking は永続 JSON の別集合) |
| `non-blocking（fix 対象外）: {non_blocking_count}件` | Recorded findings | reload 済み non_blocking_findings の nit 以外。0 件でも表示。今回の移送件数は non_fatal_moved_count、永続参照先は triage_review_path |
| `Confidence override (policy bypass): {N}件` | Number of findings imported via Confidence policy override | ステップ 1.2 best-effort parse で「Confidence 70 のままバイパス」を選択した finding 数 (Confidence 80+ ゲート invariant の policy override 追跡義務)。0 件でも常時表示 |
| `レビューソース: {review_source} (...)` | Provenance of the review findings consumed by this fix run | ステップ 1.2.0 Priority chain で決定された `review_source` 値 (schema.md Priority 1 emit 義務の provenance 契約を ステップ 4.6 で履行)。展開ルールは ステップ 4.5.3 の `{review_source}` / `{review_source_path_display}` 表を参照 |

iterate は本報告で次を決める:
- `プッシュ: 完了` → re-review (範囲は pr-review 1.2.4。fix 側で宣言しない)
- 本 cycle で accept 発生 → re-review
- 本 cycle で PR 本文を直した（`FIX_PR_BODY_EDITED=1`）→ re-review
- `プッシュ: 未実行` かつ accept なし かつ PR 本文の修正なし かつ `全指摘 == 対応指摘` → 完了

accept・PR 本文の修正の SoT は 5.1 row 4/4.5/5。
rationale: references/design-rationale.md#accept-cycle-markers


### 4.6.W Wiki Ingest Trigger (Conditional)

> **Reference**: [Wiki Ingest](../wiki-ingest/SKILL.md) — `wiki-ingest-trigger.sh` API

After outputting the completion report, trigger Wiki Ingest to capture fix patterns as experiential knowledge.


**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_ingest: true` in `rite-config.yml`. Configuration-based skip is the **only** legitimate skip path — it MUST emit a `WIKI_INGEST_SKIPPED=1` status line and `wiki_ingest_skipped` sentinel so the caller can detect and report (see ステップ 4.6.W.3 below).

**Step 1**: Check Wiki configuration (same pattern as ステップ 0.5.W Step 1, replacing `auto_query` with `auto_ingest`). If `wiki_enabled=false` or `auto_ingest=false`, the same call **emits a skip status line + sentinel** (`[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=disabled|auto_ingest_off`; do not silently skip — the caller relies on this signal for ステップ 5.6 reporting):

```bash
bash {plugin_root}/scripts/fix-step.sh wiki-ingest-check
```

If a `WIKI_INGEST_SKIPPED` reason was emitted, skip Steps 2 and ステップ 4.6.W.2 and proceed to the end of fix flow. Otherwise continue to Step 2.

Wiki 記録が有効な場合だけ [Wiki 記録・raw commit 手順](references/wiki-recording.md) を読み、残りの ingest・commit・push 再試行を実行する。未完了時の通知まで適用してからステップ 5 へ進む。

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When PR is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When Comment Retrieval Fails | ネットワーク接続を確認; `gh auth status` で認証状態を確認 |
| Error During File Modification | 原因（対象パス・一致しない置換元など）を直して 1 回再試行する。再失敗なら指摘を飛ばさず、失敗の内容を stderr に出して `[fix:error]` で停止する |
| Commit Failure | `git status` で状態を確認; 問題を解決してから再度コミット (WARNING を stderr に出力) |
| `fix-step.sh` が exit 2（`ERROR: fix-step.sh:`）で止まった | marker を待たずに停止し、未置換の placeholder・空値・数値でない引数を直して当該ステップから再実行する |

## ステップ 5: E2E フロー継続 (出力パターン)


**用語**: **soft failure** / **hard fail-fast** / **stale** / **silent regression** を区別する。
rationale: references/design-rationale.md#output-pattern-notes

**Flow detection method:** Claude determines the caller from the conversation context using mechanical pattern matching:

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Conversation history contains a record of native `Skill` or equivalent body execution invoking `rite:fix` from a caller (recent message) | Within loop → Execute ステップ 5 |
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
- **継続** (`[fix:pushed]` / `[fix:pushed-wm-stale]`): `--handoff "/rite:pr-review {pr_number} --from-iterate"` で**ループ継続マーカー**をセットする（再注入される review も iterate の内側として扱う）。
- **正常終了** (`[fix:replied-only]`): `--handoff "FINALIZE:fix:replied-only:{pr_number}"` をセットする。caller の **5.S sweep 後も返信のみの終了理由を保持**する。
- **非 fatal のみ** (`[fix:non-fatal-only]`): `--handoff "FINALIZE:fix:non-fatal-only:{pr_number}"` をセットする。caller の **5.S sweep を経てから**完了通知へ進む。
- **sweep 完了** (`[fix:sweep-done]`): `--handoff "FINALIZE:fix:sweep-done:{pr_number}"` で**終了通知マーカー**をセットする。**ステップ 1 に戻らない**（再フルレビュー禁止）。
- **エラー** (`[fix:error]`): `--handoff` を**付けない** (handoff はデフォルトクリア)。`[fix:error]` は clean terminal ではなく caller (`/rite:iterate` ステップ4) で1回自動再試行し、再失敗時に停止するため、完了通知を強制してはならない。

判定入力は本ステップ時点で確定済み。**(push 完了 or 本 cycle accept or 本 cycle の PR 本文の修正) かつ fatal 未 set → 継続 handoff**。push・accept・PR 本文の修正のいずれも無く fatal 未 set → FINALIZE。fatal → `--handoff` なし。`WM_UPDATE_FAILED` は継続を打ち消さない。accept・PR 本文の修正の条件の SoT は row 4/4.5/5 注記。

> `[fix:error]` 早期 exit では pr-review がセットした `/rite:fix` handoff を消さない。default-clear は iterate ステップ 3 の `--handoff` なし set。

行 1.5/1.6 の `NB_SWEEP_DONE_FILE` は会話 marker 欠落時の代替。`-f` 単独は成功にしない。1 行目の第 2 フィールドが、collect と同じ選び方（`LC_ALL=C` sort の末尾）の最新 review JSON basename と一致するときだけ `1`（通常ループは行 1.5 が `NB_SWEEP=1` を要求するため本 marker だけでは分岐しない）:

```bash
bash {plugin_root}/scripts/fix-step.sh nb-sweep-done-file --pr {pr_number}
```

`{fix_result}` は下表で選んだ出力 pattern の角括弧内から `fix:` を除いた値（`pushed` / `pushed-wm-stale` / `non-fatal-only` / `replied-only` / `sweep-done` / `error`）。`pushed` と `pushed-wm-stale` は同じ継続 handoff をセットする。

```bash
bash {plugin_root}/scripts/fix-step.sh output-handoff --pr {pr_number} --result {fix_result}
```

**Note on `error_count`**: phase transition ごとに 0 リセット (`--preserve-error-count` で保持)。
rationale: references/design-rationale.md#output-pattern-notes

**Also update local work memory** (`.rite/work-memory/issue-{n}.md`) with phase transition:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md) for details and marketplace install notes.

```bash
bash {plugin_root}/scripts/fix-step.sh local-wm-sync --issue '{issue_number}'
```

lock failure は WARNING で継続。non-lock は WARNING + stderr 5 行で継続。分岐は exact phrase ([common-error-handling.md](../../references/common-error-handling.md#hook-lock-contention-classification-canonical))。

Then, based on the ステップ 4.6 completion report content **and the WM_UPDATE_FAILED context flag**, output the corresponding machine-readable pattern:

| 評価順 | Condition | Output Pattern |
|--------|-----------|---------------|
| 1 (最優先) | ステップ 1.0.1 / 1.2.0 / 1.2.0.1 で `[CONTEXT] FIX_FALLBACK_FAILED=1` を context に set した (`reason` の値は ステップ 1.0.1 / 1.2.0 / 1.2.0.1 failure reasons table を **唯一の真実の源** として参照する。本セルでの固定列挙は drift 防止のため行わない) | `[fix:error]` (ステップ 1.0.1 / 1.2.0 / 1.2.0.1 のレビューソース解決失敗。fallback 経路が尽きたか、ユーザーが Interactive Fallback で中止を選んだか、ファイルパス指定の再実行でも有効なレビュー結果を取得できなかった状態のため caller は手動介入を促す) |
| 1.5 | `[CONTEXT] NB_SWEEP=1` かつ（`[CONTEXT] NB_SWEEP_RESULT=done` または `[CONTEXT] NB_SWEEP_DONE_FILE=1`） | `[fix:sweep-done]`（ステップ 1 に戻らない） |
| 1.6 | `[CONTEXT] NB_SWEEP=1` かつ `NB_SWEEP_RESULT=done 以外` かつ `NB_SWEEP_DONE_FILE` 非 1 | `[fix:error]` |
| 2 | ステップ 2.4 で `[CONTEXT] REPLY_POST_FAILED=1`、またはステップ 2.3 で `[CONTEXT] FIX_PR_BODY_EDIT_FAILED=1` を context に set した | `[fix:error]` (人間由来 thread への reply post、または PR 本文の更新が失敗。push 済みの可能性はあるが、返信または本文の修正が PR に残っていないため caller は次の iteration ではなく手動介入を促す) |
| 2.5 | ステップ 4.6 直前の gate が `[CONTEXT] FIX_REPORT_DIFF_GATE=error` を context に set した | `[fix:error]`（`map_missing` / `state_unreadable` / `diff_failed` / `jq_missing`。`unverified` / `passed` は本行にマッチしない） |
| 3 | ステップ 4.5 (4.5.1 または 4.5.2) で `[CONTEXT] WM_UPDATE_FAILED=1` を context に set した (`reason` の値は下記 reason 表のいずれか — 固定列挙は行わず、reason 表を唯一の真実の源とする) | `[fix:pushed-wm-stale]` (ステップ 4.5 で work memory 更新が silent skip された旨を caller に明示伝達。caller は work memory が stale であることを認識して fix loop を再実行するか手動介入する) |
| 4 | (Push completed (`プッシュ: 完了`) または 本 cycle 内で accept 決定が発生 [`[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED=1` または `[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1` が 1 回以上 context に出現] または 本 cycle 内で PR 本文を直した [`[CONTEXT] FIX_PR_BODY_EDITED=1`]) かつ work memory 更新成功 | `[fix:pushed]` |
| 4.5 | Push なし かつ 本 cycle 内で accept 決定なし (上記 2 マーカーがいずれも非出現) かつ 本 cycle 内で PR 本文の修正なし (`[CONTEXT] FIX_PR_BODY_EDITED=1` 非出現) かつ `{fatal_count}=0` かつ `{non_fatal_moved_count}>0` かつ All findings replied | `[fix:non-fatal-only]`（5.S sweep へ） |
| 5 | Push なし かつ 本 cycle 内で accept 決定なし (上記 2 マーカーがいずれも非出現) かつ 本 cycle 内で PR 本文の修正なし (`[CONTEXT] FIX_PR_BODY_EDITED=1` 非出現) かつ All findings replied | `[fix:replied-only]`（5.S sweep 後も返信のみで終了） |
| 6 | Unexpected state / error | `[fix:error]` |

上から最初にマッチした pattern を採用。fatal 旗 (`FIX_FALLBACK_FAILED` / `REPLY_POST_FAILED` / `FIX_PR_BODY_EDIT_FAILED` / `FIX_REPORT_DIFF_GATE=error`) → `[fix:error]`。次に `WM_UPDATE_FAILED` → `[fix:pushed-wm-stale]`。その後に通常終了。`FIX_REPORT_DIFF_GATE=unverified` / `passed` は fatal ではない。

**row 4/4.5/5 の accept・PR 本文の修正の条件 — 唯一の真実の源**: iterate ステップ 4 が読む sentinel の決定箇所。Handoff 節と 4.6 Note は参照のみ。

「本 cycle 内で accept 決定が発生」= `ACCEPT_FINGERPRINT_PERSISTED=1` **または** `ACCEPT_FINGERPRINT_PERSIST_FAILED=1` の本 cycle 出現。`{accept_count}` (累計) は使わない。両マーカー欠落時は accept 無し。「本 cycle 内で PR 本文を直した」も同じく `FIX_PR_BODY_EDITED=1` の本 cycle 出現で判定する。
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
| `config_unreadable` | ステップ 4.5.2 | rite-config.yml が存在するのに読めない、または main checkout root を解決できない。base branch を決められないため git diff と helper を呼ばない |
| `base_branch_unresolved` | ステップ 4.5.2 | rite-config.yml が無い、または `branch.base` を読めない。既定の base で補わず、git diff と helper を呼ばない |
| `git_diff_failed` | ステップ 4.5.2 | changed-files-file 用 mktemp の失敗、または `git diff --name-status origin/{base_branch}...HEAD` の失敗 (shallow clone / 無効な base / git リポジトリ外)。helper を呼ばず work memory comment を不変に保つ (原実装が git diff 失敗時に PATCH 前で exit したのと等価) |
| `wm_sync_progress_failed` | ステップ 4.5.2 | `issue-comment-wm-sync.sh ... --transform update-progress` が no_comment 以外の skipped/error status を返した (必須引数欠落 invalid_args / body 取得失敗 / safety check 失敗 / transform 失敗 / PATCH 失敗を helper が内部処理し status= 行で通知) |
| `wm_update_helper_failed` | ステップ 4.5.2 caller | helper の結果 marker 不在（欠落・起動不能・引数不正等） |
| `wm_sync_history_failed` | ステップ 4.5.2 | `issue-comment-wm-sync.sh ... --transform append-section` (レビュー対応履歴) が no_comment 以外の skipped/error status (必須引数欠落 invalid_args を含む) を返した、または履歴 content-file の mktemp が失敗 |
| `cat_redirection_failed` | ステップ 2.4 / 4.5.x (cat redirection を使う任意箇所) | cat redirection の exit code が非ゼロ (本文ファイル不在 / disk full / write permission denied / IO error)。ステップ 4.5.1 / 4.5.2 の WM 更新経路など、cat redirection を使う任意箇所で発火する可能性があるため、Phase 列は exhaustive な実 emit 箇所のリストではなく、典型的に発火する代表 phase の例示 |
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
bash {plugin_root}/scripts/fix-step.sh override-cleanup --pr {pr_number}
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
bash {plugin_root}/scripts/fix-step.sh override-cleanup --pr {pr_number}
```

未作成なら `rm -f` は no-op。
