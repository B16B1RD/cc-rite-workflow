# Graduated Relaxation Rules (Fix Targeting)

Defines how fix targets and auto-defer candidates are determined based on loop count and gate mode in the `/rite:issue:start` review-fix loop.

## Overview

The graduated relaxation gate progressively reduces review strictness as the fix cycle count increases, allowing the loop to terminate when blocking issues are resolved while deferring non-blocking issues to separate Issues.

## Gate Mode and Loop Count

| Loop Count | Gate Mode | Behavior |
|------------|-----------|----------|
| 1-2 | Strict mode | All findings (CRITICAL/HIGH/MEDIUM/LOW) are blocking |
| 3-4 | MEDIUM/LOW relaxation | CRITICAL/HIGH are blocking, MEDIUM/LOW are non-blocking (auto-defer) |
| 5-6 | HIGH relaxation | CRITICAL is blocking, HIGH/MEDIUM/LOW are non-blocking (auto-defer) |
| 7+ | Force termination | All remaining findings are non-blocking (auto-defer all) |

## Automatic Target Selection

Within the `/rite:issue:start` review-fix loop, fix targets are automatically classified without user selection:

| Gate Mode | Fix Target (Blocking) | Auto-Defer (Non-blocking) |
|-----------|----------------------|--------------------------|
| Strict mode (loops 1-2) | CRITICAL/HIGH/MEDIUM/LOW | None |
| MEDIUM/LOW relaxation (loops 3-4) | CRITICAL/HIGH | MEDIUM/LOW |
| HIGH relaxation (loops 5-6) | CRITICAL | HIGH/MEDIUM/LOW |
| Force termination (loops 7+) | None | All remaining findings |

## Auto-Defer Recording

Auto-deferred findings are recorded with the skip reason:
```
Auto-deferred by loop relaxation (loop {loop_count}, severity: {severity}, gate: {gate_mode})
```

These findings are automatically sent to the separate Issue creation flow in Phase 4.3.

## Configuration

The `review.loop` settings in `rite-config.yml` define the loop count thresholds:

```yaml
review:
  loop:
    strict_limit: 2        # Loops 1-2: Strict mode
    medium_low_limit: 4    # Loops 3-4: MEDIUM/LOW relaxation
    high_limit: 6          # Loops 5-6: HIGH relaxation
    force_exit_limit: 7    # Loops 7+: Force termination
```

## Caller Detection

Automatic target selection (graduated relaxation gate) is applied only when `/rite:pr:fix` is called from within the `/rite:issue:start` loop:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains execution context from `/rite:issue:start` Phase 5 "review-fix loop" | Within loop → Apply automatic selection |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` (recent message) | Within loop → Apply automatic selection |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution → Display option selection |

For manual execution, users select targets via interactive options.
