# Claude Code Rite Workflow Specification

> Universal Issue-Driven Development Workflow Claude Code Plugin

## Overview

**Claude Code Rite Workflow** is a universal Claude Code plugin that provides an Issue-driven development workflow.
It works with any software development project regardless of language or framework.

### Design Principles

- **Rite**: Structured process that ensures consistent, repeatable workflows
- **Universality**: No dependency on specific tech stacks
- **Automation**: Auto-detection and auto-configuration where possible
- **Customizability**: Flexible adjustment via configuration files

### Naming Origin

The command prefix `rite` was chosen for:

1. **Meaning**: A rite is a structured ceremony or process - representing consistent, repeatable workflows
2. **Practicality**: Short (4 characters), easy to type, and distinctive as a command prefix
3. **Trademark**: Low trademark risk as it's a common English word

---

## Table of Contents

1. [Command List](#command-list)
2. [Workflow Overview](#workflow-overview)
3. [Plugin Structure](#plugin-structure)
4. [Configuration File Specification](#configuration-file-specification)
5. [Command Specifications](#command-specifications)
6. [Iteration Management (Optional)](#iteration-management-optional)
7. [Hook Specification](#hook-specification)
8. [Features](#features)
9. [Build/Test/Lint Auto-Detection](#buildtestlint-auto-detection)
10. [Dynamic Reviewer Generation](#dynamic-reviewer-generation)
11. [Sub-skill Return Auto-Continuation Contract](#sub-skill-return-auto-continuation-contract)
12. [Error Handling](#error-handling)
13. [Migration](#migration)
14. [~~Internationalization~~ (Retired)](#internationalization-retired)
15. [Dependencies](#dependencies)
16. [Distribution](#distribution)
17. [~~Project Types~~ (Retired)](#project-types-retired)

---

## Command List

| Command | Description | Arguments |
|---------|-------------|-----------|
| `/rite:setup` | Initial setup wizard | `[--upgrade]` (upgrade existing `rite-config.yml` schema to the latest version) |
| `/rite:getting-started` | Interactive onboarding guide | None |
| `/rite:workflow` | Show workflow guide | None |
| `/rite:unknowns` | Pre-implementation exploration session (blind-spot pass, brainstorming, throwaway prototypes, interview) | `[theme]` |
| `/rite:investigate` | Structured code investigation | `<topic or question>` |
| `/rite:learn` | Socratic quiz to verify deep understanding of a finished session | `[issue/pr number] [eli5\|eli14\|intern]` |
| `/rite:issue-list` | List Issues | `[filter]` |
| `/rite:issue-create` | Create new Issue | `<title or description>` |
| `/rite:issue-update` | Update work memory | `[memo]` |
| `/rite:issue-close` | Check Issue completion | `<Issue number>` |
| `/rite:issue-edit` | Interactively edit existing Issue | `<Issue number>` |
| `/rite:open` | Start work end-to-end (branch → plan → implement → lint → draft PR) | `<Issue number>` |
| `/rite:iterate` | Loop review ⇄ fix until mergeable | `<PR number>` |
| `/rite:merge` | Squash-merge the PR | `<PR number>` |
| `/rite:pr-create` | Create draft PR | `[PR title]` |
| `/rite:ready` | Mark as Ready for review | `[PR number]` |
| `/rite:pr-review` | Multi-reviewer review | `[PR number]` |
| `/rite:fix` | Address review feedback | `[PR number]` |
| `/rite:cleanup` | Post-merge cleanup | `[branch name]` |
| `/rite:batch-run` | Run open→iterate (draft only) for each Issue; `--merge` opts into ready→merge→cleanup (stop on first failure) | `[--merge] <Issue number>...` |
| `/rite:lint` | Run quality checks | `[file path]` |
| `/rite:template-reset` | Regenerate templates | `[--force]` |
| `/rite:wiki-init` | Initialize Experience Wiki (branch, directories, templates) | None |
| `/rite:wiki-query` | Search Wiki pages for heuristics by keyword and inject into context | `<keywords>` |
| `/rite:wiki-ingest` | Extract heuristics from raw sources and update Wiki pages | `[source]` |
| `/rite:wiki-lint` | Lint Wiki pages for contradictions, staleness, orphans, missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs | `[--auto] [--stale-days <N>]` |
| `/rite:recover` | Resume interrupted work | `[issue_number]` |
| `/rite:skill-suggest` | Analyze context and suggest applicable skills | `[--verbose\|--filter]` |

---

## Workflow Overview

```
/rite:setup (Initial Setup)
 │
 ▼
/rite:issue-list (Check Issues)
 │
 ▼
/rite:issue-create (Create New Issue)
 │ Status: Todo
 ▼
/rite:open <issue> (Start Work)
 │ Status: In Progress
 │
 ├── Branch Creation
 ├── Implementation Planning
 ├── Implementation Work (rite:issue-implement)
 ├── /rite:lint (Quality Check, autonomous)
 └── /rite:pr-create (Create Draft PR)
 ▼
/rite:iterate <pr> (Review ⇄ Fix loop)
 │ Internally invokes /rite:pr-review and /rite:fix repeatedly
 │ until [review:mergeable] or [fix:replied-only]
 ▼
/rite:ready <pr> (Ready for Review)
 │ Status: In Review
 ▼
/rite:merge <pr> (Squash-Merge)
 │
 ▼
/rite:cleanup <pr> (Post-Merge Cleanup)
 │ Status: Done
 ▼
Issue Auto-Close
```

**Note:** The end-to-end flow is split across four single-responsibility commands. `/rite:open <issue>` handles branch creation, implementation, autonomous lint, and draft PR creation. `/rite:iterate <pr>` loops review and fix until convergence, bounded by a `safety.max_review_cycles` circuit breaker (default 5); on reach, interactive runs prompt via AskUserQuestion and `/rite:batch-run` batch marks the Issue failed and advances (manual abort via `Ctrl+C` + `/rite:recover` remains available). `/rite:ready <pr>` flips the PR to Ready for review. `/rite:merge <pr>` runs `gh pr merge --squash`. For the canonical live spec of each command, see [`skills/open/SKILL.md`](../plugins/rite/skills/open/SKILL.md), [`iterate.md`](../plugins/rite/skills/iterate/SKILL.md), [`ready.md`](../plugins/rite/skills/ready/SKILL.md), and [`merge.md`](../plugins/rite/skills/merge/SKILL.md). (The legacy [Phase 5: End-to-End Execution](#phase-5-end-to-end-execution) section below documents the pre-decomposition `start.md` orchestrator for archaeological / migration reference only.)

**Status Transitions:**
```
Todo → In Progress → In Review → Done
```

---

## Plugin Structure

> **Architecture**: The `/rite:issue-create` lifecycle is a single-file flat workflow. The previous `/rite:issue-start` flat workflow was decomposed into four single-responsibility commands (`/rite:open` / `/rite:iterate` / `/rite:ready` / `/rite:merge`); the source file `commands/issue/start.md` was deleted. Older sub-skill files (`commands/issue/start-execute`, `start-publish`, `start-finalize`, `create-interview`, `create-register`, `create-decompose`, `parent-routing`, etc.) and implicit-stop guard hooks (`auto-fire-step0.sh`, `verify-terminal-output.sh`, `stop-create-interview-block.sh`) were earlier consolidated into the flat workflow before the start.md decomposition. Sections referencing those retired components remain only as migration anchors.

```
rite-workflow/
├── .claude-plugin/
│ └── plugin.json # Plugin metadata
├── agents/ # Subagent definitions for /rite:pr-review
│ ├── _reviewer-base.md # Shared reviewer principles (not a subagent)
│ ├── security-reviewer.md
│ ├── application-reviewer.md
│ ├── code-quality-reviewer.md
│ ├── devops-reviewer.md
│ ├── test-reviewer.md
│ ├── dependencies-reviewer.md
│ ├── prompt-engineer-reviewer.md
│ ├── tech-writer-reviewer.md
│ └── error-handling-reviewer.md
├── skills/ # Claude Code auto-discovered skills (各スキル = 薄い SKILL.md + co-located references/)
│ # --- PR lifecycle ---
│ ├── open/ # /rite:open (Issue → branch → 実装 → lint → draft PR; end-to-end)
│ ├── iterate/ # /rite:iterate (review ⇄ fix loop, mergeable まで)
│ ├── pr-review/ # /rite:pr-review (multi-reviewer; + references/) — sub-skill
│ ├── fix/ # /rite:fix (review 指摘対応; + references/) — sub-skill
│ ├── ready/ # /rite:ready (Ready for review 化)
│ ├── merge/ # /rite:merge (squash merge)
│ ├── cleanup/ # /rite:cleanup (+ references/archive-procedures.md)
│ ├── batch-run/ # /rite:batch-run (複数 Issue 順次 open→iterate; --merge で ready→merge→cleanup まで)
│ ├── pr-create/ # /rite:pr-create (draft PR 作成) — sub-skill
│ # --- Issue 管理 ---
│ ├── issue-create/ # /rite:issue-create (+ references/: complexity-gate / contract-section-mapping / slug-generation)
│ ├── issue-list/ # /rite:issue-list
│ ├── issue-update/ # /rite:issue-update
│ ├── issue-close/ # /rite:issue-close
│ ├── issue-edit/ # /rite:issue-edit
│ ├── issue-implement/ # /rite:issue-implement (sub-skill, /rite:open から呼出)
│ # --- Wiki ---
│ ├── wiki-init/ # /rite:wiki-init
│ ├── wiki-query/ # /rite:wiki-query
│ ├── wiki-ingest/ # /rite:wiki-ingest (+ references/wiki-troubleshooting.md)
│ ├── wiki-lint/ # /rite:wiki-lint (+ references/: broken-ref-resolution / bash-cross-boundary-state-transfer)
│ # --- meta / top-level ---
│ ├── setup/ # /rite:setup (+ --upgrade)
│ ├── getting-started/ # /rite:getting-started
│ ├── workflow/ # /rite:workflow (rite ワークフロー全体ガイド)
│ ├── unknowns/ # /rite:unknowns (実装前探索: ブラインドスポット/ブレスト/プロトタイプ/インタビュー; + references/feedback-mode.html)
│ ├── investigate/ # /rite:investigate (構造化コード調査)
│ ├── learn/ # /rite:learn (Socratic 理解度チェック)
│ ├── lint/ # /rite:lint (品質チェック; orchestrator から呼ばれる sub-skill 兼用; + references/plugin-checks-rationale.md)
│ ├── recover/ # /rite:recover (中断した作業の再開)
│ ├── skill-suggest/ # /rite:skill-suggest
│ ├── template-reset/ # /rite:template-reset
│ # --- orchestration / knowledge (auto-discovered context) ---
│ ├── rite-workflow/ # state detection / phase routing / 共有コーディング原則 (SKILL.md + references/)
│ └── reviewers/ # reviewer 選定 + テーブル (+ references/; per-reviewer profile は agents/{type}-reviewer.md)
├── hooks/ # Claude Code lifecycle hooks + helpers
│ ├── hooks.json # Hook registration manifest
│ ├── session-start.sh / session-end.sh / session-ownership.sh
│ ├── pre-compact.sh / post-compact.sh
│ ├── pre-tool-bash-guard.sh / post-tool-wm-sync.sh
│ ├── stop-loop-continuation.sh # Stop hook: review↔fix loop continuation + terminal finalize
│ ├── hook-preamble.sh / state-path-resolve.sh / control-char-neutralize.sh # Shared helpers
│ ├── _resolve-session-id.sh / _resolve-session-id-from-file.sh # Private session-id resolution helpers
│ ├── _resolve-cross-session-guard.sh # Private legacy-state takeover classifier
│ ├── _validate-helpers.sh / _validate-state-root.sh / _mktemp-stderr-guard.sh # Private fail-fast validators
│ ├── flow-state.sh / local-wm-update.sh
│ ├── work-memory-lock.sh / work-memory-update.sh / work-memory-parse.py
│ ├── cleanup-work-memory.sh
│ ├── issue-claim.sh # Issue claim (同一 Issue 二重着手ガード、always-on)
│ ├── issue-body-safe-update.sh / issue-comment-wm-sync.sh / issue-comment-wm-update.py
│ ├── review-result-save.sh / review-comment-post.sh / review-skip-notification.sh # skills/pr-review/SKILL.md 6.1.a/b/c 委譲
│ ├── wiki-ingest-trigger.sh / wiki-query-inject.sh # Wiki auto-integration
│ ├── scripts/ # Helper scripts invoked by hooks
│ │ ├── wiki-ingest-commit.sh / wiki-worktree-commit.sh / wiki-worktree-setup.sh
│ │ ├── wiki-branch-init.sh / wiki-lint-skipped-refs.sh # inline bash 委譲
│ │ ├── wiki-lint-source-refs.sh # skills/wiki-lint/SKILL.md 6.2 委譲
│ │ ├── wiki-lint-stale.sh / wiki-lint-orphans.sh / wiki-lint-broken-refs.sh # skills/wiki-lint/SKILL.md 4/5/7 委譲
│ │ ├── wiki-growth-check.sh # lint layer-3
│ │ ├── wiki-ingest-lock.sh # /rite:wiki-ingest のセッション間直列化ロック
│ │ ├── backlink-format-check.sh / bang-backtick-check.sh
│ │ ├── bang-backtick-edit-hook.sh # PostToolUse wrapper for bang-backtick-check.sh (hooks.json 登録)
│ │ ├── bash-heaviness-check.sh # skills/**/*.md の heavy bash block 検出
│ │ ├── hardcoded-line-number-check.sh / comment-line-ref-check.sh # ハードコード行番号参照 lint (md / sh comment)
│ │ ├── comment-journal-check.sh / sh-cross-ref-check.sh # comment 規約 lint (journal 語法 / cross-file 参照)
│ │ ├── orphan-reference-check.sh # 未参照ファイル検出
│ │ ├── post-review-state-verify.sh / pr-cycle-cleanup.sh # reviewer 逸脱検出 / cycle worktree 掃除
│ │ ├── cleanup-worktree-detect.sh # cleanup.md ステップ 4-W の session-worktree 状態分類
│ │ ├── worktree-foreign-cwd.sh / worktree-live-cwd.sh # worktree cwd/liveness probe (cleanup / reap)
│ │ ├── rite-tmp-artifact.sh # 一時成果物 manifest 記録 (name 非依存 reap 用)
│ │ ├── review-schema-version-check.sh # review-result schema drift 検出
│ │ ├── settings-local-rite-hook-cleanup.sh / settings-local-rite-hook-cleanup.py # legacy hook entry 掃除 (.sh wrapper + .py 実体)
│ │ ├── reviewer-registry-drift-check.sh # lint Phase 3.5 reviewer registry 3-way 同期検証
│ │ ├── gitignore-health-check.sh
│ │ ├── projects-board-drift-check.sh # lint Phase 3.18 CLOSED+COMPLETED board≠Done 検出
│ │ ├── number-reference-check.sh # lint Phase 3.5 Issue/PR 番号参照 (#NNN) 検出 (CHANGELOG + lint.md)
│ │ ├── tmp-hardcode-check.sh # lint Phase 3.5 sandbox 非互換パターン (mktemp+/tmp テンプレート・/tmp 直書き・push の upstream -u) 検出
│ │ ├── lib/ # 共有ライブラリ (git-remote.sh / git-status-filtered.sh / wiki-config.sh / worktree-git.sh)
│ │ └── tests/ # hooks/scripts レベルのテストスイート
│ └── tests/ # Hook-level test suite (shell-based)
├── templates/
│ ├── README.md
│ ├── config/
│ │ └── rite-config.yml # Minimal default distributed by /rite:setup
│ # Note: templates/project-types/ (generic / webapp / library / cli / documentation .yml)
│ # was deleted together with the project.type preset feature retirement.
│ ├── issue/
│ │ ├── default.md / decomposition-spec.md
│ │ ├── interview-perspectives.md / template-structure.md
│ ├── pr/
│ │ └── generic.md # Generic PR template (used for all project types)
│ ├── review/
│ │ └── reply.md # Why-only PR review reply SoT
│ └── wiki/
│ ├── index-template.md / log-template.md
│ ├── page-template.md / schema-template.md
├── scripts/ # Projects integration / Sub-Issue / review metrics
│ ├── create-issue-with-projects.sh
│ ├── check-no-direct-gh-issue-create.sh # 直接 `gh issue create` 禁止の static guard
│ ├── decompose-issues.sh # 親 + Sub-Issues 一括作成
│ ├── backfill-sub-issues.sh / link-sub-issue.sh
│ ├── projects-status-update.sh / projects-items-fetch.sh
│ ├── review-findings-maps.sh # fix.md severity_map build 委譲
│ ├── review-source-resolve.sh # fix.md 1.2.0 review source Priority chain 解決
│ ├── migrate-review-state-to-1.1.sh # review-result schema 1.1.0 移行
│ ├── watchdog-status-mismatch.sh # Projects Status 不整合 watchdog
│ └── tests/ # Script-level test suite
└── references/ # Cross-cutting references used by skills
  ├── gh-cli-patterns.md / gh-cli-error-catalog.md
  ├── graphql-helpers.md / projects-integration.md
  ├── severity-levels.md / epic-detection.md
  ├── review-result-schema.md / investigation-protocol.md
  ├── wiki-patterns.md
  ├── bash-compat-guard.md / bash-defensive-patterns.md / bash-trap-patterns.md
  ├── sub-issue-link-handler.md / issue-create-with-projects.md
  ├── execution-metrics.md
  ├── plugin-path-resolution.md / git-worktree-patterns.md
  ├── common-error-handling.md
  ├── box-display-width.md # 罫線 box の表示幅ルール (SoT)
  ├── session-id-validation-contract.md # Session ID validation contract (SoT)
  ├── state-read-evolution.md # state-read.sh の変遷史 (rationale 保存)
  ├── stop-loop-continuation-contract.md # Stop hook handoff 機構の解説 SoT (iterate/pr-review/fix/cleanup/ready から参照)
  └── bottleneck-detection.md
  # Note: references/i18n-usage.md and plugins/rite/i18n/ directory (ja.yml,
  # en.yml, and the ja/ + en/ split files) were deleted entirely —
  # see the ## ~~Internationalization~~ (Retired) section below.
```

### plugin.json

Plugin metadata file format:

```json
{
 "name": "rite",
 "version": "0.9.2",
 "description": "Universal Issue-driven development workflow for Claude Code",
 "author": { "name": "asakaguchi" },
 "license": "MIT"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Plugin name (used as command prefix) |
| `version` | Yes | Semantic version |
| `description` | Yes | Short description |
| `author` | Yes | Author object with `name` field |
| `license` | No | License identifier |

### Skill File Format

rite の全機能はスキル (`skills/<name>/SKILL.md`) として実装される（旧 `commands/` は v0.7 で全廃）。各スキルは薄い SKILL.md + 同梱 `references/` で構成し、`/rite:<name>` で起動する。

**スキル行数原則**: 入口スキルの SKILL.md は 500 行未満に保つ。実行手順書スキル（pr-review / fix / lint / setup など bash 実行ブロックを本体に持つもの）は 4,000 行以内を上限とし、rationale（設計理由・背景解説）は SKILL.md 本体に書かず同梱 references/ へ退避して該当箇所に 1 行ポインタ（`rationale: references/<file>.md#<anchor>`）を残す。実行時に必要な情報（分岐表・sentinel 表・エラー処理指示・reason 表）は本体に維持する。

SKILL.md は YAML frontmatter を持つ:

```markdown
---
name: <name>                        # ディレクトリ名と一致。起動は /rite:<name>
description: |
 狭く具体的な説明 + auto-activation 条件（汎用トリガ語を誘発語にしない）
argument-hint: "<arg-hint>"         # user-invocable スキル（無引数でも ""）+ 引数を取る純 sub-skill。Read 専用 coordinator/knowledge は不要
# user-invocable: false             # Skill ツール経由で呼ばれる純 sub-skill のみ（メニュー非表示。Read 専用の knowledge/coordinator は下記ポリシー表の第3区分を参照）
---

# /rite:<name>

Skill documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | スキル識別子（= ディレクトリ名、`/rite:<name>` で起動） |
| `description` | Yes | auto-activation 条件を含む狭い説明。汎用トリガ語（workflow / PR / review / commit / branch / next steps 等）を誘発語として書かない |
| `argument-hint` | 条件付き | user-invocable スキル（`/rite:<name>` を持つもの。**無引数でも `""` を付ける**）と、Skill ツールで引数を受け取る純 sub-skill（pr-review / fix / pr-create / issue-implement）に付与する。スラッシュコマンドを持たず引数も取らない Read 専用 coordinator / knowledge skill（reviewers / rite-workflow）は autocomplete・引数受け渡しのいずれにも該当しないため付与しない |
| `disable-model-invocation` | **使用しない** | user-invocable スキルには使用しない方針。Claude Code CLI 側でユーザーが明示的にタイプしたスラッシュコマンドとモデル自身の Skill ツール呼び出しが同一経路を通り区別されない既知の挙動があり（[anthropics/claude-code#43660](https://github.com/anthropics/claude-code/issues/43660) 等）、`true` を付けるとユーザー直叩きも巻き添えで遮断されうる。auto-activate 抑止は narrow description のみで担保する（例外: 下記ポリシー表第3区分の Read 専用 knowledge/coordinator は `user-invocable: false` 併用を条件に許容） |
| `user-invocable` | No | `false` = メニュー非表示（純 sub-skill のほか、下記ポリシー表第3区分の Read 専用 knowledge/coordinator も併用） |

**frontmatter ポリシー（区分ごと）:**

| 区分 | 例 | frontmatter |
|------|----|-------------|
| user-invocable（`/rite:<name>` でユーザーが起動。orchestrator 到達の有無を問わない） | open / iterate / ready / merge / cleanup / lint / wiki-ingest / issue-create / wiki-init / learn / skill-suggest 等 | ナロー description のみ（`disable-model-invocation` は使用しない） |
| 純 sub-skill（user は直接起動しない） | pr-review / fix / pr-create / issue-implement | `user-invocable: false`（orchestrator が Skill ツールで programmatic invoke するため `disable-model-invocation` は**付けない** — 付けると programmatic invoke まで巻き添え遮断されうる #1693。auto-activate 抑止は narrow description で担保する） |
| Read 経由のみ到達する knowledge/coordinator（`/rite:<name>` を持たず、他スキルから `Read` で参照されるのみ） | reviewers（coordinator）/ rite-workflow（knowledge） | 両者とも narrow（否定形）description + `user-invocable: false`（ユーザーが直接起動できる `/rite:<name>` 自体を無くすため、`disable-model-invocation` によるユーザー直叩き巻き添え遮断の問題は起きない。Skill ツール経由の orchestrator 呼び出しの有無は本区分の判断根拠ではない）。`disable-model-invocation: true` は **reviewers のみ** 防御的に併用する（description が reviewer 選定という review 隣接ドメインを説明するため、auto-activate を二重に抑止する保険。`user-invocable: false` ゆえ巻き添え遮断リスクはない）。rite-workflow は narrow 否定形 description のみで auto-activate 抑止に足りるため併用しない（区分1 と同じ判断） |

**Skill Classification:**

| Classification | Purpose | Example |
|----------------|---------|---------|
| Reference Contents | Always-available knowledge | `rite-workflow` (workflow rules) |
| Task Contents | Active execution tasks | `reviewers` (review criteria) |

**`context: fork` について:** rite スキルは `context: fork` を使わない。forked（isolated）実行はスキル自身の出力をユーザーへ inline で返さず harness control wrapper のみが surface するため。read-only スキル (`/rite:issue-list` / `/rite:investigate` / `/rite:workflow` / `/rite:skill-suggest`) も #1554 で fork を解除済み。

### Agent File Format

Agent files (`agents/*.md`) define subagents for specialized tasks:

```markdown
---
name: agent-name
description: Short purpose description
model: opus # opus | sonnet | haiku (optional; omit to inherit from parent session)
---

# Agent Name

Agent documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique agent identifier |
| `description` | Yes | Short description for Task tool |
| `model` | No | Model selection (default: inherit from parent session) |
| `tools` | No | List of available tools (default: inherit all tools from parent; omit to enable all tools) |

**Note on `tools`**: Reviewer agents are invoked via named subagents (`rite:{reviewer_type}-reviewer`, e.g. `rite:security-reviewer`), introduced in v0.3. The previous `subagent_type: general-purpose` invocation is no longer used. Under named subagent invocation, both `model` and `tools` frontmatter are honored by the runtime. The `tools` field is optional — reviewer agents omit it to inherit all parent-session tools by default. 7 of the 9 reviewers are pinned to `model: opus`; users can override per-agent frontmatter to opt out.

**Current Agents:**

| Agent | Model | Purpose |
|-------|-------|---------|
| `security-reviewer` | opus | Security vulnerabilities, authentication, data handling |
| `application-reviewer` | opus | Application code end-to-end: API/type contracts, performance (N+1, indexes), data operations/migrations, UI safety (XSS, accessibility) |
| `code-quality-reviewer` | inherit | Duplication, naming, error handling, structure |
| `devops-reviewer` | opus | Infrastructure, CI/CD pipelines, deployment configurations |
| `test-reviewer` | opus | Test quality, coverage, testing strategies |
| `dependencies-reviewer` | opus | Package dependencies, versions, supply chain security |
| `prompt-engineer-reviewer` | opus | Claude Code skill, command, and agent definitions |
| `tech-writer-reviewer` | opus | Documentation clarity, accuracy, completeness |
| `error-handling-reviewer` | inherit | Error handling patterns, silent failures, recovery logic |

---

## Configuration File Specification

### rite-config.yml

Place in project root or `.claude/` directory. Uses YAML format for readability and comment support.

Full schema reference lives in **[docs/CONFIGURATION.md](./CONFIGURATION.md)**, which is kept in sync with `plugins/rite/templates/config/rite-config.yml` — the minimal default that `/rite:setup` distributes. The template intentionally omits advanced keys; enable them by copying the key declarations from CONFIGURATION.md as needed.

**Top-level sections** (see CONFIGURATION.md for per-key details):

| Section | Purpose |
|---------|---------|
| ~~`project.type`~~ | **DEPRECATED** — Removed entirely; project-specific configuration is now expressed via per-key YAML directly. See CONFIGURATION.md project section for deprecation note |
| `github.projects.*` | GitHub Projects integration (`field_ids`, `fields`, `project_number`, `owner`) |
| `branch.*` | `base`, `pattern`, `recognized_patterns` |
| `commands.{build,test,lint}` | Build/test/lint auto-detection overrides |
| `issue.auto_decompose_threshold` | Threshold for skipping the decomposition prompt |
| `review.*` | `loop.*` (convergence_monitoring / auto_propagation_scan / pre_commit_drift_check), `doc_heavy.*`, `fact_check.*` (incl. `use_context7`), `debate.*`, `security_reviewer.*`, `confidence_threshold`. **DEPRECATED**: `observed_likelihood_gate.*` / `fail_fast_first.*` were removed entirely — see CONFIGURATION.md for the deprecation note. The `separate_issue_creation.*` keys were removed entirely along with the `[fix:issues-created:N]` sentinel and `fix.md` Phase 4.3 |
| `fix.*` | **DEPRECATED**: `severity_gating.*` and `fail_fast_response` were removed entirely (no config surface remains) |
| `verification.*` | `run_tests_before_pr`, `acceptance_criteria_check` |
| `tdd.*` | Canon TDD cycle in the implementation phase — `enabled` (default `true`, opt-out). When on, `/rite:issue-implement` (§ 5.0.T) drives a test-list → Red → Green → Refactor cycle seeded from the Issue's Section 6 Test Specification; degrades to test-list discipline only when `commands.test` is unset, and is skipped entirely when `enabled: false`. See [CONFIGURATION.md](./CONFIGURATION.md) `### tdd` |
| `parallel.*` | Parallel implementation (per-Issue sub-agent fan-out within one session) |
| `multi_session.*` | Per-session Git worktree isolation — `enabled` (default `true`; set `false` to opt out), `worktree_base` (default `.rite/worktrees`). A **separate axis** from `parallel.*` (per-Issue sub-agent fan-out within one session); the two are not merged. See [docs/designs/multi-session-worktree.md](./designs/multi-session-worktree.md) |
| `iteration.*` | GitHub Projects Iteration field integration |
| `safety.*` | Fail-closed thresholds (`max_implementation_rounds`, `time_budget_minutes`, etc.) |
| `pr_review.post_comment` | PR review output destination |
| `wiki.*` | Experience Wiki — `enabled` (opt-out), `branch_strategy`, `auto_ingest`, `auto_query`, `auto_lint`, `growth_check.*` |
| `metrics.*` | Execution metrics recording |
| `language` | `auto` / `ja` / `en` |

**Migration**: `schema_version` (currently `2`) is bumped when breaking schema changes ship. `/rite:setup --upgrade` performs a non-destructive merge for compatible upgrades; removed keys are silently ignored at runtime — see the [CHANGELOG](../CHANGELOG.md) for the current deprecation set (v0.4.0 removed `review.loop.severity_gating_cycle_threshold`, `review.loop.scope_lock_cycle_threshold`, and `safety.max_review_fix_loops`).

### Schema Version Overview

rite workflow has **3 independently-versioned schemas that are commonly conflated** (their version numbers look similar and drift independently). Each bumps on its own timeline when its own schema changes; a bump in one does not imply or require a bump in another — do not conflate them. (Other artifacts also carry their own `schema_version` — e.g. the work-memory local file and the issue-claim JSON, both currently `1` — but their numbering is not easily confused with the 3 below, so they are out of scope for this table.)

| Schema | `schema_version` | Format | Defined At |
|--------|-------------------|--------|------------|
| `rite-config.yml` | `2` | integer | This section, above; template at `plugins/rite/templates/config/rite-config.yml` |
| Flow state (per-session) | `3` | integer | [Multi-Session State Management](#multi-session-state-management) below; `plugins/rite/hooks/flow-state.sh` |
| Review-result JSON | `1.1.0` | semver | [`review-result-schema.md` Schema Version (SoT)](../plugins/rite/references/review-result-schema.md#schema-version-sot) |

---

## Command Specifications

### /rite:setup

**Description:** Initial setup of rite workflow for a project

**Arguments:** `[--upgrade]` (optional)

| Argument | Description |
|----------|-------------|
| (none) | Run fresh setup (executes Phases 1–5 sequentially) |
| `--upgrade` | Upgrade the schema of an existing `rite-config.yml` to the latest version (skips Phases 1–3 and 5, and executes Phase 4.1.3; Phase 4.1.3 invokes Phase 4.7 (Wiki initialization) at its Step 7, so the effective execution is Phase 4.1.3 + Phase 4.7) |

**Process Flow:**

#### Phase 1: Environment Check
1. Verify gh CLI installation
2. Check GitHub authentication status
3. Get repository information

#### ~~Phase 2: Project Type Detection~~ (Removed)

> **Status: Removed**. The `project.type` preset feature and the Phase 2 auto-detection logic (`package.json` + frontend framework → webapp, etc.) were removed entirely. `/rite:setup` no longer performs project type detection; project-specific configuration is expressed via per-key YAML directly. The original detection rules below are preserved as historical reference only.

(Historical rules — no longer executed:
- `package.json` + frontend framework → webapp
- `package.json` + `main`/`exports` → library
- `pyproject.toml` + `[project.scripts]` → cli
- SSG config file → documentation
- Other → generic
followed by AskUserQuestion confirmation)

#### Phase 3: GitHub Projects Setup
1. Detect existing Projects
2. Present options:
 - Link to existing Projects
 - Create new Projects
3. Link the Project to the repository (`gh project link`, idempotent, non-blocking on failure)
4. Auto-configure fields

#### Phase 4: Template Generation
1. Check `.github/ISSUE_TEMPLATE/`
 - Recognize if exists
 - Auto-generate if not
2. Generate `rite-config.yml`
3. If an existing `rite-config.yml` is present, check its `schema_version`; if out of date, display guidance to run `/rite:setup --upgrade`

#### Phase 5: Completion Report
1. Display settings summary
2. Guide next steps

---

#### --upgrade Option (Existing Configuration Schema Upgrade)

**Purpose:** Bring an existing project's `rite-config.yml` up to the latest schema while preserving user-customized values (`project_number`, `owner`, `branch.base`, `language`, and so on). On the schema-upgrade path (`current < latest`) the upgrade applies the additions (new sections), removals (deprecated keys), and `schema_version` bump in a single confirmed batch; when the schema is already current (`current >= latest`) it instead back-adds any missing active-section / sub-key / `multi_session` / `wiki:` drift without a confirmation prompt (see Phase 4.1.3 below).

**When to use:**

- When a warning that `rite-config.yml` schema is outdated appears after upgrading the rite workflow plugin and running `/rite:setup` or starting a session. The exact Japanese message emitted by `/rite:setup` is: `rite-config.yml のスキーマが古くなっています (v{current} → v{latest})。/rite:setup --upgrade でアップグレードできます。` The session-start hook emits a slightly different variant ending in `/rite:setup --upgrade を実行してください。` ("run `/rite:setup --upgrade`")
- When release notes (`CHANGELOG.md`) announce new configuration sections (e.g., `wiki:`, `review.debate:`) that are missing from your local `rite-config.yml`
- When the `schema_version` at the top of your `rite-config.yml` diverges from the `schema_version` in the bundled template (`plugins/rite/templates/config/rite-config.yml`)

**Example:**

```bash
/rite:setup --upgrade
```

**Phase 4.1.3 Behavior (runs only with `--upgrade`):**

1. **Read current config and compare versions**
 Read `schema_version` from both the existing `rite-config.yml` and the bundled template. Missing values are treated as v1.
2. **Create a backup**
 Copy the existing file to `rite-config.yml.bak.YYYYMMDD-HHMMSS` for rollback.
3. **Branching**
 - `current < latest`: Run Step 4–6 (identify changes → preview → apply after approval), then Step 7 (Phase 4.7 Wiki initialization).
 - `current >= latest`: Run Step 4 (identify drift only) → Step 6 (back-add any missing `multi_session` section, newly added active top-level sections, missing sub-keys, and the `wiki:` section — preserving all user-customized values, idempotent, applied without a preview/confirmation prompt), then Step 7. The schema is already current, but the template can gain active sections/sub-keys without a schema bump; this path follows that drift. When nothing is missing, the config is left unchanged and "configuration is up to date" is displayed; Phase 4.7 still runs (idempotent — no-op if Wiki is already initialized).
4. **Identify and classify changes** (Step 4, runs on both paths; on the `current >= latest` short-circuit path only the drift back-add items — missing `multi_session` / active sections / sub-keys / `wiki:` — are identified)
 Each key is classified as one of:
 - **User-customized value** (preserve): `project_number`, `owner`, `iteration` settings, `branch.base`, `language`, etc.
 - **Deprecated key** (remove): `project.name`, `commit.style`, `commit.enforce`, `commit.contextual`, `branch.release`, `branch.types`, `version`
 - **Missing section** (add with template defaults): `review.debate`, `review.fact_check`, `verification`, etc.
 - **Advanced section** (add as commented-out block): `parallel`, `metrics`, `investigate`
 - **Unknown key** (preserve with warning): user-added keys not present in the template
5. **Preview and confirm** (Step 5)
 Display deprecated keys to be removed, sections to be added, and preserved existing settings; ask via `AskUserQuestion` to either apply or cancel.
6. **Apply** (Step 6)
 On the `current < latest` path, after approval, update `schema_version` to the latest value, remove deprecated keys, add missing sections (including commented-out Advanced sections), and append the `wiki:` section if it was absent. On the `current >= latest` short-circuit path (no preview), apply only the idempotent drift back-add items — missing `multi_session` / active sections / sub-keys / `wiki:` — without confirmation. All user-customized values (including an explicit `enabled: false`) are preserved on both paths.
7. **Run Phase 4.7 (Wiki initialization)** (Step 7)
 Invoke Phase 4.7 to bring existing users up to the Wiki-initialized state. If Wiki is already initialized, the phase is an idempotent no-op. Phase 4.7 is non-blocking: its failure does not affect `--upgrade` success. A final Wiki status line is displayed before the command exits.

**Relationship with `schema_version`:**

- The `schema_version` key at the top of `rite-config.yml` is an integer that identifies the configuration schema version (e.g., `schema_version: 2`). It is incremented whenever the rite workflow introduces a backward-incompatible schema change.
- `--upgrade` compares the `schema_version` in the current file against the one in the bundled template. When the current file is behind it runs the full Step 4–6 flow (preview + confirm); when the schema is already current it still runs the `current >= latest` short-circuit to back-add any active-section / sub-key / `multi_session` / `wiki:` drift the template introduced without a schema bump.
- Configuration files without a `schema_version` key are implicitly treated as v1 and can be brought up to date via `--upgrade`.

**Relationship with Phase 5 (new-install completion report):**

- `--upgrade` skips Phases 1–3 and the Phase 5 new-install completion report; only the Wiki status line is displayed at the end.
- It does not merge with the fresh-install completion report (`--upgrade` is a dedicated path for updating existing configurations).

---

### /rite:issue-create

**Description:** Create new Issue and add to GitHub Projects

**Arguments:** `<Issue title or work description>` (required)

#### Phase 0: Input Analysis

1. Extract from user input:
 - **What:** What to do
 - **Why:** Why it's needed
 - **Where:** What to change
 - **Scope:** Impact range
 - **Constraints:** Limitations

2. Detect ambiguous expressions

3. Search similar Issues for context

4. Clarify with `AskUserQuestion` if needed

5. Deep-dive interview (Phase 0.5) for implementation details

#### Phase 0.6-0.9: Task Decomposition (Conditional)

**Trigger Conditions:**
- Preliminary complexity is XL
- AND contains inclusive expressions like "build ~ system", "create ~ platform", "implement ~ infrastructure"
 - Simple expressions like "add ~ feature", "fix ~" are excluded

**Decomposition Flow:**

1. **Phase 0.6**: Decomposition trigger detection
 - If conditions are met, propose decomposition to user

2. **Phase 0.7**: Specification document generation
 - Apply Assumption Surfacing (see Phase 1.5) before generating the design document
 - Generate design document based on deep-dive interview results
 - Save to `docs/designs/{slug}.md`

3. **Phase 0.8**: Sub-Issue decomposition
 - Extract Sub-Issue candidates from specification
 - Analyze dependencies and propose implementation order

4. **Phase 0.9**: Bulk Sub-Issue creation
 - Create parent Issue and Sub-Issues
 - Set parent-child relationship via Tasklist format
 - Use GitHub Sub-Issues API (beta) if available

**Sub-Issue Granularity:**
- Each Sub-Issue should be 1 Issue = 1 PR in size
- Estimated complexity: S-L (split to avoid XL)
- Can be completed independently

#### Phase 1: Classification

**Complexity Estimation:**

| Complexity | Criteria |
|------------|----------|
| XS | Single line change, typo fix |
| S | Single file content update |
| M | Multiple files (up to 5) |
| L | Multiple files (10+), requires judgment |
| XL | Large-scale changes, design decisions |

#### Phase 1.5: Assumption Surfacing

Before Confirmation & Creation, surface the assumptions the model implicitly filled in and process them in three categories. This keeps implicit guesses from being silently locked into the Implementation Contract that drives the entire downstream pipeline (`open` → implementation → multi-reviewer → iterate); surfacing them at creation time reduces a downstream drift to a single review comment.

**Design principle**: Questions are limited to information that exists only in the user's head (user-specific decisions). Information derivable from the repository or Wiki is resolved by the model through exploration — never asked.

1. **Enumerate** the assumptions required for the Contract but not stated in the input (target file paths, naming conventions, conformance to existing patterns, backward-compatibility policy, error behavior, …).
2. **Blind spot pass** (M and above only, skipped for XS/S): actively probe for unknown unknowns via two questions — what adjacent areas not touched by this Issue could break from this change, and what existing constraints/conventions/heuristics might the user be unaware of. Findings merge into the same three categories below (no separate output format).
3. **Classify** each assumption (including blind-spot findings):
   - **(a) derivable** → self-resolve via repository/Wiki exploration (no question).
   - **(b) user-specific decision** → confirm via `AskUserQuestion`; each option carries a recommended choice.
   - **(c) deferrable** → document under Section 1 "Assumptions / Open Questions" in the Issue body.
4. **Wiki cross-check** (SHOULD): match the draft Contract against `wiki-query` results and surface contradictions as assumptions. Silently skipped when the Wiki is opt-out or uninitialized.

**Question intensity** follows the anticipated Complexity (Phase 1): XS/S → 0–1 question; M and above → at most 3. When more than three (b) items are found (original assumptions + blind-spot findings combined), the highest-impact three are asked and the remainder move to (c). The same surfacing also applies to the L/XL decomposition path (Phase 0.6-0.9), where it runs inside the specification-document generation step (Phase 0.7) before the design document is written.

#### Phase 2: Confirmation & Creation

1. Create Issue with `gh issue create`
2. Add to Projects with `gh project item-add`
3. Set fields (Status/Priority/Complexity/Work Type)

---

### /rite:issue-start (Retired)

> **Status**: Decomposed into four single-responsibility commands. The 783-line `commands/issue/start.md` orchestrator was deleted; the live specification now lives in `/rite:open` / `/rite:iterate` / `/rite:ready` / `/rite:merge`. This section is preserved as a migration anchor so that the historical Phase numbering (Phase 0 / 1 / 1.5 / 1.6 / 2 / 3 / 4 / 5) can still be traced when reading older PRs, design docs, and CHANGELOG entries.

**Mapping from old phases to new commands:**

| Old Phase (start.md) | New command + step |
|----------------------|--------------------|
| Phase 0 (Epic / Sub-Issues detection) | `/rite:open` Step 1 (Issue fetch + parent detection) |
| Phase 1 (Issue quality verification) | `/rite:open` Step 1.3 |
| Phase 1.5 / 1.6 (Parent routing / Child selection) | `/rite:open` Step 1.2 |
| Phase 2 (Branch creation, Projects Status, Iteration) | `/rite:open` Step 2 |
| Phase 3 (Implementation planning) | `/rite:open` Step 3 |
| Phase 4 (Guidance / "Work later" pause) | Removed — `/rite:open` always proceeds to implementation |
| Phase 5.1 (Implementation work) | `/rite:open` Step 4 → delegates to `/rite:issue-implement` |
| Phase 5.2 (Quality checks) | `/rite:open` Step 5 (`/rite:issue-implement` autonomously invokes `/rite:lint`) |
| Phase 5.3 (Draft PR creation) | `/rite:open` Step 6 (invokes `/rite:pr-create` sub-skill) |
| Phase 5.4 / 5.5 (Review + fix loop) | `/rite:iterate <pr>` (loops `/rite:pr-review` ⇄ `/rite:fix` until convergence, bounded by a `safety.max_review_cycles` circuit breaker) |
| Phase 5.6 (Completion report — formerly the last sub-step of Phase 5) | `/rite:ready <pr>` (Set Ready) + `/rite:merge <pr>` (Merge) — split into two responsibility-isolated commands. Historically `start.md` reached completion at Phase 5.6 and then ran `gh pr merge --squash` inline as ステップ 8 of the orchestrator |
| Phase 6 (Cleanup) | `/rite:cleanup <pr>` (unchanged, decoupled from merge) |

The four new commands maintain the same flow-state phases (`init` / `branch` / `plan` / `implement` / `lint` / `pr` / `review` / `fix` / `ready` / `ready_error` / `cleanup` / `ingest` / `completed` — `PHASE_ENUM_V3` SoT in `hooks/flow-state.sh`), so `/rite:recover` can recover from interruptions regardless of which command was running. See [skills/recover/SKILL.md](../plugins/rite/skills/recover/SKILL.md) Phase 5.3 (Phase enum → Step mapping (SoT)) for the routing table.

> **Historical Phase Description (pre-decomposition)**: The remainder of this section describes the previous `start.md` orchestrator's Phase 0 / 1 / 1.5 / 1.6 / 2 / 3 / 4 / 5 internals. Use it only for archaeological / migration cross-reference; the live specification is in the new pr/ commands above.

#### Phase 0: Epic/Sub-issues Detection

Uses GitHub standard features:
- Recognize Milestone feature
- Recognize Sub-issues (beta) if available
- List child Issues and prompt user selection

**Parent Issue Status Synchronization:**

When working on a child Issue, the parent Issue's status is automatically synchronized:

| Trigger | Parent Issue Status Update |
|---------|---------------------------|
| First child Issue becomes In Progress | Parent Issue → In Progress |
| All child Issues become Done | Parent Issue → Done |
| Some completed, some pending | Parent Issue stays In Progress |

This ensures the parent Issue accurately reflects the overall progress of its child Issues.

#### Phase 1: Issue Quality Verification

**Quality Score:**

| Score | Criteria |
|-------|----------|
| A | All items clear |
| B | Main items clear, some inferable |
| C | Basic info only, needs completion |
| D | Insufficient info, must complete before starting |

For C/D scores:
1. Attempt auto-completion
2. Ask user with `AskUserQuestion` if unable

#### Phase 1.5: Parent Issue Routing

Detects whether the target Issue is a parent (epic) Issue via:
1. `trackedIssues` API (GraphQL)
2. Body tasklist (`- [ ] #XX`)
3. Labels (`epic`/`parent`/`umbrella`)

If the Issue is a parent, routing logic determines the appropriate action: work on the parent directly, select a child Issue, or decompose into sub-Issues.

#### Phase 1.6: Child Issue Selection

When a parent Issue is detected, automatically selects the most appropriate child Issue to work on based on:
- Priority and dependency ordering
- Current status (skip completed/in-progress children)
- User confirmation before proceeding

#### Phase 2: Work Preparation

1. Generate branch name (per config pattern)
2. Check for existing branch (including recognized patterns from `branch.recognized_patterns` config)
3. Create branch with `git checkout -b`
4. Update GitHub Projects Status to "In Progress"
5. Assign to current Iteration (if `iteration.enabled: true` and `iteration.auto_assign: true`)
6. Initialize work memory comment

##### Phase 2.2.1: Recognized Branch Patterns

If `branch.recognized_patterns` is configured in rite-config.yml, detect existing non-Issue-numbered branches matching those patterns. When matched, the user can choose to use the existing branch or create a standard-pattern branch.

##### Phase 2.5: Iteration Assignment (Optional)

When `iteration.enabled: true` and `iteration.auto_assign: true` in rite-config.yml, automatically assigns the Issue to the current active iteration in GitHub Projects.

**Work Memory Comment Format:**

Add a dedicated comment to Issue, update that same comment thereafter:

```markdown
## 📜 rite Work Memory

### Session Info
- **Started**: 2025-01-03T10:00:00+09:00
- **Branch**: feat/issue-123-add-feature
- **Last Updated**: 2025-01-03T10:00:00+09:00
- **Command**: rite:issue-start
- **Phase**: phase2
- **Phase Detail**: Branch creation & setup

### Progress
- [ ] Task 1
- [ ] Task 2

### Confirmation Items
<!-- Accumulate pending questions during work. Confirm collectively at session end -->
_No confirmation items_

### Changed Files
<!-- Auto-updated -->

### Decisions & Notes
<!-- Important decisions and findings -->

### Plan Deviation Log
<!-- Record when deviating from the implementation plan -->
_No plan deviations_

### Bottleneck Detection Log
<!-- Bottleneck detection → Oracle discovery → Re-decomposition history -->
_No bottlenecks detected_

### Review Response History
<!-- Auto-recorded during review response -->
_No review responses_

### Next Steps
1. ...
```

**Phase Information:**

The Session Info section of the work memory includes phase information indicating the current work state. This information is used by `/rite:recover` for resuming work.

**Flat workflow phase (current / 13 values — matches `PHASE_ENUM_V3` SoT in `hooks/flow-state.sh`):**

| Phase | Phase Detail | 4-command step (formerly start.md step pre-decomposition) |
|-------|--------------|----------------------------------------------------|
| `init` | Workflow initialised (Issue identified) | `/rite:open` Step 1 (formerly step 1) |
| `branch` | Branch created, ready for plan | `/rite:open` Step 2 (formerly step 2) |
| `plan` | Implementation planning in progress | `/rite:open` Step 3 (formerly step 3) |
| `implement` | Implementation in progress | `/rite:open` Step 4 (formerly step 4) |
| `lint` | Quality check in progress | `/rite:open` Step 5 (formerly step 5) |
| `pr` | PR creation in progress | `/rite:open` Step 6 (formerly step 6) |
| `review` | Review in progress | `/rite:iterate` review side (formerly step 7.1) |
| `fix` | Review-fix loop in progress | `/rite:iterate` fix side (formerly step 7.2) |
| `ready` | `/rite:ready` succeeded; awaiting Projects Status In Review → completion report | `/rite:ready` (formerly step 8.3) |
| `ready_error` | `/rite:ready` failed inside e2e flow; `/rite:recover` re-enters `/rite:ready` retry | `/rite:ready` retry (formerly step 8) |
| `cleanup` | `/rite:cleanup` in progress (branch / worktree cleanup pre-ingest) | `/rite:cleanup` Steps 1-3 |
| `ingest` | Wiki ingest in progress (post-cleanup `/rite:wiki-ingest` integration) | `/rite:cleanup` ステップ 9 → `/rite:wiki-ingest` |
| `completed` | Workflow finished | `/rite:merge` / `/rite:cleanup` completed (formerly step 8 end) |

Lifecycle sub-rings (legacy granular phases — lifecycle-incomplete detection now lives in `session-end.sh`'s inline glob; see the retired Phase Transition Whitelist note below):

| Ring | Phase values |
|------|--------------|
| `/rite:cleanup` | `cleanup` / `cleanup_pre_ingest` / `cleanup_post_ingest` / `cleanup_completed` |
| `/rite:wiki-ingest` | `ingest_pre_lint` / `ingest_post_lint` / `ingest_completed` |

**Legacy phase (forward-compat acceptance only — never newly written):**

Older state files may contain these names from the pre-flat sub-skill chain architecture. `skills/recover/SKILL.md` Phase 3.5 整合性判定 (cross-check) resolves them to v3 enum values, then Phase 5.3 (Phase enum → Step mapping (SoT)) maps them to flat step numbers.

| Phase | Phase Detail |
|-------|--------------|
| `phase0` | Epic/Sub-Issues detection |
| `phase1` | Quality verification |
| `phase1_5_parent` | Parent Issue routing |
| `phase1_6_child` | Child Issue selection |
| `phase2` | Branch creation & setup |
| `phase2_branch` | Branch creation in progress |
| `phase2_work_memory` | Work memory initialization |
| `phase5_implementation` / `phase5_lint` / `phase5_pr` / `phase5_review` / `phase5_fix` / `phase5_post_ready` | sub-skill chain working phases (mapped to `implement` / `lint` / `pr` / `review` / `fix` / `ready` respectively) |

#### Phase 3: Implementation Planning

1. Analyze Issue content and identify target files
2. Generate implementation plan
3. User confirmation: Approve / Modify / Skip

#### Phase 4: Guidance and Continuation

After preparation, user selects:
- **Start implementation (Recommended)**: Proceed to Phase 5 for end-to-end execution from implementation to PR creation and review
- **Work later** (Removed — pre-decomposition behavior): Pause here and resume later with `/rite:issue-start` (now `/rite:open <issue_number>` followed by `/rite:recover` to recover from any stop)

#### Phase 5: End-to-End Execution

Starts when "Start implementation" is selected. The following steps are executed **continuously without interruption**:

**Flow Continuation Principle:** After each step completes, proceed to the next step without waiting for user confirmation (except where confirmation is explicitly required).

| Step | Content | Called Command |
|------|---------|----------------|
| 5.1 | Implementation work (including commit & push) | - |
| 5.2 | Quality checks | `/rite:lint` |
| 5.3 | Draft PR creation | `/rite:pr-create` |
| 5.4 | Self review | `/rite:pr-review` |
| 5.5 | Continuation based on review results | `/rite:fix` (if needed) |
| 5.6 | Completion report | - |

**5.2 Quality Check Result Branching:**

| Result | Next Action |
|--------|-------------|
| Success | → Proceed to 5.3 |
| Warnings only | → Proceed to 5.3 |
| Errors found | Fix errors → Re-run 5.2 |
| Skipped | → Proceed to 5.3 (recorded in PR) |

**5.5 Review Result Branching:**

| Result | Next Action |
|--------|-------------|
| Approve | Confirm `/rite:ready` execution → Proceed to 5.6 |
| Approve with conditions | Fix with `/rite:fix` → Return to 5.4 |
| Request changes | Fix with `/rite:fix` → Return to 5.4 |

**Review-Fix Cycle Continuation:** The `/rite:pr-review` → `/rite:fix` → `/rite:pr-review` cycle continues automatically until the overall assessment is "Approve" (zero blocking findings). The normal exit is `[review:mergeable]` (all findings resolved). A `safety.max_review_cycles` circuit breaker (#1701, default 5) additionally bounds non-convergent loops: on reach, interactive `/rite:iterate` prompts via `AskUserQuestion` (continue/abort/leave-draft) and `/rite:batch-run` batch marks the Issue failed and advances to the next. There is no progressive relaxation.

**Verification mode** (`review.loop.verification_mode`, default: `false`): When explicitly enabled, from the second iteration onward, reviews perform both a full review and verification of previous fixes with incremental diff regression checks. New MEDIUM/LOW findings in unchanged code are reported as non-blocking "stability concerns". The default `false` performs full review every iteration, maximizing review quality.

**Definition of "Approve":** Zero blocking findings.

### Automatic Work Memory Updates

Work memory is automatically updated when executing the following commands:

| Command | Auto-Update Content |
|---------|---------------------|
| `/rite:open` | Initialize work memory, record implementation plan |
| `/rite:pr-create` | Record changed files, commit history, PR info |
| `/rite:iterate` / `/rite:fix` | Record review response history (fix history per cycle; a review⇄fix cycle counter with a `safety.max_review_cycles` circuit breaker exists (#1701); quality-signal escalation remains absent) |
| `/rite:cleanup` | Record completion info |
| `/rite:lint` | Record quality check results (conditional: only on issue branches) |

**Manual Update:**

`/rite:issue-update` remains available for manual updates when:
- Recording important design decisions
- Adding supplementary information
- Manually updating progress at specific timing
- Preparing handoff for next session

### Interruption and Resumption

If "Work later" is selected or work is interrupted:
- Branch and work memory are preserved
- Phase information (`Command`, `Phase`, `Phase Detail`) is recorded in work memory
- Use `/rite:recover` to resume work from the interrupted phase

**How to Resume:**

```
/rite:recover
```

Or specify Issue number:

```
/rite:recover <issue_number>
```

**Session Start Auto-Detection:**

When starting a session on a feature branch, the system automatically detects phase information from work memory and notifies if there is interrupted work.

**If PR Already Exists:**
- After detecting existing branch, check for PR existence
- If PR exists, option to continue review response with `/rite:fix`

**Note:** `/rite:pr-create` can also be used independently for:
- Resuming after interruption
- Creating PR from existing branch
- Creating PR without linked Issue

---

### /rite:pr-review

**Description:** Dynamic multi-reviewer PR review

**Arguments:** `[PR number or branch name]` (optional, defaults to current branch)

#### Parallel Subagent Review

`/rite:pr-review` uses Claude Code's Task tool to spawn parallel subagents for each reviewer role:

```
/rite:pr-review start
 ↓
Get changed files list
 ↓
Analyze files and select appropriate reviewers
 ↓
Spawn subagents in parallel (Task tool)
 ├─ security-reviewer: Security perspective
 ├─ application-reviewer: Application code perspective (API/type contracts, performance, data operations, UI safety)
 ├─ code-quality-reviewer: Code quality perspective
 ├─ devops-reviewer: DevOps perspective
 ├─ test-reviewer: Test quality perspective
 ├─ dependencies-reviewer: Dependencies perspective
 ├─ prompt-engineer-reviewer: Prompt quality perspective
 ├─ tech-writer-reviewer: Documentation perspective
 └─ error-handling-reviewer: Error handling perspective
 ↓
Collect results from each subagent
 ↓
Integrate results for overall assessment
 ↓
Output review results
```

**Benefits:**
- Improved context efficiency (each subagent has focused context)
- Parallel execution for faster reviews
- Specialized expertise per review area
- Automatic reviewer selection based on changed files

**Reviewer Selection:**

Reviewers are automatically selected based on file patterns and content analysis. Not all reviewers are invoked for every PR - only relevant ones are selected.

**Fallback:** If a subagent fails or times out, the review continues with remaining subagents, and the failure is noted in the summary.

See "[Dynamic Reviewer Generation](#dynamic-reviewer-generation)" section for additional details.

---

### /rite:fix

**Description:** Address review feedback on PR

**Arguments:** `[PR number]` (optional, defaults to current branch's PR)

#### Phase 1: Review Comment Retrieval

1. Identify PR (from argument or current branch)
2. Fetch review comments using GitHub API
3. Classify comments:
 - **Changes Requested**: From `CHANGES_REQUESTED` reviews or unresolved threads
 - **Suggestions/Questions**: Improvement proposals or unanswered questions
 - **Resolved**: Already resolved threads
4. Display organized list of unresolved comments

#### Phase 2: Response Support

For each unresolved comment:

1. Show comment details (file, line, content, reviewer)
2. Prompt user for response type:
 - Fix the code
 - Reply only (no changes needed)
 - Skip (address later)
3. If fixing code:
 - Read affected file
 - Suggest fix based on comment
 - Apply fix with Edit tool
4. Optionally create reply to reviewer

#### Phase 3: Fix Commit

1. Review all changes made
2. Generate commit message based on addressed comments
3. Commit changes with appropriate message
4. Optionally push to remote

#### Phase 4: Completion Report

1. Optionally resolve addressed threads (GraphQL mutation)
2. Optionally post summary comment on PR
3. Update work memory with fix history
4. Display completion summary with next steps

---

### /rite:cleanup

**Description:** Automate post-PR-merge cleanup tasks

**Arguments:** `[branch name]` (optional, defaults to current branch)

#### Phase 1: State Verification

1. Check current branch
2. Find related PR and verify merge status
3. Identify related Issue from PR body or branch name

**If PR is not merged:**
- Warn user about potential data loss
- Offer options: Cancel (recommended) or Force cleanup

#### Phase 2: Cleanup Execution

1. Switch to main branch
2. Update base (`git fetch` + `git merge --ff-only`)
3. Delete local branch (`git branch -d`)
4. Delete remote branch if exists (`git push origin --delete`)

**On uncommitted changes:**
- Offer to stash changes before cleanup

> **Worktree Mode (`multi_session.enabled: true`)**: When `/rite:cleanup` runs from inside a session worktree, Step 4-W first checks `git status --porcelain` (dirty → AskUserQuestion to stash or cancel), then `ExitWorktree(action: "keep")` back to the main checkout and `git worktree remove {path}` → `git worktree prune` (removal failure is non-blocking — deferred to the lazy reap). The local branch is deleted **only after** its worktree is removed (a checked-out branch cannot be deleted). The base update (step 2) is replaced by the **main-checkout inviolability** rule: it runs `git fetch origin {base} && git merge --ff-only origin/{base}` **only when the main checkout is on `{base}`**; on any other branch it WARNINGs and skips (with a "return the main checkout to `{base}`" recovery hint) rather than yanking a human's working branch. The Issue claim acquired by `/rite:open` Step 1.6 is released here. See [Multi-Session State Management → Worktree Mode](#worktree-mode-session-worktree-isolation). When `multi_session.enabled: false` (explicit opt-out, or a legacy config that omits the `multi_session` block), steps 1–4 above run unchanged.

#### Phase 3: Projects Status Update

1. Get Project configuration from `rite-config.yml`
2. Find Issue's Project item
3. Update Status to "Done"
4. Add completion record to work memory comment

#### Phase 4: Completion Report

```
Cleanup completed

PR: #{pr_number} - {pr_title}
Related Issue: #{issue_number}
Status: Done

Completed tasks:
- [x] Switched to main branch
- [x] Updated base (fetch + merge --ff-only)
- [x] Deleted local branch {branch_name}
- [x] Deleted remote branch
- [x] Updated Projects Status to Done
- [x] Finalized work memory

Next steps:
1. `/rite:issue-list` to check next Issue
2. `/rite:open <issue_number>` to start new work
```

---

## Iteration Management (Optional)

GitHub Projects Iteration field integration.

### Overview

- **Optional Feature**: Disabled by default (`iteration.enabled: false`)
- **Manual Setup**: Iteration field must be created manually in GitHub Web UI (gh CLI not supported)
- **Graceful Degradation**: Other features work normally when Iteration is disabled

### Feature Comparison

| Aspect | Iteration Disabled | Iteration Enabled |
|--------|-------------------|-------------------|
| Issue Creation | Status/Priority/Complexity fields | + Iteration assignment option |
| `/rite:open` | Branch creation, Status update | + Auto-assign to current iteration |
| Issue List | Filter by Status/Priority | + `--sprint` / `--backlog` filters |
| Progress Visibility | By Status only | + By iteration (via `/rite:issue-list` filters) |

### Configuration

```yaml
# rite-config.yml
iteration:
 enabled: false # Set true to enable
 field_name: "Sprint" # Iteration field name
 auto_assign: true # Auto-assign on /rite:open
 show_in_list: true # Show Iteration column in issue-list
```

### Iteration Support in Existing Commands

| Command | Iteration Feature |
|---------|-------------------|
| `/rite:setup` | Iteration field detection & setup guide |
| `/rite:open` | Auto-assign to current iteration when starting work |
| `/rite:issue-create` | Iteration assignment option on creation |
| `/rite:issue-list` | `--sprint current`, `--backlog` filters |

### Current Iteration Detection

```
1. Get today's date
2. For each iteration:
 - endDate = startDate + duration (days)
 - startDate <= today < endDate → "current"
3. No match → next iteration (or null)
```

### Technical Constraints

- **Iteration field auto-creation**: Not possible (gh CLI doesn't support ITERATION data type)
- **Iteration field operations**: Available via GraphQL API

---

## Hook Specification

### Supported Hook Types

> **Canonical SoT**: The authoritative list of registered hook events lives in [`plugins/rite/hooks/hooks.json`](../plugins/rite/hooks/hooks.json). This table mirrors that registration; if the two diverge, `hooks.json` wins. The table below is enumerated for reader convenience but MUST be regenerated from `hooks.json` keys (`jq '.hooks | keys[]' plugins/rite/hooks/hooks.json`) whenever the registration changes.

| Type | Timing | Purpose |
|------|--------|---------|
| SessionStart | Session start | Load work memory, detect interrupted work |
| PreCompact | Before compact | Save work memory, record compact state |
| PostCompact | After compact | Restore work memory, clean compact state |
| SessionEnd | Session end | Save final state |
| PreToolUse | Before tool execution | Block tool usage after compact, detect dangerous command patterns |
| PostToolUse | After tool execution | Auto-recover local work memory |
| Stop | Turn end | Re-inject the `/rite:iterate` review↔fix loop command or the `/rite:cleanup` wiki-chain continuation (`consume-handoff` → `decision:block`) so the loop / chain continues after a continuation sentinel |

> **Note:** The legacy stop-prevention hook (`stop-guard.sh`) has been removed; workflow stop prevention itself is now handled by the per-session state structure (`.rite/sessions/{session_id}.flow-state`) and the orchestrator-level scaffolding contract (Pre-write + 🚨 Mandatory After). A **distinct** `Stop` hook (`stop-loop-continuation.sh`) is registered for a different purpose: it consumes the one-shot `handoff` marker and re-injects the next review↔fix loop command, or — for the `WIKICHAIN:` prefix set by `/rite:cleanup` Step 9 — the continuation of the cleanup → wiki-ingest → wiki-lint chain. See the [Multi-Session State Management](#multi-session-state-management) section for details.

### Hook Execution Order

```
SessionStart
 ↓
PreToolUse → Tool Execution → PostToolUse
 ↓
Stop (on turn end — review↔fix loop / cleanup wiki-chain handoff continuation)
 ↓
PreCompact (on compact)
 ↓
SessionEnd
```

> **Note:** PreToolUse and PostToolUse fire on every Claude Code tool invocation. PreCommand/PostCommand have been deprecated and are not used by rite. (The former `preflight-check.sh` compact-blocking gate was removed in v0.7 along with `commands/`; compact recovery is now handled entirely by the SessionStart interruption notice + `/rite:recover` — see Post-Compact Recovery below.)

### Post-Compact Recovery (`post-compact.sh`)

Registered as a PostCompact hook. After a compact event, restores workflow context by outputting the current per-session flow state (`.rite/sessions/{session_id}.flow-state`) and work-memory state to stdout, which Claude Code injects into the model's context so the workflow can auto-continue without user intervention.

**Behavior:**

1. Reads the per-session compact-state (`.rite/sessions/{session_id}.compact-state`, derived from the resolved per-session flow-state path) and the per-session flow state file under the resolved state root (delegates resolution to `state-path-resolve.sh`; see [Multi-Session State Management](#multi-session-state-management))
2. If no flow state exists, cleans the per-session compact-state and exits 0 (self-healing for orphaned compact markers)
3. Otherwise, emits a recovery block to stdout containing Issue number, phase, and next-action hints so the orchestrator can resume from the compact boundary
4. Double-execution is guarded via `_RITE_HOOK_RUNNING_POSTCOMPACT` (hooks.json + legacy `settings.local.json` migration safety)

**Self-Healing Mechanism:**

If the workflow has ended but a per-session compact-state remains (e.g., due to crash), the hook cleans it up and exits silently so that a fresh session is not blocked. `session-start.sh` additionally reaps the legacy shared `.rite-compact-state` as a migration path for pre-per-session residue.

### Pre-Tool Bash Guard (`pre-tool-bash-guard.sh`)

Registered as a PreToolUse hook. Blocks known incorrect Bash command patterns that the LLM repeatedly generates before execution.

**Blocked Patterns:**

| Pattern | Reason | Alternative |
|---------|--------|-------------|
| `gh pr diff --stat` | `--stat` flag is unsupported | `gh pr view {n} --json files --jq '.files[]'` |
| `gh pr diff -- <path>` | File filter is unsupported | `gh pr diff {n} \| awk` for filtering |
| 「!= null」 (in jq/awk) | Bash history expansion interprets 「!」 | `select(.field)` or `select(.field == null \| not)` |
| Reviewer subagent: write into a `.git` dir (`> .git/…`, `tee`/`cp`/`dd of=` etc.) | Invisible to `git status`, irreversible, RCE via `.git/hooks` / `.git/config` | Read-only inspection (`cat .git/config`, `git config --list`) |
| Reviewer subagent: native `.git`-writing git subcommand (`git config <key> <val>`, mutating `git remote`, `git update-ref`, `git symbolic-ref`) | Writes `.git/config` / refs with no redirect for the write-detection to see; `git config core.hooksPath` is an RCE vector | Read forms stay allowed (`git config --list/--get`, `git remote -v`, `git rev-parse`) |
| Reviewer subagent: shell wrapper (`eval` / `sh -c` / `bash -c` …) | Opaque quoting can hide a `.git` write | Direct execution, subshell `( … )`, or `bash <script.sh>` |
| Reviewer subagent: oversized command (>64KB) | Parsing could exceed the hook timeout, which fails open | Simplify the command |

Reviewer working-tree git verbs (`checkout` / `reset` / `commit` / `branch` / …) are **not** machine-gated (Issue #1879): they are visible and recoverable via `git status`, so their guarantee is the reviewer prompt READ-ONLY contract (`_reviewer-base.md`, Layer 1) plus `post-review-state-verify.sh` drift detection (Layer 3).

**Heredoc Safety:**

To prevent false positives from text in heredocs (commit messages, PR descriptions, etc.), only the command portion before `<<` is inspected.

### Post-Tool WM Sync (`post-tool-wm-sync.sh`)

Registered as a PostToolUse hook. Automatically creates local work memory files when they are missing during an active workflow.

**Behavior:**

1. Fires after Bash tool usage (with recursion guard)
2. Retrieves active workflow and Issue number from the per-session flow state file (`.rite/sessions/{session_id}.flow-state`)
3. Only creates `.rite-work-memory/issue-{n}.md` if it doesn't exist

**Purpose:** Guarantees auto-recovery of local work memory during `/rite:recover` after compact or session restart.

### Local WM Update (`local-wm-update.sh`)

Standalone wrapper script for updating local work memory files. Automatically resolves the plugin root via `BASH_SOURCE`.

**Usage:**

```bash
WM_SOURCE="implement" WM_PHASE="lint" \
 WM_PHASE_DETAIL="Quality check prep" \
 WM_NEXT_ACTION="Run rite:lint" \
 WM_BODY_TEXT="Post-implementation." \
 WM_ISSUE_NUMBER="866" \
 bash plugins/rite/hooks/local-wm-update.sh
```

**Environment Variables:**

| Variable | Required | Description |
|----------|----------|-------------|
| `WM_SOURCE` | Yes | Update source identifier (`init`, `implement`, `lint`, etc.) |
| `WM_PHASE` | Yes | Current phase (`lint`, `implement`, `pr`, etc.; see `PHASE_ENUM_V3` in `flow-state.sh`) |
| `WM_PHASE_DETAIL` | Yes | Detailed phase description |
| `WM_NEXT_ACTION` | Yes | Next action |
| `WM_BODY_TEXT` | Yes | Update content text (summary area only — free-form content under `## Detail` is preserved across updates) |
| `WM_ISSUE_NUMBER` | Yes | Issue number |

### Work Memory Lock (`work-memory-lock.sh`)

Shared library script providing `mkdir`-based lock/unlock functionality. Used by sourcing from other scripts.

**Provided Functions:**

| Function | Description |
|----------|-------------|
| `acquire_wm_lock <lockdir> [timeout]` | Acquire lock (with timeout, default: 50 iterations × 100ms = 5 seconds) |
| `release_wm_lock <lockdir>` | Release lock |
| `is_wm_locked <lockdir>` | Check lock status |

**Stale Lock Detection:**

If a lock's `mtime` exceeds the threshold (default: 120 seconds), the PID file is checked to verify process liveness. Liveness compares the PID (`kill -0`) and, when a start-token was recorded, a process start-token, so an exited holder whose PID was later recycled by an unrelated process is detected as gone. If the process has terminated (or, when a start-token was recorded, its PID was reused), the lock is automatically released. Locks written by older versions (no token file) or on platforms lacking a start-token source stay conservatively held (legacy PID-only behavior).

### Phase Transition Whitelist (retired)

> **Status: Retired**. The `phase-transition-whitelist.sh` library (and its `phase-transition-whitelist.test.sh` suite) were removed in the v2→v3 migration. The canonical phase enum is now `PHASE_ENUM_V3` in `flow-state.sh` (`init branch plan implement lint pr review fix ready ready_error cleanup ingest completed`), validated by its `_phase_is_valid` helper; legacy phase names are resolved by `_phase_migrate` plus the `/rite:recover` cross-check rather than a transition graph.

Lifecycle-incomplete detection for the legacy `create_*` / `cleanup_*` phases now lives inline in `session-end.sh` (the `[[ "$_state_phase" == create_* ]]` / `cleanup_*` glob branches). The former `rite_phase_is_create_lifecycle_in_progress` / `rite_phase_is_cleanup_lifecycle_in_progress` predicates no longer exist, so the `type … >/dev/null` guard in that hook always falls through to the inline glob, which is the sole active path (pinned by `session-end.test.sh` TC-create-lifecycle-warn-A〜D / TC-cleanup-lifecycle-warn-A〜E). The `rite_phase_transition_allowed` / `rite_phase_expected_next` / `rite_phase_is_known` functions and the `hooks.stop_guard.phase_transitions` override merging they backed are gone — no current hook, script, or template reads that config key.

### Verify Terminal Output (retired)

> **Status: Retired**. The standalone `verify-terminal-output.sh` check was removed when `/rite:issue-create` was flattened into a single file. The Terminal Completion HTML-comment wrap contract is still required (`<!-- [create:returned-to-caller:{…}] -->`; previously `<!-- [create:completed:{…}] -->`), but enforcement now lives inline in `skills/issue-create/SKILL.md` ステップ 4.4 / ステップ 5.6 and is exercised via `create-md-invocation-symmetry.test.sh` rather than a standalone hook (the older `start-md-sentinel-coverage.test.sh` was deleted — a replacement `pr-cmd-sentinel-coverage.test.sh` targeting the new `pr/` commands is planned as a follow-up; see CHANGELOG "Removed" section).

### Session Ownership (`session-ownership.sh`)

Shared library sourced by the lifecycle hooks for multi-session conflict prevention. With the per-session state structure, ownership is **structurally guaranteed** by the file naming (`.rite/sessions/{session_id}.flow-state`); this library now serves as a path/entry resolution layer rather than a runtime guard.

> **Canonical SoT for sourcing callers**: actual `source` directives in `plugins/rite/hooks/*.sh` (verify with `grep -rn "source.*session-ownership.sh" plugins/rite/hooks/ --include='*.sh' | grep -v tests/`). At present this resolves to: `session-start.sh` / `session-end.sh` / `pre-compact.sh` / `post-tool-wm-sync.sh`. (`flow-state.sh` is NOT a `source` caller of this library — it sources only `state-path-resolve.sh` and `control-char-neutralize.sh`. `stop-guard.sh` has been removed; `post-compact.sh` does not source this library directly. `pre-tool-bash-guard.sh` sources only `hook-preamble.sh`, does not participate in flow-state path resolution, and has never been a `source` caller of this library.)

**Provided Functions:**

| Function | Purpose |
|----------|---------|
| `extract_session_id <hook_json>` | Pulls `session_id` from a hook's JSON stdin payload |
| `get_state_session_id <file>` | Reads `session_id` from a per-session flow state file |
| `check_session_ownership <hook_json> <state_file>` | Returns `own` / `legacy` / `other` / `stale` (legacy / other / stale are now mostly unreachable in steady-state operation because file naming structurally enforces `own`; retained for migration compatibility and crash-recovery scenarios) |
| `parse_iso8601_to_epoch <timestamp>` | Cross-platform ISO 8601 → epoch parser |

### Issue Comment WM Sync (`issue-comment-wm-sync.sh`)

Registered as a PostToolUse hook. Synchronizes work-memory updates into the Issue comment when a phase change is detected. Delegates deterministic JSON/body construction to `issue-comment-wm-update.py` to avoid fragile inline jq + atomic-write patterns.

### Wiki Ingest Trigger (`wiki-ingest-trigger.sh`) and Wiki Query Inject (`wiki-query-inject.sh`)

A pair of hooks that automate Experience Wiki integration (opt-out via `wiki.enabled: false`).

| Hook | Trigger | Action |
|------|---------|--------|
| `wiki-ingest-trigger.sh` | `pr/pr-review.md` Phase 5.4.3 (post review), `pr/fix.md` Phase 5.4.6 (post fix), `skills/issue-close/SKILL.md` (Issue close) | Writes a raw-source file under `.rite/wiki/raw/{type}/` on the dev branch working tree. Pure file writer, no git operations. |
| `wiki-query-inject.sh` | `skills/issue-implement/SKILL.md` Phase 5.0.W (invoked from `/rite:open` Step 4 sub-skill chain, formerly `start.md` ステップ 2.6 pre-decomposition), `pr/pr-review.md` Phase 4.0.W, `pr/fix.md` Phase 0.5.W, `skills/unknowns/SKILL.md` blindspot path (conditional) | Runs `/rite:wiki-query` against the current Issue title/body and injects matching heuristics. Reads via `origin/{wiki_branch}` when the local wiki branch is absent (fresh clone / separate worktree). |

See [Experience Wiki](#experience-wiki) for the full Phase X.X.W contract and the separate `wiki-ingest-commit.sh` / `wiki-worktree-commit.sh` helpers that actually commit + push raw sources onto the wiki branch.

### Hook Preamble (`hook-preamble.sh`)

Sourced at the top of most hooks to perform shared pre-processing: plugin-root resolution via `.rite-plugin-root`, `RITE_DEBUG` log setup, and double-execution guard bookkeeping. Hooks that need to read stdin must source it *after* capturing stdin to avoid consumption conflicts.

### Helper Scripts (`hooks/scripts/`)

Non-hook helper scripts invoked either directly from orchestrator skills or by other hooks:

| Script | Purpose | Notes |
|--------|---------|-------|
| `wiki-ingest-commit.sh` / `wiki-worktree-commit.sh` / `wiki-worktree-setup.sh` | Stash-based single-process commit + push of raw sources onto the `wiki` branch | — |
| `wiki-growth-check.sh` | `/rite:lint` Phase 3.8 layer-3 warn when `wiki.growth_check.threshold_prs` PRs accumulate without a wiki commit | — |
| `backlink-format-check.sh` | Bidirectional backlink format verification for Wiki pages | — |
| `bang-backtick-check.sh` | Detect bash history-expansion pitfalls in generated content | — |
| `reviewer-registry-drift-check.sh` | `/rite:lint` Phase 3.5 — detect reviewer registry drift across `agents/*-reviewer.md` and the 2 tables in `skills/reviewers/SKILL.md` (edit procedure: CONTRIBUTING.md "Adding a New Reviewer") | — |
| `gitignore-health-check.sh` | Verify the `.rite/wiki/` last-line-of-defense `.gitignore` rule, emit `gitignore_drift` sentinel on mismatch | — |
| `projects-board-drift-check.sh` | `/rite:lint` Phase 3.18 — detect CLOSED+COMPLETED Issues whose Projects board Status is not `Done` (NOT_PLANNED excluded), optionally reconcile via `--reconcile` | — |
| `number-reference-check.sh` | `/rite:lint` Phase 3.5 — detect Issue/PR number references (`#NNN` / `Issue #NNN` / `PR #NNN`) that crept back into the number-free documentation surface (`CHANGELOG.md` / `CHANGELOG.ja.md` / `lint.md`) | — |
| `tmp-hardcode-check.sh` | `/rite:lint` Phase 3.5 — detect sandbox-incompatible patterns (`mktemp` + `/tmp` template, fixed `/tmp` path hardcode, `git push` upstream `-u`) in `plugins/rite/**/*.{md,sh}` + `docs/**/*.md` (test harnesses / error-catalog / self excluded) | — |
| `wiki-branch-init.sh` | `/rite:wiki-init` ステップ 3.1 — orphan wiki ブランチ作成 + push + 元ブランチ復帰 (stash 退避/復帰、same_branch 両対応) | — |
| `wiki-lint-skipped-refs.sh` | `/rite:wiki-lint` ステップ 6.0 — raw frontmatter (`ingest_status: skipped`) を走査して skipped_refs 集合を marker block + `log_read_ok` 4 値 enum で構築 (Issue #1520 で skip SoT が log.md から raw frontmatter へ移行。6.2 `wiki-lint-source-refs.sh` と対称) | — |
| `wiki-lint-source-refs.sh` | `/rite:wiki-lint` ステップ 6.2 — Wiki ページの Sources 行から `all_source_refs` 集合を構築 (6.0 `wiki-lint-skipped-refs.sh` と対称) | — |
| `wiki-lint-stale.sh` | `/rite:wiki-lint` ステップ 4 — frontmatter `updated` と cutoff 比較で陳腐化集合を marker block + `stale_check_ok` enum で構築 (GNU date 検査内包) | — |
| `wiki-lint-orphans.sh` | `/rite:wiki-lint` ステップ 5 — index.md 登録ページと pages_list の集合差分を marker block + `orphan_check_ok` enum で構築 (index.md 読出内包) | — |
| `wiki-lint-broken-refs.sh` | `/rite:wiki-lint` ステップ 7 — Markdown link の page-dir 起点 `realpath -m -s` 解決で壊れた相互参照集合を構築 (awk indent 不問 fence tracking) | — |
| `bang-backtick-edit-hook.sh` | `bang-backtick-check.sh` の PostToolUse(Edit\|Write\|MultiEdit) wrapper — `hooks.json` 登録済 (`tool_input.file_path` でスコープを絞る) | — |
| `bash-heaviness-check.sh` | `skills/**/*.md` 内の heavy operational bash block を non-blocking warning で検出 | — |
| `hardcoded-line-number-check.sh` | procedural markdown (`skills/**/*.md`) 内のハードコード行番号参照を検出 | — |
| `comment-line-ref-check.sh` | shell comment 内の `<file>.<ext>:<NN>` 行番号参照を検出 (`hardcoded-line-number-check.sh` の companion) | — |
| `comment-journal-check.sh` | `plugins/rite/**/*.{sh,md}` の journal 語法 comment 違反を機械検出 | — |
| `sh-cross-ref-check.sh` | shell prose (echo 文字列 / comment) 内の cross-file step/phase 参照の実在を検証 | — |
| `orphan-reference-check.sh` | plugins/rite/ 配下の未参照 (orphan) ファイル検出 | — |
| `post-review-state-verify.sh` | reviewer subagent の READ-ONLY 契約違反 (working tree / branch / stash 変更) の検出 + recovery | — |
| `pr-cycle-cleanup.sh` | 残留 `pr-{N}-cycle{X}` worktree / branch の冪等掃除 + `${TMPDIR:-/tmp}/rite-pr-create-*` 孤児 workdir の age ベース GC (mtime > 24h)。`session-start.sh` のセッション開始時 lazy reap 起動 (`CWD == STATE_ROOT` ゲート) では、stdout/stderr を `STATE_ROOT/.rite/logs/pr-cycle-cleanup.log` へ退避する (ログディレクトリ初回作成時に自己完結的な `.gitignore` (`*`) も生成し downstream consuming repo でも自動除外、上書き方式、ログ書き込み準備失敗時（ディレクトリ作成不可または既存ディレクトリへの書き込み不可）は従来どおり破棄にフォールバック、#1968) | — |
| `review-schema-version-check.sh` | review-result JSON の `schema_version` drift 検出 (`fix.md` ステップ 3.1.1 の pre-commit gate から直接呼び出される) | `review.loop.pre_commit_drift_check` |
| `settings-local-rite-hook-cleanup.sh` | `.claude/settings.local.json` の stale legacy rite hook entry 削除 (`.py` 実体への wrapper、setup.md Phase 4.5.0.2) | — |
| `lib/` (`git-remote.sh` / `git-status-filtered.sh` / `wiki-config.sh` / `worktree-git.sh`) | 汎用 git helper + wiki 系 helper の共有ライブラリ (owner/repo 解決 / sandbox ghost mount 除外 git status / wiki config 読取 / worktree git 操作) | — |
| `tests/` | hooks/scripts レベルのテストスイート | — |

---

## Features

### Multi-Session State Management

> **Design rationale**: See [`docs/designs/multi-session-state.md`](designs/multi-session-state.md) for the full design selection (6-axis trade-off comparison, Option A vs B Decision Log, and Phase 2 implementation retrospective). This section is the canonical **runtime specification**; the design doc is the canonical **rationale** record.

The flow state for `/rite:*` workflows uses a **per-session file** structure (`.rite/sessions/{session_id}.flow-state`). Each Claude Code session writes only to its own file, so concurrent sessions on the same repository are structurally race-free without lock acquisition.

> **Authority scope — session-scoped continuation hint, not a cross-`/clear` source of truth**: flow state is **session-scoped** and treats `/clear` as its continuation terminus — a session started after a `/clear` resolves a fresh `session_id` and therefore reads a different (structurally empty) state file. Consequently, **discrete commands** invoked standalone across a `/clear` (e.g. `/rite:merge`) **must not** treat flow state as the authoritative cross-`/clear` state. Their authority lives in the persistent SoT — `gh pr view` (`isDraft` / `mergeable` / `mergeStateStatus`), GitHub Projects Status, and `.rite-work-memory/issue-{n}.md`. flow state, when present, is consumed only as a **same-session continuation hint**, and its absence is the normal (un-warned) case for discrete operation. Conversely, the **continuation-loop subsystems** — `/rite:iterate`'s review↔fix loop, the `Stop` hook + `handoff` field, `/rite:pr-review` / `/rite:fix`, compact recovery, and `/rite:recover` — are single-session by nature and are precisely the domain where session-scoped flow state functions correctly; they are left untouched. See [`docs/designs/clear-per-command-flow-state-decoupling.md`](designs/clear-per-command-flow-state-decoupling.md) for the full discrete-command-vs-continuation-loop decoupling analysis and per-command breakdown; `skills/merge/SKILL.md` Step 1 is the first application of this boundary.

**File path:**

```
.rite/
└── sessions/
 ├── 34eadf04-8f13-4ce3-adcd-8dc6668a5b9f.flow-state
 ├── 9a8b7c6d-...flow-state
 └── ...
```

The `session_id` is the same UUID stored in `.rite-session-id` and propagated to every hook via the JSON stdin payload.

**Schema (`schema_version: 3`):**

| Category | Field | Source / Writer | Notes |
|----------|-------|-----------------|-------|
| Required (10) | `active` | `flow-state.sh set` | `true` while a workflow is in flight |
| Required | `issue_number` | `flow-state.sh set` | The Issue under work |
| Required | `branch` | `flow-state.sh set` | Feature branch name |
| Required | `phase` | `flow-state.sh set` | Current orchestrator phase (flat enum: `init` / `branch` / `plan` / `implement` / `lint` / `pr` / `review` / `fix` / `ready` / `ready_error` / `cleanup` / `ingest` / `completed`) |
| Required | `pr_number` | `flow-state.sh set` | `0` until the PR is opened |
| Required | `parent_issue_number` | `flow-state.sh set` | `0` when the Issue is standalone |
| Required | `next_action` | `flow-state.sh set` | Free-text continuation hint surfaced via post-compact recovery |
| Required | `updated_at` | `flow-state.sh set` (every write) | ISO 8601 UTC with `Z` suffix; generated by `date -u +"%Y-%m-%dT%H:%M:%SZ"` (cross-platform deterministic). Note: human-facing logs elsewhere may be JST; the persisted state field is UTC |
| Required | `session_id` | `flow-state.sh set` | Mirrors `.rite-session-id`, used as filename |
| Required | `last_synced_phase` | `flow-state.sh set` (merge-preserves existing value) / `post-tool-wm-sync.sh` (actual writer on phase diff via `jq '.last_synced_phase = $p'`) | Tracks the last work-memory sync point. `flow-state.sh set` merge-preserves but does not author this field — only the per-tool sync hook does (verify with `grep -n last_synced_phase plugins/rite/hooks/*.sh`) |
| Optional | `wm_comment_id` | `issue-comment-wm-sync.sh` (cache write) | GitHub comment ID for the work memory backup |
| Optional | `loop_count` | **Reader-only legacy field** — no production writer in `flow-state.sh` (verify with `grep -n loop_count plugins/rite/hooks/flow-state.sh` → 0 hits). Consumers (`pre-compact.sh` / `post-compact.sh` / `session-start.sh` / `work-memory-update.sh`) read it as best-effort; `work-memory-update.sh` increments the work-memory document copy, not the flow-state field. Schema slot retained for forward compatibility | Review-fix loop counter |
| Optional | `error_count` | `flow-state.sh set` (resets to `0` on phase transition; `--preserve-error-count` retains the existing value) | Half-legacy field — incrementer was removed with `stop-guard.sh`; writer is reset-only. Schema retained for forward compatibility |
| Optional | `handoff` | `flow-state.sh set --handoff <cmd>` (writer; **default-clears on every set** — present only when `--handoff` is passed) / `flow-state.sh consume-handoff` (reader+deleter) | One-shot continuation marker with three value families: continuation `/rite:...` set by `pr-review.md` Step 8.0 (`/rite:fix {pr}` on `[review:fix-needed]`) and `fix.md` Step 5.1 (`/rite:pr-review {pr}` on `[fix:pushed]`/`[fix:pushed-wm-stale]`); terminal `FINALIZE:{result}:{pr}` set by the same steps on terminal sentinels; chain `WIKICHAIN:{caller}:{pr}` set by `cleanup.md` Step 9 before invoking `rite:wiki-ingest` (cleared by the Step 12 terminal set's default-clear when the chain completes). Consumed (printed + deleted) by the `Stop` hook `stop-loop-continuation.sh`, which emits `decision:block` with a prefix-selected reason. Default-clear semantics mirror `error_count`; no `schema_version` bump (additive, backward-compatible via `.handoff // ""`) |
| Optional | `worktree` | `flow-state.sh set --worktree <abs-path>` | Session worktree absolute path under multi-session mode (`.rite/worktrees/issue-{N}`, design §2). **Merge-preserve** semantics like `branch` (NOT default-clear like `handoff`): an unspecified `--worktree` preserves the existing value across phase-transition sets. Written conditionally — non-worktree (single-session) sessions never gain the key, so the state file is byte-identical and no `schema_version` bump is needed (additive, read via `.worktree // ""`). A same-session hint only: the canonical session↔worktree correspondence is the issue-number → path derivation in `/rite:recover` (session_id changes on crash, so the field is not authoritative) |
| Optional | `cycle_count` | `flow-state.sh set --cycle-count <N>` | The `/rite:iterate` review⇄fix cycle counter for the `safety.max_review_cycles` circuit breaker (#1701). `/rite:iterate` increments it at each loop head, resets it to `0` on a fresh entry (phase not in `review`/`fix`), and continues it across `/rite:recover` (AC-3). **Merge-preserve** semantics like `worktree`/`branch` (NOT default-clear like `handoff`): an unspecified `--cycle-count` preserves the existing value. `--cycle-count 0` deletes the key. Written conditionally — sessions that never run the breaker never gain the key, so the state file is byte-identical and no `schema_version` bump is needed (additive, read via `.cycle_count // 0`) |
| Optional | `schema_version` | `flow-state.sh set` | `3` for the per-session structure; absent or `!= 3` triggers migration |

> **`needs_clear` field**: Removed. The previous compact-recovery design discussed `needs_clear` as a flag, but production code never had a writer or non-test reader. Test fixtures (`pre-compact.test.sh` TC-014 / TC-014b) actively assert that `pre-compact does NOT set needs_clear`. The new schema does not include this field.

> **`previous_phase` field**: Removed in the v2→v3 migration. The v2 schema auto-populated it from the outgoing `phase` value, but v3 discriminates resume routing by step-name mapping (`skills/recover/SKILL.md`) instead. `cmd_set` no longer writes it (verify with `grep -n previous_phase plugins/rite/hooks/flow-state.sh`), and `_migrate_file` strips it from migrated files via `del(.previous_phase)`.

**Migration from legacy single-file format:**

Legacy state files (flat JSON without `schema_version`, or any file with `schema_version != 3`) are auto-migrated to v3 on session start by [`flow-state.sh migrate`](../plugins/rite/hooks/flow-state.sh) — the `cmd_migrate` / `_migrate_file` path — invoked from [`session-start.sh`](../plugins/rite/hooks/session-start.sh). `_migrate_file` rewrites each file **in place** via `mktemp + flock + atomic mv` (`_atomic_write`; when `flock` is absent — stock macOS / Windows Git Bash — the lock is skipped and the plain atomic `mv` still applies): it strips the legacy `previous_phase` field, normalizes `branch_name` → `branch`, reduces the legacy `phase` value to the v3 enum, bumps `schema_version` to `3`, and refreshes `updated_at`, while preserving `last_synced_phase`. There is no separate `.rite-flow-state.legacy.{timestamp}` backup — the rewrite is in place. A performed migration always prints an explicit `migrated:` line to stderr (unconditional, not gated on `--verbose`, so the session-start auto path surfaces it — silent skip is forbidden, AC-8); the no-op already-v3 case stays quiet unless `--verbose`. The `--dry-run` preview (`would migrate:`) also goes to stderr for symmetry with the `migrated:` announcement, so dry-run output surfaces alongside real migrations under the session-start stdout-only silence policy. The multi-session atomicity / glob-collision rationale is in [`docs/designs/multi-session-state.md`](designs/multi-session-state.md#migration-戦略).

**Legacy single-file selection (removed):**

`rite-config.yml` previously accepted `flow_state.schema_version: 1` to force the legacy single-file (`.rite-flow-state`) code path (adapter pattern). That dual logic has been removed — flow-state is always per-session (`.rite/sessions/{session_id}.flow-state`). An explicit `flow_state.schema_version: 1` is now ignored; `session-start.sh` emits a deprecation warning once per session start (every startup until the key is removed) prompting its removal. A residual `.rite-flow-state` single-file is absorbed into per-session/v3 by the `flow-state.sh migrate` path above.

**Sub-Issues API parent-child structure:**

This feature uses GitHub's native Sub-Issues API to maintain the parent-child relation. `/rite:open` Step 1.2 (previously `start.md` Phase 0.3 before the decomposition) detects parent Issues via three OR-combined methods (trackedIssues API → body tasklist `- [ ] #N` → label-based `epic`/`parent`/`umbrella`). The child→parent Status promotion (Todo → In Progress) is propagated in the same OR-combined order (`## 親 Issue` body meta → Sub-Issues API `trackedInIssues` → tasklist search) by `/rite:open` Step 2.4 (`### 2.4 GitHub Projects Status 更新`, sub-step 2.4.7 — see [`references/projects-integration.md`](../plugins/rite/references/projects-integration.md) §2.4.7 Parent Issue Status Update for the SoT).

> **Hook list canonical SoT**: The hooks that read or write per-session state are registered in [`plugins/rite/hooks/hooks.json`](../plugins/rite/hooks/hooks.json) — currently 7 events (`SessionStart` / `SessionEnd` / `PreCompact` / `PostCompact` / `PreToolUse` / `PostToolUse` / `Stop`). To re-enumerate the live registration, run `jq '.hooks | keys[]' plugins/rite/hooks/hooks.json`. The `Stop` event is registered to `stop-loop-continuation.sh` for review↔fix loop continuation; the legacy `stop-guard.sh` stop-prevention hook remains removed (see the retired-layers note below). The library script `session-ownership.sh` is sourced (not registered) and therefore does not appear in `hooks.json`.

#### Worktree Mode (session worktree isolation)

The per-session flow-state structure above isolates the **state** layer; **Worktree Mode** (`multi_session.enabled: true`, the default) additionally isolates the **working-tree / current-branch** layer so that multiple sessions can run *different* Issues in the same repository without their `git switch` operations destroying each other's working tree. When `multi_session.enabled: false` (explicit opt-out, or a legacy config that omits the `multi_session` block) none of the paths below activate and behavior is byte-identical to single-session. Full design rationale + Decision Log: [`docs/designs/multi-session-worktree.md`](designs/multi-session-worktree.md).

**Session worktree lifecycle:**

| Stage | Command | Action |
|---|---|---|
| Create / enter | `/rite:open N` | `git worktree add --no-track -b {branch} {worktree_base}/issue-{N} origin/{base}` (idempotent across 5 cases — reuse / stale-residue prune / branch-only / new / other-worktree abort; `--no-track` avoids sandbox-rejected `.git/config` tracking writes, Issue #1894), then `EnterWorktree(path)` (Step 2.2-W / 2.3-W). A pre-existing `worktree` flow-state value triggers Step 0.5 re-entry on resume |
| Work | implement / lint / push / PR create | unchanged — they are cwd-relative and complete inside the worktree (Steps 3–6) |
| Exit / remove | `/rite:cleanup` | `ExitWorktree(action: "keep")` back to the main checkout, then `git worktree remove {path}` (a path-entered worktree is **not** removed by `ExitWorktree` itself, so removal runs from the main checkout) |
| Reap (orphans) | `pr-cycle-cleanup.sh` Step 5 | lazily removes abnormally-orphaned session worktrees only when a **self-exclusion guard (Gate 0)** plus **3 gates** all pass: Gate 0 never reaps the worktree the cleanup is itself running in (invocation cwd or `RITE_WORKTREE` matching or nested under the candidate, so a long-lived session cannot delete its own active worktree mid-flight), then strict `^issue-[0-9]+$` name under `worktree_base`, claim not live (or no claim + mtime > 24h — a worktree whose checked-out branch is reap-manifest-recorded, i.e. cleanup verified the PR merged and deferred the removal, bypasses the age guard: the harness refreshes the root mtime every session, so the guard alone would leak the deferred tree forever, Issue #1966), and `git status --porcelain` empty (a dirty worktree is never auto-reaped — WARNING + manual command instead; the sole exception is an admin-HEAD-missing, git-unrecognized **corpse** whose status is structurally undeterminable — it bypasses the status gate and is reaped, working tree + admin dir, behind the claim + 24h age guards, Issue #1957) |

The session worktree is one of **four non-overlapping worktree namespaces** (`.rite/worktrees/issue-{N}` session / `.worktrees/{issue}/{task}` parallel sub-agent / `pr-{N}-cycle{X}` reviewer transient / `.rite/wiki-worktree` wiki); the reap's strict regex guarantees it never touches the other three. See [`references/git-worktree-patterns.md` → Multi-Session Patterns](../plugins/rite/references/git-worktree-patterns.md#multi-session-patterns).

**Shared state root (worktree-aware resolution):** `state-path-resolve.sh` detects a linked worktree (via `git rev-parse --git-common-dir`) and resolves state / locks / wiki-worktree to the **main checkout root** even when the session cwd is inside a worktree, so cross-session exclusion (work-memory lock, the `.rite/state/` flock group, the single `.rite/wiki-worktree`) stays intact. Non-worktree sessions resolve byte-identically to today (pinned by `state-path-resolve.test.sh`). PR-state artifacts (`.rite/review-results/`, `.rite/fix-cycle-state/`, `.rite/state/accepted-fingerprints-*`) also resolve to this **shared state root** (Issue #1831): a save from inside a session worktree must be readable by the fix loop and deletable by `/rite:cleanup` from the main checkout, so keeping them worktree-local silently split the save/read/delete paths. Same-PR filename collisions across sessions are handled by the `~<hex>` suffix in `review-result-schema.md`. Only `.rite/tmp/` intentionally stays **cwd-relative (worktree-local)** so it vanishes with the worktree.

**Issue claim mechanism (always-on):** Independently of `multi_session.enabled`, `/rite:open` Step 1.6 acquires an Issue claim *before* any branch / worktree side-effect (fail-fast against double-starting the same Issue), and `/rite:cleanup` releases it. Claims live at `.rite/state/issue-claims/issue-{N}.json` and are managed by `hooks/issue-claim.sh {claim|release|check} --issue N`. **Liveness** reuses the flow-state heartbeat — a claim is live iff the holding session's flow-state is `active=true` and `updated_at` is within 2h (the same threshold and `parse_iso8601_to_epoch` as `session-ownership.sh`); no new heartbeat file is introduced. On detecting another **live** claim, `/rite:open` always surfaces an AskUserQuestion (never an unattended steal); a stale claim is reclaimed only by the reap path under the clean-worktree gate. Claims are **not** released at session end, so a crashed session's work stays resumable. Because claims only ever create files under the already-gitignored `.rite/state/`, the mechanism is silent and backward-compatible when there is no conflict (Decision D-3: always-on regardless of the worktree flag).

**main-checkout inviolability convention:** In Worktree Mode rite **never switches the main checkout's current branch** (moving it is a human-only action). Consequences enforced across the workflow: new session branches are based on `origin/{base}` directly (not a local `{base}` another worktree may hold); a branch is deleted only *after* its worktree is removed (a checked-out branch can be neither deleted nor fetch-updated); `/rite:cleanup`'s base update runs **only when the main checkout is on `{base}`** and otherwise WARNINGs + skips with a recovery hint. See the `/rite:cleanup` Phase 2 note and [`references/git-worktree-patterns.md`](../plugins/rite/references/git-worktree-patterns.md#multi-session-patterns).

**Crash recovery / `/rite:recover`:** After a crash a new session starts at the repository root. `/rite:recover` re-enters the worktree *before* any branch-dependent cross-check (flow-state `worktree` → else issue-number → path derivation), and reconstructs a missing worktree from the branch (local → `git worktree add`; remote-only → `git fetch` + `--track -b`; nowhere → AskUserQuestion). The `worktree` flow-state field is a **same-session hint only** — the canonical session↔worktree correspondence is the issue-number → path derivation, because `session_id` changes on crash (see the schema table's `worktree` row above).

**Configuration:** `multi_session.enabled` (default `true`; set `false` to opt out — a legacy config that omits the block also falls back to `false`) and `multi_session.worktree_base` (default `.rite/worktrees`). A **separate axis** from `parallel.*` (per-Issue sub-agent fan-out within one session); the two are orthogonal and intentionally not merged. `.rite/worktrees/` must be effectively ignored by `.gitignore` — a broad `.rite/` rule suffices (`/rite:setup` adds an entry only when not already covered; `gitignore-health-check.sh` probes with `git check-ignore` and emits a non-blocking warning if the path is not ignored while `multi_session.enabled: true`). Disk cost: each session worktree is a full working-tree clone, so build artifacts (`node_modules`, etc.) may need rebuilding per worktree. See [`docs/CONFIGURATION.md` → multi_session](CONFIGURATION.md#multi_session).

### Local Work Memory + Compact Resilience

In addition to Issue comment backups, work memory is maintained on the local filesystem. This ensures resilience against context compaction.

**Architecture:**

| Component | Role | Location |
|-----------|------|----------|
| Local work memory (SoT) | Source of truth | `.rite-work-memory/issue-{n}.md` |
| Issue comment (backup) | Cross-session backup | GitHub Issue comment |
| Flow state | Workflow control | `.rite/sessions/{session_id}.flow-state` (per-session; see [Multi-Session State Management](#multi-session-state-management)) |
| Compact state | Post-compact state management | `.rite/sessions/{session_id}.compact-state` (per-session; legacy shared `.rite-compact-state` retained for migration) |

**Local Work Memory Features:**

- Exclusive access control via `mkdir`-based locking
- Auto-recovery through PostToolUse hook
- State restoration from the per-session flow state file possible even after compact

### Implementation Contract Issue Format

A format that includes an Implementation Contract section in Issues generated by `/rite:issue-create`. Separates high-level design from specification and detailed implementation steps.

**Structure:**

- **Phase 0.7 (Specification generation)**: Generates high-level What/Why/Where design in `docs/designs/`
- **Phase 3 (Implementation plan)**: Generates detailed How steps as a dependency graph
- Issue body checklist tracks progress

### Complexity-Based Question Filtering

A mechanism that dynamically adjusts the number of questions based on Issue complexity during `/rite:issue-create`'s deep-dive interview (Phase 0.5).

**Filtering Rules:**

| Complexity | Questions | Scope |
|------------|-----------|-------|
| XS-S | Minimal (1-2) | What/Why only |
| M | Standard (3-4) | What/Why/Where/Scope |
| L-XL | Detailed (5+) | All items + decomposition proposal |

### Shell Script Test Framework

A test framework for ensuring Hook script quality. Located in `plugins/rite/hooks/tests/`.

**Test Targets (excerpt — see `hooks/tests/` for the full suite):**

| Script | Test Content |
|--------|-------------|
| `post-compact.sh` | Recovery context emission, per-session compact-state self-healing |
| `pre-compact.sh` | State capture before compact |
| `pre-tool-bash-guard.sh` | Dangerous pattern detection, heredoc safety |
| `post-tool-wm-sync.sh` | Work memory auto-recovery after Bash tool calls |
| `session-start.sh` / `session-end.sh` | Session lifecycle + ownership transitions |
| `work-memory-lock.sh` | Lock acquire/release + stale detection |
| `wiki-ingest-trigger.sh` | Raw-source write contract |
| `parent-child-sync-static` | Parent/child Issue state synchronization |

**Execution:**

```bash
bash plugins/rite/hooks/tests/run-tests.sh
```

---

## Build/Test/Lint Auto-Detection

### Detection Priority

1. **Explicit specification in rite-config.yml**
2. **package.json scripts**
 - Detect `build`, `test`, `lint`
3. **Makefile targets**
4. **Standard file structure inference**

### Language/Framework Detection

| File | Language/FW | Build | Test | Lint |
|------|-------------|-------|------|------|
| `package.json` | Node.js | `npm run build` | `npm test` | `npm run lint` |
| `pyproject.toml` | Python | `python -m build` | `pytest` | `ruff check` |
| `Cargo.toml` | Rust | `cargo build` | `cargo test` | `cargo clippy` |
| `go.mod` | Go | `go build` | `go test` | `golangci-lint` |
| `pom.xml` | Java | `mvn package` | `mvn test` | `mvn checkstyle:check` |

### Fallback Behavior When Commands Not Detected

When build/test/lint commands cannot be detected, the workflow provides interactive options instead of terminating:

**Options presented via `AskUserQuestion`:**

| Option | Description |
|--------|-------------|
| **Skip and continue (Recommended)** | Skip the command and proceed to the next step. Record the skip in PR body under "Known Issues" |
| **Specify command** | User manually enters the command to execute |
| **Abort** | Terminate the process and guide user to configure settings |

**Skip behavior:**
- The skip is recorded in the conversation context
- When `/rite:pr-create` is called, the "Known Issues" section includes the skipped command
- The end-to-end flow (`/rite:open` → `/rite:iterate` → `/rite:ready` → `/rite:merge`) continues without interruption

**Command specification behavior:**
- The specified command is used for the current execution only
- Configuration is not automatically saved to `rite-config.yml`
- User is guided to use `/rite:setup` or manual editing for permanent configuration

---

## Dynamic Reviewer Generation

### Overview

Analyze PR changes and dynamically generate appropriate reviewers.

### Reviewer Selection Logic

#### Step 1: File Type Analysis

| File Pattern | Recommended Reviewer |
|--------------|---------------------|
| `**/security/**`, `auth*`, `crypto*` | Security Expert |
| `.github/**`, `Dockerfile`, `*.yml` (CI) | DevOps Expert |
| `**/*.md`, `docs/**` | Technical Writer |
| `**/*.test.*`, `**/*.spec.*` | Test Expert |
| `**/api/**`, `**/routes/**` | Application Expert |

#### Step 2: Content Analysis

LLM analyzes diff content to determine:
- Change complexity
- Required expertise
- Potential risk areas

#### Step 3: Dynamic Reviewer Count

| Condition | Reviewers |
|-----------|-----------|
| Single file, <10 lines | 1 |
| Multiple files, <100 lines | 2-3 |
| Large changes, security-related | 4-5 |

### Dynamically Generated Reviewer Profiles

- **Security Expert**: Vulnerabilities, authentication, encryption
- **Application Expert**: Application code end-to-end (contracts, performance, data operations, UI safety)
- **Accessibility Expert**: WCAG compliance, screen reader support
- **Technical Writer**: Documentation quality, consistency
- **Architect**: Design patterns, dependencies
- **DevOps Expert**: CI/CD, infrastructure, deployment

### Review Result Format

```markdown
## 📜 rite Review Results

### Overall Assessment
- **Recommendation**: Approve / Approve with conditions / Request changes

### Individual Reviewer Assessments

#### Security Expert
- **Assessment**: Approve
- **Comments**: No issues with authentication logic

#### Application Expert
- **Assessment**: Approve with conditions
- **Comments**: Potential N+1 query (L45-52)

...
```

---

## Workflow Failure Surfacing

### Overview

When a step of the end-to-end flow (`/rite:open` → `/rite:iterate` → `/rite:ready` → `/rite:merge`) fails or is skipped (Skill load failure, hook abnormal exit, Wiki ingest skip/failure, `.gitignore` drift, etc.), the relevant script or hook emits a plain `WARNING` / `ERROR` line to **stderr**. The orchestrator LLM surfaces these in the conversation context, and the user resolves them by re-running the affected step via `/rite:recover`.

> **History**: An earlier design auto-detected these as "workflow incidents" — each failure path emitted a `[CONTEXT] WORKFLOW_INCIDENT=1; ...` sentinel via a dedicated `workflow-incident-emit.sh` hook, which the (then-current) `/rite:issue-start` orchestrator's ステップ 8.5 grepped from the conversation context to auto-register the blocker as a Todo Issue (`AskUserQuestion` confirmation, per-session dedupe, `workflow_incident.enabled` opt-out). The entire mechanism — the emit hook, the ステップ 8.5 detection logic, the `workflow_incident:` config key, and the sentinel format — was removed in favor of the single-layer plain-stderr design described above. The `/rite:issue-start` orchestrator itself was subsequently decomposed into the four `pr/` commands (see the [Retired section](#riteissuestart-retired) above). Failures are now visible but no longer auto-registered; the user decides whether to file an Issue.

### Reviewer-Triggered Issue Creation (Two Paths)

There are (were) two paths that converted reviewer "別 Issue として作成" recommendations into tracked GitHub Issues. Their current status differs and must not be conflated:

| Path | Location | Status | Notes |
|------|----------|--------|-------|
| Fix-side post-loop | `fix.md` Phase 4.3 ("Automatic Separate Issue Creation") | **Removed** | The full Phase 4.3 section and the `[fix:issues-created:N]` sentinel were deleted. The `review.separate_issue_creation.*` runtime mechanism is removed, but the scaffolding block remains in `templates/config/rite-config.yml` (no runtime effect) and is scheduled for removal in a follow-up PR — see [CONFIGURATION.md](./CONFIGURATION.md) `~~separate_issue_creation.*~~` DEPRECATED note for the template state caveat. Inside the `/rite:fix` review-fix loop, reviewer recommendations are now handled per-finding via the Phase 2.1 menu (fix / accept / reply) — no post-loop auto-creation. |
| Review-side | `pr/pr-review.md` Phase 7 ("Automatic Issue Creation") | **Live (not removed)** | Calls `plugins/rite/scripts/create-issue-with-projects.sh` with `source: "pr_review"`, gated by `AskUserQuestion` confirmation. This is the canonical path for converting reviewer recommendations into tracked Issues. |

The `scripts/create-issue-with-projects.sh` helper is the canonical Issue-creation path for both the review-side Phase 7 invocation above and for manual `/rite:issue-create` use.

## Experience Wiki

### Overview

The Experience Wiki is an LLM-driven project knowledge base that persists **experiential heuristics** — the "what we learned the hard way" lessons that usually live only in reviewer heads or scattered across Issue/PR comments. It is based on the LLM Wiki pattern (Karpathy). The full design rationale lives in `docs/designs/experience-heuristics-persistence-layer.md`.

Wiki is **opt-out** by default (`wiki.enabled: true`). Configuration lives under the `wiki:` section of `rite-config.yml` — see [Configuration Reference → wiki](CONFIGURATION.md#wiki).

### Architecture

Wiki data is stored in a dedicated branch (default: `wiki`) or inline on the working branch, controlled by `wiki.branch_strategy`. Each Wiki page is a Markdown file keyed by topic (e.g., `review-quality.md`, `fix-cycle-convergence.md`). Pages are built up incrementally from raw sources (review comments, fix outcomes, Issue discussions) through an ingest pipeline that deduplicates and merges overlapping heuristics.

### OKF v0.1 Conformance

The `.rite/wiki/` bundle is stored as an [Open Knowledge Format (OKF) v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog)-conformant structure so the accumulated heuristics can be browsed as a concept graph with the upstream OKF static visualizer:

| Element | Conformance | Implementation SoT |
|---------|-------------|--------------------|
| Page frontmatter | Declares concept `type:` (`patterns` / `heuristics` / `anti-patterns`) and `description:` | `templates/wiki/page-template.md` |
| `index.md` | Carries `okf_version: "0.1"`; page catalog as OKF bullets `* [title](path) - desc` | `templates/wiki/index-template.md` |
| `log.md` | Change history in OKF reserved structure (`## YYYY-MM-DD` headings + prose bullets, newest-first, append-only, human-facing) | `templates/wiki/log-template.md` |
| Raw frontmatter | Ingest skip state held as `ingest_status: skipped` + `skip_reason:` (skip SoT; not kept in `log.md`) | `skills/wiki-ingest/SKILL.md` step 5 |

**Visualizer integration (not vendored)**: the upstream OKF static HTML visualizer (`GoogleCloudPlatform/knowledge-catalog`, Apache-2.0) is **not bundled** in this repo. `plugins/rite/references/wiki-patterns.md` documents the procedure to materialize the bundle (reusing `wiki-worktree-setup.sh` for `separate_branch`) and point the upstream visualizer at it, plus the license-confirmation step. Producing the conformant structure is the responsibility of `/rite:wiki-init` and `/rite:wiki-ingest`; consumers (`/rite:wiki-query`, `/rite:wiki-lint`) read it.

### Commands

| Command | Purpose |
|---------|---------|
| `/rite:wiki-init` | One-time setup: create the Wiki branch (if `branch_strategy: "separate_branch"`), scaffold directory structure, and install page templates |
| `/rite:wiki-ingest` | Parse raw sources (review results, fix outcomes, closed Issues) and update or create Wiki pages. Invoked manually or automatically by the `wiki-ingest-trigger.sh` hook |
| `/rite:wiki-query` | Search Wiki pages by keyword and inject matching heuristics into the conversation context. Invoked manually or automatically by the `wiki-query-inject.sh` hook at Issue start / review / fix / implement phases |
| `/rite:wiki-lint` | Check Wiki pages for contradictions, staleness, orphans (pages with no cross-refs), missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs. Supports `--auto` mode for CI-style batch runs |

### Automatic Hook Integration

When `wiki.auto_ingest`, `wiki.auto_query`, or `wiki.auto_lint` are enabled, the following hooks fire without user action:

| Hook | Trigger | Action |
|------|---------|--------|
| `wiki-query-inject.sh` | `skills/issue-implement/SKILL.md` Phase 5.0.W (invoked from `/rite:open` Step 4 sub-skill chain, formerly `start.md` ステップ 2.6 pre-decomposition), `pr/pr-review.md` Phase 4.0.W, `pr/fix.md` Phase 0.5.W, `skills/unknowns/SKILL.md` blindspot path (conditional) | Run `/rite:wiki-query` against the current Issue title/body and inject matching heuristics |
| `wiki-ingest-trigger.sh` | `pr/pr-review.md` Phase 5.4.3 (post review), `pr/fix.md` Phase 5.4.6 (post fix), `skills/issue-close/SKILL.md` (Issue close) | Write a raw source file into `.rite/wiki/raw/{type}/` on the dev branch working tree (pure file writer, no git operations) |
| `wiki-ingest-commit.sh` | Phase 6.5.W.2 (review), Phase 4.6.W.2 (fix), Phase 4.4.W.2 (close) — immediately after the trigger | Move pending raw sources onto the `wiki` branch and commit + push them **in a single shell process** with no dependency on Claude multi-step orchestration |
| `/rite:wiki-ingest` | Manual or optional post-commit invocation | LLM-driven page integration: read accumulated raw sources, produce/update wiki pages, refresh `index.md` / `log.md` |
| `/rite:wiki-lint --auto` | After each successful page integration (when `auto_lint: true`) | Validate Wiki consistency; surface warnings without blocking the workflow |

### Phase X.X.W Mandatory Execution (shell commit refactor)

`pr/pr-review.md` Phase 6.5.W / 6.5.W.2, `pr/fix.md` Phase 4.6.W / 4.6.W.2, and `issue/close.md` Phase 4.4.W / 4.4.W.2 collectively form the **Wiki growth path**. This path is hardened against silent skip with a 3-layer defense; the subsequent shell-commit refactor added a deterministic foundation underneath layers 1-3.

| Layer | Mechanism | Files |
|-------|-----------|-------|
| **0. Deterministic raw-commit path** | Phase X.X.W.2 invokes `wiki-ingest-commit.sh` directly as a single shell process. The script stashes raw sources into `/tmp`, removes them from the dev working tree, stashes any remaining unrelated changes, checks out the wiki branch, replays the staged raw sources, commits, pushes, checks out the original branch again, and pops the stash — all within one `bash` invocation. This eliminates dependency on Claude multi-step orchestration (the root cause of the pre-refactor regression where the `wiki` branch never grew despite multiple rounds of layer 1-3 defence). | `hooks/scripts/wiki-ingest-commit.sh`, `pr/pr-review.md`, `pr/fix.md`, `issue/close.md` |
| **1. Mandatory execution** | Each Phase X.X.W explicitly states "**NEVER** skipped under E2E Output Minimization" and emits an observable `[CONTEXT] WIKI_INGEST_DONE=1` / `WIKI_INGEST_SKIPPED=1; reason=...` / `WIKI_INGEST_FAILED=1; reason=...` line at completion (success / config-skip / commit-failure) | `pr/pr-review.md`, `pr/fix.md`, `issue/close.md` |
| **2. stderr observability** | Both legitimate skip (`wiki_ingest_skipped`) and commit failure (`wiki_ingest_failed`) emit a plain `WARNING` / `ERROR` line to stderr alongside the `[CONTEXT] WIKI_INGEST_SKIPPED=1` / `WIKI_INGEST_FAILED=1` status line. The orchestrator surfaces these in the conversation context; the user re-runs the affected step via `/rite:recover` if action is needed. | `pr/pr-review.md`, `pr/fix.md`, `issue/close.md` Phase X.X.W |
| **3. Lint growth check** | `lint.md` Phase 3.8 runs `wiki-growth-check.sh` which warns (non-blocking, `[lint:success]` retained) when `wiki.growth_check.threshold_prs` consecutive merged PRs land without a corresponding wiki branch commit. With layer 0 in place, a growth stall is a genuine regression signal (no longer confounded by fragile orchestration), and the warning is worth investigating promptly even though the contract remains non-blocking. | `wiki-growth-check.sh`, `lint.md` Phase 3.8 |

**Responsibility split after the refactor**: `wiki-ingest-commit.sh` commits **raw sources only**. LLM-driven Wiki **page** integration (reading raw sources, deciding create/update/skip, writing `.rite/wiki/pages/*`) is **deferred** to `/rite:wiki-ingest`, which is idempotent over accumulated raw sources and can be invoked at a later, independent time (manually or in a separate session). This separation guarantees that raw sources are never lost even when page integration is skipped or fails.

Layer 3's threshold is configurable via `wiki.growth_check.threshold_prs` (default: 5). Setting it to a very large number effectively disables the lint check while preserving layers 0-2.

The completion report (now emitted by `/rite:cleanup` after merge) **always** includes a "Wiki ingest 状況" section that aggregates these signals so the user has a definitive answer about whether the Wiki branch grew during each end-to-end flow (`/rite:open` → `/rite:iterate` → `/rite:ready` → `/rite:merge` → `/rite:cleanup`). This section is rendered even when all counters are zero — its absence would itself be a regression signal.

### Relationship to workflow failure surfacing

The two paths address distinct concerns:

| Concern | Destination |
|---------|-------------|
| **Recurring quality/process heuristics** (e.g., "review-fix loops should not skip LOW findings", "use dotenvx not dotenv") | Wiki pages via `/rite:wiki-ingest` |
| **One-time platform defects** (e.g., "hook X exited abnormally in iteration Y") | Surfaced as a plain `WARNING` / `ERROR` on stderr; the user files an Issue manually if it warrants follow-up (see [Workflow Failure Surfacing](#workflow-failure-surfacing)) |

They share no code paths.

## Sub-skill Return Auto-Continuation Contract

### Overview

When an orchestrator command (e.g., `/rite:open`, `/rite:iterate`, `/rite:issue-create`) invokes a sub-skill via the Skill tool and the sub-skill outputs its result pattern (e.g., `[lint:success]`, `[review:mergeable]`, `[ready:returned-to-caller]`, `[ingest:returned-to-caller]`), control returns to the orchestrator LLM. The orchestrator **MUST** continue executing the next phase in the **same response turn** — the sub-skill return is a continuation trigger, not a turn boundary. (Sentinel naming: `:returned-to-caller` replaced the older `:completed` form to prevent LLM turn-boundary heuristic misfires.)

Violating this contract leaves the workflow partially executed: no Issue created, `.rite-flow-state` stuck in `active: true`, stale timestamps, and the user forced to type `continue` manually to recover. This failure was observed multiple times in `/rite:issue-create` with the Bug Fix preset.

### The defense-in-depth layers

| Layer | Mechanism | Enforced by |
|-------|-----------|------------|
| ~~**1. Prompt contract**~~ (retired) | (Historical) Anti-pattern / correct-pattern examples + "same response turn" / "DO NOT stop" phrases + Mandatory After prose enforced caller chain continuation across sub-skill boundaries. The enforcement source sections (`skills/cleanup/SKILL.md` Sub-skill Return Protocol + Mandatory After Wiki Ingest, `skills/wiki-ingest/SKILL.md` Mandatory After Auto-Lint Step 0/1) have been **physically removed** because declarative defense layers triggered the `declarative-invariant-wording-layer-escalation` anti-pattern. cleanup.md is now a flat ステップ 1-12 task list and ingest/lint use minimum HTML sentinels. Continuation now relies on caller-continuation hints (Layer 3) + the orchestrator's flat sequential structure rather than imperative prose. | (historical: deleted from cleanup.md / ingest.md) |
| ~~**2. Flow state hard gate**~~ (retired) | (Historical) Sub-skills write `*_post_*` phase markers with `active: true` before return; `stop-guard.sh` blocked stop attempts until terminal phase. flow-state still records phase markers for observability but no longer enforces stops. | (historical: `hooks/stop-guard.sh`) |
| **3. Caller-continuation hints** (3 sub-layers 3a/3b/3c) | Plain-text reminder + HTML comment immediately before the sub-skill's result pattern. The plain-text line renders in user-facing output; the HTML comment is visible to the LLM via conversation context but does NOT render in Markdown. Dual form ensures robustness against rendering modes that strip comments. 3a = plain-text caller line, 3b = HTML comment caller mirror, 3c = sub-skill terminal sentinel comment. | Defense-in-Depth sections in `skills/issue-create/SKILL.md` (flat workflow ステップ 4.4 / 5.6), `skills/wiki-ingest/SKILL.md`, `skills/cleanup/SKILL.md`. |
| **4a. Pre-check list** | 4-item self-check the orchestrator runs before ending any response turn: (a) `[create:returned-to-caller:{N}]` output? (b) `✅ Issue #{N} を作成しました` shown? (c) `.rite-flow-state` deactivated? (d) last sub-skill tag handled as continuation trigger? A single `NO` means the workflow is mid-flight. Renamed from "Layer 4" to "Layer 4a" to avoid numbering collision with the new mechanical enforcement layer (4b below). | `skills/issue-create/SKILL.md` "Pre-check list" section |
| **4b. Completion message** | Terminal completion emits an explicit `✅ Issue #{N} を作成しました: {url}` line **before** the `<!-- [create:returned-to-caller:{N}] -->` sentinel (HTML-comment wrap form; sentinel renamed from `:completed` to `:returned-to-caller`). The sentinel remains grep-matchable for tooling (AC-4 backward compat) but is no longer the absolute last visible line. Renamed from "Layer 5" to "Layer 4b" (4a/4b grouping reflects that both are orchestrator-side completion reinforcements). | `skills/issue-create/SKILL.md` ステップ 4.4 (Single Issue 完了レポート) / ステップ 5.6 (Decompose 完了レポート) |
| ~~**4. Mechanical enforcement**~~ (retired) | (Historical) PostToolUse hook `auto-fire-step0.sh` (matcher `Skill`) fired after sub-skill Skill tool completion to patch `*_post_*` flow-state phases and inject continuation context. The mechanical enforcement layer was removed along with the implicit-stop guard layer; recovery now relies on `/rite:recover` rather than a runtime continuation hook. | (historical: `hooks/auto-fire-step0.sh`) |
| ~~**6. stop-guard incident emit**~~ (retired) | (Historical) When `stop-guard.sh` blocked an implicit stop, it emitted a `manual_fallback_adopted` workflow-incident sentinel for post-hoc visibility. Both the Stop hook and the workflow-incident mechanism have since been removed; an implicit stop now simply leaves the workflow mid-flight for the user to recover via `/rite:recover`. | (historical: `hooks/stop-guard.sh`) |

The remaining **primary active layers** are the caller HTML hint (Layer 3) and the orchestrator-side reinforcements (Layer 4a pre-check list, Layer 4b completion message). Layers 1, 2, 4, and 6 are retired and shown above only as historical context (Layer 1 was retired as part of the cleanup.md flat-化 refactor — declarative defense 層を物理排除した)。Weakening any active layer (e.g., loosening Layer 3 caller-continuation hints without strengthening Layer 4a/4b) re-opens the original implicit-stop failure mode. The flat-workflow refactor traded the mechanical enforcement layer for a simpler "user runs `/rite:recover` to recover" philosophy, accepting that occasional implicit stops will surface to the user; the trade-off was deemed favorable because the mechanical enforcement layer was itself a frequent failure source (auto-fire-step0.sh state mutations were hard to recover from when wrong).

### Contract specification

For every Skill tool invocation within an orchestrator:

1. When the sub-skill returns control (outputs its result pattern), the orchestrator LLM **MUST NOT** end its response.
2. The orchestrator **MUST NOT** re-invoke the completed sub-skill.
3. The orchestrator **MUST** execute its 🚨 Mandatory After section for the current phase, beginning with the `.rite-flow-state` update, then proceeding to the next phase — all in the same response turn.

> **Historical note (item 4, retired)**: A former item 4 instructed the orchestrator to follow `ACTION:` instructions on `stop-guard.sh` exit 2. With the Stop hook removed, this branch is unreachable at runtime — Layer 3 (caller HTML hint) and Layer 4a/4b (orchestrator-side reinforcements) are the active enforcement now that Layer 1 is retired.

The contract ends only when the orchestrator's terminal completion marker has been output:

| Orchestrator | Terminal marker |
|-------------|----------------|
| `/rite:open` | Step 6 completion notice listing the draft PR number/URL and the next-command suggestions (`/rite:iterate` / `/rite:ready` / `/rite:merge` / `/rite:cleanup`) |
| `/rite:iterate` | `[review:mergeable]` or `[fix:replied-only]` (whichever sub-skill returns first terminates the loop) / `[fix:cancelled-by-user]` (user-initiated cancel via fix.md AskUserQuestion) / `[iterate:max-cycles-reached]` (circuit breaker in a `/rite:batch-run` batch — the Issue is marked failed and the batch advances) / `[iterate:max-cycles-stopped]` (circuit breaker in interactive mode — user chose abort / leave-draft at the `safety.max_review_cycles` AskUserQuestion) |
| `/rite:ready` | `[ready:returned-to-caller]` (E2E flow) / completion display message (standalone) |
| `/rite:merge` | `[merge:returned-to-caller]` |
| `/rite:batch-run` | `<!-- [run:all-completed] -->` (all Issues completed; default = draft PRs left for review, `--merge` = merged/cleaned up) / `<!-- [run:stopped] -->` (stopped on first failure; processed/remaining Issues reported). `run-queue-{session_id}.json` (session-scoped filename — session_id derived from `flow-state.sh path`; each concurrent session holds an independent queue so parallel batch-runs cannot clobber each other, Issue #1859; unresolvable session_id fails loud rather than falling back to a global file) persists `{issues, cursor, mode, failed, active, updated_at}`: `mode` (`default`/`merge`; missing → `default` for backward compat), `failed` (Issues whose `/rite:iterate` tripped the `safety.max_review_cycles` circuit breaker → `[iterate:max-cycles-reached]`; missing → `[]`), `active` (true while the batch drives iterate, set false on stop; missing → `false` — consulted by `/rite:iterate` ステップ6 so a dormant queue is not misread as an active batch), and `updated_at` (ISO 8601 timestamp refreshed on cursor-advance (step 6) and active-set (steps 0/8) writes — not on step 1's coarse skip-closed cursor advance; missing → freshness unknown, treated as stale — consulted by `/rite:recover` Phase 5.5 to detect a genuine active-batch interruption vs. a stale leftover queue). Does NOT use flow-state handoff; per-Issue continuation rides each sub-skill's own mechanism |
| `/rite:issue-create` | `<!-- [create:returned-to-caller:{N}] -->` (HTML-comment wrap form) preceded by user-visible `✅ Issue #{N} を作成しました: {url}` and next-step guidance |

### Phase-aware continuation hints

> **Historical note**: Before the Stop hook was retired, these phase-specific continuation hints were emitted by the Stop hook (`stop-guard.sh`) when a stop attempt was blocked with an active per-session flow state. The hint table below is preserved as **prompt-level guidance** that the orchestrator surfaces directly when a sub-skill returns without producing the expected terminal marker. After Layer 1 retire これらの hints は Layer 3 (caller HTML hint) + Layer 4a/4b (orchestrator-side reinforcements) を介して伝達される。

| Active phase | Hint content |
|-------------|-------------|
| ~~`create_post_interview`~~ (retired) | (Historical) The flat-workflow consolidation merged this phase into `create.md`; the flow state no longer records it. |
| ~~`create_delegation`~~ (retired) | (Historical) Delegation phase は flat-workflow 統合で create.md 内部に取り込まれた |
| ~~`create_post_delegation`~~ (retired) | (Historical) Same as above |

These hints are **best-effort**: the primary enforcement is the orchestrator's flat sequential structure (cleanup.md ステップ 1-12 / pr/iterate.md ステップ 7 review-fix loop 等) と Layer 3 caller-continuation hints。Layer 1 prompt contract と「🚨 Mandatory After scaffolding」は物理排除され、現行は flat 構造そのものが mid-flight 中断を構造的に防ぐ責務を負う。

### Contract violation recovery (`auto_continuation_failed`, obsolete)

When the contract is violated in practice — i.e., the user types `continue` to recover — there is **no** automatic detection or registration. The orchestrator simply resumes from where it stopped.

> **History**: A follow-up (Decision Log D-02) once proposed an optional (`MAY`) `auto_continuation_failed` sentinel that would auto-register the violation as an Issue via start.md ステップ 8.5. That proposal depended on the workflow-incident mechanism, which has since been removed entirely. The `auto_continuation_failed` sentinel was never implemented and is now obsolete.

### Acceptance criteria

| AC | Description |
|----|-------------|
| AC-1 | bug fix preset で `/rite:issue-create` が end-to-end で `[create:returned-to-caller:{N}]` まで自動完了する（利用者の `continue` 介入なし） |
| AC-2 | M complexity 以上で flat create.md が同 turn 内で Single Issue → ステップ 4 (Heuristics + 出力) を実行する |
| ~~AC-3~~ (retired) | (Historical) `create.md` の Sub-skill Return Protocol セクションに "anti-pattern" / "correct-pattern" / "same response turn" / "DO NOT stop" の 4 phrase が全て含まれる。The dedicated section was consolidated into the flat workflow; the contract is now enforced by `skills/cleanup/SKILL.md` + `skills/wiki-ingest/SKILL.md` + the orchestrator's inline "Mandatory After" prose. |
| ~~AC-4~~ (obsolete) | (Historical) `auto_continuation_failed` sentinel 実装時、ステップ 8.5 で観測可能（MAY）。The workflow-incident mechanism was removed; this sentinel was never implemented. |
| AC-5 | Terminal Completion pattern (`[create:returned-to-caller:{N}]` + `.rite-flow-state active: false`) が引き続き動作する (non-regression) |
| AC-6 | Terminal sub-skill の最終出力に `✅` で始まるユーザー向け完了メッセージが含まれる。Register 経路: `✅ Issue #{N} を作成しました: {url}`、Decompose 経路: `✅ Issue #{N} を分解して {count} 件の Sub-Issue を作成しました: {url}`。いずれの形式も `[create:returned-to-caller:{N}]` は最終行として維持される |
| ~~AC-7~~ (retired) | (Historical) `stop-guard.sh` が `create_post_interview` / `create_delegation` / `create_post_delegation` phase で implicit stop を block した際、`manual_fallback_adopted` sentinel を emit する。Both the Stop hook layer and the workflow-incident mechanism were removed; implicit stops are now simply recovered by the user via `/rite:recover`. |
| AC-8 | `create.md` に "Pre-check list" セクションが存在し、4 項目全て `YES` が turn 終了の必要条件として文書化されている |

## Error Handling

### Auto-Retry

| Error Type | Retry Count | Interval |
|------------|-------------|----------|
| GitHub API temporary error (5xx) | 3 | Exponential backoff |
| Network error | 3 | 5 seconds |
| Rate limit (429) | 1 after wait | API-specified time |

### Manual Recovery Guidance

For persistent errors, provide:

1. **Detailed error explanation**
2. **Possible causes** (list if multiple)
3. **Recovery steps** (step-by-step)
4. **Links to related documentation**

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `gh: command not found` | gh CLI not installed | Guide in `/rite:setup` |
| `authentication required` | GitHub not authenticated | Guide `gh auth login` |
| `branch already exists` | Branch conflict | Suggest alternative name |
| `Context limit reached` | Long-running flow exceeded context window | `/clear` then `/rite:recover` |

### Context Limit Recovery

Long-running commands such as the end-to-end flow `/rite:open` → `/rite:iterate` (branch creation → implementation → PR creation → review-fix loop) may exceed Claude Code's context window and get interrupted with `Context limit reached`.

**Recovery steps:**

1. Run `/clear` to reset the context
2. Run `/rite:recover` to continue from where it left off

**Why this works:**

- Work memory (Issue comments + the local `.rite-work-memory/issue-{n}.md` file) and git/PR artifacts persist workflow state across sessions. The per-session flow state file is session-scoped (see [Multi-Session State Management](#multi-session-state-management)), so the post-`/clear` session reads a fresh empty file; `/rite:recover` reconstructs the resume point from work memory + git/PR cross-check, using flow state only as the same-session signal when present
- All git artifacts (branches, commits, PRs) are preserved — nothing is lost
- `/rite:recover` reads the persisted state and resumes the appropriate phase

**What is preserved:**

| Artifact | Storage | Survives context limit |
|----------|---------|------------------------|
| Branch | Git | Yes |
| Commits | Git | Yes |
| Draft PR | GitHub | Yes |
| Work memory | Issue comment | Yes |
| Flow state | `.rite/sessions/{session_id}.flow-state` (see [Multi-Session State Management](#multi-session-state-management)) | Partial — the file persists on disk, but the post-`/clear` session reads a fresh empty file (session-scoped); `/rite:recover` falls back to work memory + git/PR |

### API Error Handling

#### Retry Strategy

| Error Type | Response |
|-----------|----------|
| Network error | Max 3 retries (exponential backoff: 2s, 4s, 8s) |
| Rate limit (403/429) | Wait per `Retry-After` header, then retry |
| Auth error (401) | Display error, guide `gh auth login` |
| Not Found (404) | Display error, guide configuration check |
| Server error (5xx) | Max 2 retries (3s interval) |

#### Fallback Strategy

| Situation | Fallback Behavior |
|-----------|-------------------|
| Project API failure | Execute Issue creation only, skip Projects operations |
| Iteration API failure | Display warning, skip Iteration operations |
| Field update failure | Display warning, continue to next operation |
| Status update failure | Guide manual update method |

#### Error Message Format

```
Error: {error summary}

Cause: {possible cause}

Solution:
1. {step 1}
2. {step 2}

Details: {technical details for debugging}
```

---

## Migration

### Introducing to Existing Projects

**Hybrid Approach:**

- Existing Issues are read-only (viewable via `/rite:issue-list`)
- Edit/update only newly created Issues
- Auto-link if existing Projects found

### Version Upgrade

**Auto-Migration:**

1. Auto-convert configuration file format
2. Update Projects field structure
3. Create backup on breaking changes

---

## ~~Internationalization~~ (Retired)

> **Status: Retired**. The runtime i18n mechanism (`{i18n:key_name}` placeholder substitution, the `plugins/rite/i18n/` directory tree with `ja.yml` / `en.yml` legacy monolithic files and `ja/` / `en/` per-domain split files, and the `references/i18n-usage.md` reference doc) was deleted entirely (commit `d3a105f1`). All 364 placeholders across 10 remaining command/sub-skill files were resolved to inline Japanese, removing the runtime i18n resolution dependency. No language file structure remains in the plugin source tree.
>
> The remaining language-related controls are documentation-side conventions only. The `language` setting in `rite-config.yml` (still live) controls the output language of LLM-generated content — including commit messages (`skills/issue-implement/SKILL.md`, `skills/fix/SKILL.md`), PR title and body (`skills/pr-create/SKILL.md`), Issue creation prompts (`skills/issue-create/SKILL.md`), workflow / list output (`skills/workflow/SKILL.md`, `skills/issue-list/SKILL.md`). It does not select a runtime UI message catalog (no such catalog exists after the i18n retirement).

### Documentation language conventions

When authoring Japanese documentation or UI wording, the following terms are **kept in English** (not translated). `finding` is included in this set.

| Term | Note |
|------|------|
| `Issue` / `PR` (`Pull Request` も可) | GitHub の固有概念 |
| `Sprint` / `Iteration` | Iteration は GitHub Projects のフィールド名 |
| `finding` / `fingerprint` / `severity` / `confidence` | レビュー概念。「指摘」(UI の行為表現) とは概念的に別物 |
| `blocking` / `non-blocking` | finding の merge gate 効果 |
| `review-fix loop` | 一語のみ片仮名化可 (慣用) |
| GitHub Projects フィールド名 (`Status`, `Todo`, `In Progress`, `In Review`, `Done` 等) | GitHub UI と一致させる |
| `rite-config.yml` キー名 / コマンド名 (`/rite:open` 等) | 原文ママ |

`worktree` / `hook` / `sentinel` / `marker` 等の英語固有概念も、意味を保つ必要があれば英語のまま使用してよい。文体は常体 (である調)、半角英数字と日本語の間は半角スペース、YAML キー名・コマンド名・Projects フィールド名は翻訳しない。

**document-vs-inline split**: ドキュメント (`*.ja.md`) では `finding` を英語のまま使う。一方 skills / sub-skills の UI 文言では、ユーザーに見せる行為的表現として「指摘」を使い、技術識別子としては素の `finding` を保持する (旧 `plugins/rite/i18n/ja/` の使い分けを i18n 削除後も日本語直書きで継承)。

---

## Dependencies

### Required

| Tool | Purpose | Installation Check |
|------|---------|-------------------|
| gh CLI | GitHub API operations | `gh --version` |

### Optional

| Tool | Purpose |
|------|---------|
| Project-specific build tools | Build/Test/Lint |

---

## Distribution

Distributed via Claude Code plugin system:

```bash
# Add the marketplace
/plugin marketplace add asakaguchi/cc-rite-workflow

# Install the plugin
/plugin install rite@rite-marketplace

# Reload plugins to activate the new commands
/reload-plugins
```

---

## ~~Project Types~~ (Retired)

> **Status: Retired**. The `project.type` preset feature (`generic` / `webapp` / `library` / `cli` / `documentation`) and the associated `templates/project-types/*.yml` files were removed entirely. The Type-Specific PR templates (`templates/pr/{cli,library,webapp,documentation,fix-report}.md`) were also deleted in the same wave — only `templates/pr/generic.md` remains. Project-specific configuration is now expressed via the per-key YAML structure directly in `rite-config.yml` (see [CONFIGURATION.md](./CONFIGURATION.md) `~~Project Type Presets~~ (DEPRECATED)` section).
>
> The content below is preserved as **historical reference only** and does not reflect the v0.5.0 behavior. Do not consult these sections for current implementation guidance.

### Supported Types

| Type | Description | Characteristics |
|------|-------------|-----------------|
| `generic` | Universal | Basic field configuration |
| `webapp` | Web Application | Front/Back/DB separation |
| `library` | OSS Library | Breaking changes, CHANGELOG focus |
| `cli` | CLI Tool | Command changes, compatibility focus |
| `documentation` | Documentation | Build, link verification focus |

### Type-Specific PR Templates

#### generic

```markdown
## Summary
<!-- 1-2 sentence description -->

## Changes
- Change description

## Checklist
- [ ] Tested
- [ ] Documentation updated

Closes #XXX
```

#### webapp

```markdown
## Summary

## Changes
- [ ] Frontend
- [ ] Backend
- [ ] Database

## Screenshots
<!-- If applicable -->

## Test Plan
- [ ] Unit tests
- [ ] E2E tests
- [ ] Manual testing

## Performance Impact
<!-- If applicable -->

Closes #XXX
```

#### library

```markdown
## Summary

## Changes

## Breaking Changes
- [ ] None
- [ ] Yes (details: )

## Migration Guide
<!-- If breaking changes exist -->

## Tests
- [ ] Unit tests
- [ ] Integration tests

## Documentation
- [ ] API docs updated
- [ ] README updated
- [ ] CHANGELOG updated

Closes #XXX
```

#### cli

```markdown
## Summary

## Changes

## Command Changes
- [ ] New command added
- [ ] Existing command modified
- [ ] Options added/changed

## Compatibility
- [ ] Backward compatible
- [ ] Breaking changes

## Help/Manual
- [ ] --help updated
- [ ] man page updated

Closes #XXX
```

#### documentation

```markdown
## Summary

## Changes
- [ ] New documentation
- [ ] Existing documentation update
- [ ] Structure changes

## Checklist
- [ ] Build successful
- [ ] Links verified
- [ ] Spell checked
- [ ] Style guide compliant

## Preview
<!-- Preview URL, etc. -->

Closes #XXX
```

---

## Future Extensions

1. **Enhanced AI Code Review**
 - More detailed security analysis
 - Performance optimization suggestions

2. **CI/CD Integration**
 - GitHub Actions integration
 - Auto-deploy triggers

3. **Metrics & Dashboard**
 - Development velocity visualization
 - Issue resolution time analysis

---

## References

- [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices)
- [Claude Code Plugins Reference](https://code.claude.com/docs/en/plugins-reference)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
- [Conventional Commits](https://www.conventionalcommits.org/)
