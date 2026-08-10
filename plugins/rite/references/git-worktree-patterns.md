# Git Worktree Patterns

Operation patterns for `git worktree` to provide independent working directories for parallel agents, solving the shared working directory problem.

## Overview

When `parallel.mode: "worktree"` is set in `rite-config.yml`, each parallel agent receives its own worktree directory instead of sharing the repository's main working directory. This eliminates the critical problem where `git checkout` by one agent interferes with another.

> **Background**: When all agents share the same git working directory, `git checkout` by one agent interferes with another — commits land on wrong branches, and parallel work becomes unreliable. The worktree mode solves this by giving each agent an independent directory.

### Table of Contents

- [Worktree Lifecycle](#worktree-lifecycle) - Creation, usage, and removal flow
- [Worktree Creation](#worktree-creation) - `git worktree add` patterns
- [Agent Execution in Worktree](#agent-execution-in-worktree) - Agent working directory specification via prompt
- [Quality Gate per Worktree](#quality-gate-per-worktree) - Test and lint execution in each worktree
- [Merge Strategy](#merge-strategy) - `--no-ff` merge and integration flow
- [Conflict Resolution Convention](#conflict-resolution-convention) - Multi-agent edit conflict handling
- [Worktree Cleanup](#worktree-cleanup) - Removal and safety mechanisms
- [Safety Mechanisms](#safety-mechanisms) - Preventing forgotten worktree removal
- [Configuration Reference](#configuration-reference) - rite-config.yml settings
- [SSH host alias 経由の git push/fetch が sandbox のネットワーク許可リストでブロックされる](#ssh-host-alias-経由の-git-pushfetch-が-sandbox-のネットワーク許可リストでブロックされる) - Bad Gateway failures when `origin` uses an SSH host alias remote
- [worktree cwd から main checkout 配下への書き込みが sandbox の write 許可リストでブロックされる](#worktree-cwd-から-main-checkout-配下への書き込みが-sandbox-の-write-許可リストでブロックされる) - State writes rejected as read-only filesystem after `EnterWorktree`
- [sandbox write-allowlist 設定の自動化（Decision Log）](#sandbox-write-allowlist-設定の自動化decision-log) - Why setup Phase 4.8 auto-writes `sandbox.filesystem.allowWrite` instead of guidance-only
- [sandbox の write-block マスクマウントが git status に幽霊 untracked エントリを生む](#sandbox-の-write-block-マスクマウントが-git-status-に幽霊-untracked-エントリを生む) - Ghost `??` entries from sandbox `/dev/null` bind mounts, not real files

---

## Worktree Lifecycle

```
1. Orchestrator creates branch for Issue
2. For each parallel task:
   a. git worktree add <path> -b <task-branch> <base-branch>
   b. Spawn agent with prompt specifying worktree path as working directory
   c. Agent works (Read/Edit/Write only, NO git operations)
   d. Agent reports completion
3. Orchestrator validates each worktree:
   a. Run quality gate (test + lint) in each worktree
   b. Exclude failed worktrees from merge
4. Orchestrator merges each worktree branch:
   a. git merge --no-ff <task-branch>
   b. Handle conflicts (first-merge-wins convention)
5. Cleanup:
   a. git worktree remove <path>
   b. git branch -d <task-branch>
```

**Critical constraint**: Only the orchestrator performs git operations. Agents spawned via Task tool use only Read/Edit/Write/Glob/Grep/Bash (non-git) tools within their assigned worktree directory.

---

## Worktree Creation

Create a worktree for each independent parallel task identified in the implementation plan (Phase 5.1.0.1).

### Naming Convention

```
{worktree_base}/{issue_number}/{task_id}
```

- `{worktree_base}`: From `parallel.worktree_base` in rite-config.yml (default: `.worktrees`)
- `{issue_number}`: Current Issue number
- `{task_id}`: Task identifier from the implementation plan (e.g., `task-1`, `task-2`)

### Creation Command

```bash
# Ensure worktree base directory exists
mkdir -p {worktree_base}/{issue_number}

# Create worktree with a task-specific branch
git worktree add {worktree_base}/{issue_number}/{task_id} -b {issue_branch}/{task_id} {issue_branch}
```

Where `{issue_branch}` is the Issue's feature branch (e.g., `feat/issue-123-feature-name`).

### Example

```bash
mkdir -p .worktrees/651
git worktree add .worktrees/651/task-1 -b feat/issue-651-git-worktree-integration/task-1 feat/issue-651-git-worktree-integration
git worktree add .worktrees/651/task-2 -b feat/issue-651-git-worktree-integration/task-2 feat/issue-651-git-worktree-integration
```

---

## Agent Execution in Worktree

Agents are spawned using the Task tool with the worktree path specified in the prompt. The Task tool does not have a `cwd` parameter — instead, the prompt explicitly instructs the agent to use absolute paths within the worktree directory.

### Task Tool Invocation

```
Task tool parameters:
  subagent_type: "general-purpose"
  prompt: "{task_description}. Work ONLY in the directory {worktree_path}. Use ABSOLUTE paths for all file operations (e.g., {worktree_path}/src/file.ts). Do NOT run any git commands (checkout, commit, push, branch, merge, stash). You may use Read, Edit, Write, Glob, Grep, and Bash (for non-git commands like test/lint) tools."
```

**Enforcement rules for agents in worktree mode:**

| Allowed | Prohibited |
|---------|------------|
| Read (files in worktree) | git checkout |
| Edit (files in worktree) | git commit |
| Write (files in worktree) | git push |
| Glob (files in worktree) | git branch |
| Grep (files in worktree) | git merge |
| Bash (non-git commands: test, lint) | git stash |

### Path Scoping

Agents must only modify files within their assigned worktree path. The prompt should explicitly state the absolute worktree path and instruct the agent to use it for all file operations.

---

## Quality Gate per Worktree

Before merging, run quality checks in each worktree to ensure independent validation.

### Execution Flow

```bash
# For each worktree that completed successfully:
cd {worktree_path}

# Run tests (if configured)
if [ -n "{test_command}" ]; then
  {test_command}
  test_exit=$?
fi

# Run lint (if configured)
if [ -n "{lint_command}" ]; then
  {lint_command}
  lint_exit=$?
fi
```

### Result Handling

| Test Result | Lint Result | Action |
|-------------|-------------|--------|
| Pass (or N/A) | Pass (or N/A) | Include in merge |
| Fail | Any | Exclude from merge, report failure |
| Any | Fail | Exclude from merge, report failure |

**On partial failure**: Report which worktrees passed and which failed. Merge only passing worktrees. Failed tasks fall back to sequential implementation after merge.

---

## Merge Strategy

All worktree branches are merged back to the Issue branch using `--no-ff` (no fast-forward) to preserve merge commit history.

### Merge Flow

```bash
# Switch to the Issue's feature branch
git checkout {issue_branch}

# Merge each task branch (in dependency order if applicable)
git merge --no-ff {issue_branch}/task-1 -m "chore(parallel): integrate task-1 ({task_description})"
git merge --no-ff {issue_branch}/task-2 -m "chore(parallel): integrate task-2 ({task_description})"
```

### Why `--no-ff`

- Preserves the fact that work was done in parallel
- Creates a merge commit that serves as a documentation point
- Makes it easy to revert an entire parallel task if needed
- `git log --first-parent` shows clean integration history

---

## Conflict Resolution Convention

When multiple agents edit the same file (which should be avoided by proper task decomposition, but may happen):

### First-Merge-Wins Rule

1. The first worktree branch merged into the Issue branch takes precedence
2. Subsequent merges that conflict must rebase onto the updated Issue branch
3. After rebase, re-run quality gate before attempting merge again

### Resolution Flow

```bash
# If merge conflicts occur on task-2 after task-1 was merged:
git merge --abort

# Rebase task-2 onto updated Issue branch
# Note: Cannot use `git checkout` for a branch checked out in a worktree.
# Use `git -C` to run rebase within the worktree directory instead.
git -C {worktree_path_task_2} rebase {issue_branch}

# Resolve conflicts manually (orchestrator responsibility)
# ... edit conflicting files in {worktree_path_task_2} ...
git -C {worktree_path_task_2} add {resolved_files}
git -C {worktree_path_task_2} rebase --continue

# Re-run quality gate in the rebased worktree
cd {worktree_path_task_2}
{test_command}
{lint_command}

# Retry merge from the Issue branch
git checkout {issue_branch}
git merge --no-ff {issue_branch}/task-2
```

### Prevention

To minimize conflicts, the implementation plan should assign independent files to each parallel task (Phase 5.1.0.1 independence criteria). When file overlap is unavoidable, tasks should be executed sequentially instead of in parallel.

---

## Worktree Cleanup

After all merges are complete, remove worktrees and their associated branches.

### Cleanup Commands

```bash
# Remove each worktree
git worktree remove {worktree_base}/{issue_number}/task-1
git worktree remove {worktree_base}/{issue_number}/task-2

# Delete task branches (merged, no longer needed)
git branch -d {issue_branch}/task-1
git branch -d {issue_branch}/task-2

# Remove the Issue-specific worktree directory
rmdir {worktree_base}/{issue_number} 2>/dev/null || true

# Prune worktree metadata
git worktree prune
```

### Force Removal

If a worktree is in a dirty state (uncommitted changes from a failed agent):

```bash
# Force remove (discards uncommitted changes in the worktree)
git worktree remove --force {worktree_base}/{issue_number}/task-N
```

---

## Safety Mechanisms

Prevent worktree accumulation from forgotten cleanups.

### 1. Post-Merge Automatic Cleanup

After all merge operations complete in Phase 5.1.0.3 (Result Integration), the orchestrator **must** execute the cleanup commands above. This is enforced by including cleanup as the final step of the parallel implementation flow.

### 2. Stale Worktree Detection

At the start of worktree creation (Phase 5.1.0.2), check for existing worktrees from previous runs:

```bash
# List existing worktrees
git worktree list --porcelain

# Check for stale worktrees under the worktree base
ls -d {worktree_base}/*/* 2>/dev/null
```

If stale worktrees are found, display a warning and offer cleanup:

```
⚠️ 既存の worktree が検出されました:
{stale_worktree_paths}

オプション:
- クリーンアップして続行（推奨）: 古い worktree を削除して新規作成
- そのまま続行: 既存の worktree を無視して新規作成
- 中断: 手動で状況を確認
```

### 3. `.gitignore` Entry

The worktree base directory should be added to `.gitignore` to prevent accidental commits:

```
# Git worktrees for parallel agents
.worktrees/
```

### 4. Session End Cleanup Hook

The `pre-compact.sh` hook can check for leftover worktrees and include a warning in the compaction summary:

```bash
# In pre-compact.sh (optional enhancement)
worktree_count=$(git worktree list | wc -l)
if [ "$worktree_count" -gt 1 ]; then
  echo "WARNING: $((worktree_count - 1)) worktree(s) still exist" >&2
fi
```

---

## Configuration Reference

Settings in `rite-config.yml` that control worktree behavior:

```yaml
parallel:
  enabled: true          # Enable parallel implementation (default: true)
  max_agents: 3          # Maximum concurrent agents (default: 3)
  mode: "shared"         # "shared" (default) or "worktree"
  worktree_base: ".worktrees"  # Base directory for worktrees (default: ".worktrees")
```

| Setting | Values | Description |
|---------|--------|-------------|
| `parallel.mode` | `"shared"` (default) | Agents share the main working directory (current behavior) |
| | `"worktree"` | Each agent gets an independent worktree directory |
| `parallel.worktree_base` | Path string | Base directory for worktree creation (default: `.worktrees`) |

**When `mode: "shared"`**: The existing parallel implementation behavior (Phase 5.1.0.2) is used. No worktree operations are performed.

**When `mode: "worktree"`**: The orchestrator creates worktrees per this document's patterns. Agents are constrained to their worktree directories.

---

## Multi-Session Patterns

These patterns apply to the **session worktree** layer governed by `multi_session.enabled`
(default `true`; see [docs/designs/multi-session-worktree.md](../../../docs/designs/multi-session-worktree.md)).
This is a **separate axis** from the `parallel.mode: "worktree"` patterns above:
`parallel` is per-Issue sub-agent fan-out within one session; `multi_session` is
session-wide lifecycle isolation. `/rite:open` creates a session worktree and
`EnterWorktree`-s into it; `/rite:cleanup` exits and removes it; orphans are
reaped lazily by `pr-cycle-cleanup.sh` Step 5.

### Worktree namespaces (4 kinds — do not cross-contaminate)

| Namespace | Purpose | Lifecycle |
|---|---|---|
| `.rite/worktrees/issue-{N}` | **Session worktree** (multi_session) | `open` creates → `cleanup` removes (orphans reaped via Step 5) |
| `.worktrees/{issue}/{task}` | parallel implementation sub-agent worktree | per-batch create/remove |
| `pr-{N}-cycle{X}` etc. | reviewer transient worktree | idempotently swept by `pr-cycle-cleanup.sh` |
| `.rite/wiki-worktree` | persistent wiki-branch worktree | manual removal only (reap-excluded) |

The session-worktree reap (`pr-cycle-cleanup.sh` Step 5) matches **only** the strict
`^issue-[0-9]+$` directory name under `multi_session.worktree_base`, so it never
touches the other three namespaces.

### Concurrent `git fetch` — ref-lock retry (3 attempts)

`refs` / `objects` / `config` are shared across all worktrees, so two sessions
running `git fetch` at the same time can transiently fail on a ref lock. Retry up
to 3 times:

```bash
n=0; until git fetch origin "$base" 2>/dev/null; do n=$((n+1)); [ "$n" -ge 3 ] && break; sleep 1; done
```

### `EnterWorktree` fails with "not in a git repository" (harness git mis-detection)

`/rite:open` (Step 2.3-W) and `/rite:recover` (re-entry) enter the session
worktree via the `EnterWorktree` tool. If the harness mis-detected the launch
directory as non-git **at session startup** (`Is a git repository: false` in the
launch context even though `.git` exists and `git -C {wt_path} rev-parse` succeeds),
`EnterWorktree` rejects entry with
`Error: ... the current directory is not in a git repository.`

This is a **harness-side** startup judgement that rite cannot fix from a plugin.
The remedy is to **restart Claude Code from the repository ROOT** and re-run the
command:

- The session worktree created by `git worktree add` is **preserved** — the failure
  does not destroy it.
- On re-run, `open` Step 2.2-W classifies it as `WT_CASE=reuse` (and the
  `ensure_session_worktree` helper used by `/rite:recover` / `review` / `iterate` /
  `fix` as `WT_ENSURE=reenter`), so the workflow continues on the existing worktree
  without rebuilding it.

rite **never** silently falls back to `git switch -c` (which would discard worktree
isolation) or to a Bash-persisted-cwd path (which would leave the harness cwd on the
main checkout and risk relative-path edits hitting the main tree); the workflow
surfaces the diagnosis and the restart guidance instead. Failures from other causes
(e.g. the worktree path vanished) follow the normal `ensure_session_worktree` rebuild
path (`WT_ENSURE=reconstructed`, #1676), not the restart guidance.

### Branch-creation worktree invariant (marker 再確定・silent fallback 排除)

In `multi_session` mode the feature branch **must** be created on the session worktree
(`{worktree_base}/issue-{N}`), regardless of the flow entry path (fresh / `/rite:recover` /
post-compaction mid-flow entry). The earlier failure mode (#1595) was that `/rite:open`
gated the worktree-vs-main-tree branch decision **only on the in-context
`[CONTEXT] MULTI_SESSION_ENABLED=` marker** emitted at Step 1.4. When that marker was lost
from context (resume / compaction / mid-flow re-entry), routing fell back to the legacy
`git switch -c` path and the branch was created on the **main checkout**, leaving
`{worktree_base}/` empty and the flow-state `worktree` field unset.

The invariant is enforced by three complementary gates, **none of which trusts remembered
context**:

- **Re-derive at branch time, not at Step 1.4** (`open` Step 2.1-G): immediately before the
  branch-creation side effect, `multi_session` is re-parsed from `rite-config.yml` with the
  same parser as Step 1.4, emitting a fresh `MULTI_SESSION_ENABLED=...; SOURCE=branch-gate`
  marker. There is **no "marker missing → legacy" branch** — the marker is regenerated every
  time, so it can never be absent at routing.
- **Legacy path is `false`-only** (`open` Step 2.3): the `git switch -c` block runs only
  when the branch-time re-derivation yielded `false`. Reaching it with `true` is prohibited.
- **Post-entry toplevel check** (`open` Step 2.3-W): after `EnterWorktree`,
  `git rev-parse --show-toplevel` must equal the worktree path; a mismatch
  (`WORKTREE_INVARIANT=violated`) stops the flow instead of silently implementing on the main
  tree. The data layer mirrors this — `flow-state.sh set --require-worktree` emits
  `WORKTREE_INVARIANT=missing` (loud WARNING, non-blocking write) when a branch/pr-phase set
  carries no worktree path.

This complements the `EnterWorktree`-failure convention above (which forbids silent fallback
on *entry*) by forbidding it at *branch creation* too: the worktree is a **hard invariant**,
not best-effort.

### main-checkout-不可侵 (inviolability) convention

In `multi_session` mode rite **never switches the main checkout's current branch**
(`git switch {base}` from a session is impossible anyway — the main checkout holds it).
Consequences enforced across the workflow:

- New session branches are created with their base as **`origin/{base}` directly**
  (`git worktree add --no-track -b {branch} {path} origin/{base}`), not via a local
  `{base}` that another worktree may have checked out. `--no-track` avoids
  `branch.autoSetupMerge` writing upstream tracking to `.git/config`, which sandbox
  environments reject .
- A branch is deleted **only after** its worktree is removed (a branch checked out
  in a worktree cannot be deleted or fetch-updated).
- `cleanup`'s base update runs **only when the main checkout is on `{base}`**; on any
  other branch it WARNINGs and skips (it must not yank the main checkout off a
  human's working branch). Moving the main checkout's branch is a **human-only** action.

### Issue claim + lazy reap (lifecycle bookends)

Two helper-driven patterns bracket the session-worktree lifecycle:

- **Issue claim** (`hooks/issue-claim.sh`, always-on regardless of the flag): `/rite:open`
  Step 1.6 claims the Issue **before** creating the branch/worktree (fail-fast against
  double-starting), and `/rite:cleanup` releases it. Claims live under the
  gitignored `.rite/state/issue-claims/`; liveness reuses the flow-state heartbeat
  (`active=true` ∧ `updated_at` within 2h) rather than a new heartbeat file. A live
  `other` claim is surfaced via AskUserQuestion — never an unattended steal.
- **Lazy reap** (`pr-cycle-cleanup.sh` Step 5): normal cleanup removes the worktree
  immediately; reap only collects **abnormally-orphaned** worktrees, and only when a
  self-exclusion guard plus all 3 gates pass — the guard (Gate 0) never reaps the
  worktree the cleanup is itself running in (invocation cwd or `RITE_WORKTREE` matching
  or nested under the candidate), so a long-lived session cannot delete its own active
  worktree mid-flight; then strict `^issue-[0-9]+$` name under
  `worktree_base`, claim not live (or absent + mtime > 24h — except a worktree whose
  checked-out branch is **reap-manifest-recorded**, i.e. cleanup already verified the
  PR merged and deferred the removal: that explicit "reap me" record bypasses the age
  guard, since the harness refreshes the worktree root mtime every session and the
  guard would otherwise leak the deferred tree forever, the governing rationale), and a clean
  `git status --porcelain` (a dirty worktree is never auto-reaped — the sole exception is
  an admin-HEAD-missing, git-unrecognized **corpse** whose status is structurally
  undeterminable: it bypasses the status gate and is reaped, working tree + admin dir,
  behind the same claim + 24h age guards, the governing rationale). Once the worktree is gone, its
  branch is recovered rather than left untouched: `git branch -d` (safe-delete) runs
  first so an unmerged branch is preserved; if that's refused but the reap manifest
  confirms the PR was merged, `git branch -D` force-deletes it. On any successful
  recovery (`-d` and `-D` alike) the branch's manifest entry is consumed in the same
  run (a lingering entry is no longer inert once it also keys
  the age-guard bypass, the governing rationale); an unmerged,
  manifest-unrecorded branch is kept with a WARNING . A corpse's HEAD can't
  be read, so branch recovery is structurally skipped for it.

### SSH host alias 経由の `git push`/`fetch` が sandbox のネットワーク許可リストでブロックされる

`origin` remote が `~/.ssh/config` の `Host` alias（例: `git@github.com-work:owner/repo.git`）
経由の環境で、sandbox が有効なとき `git push` / `git fetch` の SSH 接続がブロックされることがある。

**症状**: `socat[N] E CONNECT github.com-work:22: Bad Gateway` のようなエラーで SSH 接続が拒否
され、`git push origin {branch}` / `git fetch origin {base}` が失敗する。`gh` CLI（HTTPS 経由で
`api.github.com` を使う）は影響を受けないため、`gh issue view` 等の issue 操作は成功するのに
push/fetch だけ失敗する非対称な挙動になる。

**原因**: 以下の 3 段の因果連鎖で発生する:

1. sandbox の credentials 保護設定（`~/.claude/settings.json` の `sandbox.credentials.files:
   [{"path": "~/.ssh", "mode": "deny"}]`。公式のデフォルトは `~/.ssh` を読み取り許可しており、
   この deny はユーザー側の hardening 設定由来）により、sandbox 内から `~/.ssh` が不可視になる
2. ssh が `~/.ssh/config` を読めないため、`Host github.com-work` → `HostName github.com` の
   **alias 解決自体が起きない**（sandbox 内の `ssh -G github.com-work` は `hostname
   github.com-work` を返す。sandbox 外では `github.com` に解決される）
3. その結果 CONNECT が alias 名のまま proxy に渡り、sandbox のネットワーク許可リスト（ドメイン名
   ベース。`github.com` / `*.github.com` 等）のいずれのパターンにも一致せず Bad Gateway になる

**効かない対処**: `network.allowedDomains` へ alias 名（例: `github.com-work`）を追加しても解消
しない — alias 名は DNS 解決できず、そもそも `~/.ssh` の秘密鍵が読めないため認証も成立しない
（原因の 1, 2 段目が未解消のまま）。

**現状の回避策**: 当該 `git push` / `git fetch` コマンドのみ `dangerouslyDisableSandbox: true`
で再実行してよい（ユーザー確認は不要 — 既知の環境制約、the governing rationale）。sandbox のネットワーク許可
リスト・credentials 保護設定はプラグイン外の環境設定のため、rite 側の設定変更では解消できない。
SSH alias remote を使う任意のプロジェクトで同様に起こりうる。

**本回避策が使えない経路（reviewer subagent）**: Task で spawn した reviewer subagent（`/rite:pr-review`
が起動する各 `*-reviewer` エージェント）の Bash 呼び出しには、呼び出し元から `dangerouslyDisableSandbox`
フラグを渡す経路が無い。そのため reviewer subagent が SSH host alias remote に対して `git fetch` 等を
実行し本問題に遭遇した場合、この回避策では解消できない（reviewer は元々 read-only 契約で `git push` を
実行しないため実害は限定的だが、bare `git fetch` で同じ Bad Gateway に当たりうる）。回避策はメインエー
ジェントが直接実行する `git push`/`fetch`（例: `open`/`fix` の push、Wiki ingest commit の push）にのみ
適用できる。

**恒久策**: `sandbox.excludedCommands`（公式サポート設定。指定したコマンドを sandbox 外で通常の
permission フローに乗せる）は一見この問題の恒久策に見えるが、**Linux/WSL2 環境では現状機能しない**:

```json
{
  "sandbox": {
    "excludedCommands": ["git push *", "git fetch *", "git pull *"]
  }
}
```

上流の複数の実測報告によれば、Linux/WSL2 環境では `excludedCommands` はファイルシステムの
sandbox（bubblewrap）のみをバイパスし、ネットワークの sandbox はグローバルに適用され続ける。SSH
（port 22）はブロックされたままで、本問題は解消しない（[claude-code#30619](https://github.com/anthropics/claude-code/issues/30619)、
[#29274](https://github.com/anthropics/claude-code/issues/29274)、[#53012](https://github.com/anthropics/claude-code/issues/53012)。
いずれも `not planned` でクローズ済み、2026-04 リリース時点でも未修正）。設定自体は無害なので試して
もよいが、確実に機能するのは `dangerouslyDisableSandbox: true` での再実行のみである。

### worktree cwd から main checkout 配下への書き込みが sandbox の write 許可リストでブロックされる

sandbox が有効な環境で `EnterWorktree` によりセッション worktree（`.rite/worktrees/issue-{N}`）へ
cwd が移った後、main checkout 配下（`.rite/sessions/` の flow-state、`.rite/state/` の run-queue /
issue claim 等）を更新する hook / script が失敗することがある。

**症状**: `mktemp` / `mv` / リダイレクト書き込みが「読み込み専用ファイルシステムです」（Read-only
file system）で失敗する。`flow-state.sh set` / `issue-claim.sh` / `issue-comment-wm-sync.sh` /
run-queue の `jq` 書込等、state root（main checkout）配下へ書き込むあらゆる呼び出しが該当する。
worktree 内への書き込みは成功するため、worktree 入場後に state 書込だけが失敗する非対称な挙動に
なり、sandbox 起因と気付きにくい。

**原因**: sandbox の write 許可リストはセッションのプロジェクトディレクトリを相対パス `.`（cwd
依存）で許可する構成が既定のため、`EnterWorktree` で cwd がセッション worktree に切り替わると
`.` が worktree を指し、main checkout root が許可リストから外れる。rite の state root は
`state-path-resolve.sh` により main checkout へ統一されている（linked worktree 間の state 共有・
flock 排他の前提）ため、worktree cwd からの state 書込は構造的にすべて拒否される。

**対処**: 恒久対処は、sandbox の write 許可リストへ main checkout root の**絶対パス**を追加する
こと（`/sandbox` コマンド / settings の sandbox 設定。プラグイン外の環境設定のため rite 側の
変更では解消できない）。追加できない場合は、拒否された当該 hook / script 呼び出しのみ
`dangerouslyDisableSandbox: true` で再実行してよい（ユーザー確認は不要 — 既知の環境制約、
the governing rationale）。worktree 内のファイルだけを扱うコマンドは影響を受けないため、sandbox 有効のまま
実行する。

### sandbox write-allowlist 設定の自動化（Decision Log）

上記の恒久対処（write 許可リストへ main checkout root を追加）は、当初 `/rite:setup` Phase 4.8 で
**案内表示のみ**（設定ファイルへの自動書き込みは MUST NOT）としていた。しかし実運用データから、
この手動設定への依存自体が UX 問題であることが判明したため、この仕様により自動化へ方針転換した。

**根拠データ**: 2026-07-20 の 1 セッションで、許可リスト未設定に起因する state-write バイパス
（`dangerouslyDisableSandbox: true` の都度実行）が 30〜45 回発生（セッション 73fa87c6=45 回、
5ea9d2e1=41 回）。同日、ユーザーが手動で許可リストへ main checkout root を追加した結果、以降の
セッションでは state-write バイパスが 0 回に収束した。恒久対処自体は機能するが、「ユーザーが毎回
手動で設定する」という導線が UX 上のボトルネックだった。

**比較検討した 3 方向**:

| 方向 | 内容 | 採否 |
|------|------|------|
| (a) 案内強化のみ | Phase 4.8 のメッセージに、なぜ必要か（state 共有 + flock 排他設計）の説明とコピペ用 JSON snippet を追加する。設定ファイルへの自動書き込みは行わない | 不採用（単独では） |
| (b) state root を worktree ローカルへ移す設計変更 | `state-path-resolve.sh` の解決先を main checkout でなく worktree ローカルにし、変更を同期する | **不採用** |
| (c) 許可リスト設定の自動化 | `/rite:setup` Phase 4.8 が `.claude/settings.local.json` の `sandbox.filesystem.allowWrite` へ main checkout root を idempotent に自動追記する | **採用** |

- **(b) を不採用とした理由**: state root を main checkout に統一しているのは、`state-path-resolve.sh` の
  flock 排他制御（linked worktree 間で同一ロックファイルを共有し、per-inode の排他を成立させるため）が
  前提になっている。state root を worktree ローカルに分散させると、この排他設計そのものを作り直す必要が
  あり、本 Issue の Non-goal「flock 排他設計の無条件廃止」と衝突する。M 複雑度の見積りを超える高い
  blast radius を持つため見送った。
- **(c) を採用した理由**: `sandbox.filesystem.allowWrite` は Claude Code 公式ドキュメント
  （[Configure the sandboxed Bash tool](https://code.claude.com/docs/en/sandboxing.md)）で
  「These paths are enforced at the OS level」と明記されており、`/sandbox` コマンドでのユーザー
  操作を経ずに設定ファイルへの記述だけで有効になる。main checkout root は開発者ごとに異なる絶対パス
  のため、コミットされる `.claude/settings.json` ではなく `.claude/settings.local.json`
  （ユーザーローカル設定として書き込む意図のファイル）へ書き込む。この判断は、従来の「設定ファイルへの
  自動書き込みは MUST NOT」という Phase 4.8 の方針を **`.claude/settings.local.json` に限定して**
  撤回するものであり、コミットされる共有設定（`.claude/settings.json`）を自動変更する話ではない。
  ただし「ユーザーローカル」という性質は当該リポジトリの `.gitignore` に明示エントリがあって初めて
  保証される（開発者個人のグローバル gitignore への依存は他の contributor 環境では効かず、機械固有の
  絶対パスがコミットされる経路が残る）。Phase 4.8 は書込前に対象リポジトリの `.gitignore` へ
  `.claude/settings.local.json` エントリを保証してから追記する（詳細は
  [Phase 4.8 本体](../skills/setup/SKILL.md#phase-48-sandbox-write-allowlist-自動設定multi_session-有効時1896--1942)）。
  書き込みが sandbox の write 制限で失敗しても bash 呼び出し自体は正常終了しうる（`else` 節に落ちて
  marker のみ `failed` になる）ため、再試行の要否は「コマンド自体の失敗」ではなく marker の値で判定する
  — `failed` であれば理由を問わず `dangerouslyDisableSandbox: true` で一度だけ再試行し、それでも
  `failed` の場合のみ非 blocking で従来の手動案内メッセージへフォールバックする。
- **反映タイミングの不確実性**: 設定変更が同一セッション内で即座に反映されるか、Claude Code の
  再起動が必要かは公式ドキュメントで明言されていない。安全側に倒し、案内メッセージでは「次回セッション
  から有効になる場合がある」旨を明記する。

### sandbox の write-block マスクマウントが `git status` に幽霊 untracked エントリを生む

sandbox が有効な環境（worktree の内外を問わない）では、`git status` にリポジトリ直下の `.bashrc` /
`.gitconfig` / `.claude/settings.json` / `.mcp.json` 等が `??`（未追跡）として列挙されることがある。
これは実在の未追跡ファイルではない。

**症状**:

```
$ git status --short
?? .bashrc
?? .gitconfig
?? .claude/settings.json
?? .mcp.json
```

```
$ ls -la .bashrc
crw-rw-rw- 1 nobody nogroup 1, 3  7月 20 09:39 .bashrc
```

`ls -la` の1桁目が `c`（character device）になっている点に注目する。通常ファイルであれば `-` になる。

**原因**: Bash tool の sandbox write-block 機構は、書き込みを拒否したい保護対象パス（シェル
dotfile、`.claude/settings.json`、`.mcp.json` 等）へ `/dev/null` のキャラクタデバイスを bind mount
する。結果としてそのパス上には実ファイルではなくデバイスノードが存在する状態になり、`git status` は
これを「git 管理外の新規パス」として `??` に分類する。しかし対象は実ファイルの内容変化ではなくデバイス
ノードであり、作業ツリーの実体は変化していない（sandbox 外で同じ `git status` を実行すると clean に
なる）。

**列挙は例示であり網羅ではない**: 上記のパスは観測された一例に過ぎず、どのパスが保護対象になるかは
sandbox 設定に依存して変わる。ファイル名の allowlist で判定してはならない。判定は常に下記の機構ベース
（`test -c`）で行う。

**実在確認手順**:

- 当該パスがキャラクタデバイスかどうかを判定する: `test -c <path> && echo "ghost mount" || echo "real file"`
- または sandbox の外側（通常のシェル）で同じ `git status` を実行し、差分が実在するか確認する

**canonical な判定経路**: dirty 判定を行う hook / script は `hooks/scripts/lib/git-status-filtered.sh`
を経由する。この helper は `git status --porcelain -z` の出力のうち `??` エントリで `test -c` により
キャラクタデバイスと判定されたものだけを機械的に除外し、それ以外の全ステータス（staged / unstaged /
unmerged / renamed / copied）はそのまま通す。ファイル名 allowlist を持たない機構ベース設計のため、
sandbox 設定が変わっても追随できる。

**実行エージェントへの指示**: この現象で列挙される `??` エントリを「未追跡ファイルの異常」「リポジトリ
汚染」として報告しない。削除・`git add`・コミットを試みない。dirty 判定が必要な箇所では `git status`
を直接パースせず `git-status-filtered.sh` を使う。

**関連 Issue**: #1936（`git-status-filtered.sh` 導入元）/ #1944（drift-hash 経路の sandbox 内外
コンテキスト混在による誤警報の残件、本節の対象外）

> **Canonical spec**: This file documents the operational *patterns*; the canonical
> runtime specification for the session-worktree layer (lifecycle, claim, reap,
> shared-state-root resolution, crash recovery) lives in
> [`docs/SPEC.md` → Multi-Session State Management → Worktree Mode](../../../docs/SPEC.md#worktree-mode-session-worktree-isolation),
> with the full Decision Log in [`docs/designs/multi-session-worktree.md`](../../../docs/designs/multi-session-worktree.md).
