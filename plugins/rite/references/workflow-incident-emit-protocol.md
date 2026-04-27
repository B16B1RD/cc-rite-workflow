# Workflow Incident Emit Protocol

Common emit protocol for workflow incident sentinels, referenced by sub-skills (`lint.md`, `pr/create.md`, `pr/fix.md`, `pr/review.md`, `issue/close.md`) and hook scripts (`state-read.sh`, `flow-state-update.sh`). Centralizes the bash snippet, Sentinel Visibility Rule, and non-blocking guarantees to prevent drift across emit sites. cycle 36 F-09 fix expanded scope from "skill commands" to include hook scripts after `cross_session_takeover_refused` / `legacy_state_corrupt` types were added (which only hook scripts emit).

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
| `{sentinel_type}` | From the skill's failure paths table (`skill_load_failure`, `hook_abnormal_exit`, `manual_fallback_adopted`, `wiki_ingest_skipped` (#524), `wiki_ingest_failed` (#524), `wiki_ingest_push_failed` (#555), `gitignore_drift` (#567), `cross_session_takeover_refused` (#687), `legacy_state_corrupt` (#687)) |
| `{specific failure description}` | From the skill's failure paths table |
| `{optional hypothesis}` | Optional root cause hint (may be empty) |
| `{pr_number}` | Current PR number, or `0` if no PR exists yet |

## Sentinel Visibility Rule (LLM Responsibility — Defensive Practice)

Sub-skills (`lint.md`, `pr/create.md`, `pr/fix.md`, `pr/review.md`, `issue/close.md`) execute inline within the orchestrator's conversation context. Bash tool call stdout is directly visible to the orchestrator, so sentinel lines emitted via the bash snippet above are automatically part of the conversation context. cycle 36 F-13 fix added `issue/close.md` to this list (close.md emits at L390/468/546/571/591 for various failure paths).

As a **defensive practice**, sub-skills SHOULD still include the captured `sentinel_line` value verbatim in their final visible response text. This ensures sentinel detection remains robust even if execution context changes in the future.

**Concrete pattern**:

After executing Step 1 and Step 2, the LLM should include the `sentinel_line` value in its response as a defense-in-depth measure. Example:

```
[lint:error] — 3 errors detected
[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=rite:lint tool not found: ruff; iteration_id=0-1775650793
```

## Non-Blocking Guarantee

`|| true` ensures non-blocking behavior — emission failure does not abort the skill flow. The workflow MUST NOT halt because sentinel emission failed.

## Extended Pattern: Wiki Ingest Sentinel Emit (#524)

The `pr/review.md` Phase 6.5.W, `pr/fix.md` Phase 4.6.W, `issue/close.md` Phase 4.4.W use an **extended pattern** that adds (a) stderr capture for emit-script failures, (b) trap-based tempfile cleanup, (c) canonical-format fallback emit (`hook_abnormal_exit`) when `workflow-incident-emit.sh` itself fails. This prevents both silent drop and orphan-format sentinels.

**Pattern shape** (see `pr/review.md` for the canonical full text — 6 invocation sites total across 3 files):

```bash
emit_err=$(mktemp /tmp/rite-wiki-emit-err-XXXXXX 2>/dev/null) || emit_err=""
trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
    --type wiki_ingest_{skipped|failed} ... 2>"${emit_err:-/dev/null}"); then
  if [ -n "$sentinel_line" ]; then
    echo "$sentinel_line"          # canonical: stdout (orchestrator context)
    echo "$sentinel_line" >&2      # defense-in-depth: stderr (human debug)
  fi
else
  # workflow-incident-emit.sh failed → emit canonical fallback so Phase 5.4.4.1 still detects
  fallback_iter="{pr_number}-$(date +%s)"
  fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=...; iteration_id=$fallback_iter"
  echo "$fallback_sentinel"
  echo "$fallback_sentinel" >&2
  echo "WARNING: ..." >&2
  [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
fi
[ -n "$emit_err" ] && rm -f "$emit_err"
trap - EXIT INT TERM HUP
```

**Future consolidation**: When 4+ skill files adopt the extended pattern, extract into a helper script `hooks/scripts/wiki-sentinel-emit.sh` and reduce each invocation to a 1-line call. Currently kept inline (3 files × 2 sites) to avoid premature abstraction. Drift between sites is monitored manually until the helper is justified.

## Configuration Boundary

Sentinel emission is bounded by `workflow_incident.enabled` in `rite-config.yml`. If disabled (`enabled: false`), the orchestrator simply ignores the sentinel. Skills should still emit sentinels regardless of this setting — the filtering is done at the orchestrator level.
