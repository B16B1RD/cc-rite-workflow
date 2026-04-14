# Fix Targeting Rules

Defines how fix targets are determined in the `/rite:issue:start` review-fix loop.

## Overview

All findings are always blocking regardless of severity. The review-fix loop continues until all findings are resolved (0 findings remaining).

## Fix Target Classification

All findings (CRITICAL/HIGH/MEDIUM/LOW) are always fix targets. There is no auto-defer mechanism.

| Severity | Classification | Action |
|----------|---------------|--------|
| CRITICAL | Blocking | Must fix |
| HIGH | Blocking | Must fix |
| MEDIUM | Blocking | Must fix |
| LOW | Blocking | Must fix |

## Loop Termination

| Condition | Result |
|-----------|--------|
| 0 findings remaining | Loop exits with `[review:mergeable]` |
| `loop_count >= safety.max_review_fix_loops` | Loop halted by hard limit (#453). User chooses: extend (+5) / retry in current PR / escalate (the severity gating option was removed in #506) |

The primary exit condition is zero findings. The hard limit (`safety.max_review_fix_loops`, default: 7) provides a safety net against infinite loops.

## Convergence Strategy Override (#453)

When the convergence monitor (start.md Phase 5.4.1.0) detects non-convergence and the user selects a strategy, the fix target classification is overridden:

| Strategy | CRITICAL | HIGH | MEDIUM | LOW |
|----------|----------|------|--------|-----|
| `"none"` (default) | Blocking | Blocking | Blocking | Blocking |
| ~~`"severity_gating"`~~ (DEPRECATED #506) | ~~Blocking~~ | ~~Blocking~~ | ~~**Deferred**~~ | ~~**Deferred**~~ |
| `"batched"` | Blocking (batch) | Blocking (batch) | Blocking (batch) | Blocking (batch) |
| `"scope_lock"` | Blocking (original files only) | Blocking (original files only) | Blocking (original files only) | Blocking (original files only) |

> **DEPRECATED (#506)**: `"severity_gating"` strategy は #506 で廃止されました。本 PR 起因 findings は severity 問わず本 PR 内で対応する方針（本 PR 完結原則）に変更され、非収束時は fix.md Phase 4.3.3 の AskUserQuestion（`本 PR 内で再試行 / 別 Issue 化 / 取り下げ`）に統合されています。`rite-config.yml` の `fix.severity_gating.enabled` は後方互換のため残置されていますが `false` 固定扱いで参照されません。新規の非収束対応は `"batched"` または `"scope_lock"` strategy を使用してください。

**Scope lock details**: Findings in files that were added or modified by fix commits (not in the original PR diff) are deferred. This prevents the positive feedback loop where "fix adds defensive code → review finds issues in defensive code → fix adds more defensive code".

## Caller Detection

**Scope**: このセクションは **fix target 選択**（Phase 2.1、どの findings を修正対象とするか）の caller-based 自動化のみを扱います。**separate issue creation**（Phase 4.3.3、skip findings の別 Issue 化可否の確認）は #506 以降、caller に関係なく **常に `AskUserQuestion` で確認** されるため、本 Caller Detection の対象外です。

Automatic fix target selection (Phase 2.1) is applied only when `/rite:pr:fix` is called from within the `/rite:issue:start` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains execution context from `/rite:issue:start` Phase 5 "review-fix loop" | Within loop → Apply automatic selection (all findings) |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` (recent message) | Within loop → Apply automatic selection (all findings) |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options. **Note**: Regardless of caller, separate-issue creation for skipped findings (Phase 4.3.3) always presents `AskUserQuestion` with options `retry in current PR / create separate issue / withdraw` as of #506.
