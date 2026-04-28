# Work Memory Format Reference

Format definition for work memory. Local file (`.rite-work-memory/issue-{n}.md`) is the Source of Truth (SoT). Issue comment is a backup replica.

## Basic Structure

```markdown
## 📜 rite 作業メモリ

### セッション情報
- **開始**: {timestamp}
- **ブランチ**: {branch_name}
- **最終更新**: {timestamp}
- **コマンド**: {command_name}
- **フェーズ**: {phase}
- **フェーズ詳細**: {phase_detail}

### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ⬜ 未着手 | - |
| テスト | ⬜ 未着手 | - |
| ドキュメント | ⬜ 未着手 | - |

### 要確認事項
<!-- 作業中に発生した確認事項を蓄積。セッション終了時にまとめて確認 -->
_確認事項はありません_

### 変更ファイル
<!-- 自動更新 -->
_まだ変更はありません_

### 決定事項・メモ
<!-- 重要な判断や発見 -->

### 計画逸脱ログ
<!-- 実装中に計画から逸脱した場合に記録 -->
_計画逸脱はありません_

### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->
_ボトルネック検出はありません_

### レビュー対応履歴
- **現在のループ回数**: {n}

### 次のステップ
- **コマンド**: {next_command}
- **状態**: {next_status}
- **備考**: {next_note}
```

## Placeholder Definitions

| Placeholder | Format | Example |
|-------------|--------|---------|
| `{timestamp}` | ISO 8601 `YYYY-MM-DDTHH:MM:SS+HH:MM` | `2026-01-29T14:30:00+09:00` |
| `{branch_name}` | `{type}/issue-{number}-{slug}` | `feat/issue-13-new-feature` |
| `{command_name}` | Command path | `/rite:issue:start`, `/rite:pr:create` |
| `{phase}` | Phase ID (see [phase-mapping.md](./phase-mapping.md)) | `phase5_implementation` |
| `{phase_detail}` | Detail state | `実装作業中`, `PR 作成完了` |
| `{next_command}` | Next command | `/rite:pr:create`, `/rite:pr:review #42` |
| `{next_status}` | `待機中` / `実行中` / `完了` | `待機中` |
| `{next_note}` | Supplementary info | `lint 完了、PR 作成準備完了` |

## Progress Summary Status

| Status | Notation |
|--------|----------|
| Not started | ⬜ 未着手 |
| In progress | 🔄 進行中 |
| Completed | ✅ 完了 |

## Confirmation Items

Accumulates pending questions (design decisions, spec checks, review requests) during work. Confirmation requested collectively at session end per SKILL.md rules.

Example:
```markdown
### 要確認事項
1. [ ] API endpoint naming convention
2. [x] Auth method (decided: JWT)
```

## Next Steps Section

Enables flow continuation after `/clear`.

Format:
```markdown
### 次のステップ
- **コマンド**: `/rite:pr:create`
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
```

Fields: `コマンド` (next command), `状態` (待機中/実行中/完了), `備考` (notes)

### Recording Examples

| Completed | Next Command | Note |
|-----------|--------------|------|
| `/rite:lint` (ok) | `/rite:pr:create` | `lint 完了、PR 作成準備完了` |
| `/rite:lint` (error) | `/rite:lint` | `lint エラー修正後、再度 lint を実行` |
| `/rite:pr:create` | `/rite:pr:review #123` | `PR 作成完了、レビュー準備完了` |
| `/rite:pr:review` (ok) | `/rite:pr:ready` | `指摘なし、Ready for review に変更可能` |
| `/rite:pr:review` (issues) | `/rite:pr:fix` | `要修正の指摘あり、修正が必要` |

**PR number**: Replaced with actual number after `/rite:pr:create`. If retrieval fails, record `/rite:pr:review` without number (fallback: auto-search).

**Design**: Each command reads from/writes to work memory. `/clear` can be executed anytime; `/rite:resume` recovers state.

## Plan Deviation Log Section

Records deviations from the implementation plan during Phase 5.1 when using the adaptive implementation loop (dependency graph format). Added by the 5.1.0.5 Adaptive Re-evaluation Checkpoint.

```markdown
### 計画逸脱ログ
<!-- 実装中に計画から逸脱した場合に記録 -->

| # | ステップ | 逸脱種別 | 理由 | 影響範囲 | 代替ステップ |
|---|---------|---------|------|---------|------------|
| 1 | S3 | 変更 | API の仕様が想定と異なった | S3, S4 | S3' (新しいアプローチ) |
| 2 | S5 | スキップ | S2 の実装で不要になった | なし | — |
| 3 | — | 追加 | テスト中に新たな問題を発見 | S4 以降 | S6 (新規ステップ) |
```

**Deviation types**:

| 逸脱種別 | Description |
|---------|-------------|
| 変更 | Planned step modified (approach/scope changed) |
| スキップ | Planned step no longer needed |
| 追加 | New step discovered during implementation |

**Fields**:
- `ステップ`: Step ID from the dependency graph (`—` for newly added steps)
- `逸脱種別`: One of 変更/スキップ/追加
- `理由`: Why the deviation occurred (concise, 1-2 sentences)
- `影響範囲`: Which other steps are affected
- `代替ステップ`: Replacement step if applicable (`—` for skips)

**When no deviations**: Display `_計画逸脱はありません_`

## Bottleneck Detection Log Section

Records bottleneck detection and Oracle-based re-decomposition events during Phase 5.1. Added after the "計画逸脱ログ" section. See [Bottleneck Detection Reference](../../../references/bottleneck-detection.md) for thresholds and Oracle discovery protocol.

```markdown
### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->

| 検出時刻 | Step | 検出理由 | Oracle | 再分解 |
|---------|------|---------|--------|-------|
| {timestamp} | S{n} | {reason} | {oracle_source}: {oracle_path} | S{n}.1, S{n}.2, ... |
```

**Fields**:

| Field | Description | Example |
|-------|-------------|---------|
| 検出時刻 | ISO 8601 timestamp | `2026-02-15T12:00:00+09:00` |
| Step | Original step ID | `S3` |
| 検出理由 | Which threshold was exceeded | `ラウンド数超過 (5/3)` |
| Oracle | Source and file path | `Phase 3.2.1: implement.md` or `同ディレクトリ: create.md` or `なし` |
| 再分解 | List of sub-step IDs | `S3.1, S3.2, S3.3` |

**When no bottlenecks detected**: Display `_ボトルネック検出はありません_`

**Recording timing**: At the next bulk update point (commit time), per implement.md 5.1.0.5. This avoids excessive API calls during active implementation.

## TDD State Section

Tracks TDD Light mode state during implementation. Added by Phase 5.1.0.T when `tdd.mode: "light"` is configured. Not present during initialization (added at first skeleton generation).

```markdown
### TDD 状態
- **skeleton_generated**: {true/false}
- **classification**: {TDD_RED_CONFIRMED/TDD_TRIVIALLY_PASSING/...}
- **criteria_count**: {n}
- **generated_count**: {n}
- **skipped_count**: {n}
- **skip_reason**: {reason or null}
```

**Field definitions:**

| Field | Type | Description |
|-------|------|-------------|
| `skeleton_generated` | bool | Whether skeletons have been generated |
| `classification` | string | Classification result from Phase B (see [tdd-light.md](../../../references/tdd-light.md#classification-logic)) |
| `criteria_count` | int | Total acceptance criteria extracted |
| `generated_count` | int | Number of skeletons actually generated |
| `skipped_count` | int | Number of criteria skipped (idempotency or limit) |
| `skip_reason` | string/null | Reason if entire generation was skipped (e.g., `commands.test: null`, `no acceptance criteria`, `framework not detected`) |

**Skip stub schema** (when generation is skipped entirely):

```markdown
### TDD 状態
- **skeleton_generated**: false
- **classification**: N/A
- **criteria_count**: 0
- **generated_count**: 0
- **skipped_count**: 0
- **skip_reason**: {reason}
```

**Idempotency rules**:

- Global skip: `skeleton_generated: true` AND tags exist in codebase → skip generation
- Per-criterion skip: tag already exists in test file → skip individual criterion
- Tag disappearance: `skeleton_generated: true` but tags not found → WARNING + regenerate

**Conditional preservation in update.md**: Preserve `### TDD 状態` section when it exists. Do not add during initial work memory creation (Phase 2.6) — only added by Phase 5.1.0.T.

## Review Response History Section

Tracks the review-fix loop count. Updated by `/rite:pr:review` Phase 6.2 after each review cycle.

```markdown
### レビュー対応履歴
- **現在のループ回数**: {n}
```

**Field definition:**

| Field | Type | Description |
|-------|------|-------------|
| `現在のループ回数` | Integer | Number of completed review-fix cycles. Starts at `1` after the first review and increments by 1 on each subsequent review. |

**Update timing**: `/rite:pr:review` Phase 6.2 reads the current value, increments by 1 (or sets to `1` if absent), and writes back alongside the review history.

**Purpose**: Provides a reliable source for `loop_count` in Phase 1.2.4, avoiding inference from conversation context which becomes unreliable after context compaction.

**When `レビュー対応履歴` section does not exist**: Initialize with `現在のループ回数: 1` on first review.

---

## Review Results Section

Added after `/rite:pr:review` as a new comment or section.

```markdown
## 📜 rite レビュー結果

### 総合評価
**評価**: マージ可 / 条件付き / 要修正 / マージ不可（指摘あり）

| レビュアー | 評価 | 重要度 |
|-----------|------|--------|
| security-reviewer | 可 | - |

### 指摘サマリー
| 重要度 | 件数 |
|--------|------|
| CRITICAL | 0 |
| MUST | 1 |
| SHOULD | 3 |

### 次のアクション
/rite:pr:ready or /rite:pr:fix
```

Fields: `総合評価` (overall result), `レビュアー` (agent name), `評価` (可/条件付き/要修正), `重要度` (CRITICAL/MUST/SHOULD), count by severity, recommended action

### When PR Number Is Added

Added to `セッション情報` when `/rite:pr:create` succeeds:
```markdown
- **PR 番号**: #538
```

Timing: Immediately after PR creation, during Phase 4 update. If creation fails, field is omitted and error details go in `備考`.

### Validation

✅ **Valid**: All required fields present, ISO 8601 timestamps, known phase values

❌ **Invalid**: Missing required field (`フェーズ`), wrong timestamp format (`02/10/2026 7:00 AM`), unknown phase ID (`phase99_unknown`)

## Local Work Memory File (Schema v1)

Local file at `.rite-work-memory/issue-{n}.md` is the SoT for all work memory operations.

### File Structure

```markdown
# 📜 rite 作業メモリ

## Summary
---
schema_version: 1
issue_number: 721
sync_revision: 3
sync_status: synced
source: pre_compact
last_modified_at: "2026-02-21T06:30:00Z"
phase: "phase5_implementation"
phase_detail: "ファイル編集"
next_action: "テスト実行"
branch: "feat/issue-721"
pr_number: null
last_commit: "abc1234"
loop_count: 0
---

短い人間可読サマリー

## Detail
自由記述
```

### Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | int | Yes | Always `1` for v1 |
| `issue_number` | int | Yes | Issue number (cross-validated with filename) |
| `sync_revision` | int | Yes | Incremented on each write |
| `sync_status` | string | No | `synced` / `pending` / `conflict` |
| `source` | string | No | Provenance tracking (e.g., `pre_compact`, `resume`, `init`) |
| `last_modified_at` | string | No | UTC ISO 8601 timestamp (`Z` suffix) |
| `phase` | string | No | Current phase ID (e.g., `phase5_implementation`; see [phase-mapping.md](./phase-mapping.md)) |
| `phase_detail` | string | No | Phase detail |
| `next_action` | string | No | Next action description |
| `branch` | string | No | Branch name |
| `pr_number` | int/null | No | PR number (null if not created) |
| `last_commit` | string | No | Last commit hash |
| `loop_count` | int | No | Review-fix loop count |

### SoT Rules

- **Local file is always SoT**. Issue comment is backup/replica only.
- **Restore from API** is allowed only when: (1) local file does not exist, or (2) local file is corrupt.
- **`source` field** is for provenance tracking only. It is NOT used for SoT determination or conflict resolution.

### Corruption Detection

A local work memory file is corrupt if any of:
1. Header `# 📜 rite 作業メモリ` is missing
2. Frontmatter cannot be extracted (no `---` delimiters)
3. Required keys missing (`schema_version`, `issue_number`, `sync_revision`)
4. `issue_number` in frontmatter does not match filename `issue-{n}.md`

### Parsing

Use `{plugin_root}/hooks/work-memory-parse.py` for parsing. Do NOT use shell `grep`/`sed` for YAML interpretation. Resolve `{plugin_root}` per [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version).

```bash
python3 {plugin_root}/hooks/work-memory-parse.py .rite-work-memory/issue-721.md
# Output: JSON with status, data, errors fields
```

### Directory Setup

```bash
mkdir -p .rite-work-memory
chmod 700 .rite-work-memory 2>/dev/null || true
```

Files are written atomically: `tmp` → `mv`.

## Lock Mechanism

Issue-level locking prevents concurrent access to local work memory files from implementation commands and the pre-compact hook.

### Shared Lock Module

`{plugin_root}/hooks/work-memory-lock.sh` provides `mkdir`-based lock/unlock functions:

| Function | Description |
|----------|-------------|
| `acquire_wm_lock "$lockdir" [timeout]` | Acquire lock (default: 50 iterations x 100ms = 5s) |
| `release_wm_lock "$lockdir"` | Release lock |
| `is_wm_locked "$lockdir"` | Check if locked |

**Lock paths**:
- Compact state lock: `.rite-compact-state.lockdir` (used by pre-compact.sh)
- Issue work memory lock: `.rite-work-memory/issue-{n}.md.lockdir` (used by commands)

**Stale lock detection**: Controlled by `WM_LOCK_STALE_THRESHOLD` (default: 120s for compact, 300s for issue). When lock age exceeds the threshold, force-remove and retry once.

### Usage in Commands

**Recommended: Use the self-resolving wrapper** (`local-wm-update.sh`):

```bash
WM_SOURCE="implement" \
  WM_PHASE="phase5_lint" \
  WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint を実行" \
  WM_BODY_TEXT="Post-implementation." \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

The wrapper auto-resolves the plugin root via `BASH_SOURCE`, then sources `work-memory-update.sh` and calls `update_local_work_memory`. For marketplace installs, resolve `{plugin_root}` per [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version), then use `bash {plugin_root}/hooks/local-wm-update.sh` instead. The helper handles lock acquisition, YAML frontmatter parsing, atomic write, and lock release internally. See `hooks/work-memory-update.sh` header comments for the full list of environment variables.

**Low-level lock API** (for non-standard use cases only):

```bash
source {plugin_root}/hooks/work-memory-lock.sh
WM_LOCK_STALE_THRESHOLD=300  # 5 minutes for issue lock
LOCKDIR=".rite-work-memory/issue-{n}.md.lockdir"
if acquire_wm_lock "$LOCKDIR"; then
  # ... atomic write (tmp + mv) ...
  release_wm_lock "$LOCKDIR"
fi
```

**On lock failure**: Commands treat local work memory update as best-effort. `.rite-flow-state` is the primary state record; local work memory is for cross-session recovery.

## sync_revision Rules

The `sync_revision` field tracks write operations for ordering and conflict detection.

| Rule | Description |
|------|-------------|
| **Increment on every write** | Each write to the local file increments `sync_revision` by 1 |
| **Read before increment** | Use `work-memory-parse.py` to read current revision |
| **Start at 1** | When file does not exist, start with `sync_revision: 1` |
| **Source tracking** | `source` field records the writer (e.g., `pre_compact`, `implement`, `fix`, `lint`, `resume`) |

### Sync Status

| Value | Meaning |
|-------|---------|
| `synced` | Local and Issue comment are in sync |
| `pending` | Local updated, Issue comment not yet synced |
| `conflict` | Detected inconsistency (manual resolution needed) |

### Issue Comment Backup Sync

Issue comment is a backup replica, synced at phase transitions:

| Trigger | Description |
|---------|-------------|
| Phase transition (review-fix loop) | After each review or fix cycle |
| Pre-compact snapshot | Hook saves local state before compaction |
| Resume from Issue comment | Restored when local file is missing/corrupt |
| PR creation | After `rite:pr:create` completes |
| Cleanup completion | Final state record in `rite:pr:cleanup` |

## Preflight Guard Contract (Phase C)

All `/rite:*` commands (except `issue/start` and `resume`, which are Orchestrators) run a preflight check before execution. `issue/start` and `resume` manage flow state via `.rite-flow-state` and delegate preflight to the sub-commands they invoke. The check detects compact-blocked state and prevents execution when recovery is needed.

### Contract

```bash
bash {plugin_root}/hooks/preflight-check.sh --command-id "/rite:{command}" --cwd "$(pwd)"
```

- Exit `0`: Allowed (proceed with command)
- Exit `1`: Blocked (do not execute command, display preflight output)
- `/rite:resume` is always allowed (bypasses block)

### Command Categories

| Category | Commands | Local WM Operation |
|----------|---------|-------------------|
| **Write** | `pr/create`, `pr/review`, `pr/ready`, `pr/cleanup`†, `pr/fix`, `issue/close`, `issue/update`, `issue/implement`, `issue/work-memory-init`, `lint` | Read + Write (via `local-wm-update.sh`) |
| **Read** | `issue/branch-setup`, `issue/implementation-plan`, `sprint/execute`, `sprint/team-execute` | Read only |
| **Preflight only** | `issue/create`, `issue/list`, `issue/edit`, `issue/parent-routing`, `issue/child-issue-selection`, `workflow`, `getting-started`, `sprint/list`, `sprint/current`, `sprint/plan`, `skill/suggest`, `template/reset`, `init` | None |
| **Orchestrator** | `issue/start`, `resume` | Managed by flow state (these commands orchestrate other commands; they do not directly read/write local WM but control flow via `.rite-flow-state`) |

† `pr/cleanup` updates Issue comment directly in Phase 4.5 (final archival record) because local WM file is deleted earlier in Phase 3.

### SoT Access Pattern

All commands that read work memory follow this priority:

1. **Local file** (`.rite-work-memory/issue-{n}.md`) — SoT
2. **Issue comment API** — fallback when local file missing/corrupt
3. **Context** — information already loaded in conversation

Commands that write work memory update the local file first (SoT), then sync to Issue comment (backup) at phase transitions.

## Related

- [Phase Mapping](./phase-mapping.md) - Phase definitions
- [Session Detection](./session-detection.md) - Auto-detection at session start
- [Bottleneck Detection](../../../references/bottleneck-detection.md) - Thresholds, Oracle discovery, re-decomposition
