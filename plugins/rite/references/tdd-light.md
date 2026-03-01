# TDD Light Reference

Detailed specification for the TDD Light mode (Phase 5.1.0.T in implement.md). Generates test skeletons from acceptance criteria before implementation.

> **Note**: Section headings and definitions are in English. Output templates and user-facing messages are in Japanese per project i18n conventions.

## Table of Contents

- [Configuration](#configuration)
- [Tag Format](#tag-format)
- [Hash Normalization](#hash-normalization)
- [Criterion Summary Sanitization](#criterion-summary-sanitization)
- [Classification Logic](#classification-logic)
- [Output Processing](#output-processing)
- [Skeleton Templates](#skeleton-templates)
- [Idempotency Rules](#idempotency-rules)
- [Edge Cases](#edge-cases)

---

## Configuration

Read from `rite-config.yml`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `tdd.mode` | string | `"off"` | `off` or `light` |
| `tdd.tag_prefix` | string | `"AC"` | Tag prefix for test markers |
| `tdd.run_baseline` | bool | `true` | Run baseline test before skeleton generation |
| `tdd.max_skeletons` | int | `20` | Maximum skeletons per Issue |

**When `tdd` section is undefined**: Treat as `mode: "off"` (backward compatible).

---

## Tag Format

```
{tag_prefix}[{criterion_hash}]: {criterion_summary}
```

- Embedded in both fail messages and source comments
- Example: `AC[a1b2c3d4]: rite-config.yml に tdd セクションが追加されている`

---

## Hash Normalization

Input: raw acceptance criterion text. Output: SHA-256 first 8 hex characters.

**Normalization steps** (applied in order):

| Step | Operation | Example |
|------|-----------|---------|
| 1 | Remove checkbox prefix (`- [ ] `, `- [x] `, `- [X] `) | `- [ ] foo` → `foo` |
| 2 | CRLF → LF | `foo\r\n` → `foo\n` |
| 3 | Trim trailing whitespace per line | `foo  \n` → `foo\n` |
| 4 | Join nested items with ` \| ` | `parent\n  child` → `parent \| child` |

**Hash computation**:

```bash
echo -n "{normalized_text}" | sha256sum | cut -c1-8
```

---

## Criterion Summary Sanitization

Applied to `{criterion_summary}` portion of the tag:

| Rule | Limit | Action |
|------|-------|--------|
| Max length | 80 characters | Truncate with `...` |
| Single line | 1 line | Replace newlines with spaces |
| Dangerous characters | `"`, `'`, `` ` ``, `$`, `\` | Escape with `\` |

---

## Classification Logic

Two-phase evaluation: Phase A (output capture check) → Phase B (tag detection).

### Phase A: Output Capture Check

| Condition | Classification |
|-----------|---------------|
| Output file does not exist | `TDD_RUNNER_ABORTED_OR_BLOCKED` |
| Output file is 0 bytes AND exit code != 0 | `TDD_RUNNER_ABORTED_OR_BLOCKED` |

If neither matches, proceed to Phase B.

### Phase B: Tag Detection

Search for tag strings (`{tag_prefix}[`) in the test output.

| Exit Code | Tag Found | Classification | Meaning |
|-----------|-----------|---------------|---------|
| Non-zero | Yes | `TDD_RED_CONFIRMED` | Expected: tests fail with tag (success) |
| 0 | Yes | `TDD_TRIVIALLY_PASSING` | Unexpected: tests pass with tag |
| 0 | No | `TDD_ALL_PASSING` | No skeleton tests detected |
| Non-zero | No | `TDD_NO_SKELETON_OUTPUT` | Skeleton tests not reached |

### Classification Summary

| Label | Severity | Action |
|-------|----------|--------|
| `TDD_RED_CONFIRMED` | OK | Proceed to implementation |
| `TDD_TRIVIALLY_PASSING` | WARNING | Review skeleton — may be trivially true |
| `TDD_ALL_PASSING` | INFO | No skeleton tests found |
| `TDD_NO_SKELETON_OUTPUT` | WARNING | Skeleton tests may not be reachable |
| `TDD_RUNNER_ABORTED_OR_BLOCKED` | ERROR | Test runner failed to execute |

---

## Output Processing

### ANSI Escape Code Removal

```bash
set -o pipefail
TERM=dumb {test_command} 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$output_file"
test_rc=${PIPESTATUS[0]}
```

**Note**: Use `set -o pipefail` and `${PIPESTATUS[0]}` to capture the test command's exit code, not `sed`'s. The `sed` pattern `'s/\x1b\[[0-9;]*m//g'` targets SGR sequences (color/style). For broader ANSI escape removal (cursor control, title sequences), use `'s/\x1b\[[0-9;]*[A-Za-z]//g'` instead.

### Output File Path

```bash
output_file=$(mktemp)
trap 'rm -f "$output_file"' EXIT
```

---

## Skeleton Templates

Framework detection is based on project files and `commands.test` configuration.

### Jest / Vitest

```typescript
describe('Acceptance Criteria', () => {
  test('{tag_prefix}[{criterion_hash}]: {criterion_summary}', () => {
    throw new Error('NOT_IMPLEMENTED: {tag_prefix}[{criterion_hash}]: {criterion_summary}');
  });
});
```

**Note**: `test.todo()` does not cause test failure (exit code 0) and may not output the tag string, which prevents `TDD_RED_CONFIRMED` classification. Use `throw new Error()` to guarantee non-zero exit code and tag presence in output.

### pytest

```python
import pytest

def test_{snake_case_summary}():
    pytest.fail("{tag_prefix}[{criterion_hash}]: {criterion_summary}")
```

**Note**: Do not use `@pytest.mark.skip` — it prevents `pytest.fail()` from executing, resulting in exit code 0 instead of the required non-zero for `TDD_RED_CONFIRMED`.

### Go testing

```go
func Test_{PascalCaseSummary}(t *testing.T) {
	t.Fatal("{tag_prefix}[{criterion_hash}]: {criterion_summary}")
}
```

**Note**: Do not use `t.Skip()` — it stops test execution before `t.Fatal()`, resulting in exit code 0 instead of the required non-zero for `TDD_RED_CONFIRMED`.

### Generic (unknown framework)

When the test framework cannot be determined, skip skeleton generation entirely to prevent compile errors. Record a skip stub in work memory TDD state.

---

## Idempotency Rules

### Global Skip

Skeleton generation is skipped when **both** conditions are true:

1. `tdd_state.skeleton_generated` is `true` in work memory
2. Tag strings exist in the codebase (verified via `grep -r "{tag_prefix}["`)

### Per-Criterion Skip

Individual criterion skeletons are skipped when the tag string already exists in a test file (scanned per file in the test directory).

### Tag Disappearance Recovery

When `tdd_state.skeleton_generated` is `true` but tags are not found in codebase:

```
WARNING: TDD tags not found despite skeleton_generated=true. Regenerating skeletons.
```

Reset `skeleton_generated` to `false` and re-run generation.

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Baseline has existing failures | Record failures and continue (`run_baseline` logs only) |
| Issue body lost to context compaction | Re-fetch via `gh issue view {issue_number} --json body --jq '.body'` |
| No acceptance criteria section | Record skip stub, skip generation |
| Framework not detectable | Skip generation (prevent compile errors), record skip stub |
| `commands.test: null` | Auto-skip (no test runner available) |
| `max_skeletons` exceeded | Generate up to limit, warn about remaining |

---

## Related

- [implement.md Phase 5.1.0.T](../commands/issue/implement.md) — Summary and invocation
- [Work Memory Format - TDD State](../skills/rite-workflow/references/work-memory-format.md) — State tracking
- [Bottleneck Detection](./bottleneck-detection.md) — Similar Oracle-based reference pattern
