# Fix Targeting Rules

Defines how fix targets are determined in the `/rite:issue:start` review-fix loop.

## Overview

All findings are always blocking regardless of loop count or severity. The review-fix loop continues until all findings are resolved (0 findings remaining) or `max_iterations` is reached.

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
| `max_iterations` reached | Loop exits with `[review:loop-limit:{n}]`, remaining findings converted to separate Issues |

## Caller Detection

Automatic target selection is applied only when `/rite:pr:fix` is called from within the `/rite:issue:start` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains execution context from `/rite:issue:start` Phase 5 "review-fix loop" | Within loop → Apply automatic selection (all findings) |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` (recent message) | Within loop → Apply automatic selection (all findings) |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options.
