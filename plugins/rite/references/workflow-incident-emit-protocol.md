# Workflow Incident Emit Protocol

Common emit protocol for workflow incident sentinels, referenced by **actual emit caller** sub-skills (`pr/review.md`, `pr/fix.md`, `pr/cleanup.md`, `issue/close.md`) and hook scripts (`state-read.sh`, `flow-state-update.sh` — emit indirectly via helper `_emit-cross-session-incident.sh`).

Centralizes the bash snippet, Sentinel Visibility Rule, and non-blocking guarantees to prevent drift across emit sites.

> **Reference**: See `start.md` Phase 5.4.4.1 "Workflow Incident Sentinel Visibility Rule" for the full orchestrator-side specification.

## Scope

| File | Status | Emit sites |
|------|--------|------------|
| `pr/review.md` | actual emit caller | 5 sites |
| `pr/fix.md` | actual emit caller | 5 sites |
| `pr/cleanup.md` | actual emit caller | 3 sites |
| `issue/close.md` | actual emit caller | 5 sites |
| `state-read.sh` / `flow-state-update.sh` | indirect emit (via `_emit-cross-session-incident.sh`) | 6 indirect sites (state-read.sh ×3 [foreign / corrupt / invalid_uuid arms] + flow-state-update.sh ×3 [foreign / corrupt / invalid_uuid arms]) |
| `commands/lint.md` (rite lint) | actual emit caller (declarative; 3 failure paths via Workflow Incident Emit Helper section + indirect `gitignore_drift` via `gitignore-health-check.sh`) | 3 declarative + 1 indirect |
| `commands/wiki/lint.md` / `pr/create.md` | **out of scope** (do not reference this protocol, do not emit) | 0 sites |

Total: **18 invocation sites across 4 files** (sub-skill: `pr/review.md` / `pr/fix.md` / `pr/cleanup.md` / `issue/close.md`). `commands/lint.md` の 3 declarative path は本 count に含まれない (sub-skill ではなく lint 専用の declarative emit のため別カウント)。

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
| `{plugin_root}` | [Plugin Path Resolution](./plugin-path-resolution.md#resolution-script-full-version) |
| `{sentinel_type}` | From the skill's failure paths table (`skill_load_failure`, `hook_abnormal_exit`, `manual_fallback_adopted`, `wiki_ingest_skipped`, `wiki_ingest_failed`, `wiki_ingest_push_failed`, `gitignore_drift`, `cross_session_takeover_refused`, `legacy_state_corrupt`) |
| `{specific failure description}` | From the skill's failure paths table |
| `{optional hypothesis}` | Optional root cause hint (may be empty) |
| `{pr_number}` | Current PR number, or `0` if no PR exists yet |

## Sentinel Visibility Rule (LLM Responsibility — Defensive Practice)

Sub-skills that **actually emit** execute inline within the orchestrator's conversation context. Bash tool call stdout is directly visible to the orchestrator, so sentinel lines emitted via the bash snippet above are automatically part of the conversation context.

As a **defensive practice**, sub-skills SHOULD still include the captured `sentinel_line` value verbatim in their final visible response text. This ensures sentinel detection remains robust even if execution context changes in the future.

**Concrete pattern**:

After executing Step 1 and Step 2, the LLM should include the `sentinel_line` value in its response as a defense-in-depth measure. Example:

```
[lint:error] — 3 errors detected
[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=rite:lint tool not found: ruff; iteration_id=0-1775650793
```

## Non-Blocking Guarantee

`|| true` ensures non-blocking behavior — emission failure does not abort the skill flow. The workflow MUST NOT halt because sentinel emission failed.

## Extended Pattern: Wiki Ingest Sentinel Emit

The `pr/review.md` Phase 6.5.W, `pr/fix.md` Phase 4.6.W, `pr/cleanup.md` Phase 4.W, `issue/close.md` Phase 4.4.W use an **extended pattern** that adds (a) stderr capture for emit-script failures, (b) trap-based tempfile cleanup, (c) canonical-format fallback emit (`hook_abnormal_exit`) when `workflow-incident-emit.sh` itself fails. This prevents both silent drop and orphan-format sentinels.

**Pattern shape** (see `pr/review.md` for the canonical full text):

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

**Future consolidation**: At 18 invocation sites the per-site drift exposure already exceeds the helper-extraction effort cost. When the next emit-pattern change is required (e.g., a new mandatory metadata field), prefer extracting `hooks/scripts/wiki-sentinel-emit.sh` and reducing each invocation to a 1-line call rather than synchronizing 18 inline sites manually.

> **Note for future PR**: When `wiki-sentinel-emit.sh` is extracted, update the Scope table above (1 helper × 18 callsites instead of 4 files × 18 sites) and revise the Pattern shape sample.

**Drift monitoring (current limits)**: Drift between sites can be **partially audited** via `hooks/scripts/distributed-fix-drift-check.sh` (covers `fix.md` / `review.md` / `tech-writer.md` only). **`cleanup.md` / `close.md` drift is currently unmonitored**, and **invocation-count drift across the 18 sites is not directly detected**. Full coverage requires either helper extraction (preferred) or a dedicated drift-check enhancement (separate Issue tracking).

## Configuration Boundary

Sentinel emission is bounded by `workflow_incident.enabled` in `rite-config.yml`. If disabled (`enabled: false`), the orchestrator simply ignores the sentinel. Skills should still emit sentinels regardless of this setting — the filtering is done at the orchestrator level.

## Revision Log

This section tracks corrections and significant changes to this protocol document. Earlier inline `cycle XX F-YY` notes were consolidated here in PR #688 cycle 9 F-12 (LOW) to improve readability for new readers; the protocol body now describes only the current specification.

> **Reading note** — entries are recorded in **chronological commit order**. PR #688 saw two review-fix runs (cycle 1〜44 followed by a post-cycle-44 re-review run that re-numbered cycles from 1〜15). As a result the table is **not** strictly monotonic in cycle number: the `cycle 9 F-12 LOW` row at the bottom is from the post-cycle-44 re-review run, not from before cycle 36. When in doubt, treat the row order as authoritative and the `cycle XX` label as a within-run identifier.

| Cycle | Change |
|-------|--------|
| cycle 36 F-09 | Expanded scope from "skill commands" to include hook scripts after `cross_session_takeover_refused` / `legacy_state_corrupt` types were added (which only hook scripts emit) |
| cycle 36 F-13 | Added `issue/close.md` to the Sentinel Visibility Rule list (close.md emits at Phase 4.4.W Step 1 [skip], Phase 4.4.W [trigger-failed], Phase 4.4.W.2 [skip / push-failed / other-failed]) |
| cycle 38 F-18 LOW | Documented that `state-read.sh` / `flow-state-update.sh` emit indirectly via the common helper `_emit-cross-session-incident.sh` (new readers could not reach direct callers via grep `workflow-incident-emit.sh`) |
| #524 | Added `wiki_ingest_skipped` / `wiki_ingest_failed` sentinel types |
| #555 | Added `wiki_ingest_push_failed` sentinel type |
| #567 | Added `gitignore_drift` sentinel type |
| #687 | Added `cross_session_takeover_refused` / `legacy_state_corrupt` sentinel types |
| PR #688 cycle 41 F-10 HIGH | Updated invocation site count from "15 sites across 3 files" undercount to actual "18 sites across 4 files" (missed `pr/cleanup.md`'s 3 sites) |
| PR #688 cycle 41 F-11 MEDIUM | Restricted sub-skill list to actual emit callers and added `pr/cleanup.md` (3 emit sites at Phase 4.W.1 [skip], Phase 4.W.3 [push-failed], Phase 4.W.3 [ingest-failed]) |
| PR #688 cycle 43 F-05 HIGH | Removed incorrect statement that `wiki/lint.md` / `pr/create.md` "reference this protocol in documentation" — runtime grep returned 0 references in both files; both are genuinely out of scope. **Note (cycle 12 F-01 HIGH 訂正)**: cycle 43 F-05 の grep 検査範囲は `commands/wiki/lint.md` のみで `commands/lint.md` (rite lint) を見落としていた。実際には `commands/lint.md` の `## Workflow Incident Emit Helper (#366)` section が本 protocol への reverse-reference link を持ち、続く failure path table で 3 件の declarative sentinel emit failure path (`manual_fallback_adopted` / `hook_abnormal_exit` × 2) を定義している。ファイル名衝突 (`lint.md` vs `wiki/lint.md`) 検査時は `find -name` で全候補列挙してから対象選択する手順を採用。**post-review F-04 (LOW) 修正**: cycle 12 F-04 で確立された「DRIFT-CHECK ANCHOR は semantic name 参照」doctrine に従い、line 番号参照 (`commands/lint.md:1108` / `L1106-1118`) を semantic section 名 (`## Workflow Incident Emit Helper (#366)` heading) に置換し line shift drift から守る |
| PR #688 cycle 43 F-10 MEDIUM | Added `cleanup.md Phase 4.W` to the Phase enumeration (the 3-phase list had drifted after cycle 41 F-11 added cleanup.md to the file count) |
| PR #688 cycle 43 F-11 MEDIUM | Corrected exaggerated drift-monitoring claim — `distributed-fix-drift-check.sh` only covers `fix.md` / `review.md` / `tech-writer.md`, not `cleanup.md` / `close.md`, and does not detect invocation-count drift |
| PR #688 cycle 9 F-12 LOW (post-cycle-44 re-review run) | Consolidated inline `cycle XX F-YY` revision notes into this Revision Log section. The protocol body now describes only the current specification, improving readability for new readers (8 lines / ≒9% of the body were meta-commentary). The `Scope` section was added to summarize the file ↔ status ↔ site-count matrix in one place |
