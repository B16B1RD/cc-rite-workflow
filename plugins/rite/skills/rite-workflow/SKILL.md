---
name: rite-workflow
description: |
  rite workflow orchestration context for rite's Issue-to-PR lifecycle:
  workflow state detection, phase routing, and shared coding principles
  for the rite skills. Loaded only when explicitly working within the
  rite workflow — not a general-purpose Issue / PR / commit / branch /
  review helper, and intentionally does not auto-activate on those terms.
user-invocable: false
---

# Rite Workflow Skill

rite workflow 操作のコンテキスト: 状態検出・コマンド案内・共有原則。

- Workflow Awareness / Command Guidance / Best Practices（Conventional Commits・ブランチ命名・PR テンプレート）
- [coding-principles.md](./references/coding-principles.md) / [common-principles.md](./references/common-principles.md) / [comment-best-practices.md](./references/comment-best-practices.md)

## Workflow Identity (品質 > 時間/context)

rite workflow の identity は「定義された step を全て実行し、生成物の品質を担保する」ことである。**時間的制約や context 残量を理由にした step の省略は禁止**。残量の推論も禁止。context 枯渇の正規経路は `/clear` + `/rite:recover`。LLM が自己判断でワークフローを短縮する経路は存在しない。

**workflow は途中で止まらない。最後のわけのわからない出力で終わらない。** sub-skill の return tag (`[lint:*]` / `[pr:created:N]` / `[review:*]` / `[fix:*]` / `[ready:returned-to-caller]`) は **turn 境界ではなく継続トリガ**。ユーザー介入を要求せず同 turn 内で次 phase へ進む。

`[create:returned-to-caller:{N}]` は create.md 内で完結する terminal sentinel。user-visible な最終行は「✅ Issue #{N} を作成しました: {url}」等の完了メッセージとし、sentinel は HTML コメント化して末端に孤立させない。

> **Sentinel naming policy**: skill return signal の literal は `:returned-to-caller` 形式で統一する。各 emit site では sentinel 直前に `<!-- skill return signal: caller must continue next step -->` を併記する。
> rationale: references/rationale.md#sentinel-naming

| 禁止事項 | 正規経路 |
|---------|---------|
| 「時間が足りないので X を省略します」 | 手順どおり実行 |
| 「context が圧迫しているので要約します」 | 手順どおり実行 |
| 「残量が不安なので review を切り上げます」 | `/clear` + `/rite:recover` をユーザーに案内 |
| return tag 直後に turn を閉じる | 同 turn 内で次 phase に継続。途中で止まった場合の正規復帰経路は `/rite:recover` (`skills/recover/SKILL.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の phase→step 表に従う) |
| sentinel marker `[create:returned-to-caller:{N}]` を user-visible な最終行として残す | HTML コメント `<!-- [create:returned-to-caller:{N}] -->` として末尾に配置し、user-visible な最終行は `✅ ...` 完了メッセージにする |

詳細と Anti-pattern / Correct Pattern は [references/workflow-identity.md](./references/workflow-identity.md) を参照。各 command (start / review / fix / ready / lint / cleanup / create / recover 等) からも同 reference を引いている。

## Multi-Step Workflow Task Tracking

3 step 以上の sequential workflow では `TaskCreate` / `TaskUpdate` / `TaskList` で進捗を追跡する。「最外側 skill」= `TaskCreate` を発行する skill、「nested sub-skill」= Skill ツール経由で呼ばれた skill。代表例: `cleanup`, `iterate`, `open`, `review`, `fix`, `wiki-ingest`, `wiki-lint`。
rationale: references/rationale.md#task-tracking-threshold

- **開始時 (最外側 skill のみ)**: `TaskCreate` でステップ列を全件登録する。nested sub-skill は既存 TaskList に対し下記 **各 step 完了時** ルールと **nested sub-skill の return 時点** ルールのみ適用する (二重 TaskCreate 禁止)。
- **各 step 完了時**: `TaskUpdate` で当該 step の status を `completed` に更新する。
- **最外側 skill の return 時点**: `TaskList` で未完了タスクの有無を確認する。未完了タスクが残っている場合は、未実行の最初の step に戻って実行を継続する (turn を終了しない)。全タスクが `completed` の場合のみ turn を終了する。
- **nested sub-skill (例: `wiki-ingest` から呼ばれた `wiki-lint`) の return 時点**: `TaskUpdate` のみ行い、turn 終了の判断は最外側 skill に委ねる。

## Workflow State Detection

Detect current state from:
- Branch name pattern: `{type}/issue-{number}-*`
  - `{type}` values: `feat`, `fix`, `docs`, `refactor`, `chore`, `style`, `test`
  - `style` is used for code style/formatting changes (no logic changes)
- Git status
- Open PRs

## Suggested Actions

| State | Suggestion |
|-------|------------|
| On main/develop, no Issue | `/rite:issue-create` or `/rite:issue-list` |
| Have an Issue, want to start work | `/rite:open <issue>` (Issue → branch → 実装 → lint → draft PR を一気通貫) |
| On feature branch, PR open / draft, review-fix cycle | `/rite:iterate <pr>` (mergeable まで review ⇄ fix をループ、収束トレンドの発散検出 + `safety.max_review_cycles` backstop のサーキットブレーカーあり) |
| Review mergeable, want to mark Ready | `/rite:ready <pr>` then `/rite:merge <pr>` |
| Merge 完了、branch 削除 / Wiki ingest / Projects Status Done 後処理が必要 | `/rite:cleanup <pr>` |
| 複数 Issue を draft PR まで一括自律実行したい | `/rite:batch-run <issue>...` (各 Issue に open→iterate を順次実行し draft 止まり、失敗で即停止)。merge→cleanup まで完走するなら `/rite:batch-run --merge <issue>...` |
| Long session (30+ minutes elapsed) | `/rite:issue-update` |

## Question Management

> **Key Principle**: 質問前に必ず `question_self_check`（[common-principles.md](./references/common-principles.md)）。大半は推論とデフォルトで避けられる。

### When Questions Are Necessary

Ask immediately (do not defer) when:
- **Blockers**: Issues that prevent further progress
- **Security-related**: Decisions affecting security
- **Destructive operations**: Actions that cannot be undone
- **External impacts**: Changes affecting users or external systems

### Work Memory Integration

If questions arise during work, record them in the work memory comment under "要確認事項" (Items to Confirm):

```markdown
### 要確認事項

1. [ ] {confirmation_item_1}
2. [ ] {confirmation_item_2}
```

### Expected Question Frequency

**Target**: Minimize questions through context inference and sensible defaults. Issue Start: 0-1 (score C/D only), Implementation: 0, PR Review: 0-1 (critical decisions only). Record non-blocking questions in work memory.

See [references/common-principles.md](./references/common-principles.md) for detailed frequency table by phase.

## Session Start Auto-Detection

Automatically detect work state at session start and notify if interrupted work exists.

See [references/session-detection.md](./references/session-detection.md) for details.

### Quick Reference

1. Extract Issue number from branch name (`{type}/issue-{number}-*` pattern)
2. Fetch work memory comment from the Issue
3. Extract and display phase information

See [references/phase-mapping.md](./references/phase-mapping.md) for phase list.

See [references/work-memory-format.md](./references/work-memory-format.md) for work memory format.

## 4 Command Architecture

**4 つの単機能コマンド**（旧 `/rite:issue-start` 分解。詳細は CHANGELOG）:
rationale: references/rationale.md#four-command-split

| コマンド | 責務 | 区分 |
|---|---|---|
| `/rite:open <issue>` | Issue → branch → 実装 → lint → draft PR (Step 0 Resume Dispatch 含む) | orchestrator |
| `/rite:iterate <pr>` | review ↔ fix を `[review:mergeable]` までループ (サーキットブレーカーあり: 収束トレンドの発散検出が主経路、`safety.max_review_cycles` は backstop; 発火時は batch / 対話とも人間に問わず機械的に停止し、再開は `/rite:iterate` の明示的な再実行のみ。手動中断は Ctrl+C) | orchestrator |
| `/rite:ready <pr>` | Ready 化 + Projects Status + 親判定 + 完了レポート | self-contained command |
| `/rite:merge <pr>` | `gh pr merge --squash` を叩くだけ (cleanup は分離) | self-contained command |

`/rite:issue-create` は flat single-file を維持。マージ後の cleanup は `/rite:cleanup` を別途実行。

複数 Issue は `/rite:batch-run <issue>...` が **デフォルトでは** `open → iterate` を順次自律実行して draft PR を残し、`--merge` 時のみ `ready → merge → cleanup` まで完走する（成功する限り無確認、失敗で即停止、残りキューは `.rite/state/run-queue-{session_id}.json`）。flow-state の handoff は使わず、継続は flat step 構造に委ねる。

途中停止の正規復帰は `/rite:recover`（`skills/recover/SKILL.md` Phase 5.3 の phase→step 表）。

### Sub-skill sentinel 一覧 (orchestrator から grep される SoT)

| sub-skill | emit する sentinel | invoke 元 |
|---|---|---|
| `rite:issue-implement` | (現状 sentinel 未発火 — 完了は work memory / flow-state 側で確認する設計) | `open` Step 4 |
| `rite:lint` | `[lint:success]` / `[lint:skipped]` / `[lint:error]` / `[lint:aborted]` | `implement` 内で autonomous invoke、`open` Step 5 が結果を読む |
| `rite:pr-create` | `[pr:created:N]` / `[pr-create-failed]` | `open` Step 6 |
| `rite:pr-review` | `[review:mergeable]` / `[review:fix-needed:N]` / `[review:error]` | `iterate` 内ループ |
| `rite:fix` | `[fix:pushed]` / `[fix:pushed-wm-stale]` / `[fix:replied-only]` / `[fix:cancelled-by-user]` / `[fix:error]` | `iterate` 内ループ |
| `rite:ready` | `[ready:returned-to-caller]` / `[ready:error]` | ユーザー直接 / `run` orchestrator |
| `rite:merge` | `[merge:returned-to-caller]` / `[merge:not-ready]` / `[merge:error]` | ユーザー直接 / `run` orchestrator |
| `rite:cleanup` | `[cleanup:returned-to-caller]` | ユーザー直接 / `run` orchestrator |

orchestrator (`open` / `iterate`) が sub-skill 出力の sentinel を grep で routing する。`run` はデフォルト `open → iterate`、`--merge` 時は続けて `ready → merge → cleanup`（失敗で即停止）。handoff は使わず flat step 構造に委ねる。

## AI Coding Principles (Summary)

仮定を表面化し、押し返し、シンプルさ・スコープ規律を死守する。user-visible な挙動が変わったら README / docs / CLAUDE.md / plugin .md を同じ PR で更新する（`documentation_consistency`）。知識の経路（`knowledge_routing`）: How → code, What → tests, Why → commit log, Why not → code comments。全文: [coding-principles.md](./references/coding-principles.md)。

**Canon TDD**: `tdd.enabled: true`（default, opt-out）のとき `rite:issue-implement` が Canon TDD を回す（[`issue-implement/SKILL.md`](../issue-implement/SKILL.md) § 5.0.T）。`commands.test` 未設定なら test-list discipline のみ、`tdd.enabled: false` なら skip。スキーマ: [CONFIGURATION.md](../../../../docs/CONFIGURATION.md) `### tdd`。

## Simplification Charter (rite plugin maintenance)

`plugins/rite/` の編集と生成物（commit / Issue / PR / review）は **Simplification Charter** に従う。runtime に効かない経緯は書かない / git log で足りるものはコードに書かない / `Issue #` / `PR #` / `cycle #` の本文引用は禁止 / 重複 confirmation 禁止。cleanup / fix / review の `references/` は主要適用対象。

See [simplification-charter.md](./references/simplification-charter.md)。

## Common Principles (AskUserQuestion Reduction)

Reduce excessive questions: self-check necessity, use defaults when available, infer from context.

See [references/common-principles.md](./references/common-principles.md) for details.

## gh CLI Safety Rules

All `gh` commands that accept `--body` or `--comment` parameters **MUST** use safe patterns to avoid shell injection:

- Use `--body-file` with `mktemp` for multi-line content
- Reference: See `references/gh-cli-patterns.md` for detailed safe patterns

**Never** pass user-generated content directly via `--body` or `--comment` flags.

## Workflow Failure Surfacing

`/rite:open` / `/rite:iterate` / `/rite:ready` / `/rite:merge` の失敗・skip は該当 skill / hook が `WARNING` / `ERROR` を **stderr** に出す。orchestrator が会話へ surface し、ユーザーは `/rite:recover` で再実行する。失敗は可視だが Issue 自動登録はしない。
rationale: references/rationale.md#incident-emit-removed

## Integration

This skill works with:
- All `/rite:*` commands
- GitHub CLI operations
- Git operations
