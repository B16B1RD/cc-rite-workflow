#!/usr/bin/env python3
"""rite workflow - Work Memory YAML Frontmatter Parser

Parses the YAML frontmatter from a local work memory file (.rite-work-memory/issue-{n}.md).
Reads from the first --- to the next ---, outputs JSON to stdout.

Usage:
    python3 work-memory-parse.py <file_path>
    python3 work-memory-parse.py --validate <file_path>

Exit codes:
    0: Success (valid frontmatter)
    1: File not found or read error
    2: Corrupt (missing header, invalid frontmatter, or missing required keys)
"""

import json
import re
import sys
from pathlib import Path


REQUIRED_KEYS = {"schema_version", "issue_number", "sync_revision"}

HEADER_MARKER = "# 📜 rite 作業メモリ"


def parse_frontmatter(content: str) -> dict | None:
    """Extract YAML frontmatter between first pair of --- delimiters.

    Returns parsed dict or None if frontmatter is not found/invalid.
    Uses simple line-based parsing (no PyYAML dependency).
    Single-pass: iterates lines once using a state machine.
    """
    result = {}
    in_frontmatter = False

    for line in content.split("\n"):
        stripped = line.strip()
        if stripped == "---":
            if not in_frontmatter:
                in_frontmatter = True
                continue
            else:
                # Closing delimiter found
                return result

        if not in_frontmatter:
            continue

        # Parse key-value pairs inside frontmatter
        if not stripped or stripped.startswith("#"):
            continue

        match = re.match(r'^([a-z_][a-z0-9_]*)\s*:\s*(.*)$', line)
        if not match:
            continue

        key = match.group(1)
        value = match.group(2).strip()

        # Remove surrounding quotes
        if (value.startswith('"') and value.endswith('"')) or \
           (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]

        # Type coercion
        if value == "null" or value == "~" or value == "":
            result[key] = None
        elif value == "true":
            result[key] = True
        elif value == "false":
            result[key] = False
        elif re.match(r'^-?\d+$', value):
            result[key] = int(value)
        else:
            result[key] = value

    # No closing --- found
    return None


def validate_work_memory(file_path: str, validate_only: bool = False) -> dict:
    """Parse and validate a work memory file.

    Returns a dict with:
        status: "valid" | "corrupt"
        data: parsed frontmatter dict (if valid)
        errors: list of error messages (if corrupt)
        file: input file path
    """
    path = Path(file_path)
    result = {"file": str(path), "status": "valid", "data": {}, "errors": [], "errno": None, "strerror": None}

    # Check file exists
    if not path.exists():
        result["status"] = "corrupt"
        result["errors"].append("file_not_found")
        return result

    try:
        content = path.read_text(encoding="utf-8")
    except OSError as e:
        result["status"] = "corrupt"
        result["errors"].append(f"read_error: {e}")
        result["errno"] = e.errno
        result["strerror"] = e.strerror
        return result
    except UnicodeDecodeError as e:
        result["status"] = "corrupt"
        result["errors"].append(f"read_error: {e}")
        return result

    # Check header marker
    if HEADER_MARKER not in content:
        result["status"] = "corrupt"
        result["errors"].append("missing_header")
        return result

    # Parse frontmatter
    frontmatter = parse_frontmatter(content)
    if frontmatter is None:
        result["status"] = "corrupt"
        result["errors"].append("no_frontmatter")
        return result

    result["data"] = frontmatter

    # Check required keys
    missing = REQUIRED_KEYS - set(frontmatter.keys())
    if missing:
        result["status"] = "corrupt"
        result["errors"].append(f"missing_keys: {', '.join(sorted(missing))}")

    # Cross-validate issue_number with filename
    if "issue_number" in frontmatter:
        match = re.search(r'issue-(\d+)\.md$', str(path))
        if match:
            file_issue = int(match.group(1))
            if frontmatter["issue_number"] != file_issue:
                result["status"] = "corrupt"
                result["errors"].append(
                    f"issue_number_mismatch: frontmatter={frontmatter['issue_number']}, filename={file_issue}"
                )

    return result


def main():
    if len(sys.argv) < 2:
        print("Usage: work-memory-parse.py [--validate] <file_path>", file=sys.stderr)
        sys.exit(1)

    validate_only = False
    file_path = sys.argv[1]

    if sys.argv[1] == "--validate":
        validate_only = True
        if len(sys.argv) < 3:
            print("Usage: work-memory-parse.py --validate <file_path>", file=sys.stderr)
            sys.exit(1)
        file_path = sys.argv[2]

    result = validate_work_memory(file_path, validate_only)
    print(json.dumps(result, ensure_ascii=False))

    if result["status"] == "corrupt":
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
