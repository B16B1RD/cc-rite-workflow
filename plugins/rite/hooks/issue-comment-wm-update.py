#!/usr/bin/env python3
"""rite workflow - Issue Comment Work Memory Update

Pure text transformation script for updating work memory comment body.
Reads body from stdin, applies transformations, writes updated body to stdout.
No API calls — all GitHub API operations are handled by the calling bash script.

Usage:
    cat body.txt | python3 issue-comment-wm-update.py update-progress \
        --impl-status "✅ 完了" --test-status "⬜ 未着手" --doc-status "⬜ 未着手" \
        --changed-files-file /tmp/files.md > updated.txt

    cat body.txt | python3 issue-comment-wm-update.py update-phase \
        --phase "phase5_review" --phase-detail "レビュー中" > updated.txt

    cat body.txt | python3 issue-comment-wm-update.py update-plan-status > updated.txt

    cat body.txt | python3 issue-comment-wm-update.py append-section \
        --section "品質チェック履歴" --content-file /tmp/lint.md > updated.txt

    cat body.txt | python3 issue-comment-wm-update.py replace-section \
        --section "次のステップ" --content-file /tmp/next.md > updated.txt

    cat body.txt | python3 issue-comment-wm-update.py update-checkboxes \
        --tasks "task1,task2" > updated.txt

Exit codes:
    0: Success (updated body written to stdout)
    1: Usage error (missing arguments, unknown option)
    2: File read error (content-file or changed-files-file not found)
"""

import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path


def get_timestamp() -> str:
    """Generate ISO 8601 timestamp in JST."""
    jst = timezone(timedelta(hours=9))
    return datetime.now(jst).strftime("%Y-%m-%dT%H:%M:%S+09:00")


def update_progress(body: str, impl_status: str, test_status: str,
                    doc_status: str, changed_files_md: str | None = None,
                    timestamp: str | None = None) -> str:
    """Update progress summary table (v2/v1 auto-detection) and changed files section."""
    ts = timestamp or get_timestamp()

    # v2 format: Markdown table (| 実装 | ⬜ 未着手 | - |)
    v2_updated = False
    for item, status in [("実装", impl_status), ("テスト", test_status), ("ドキュメント", doc_status)]:
        pattern = r"(\| " + re.escape(item) + r" \| ).*?( \|.*\|)"
        new_body = re.sub(pattern, lambda m: m.group(1) + status + m.group(2), body, count=1)
        if new_body != body:
            v2_updated = True
        body = new_body

    # v1 format fallback: checkbox style (- [ ] 実装開始 → - [x] 実装開始)
    if not v2_updated:
        if "### 進捗" in body and "### 進捗サマリー" not in body:
            for item, status in [("実装", impl_status), ("テスト", test_status), ("ドキュメント", doc_status)]:
                if "完了" in status:
                    body = re.sub(r"- \[ \] " + re.escape(item), "- [x] " + item, body, count=1)

    # Update changed files section
    if changed_files_md is not None:
        pattern = r"(### 変更ファイル\n)(?:<!-- .*?-->\n)?.*?(?=\n### |\Z)"
        body = re.sub(pattern, r"\g<1>" + changed_files_md, body, count=1, flags=re.DOTALL)

    # Update timestamp
    body = re.sub(
        r"^(- \*\*最終更新\*\*: ).*",
        lambda m: m.group(1) + ts,
        body, count=1, flags=re.MULTILINE
    )

    return body


def update_phase(body: str, phase: str, phase_detail: str,
                 timestamp: str | None = None) -> str:
    """Update session info phase fields."""
    ts = timestamp or get_timestamp()

    body = re.sub(
        r"^(- \*\*最終更新\*\*: ).*",
        lambda m: m.group(1) + ts,
        body, count=1, flags=re.MULTILINE
    )
    body = re.sub(
        r"^(- \*\*フェーズ\*\*: ).*",
        lambda m: m.group(1) + phase,
        body, count=1, flags=re.MULTILINE
    )
    body = re.sub(
        r"^(- \*\*フェーズ詳細\*\*: ).*",
        lambda m: m.group(1) + phase_detail,
        body, count=1, flags=re.MULTILINE
    )

    return body


def update_plan_status(body: str) -> str:
    """Bulk-update implementation plan step statuses: ⬜ → ✅."""
    if "### 実装計画" not in body:
        return body

    body = re.sub(
        r"(\| S\d+(?:\.\d+)? \|.*?\| )(⬜)( \|)",
        r"\g<1>✅\g<3>",
        body
    )

    return body


def append_section(body: str, section_name: str, content: str) -> str:
    """Append content to the end of a named section (before next ### or EOF)."""
    # Find the section and its content boundary
    pattern = r"(### " + re.escape(section_name) + r"\n(?:<!-- .*?-->\n)?)(.*?)(?=\n### |\Z)"
    match = re.search(pattern, body, flags=re.DOTALL)

    if not match:
        return body

    section_header = match.group(1)
    existing_content = match.group(2)

    # Remove placeholder text if present
    placeholders = [
        "_確認事項はありません_",
        "_計画逸脱はありません_",
        "_ボトルネック検出はありません_",
        "_レビュー対応はありません_",
        "_まだ変更はありません_",
    ]
    cleaned = existing_content
    for ph in placeholders:
        cleaned = cleaned.replace(ph, "")
    cleaned = cleaned.strip()

    # Build new content
    if cleaned:
        new_content = cleaned + "\n" + content
    else:
        new_content = content

    replacement = section_header + new_content
    body = body[:match.start()] + replacement + body[match.end():]

    return body


def replace_section(body: str, section_name: str, content: str) -> str:
    """Replace the entire content of a named section (header preserved)."""
    pattern = r"(### " + re.escape(section_name) + r"\n)(?:<!-- .*?-->\n)?.*?(?=\n### |\Z)"
    body = re.sub(pattern, r"\g<1>" + content, body, count=1, flags=re.DOTALL)

    return body


def update_checkboxes(body: str, task_names: list[str]) -> str:
    """Update specified tasks from - [ ] to - [x]."""
    for task_name in task_names:
        pattern = r"^(- \[) (\] " + re.escape(task_name) + r")$"
        body = re.sub(pattern, r"\1x\2", body, flags=re.MULTILINE)

    return body


def parse_args(args: list[str]) -> tuple[str, dict]:
    """Parse command-line arguments. Returns (subcommand, options dict)."""
    if len(args) < 1:
        print("Usage: issue-comment-wm-update.py <subcommand> [options]", file=sys.stderr)
        sys.exit(1)

    subcommand = args[0]
    opts: dict = {}
    i = 1

    value_opts = {
        "--impl-status": "impl_status",
        "--test-status": "test_status",
        "--doc-status": "doc_status",
        "--changed-files-file": "changed_files_file",
        "--phase": "phase",
        "--phase-detail": "phase_detail",
        "--section": "section",
        "--content-file": "content_file",
        "--tasks": "tasks",
        "--timestamp": "timestamp",
    }

    while i < len(args):
        arg = args[i]
        if arg in value_opts:
            if i + 1 >= len(args):
                print(f"ERROR: {arg} requires a value", file=sys.stderr)
                sys.exit(1)
            opts[value_opts[arg]] = args[i + 1]
            i += 2
        else:
            print(f"ERROR: Unknown option: {arg}", file=sys.stderr)
            sys.exit(1)

    return subcommand, opts


def read_file_content(file_path: str) -> str:
    """Read content from a file path."""
    try:
        return Path(file_path).read_text(encoding="utf-8").rstrip("\n")
    except OSError as e:
        print(f"ERROR: Cannot read file {file_path}: {e}", file=sys.stderr)
        sys.exit(2)


def main():
    subcommand, opts = parse_args(sys.argv[1:])

    # Read body from stdin
    body = sys.stdin.read()
    if not body:
        print("ERROR: No input received on stdin", file=sys.stderr)
        sys.exit(1)

    timestamp = opts.get("timestamp")

    if subcommand == "update-progress":
        changed_files_md = None
        if "changed_files_file" in opts:
            changed_files_md = read_file_content(opts["changed_files_file"])
        body = update_progress(
            body,
            opts.get("impl_status", "⬜ 未着手"),
            opts.get("test_status", "⬜ 未着手"),
            opts.get("doc_status", "⬜ 未着手"),
            changed_files_md,
            timestamp,
        )

    elif subcommand == "update-phase":
        if "phase" not in opts or "phase_detail" not in opts:
            print("ERROR: --phase and --phase-detail are required for update-phase", file=sys.stderr)
            sys.exit(1)
        body = update_phase(body, opts["phase"], opts["phase_detail"], timestamp)

    elif subcommand == "update-plan-status":
        body = update_plan_status(body)

    elif subcommand == "append-section":
        if "section" not in opts or "content_file" not in opts:
            print("ERROR: --section and --content-file are required for append-section", file=sys.stderr)
            sys.exit(1)
        content = read_file_content(opts["content_file"])
        body = append_section(body, opts["section"], content)

    elif subcommand == "replace-section":
        if "section" not in opts or "content_file" not in opts:
            print("ERROR: --section and --content-file are required for replace-section", file=sys.stderr)
            sys.exit(1)
        content = read_file_content(opts["content_file"])
        body = replace_section(body, opts["section"], content)

    elif subcommand == "update-checkboxes":
        if "tasks" not in opts:
            print("ERROR: --tasks is required for update-checkboxes", file=sys.stderr)
            sys.exit(1)
        task_names = [t.strip() for t in opts["tasks"].split(",") if t.strip()]
        body = update_checkboxes(body, task_names)

    else:
        print(f"ERROR: Unknown subcommand: {subcommand}", file=sys.stderr)
        sys.exit(1)

    # Write updated body to stdout
    sys.stdout.write(body)


if __name__ == "__main__":
    main()
