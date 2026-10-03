#!/usr/bin/env python3
"""Check explicit repository, cwd and failure propagation in operational blocks."""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import sys


KNOWN_SKILLS = {"open", "issue-implement", "pr-review"}
HELPER = "issue-complexity-lane.sh"


def commands(text):
    """Yield logical shell lines, preserving their source line for diagnostics."""
    pending = ""
    start = 0
    heredocs = []
    for number, line in text:
        if heredocs:
            delimiter, tabs = heredocs[0]
            if (line.lstrip("\t") if tabs else line) == delimiter:
                heredocs.pop(0)
            continue
        if not pending:
            start = number
        pending += line
        if pending.endswith("\\"):
            pending = pending[:-1] + " "
            continue
        yield start, pending
        # Shell examples in a heredoc are data, including apparent cd/helper
        # lines. Match delimiters only after removing comments with shlex.
        lexer = shlex.shlex(pending, posix=True, punctuation_chars=";<>&|()")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        try:
            parts = list(lexer)
        except ValueError:
            parts = []
        for index, part in enumerate(parts[:-1]):
            if part == "<<":
                delimiter = parts[index + 1]
                tabs = delimiter.startswith("-")
                heredocs.append((delimiter[1:] if tabs else delimiter, tabs))
        pending = ""
    if pending:
        yield start, pending


def tokens(line):
    lexer = shlex.shlex(line, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = "#"
    return list(lexer)


def check_file(path, label):
    findings = []
    calls = 0
    block = None
    fence = None
    for number, line in enumerate(path.read_text().splitlines(), 1):
        opening = re.fullmatch(r"\s*(`{3,}|~{3,})\s*(bash|sh|shell)\s*", line)
        if block is None:
            if opening:
                block = []
                fence = opening[1]
            continue
        if line.strip() != fence:
            block.append((number, line))
            continue
        logical_commands = []
        for source_line, command in commands(block):
            try:
                parts = tokens(command)
            except ValueError:
                parts = None
            if parts or parts is None:
                logical_commands.append((source_line, command, parts))
        for source_line, command, parts in logical_commands:
            if parts is None:
                if HELPER in command:
                    calls += 1
                    findings.append((source_line, "unparseable helper invocation"))
                continue
            helper_call = len(parts) > 1 and parts[0] == "bash" and parts[1].endswith("/" + HELPER)
            if helper_call:
                calls += 1
                reasons = []
                for flag, value in (("--repo", "{owner_repo}"), ("--cwd", "{execution_cwd}")):
                    if parts.count(flag) != 1 or parts[parts.index(flag) + 1:parts.index(flag) + 2] != [value]:
                        reasons.append("missing explicit " + flag + " " + value)
                if len(logical_commands) != 1 or any(p in {"||", "&&", ";", "|", "&", "(", ")"} for p in parts):
                    reasons.append("helper must be the single top-level command; its exit status must propagate")
                if reasons:
                    findings.append((source_line, "; ".join(reasons)))
            elif any(part.endswith("/" + HELPER) for part in parts):
                calls += 1
                findings.append((source_line, "helper invocation must be a single direct bash command"))
        block = None
    if block is not None:
        findings.append((block[0][0] if block else 1, "unclosed operational shell fence"))
    return calls, [f"[repository-context] {label}:{line}: {reason}" for line, reason in findings]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--repo-root")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    try:
        root = Path(args.repo_root or subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
        targets = [root / name for name in args.target]
        if args.all:
            base = root / "plugins/rite/skills"
            if not base.is_dir():
                raise ValueError(f"skill directory missing: {base}")
            targets += sorted(p for p in base.rglob("*.md") if "tests" not in p.relative_to(base).parts)
        if not targets:
            raise ValueError("no targets (use --all or --target FILE)")
        calls = 0
        findings = []
        seen = set()
        for path in dict.fromkeys(targets):
            label = str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
            count, problems = check_file(path, label)
            calls += count
            findings += problems
            if count and path.name == "SKILL.md":
                seen.add(path.parent.name)
        if not calls:
            raise ValueError("no Complexity helper invocations found")
        if args.all and not KNOWN_SKILLS <= seen:
            raise ValueError("missing expected helper invocations: " + ", ".join(sorted(KNOWN_SKILLS - seen)))
        for finding in findings:
            print(finding)
        if not args.quiet:
            print(f"Total repository-context findings: {len(findings)}; invocations: {calls}", file=sys.stderr)
        return bool(findings)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: repository-context: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
