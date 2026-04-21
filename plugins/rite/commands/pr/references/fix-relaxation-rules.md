# Fix Targeting Rules

Defines how fix targets are determined in the `/rite:issue:start` review-fix loop.

## Overview

All findings are always blocking regardless of severity. The review-fix loop continues until all findings are resolved (**0 findings remaining is the only normal exit**).

## Fix Target Classification

All findings (CRITICAL/HIGH/MEDIUM/LOW) are always fix targets. There is no auto-defer mechanism.

| Severity | Classification | Action |
|----------|---------------|--------|
| CRITICAL | Blocking | Must fix |
| HIGH | Blocking | Must fix |
| MEDIUM | Blocking | Must fix |
| LOW | Blocking | Must fix |

## Loop Termination (v0.4.0 #557)

The review-fix loop exits via exactly two paths:

| Exit Type | Condition | Result |
|-----------|-----------|--------|
| **Normal** | 0 findings remaining | `[review:mergeable]` |
| **Escalate** | Any of the 4 quality signals fires | Present `AskUserQuestion` → user decides (continue / create separate Issue / withdraw / manual review) |

Cycle-count-based degradation (convergence strategy override / hard limit / severity gating) was fully removed in v0.4.0. See `commands/issue/start.md` Phase 5.4 for the escalate logic.

## Four Quality Signals for Escalation

Instead of cycle counting, the loop monitors quality signals that **each independently** indicate non-convergence. If any fires, the orchestrator escalates to the user.

| # | Signal | Detection | Where it runs |
|---|--------|-----------|---------------|
| 1 | **Same-finding cycling** | A finding fingerprint (file + category + normalised message) appears in two or more cycles | `start.md` Phase 5.4.1.0 |
| 2 | **Root-cause-missing fix** | A fix commit body lacks `Root cause:` / `根本原因:` section | `fix.md` Phase 3 (root-cause gate) |
| 3 | **Cross-validation disagreement** | Two or more reviewers report the same finding with severity gap ≥ 2 and debate fails to resolve | `review.md` Phase 5.2 + debate |
| 4 | **Finding quality gate failure** | Reviewer degrades itself (self-reports inability to provide confident findings) | `_reviewer-base.md` Finding Quality Guardrail |

Bikeshedding and defensive-code suggestions are filtered out by the Finding Quality Guardrail **before** output, so they never reach the loop counter. Only confident, evidence-backed findings participate in the fingerprint cycling signal.

## Caller Detection

**Scope**: このセクションは **fix target 選択**（Phase 2.1、どの findings を修正対象とするか）の caller-based 自動化のみを扱います。**separate issue creation**（Phase 4.3.3、skip findings の別 Issue 化可否の確認）は #506 以降、caller に関係なく **常に `AskUserQuestion` で確認** されるため、本 Caller Detection の対象外です。

Automatic fix target selection (Phase 2.1) is applied only when `/rite:pr:fix` is called from within the `/rite:issue:start` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains execution context from `/rite:issue:start` Phase 5 "review-fix loop" | Within loop → Apply automatic selection (all findings) |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` (recent message) | Within loop → Apply automatic selection (all findings) |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options. **Note**: Regardless of caller, separate-issue creation for skipped findings (Phase 4.3.3) always presents `AskUserQuestion` with options `retry in current PR / create separate issue / withdraw` as of #506.
