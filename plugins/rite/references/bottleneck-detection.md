# Bottleneck Detection Reference

Detection thresholds, Oracle discovery protocol, and step re-decomposition procedure for implementation bottlenecks.

## Overview

During implementation (Phase 5.1), each step is monitored for bottleneck symptoms. When a bottleneck is detected, execution pauses to discover similar implementations (Oracle pattern) in the codebase and re-decompose the problematic step into smaller sub-steps.

**Oracle pattern**: Using existing correct implementations in the codebase as structural guides for new or problematic implementations. Instead of building from scratch, the AI reads reference files with similar structure/purpose and uses their patterns (section organization, naming conventions, error handling) as a template for decomposition and implementation.

> **Note**: Section headings and definitions are in English. Output templates and user-facing messages are in Japanese per project i18n conventions.

### Table of Contents

- [Bottleneck Detection Thresholds](#bottleneck-detection-thresholds) - Threshold conditions and measurement
- [Oracle Discovery Protocol](#oracle-discovery-protocol) - Priority-based reference discovery
- [Step Re-decomposition Procedure](#step-re-decomposition-procedure) - Breaking down bottlenecked steps
- [Work Memory Recording Format](#work-memory-recording-format) - Logging format for detection events
- [Integration Points](#integration-points) - Cross-references to related components

---

## Bottleneck Detection Thresholds

A step is classified as a bottleneck when **any** of the following thresholds is exceeded:

| Threshold | Condition | Measurement Method |
|-----------|-----------|-------------------|
| Round count | > 3 rounds on a single step | Count tool call round-trips (Read/Edit/Bash cycles) within the step |
| File count | > 5 files touched in a single step | Count distinct files modified (Edit/Write) or created within the step |
| Line count | > 200 lines changed in a single step | Sum of insertions + deletions across all files within the step |

### Measurement Details

**Round count**: A "round" is one cycle of: read file(s) → edit/write → verify (optional). Parallel tool calls within a single message count as 1 round.

**File count**: Count unique file paths passed to Edit or Write tools within the current step. Reading files (Read tool) does not count.

**Line count**: Approximate by counting lines in `old_string` (deletions) and `new_string` (insertions) passed to Edit tool, or total lines in Write tool content for new files.

### Detection Timing

Check thresholds at the **adaptive re-evaluation checkpoint** (5.1.0.5) — immediately after each step completion. This integrates naturally with the existing re-evaluation flow without adding overhead during active implementation.

### When No Bottleneck is Detected

Proceed normally through the re-evaluation checkpoint. The bottleneck detection adds zero overhead to the normal (non-bottleneck) path — it is a guard clause that returns immediately when thresholds are not exceeded.

---

## Oracle Discovery Protocol

When a bottleneck is detected, discover similar implementations in the codebase to guide step re-decomposition.

### Input Priority

Oracle inputs are checked in the following priority order. Stop at the first level that yields results:

| Priority | Source | Description |
|----------|--------|-------------|
| 1 | Phase 3.2.1 references | Reference implementations already discovered during plan generation. These are retained in conversation context and work memory |
| 2 | Same directory / pattern search | Search for files with similar structure in the same directory or matching naming patterns |
| 3 | Test result reverse lookup | If tests exist and have been run, trace test targets back to their implementations for structural reference |

### Discovery Procedure

#### Priority 1: Reuse Existing References

Check if the implementation plan (Phase 3) included reference implementations in the "参考実装" section. If references exist and are relevant to the current bottlenecked step:

1. Re-read the reference file(s) with Read tool (if not already in context)
2. Extract the structural pattern relevant to the bottleneck
3. Proceed to [Step Re-decomposition](#step-re-decomposition-procedure)

**Relevance check**: A reference is relevant if it shares the same file type AND at least one of: same directory, similar naming pattern, similar functionality (determined by AI judgment based on file content).

#### Priority 2: Same Directory / Pattern Search

If Priority 1 yields no relevant references:

1. **Same directory search**: Use Glob tool with `{current_file_directory}/*.{ext}` to find sibling files
2. **Name pattern search**: Extract naming patterns from the bottlenecked file and search with Glob tool
   - Example: editing `implement.md` → search `commands/issue/*.md`
3. **Read candidates**: Read up to 2 candidate files (prioritize by modification time — more recent first)
4. Extract structural patterns relevant to the bottleneck

#### Priority 3: Test Result Reverse Lookup

If Priority 2 yields no results:

1. Search for test files corresponding to the bottlenecked file:
   - Pattern: `{name}.test.{ext}`, `{name}.spec.{ext}`, `tests/{name}.*`
2. If test files exist, read them to understand the expected structure
3. Use the test structure as a guide for decomposition

**When no Oracle is found at any priority level**: Proceed with re-decomposition using general heuristics (see "Fallback Decomposition" below).

---

## Step Re-decomposition Procedure

After discovering an Oracle (or falling back to heuristics), decompose the bottlenecked step into smaller sub-steps.

### Re-decomposition Flow

```
ボトルネック検出
├─ Oracle 発見
│   ├─ 優先度1: 既存の参考実装を再利用 → 構造パターンに基づき分解
│   ├─ 優先度2: 同ディレクトリ/パターン検索 → 類似ファイル構造に基づき分解
│   └─ 優先度3: テスト逆引き → テスト構造に基づき分解
└─ Oracle なし
    └─ フォールバック分解 → 一般的ヒューリスティクスに基づき分解
```

### Decomposition Based on Oracle

When an Oracle is found, use its structure as a template:

1. **Identify structural units**: Sections, functions, classes, or logical blocks in the Oracle file
2. **Map to current step**: Match each structural unit to a portion of the current step's work
3. **Create sub-steps**: Each mapped portion becomes a sub-step with explicit dependencies

### Fallback Decomposition (No Oracle)

When no Oracle is found, apply these heuristics:

| Heuristic | When to Apply | Decomposition Strategy |
|-----------|---------------|----------------------|
| File boundary | Step touches > 3 files | One sub-step per file (or logical file group) |
| Section boundary | Single large file edit | One sub-step per logical section (heading, function, class) |
| Dependency order | Step has internal dependencies | Split into: data model → logic → integration |

### Sub-step Format

Re-decomposed sub-steps are inserted into the dependency graph as children of the original step:

```
元のステップ: S{n} (ボトルネック検出)
分解後:
| Step | 内容 | depends_on |
|------|------|------------|
| S{n}.1 | {sub_step_1} | — |
| S{n}.2 | {sub_step_2} | S{n}.1 |
| S{n}.3 | {sub_step_3} | S{n}.1 |
```

Sub-step IDs use dot notation (`S{n}.1`, `S{n}.2`) to maintain traceability to the original step.

### User Notification

Display after re-decomposition:

```
⚠️ ボトルネック検出: Step S{n} ({step_description})
検出理由: {threshold_exceeded} （{actual_value}/{threshold_value}）

Oracle: {oracle_source} ({oracle_file_path})

再分解:
| Step | 内容 | depends_on |
|------|------|------------|
| S{n}.1 | {sub_step_1} | — |
| S{n}.2 | {sub_step_2} | S{n}.1 |

→ 次に実行: Step S{n}.1
```

When no Oracle is found:

```
⚠️ ボトルネック検出: Step S{n} ({step_description})
検出理由: {threshold_exceeded} （{actual_value}/{threshold_value}）

Oracle: なし（フォールバック分解を適用）

再分解:
| Step | 内容 | depends_on |
|------|------|------------|
| S{n}.1 | {sub_step_1} | — |
| S{n}.2 | {sub_step_2} | S{n}.1 |

→ 次に実行: Step S{n}.1
```

---

## Work Memory Recording Format

Record bottleneck detection and re-decomposition events in the work memory's "ボトルネック検出ログ" section.

### Section Template

Add this section to work memory (after "計画逸脱ログ"):

```markdown
### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->

| 検出時刻 | Step | 検出理由 | Oracle | 再分解 |
|---------|------|---------|--------|-------|
| {timestamp} | S{n} | {reason} | {oracle_source}: {oracle_path} | S{n}.1, S{n}.2, ... |
```

### Field Definitions

| Field | Description | Example |
|-------|-------------|---------|
| 検出時刻 | ISO 8601 timestamp | `2026-02-15T12:00:00+09:00` |
| Step | Original step ID | `S3` |
| 検出理由 | Which threshold was exceeded | `ラウンド数超過 (5/3)` |
| Oracle | Source and file path | `Phase 3.2.1: implement.md` or `同ディレクトリ: create.md` or `なし` |
| 再分解 | List of sub-step IDs | `S3.1, S3.2, S3.3` |

### Recording Timing

Record in work memory at the next bulk update point (typically at commit time, per implement.md 5.1.0.5). This avoids excessive API calls for work memory updates during implementation.

---

## Integration Points

| Component | Integration |
|-----------|-------------|
| `implement.md` 5.1.0.5 | Bottleneck check added to adaptive re-evaluation checkpoint |
| `implementation-plan.md` 3.5.1 | Mid-replanning: re-insert sub-steps into plan and work memory |
| `coding-principles.md` `reference_discovery` | Oracle discovery reuses the same search patterns |
| `execution-metrics.md` `plan_deviation_count` | Each re-decomposition counts as a plan deviation |
| `work-memory-format.md` | New "ボトルネック検出ログ" section added |

---

## Related

- [Implementation Guidance](../commands/issue/implement.md) - 5.1.0.5 Adaptive Re-evaluation
- [Implementation Plan](../commands/issue/implementation-plan.md) - 3.2.1 Reference Implementation Discovery
- [AI Coding Principles](../skills/rite-workflow/references/coding-principles.md) - `reference_discovery` principle
- [Execution Metrics](./execution-metrics.md) - `plan_deviation_count` metric
- [Work Memory Format](../skills/rite-workflow/references/work-memory-format.md) - "ボトルネック検出ログ" section format
