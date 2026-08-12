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

This skill provides context for rite workflow operations.

## Context

When activated, this skill provides:

1. **Workflow Awareness**
   - Current branch and associated Issue
   - Work memory state
   - Status in GitHub Projects

2. **Command Guidance**
   - Suggest appropriate commands
   - Remind about work memory updates
   - Guide through workflow steps

3. **Best Practices**
   - Conventional Commits format
   - Branch naming conventions
   - PR template usage

4. **Coding Principles**
   - Avoid common AI coding failure patterns
   - See [references/coding-principles.md](./references/coding-principles.md) for details

5. **Common Principles**
   - Reduce excessive AskUserQuestion usage
   - See [references/common-principles.md](./references/common-principles.md) for details

6. **Comment Best Practices**
   - WHY > WHAT, no journal comments, no line/cycle number references, jargon whitelist enforcement
   - See [references/comment-best-practices.md](./references/comment-best-practices.md) for details

## Workflow Identity (品質 > 時間/context)

rite workflow の identity は「定義された step を全て実行し、生成物の品質を担保する」ことである。**時間的制約や context 残量を理由にした step の省略は禁止**。残量の推論も禁止。context が実際に枯渇した場合の正規経路は `/clear` + `/rite:recover` の組合せであり、LLM が自己判断でワークフローを短縮する経路は存在しない。

**さらに、workflow は途中で止まらない。そして最後のわけのわからない出力で終わらない。** sub-skill の return tag (`[lint:*]` / `[pr:created:N]` / `[review:*]` / `[fix:*]` / `[ready:returned-to-caller]`) は **turn 境界ではなく継続トリガ** である。ユーザー介入 (`continue` 入力) を要求せずに、同 turn 内で次 phase へ進む。

`create.md` の flat workflow 終端で出力される `[create:returned-to-caller:{N}]` HTML コメント marker は、他 sub-skill の return tag と異なり create.md 内で完結する terminal sentinel である (create は orchestrator から sub-skill として呼ばれず、継続すべき caller skill を持たない)。`:returned-to-caller` という命名は terminal vocabulary (`:completed`) が LLM の turn-boundary heuristic を誤発火させるのを避けるための全 producer 統一形式であり、create に caller skill が存在することを意味しない (hook / grep 契約のため必須)。ワークフロー完了時の user-visible な最終行は sentinel marker ではなく「✅ Issue #{N} を作成しました: {url}」のような人間可読な完了メッセージとし、sentinel は HTML コメント化等で user-visible な末端に孤立させない。

> **Sentinel naming policy**: skill return signal の literal は `:returned-to-caller` 形式で統一する。旧 `:completed` 形式は LLM の turn-boundary heuristic と衝突し、caller skill の次 step を skip して turn が暗黙終了する事象を構造的に誘発する (実測ベース)。新形式は「caller に return した = caller の次 step に進む」という semantic に置換することで terminal vocabulary を構造的に排除する。各 emit site では sentinel 直前に `<!-- skill return signal: caller must continue next step -->` を併記して active disambiguation を提供する。

| 禁止事項 | 正規経路 |
|---------|---------|
| 「時間が足りないので X を省略します」 | 手順どおり実行 |
| 「context が圧迫しているので要約します」 | 手順どおり実行 |
| 「残量が不安なので review を切り上げます」 | `/clear` + `/rite:recover` をユーザーに案内 |
| return tag 直後に turn を閉じる | 同 turn 内で次 phase に継続。途中で止まった場合の正規復帰経路は `/rite:recover` (`skills/recover/SKILL.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の phase→step 表に従う) |
| sentinel marker `[create:returned-to-caller:{N}]` を user-visible な最終行として残す | HTML コメント `<!-- [create:returned-to-caller:{N}] -->` として末尾に配置し、user-visible な最終行は `✅ ...` 完了メッセージにする |

詳細と Anti-pattern / Correct Pattern は [references/workflow-identity.md](./references/workflow-identity.md) を参照。各 command (start / review / fix / ready / lint / cleanup / create / recover 等) からも同 reference を引いている。

## Multi-Step Workflow Task Tracking

3 step 以上の sequential workflow を実行する際は、以下の手順で `TaskCreate` / `TaskUpdate` / `TaskList` を使って進捗を能動追跡する。ここで「最外側 skill」とは `TaskCreate` を発行する skill (= ユーザーが invoke した最上位の skill) を指し、それ以外の skill (最外側から Skill ツール経由で呼ばれた skill) を「nested sub-skill」と呼ぶ。閾値を「3 step 以上」とするのは、2 step 以下の skill は単一 turn 内で逐次実行する想定で TaskList 管理の overhead が利点を上回らないため。代表例: `cleanup`, `iterate`, `open`, `review`, `fix`, `wiki-ingest`, `wiki-lint` (列挙は例示で完全網羅ではない)。

- **開始時 (最外側 skill のみ)**: `TaskCreate` でステップ列を全件登録する。nested sub-skill は既存 TaskList に対し下記 **各 step 完了時** ルールと **nested sub-skill の return 時点** ルールのみ適用する (二重 TaskCreate 禁止)。
- **各 step 完了時**: `TaskUpdate` で当該 step の status を `completed` に更新する。
- **最外側 skill の return 時点**: `TaskList` で未完了タスクの有無を確認する。未完了タスクが残っている場合は、未実行の最初の step に戻って実行を継続する (turn を終了しない)。全タスクが `completed` の場合のみ turn を終了する。
- **nested sub-skill (例: `wiki-ingest` から呼ばれた `wiki-lint`) の return 時点**: `TaskUpdate` のみ行い、turn 終了の判断は最外側 skill に委ねる。

これにより skill ネスト時 (例: `cleanup → wiki-ingest → wiki-lint`) の最内側 sentinel を turn 終了と誤認する事故を防ぐ。

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

> **Key Principle**: Always apply `question_self_check` (see [references/common-principles.md](./references/common-principles.md)) before asking questions. Most questions can be avoided through context inference and using sensible defaults.

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

`/rite:issue-start` は廃止され、**4 つの単機能コマンド** に分解されている (詳細は CHANGELOG 参照):

| コマンド | 責務 | 区分 |
|---|---|---|
| `/rite:open <issue>` | Issue → branch → 実装 → lint → draft PR (Step 0 Resume Dispatch 含む) | orchestrator |
| `/rite:iterate <pr>` | review ↔ fix を `[review:mergeable]` までループ (サーキットブレーカーあり: 収束トレンドの発散検出が主経路、`safety.max_review_cycles` は backstop; 発火時は batch / 対話とも人間に問わず機械的に停止し、再開は `/rite:iterate` の明示的な再実行のみ。手動中断は Ctrl+C) | orchestrator |
| `/rite:ready <pr>` | Ready 化 + Projects Status + 親判定 + 完了レポート | self-contained command |
| `/rite:merge <pr>` | `gh pr merge --squash` を叩くだけ (cleanup は分離) | self-contained command |

`/rite:issue-create` は引き続き flat single-file workflow を維持。マージ後の cleanup は `/rite:cleanup` (既存) を別途実行する。

複数 Issue をまとめて回す場合は `/rite:batch-run <issue>...` が各 Issue に対し **デフォルトでは** `open → iterate` を順次・完全自律で実行して draft PR を残し (merge せずレビュー待ち)、`--merge` 指定時のみ `ready → merge → cleanup` まで完走する (meta-orchestrator。成功する限り無確認、失敗で即停止、残りキューとモードは `.rite/state/run-queue-{session_id}.json` にセッションごとに永続化 = 並行 batch-run が相互破壊しない)。flow-state の handoff は使わず、継続は flat step 構造に委ねる。

LLM が途中で停止した場合の正規復帰経路は `/rite:recover` で、`skills/recover/SKILL.md` Phase 5.3 (Phase enum → Step mapping (SoT)) の phase→新 4 コマンド routing 表に従う。implicit-stop 対策の hook 群 (`auto-fire-step0.sh` / `stop-create-interview-block.sh` / `verify-terminal-output.sh`) は撤去済み。

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

orchestrator (`open` / `iterate`) が sub-skill 出力の sentinel を grep で routing する。`ready` / `merge` / `cleanup` は self-contained だが、`run` (meta-orchestrator) が各 Issue に対しデフォルトでは `open → iterate` を、`--merge` 指定時のみ続けて `ready → merge → cleanup` を順に invoke し、それぞれの sentinel を grep して次段へ進む (失敗で即停止)。`run` は flow-state の handoff を使わず、継続は flat step 構造に委ねる。

現行の continuation enforcement は Layer 3 caller-continuation hints + Layer 4a/4b orchestrator-side reinforcements + flat sequential structure による (旧 Layer 1 prompt contract は cleanup.md flat 化と同時に物理排除済)。

## AI Coding Principles (Summary)

Avoid common AI coding failure patterns: surface assumptions, manage confusion, push back when warranted, enforce simplicity, maintain scope discipline, clean dead code, plan inline, address all discovered issues, and keep documentation in sync with specification changes (`documentation_consistency`) — when the implementation changes user-visible behavior, update related README / docs / CLAUDE.md / plugin .md files in the same PR rather than deferring to a follow-up Issue. Route each kind of knowledge to its durable medium (`knowledge_routing`): How → code, What → tests, Why → commit log, Why not → code comments.

See [references/coding-principles.md](./references/coding-principles.md) for the full principle list and details.

**Canon TDD in the implementation phase**: When `tdd.enabled: true` (default, opt-out) in `rite-config.yml`, `rite:issue-implement` drives a Canon TDD cycle — build a test list (seeded from the Issue's Section 6 Test Specification), then for each behavior: write a test → confirm it fails (Red) → minimal implementation (Green) → Refactor → repeat until the list is empty. The cycle is defined in [`skills/issue-implement/SKILL.md`](../issue-implement/SKILL.md) § 5.0.T. It degrades to test-list discipline only (Red/Green runs skipped) when `commands.test` is unset, and is skipped entirely when `tdd.enabled: false`. Config schema: [docs/CONFIGURATION.md](../../../../docs/CONFIGURATION.md) `### tdd`.

## Simplification Charter (rite plugin maintenance)

`plugins/rite/` 配下のファイルを編集する LLM・メンテナ、および rite workflow が生成する commit message / Issue body / PR description / review 指摘は、自己生成的に肥大化しないよう **Simplification Charter** に従う。runtime に効かない経緯記述は書かない / git log で代替できるものはコードに書かない / `Issue #` / `PR #` / `cycle #` の本文引用は禁止 / 重複 confirmation 禁止。

特に `skills/cleanup/SKILL.md` および pr lifecycle 系スキル（cleanup / fix / review）の `references/` 配下のファイル群（**pr/cleanup 系**）は本 charter の主要適用対象であり、各ファイル冒頭に charter SoT 参照行を持つ。

See [references/simplification-charter.md](./references/simplification-charter.md) for the 5 self-questions (5 つの自問) / prohibited patterns (禁止パターン) / recommended patterns (推奨パターン).

## Common Principles (AskUserQuestion Reduction)

Reduce excessive questions: self-check necessity, use defaults when available, infer from context.

See [references/common-principles.md](./references/common-principles.md) for details.

## gh CLI Safety Rules

All `gh` commands that accept `--body` or `--comment` parameters **MUST** use safe patterns to avoid shell injection:

- Use `--body-file` with `mktemp` for multi-line content
- Reference: See `references/gh-cli-patterns.md` for detailed safe patterns

**Never** pass user-generated content directly via `--body` or `--comment` flags.

## Workflow Failure Surfacing

When a step of `/rite:open` / `/rite:iterate` / `/rite:ready` / `/rite:merge` fails or is skipped (Skill load failure, hook abnormal exit, Wiki ingest skip/failure, etc.), the affected skill or hook emits a plain `WARNING` / `ERROR` line to **stderr**. The orchestrator surfaces it in the conversation context, and the user re-runs the affected step via `/rite:recover`. Failures are visible but not auto-registered as Issues; the user decides whether to file one.

> The earlier auto-registration mechanism (`workflow-incident-emit.sh` sentinel + `/rite:issue-start` detection + `workflow_incident:` config key) was removed in favor of this single-layer plain-stderr design. See `docs/SPEC.md` "Workflow Failure Surfacing" for details.

## Integration

This skill works with:
- All `/rite:*` commands
- GitHub CLI operations
- Git operations
