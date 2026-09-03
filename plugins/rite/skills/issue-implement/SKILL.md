---
name: issue-implement
description: |
  rite workflow の実装 sub-skill: 実装作業・コミット・プッシュ・チェックリスト更新を行う。
  /rite:open から programmatic に呼ばれる（ユーザーは直接起動しない）。汎用の「実装して」
  ヘルパーではなく、その語では auto-activate しない。
argument-hint: "<issue_number>"
user-invocable: false
---

# Implementation Guidance

## 5.1 Implementation Work

`skills/open/SKILL.md` ステップ 3 で承認した計画に従って実装する。

> **Reference**: Apply the Phase 5.1 checklist from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).
> In particular, check `simplicity_enforcement`, `scope_discipline`, `dead_code_hygiene`, and `knowledge_routing` — route each finding to its durable medium (How → code, What → tests, Why → commit log, Why not → comments).
> Also follow [Comment Best Practices](../../skills/rite-workflow/references/comment-best-practices.md) for WHY > WHAT, journal/line-number/cycle-number prohibition, jargon whitelist, and density-by-audience rules.

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands in this file.

### 5.0.L Contract Literalism Mandate（全 Complexity 共通）

実装は Issue 契約の字義に限定する。契約の根拠として使えるのは Target Files、Scope、MUST / MUST NOT、Non-goal であり、これらで必要性を説明できないオプション・パラメータ・guard・一般化・予約フィールドは実装しない。迷った場合は小さい実装を選ぶ。

契約外の必要性に気付いた場合は実装せず、既存の Issue コメントへ必要性と根拠を記録して差し戻す。拡張は実需を記した別 Issue の契約として扱い、現在の実装へ先回りして含めない。

本 mandate は **XS / S / M / L / XL の全 Complexity に適用する**。Complexity レーンは儀式コストと生産量制約だけを変え、本 mandate の適用有無を変えない。

### 5.0.F テスト規律（全 Complexity 共通）

task が求める挙動 1 つにテスト 1 つ。隣接するテストファイルと同規模。scratch の検証スクリプトを permanent test にしない。既存 suite がある種別は新規ファイルより追記する。テスト数の上限は設けない。
rationale: references/rationale.md#test-file-discipline

既存 suite が無い種別は新規テストファイルを認め、規模は隣接テストファイルに合わせる。**XS/S では 5.1.0.8 の新規テストファイル禁止が優先**し、既存 suite が無くても新規ファイルは作らない。

削った scratch と残したテストの判断は work memory の決定事項に記録する（silent 削除禁止）。本規律は **XS / S / M / L / XL の全 Complexity に適用する**。レーンは 5.1.0.8 の抑制表だけを変え、本規律の適用有無を変えない。

### 5.0.C Complexity Lane Determination (XS/S 軽量レーン)

対象 Issue の**宣言 Complexity** からレーンを決める。同じ helper が 5.1.0.1 と 5.1.0.8 の両方に供給する。
rationale: references/rationale.md#complexity-read-once

```bash
bash {plugin_root}/scripts/issue-complexity-lane.sh --issue {issue_number}
```

> **Reference**: 設計根拠（レーン境界 / 何を制約し何を制約しないか / 情報欠落時に必ず `full` へ倒す理由）は [complexity-lane.md](../pr-review/references/complexity-lane.md) が SoT。reason 語彙は helper docstring が SoT。**reason は分岐を変えない** — 全 reason が `full` に落ち WARNING を伴う。**helper が非ゼロ終了した / `COMPLEXITY_LANE=` marker を観測できない場合も `full` として扱い**、`⚠️ Complexity レーン判定のフォールバック: reason=helper_failed。フル装備 (M+ 相当) で実行します。` を出力する（consumer 側の既定。silent fallback 禁止）。

| `COMPLEXITY_LANE` + `complexity=` | 5.1.0.1 並列実装ゲート | 5.1.0.8 生産量制約 |
|---|---|---|
| `light` + `complexity=XS` | 順次実装（並列しない） | 適用（新規テストファイル抑制 **+ 説明的派生散文の新設禁止**） |
| `light` + `complexity=S` | 順次実装（並列しない） | 適用（新規テストファイル抑制） |
| `full` + `complexity=M` / `L` / `XL`（宣言値あり） | 従来どおり独立タスク数で判定 | 適用しない（現行どおり） |
| `full` + `COMPLEXITY_LANE_FALLBACK=1`（fail-safe 全 reason） | **順次実装（並列しない）** — 本ゲートでは `full` が攻撃的な側のため、欠落時は減らす方へ倒す | 適用しない（現行どおり） |

### 5.0.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki-query/SKILL.md) — `wiki-query-inject.sh` API

**Condition**: `wiki.enabled: true` AND `wiki.auto_query: true`。それ以外は silent skip。

**Step 1**: Wiki 設定:

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

`wiki_enabled=false` または `auto_query=false` なら実装へ。

**Step 2**: 計画のステップ記述・対象パス・ドメイン用語から keywords を生成して query:

```bash
# {plugin_root} はリテラル値で埋め込む
# {keywords} は実装計画のキーワード（ファイルパス、ドメイン用語等）をカンマ区切りで生成
# （他コーラー skills/issue-create/SKILL.md / skills/fix/SKILL.md /
#   skills/pr-review/SKILL.md / skills/unknowns/SKILL.md と同形式）
wiki_context=$(bash {plugin_root}/hooks/wiki-query-inject.sh \
  --keywords "{keywords}" \
  --format compact 2>/dev/null) || wiki_context=""
if [ -n "$wiki_context" ]; then
  echo "$wiki_context"
else
  echo "(Wiki から関連経験則は見つかりませんでした)"
fi
```

**Step 3**: `wiki_context` が非空なら会話 context に保持し、実装中に参照する。

### 5.0.T Canon TDD Cycle (Conditional)

> **Reference**: Canon TDD (Kent Beck) — test list → pick one behavior → Red (write a failing test) → Green (minimal implementation) → Refactor → repeat until the list is empty. The `tdd:` config key is documented in [CONFIGURATION.md](../../../../docs/CONFIGURATION.md) (`### tdd`).

`tdd.enabled: true`（既定、opt-out）なら 5.1 の各挙動を Canon TDD で進める。

**Step T1: Configuration gate** (same sed/awk read pattern as 5.0.W):

```bash
# tdd.enabled を読む (opt-out default: tdd: キー欠落 / enabled: 欠落 はいずれも true 扱い)
tdd_section=$(sed -n '/^tdd:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || tdd_section=""
tdd_enabled=""
if [[ -n "$tdd_section" ]]; then
  tdd_enabled=$(printf '%s\n' "$tdd_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$tdd_enabled" in false|no|0) tdd_enabled="false" ;; *) tdd_enabled="true" ;; esac  # opt-out default
# commands.test の有無を判定 (degrade detection)
test_cmd=$(awk '/^commands:/{c=1;next} c&&/^[a-zA-Z]/{exit} c&&/^[[:space:]]+test:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*test:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$test_cmd" in ''|null|'~') test_cmd="" ;; esac
echo "[CONTEXT] TDD_ENABLED=$tdd_enabled; TEST_CMD_SET=$([ -n "$test_cmd" ] && echo yes || echo no)"
```

**Mode routing** (read `[CONTEXT] TDD_ENABLED` / `TEST_CMD_SET` from context):

| TDD_ENABLED | TEST_CMD_SET | Mode | Behavior |
|---|---|---|---|
| `true` | `yes` | **Full Canon TDD** | Execute the Step T2 cycle with real Red/Green test runs |
| `true` | `no` | **Degraded TDD** | Execute Step T2 but skip the Red/Green auto-run; keep the test-list discipline. Display `TDD: テスト実行 skip（commands.test 未設定）` |
| `false` | (any) | **Disabled** | Skip 5.0.T entirely; run the conventional flow (5.1.0 / Basic implementation flow) unchanged (behavior identical to before this feature) |

**Step T2: Canon TDD cycle** (Full / Degraded modes):

1. **Build the test list**: Seed from the Issue's Section 6 Test Specification (the `## 6. Test Specification` table; each `T-xx` row is one list item). Append newly discovered behaviors to the list as they surface during implementation.
2. **Pick one behavior** from the list (smallest unverified behavior first). Exactly one behavior per cycle iteration.
3. **Red — write the test and confirm it fails**:
   - Write a single test for the picked behavior (Edit/Write).
   - **Full mode**: run `commands.test`; confirm the new test **fails** (Red). If it passes immediately, the test does not exercise the target behavior — display `TDD: テストが最初から通過。対象挙動を検証できていない可能性` and revise the test before proceeding.
   - **Degraded mode**: skip the run and record that Red could not be auto-confirmed (test-list discipline still applies).
4. **Green — minimal implementation**: implement the **smallest** change that makes the test pass; do not add unrequested behavior.
   - **Full mode**: confirm Green by reusing 5.1.0.6's **test-execution step** (run `commands.test`, check the exit code) per behavior — do NOT re-implement test execution here. This per-behavior Green check reuses only the *execution* procedure; the **full 5.1.0.6 Test Verification Gate** (with its `max_implementation_rounds` budget and "return to Phase 5.1 on failure" semantics) still runs **once** after all behaviors are complete, as the pre-commit gate (canonical chain `5.1.0.6 → 5.1.0.6.1 → 5.1.0.7 → 5.1.0.8 → 5.1.1`).
   - **Degraded mode**: skip the run.
5. **Refactor — only after Green**: improve structure with tests passing. **Refactoring on a Red / unverified state is prohibited** — if not Green (Full mode) or Green is unconfirmed (Degraded mode), do not refactor; return to step 4 or move to the next behavior.
6. **Repeat** from step 2 until the test list is empty (every listed behavior implemented and, in Full mode, Green).

TDD 中の並列は Red/Green を共有しない Refactor（T2.5）に限る。per-behavior Green は 5.1.0.6 の実行手順だけ再利用し、フルゲート（rounds / 5.1 戻り）は pre-commit で 1 回。
rationale: references/rationale.md#tdd-green-reuse

**Disabled**（`tdd.enabled: false`）: 5.0.T を skip。従来の 5.1.0 / Basic + 5.1.0.6 と同一。

**Basic implementation flow:**

1. Read で現状確認
2. Edit で変更
3. 必要なら Bash で検証
4. 計画順に繰り返す

| Tool | Usage |
|------|-------|
| Read | Check content of files to change |
| Edit | Add/modify code |
| Bash | Verify changes with `git status`, run tests |
| Glob/Grep | Explore related files (when needed) |

計画あり: `depends_on` が揃った次ステップを実行し、完了ごとに 5.1.0.5 で再評価。計画 skip: Issue の What / Where。判断は work memory に残す。大規模・複数セッションは `/rite:issue-update`（小変更は省略可）:

```
Skill ツール呼び出し:
  skill: "rite:issue-update"
```

### 5.1.0 Parallel Implementation (Conditional)

`parallel.enabled` が `true`（既定）かつ下記 **all** のとき並列する。

#### 5.1.0.1 Parallel Implementation Condition Check

| Condition | Determination Method |
|-----------|---------------------|
| `parallel.enabled: true` | From `rite-config.yml` (default: `true`) |
| Complexity M or above | 5.0.C の marker が `COMPLEXITY_LANE=full` **かつ `complexity=` を伴う**（= 宣言値が M / L / XL）。**`COMPLEXITY_LANE_FALLBACK=1` を伴う fail-safe 経路は満たさない**（下記）。**helper が 3 記法（`**Complexity**: X` / `| **Complexity** | X |` / `## 複雑度`）を受理するため、ここで body を再解析しない** — 2 箇所で別々に読むと片方だけが片方の記法に対応する drift が生まれる |
| 2 or more independent tasks | Determined from implementation plan (see below) |

Complexity を読めなかった Issue（`COMPLEXITY_LANE_FALLBACK=1`）は `full` に含めず**順次実装へ倒す**。判定キーは `COMPLEXITY_LANE=full` 単独ではなく `complexity=` の存在。
rationale: references/rationale.md#fail-safe-orientation

**Independent task determination:**

計画（`skills/open/SKILL.md` ステップ 3）の変更ファイルから独立性を判定:

| Criterion | Determined as Independent | Determined as Dependent |
|-----------|--------------------------|------------------------|
| Inter-file imports | No cross-references | One imports the other |
| Shared state | No shared variables/state | Shares global state |
| Execution order | Order-independent | Requires preceding task results |

**Determination flow:**

```
parallel.enabled を確認
├─ false → 5.1.0.1-5.1.0.4 parallel implementation はスキップ、5.1.0.5 Adaptive Re-evaluation / 5.1.0.6 Test Verification Gate / 5.1.0.6.1 Acceptance Criteria Check / 5.1.0.7 Documentation Impact Investigation / 5.1.0.8 XS/S Production Constraint を経て 5.1.1 へ
└─ true → 複雑度を確認
    ├─ XS/S → 通常の順次実装
    └─ M 以上 → 独立タスクを分析
        ├─ 独立タスク 1 件以下 → 通常の順次実装
        └─ 独立タスク 2 件以上 → parallel.mode を確認
            ├─ "shared"（デフォルト）→ 5.1.0.2 共有モード実行
            └─ "worktree" → 5.1.0.2W Worktree モード実行
```

#### 5.1.0.2 Parallel Implementation Execution (Shared Mode)

**Applies when**: `parallel.mode: "shared"` (default) or `parallel.mode` is not set.

Invoke multiple Task tools (`subagent_type: "general-purpose"`) **within a single message** for parallel execution. When exceeding `max_agents` (default: 3), split into batches of `max_agents`, waiting for each batch to complete before executing the next.

#### 5.1.0.2W Parallel Implementation Execution (Worktree Mode)

**Applies when**: `parallel.mode: "worktree"` in `rite-config.yml`.

> **Reference**: [Git Worktree Patterns](../../references/git-worktree-patterns.md) for complete operation patterns, merge strategy, and safety mechanisms.

**Step 1: Stale worktree detection and `.gitignore` verification**

Check for existing worktrees from previous runs:

```bash
# List existing worktrees (more than 1 entry means worktrees exist beyond the main)
git worktree list --porcelain

# Check for stale worktrees under the worktree base directory
ls -d {worktree_base}/*/* 2>/dev/null
```

If stale worktrees are found, offer cleanup via `AskUserQuestion` (see [Safety Mechanisms](../../references/git-worktree-patterns.md#safety-mechanisms)).

Verify `.worktrees/` is in `.gitignore`:

```bash
grep -q '^\.worktrees/' .gitignore 2>/dev/null || echo '.worktrees/' >> .gitignore
```

**Step 2: Create worktrees**

For each independent task identified in 5.1.0.1:

```bash
mkdir -p {worktree_base}/{issue_number}
git worktree add {worktree_base}/{issue_number}/{task_id} -b {branch_name}/{task_id} {branch_name}
```

Where `{worktree_base}` is from `parallel.worktree_base` in rite-config.yml (default: `.worktrees`).

**Error handling**: If `git worktree add` fails (e.g., branch already exists, path conflict):

| Exit Code | Likely Cause | Action |
|-----------|-------------|--------|
| Non-zero with "already exists" | Branch from previous run | Remove stale branch with `git branch -D {branch_name}/{task_id}` and retry |
| Non-zero with "is a worktree" | Path conflict | Remove with `git worktree remove --force {path}` and retry |
| Other non-zero | Unexpected error | Skip this task and fall back to sequential implementation |

**Step 3: Spawn agents in worktrees**

Invoke multiple Task tools **within a single message**, each with a specific worktree path. When exceeding `max_agents`, split into batches.

```
Task tool parameters:
  subagent_type: "general-purpose"
  prompt: "{task_description}. Work ONLY in {worktree_path}. Use ABSOLUTE paths for all file operations (e.g., {worktree_path}/src/file.ts). Do NOT run any git commands (checkout, commit, push, branch, merge, stash). You may use Read, Edit, Write, Glob, Grep, and Bash (for non-git commands like test/lint) tools."
```

Agent prompt は git 操作（checkout, commit, push, branch, merge, stash）を明示禁止する。git は orchestrator だけ。

**Step 4: Quality gate per worktree**

After all agents complete, run quality checks in each worktree if `commands.test` or `commands.lint` is configured:

```bash
cd {worktree_path} && {test_command} && {lint_command}
```

Exclude failed worktrees from merge (see [Quality Gate per Worktree](../../references/git-worktree-patterns.md#quality-gate-per-worktree)).

**Step 5: Merge worktree branches**

Merge each passing task branch back to the Issue branch using `--no-ff`:

```bash
git checkout {branch_name}
git merge --no-ff {branch_name}/{task_id} -m "chore(parallel): integrate {task_id} ({task_description})"
```

On merge conflict, follow the [first-merge-wins convention](../../references/git-worktree-patterns.md#conflict-resolution-convention).

**Step 6: Cleanup**

Remove all worktrees and task branches:

```bash
git worktree remove {worktree_base}/{issue_number}/{task_id}
git branch -d {branch_name}/{task_id}
```

Then prune worktree metadata: `git worktree prune`.

#### 5.1.0.3 Parallel Implementation Result Integration

Display results in a table. On partial failure, retain successful results and prompt manual handling for failures. Fall back to sequential implementation when all tasks fail. After parallel implementation, check for conflicts with `git status`.

**Worktree mode additional reporting**: When `parallel.mode: "worktree"`, include merge status and any conflict resolution actions in the results table.

#### 5.1.0.4 Parallel Implementation Skip

Use sequential implementation when: `parallel.enabled: false`, complexity S or below, 1 or fewer independent tasks, or plan was skipped.

#### 5.1.0.5 Adaptive Re-evaluation Checkpoint

各ステップ完了後、残ステップを再評価する。対象は `depends_on` 列のある計画（`skills/open/SKILL.md` ステップ 3.3）。計画 skip（ステップ 3.4）または `depends_on` 無しは skip。並列中は **batch 完了ごと**（個別タスクごとではない）。

固定の手順表・チェック表・閾値は持たない。記録義務は維持する。
rationale: references/rationale.md#adaptive-no-fixed-checklist

各ステップ完了時に、次の 4 つを状況に応じて判断し、判断の痕跡を work memory に残す:

1. **完了の確証**: このステップは計画の意図（`検証基準` 列があればその基準）を本当に満たしたか。ツールで確認できるもの（ファイル存在・パターン・テスト通過・設定値）は Read / Grep / Glob / Bash で確認してから完了にする。基準を満たせないまま完了扱いにしない。再試行しても満たせない場合は、基準側が誤っているのか実装が誤っているのかを判断し、基準を更新したなら「計画逸脱ログ」に記録する。繰り返し失敗して判断に迷うときは `AskUserQuestion` でユーザーに委ねる（続行 / 基準更新 / 逸脱記録つきスキップ）
2. **逸脱の検知と記録**: スコープ逸脱（計画外ファイルの変更）・共有コード変更の影響範囲・Issue の What/Why との乖離に気付いたら、work memory の「計画逸脱ログ」に既存のテーブル形式で記録する（記録は義務。閾値や固定チェックリストはない）。軽微な調整（同一ステップ内の手法変更・不要になったステップのスキップ・小さな補助ステップの追加）は記録して続行する。計画の前提を変える変更（計画外の新規ファイル追加・公開 API / 契約の変更・見積もりを大きく超えるスコープ拡大・残ステップの依存構造の組み替え）は `AskUserQuestion` でユーザーに確認する
3. **次ステップの選定**: `depends_on` が解けたステップの中から「次に最も明白な問題」を選ぶ。目安: 下流を最も多く解放するもの・リスクが高く早く失敗を表面化させたいもの・小さく完了して勢いを保てるもの — どれを優先するかは残りの計画全体を見て判断する
4. **行き詰まりの検知**: このステップが計画時の粒度見積もりを明らかに超えて膨らんでいる（修正の往復が続く、変更ファイル・行数が想定と乖離した）と感じたら、[Bottleneck Detection Reference](../../references/bottleneck-detection.md) の Oracle discovery（既存の正しい実装を構造ガイドに使う）でステップをサブステップ `S{n}.1`, `S{n}.2`, ... に再分解し、work memory の「ボトルネック検出ログ」に記録する（記録は次回 bulk update = commit 時）。固定閾値は使わない — 膨らみの判断は計画粒度との乖離で行う。再分解後は最初のサブステップから実行を続ける

完了表示を出す。永続化は commit 時 5.1.1.2 の一括更新（毎ステップではない）。

**Display format** (after each step, normal path):

```
✅ Step {completed_id} 完了: {step_description}

次のステップ候補:
| Step | 内容 | 状態 | 選出理由 |
|------|------|------|---------|
| {next_id} | {description} | 🔓 実行可能 | {reason} |
| {other_id} | {description} | 🔒 依存待ち ({pending_deps}) | - |

→ 次に実行: Step {next_id}
```

**Display format** (行き詰まり判断でステップを再分解した場合):

```
⚠️ ボトルネック検出: Step S{n} ({step_description})
検出理由: {なぜ膨らんでいると判断したかの短い説明}

Oracle: {oracle_source} ({oracle_file_path}) ／ なし（フォールバック分解を適用）

再分解:
| Step | 内容 | depends_on |
|------|------|------------|
| S{n}.1 | {sub_step_1} | — |
| S{n}.2 | {sub_step_2} | S{n}.1 |

→ 次に実行: Step S{n}.1
```

**When all steps are complete**: Proceed to 5.1.0.6 (Test Verification Gate), then 5.1.0.7 (Documentation Impact Investigation), then 5.1.0.8 (XS/S Production Constraint), then 5.1.1 (Commit). The chain is **5.1.0.6 → 5.1.0.6.1 → 5.1.0.7 → 5.1.0.8 → 5.1.1**; never bypass 5.1.0.7 or 5.1.0.8 on the way to commit.

#### 5.1.0.6 Test Verification Gate (Conditional)

Execute test verification before committing when conditions are met.

##### Condition Check

Read `rite-config.yml` and check:

| Condition | Check Method |
|-----------|-------------|
| `commands.test` is set | Non-null value in `rite-config.yml` |
| `verification.run_tests_before_pr` is `true` | From `rite-config.yml` (default: `true`) |

**Skip conditions** (any match → skip to 5.1.0.7, then 5.1.0.8, then 5.1.1):
- `commands.test` is `null` or not set
- `verification.run_tests_before_pr` is `false`

skip 時の表示:
- `commands.test` 未設定: `テスト検証: スキップ（commands.test 未設定）`
- `run_tests_before_pr: false`: `テスト検証: スキップ（verification.run_tests_before_pr: false）`

##### Test Execution

```bash
# rite-config.yml の commands.test を実行
{test_command}
```

**Result handling:**

| Exit Code | Action |
|-----------|--------|
| 0 | Tests passed → proceed to 5.1.0.6.1 (acceptance criteria check) → 5.1.0.7 (documentation impact investigation) → 5.1.0.8 (XS/S production constraint) → 5.1.1 (commit) |
| Non-zero | Tests failed → display failures, return to 5.1 implementation |

**On test failure:**

```
テスト失敗: {test_error_count} 件のテストが失敗しました

失敗したテスト:
{test_output}

実装を修正してテストを再実行してください。
```

Phase 5.1 へ戻る。commit しない。

再実行上限は `safety.max_implementation_rounds`。到達時は `AskUserQuestion`: `テスト再実行の上限に達しました（{max_implementation_rounds}回）。続行しますか？ オプション: 継続する / 中断してユーザーに確認`

E2E では結果を context に残す（`/rite:lint` Phase 3.4 が再利用できる）。

##### 5.1.0.6.1 Acceptance Criteria Check (Conditional)

**Condition**: `verification.acceptance_criteria_check` is `true` (default: `true`) AND Issue body contains an acceptance criteria section.

**Heading match rules**: Match any of the following headings (case-insensitive, level 2 `##`):

| Pattern | Examples |
|---------|---------|
| `## 受入条件` | Exact match (Japanese) |
| `## Acceptance Criteria` | Exact match (English) |
| `## 受け入れ条件` | Alternative Japanese form |

The section extends from the matched heading to the next `##` heading or end of body.

**Skip conditions** (any match → skip to 5.1.0.7, then 5.1.0.8, then 5.1.1):
- `verification.acceptance_criteria_check` is `false`
- Issue body does not contain an acceptance criteria section (none of the above headings found)

> `{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute する。

**Issue body retrieval**: Use the Issue body already obtained at `skills/open/SKILL.md` ステップ 1.1 Issue 情報取得 (retained in conversation context). If context was compacted and the body is unavailable, re-fetch with `gh issue view {issue_number} -R {owner_repo} --json body --jq '.body'`. If retrieval fails, display `WARNING: Issue body の取得に失敗。受入条件チェックをスキップします` and skip to 5.1.0.7 (then 5.1.0.8, then 5.1.1).

**Check procedure:**

1. Extract acceptance criteria items from Issue body (lines matching `- [ ]` or `- [x]` under the acceptance criteria heading)
2. For each criterion, evaluate whether the current implementation satisfies it based on:
   - Changed files and their content
   - Test results (if tests were run)
   - Implementation plan completion status
3. Display verification results:

```
受入条件チェック:
- {criterion_1} — 満たされています
- {criterion_2} — 満たされています
- {criterion_3} — 確認が必要です（理由: {reason}）
```

**Result handling:**

| Result | Action |
|--------|--------|
| All criteria satisfied | Proceed to 5.1.0.7 (documentation impact investigation) → 5.1.0.8 (XS/S production constraint) → 5.1.1 (commit) |
| Some need attention | Display via `AskUserQuestion`: `受入条件の一部が未確認です。続行しますか？ オプション: コミットに進む / 実装に戻る` |

advisory。ユーザーが続行を選べば止めない。

#### 5.1.0.7 Documentation Impact Investigation

> **Reference**: Apply `documentation_consistency` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).

コミット前にユーザー可視の仕様変更がドキュメント更新を要するか調べ、stale なら同じブランチで即直す。別 Issue に回さない。`AskUserQuestion` しない。
rationale: references/rationale.md#doc-impact-no-defer

##### Skip Conditions

Skip this entire section (proceed to 5.1.0.8, then 5.1.1) when **any** of the following holds:

| Skip condition | Determination |
|---------------|---------------|
| No specification change | The diff only touches internals (private functions, refactor, code style, comment-only edits) with no observable change to commands, configuration keys, file layout, public API, workflow phases, or user-visible behavior |
| Auxiliary documentation-only change | The diff only modifies auxiliary documentation that does NOT define user-visible workflow, commands, config keys, or specification — e.g., `CHANGELOG*`, release notes, or pure prose updates to `README*`. **Do NOT skip** when the diff touches files that define workflow or specification (e.g., `plugins/rite/skills/**/*.md`, `plugins/rite/references/**/*.md`, or any `docs/` file documenting a public API) — those changes are themselves the drift source that this step is meant to detect |
| Test-only change | The diff only touches test files (`*.test.*`, `*.spec.*`, `tests/**`) |

The decision is made by the LLM based on the actual diff (`git diff --name-status origin/{base_branch}...HEAD` plus the work memory's "決定事項・メモ") — there is no explicit trigger pattern. When in doubt, do **NOT** skip.

##### Investigation Procedure

固定 glob 列挙は持たない。実装が導入した**ユーザー可視の識別子**（コマンド名・config キー・ファイルパス・phase / workflow 名・hook / helper 名。ソースは work memory の「決定事項・メモ」と diff。内部限定は除く）ごとにリポジトリ全体を探し、食い違う記述を直す:

- Grep。`*.md` 決め打ちしない（拡張子なし README / CHANGELOG も対象）
- 今回の変更ファイル集合（`git diff --name-only origin/{base_branch}...HEAD`）は除外
- ヒットは Read で周辺確認。古い挙動・旧名称・削除済みなら Edit。正しいなら触らない。**迷ったら stale として更新する**
- 修正は実装と同じコミットにステージ。`AskUserQuestion` は使わない

##### Result Handling

| Result | Action |
|--------|--------|
| 0 hits across all keywords | Proceed silently to 5.1.0.8 (then 5.1.1) — no warning, no extra commit |
| Stale docs detected and auto-fixed | Stage the edited documentation files and proceed to 5.1.0.8 (then 5.1.1) — the documentation edits are committed in the **same** commit as the implementation. (Note: 5.1.0.7 always runs **before** 5.1.1 in the normal flow, so the implementation is never already committed at this point.) |
| Search command failed (Grep tool error, etc.) | Display warning `WARNING: ドキュメント影響調査でエラー: {error}. ステップをスキップして実装フェーズを継続します` and proceed to 5.1.0.8 (then 5.1.1) — do NOT block the flow |

##### Constraints

- **MUST NOT** invoke `AskUserQuestion` from this step
- **MUST NOT** defer detected drift to a separate Issue (this contradicts `issue_accountability` and the MUST NOT constraints)
- **MUST NOT** modify files outside documentation (no code changes triggered by this step)
- **MUST NOT** modify `plugins/rite/skills/reviewers/**`, `plugins/rite/hooks/**`, or `rite-config.yml` from this step — those are out of scope for documentation impact investigation

#### 5.1.0.8 XS/S Production Constraint (Conditional)

**Execution condition**: 5.0.C の `COMPLEXITY_LANE == light`。`full`（M / L / XL、および fail-safe 全 reason）のときは本サブセクション全体を skip し、挙動は本機能導入前と完全に同一。

コミット前に、本レーンで**生産しすぎていないか**を確認する。該当したものはコミット前に**削る**（follow-up Issue へ回さない）:
rationale: references/rationale.md#production-constraint-churn

| 制約 | 適用 | 判定 |
|---|---|---|
| **新規テストファイルを作らない** | XS / S | 新しい `*.test.*` / `*.spec.*` ファイルを作っていないか。検証は**既存 suite への assert 追加**で行う。新規テストファイルは M+ の装備 |
| **説明的派生散文を新設しない** | **XS のみ** | 実装から逆導出できる解説・列挙・トラジェクトリ引用・背景説明の**新規節**を書いていないか。XS で許されるのは**既存記述の同期**（既に存在する表・手順・reference の値を実装に合わせて更新すること）のみ |

**縮小しないもの**（本レーンでも M+ と同一）: 5.1.0.6 Test Verification Gate、5.1.0.6.1 Acceptance Criteria Check、5.1.0.7 Documentation Impact Investigation。5.1.0.7 が検出した stale ドキュメントの修正は「既存記述の同期」であり、XS でも**必ず実施する** — 本制約が禁じるのは新規の説明散文であって、既存記述を実装に合わせることではない。

削った事実は work memory の「決定事項・メモ」に記録する（silent 削除禁止）。

> **Reference**: なぜ散文の新設禁止が XS 限定で、新規テストファイル抑制が XS/S 両方なのか: [complexity-lane.md](../pr-review/references/complexity-lane.md#レーン境界を二値にする理由)。

### 5.1.1 Commit and Push Changes

**Commit procedure:**

1. `git status` で変更ファイルを確認
2. `git add {changed_files}` で明示 stage（**not** `git add .`）
3. Conventional Commits でメッセージ生成
4. `git commit`
5. `git push origin {branch_name}`（`-u` なし）
rationale: references/rationale.md#git-add-dot-sandbox
rationale: references/rationale.md#push-no-upstream

> **⚠️ CRITICAL**: commit message の `description` は `language` 設定に従う。例の言語をコピーしない。

形式 `{type}({scope}): {description}`。言語は `rite-config.yml` の `language`（`auto` は日本語文字の有無）。type/scope は常に英語。body は why を自由形式。description との間に空行。trivial は省略可。

```bash
git add {changed_files}
git commit -m "$(cat <<'EOF'
{commit_message}
EOF
)"
git push origin {branch_name}
```

`{changed_files}` は本フェーズで Edit/Write した実パスの明示列挙（`skills/fix/SKILL.md` ステップ 3.3 と同規約）。`git add .` / `git add -A` は使わない。commit / push は `/rite:pr-create` より前に完了する。

#### 5.1.1.1 Issue Body Checklist Update

**Execution condition**: `skills/open/SKILL.md` ステップ 3.5 でチェックリストを保持しているときだけ。

`git commit` 成功後と Phase 5.1 完了時に、変更ファイルとチェック項目の対応を見て `[ ]` → `[x]`。

> **⚠️ 注意**: `--body "$var"` は禁止。`--body-file` + 一時ファイル。
> rationale: references/rationale.md#body-file-not-var

3 段（Bash → Read+Write → Bash）。temp パスは Step 1 出力を Step 3 へ literal 渡し。検証失敗は WARNING して残りを skip（`exit 1` しない）。

**Step 1: Bash tool call — Fetch body and validate**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {issue_number}
```

Outputs: `tmpfile_read=<path>`, `tmpfile_write=<path>`, `original_length=<n>`. If fetch fails, outputs WARNING and exits 0 (skip).

**Step 2: Read tool + Write tool — Write checkbox-updated body**

1. Read the contents of `$tmpfile_read` (path output in Step 1) using Claude Code's Read tool
2. Create the full text with `[ ]` → `[x]` updates based on the read content
3. Write the updated body to `$tmpfile_write` (path output in Step 1) using Claude Code's Write tool

> **CRITICAL**: Write はチェックボックス以外を変えない **全文**。部分出力禁止。

**Step 3: Bash tool call — Validate and apply**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh apply --issue {issue_number} \
  --tmpfile-read "{tmpfile_read}" --tmpfile-write "{tmpfile_write}" \
  --original-length {original_length}
```

Replace `{tmpfile_read}`, `{tmpfile_write}`, `{original_length}` with the values output in Step 1. Validates body length (rejects <50% shrinkage), applies via `--body-file`, and cleans up temp files.

Also synchronize the "Issue checklist" section in the work memory.

#### 5.1.1.2 Work Memory Progress Summary and Changed Files Update

**Execution condition**: commit / push 成功後、`issue-{n}` ブランチ。進捗表・計画 `状態`・変更ファイルを実装後の状態へ更新する。

**Step 1: Determine progress summary statuses**

Analyze the committed changes to determine the status of each progress item:

```bash
# ベースブランチからの変更ファイル一覧を取得
diff_files=$(git diff --name-only origin/{base_branch}...HEAD 2>/dev/null)
```

Claude determines statuses based on `diff_files`:
- **実装**: `✅ 完了` (implementation is complete since we are at the commit stage)
- **テスト**: `✅ 完了` if test files (*.test.*, *.spec.*, test_*, tests/**) exist in `diff_files`, otherwise `⬜ 未着手`
- **ドキュメント**: `✅ 完了` if documentation files (*.md in docs/, README.md, CHANGELOG.md, API.md, etc.) exist in `diff_files`, otherwise `⬜ 未着手`

**Step 2: Generate changed files list**

Format the changed files from `git diff --name-status origin/{base_branch}...HEAD`:

```markdown
- `path/to/file1.md` - 変更
- `path/to/file2.md` - 変更
```

Status mapping: `A` → 追加, `M` → 変更, `D` → 削除, `R` → 名前変更.

**Step 3: Update Issue work memory comment**

Generate a changed files list and write it to a temp file, then invoke the sync script:

```bash
# Step 3a: 変更ファイルリスト生成
changed_files_tmp=$(mktemp)
trap 'rm -f "$changed_files_tmp"' EXIT
git diff --name-status origin/{base_branch}...HEAD 2>/dev/null | while IFS=$'\t' read status file; do
  case "$status" in A) echo "- \`$file\` - 追加";; M) echo "- \`$file\` - 変更";; D) echo "- \`$file\` - 削除";; R*) echo "- \`$file\` - 名前変更";; esac
done > "$changed_files_tmp" || true

# Step 3b: 進捗サマリー + 変更ファイル更新
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-progress \
  --impl-status "{impl_status}" --test-status "{test_status}" --doc-status "{doc_status}" \
  --changed-files-file "$changed_files_tmp" \
  2>/dev/null || true

# Step 3c: 実装計画ステップ ⬜ → ✅ 一括更新
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-plan-status \
  2>/dev/null || true

rm -f "$changed_files_tmp"
```

**Placeholder substitution**: Claude MUST replace `{impl_status}`, `{test_status}`, `{doc_status}` with the actual status strings determined in Step 1 (e.g., `"✅ 完了"`, `"⬜ 未着手"`). All other `{...}` placeholders follow the standard placeholder legend.

**On failure**: The script outputs WARNING on stderr and exits 0 (non-blocking). The progress update is best-effort; the flow state record is the primary state record.

#### 5.1.1.3 Local Work Memory Update

**Execution condition**: `issue-{n}` ブランチ。commit / push 後に `phase=lint` へ。
[Work Memory Format](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands)

```bash
WM_SOURCE="implement" \
  WM_PHASE="lint" \
  WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint を実行" \
  WM_BODY_TEXT="Post-implementation. Proceeding to lint." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

lock 失敗は WARNING（`rite: implement: local work memory lock failed`）して続行。主記録は 4a の flow-state。

#### 5.1.2 Parent Issue Progress Update (only when working on child Issue)

**Execution condition**: `parent_issue_number` が非 0 のときだけ。`flow-state.sh` で読む:

```bash
# `if ! var=$(cmd); then rc=$?` は bash 仕様上 `$?` が常に 0 になるため、capture と exit code を
# 両方取る場合は if/else 形式にする。
if parent_issue_number=$(bash {plugin_root}/hooks/flow-state.sh get --field parent_issue_number --default 0); then
  :
else
  rc=$?
  echo "ERROR: flow-state.sh failed (rc=$rc) reading parent_issue_number for parent progress sync" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=parent_progress_sync; rc=$rc" >&2
  echo "RESUME_HINT: flow-state.sh が異常 exit (rc=$rc) しました。ファイル不在/empty/jq parse 失敗は --default で吸収 (exit 0) されるため、本経路は helper validation 失敗 / --field 引数欠落 / invalid field name 等の caller 側引数異常で発火します。\$PLUGIN_ROOT/hooks/_validate-helpers.sh と state-path-resolve.sh の存在/実行権限を確認し、必要なら /rite:recover で再開、または STATE_ROOT 配下の sessions/ を確認してください。" >&2
  exit 1
fi
# non-numeric injection 経路を遮断
case "$parent_issue_number" in
  ''|*[!0-9]*)
    echo "WARNING: parent_issue_number is not numeric ('$parent_issue_number'), defaulting to 0 (no parent)" >&2
    parent_issue_number=0
    ;;
esac
if [ "$parent_issue_number" -eq 0 ] 2>/dev/null; then
  echo "[CONTEXT] PARENT_ISSUE=none — skip 5.1.2"
else
  echo "[CONTEXT] PARENT_ISSUE=$parent_issue_number — execute 5.1.2"
fi
```

Skip this section when `PARENT_ISSUE=none`.

**5.1.2.1 Tasklist Update**

Update the relevant child Issue's `- [ ]` to `- [x]` in the `## Sub-Issues` section of the parent Issue body.

> **⚠️ 注意**: `--body "$var"` は禁止。`--body-file` + 一時ファイル。
> rationale: references/rationale.md#body-file-not-var

3 段（Bash → Read+Write → Bash）。検証失敗は WARNING して残りを skip（`exit 1` しない）。
rationale: references/rationale.md#parent-step1-no-exit-trap

**Step 1: Bash tool call — Fetch parent Issue body and validate**

```bash
# Create temp files (for reading and writing)
# Do NOT set an EXIT trap here: Step 1 is its own Bash tool call, so an EXIT trap
# would fire when Step 1 exits and delete the temp files before Step 2's Read tool
# can read them. The files are cleaned up explicitly instead — in Step 3 on success,
# and in the failure branch below on a Step 1 failure.
tmpfile_read=$(mktemp)
tmpfile_write=$(mktemp)

gh issue view {parent_issue_number} -R {owner_repo} --json body --jq '.body' > "$tmpfile_read"

# Validate retrieval result
if [ ! -s "$tmpfile_read" ]; then
  echo "WARNING: Parent Issue body の取得に失敗。タスクリスト更新をスキップします" >&2
  rm -f "$tmpfile_read" "$tmpfile_write"
  exit 0  # Skip — do not abort workflow
fi

# Record original length for Step 3 comparison
original_length=$(wc -c < "$tmpfile_read")
echo "original_length=$original_length"

# Output mktemp paths for use in subsequent Read/Write tool calls
echo "tmpfile_read=$tmpfile_read"
echo "tmpfile_write=$tmpfile_write"
```

**Step 2: Read tool + Write tool — Write tasklist-updated body**

1. Read the contents of `$tmpfile_read` (path output by `mktemp` in Step 1) using Claude Code's Read tool
2. In the `## Sub-Issues` section only, update the relevant child Issue's `- [ ]` to `- [x]`. Do not modify other sections
3. Write the updated body to `$tmpfile_write` (another path output by `mktemp` in Step 1) using Claude Code's Write tool

> **CRITICAL**: The Write tool output MUST contain the ENTIRE parent Issue body with only the `## Sub-Issues` section checkbox change. Never output partial content or only the changed lines.

**Step 3: Bash tool call — Validate and apply**

```bash
# Set paths output by mktemp in Step 1 (shell variables do not carry over between Bash tool calls, so directly write the actual paths from Step 1 output)
tmpfile_read="${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"   # ← Replace with the tmpfile_read= value from Step 1 output (literal path)
tmpfile_write="${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"  # ← Replace with the tmpfile_write= value from Step 1 output (literal path)
original_length=XXXXX                # ← Replace with the original_length= value from Step 1 output

# Validate update content before applying
if [ ! -s "$tmpfile_write" ]; then
  echo "WARNING: 更新内容が空。タスクリスト更新をスキップします" >&2
  rm -f "$tmpfile_read" "$tmpfile_write"
  exit 0  # Skip — do not abort workflow
fi

# Body length comparison safety check (reject if updated body is less than 50% of original)
updated_length=$(wc -c < "$tmpfile_write")
if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
  echo "WARNING: 更新後の body が元の50%未満 (${updated_length}/${original_length})。body 消失の可能性があるためスキップします" >&2
  rm -f "$tmpfile_read" "$tmpfile_write"
  exit 0  # Skip — do not abort workflow
fi

gh issue edit {parent_issue_number} -R {owner_repo} --body-file "$tmpfile_write"

# No EXIT trap is set in Step 1 (it would delete these before Step 2), so clean up here
rm -f "$tmpfile_read" "$tmpfile_write"
```

**5.1.2.2 Progress Comment Addition**

Record progress in a comment on the parent Issue (completed child Issues, progress status, suggest next candidates when 1-3 remain).

**5.1.2.3 Remaining Child Issues Check**

Check the state of remaining child Issues with `trackedIssues` and calculate `remaining_count`. Full child Issue completion check is performed in `skills/open/SKILL.md` ステップ 1.2 (parent detection) / `skills/issue-close/SKILL.md` (parent close) (parent close judgement).

**After 5.1.1 commit/push completion:**

1. 親進捗（子 Issue のとき、5.1.2）
2. **work memory 更新**
3. **ローカル work memory 更新**（5.1.1.3）
4. **CRITICAL: flow-state 初期化と lint invoke**（atomic pair — 両方必須）:
rationale: references/rationale.md#lint-atomic-pair

   **4a**: Create state file:

   ```bash
   bash {plugin_root}/hooks/flow-state.sh set \
     --phase "lint" --issue {issue_number} --branch "{branch_name}" \
     --pr 0 \
     --next "After rite:lint returns: [lint:success/skipped]->/rite:open ステップ 6 (PR creation). [lint:error]->fix and re-invoke. [lint:aborted]->/rite:open 完了通知でユーザー判断. Do NOT stop."
   ```

   **4b**: **Immediately** invoke `rite:lint` via Skill tool（停止禁止）

### Mandatory Action After Phase 5.1.1 Completion (Absolute Requirement)

> 停止禁止。
> 1. commit / push 成功を確認
> 2. **Immediately** `rite:lint` を Skill で呼ぶ
> 3. 「次のステップ」案内で止めない

- [ ] Commit complete
- [ ] Push complete
- [ ] **Next action**: Invoke `rite:lint` via Skill tool (**execute now**)
