# Workflow Incident Emit Protocol

Common emit protocol for workflow incident sentinels, referenced by skill commands (`lint.md`, `fix.md`, `review.md`). Centralizes the bash snippet, Sentinel Visibility Rule, and non-blocking guarantees to prevent drift across skills.

> **Reference**: See `start.md` Phase 5.4.4.1 "Workflow Incident Sentinel Visibility Rule" for the full orchestrator-side specification.

## How to Emit

Call this immediately before falling back to manual flow or returning a soft-failure pattern:

```bash
# Step 1: emit sentinel via hook script (silent capture, non-blocking via || true)
sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
  --type {sentinel_type} \
  --details "{specific failure description}" \
  --root-cause-hint "{optional hypothesis}" \
  --pr-number {pr_number} 2>/dev/null) || true

# Step 2: also echo to stderr for human-visible debugging
[ -n "$sentinel_line" ] && echo "$sentinel_line" >&2
```

**Placeholder values**:

| Placeholder | Source |
|-------------|--------|
| `{plugin_root}` | [Plugin Path Resolution](./plugin-path-resolution.md#resolution-script) |
| `{sentinel_type}` | From the skill's "When to emit" table (`skill_load_failure`, `hook_abnormal_exit`, `manual_fallback_adopted`) |
| `{specific failure description}` | From the skill's "When to emit" table |
| `{optional hypothesis}` | Optional root cause hint (may be empty) |
| `{pr_number}` | Current PR number, or `0` if no PR exists yet |

## Sentinel Visibility Rule (LLM Responsibility)

Skills declared with `context: fork` execute Bash tool calls in an **isolated subprocess context**. The orchestrator (`/rite:issue:start`) does NOT see subprocess `stdout` directly — it only sees the **final response message** that the sub-skill LLM returns.

**Therefore**: When a sub-skill emits a workflow incident sentinel via the bash snippet above, the sub-skill LLM **MUST also include the captured `sentinel_line` value verbatim in its final visible response text** (not only as bash stdout). Otherwise the orchestrator's context grep in Phase 5.4.4.1 will never see the sentinel and AC-5 (hook abnormal exit detection) becomes silently broken.

**Concrete pattern**:

After executing Step 1 and Step 2, the LLM must include the `sentinel_line` value in its response. Example:

```
[lint:error] — 3 errors detected
[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=rite:lint tool not found: ruff; iteration_id=0-1775650793
```

## Non-Blocking Guarantee

`|| true` ensures non-blocking behavior — emission failure does not abort the skill flow. The workflow MUST NOT halt because sentinel emission failed.

## Configuration Boundary

Sentinel emission is bounded by `workflow_incident.enabled` in `rite-config.yml`. If disabled (`enabled: false`), the orchestrator simply ignores the sentinel. Skills should still emit sentinels regardless of this setting — the filtering is done at the orchestrator level.
