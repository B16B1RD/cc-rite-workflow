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


def stopping_tail(parts, status):
    return parts[-3:] == ["||", "exit", status]


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
        pinned = False
        straight_line = True
        for source_line, command in commands(block):
            try:
                parts = tokens(command)
            except ValueError:
                if HELPER in command:
                    calls += 1
                    findings.append((source_line, "unparseable helper invocation"))
                pinned = False
                continue
            if not parts:
                continue
            if parts[0] in {"if", "elif", "else", "fi", "for", "while", "until", "case", "esac", "do", "done", "function", "{"} or any(p in {"(", ")"} for p in parts):
                straight_line = False
            # Only a straight-line command establishes the cwd; a cd in an if,
            # subshell or another command's string cannot establish this boundary.
            if straight_line and parts == ["cd", "{execution_cwd}", "||", "exit", "1"]:
                pinned = True
                continue
            helper_call = len(parts) > 1 and parts[0] == "bash" and parts[1].endswith("/" + HELPER)
            if helper_call:
                calls += 1
                reasons = []
                if not pinned:
                    reasons.append("missing same-block cd {execution_cwd} || exit 1")
                repo_count = parts.count("--repo")
                if repo_count != 1 or parts[parts.index("--repo") + 1:parts.index("--repo") + 2] != ["{owner_repo}"]:
                    reasons.append("missing explicit --repo {owner_repo}")
                if not stopping_tail(parts, "$?") or any(p in {"||", "&&", ";", "|", "(", ")"} for p in parts[:-3]):
                    reasons.append("helper failure must propagate with || exit $?")
                if reasons:
                    findings.append((source_line, "; ".join(reasons)))
            elif any(part.endswith("/" + HELPER) for part in parts):
                calls += 1
                findings.append((source_line, "helper invocation must be a direct bash command with || exit $?"))
            # Any intervening executable line could change scope or cwd. The
            # boundary must stay adjacent, rather than accepting a distant cd.
            pinned = False
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
