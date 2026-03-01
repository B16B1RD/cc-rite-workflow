# Bash Defensive Patterns Reference

A collection of defensive Bash patterns to prevent recurring syntax errors in rite workflow command templates.

> **CRITICAL: All Bash code in command templates MUST use the defensive patterns defined in this document.**
>
> These patterns prevent the 4 most common runtime errors observed in rite workflow execution.
>
> **Applies to**: All command templates under `commands/` that contain Bash code blocks

---

## Table of Contents

- [Summary: Error Pattern → Defensive Pattern Mapping](#summary-error-pattern--defensive-pattern-mapping)
- [Pattern 1: Integer Comparison](#pattern-1-integer-comparison)
- [Pattern 2: grep Variable Expansion](#pattern-2-grep-variable-expansion)
- [Pattern 3: Python Inline Scripts with Japanese](#pattern-3-python-inline-scripts-with-japanese)
- [Pattern 4: Directory Pre-creation](#pattern-4-directory-pre-creation)
- [Quick Checklist for Template Authors](#quick-checklist-for-template-authors)

---

## Summary: Error Pattern → Defensive Pattern Mapping

| # | Error Message | Root Cause | Defensive Pattern |
|---|---------------|-----------|-------------------|
| 1 | `整数の式が予期されます` | Unquoted variable or missing default in `[ ]` integer comparison | `[[ "${var:-0}" -gt 0 ]]` |
| 2 | `grep: 無効なオプション -- ' '` | Unquoted variable passed to grep | `grep -- "$pattern"` + `|| true` |
| 3 | `SyntaxError: unterminated string literal` | Japanese strings in inline Python script (`python3 -c`) | File-based argument passing |
| 4 | `そのようなファイルやディレクトリはありません` | Missing directory before file write | `mkdir -p` before write |

---

## Pattern 1: Integer Comparison

### Vulnerable Pattern

```bash
count=$(echo "$result" | grep -c "pattern")
if [ $count -gt 0 ]; then
  echo "found"
fi
```

**Failure mode**: When `grep -c` finds 0 matches, it exits with code 1. Under `set -e`, this aborts the script before the assignment completes, leaving `$count` empty or unset. The `[` command then receives insufficient arguments and fails with `整数の式が予期されます`.

### Defensive Pattern

```bash
count=$(echo "$result" | grep -c "pattern" || true)
if [[ "${count:-0}" -gt 0 ]]; then
  echo "found"
fi
```

**Key changes**:
1. `|| true` — prevents `set -e` from aborting when grep finds 0 matches (exit code 1)
2. `[[ ]]` — handles empty/whitespace variables without word splitting
3. `${count:-0}` — provides default value `0` when variable is empty or unset

### Additional Examples

```bash
# Before (vulnerable)
if [ "$updated_length" -lt $((original_length / 2)) ]; then
  echo "WARNING: body too short" >&2
  exit 1
fi

# After (defensive)
if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
  echo "WARNING: body too short" >&2
  exit 1
fi
```

```bash
# Before (vulnerable)
if [ "$patch_status" -ne 0 ]; then
  echo "ERROR: PATCH failed" >&2
  exit 1
fi

# After (defensive)
if [[ "${patch_status:-1}" -ne 0 ]]; then
  echo "ERROR: PATCH failed" >&2
  exit 1
fi
```

---

## Pattern 2: grep Variable Expansion

### Vulnerable Pattern

```bash
echo "$body" | grep $pattern
echo "$body" | grep -c $pattern
```

**Failure mode**: When `$pattern` contains spaces or starts with `-`, grep interprets parts as options, producing `無効なオプション` errors.

### Defensive Pattern

```bash
echo "$body" | grep -- "$pattern" || true
echo "$body" | grep -c -- "$pattern" || true
```

**Key changes**:
1. `"$pattern"` — double quotes prevent word splitting
2. `--` — end-of-options separator prevents pattern from being interpreted as flags
3. `|| true` — prevents non-zero exit code when no matches found

### grep -c Specific Pattern

When using `grep -c` to count matches and storing the result:

```bash
# Defensive: capture count safely
match_count=$(echo "$body" | grep -c -- "$pattern" || true)
if [[ "${match_count:-0}" -gt 0 ]]; then
  echo "Found ${match_count} matches"
fi
```

---

## Pattern 3: Python Inline Scripts with Japanese

### Vulnerable Pattern

```bash
python3 -c "
import re
body = '''$body_content'''
updated = re.sub(r'現在のループ回数: \d+', '現在のループ回数: $new_count', body)
print(updated)
"
```

**Failure mode**: Shell variable expansion (`$body_content`) inside double-quoted `python3 -c` strings can produce unterminated string literals when the content contains quotes, triple-quotes, or backslashes. This pattern is especially common in this project because command templates frequently process Japanese text content via shell variable expansion.

### Defensive Pattern

```bash
# Write body to file first, pass file paths as arguments
printf '%s' "$body_content" > "$body_tmp"

python3 -c '
import sys, re

body_path, out_path, new_count = sys.argv[1], sys.argv[2], sys.argv[3]
with open(body_path, "r") as f:
    body = f.read()
updated = re.sub(
    r"^- \*\*現在のループ回数\*\*: \d+",
    f"- **現在のループ回数**: {new_count}",
    body, count=1, flags=re.MULTILINE
)
with open(out_path, "w") as f:
    f.write(updated)
' "$body_tmp" "$updated_tmp" "$new_loop_count"
```

**Key changes**:
1. Body content is written to a temp file, not embedded in the script
2. Python script is wrapped in single quotes — no shell expansion inside
3. File paths and simple values are passed as `sys.argv` arguments
4. Japanese regex patterns are safe inside Python string literals (not shell-expanded)

---

## Pattern 4: Directory Pre-creation

### Vulnerable Pattern

```bash
echo "$content" > .rite-work-memory/issue-123.md
printf '%s' "$backup" > /tmp/rite-backups/wm-backup.md
```

**Failure mode**: Parent directory does not exist, producing `そのようなファイルやディレクトリはありません`.

### Defensive Pattern

```bash
mkdir -p .rite-work-memory
echo "$content" > .rite-work-memory/issue-123.md

mkdir -p /tmp/rite-backups
printf '%s' "$backup" > /tmp/rite-backups/wm-backup.md
```

**Key changes**:
1. `mkdir -p` — creates directory and all parent directories if they don't exist
2. `-p` flag — no error if directory already exists (idempotent)
3. Place `mkdir -p` immediately before the first write to that directory

### Common Directories to Pre-create

| Directory | Purpose |
|-----------|---------|
| `.rite-work-memory/` | Local work memory files |
| `/tmp/rite-backups/` | Work memory backup files |
| `docs/designs/` | Design documents |

---

## Quick Checklist for Template Authors

Before adding Bash code to a command template, verify:

- [ ] All integer comparisons use `[[ ]]` with `${var:-default}`
- [ ] All `grep` invocations quote variables and use `--` separator
- [ ] All `grep -c` results are captured with `|| true`
- [ ] Python inline scripts use file-based argument passing (no shell variable embedding)
- [ ] All file writes are preceded by `mkdir -p` for the target directory
- [ ] All variables in `[ ]` or `[[ ]]` are double-quoted
