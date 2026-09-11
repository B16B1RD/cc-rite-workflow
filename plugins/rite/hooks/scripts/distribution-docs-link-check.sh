#!/usr/bin/env bash
# distribution-docs-link-check.sh
#
# Detect markdown links in the distributed plugin that resolve outside
# plugins/rite/. Marketplace installs do not ship the development repo's
# docs/ (or any sibling of the plugin root), so those links 404 at the
# destination. This check is the recurrence guard.
#
# Inline [text](url) / ![alt](url) only. http(s)/mailto/fragment-only and
# `{placeholder}` template hrefs are skipped. Fenced code is skipped so
# examples do not become findings.
#
# Usage:
#   distribution-docs-link-check.sh [--all] [--target FILE]... [--repo-root DIR]
#                                   [--quiet] [--skip-if-no-target]
#
# Exit codes: 0 = clean (or not-applicable skip), 1 = pattern detected,
#             2 = invocation error or one or more files could not be scanned.
# Findings on stdout; summary on stderr (log(), --quiet respected for
# progress; the Total line is always emitted so /rite:lint can count).

set -uo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: python3 is required for distribution-docs-link-check.sh' >&2
  exit 2
fi

python3 - "$@" <<'PY'
import os
import re
import sys

LINK_RE = re.compile(r"\]\(([^)]+)\)")
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def usage():
    print(
        "Usage: distribution-docs-link-check.sh [--all] [--target FILE]... "
        "[--repo-root DIR] [--quiet] [--skip-if-no-target]",
        file=sys.stderr,
    )


def parse_args(argv):
    root = ""
    use_all = False
    quiet = False
    skip_if_no_target = False
    targets = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--all":
            use_all = True
            i += 1
        elif a == "--quiet":
            quiet = True
            i += 1
        elif a == "--skip-if-no-target":
            skip_if_no_target = True
            i += 1
        elif a == "--repo-root":
            if i + 1 >= len(argv):
                print("ERROR: --repo-root requires a directory argument", file=sys.stderr)
                sys.exit(2)
            root = argv[i + 1]
            i += 2
        elif a == "--target":
            if i + 1 >= len(argv):
                print("ERROR: --target requires a value", file=sys.stderr)
                sys.exit(2)
            targets.append(argv[i + 1])
            i += 2
        elif a in ("-h", "--help"):
            usage()
            sys.exit(0)
        else:
            print(f"ERROR: unknown or incomplete argument: {a}", file=sys.stderr)
            usage()
            sys.exit(2)
    return root, use_all, quiet, skip_if_no_target, targets


def log(quiet, msg):
    if not quiet:
        print(msg, file=sys.stderr)


def under_plugin(resolved, plugin_root):
    plugin = os.path.abspath(plugin_root)
    path = os.path.abspath(resolved)
    return path == plugin or path.startswith(plugin + os.sep)


def strip_destination(raw):
    dest = raw.strip()
    if dest.startswith("<"):
        end = dest.find(">")
        if end == -1:
            return ""
        dest = dest[1:end].strip()
    else:
        dest = dest.split()[0] if dest else ""
    dest = dest.split("#", 1)[0]
    return dest


def is_fence_line(line):
    indent = 0
    probe = line
    while probe.startswith(" "):
        indent += 1
        probe = probe[1:]
        if indent > 3:
            return False, "", 0
    if not (probe.startswith("```") or probe.startswith("~~~")):
        return False, "", 0
    ch = probe[0]
    n = 0
    while n < len(probe) and probe[n] == ch:
        n += 1
    return True, ch, n


def scan_file(path, repo_root, plugin_root):
    findings = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        print(f"WARNING: target not readable: {path} ({exc}) — not scanned", file=sys.stderr)
        return None

    in_fence = False
    fence_char = ""
    fence_len = 0
    rel = os.path.relpath(path, repo_root)
    for idx, line in enumerate(lines, 1):
        is_fence, ch, n = is_fence_line(line.rstrip("\n"))
        if is_fence:
            if not in_fence:
                in_fence = True
                fence_char = ch
                fence_len = n
            elif ch == fence_char and n >= fence_len:
                rest = line.lstrip(" ")[n:].strip()
                if rest == "":
                    in_fence = False
                    fence_char = ""
                    fence_len = 0
            continue
        if in_fence:
            continue
        if "drift-check-ignore" in line:
            continue
        file_dir = os.path.dirname(path)
        for match in LINK_RE.finditer(line):
            dest = strip_destination(match.group(1))
            if not dest:
                continue
            if SCHEME_RE.match(dest):
                continue
            if "{" in dest or "}" in dest:
                continue
            if dest.startswith("/"):
                resolved = os.path.normpath(os.path.join(repo_root, dest.lstrip("/")))
            else:
                resolved = os.path.normpath(os.path.join(file_dir, dest))
            if under_plugin(resolved, plugin_root):
                continue
            escaped = os.path.relpath(resolved, repo_root)
            findings.append(
                f"[distribution-docs-link] {rel}:{idx}: relative link escapes plugin root: "
                f"`{dest}` -> {escaped}"
            )
    if in_fence:
        print(
            f"WARNING: unbalanced code fence in {rel} — file skipped "
            "(detection is dropped rather than guessed)",
            file=sys.stderr,
        )
        return None
    return findings


def collect_all(repo_root):
    scan_dir = os.path.join(repo_root, "plugins/rite")
    out = []
    for dirpath, dirnames, filenames in os.walk(scan_dir):
        dirnames[:] = [d for d in dirnames if d != "tests"]
        rel_dir = os.path.relpath(dirpath, repo_root)
        if os.sep + "tests" + os.sep in (os.sep + rel_dir + os.sep):
            continue
        for name in filenames:
            if name.endswith(".md"):
                out.append(os.path.join(dirpath, name))
    out.sort()
    return out


def main():
    root, use_all, quiet, skip_if_no_target, targets = parse_args(sys.argv[1:])
    if not root:
        import subprocess

        try:
            root = subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            root = os.getcwd()
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        print(f"ERROR: repository root is not a directory: {root}", file=sys.stderr)
        sys.exit(2)

    plugin_root = os.path.join(root, "plugins/rite")
    files = []
    if use_all:
        if not os.path.isdir(plugin_root):
            if skip_if_no_target:
                print(
                    "[distribution-docs-link] not applicable: no plugins/rite under "
                    f"{root} — clean skip (--skip-if-no-target)",
                    file=sys.stderr,
                )
                print("Total distribution-docs-link findings: 0", file=sys.stderr)
                sys.exit(0)
            print(
                f"ERROR: --all requested but plugins/rite does not exist under {root}",
                file=sys.stderr,
            )
            sys.exit(2)
        files.extend(collect_all(root))
    for t in targets:
        path = t if os.path.isabs(t) else os.path.join(root, t)
        if not os.path.isfile(path):
            print(f"ERROR: target not found: {t}", file=sys.stderr)
            sys.exit(2)
        files.append(os.path.abspath(path))

    if not files:
        print("ERROR: no targets specified (use --all or --target FILE)", file=sys.stderr)
        usage()
        sys.exit(2)

    log(quiet, f"Scanning {len(files)} file(s)...")
    findings = []
    skipped = 0
    seen = set()
    for path in files:
        if path in seen:
            continue
        seen.add(path)
        result = scan_file(path, root, plugin_root)
        if result is None:
            skipped += 1
            continue
        findings.extend(result)

    for line in findings:
        print(line)
    print(f"Total distribution-docs-link findings: {len(findings)}", file=sys.stderr)

    if skipped:
        print(
            f"ERROR: {skipped} file(s) could not be scanned — this run is not a clean bill",
            file=sys.stderr,
        )
        print("  See the WARNING lines above for which files and why.", file=sys.stderr)

    if findings:
        sys.exit(1)
    if skipped:
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
PY
