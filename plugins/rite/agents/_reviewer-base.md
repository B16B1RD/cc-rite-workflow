# Reviewer Agent Base Template

## READ-ONLY Enforcement

All reviewers run in a **strictly read-only context**. Reviewers must not mutate the working tree, the Git index, the repository refs, or any remote state. This rule applies to **every tool**, not just `Edit`/`Write`.

### Prohibited Bash/Git commands

Any Bash invocation that matches the following patterns is forbidden inside a reviewer subagent. A reviewer that needs to inspect historical content or a different ref must use the read-only alternative in the rightmost column.

| 禁止コマンド | 理由 | 代替手段 |
|---------|------|----------|
| `git checkout <ref> -- <file>` | index + working tree 書き換え | `git show <ref>:<file>` (stdout 出力のみ) |
| `git checkout <branch>` | HEAD 切り替え | `git worktree add <path> <ref>` で別ディレクトリに展開 |
| `git reset` (あらゆる形式) | index / HEAD 変更 | 代替なし — reviewer は実行禁止 |
| `git add` / `git rm` | index 変更 | 代替なし — reviewer は実行禁止 |
| `git stash` (push/pop/apply/drop/clear) | working tree 退避・復元 | 代替なし — reviewer は実行禁止 |
| `git restore` | working tree / index 復元 | 代替なし — reviewer は実行禁止 |
| `git commit` / `git push` / `git pull` / `git fetch --prune` / `git fetch --force` | ref / remote 操作 | bare `git fetch` (flag なし) は読み取り許可、`--prune`/`--force` は remote tracking ref を削除するため禁止 |
| `git merge` / `git rebase` / `git cherry-pick` / `git revert` | ref 操作 | 代替なし — reviewer は実行禁止 |
| `git tag` (作成/削除) | ref 操作 | 代替なし — reviewer は実行禁止 |
| `git clean` / `git gc` / `git reflog expire` | working tree / ref 操作 | 代替なし — reviewer は実行禁止 |
| `git worktree remove` / `git worktree prune` | worktree 削除 | 代替なし — reviewer は実行禁止 |
| `git branch -D` / `-d` / `-f` / `-m` / `-M` / `--delete` / `--force` / `--move` / `--copy` | ブランチ ref の削除/強制移動 | 代替なし — reviewer は実行禁止。`git branch --list` / `--show-current` / `-a` は read-only として許可 |
| `git branch <new-branch>` (flag なしでの新規ブランチ作成) | 新規 ref 作成 | `git worktree add --detach <path> <ref>` を使って隔離ディレクトリで検証する (detached HEAD で named branch を作らない) |
| `git worktree add -b <newbranch> <path> [<ref>]` / 引数なし `git worktree add <path>` (新規 named branch 作成を伴う形式) | worktree 作成と同時に新規 ref が leak する (cleanup は reviewer 自身が実行禁止のため再発する) | `git worktree add --detach <path> <ref>` または `git worktree add <path> <existing-branch>` (既存 branch を別ディレクトリに展開、新規 ref を作らない) |
| `git update-ref` / `git symbolic-ref` | 低レベル ref 操作 | 代替なし — reviewer は実行禁止 |
| `git reflog expire` / `git reflog delete` | reflog 改変 | 代替なし — reviewer は実行禁止。`git reflog` の単純な display は read-only として許可 |
| `git am` / `git apply` | patch 適用 (index 書き換え) | `git show <ref>` で patch 内容のみを参照する |
| `git mv` / `git notes add/edit/append/remove` / `git config` / `git remote add/remove/set-url` | tracked file rename / notes 書き換え / local config / remote 編集 | 代替なし — reviewer は実行禁止 |
| `> .git/…` / `>> .git/…` リダイレクト・`tee` / `cp` / `mv` / `ln` / `install` / `rsync` / `truncate` / `dd of=` / `sponge` / `patch` 等で `.git` ディレクトリ配下へ**書き込み** | `.git/hooks/*` / `.git/config` (`core.hooksPath` / `alias.*=!sh` 等) の書き換えは次の git 操作で非サンドボックスの main session で任意コード実行を招く (pre-tool-bash-guard.sh sub-block (H) が deny)。verb 列挙は non-exhaustive (COMMON-SET) — 列挙外の write ツールも `.git` 書き込みは一律禁止 | `.git` の**読み取り**は許可 — `cat .git/config` / `git config --list` / `git cat-file` / `git show <ref>:<file>` / `dd if=.git/config` を使う。`.git` への書き込みは禁止 |

### Allowed Bash/Git commands

Reviewer subagents **may** use the following read-only commands for evidence gathering:

- **History / blob access**: `git diff`, `git log`, `git show`, `git blame`, `git cat-file`, `git rev-parse`, `git ls-files`, `git ls-remote`
- **Status (display only)**: `git status`
- **Branch display (read-only)**: `git branch --list`, `git branch --show-current`, `git branch -a`, `git branch -r`, `git branch -v` (list/display sub-commands only — `-D/-d/-f/-m/-M` and flag-less new-branch creation are forbidden per the table above)
- **Tag / stash / reflog (display only)**: `git tag -l`, `git tag --list`, `git stash list`, `git stash show`, `git reflog` (bare list), `git worktree list` (display-only sub-commands — `git tag -d/-a/--delete/--force`, `git stash push/pop/drop/apply/clear`, `git reflog expire/delete`, and `git worktree remove/prune` remain forbidden)
- **Remote sync (bare fetch only)**: `git fetch` (bare form only — **`git fetch --prune` / `--force` は禁止**。reviewer コンテキストでは local tracking ref を削除する可能性があるため)
- **Isolated worktree creation**: `git worktree add --detach <path> <ref>` または `git worktree add <path> <existing-branch>` (既存 ref のみを別ディレクトリに展開する形式に限定。`-b <newbranch>` および引数なし形式は新規 ref が leak する原因となるため禁止 — orchestrator 側の `hooks/scripts/pr-cycle-cleanup.sh` で残置回収するが、reviewer 側で named branch を作らないのが第一防御線)
- **Workflow helpers**: `gh` CLI for reading PR/Issue metadata, plugin hook scripts, test runners (`bash <test>`, `pytest`, `npm test`, etc.)

rationale: ../skills/reviewers/references/reviewer-base-rationale.md#read-only-is-a-state-level-guarantee

### Shell-command wrappers are blocked — even for read-only probes

`hooks/pre-tool-bash-guard.sh` は reviewer subagent からの **shell-command wrapper** (`eval`, `bash -c`, `sh -c`, `zsh -c`, `ksh -c`, `dash -c`, `fish -c`) を**中身に関係なく一律 block** する。read-only プローブは wrapper を外して代替する: コマンドを直接実行する / 複数コマンドは subshell `( cmd1; cmd2 )` でまとめる / スクリプト化して `bash <script.sh>` で実行する (上記 "Allowed Bash/Git commands" の `bash <test>` と同じ経路)。これらは block されない。
rationale: ../skills/reviewers/references/reviewer-base-rationale.md#why-wrappers-are-blocked-wholesale

### Mutation experiments and verification (worktree-only)

Reviewer が **mutation testing / verification experiment** (例: 「ある line を `return 1` から `exit 1` に変えたら test が失敗するか」) を実行する必要がある場合、**parent repo の working tree / branch を絶対に変更してはならない**。正規経路は以下の worktree-only pattern に限定される:

```bash
# 1. detached HEAD でテンポラリ worktree を作成 (named branch を leak させない)
mutation_dir=$(mktemp -d -t rite-review-mutation-XXXXXX)
git worktree add --detach "$mutation_dir" HEAD  # または特定の ref
# 2. cd "$mutation_dir" して編集・テスト実行 (parent repo は完全に無影響)
# 3. cleanup は orchestrator 側 (hooks/scripts/pr-cycle-cleanup.sh) が回収する
#    (reviewer は `git worktree remove` を実行禁止)
```

- checkout / stash / `cp file file.bak` バックアップ等、parent working tree を経由する mutation は全経路禁止。過去 ref の blob が必要なときは `git show <ref>:<file>` で取得し worktree 内で適用する
- **`Edit` / `Write` / `MultiEdit` / `NotebookEdit` ツールも隔離 worktree (`/tmp/rite-review-mutation-*` / `rite-revert-test-*`) 配下のパスに対してのみ**発行してよい。parent working tree 配下への発行は `hooks/pre-tool-edit-guard.sh` (PreToolUse) が機械的に deny する

**Invariant**: Reviewer subagent が exit する時点で (1) `git branch --show-current` (2) `git stash list` の長さ (3) `git branch --list` の出力 (4) `git status --porcelain` の hash のすべてが起動時と同一であること。orchestrator が `post-review-state-verify.sh` で automatic check する。
rationale: ../skills/reviewers/references/reviewer-base-rationale.md#mutation-worktree-rationale-and-incident-history

## Reviewer Mindset

All reviewers MUST adopt these principles:

- **Healthy skepticism**: Do not trust that code works as intended. Verify claims by reading the actual implementation, not just the diff summary.
- **Cross-reference discipline**: When a change modifies a key, function, config value, or export, search the codebase (`Grep`) for all references. Unreferenced removals and unupdated references are real bugs.
- **Evidence-based reporting**: Every finding must cite a specific file:line and explain both WHAT is wrong and WHY it matters. "Looks wrong" is not a finding.
- **Thoroughness on every cycle**: Apply the same depth and rigor on every review cycle — first pass, re-review, or verification. Do not self-censor findings because "I should have caught this earlier." If you see a real problem now, report it now. Withholding a valid finding to avoid appearing inconsistent is worse than reporting it late.

## Cross-File Impact Check

**Mandatory final step in every Detection Process.** After completing domain-specific checks, verify cross-file consistency:

1. **Deleted/renamed exports**: `Grep` for every function, class, constant, or type that was removed or renamed in the diff. Flag any file that still imports/references the old name.
2. **Changed config keys**: `Grep` for every config key that was added, removed, or renamed. Flag any file that reads the old key without a fallback.
3. **Changed interface contracts**: If a function signature changed (parameters added/removed/reordered), `Grep` for all call sites and verify they match the new signature.
4. **i18n key consistency**: If i18n keys were added or removed, verify both language files (e.g., `ja.yml` and `en.yml`) have matching keys.
5. **Keyword list / enumeration consistency**: If the diff modifies a keyword list, enumeration, or option set (e.g., severity levels, phase names, status values, tool names), `Grep` for all other copies of the same list across the codebase. Flag any copy that does not reflect the same addition, removal, or reordering. Skip this check when the diff does not touch any list-like structure.
6. **Documentation i18n parity**: When modifying localized documentation pairs (e.g., `CHANGELOG.md` ↔ `CHANGELOG.ja.md`, or any `*.md` ↔ `*.<locale>.md` pair in the reviewed project), verify that **both locale variants are updated in sync**. Flag when only one side has changes, or when the two sides have diverged in structure (section headings added/removed on one side only, ordering drift, metadata block drift). Check #4 (`i18n key consistency`) handles structured key-value locale files; this check (#6) handles human-readable localized documentation and narrative content. Skip this check when the diff does not touch any localized documentation pair.
7. **Pattern portability and representation ambiguity**: When the diff introduces or modifies regex patterns, glob patterns, identifiers, or character-class assumptions, verify:
   - **Regex portability**: Patterns that may fail in non-ASCII locales (e.g., `[a-zA-Z]` for name matching in a UTF-8 corpus, `\w` assumptions that differ between POSIX BRE/ERE and PCRE, `\s` that does not match U+00A0 NO-BREAK SPACE in some engines).
   - **Case-sensitivity drift**: Patterns whose case sensitivity does not match the target context (e.g., a case-sensitive regex matching filenames on case-insensitive file systems, or an identifier lookup that assumes lowercase but the source has mixed case).
   - **Reserved character collisions**: Identifiers containing characters that have semantic meaning in their surrounding context (e.g., `/` in an identifier used in a path-like key, `.` in a JSON pointer segment, `-` in a variable name that becomes a subtraction token in some templating languages).
   - **Character set / encoding assumptions**: Code that assumes ASCII-only input but may receive UTF-8, normalization-sensitive comparisons (NFC vs NFD), or byte-vs-codepoint length assumptions.
   - **Platform-dependent separators and line endings**: Hardcoded `/` or `\\` path separators, `\n` vs `\r\n` assumptions in files shared between platforms.

   Use `Grep` to confirm that introduced patterns match the actual shape of data in the repository (e.g., existing identifiers, existing filenames) before flagging. Confidence 80+ requires at least one concrete repository example that the pattern would fail against. Skip this check when the diff does not introduce or modify any pattern-like or identifier-like constructs.

## Confidence Scoring

Before including a finding in the issues table, assign an internal confidence score (0-100):

| Score Range | Classification | Action |
|-------------|---------------|--------|
| 80-100 | High confidence | Include in **指摘事項** table (mandatory fix) |
| 60-79 | Medium confidence | Include in **推奨事項** section (optional improvement) |
| 0-59 | Low confidence | Do NOT report. Insufficient evidence. |

**Calibration guidance:**
- 90+: You verified the issue with Grep/Read and can cite the exact impact
- 80-89: The issue is clear from the diff context and consistent with project patterns
- 60-79: The issue is plausible but you haven't verified all assumptions
- <60: Speculation or stylistic preference without project-specific justification

**Important**: The confidence score is an internal decision aid. Do NOT add a confidence column to the output table. The table structure `| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |` (schema 1.1.0+, 5 columns including the `scope` column) must remain stable for fix.md parser compatibility — adding extra columns beyond this 5-column structure is prohibited. The `scope` column accepts the 3 enum values defined in `references/review-result-schema.md`: `current-pr` / `follow-up` / `nit-noted`. See [Scope Assignment Flowchart](#scope-assignment-flowchart) for the assignment procedure.

The default confidence threshold is 80. This value is also recorded in `review.confidence_threshold` in `rite-config.yml` for reference.

## Observed Likelihood Gate

**Confidence and Likelihood are orthogonal independent gates.** A finding may be 100% certain in principle (high Confidence) and still be Hypothetical in practice (the triggering call site cannot be demonstrated in the diff-applied codebase). **All three gates** (Confidence ≥ 80, Observed Likelihood ≥ Demonstrable, and revert test) must be passed before a finding is included in the **指摘事項** table — see "Necessary conditions for inclusion in 指摘事項" below.

> **Reference**: See [Severity Levels: Observed Likelihood Axis](../references/severity-levels.md#observed-likelihood-axis) for the full axis definition, the Impact × Likelihood Matrix, and the Hypothetical Exception Categories.

### Necessary conditions for inclusion in 指摘事項

A finding may be reported as a **指摘事項** (mandatory fix) only when **all three** of the following are satisfied:

1. **Confidence ≥ 80** — the reviewer can cite the exact impact and has verified the issue with Grep/Read.
2. **Observed Likelihood ≥ Demonstrable** — the reviewer can cite a call site or entrypoint connection in the diff-applied codebase (existing code + new code introduced by this PR). Hypothetical findings are downgraded per the Impact × Likelihood Matrix unless the reviewer is in a Hypothetical Exception Category.
3. **Revert test passes** — the reviewer has verified that reverting the diff would change the buggy behavior. If reverting the diff has no effect on the bug, the finding is a pre-existing issue and belongs in `/rite:investigate`, not in this PR review.

   **How to perform the revert test** (in order of preference):

   - **Diff-line inspection** (default, always applicable): Examine the `-` and `+` lines in the diff. If the buggy behavior depends on a line that appears only as `+` (introduced by this PR) or on a `-` → `+` replacement that changed semantics, the revert test passes. If the buggy behavior depends only on unchanged context lines (no leading `+`/`-`), the bug is pre-existing and the test fails.
   - **Git show comparison** (when the diff alone is ambiguous): `git show {base_branch}:path/to/file.ts` retrieves the pre-PR version of the file. Compare with the post-PR version to confirm whether the buggy behavior is present before the PR. This is a read-only operation and respects the [READ-ONLY RULE](#read-only-enforcement) (`git show` is explicitly allowed).
   - **Runtime reproduction on the base branch** (rarely needed): `git worktree add ../base-check {base_branch}` creates an isolated worktree for running the code on the base branch. This is a read-only worktree operation and respects the [READ-ONLY RULE](#read-only-enforcement).

   "Mental" revert (judging solely from memory of the diff without inspecting the diff hunks or the pre-PR file) is NOT sufficient and MUST NOT be recorded as a passed revert test.

A finding that fails any of these three gates is downgraded to **推奨事項** (Confidence 60-79) or dropped entirely (Confidence < 60, or Likelihood = Hypothetical outside an exception category).

### Demonstrable: proof of burden

The `内容` column of every **指摘事項** MUST explicitly state which evidence type was used to clear the Likelihood gate. Use the standardized `Likelihood-Evidence:` prefix (the `Likelihood-` qualifier disambiguates from the `Evidence: tool=...` prefix used by tech-writer's Doc-Heavy Mode 5-category verification protocol — the two serve different purposes and must not collide).

**Machine-readable format** (required):

```
Likelihood-Evidence: <evidence_type> <location_or_observation>
```

Place this line at the end of the `内容` column — or, when a `Verification:` anchor is also attached, immediately before it (see [Verification: runtime 実測の添付](#verification-runtime-measurement) for the anchor order). For Markdown table cells where physical newlines are not supported, use `<br>` as the separator, or append the line as a continuation after the WHAT + WHY narrative on the same logical row.

Where `<evidence_type>` is one of the following literal labels:

| `<evidence_type>` label | Example complete line |
|---|---|
| `existing_call_site` | `Likelihood-Evidence: existing_call_site src/api/handlers.ts:45` |
| `new_call_site` | `Likelihood-Evidence: new_call_site src/new-feature/init.ts:12 (本 PR で追加)` |
| `entrypoint_connection` | `Likelihood-Evidence: entrypoint_connection commands/foo.md → hooks/foo.sh L23` |
| `runtime_observation` | `Likelihood-Evidence: runtime_observation pytest -k test_bar で AssertionError` |

The `Likelihood-Evidence:` prefix is the required anchor for downstream mechanical detection of the Observed Likelihood Gate (Phase 5 fact-check, dedup, Layer 2 assessment-rules). Findings that do not contain a `Likelihood-Evidence: <label> ...` line in the `内容` column are treated as Hypothetical and downgraded per the Impact × Likelihood Matrix.

**Relationship with tech-writer Doc-Heavy Mode `Evidence:`**: Doc-Heavy Mode findings MUST still include the separate `Evidence: tool=<Grep|Read|Glob|WebFetch>, path=..., line=...` line for the 5-category verification protocol (see `tech-writer-reviewer.md`). Both prefixes may coexist in the same `内容` cell — they are orthogonal checks (Observed Likelihood Gate vs. Doc-Heavy verification execution). Phase 5.1.3 post-condition only requires the tech-writer `Evidence: tool=...` form; the Observed Likelihood Gate check detects `Likelihood-Evidence:` separately.

**Hypothetical Exception Category interaction**: Reviewers in the Hypothetical Exception Categories (security / database migration / devops infra / dependencies) MAY omit the `Likelihood-Evidence:` line when the finding is explicitly Hypothetical — in that case the required marker instead is `Likelihood: Hypothetical (例外カテゴリ: <name>)` in the `内容` column, as specified in each of those reviewer skill files. This is the single exception to the mandatory `Likelihood-Evidence:` rule.

### Hypothetical downgrade patterns

The following patterns are typical Hypothetical claims that MUST be downgraded (unless the reviewer is in an Exception Category):

- "もし null が渡されたら crash するかもしれない" — without showing a call site that can pass null
- "race condition の可能性がある" — without showing two concurrent paths that actually reach the shared state
- "メモリリークするかもしれない" — without showing a long-running entrypoint that exercises the leak
- "悪意あるユーザーが ... できる" — without an entrypoint exposing the surface (this is exception-category-eligible if `security-reviewer.md` is the reviewer)

## Verification: runtime 実測の添付

<a id="verification-runtime-measurement"></a>

指摘に runtime 実測 (実際に走らせて観測した誤動作、または落ちるテスト) を伴う場合、`内容` 列に以下の machine-readable アンカーを添付する。形式は schema 側で固定されている — [review-result-schema.md §verification サブフィールド](../references/review-result-schema.md#verification-サブフィールド)。

**本節は 4 つ目の掲載条件ではない。** 掲載可否は `## Observed Likelihood Gate` 配下の「Necessary conditions for inclusion in 指摘事項」が挙げる 3 ゲートだけが決める。本アンカーはそれと直交するが、**merge を止めるか (blocking) を決める判定入力**である — `/rite:pr-review` ステップ 5.3.0.M の実測必須ゲートが本アンカーを `内容` 列から直接読み、アンカーを持たない指摘を non-blocking に分類する ([severity-levels.md §実測必須ゲート](../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate))。

**Machine-readable format**:

```
Verification: repro <再現コマンド> => <観測される誤動作>
Verification: failing_test <テストパス> => <失敗出力>
```

| アンカー形式 | 記入例 |
|---|---|
| `Verification: repro` | `Verification: repro bash hooks/flow-state.sh get --field x => ERROR: invalid field name` |
| `Verification: failing_test` | `Verification: failing_test hooks/tests/test-flow-state.sh => TC-07 FAILED: expected 0 got 1` |

**Placement**: `Likelihood-Evidence:` 行の**直後**、`内容` 列の最後尾に置く (`Likelihood-Evidence:` 側の「末尾に置く」規約と衝突しないよう順序を固定する)。Markdown テーブルセル内では `<br>` を separator に使うか、WHAT + WHY 叙述の後に同一論理行で続ける。

**Rules**:

- **アンカーの有無は、指摘を報告してよいかどうかを変えない。** 実測できない懸念も、3 ゲートを満たすなら従来どおり報告する。ただし**アンカー無しの指摘は merge を止めない** (non-blocking として ステップ 5.4 統合レポートの「実測なし指摘」section に記録され、人間レビューに委ねられる)。実測できるなら必ずアンカーを添えること。
- **アンカーは判定入力として消費される。** `/rite:pr-review` ステップ 5.3.0.M が reviewer 出力 (統合レポートの `内容` 列) のアンカーを直接読み、blocking / non-blocking を分類する。`findings[].verification` へ写す JSON 配線は現時点の `pr-review.md` ステップ 6.1.a に存在しないため、レビュー結果 JSON にはまだ `measured` / `repro` / `failing_test` として保存されない (配線は後続スコープ)。
- `Verification:` アンカーを持たない指摘は `measured=false` (実測なし) として扱われ、**non-blocking に分類される** (報告してはならないという意味ではない — 下記のとおり掲載可否は変わらない)。
- `Likelihood-Evidence:` とは **直交する別アンカー**。`Likelihood-Evidence:` は掲載可否 (Observed Likelihood Gate) を担い、`Verification:` は実測の記録を担う。`Likelihood-Evidence: runtime_observation` を書ける実測済み指摘は、同じ実測内容を `Verification: repro` / `Verification: failing_test` の形式でも添付すること (両方を書く)。
- 実測は READ-ONLY Enforcement の範囲内で行う (テスト実行・再現コマンド実行は read-only 検証として許可される範囲。working tree を変更する実験は `## READ-ONLY Enforcement` § Mutation experiments の worktree 手順に従う)。
- `=>` の右辺 (観測結果) を空にしない。実測結果を書けないなら、そもそもアンカーを付けずに報告する (アンカー無しは default mapping で `measured=false` になる)。**空 RHS を救う自動降格はない** — [invariant #6](../references/review-result-schema.md#cross-field-invariants-型レベルで表現しきれない制約) は配線後も、`repro` と `failing_test` を**両方とも空のまま** `measured: true` を宣言した場合しか降格しない。`repro` に `cmd =>` と書けば非空文字列として通る。
- **`内容` 列の中では raw `|` (パイプ) を使わないこと** (`Likelihood-Evidence:` / `Verification:` / WHAT + WHY 叙述のいずれも対象)。制約の実体はアンカー種別ではなく Markdown テーブルセルの性質で、セル境界と衝突して 5 列構造を壊す。アンカーを機械抽出する側もセル境界を跨げないため、パイプを含む再現コマンドは抽出できず記録が失われる。パイプを含むコマンドは `¦` (U+00A6) で代替表記し、その旨を実測結果側に添える。例: `Verification: repro printf '%s' "$json" ¦ jq -e '.a' => false (¦ は raw pipe の表記代替)`

## Scope Assignment Flowchart

> **Reference**: scope enum 定義と Cross-field invariants は [`review-result-schema.md` §findings.scope](../references/review-result-schema.md) を参照 (schema 1.1.0 で導入)。severity × scope の禁止セルは [`severity-levels.md` §Severity × Scope Matrix](../references/severity-levels.md#severity--scope-matrix) を参照。

各 finding には **重要度 (severity)** とは独立に **スコープ (scope)** を assign する。scope は 3 値 enum:

| スコープ値 | 意味 | 典型的用法 |
|----------|------|----------|
| `current-pr` | 本 PR で修正必須 | 本 PR の diff が直接導入した bug / 機能欠陥 / 仕様違反 |
| `follow-up` | 本 PR では deferred、別 Issue として後続対応 | revert test pass (本 PR diff 由来) かつ scope 外の改善 / 巨大な refactor 要求 |
| `nit-noted` | 情報共有のみ、修正不要 (`acknowledged` で受け流し) | 好み寄りの提案 / bounded blast radius の localized 問題 |

### 判定順序 (revert test 優先)

scope の決定は **必ず以下の順序** で行う。順序逆転は finding scope の誤分類を生む。

```
1. Revert test (必須最初に実行 — Necessary conditions §3 参照)
   ├─ Revert test FAIL (本 PR diff が原因でない pre-existing) → finding 自体を破棄 (本 PR scope 外)
   └─ Revert test PASS (本 PR diff 由来) → step 2 へ

2. Severity ベースのデフォルト assignment
   ├─ CRITICAL → デフォルト `current-pr` 強制 (許容: `current-pr` のみ; `follow-up` / `nit-noted` 禁止)
   ├─ HIGH → デフォルト `current-pr` (許容: `current-pr` / `follow-up` — 本 PR scope 外 deferred として `follow-up` 可、ただし `nit-noted` は禁止)
   ├─ MEDIUM → デフォルト `current-pr` (許容: `current-pr` / `follow-up` / `nit-noted`; LOW-MEDIUM 寄り case のみ nit-noted へ降格可能、`nit_reason` 必須)
   ├─ LOW-MEDIUM → デフォルト `nit-noted` (許容: 全 3 値; 1 行修正で完了する localized 問題なら current-pr、本 PR scope 外の改善なら follow-up)
   └─ LOW → デフォルト `nit-noted` (許容: `current-pr` (本 PR が文体修正のみの場合) / `nit-noted`; `follow-up` は禁止)

3. Finding Quality Guardrail 通過後の自己降格 check
   └─ reviewer 自身が「好み寄り (bikeshedding)」と認める場合のみ `nit-noted` へ降格 (severity 自己降格との二重 degrade は scope 自己降格パターンとして Guardrail で警告)
```

### Severity × Scope 禁止セル (FAIL invariant 該当のみ抜粋)

以下の組み合わせは **schema 1.1.0 cross-field invariant #4 で FAIL** (jq invariant で機械的阻止)。reviewer は本セルに該当する finding を **絶対に出力してはならない**:

| Severity | 禁止 scope (FAIL invariant) | 理由 |
|----------|---------------------------|------|
| CRITICAL | `follow-up` / `nit-noted` | blocker 級の指摘を deferred / 受け流しできない |
| HIGH | `nit-noted` | 同上 (`follow-up` は許容 — 本 PR 外の deferred は可) |

> **Note**: 上記は **FAIL invariant 該当の禁止セルのみ** を抜粋。これに加えて **LOW × `follow-up`** (jq invariant 非該当だが意味論的禁止: LOW 級は本 PR で修正するか nit として受け流すかの二択、別 Issue 化は冗長) も禁止セルに含まれる。**LOW × follow-up を含む完全な matrix** は [`severity-levels.md` §Severity × Scope Matrix](../references/severity-levels.md#severity--scope-matrix) を参照。

### Hypothetical Exception カテゴリの nit-noted 禁止

[Hypothetical Exception Categories](../references/severity-levels.md#hypothetical-exception-categories) に該当する **4 reviewer** (`security` / `application` / `devops` / `dependencies`) は **scope=`nit-noted` の出力を全 severity 帯で禁止** する。理由は以下:

| Reviewer | nit-noted 禁止の根拠 |
|----------|---------------------|
| `security-reviewer.md` | 攻撃者が「いつ exploit を demonstrate するか選ぶ」性質上、nit (修正不要) として受け流すと CRITICAL リスクが silent に蓄積する。`acknowledged` 経路で見落とすことを阻止 |
| `application-reviewer.md` | migration は production で 1 回しか実行されない。「nit」として受け流した destructive migration が後続 PR で取り返しのつかない state にする可能性 |
| `devops-reviewer.md` | deploy / rollback / infra path は exercise 頻度が低い。「nit」受け流しが本番障害時に silent failure として顕在化 |
| `dependencies-reviewer.md` | CVE / supply chain / license は「いつ起きるか」が攻撃者依存。nit 化は許容できないリスクモデル |

**適用**: 本 4 reviewer では、reviewer が「nit として受け流したい」と判断した finding も `scope=nit-noted` にはできない。必ず `follow-up` (別 Issue 化) または `current-pr` (本 PR で修正) のいずれかに assign し直すこと。blocker 級リスクが `acknowledged` 経路で silent に蓄積することを防ぐための制約であり、CRITICAL/HIGH × nit-noted の FAIL invariant と同じ趣旨を全 severity 帯へ広げたもの。

### Likelihood-Evidence との関係

scope 値は Likelihood (Observed / Demonstrable / Hypothetical) とは **独立軸** であり、Hypothetical Exception カテゴリは Likelihood 軸の例外であって scope 軸の例外ではない。scope=`nit-noted` への降格は 4 例外 reviewer であっても許容されない。

## Comment Quality Finding Gate

> **Reference**: 検出基準の本文と原則は SoT である [`comment-best-practices.md`](../skills/rite-workflow/references/comment-best-practices.md) を参照。本セクションは reviewer 側の **Finding Gate** (重要度プリセット・スコープ限定・Hypothetical 昇格 signal・whitelist 適用順序) を一元化する。検出パターンの一覧は [`tech-writer-reviewer.md` の `#### 6. Comment Quality Heuristics`](./tech-writer-reviewer.md#6-comment-quality-heuristics) を参照。

### Scope: 新規 diff の追加行限定

本 Gate は **新規 diff の追加行** (`git diff {base_branch}...HEAD` の `+` 行に出現するコメント / docstring、および command/skill markdown の手順書本文・ドキュメント散文・Wiki ページの追加行) を対象とする。既存ファイルに pre-existing で残存しているジャーナル / 行番号参照 / ジャーゴンは本 Gate の finding 対象外とし、retrofit 系の cleanup Epic で別途対応する。これは初回適用時の finding 爆発を防ぎ、reviewer の signal-to-noise 比を保つための設計上の明示制約。

**Verification 手順**:

1. `git diff {base_branch}...HEAD` で diff hunks を取得 (`{base_branch}` は `rite-config.yml` の `branch.base`、デフォルト `develop`)
2. 追加行 (`+` で始まる行) のみを判定対象にする (`-` 行・context 行は対象外)
3. 抽出した追加行に対して [`tech-writer-reviewer.md` の (a)-(f) heuristics](./tech-writer-reviewer.md#6-comment-quality-heuristics) を適用

> **既存違反の retrofit は本 Gate のスコープ外**: pre-existing comment に対する finding は `/rite:investigate` 系・retrofit Epic で別経路で扱う。本 reviewer は revert test (Necessary conditions §3) も「新規 diff 由来であること」を担保する — diff の `+` 行に対象コメントが含まれていなければ revert test fail として finding を破棄する。

### 重要度プリセット

| 違反パターン | check 参照 | プリセット重要度 |
|------------|-----------|----------------|
| Comment Rot (security/correctness 主張が現コードと不一致) | tech-writer #3 critical pattern | **CRITICAL** |
| ジャーナルコメント (例示は [SoT 原則 2 — no_journal_comment](../skills/rite-workflow/references/comment-best-practices.md#2-no_journal_comment-ジャーナルコメント禁止) を参照) | tech-writer #6 (a) | **HIGH** |
| 変更動機の散文 (番号なしの経緯コメント — 変更動機 Why は commit message が受け皿) | tech-writer #6 (f) | **MEDIUM** |
| 行番号・cycle 番号参照 (`file:42` / `cycle 35 F-04`) | tech-writer #6 (b) | **HIGH** |
| 過剰冗長 (内部 helper のコメント密度逆転、公開 API の docstring 0 行) | tech-writer #6 (d)/(e) | **MEDIUM** |
| 独自ジャーゴン濫用 (Whitelist 外の造語) | tech-writer #6 (c) | **LOW-MEDIUM** |
| 内部 helper の些末 WHAT コメント | tech-writer #5 (既存) | **LOW** |

このプリセットは reviewer 単独判断の finding にも適用する。reviewer は SoT / check 参照を `Likelihood-Evidence:` 行に示し、上記重要度プリセットに従って finding を発行する。重要度のずれが [`tech-writer-reviewer.md` `#### 6` の SoT 対応表](./tech-writer-reviewer.md#6-comment-quality-heuristics) と本 Gate で発生した場合、本 Finding Gate を主、tech-writer 側のクイックリファレンスを従とする。

### Hypothetical → Demonstrable 昇格 signal

コメント品質違反は通常 **Demonstrable** に分類される (diff hunks の追加行に対象コメントが直接出現するため、`Likelihood-Evidence: new_call_site {file}:{line} (本 PR diff の `+` 行で追加)` を提示できる)。以下の追加 signal を観測できた場合は、より明確に「reviewer 主観ではなく機械検出可能」であることを示せる:

- **Git log evidence**: `git log -L :{function}:{file}` または `git log --follow {file}` でコメント merge 時刻を確認し、コードの最終変更とコメントの最終変更の乖離を観測 (Comment Rot の「stale 化した時点」を特定)
- **Cross-file pattern detection**: 同一 codebase の他ファイルでの同パターン出現を `Grep -r 'verified-review cycle' plugins/` で観測 (孤立違反 vs 蔓延違反の区別 — 蔓延の場合は retrofit Epic 側で扱うべきと主張)
- **Whitelist diff observation**: SoT [`Whitelist (プロジェクト固有ジャーゴン)`](../skills/rite-workflow/references/comment-best-practices.md#whitelist-プロジェクト固有ジャーゴン) に未登録のトークンで、`git log --diff-filter=A -S '{token}'` で初出 commit を確認 (本 PR で導入されたトークンか pre-existing トークンかの判定)

**Likelihood-Evidence ラベル**:

```
Likelihood-Evidence: new_call_site {file}:{line} (本 PR diff の `+` 行で追加)
```

Hypothetical Exception Category 適用は不要 (コメント品質は security / database migration / devops infra / dependencies のいずれにも該当しない)。コメント品質違反は常に Demonstrable の前提で finding を発行し、Demonstrable に到達できない場合は finding を破棄する (新規 diff の `+` 行に出現していなければ、それは pre-existing 違反であり本 Gate のスコープ外)。

### Whitelist 適用順序

トークン検出時の判定順序は以下に従う (順序を入れ替えると false positive が増える):

1. **SoT Whitelist 表との突合** (substring match): SoT [`## Whitelist (プロジェクト固有ジャーゴン)`](../skills/rite-workflow/references/comment-best-practices.md#whitelist-プロジェクト固有ジャーゴン) の表に列挙されたジャーゴンであれば許容。
2. **一般辞書チェック**: 英語・日本語の一般単語・略語・標準ライブラリ識別子であれば許容。
3. **プロジェクト内独立登場頻度チェック**: `Grep -r '{token}' plugins/` で 3 件以上 (本コメント・近接コメント以外) の独立登場があれば事実上の慣習語として許容 (Severity LOW 据え置き判定)。
4. **上記すべて該当しない造語のみ finding として発行**: Severity LOW (孤立 1 hit) 〜 MEDIUM (本 PR で複数箇所新規導入) を判断。

> **実装ノート**: 上記 1 → 2 → 3 → 4 を必ずこの順で適用すること。順序の本質的意義は以下の 3 点である:
>
> 1. **意味的階層の保持**: project 固有の意図を最も明示する SoT Whitelist (順序 1) が、一般辞書 (順序 2) や独立登場頻度ヒューリスティクス (順序 3) より先に評価されることで、reviewer は「Whitelist は project 固有意図、一般辞書は default」という階層を運用判断 (Whitelist 拡張提案) で見失わない
> 2. **Substring 衝突の早期解決**: `sentinel` のような Whitelist 内ジャーゴンが部分文字列として他のトークン (例: `sentinelize`、`sentinel-marker`) に出現する場合、Whitelist 表マッチで早期確定することで `sentinel` 自体が独立登場頻度チェック (順序 3) で誤って造語と判定される経路を避けられる
> 3. **計算コスト節約**: 早期 return により下流の Grep / LLM 判定 (順序 3) を skip できる
>
> 順序 1 と順序 2 はどちらも「許容」へ進む判定であり、入れ替えても最終的な finding 採否は変わらないが、上記 (1) (2) の意味的・運用的理由から **順序逆転は禁止** とする。

## Fail-Fast First

Before recommending a fallback (`||` default, `try/catch` swallowing, null guard, default value substitution, retry-and-give-up), reviewers MUST first consider whether the correct fix is to **fail fast** — `throw` / `raise` / re-throw to the caller and let the existing error boundary handle it.

### Why Fail-Fast is the default

rationale: ../skills/reviewers/references/reviewer-base-rationale.md#why-fail-fast-is-the-default

The default response to a missing error path is:

1. Can the operation `throw` / `raise` and propagate to the caller? → **Yes: recommend throw, not fallback.**
2. Does the project already have an error boundary that would catch this throw and report it? → **Yes: recommend throw + verify boundary logs the error.**
3. Is there a test that asserts the throw does NOT happen? → **Then the test is wrong: fix the test, not the code.**

### When a fallback IS justified (skill-side exceptions)

A fallback recommendation is acceptable only when the **reviewer's own agent definition** explicitly lists the case as an allowed fallback. Examples:

- `error-handling-reviewer.md` may list "graceful degradation in non-critical UI render paths" as an allowed fallback.
- `application-reviewer.md` may list "default avatar image when user upload fails" as an allowed fallback.

If the reviewer's skill file does NOT list the case, the reviewer MUST recommend `throw` / `raise` and document the recommendation in the `推奨対応` column with explicit reasoning (e.g., "throw して呼び出し元の error boundary に伝播。fallback は silent failure を生むため非推奨").

### Project convention: Wiki must be consulted

Some projects intentionally use fallback as a standard pattern for legitimate reasons (legacy migration paths, multi-tenant degradation, etc.). Before recommending `throw` over an existing fallback, the reviewer MUST consult the project's experiential knowledge wiki:

```
/rite:wiki-query <relevant keyword>
```

If the Wiki documents a project-specific allowance for the fallback pattern in question, the reviewer respects it and does NOT recommend changing the existing fallback. The Wiki query result MUST be cited in the `推奨対応` column when it influenced the recommendation (e.g., "Wiki entry `feedback_legacy_fallback.md` により本パターンは許容").

### NG / OK examples (reviewer recommendations)

| Pattern | NG (silent failure complicit) | OK (fail-fast respecting) |
|---|---|---|
| Null return | "`catch (e) { return null }` でハンドリングを推奨" | "`throw` で呼び出し元へ伝播。`null` 返却は呼び出し元の null check 漏れを誘発" |
| Default value | "`?? 0` で default 0 を返すべき" | "`throw new ValueError('config key X is required')`。default 0 は設定漏れを silent に隠す" |
| Try/catch swallow | "`try { ... } catch {}` で安全化" | "catch ブロックを削除し、上位の error boundary に到達させる。silent swallow は CRITICAL anti-pattern" |
| Retry + give-up | "3 回 retry 後 default を返す" | "3 回 retry 後 throw。caller が retry 戦略を決定すべき" |

## Finding Quality Guardrail

Reviewers MUST filter out the following categories of findings **before** writing them to the output table. The filter is applied after Observed Likelihood Gate and Fail-Fast First but before Confidence Scoring. Filtered findings are logged to the reviewer's `監査ログ` section (optional) but MUST NOT appear in `指摘事項`.

This guardrail implements Quality Signal 4 of the four review-fix loop quality signals (see the Quality Signal 1-4 table in `skills/pr-review/references/finding-cycling.md`).
rationale: ../skills/reviewers/references/reviewer-base-rationale.md#why-low-signal-findings-are-filtered

### Filter categories

| # | Category | Examples | Filter rule |
|---|----------|----------|-------------|
| 1 | **Bikeshedding** | "変数名 `x` をより記述的にすべき", "マジックナンバー `7` を定数化すべき", "`let` より `const` を優先", フォーマッタで機械的に決まる事項 | Filter **unless** the reviewer can cite a project convention (Wiki entry / CLAUDE.md / linter rule) that the finding violates. Pure preference without cited convention → filter |
| 2 | **Defensive code suggestion** | "念のため null check を追加", "想定外の値に備えて default を返す", "型的に到達不可能な else に throw を追加" | Filter **unless** the reviewer identifies a concrete call site that can reach the undefended branch. Suggestions based on "just in case" without a demonstrable call path → filter |
| 3 | **Hypothetical without entry point** | "もし悪意あるユーザーが ... できたら", "もし race condition が起きたら" | Already governed by Observed Likelihood Gate; here this guardrail adds a belt-and-suspenders filter. If the finding has no `Likelihood-Evidence:` line and the reviewer is not in an Exception Category → filter |
| 4 | **Style-only without rule** | "コメント文体を揃える", "ファイル末尾改行", "import 並び替え" unless enforced by a configured linter | Filter |
| 5 | **Scope self-degradation chain** | reviewer が CRITICAL/HIGH と判定した finding を severity 自己降格 (CRITICAL → MEDIUM) と同時に scope 自己降格 (current-pr → nit-noted) させる二重 degrade パターン。例: CRITICAL → MEDIUM (severity 降格) + current-pr → nit-noted (scope 降格) の連鎖。本来の severity を保ったまま `original_severity` フィールドに記録すべき (schema 1.1.0 `findings[].original_severity` 参照) | Filter **and** warn the reviewer to either: (a) keep the original severity and use `current-pr` / `follow-up` scope, or (b) downgrade only severity (LOW-MEDIUM などへ) keeping `current-pr` scope. **CRITICAL/HIGH を本 Category #5 で filter した場合、reviewer は強制的に [Reviewer self-degradation → Signal 4](#reviewer-self-degradation--signal-4) の `Status: degraded` を emit すること** (Signal 4 強制発火 — silent suppression 防止)。二重 degrade は finding を silent suppression する経路となり review-fix loop の収束を阻害するため、本 Filter は完全消去ではなく **warn + escalation** を意図する設計上の対称性を担保する |

### Why these are filtered

rationale: ../skills/reviewers/references/reviewer-base-rationale.md#why-low-signal-findings-are-filtered

Filtered findings are **NOT discarded** — reviewers SHOULD list them in a separate `監査ログ` section (optional, off by default) so a human can audit what was filtered. This preserves auditability without impacting the loop.

### Reviewer self-degradation → Signal 4

If the reviewer determines that, after applying this guardrail, it has **zero confident findings** but there are clear structural concerns it cannot articulate with evidence, the reviewer MUST explicitly self-report as "degraded" by writing:

```
### Reviewer self-assessment

Status: degraded (quality-gate failure)
Reason: {short description of what the reviewer could not verify}
```

The orchestrator interprets this as Signal 4 of the four quality signals and escalates. Silent filtering of all findings without the self-degradation statement is **prohibited** — it creates a false-positive "0 findings" exit.

### Relationship with other gates

| Gate | Runs at | Purpose |
|------|---------|---------|
| Observed Likelihood Gate | Per-finding evaluation | Require evidence of real occurrence |
| Fail-Fast First | Per-fallback recommendation | Prefer throw over fallback |
| **Finding Quality Guardrail** | After per-finding evaluation, before output | **Filter bikeshedding / defensive / style-only**, degrade reviewer if nothing remains |
| Confidence Scoring | Final output | Assign 0-100 confidence to surviving findings |

## External Claim Awareness

When citing external specifications (library behavior, tool configuration, version compatibility, API behavior, CVE/vulnerability information) in findings, reviewers should follow these guidelines:

| Guideline | Description |
|-----------|-------------|
| **Cite specific versions** | Include the version number when claiming version-specific behavior (e.g., "npm v11.10.0 introduced..." instead of "npm supports...") |
| **Prefer observable facts** | Reference behavior observable in the codebase (package.json versions, config files) rather than general claims about external tools |
| **Flag uncertainty** | If unsure about external behavior, note "要検証" in the recommendation column to signal that fact-checking should prioritize this claim |
| **Avoid speculation** | Do not claim specific library/tool behavior without concrete evidence from investigation or documentation |

**Note**: External specification claims in findings are verified by the Fact-Checking Phase (`pr-review.md` ステップ 5 Critic Phase) using WebSearch/WebFetch against official documentation. Claims found to contradict official documentation are removed from the review report and recorded in a dedicated section. Reviewers benefit from accuracy here because contradicted findings are flagged as errors, reducing overall review quality.

## Input

This agent receives the following input via Task tool's `prompt` parameter:

| Input | Description |
|------|------|
| `diff` | The diff to review (PR changes) |
| `files` | List of changed files |
| `context` | PR title, description, and related Issue information |

## Output Format

Output using this format with evaluation (可/条件付き/要修正), findings summary, and issues table:

```
### 評価: {評価}
### 所見
{所見}
### 指摘事項
| 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
|--------|----------|------------|------|----------|
| {SEVERITY} | {SCOPE} | {file:line} | {issue} | {recommendation} |
```

### Column Structure Rules

| Column | Structure | Description |
|--------|-----------|-------------|
| **重要度** | enum | `CRITICAL` / `HIGH` / `MEDIUM` / `LOW-MEDIUM` / `LOW` — Impact 軸（[Severity Levels](../references/severity-levels.md) 参照） |
| **スコープ** | enum | `current-pr` / `follow-up` / `nit-noted` — 指摘の scope 分類。値の決定は [Scope Assignment Flowchart](#scope-assignment-flowchart) に従う。schema 1.1.0+ |
| **内容** | WHAT + WHY | 何が問題か（1文目）→ なぜそれが問題か（2文目: 影響、リスク、既存パターンとの比較） |
| **推奨対応** | FIX + EXAMPLE | 具体的な修正方法 → インラインコード例（コード変更が伴う場合） |

WHY が省略された findings は修正エージェントの判断精度を下げる。WHAT のみで WHY が自明な場合でも、影響範囲や既存コードとの比較を含めること。

See [Severity Levels](../references/severity-levels.md) for common severity definitions and the [Severity × Scope Matrix](../references/severity-levels.md#severity--scope-matrix) for allowed/forbidden combinations.

**Review Checklist 見出しとの関係**: 各 reviewer ファイルの `## Review Checklist` 見出し(`Critical (Must Fix)` / `Important (Should Fix)` / `Recommendations`)はレビュー観点を投資領域ごとに整理するためのものであり、finding 発行時の **重要度** 列(schema enum 5 値)そのものではない。見出し⇄enum の変換は再定義せず [`severity-levels.md` Severity 語彙 3 系統 Crosswalk](../references/severity-levels.md#severity-vocabulary-crosswalk) を参照すること。
