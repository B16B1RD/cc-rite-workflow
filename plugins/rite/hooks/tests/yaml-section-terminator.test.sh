#!/bin/bash
# Contract test for the line that ends a YAML section.
#
# Readers of rite-config.yml sections and of page frontmatter `sources:` stop at
# the next line that starts a new top-level key. A terminator that only accepts
# letters (`^[a-zA-Z]`, `^[A-Za-z_]`) misses keys that start with a digit or an
# underscore, and the values under such a key are read as values of the section.
#
# The test finds every terminator in the plugin (tests excluded) in the four
# shapes that readers use:
#   sed    sed -n '/^NAME:/,/END/p'
#   awk    guard && /END/ { exit }   or   guard && /END/ { var=0 }
#   awk    /END/ { var = 0 }         (standalone pattern)
#   python (?=END|...)               (lookahead in re.search)
# Each END is evaluated by the engine it is written for, never by a stand-in:
# `\s` inside a bracket means different things in Python and in POSIX tools.
#
# Required of every END:
#   - it matches `2fa: x` and `_x: y` (a digit- or underscore-led key ends the section)
#   - it does not match an empty line
#   - it does not match `# c`, unless the file and END are in COMMENT_ENDS below
# sed ranges are also run whole on a fixture where the target key sits only
# under the digit-led key, so a leak shows up as output.
#
# The per-file counts in EXPECTED_COUNTS pin where terminators are, so a reader
# written in a shape the extraction misses shows up as a count change instead
# of silently going unchecked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

echo "=== YAML section terminator contract ==="

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required"
  print_summary "$(basename "$0")"
  exit 1
fi

# $1: tree to scan, $2: "real" to also check the count table.
# Prints one line per violation; prints nothing when the tree is clean.
check_tree() {
  python3 - "$1" "$2" <<'PY'
import collections, os, re, subprocess, sys

root, mode = sys.argv[1], sys.argv[2]

FORMS = [
    ("sed", re.compile(r"sed -n '/\^([A-Za-z0-9_]+):/,/(\^\[[^/]*)/p'")),
    ("awk", re.compile(r"&&\s*/(\^\[[^/]*)/\s*\{\s*(?:exit|[a-z_]+\s*=\s*0)\s*\}")),
    ("awk", re.compile(r"^\s*/(\^\[[^/]*)/\s*\{\s*[a-z_]+\s*=\s*0\s*\}")),
    ("python", re.compile(r"\(\?=(\^\[[^|)]*\])\|")),
]

# Terminators allowed to end a section on a column-0 comment. They are not
# letter-only, so they still end on digit- and underscore-led keys.
COMMENT_ENDS = {
    ("hooks/scripts/wiki-apply-capture.sh", "^[^ ]"),
    ("hooks/scripts/wiki-apply-gate.sh", "^[^ ]"),
    ("hooks/scripts/wiki-growth-check.sh", "^[^ ]"),
    ("scripts/fix-work-memory-update.sh", "^[^ ]"),
    ("hooks/scripts/wiki-lint-descriptive-refs.sh", "^[^[:space:]]"),
    # Ends a markdown table, not a YAML section.
    ("hooks/scripts/fix-reason-coverage-check.sh", "^[^|]"),
}

EXPECTED_COUNTS = {
    "hooks/scripts/cleanup-session-worktree-teardown.sh": 1,
    "hooks/scripts/fix-reason-coverage-check.sh": 1,
    "hooks/scripts/gitignore-health-check.sh": 2,
    "hooks/scripts/lib/review-stagnation.py": 1,
    "hooks/scripts/lib/wiki-config.sh": 1,
    "hooks/scripts/lib/worktree-git.sh": 1,
    "hooks/scripts/pr-cycle-cleanup.sh": 1,
    "hooks/scripts/pr-review-post-comment-read.sh": 1,
    "hooks/scripts/wiki-apply-capture.sh": 1,
    "hooks/scripts/wiki-apply-gate.sh": 2,
    "hooks/scripts/wiki-growth-check.sh": 2,
    "hooks/scripts/wiki-lint-descriptive-refs.sh": 1,
    "hooks/scripts/wiki-lint-source-refs.sh": 1,
    "hooks/scripts/wiki-okf-migrate.sh": 1,
    "hooks/session-start.sh": 1,
    "hooks/wiki-ingest-trigger.sh": 1,
    "hooks/wiki-query-inject.sh": 1,
    "references/wiki-patterns.md": 6,
    "scripts/fix-work-memory-update.sh": 1,
    "scripts/iterate-step.sh": 2,
    "scripts/review-pr-recommendations.sh": 1,
    "skills/fix/SKILL.md": 2,
    "skills/issue-implement/SKILL.md": 3,
    "skills/open/SKILL.md": 2,
    "skills/pr-review/SKILL.md": 2,
    "skills/recover/SKILL.md": 1,
    "skills/setup/SKILL.md": 4,
    "skills/setup/references/rationale.md": 1,
    "skills/unknowns/SKILL.md": 1,
    "skills/wiki-ingest/SKILL.md": 1,
    "skills/wiki-init/SKILL.md": 4,
    "skills/wiki-query/SKILL.md": 1,
}


def matches(engine, end, line):
    if engine == "python":
        return re.match(end, line) is not None
    if engine == "sed":
        cmd = ["sed", "-n", "/" + end + "/p"]
    else:
        cmd = ["awk", "/" + end + "/ { print }"]
    out = subprocess.run(cmd, input=line + "\n", capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("cannot evaluate " + end + " with " + engine + ": " + out.stderr.strip())
    return out.stdout != ""


violations, counts, seen_comment_ends = [], collections.Counter(), set()
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x != "tests"]
    for f in sorted(files):
        if not f.endswith((".sh", ".py", ".md")):
            continue
        path = os.path.join(d, f)
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        for n, line in enumerate(lines, 1):
            for engine, rx in FORMS:
                for m in rx.finditer(line):
                    end = m.group(m.lastindex)
                    where = f"{rel}:{n} [{engine}] {end}"
                    counts[rel] += 1
                    for key in ("2fa: x", "_x: y"):
                        if not matches(engine, end, key):
                            violations.append(f"{where}: does not end the section at '{key}'")
                    if matches(engine, end, ""):
                        violations.append(f"{where}: ends the section at an empty line")
                    if (rel, end) in COMMENT_ENDS:
                        seen_comment_ends.add((rel, end))
                    elif matches(engine, end, "# c"):
                        violations.append(f"{where}: ends the section at a column-0 comment")
                    if engine == "sed":
                        name = m.group(1)
                        fixture = f"{name}:\n# c\n  k: in\n2fa:\n  k: leak\n"
                        out = subprocess.run(["sed", "-n", f"/^{name}:/,/{end}/p"],
                                             input=fixture, capture_output=True, text=True).stdout
                        if "k: in" not in out or "leak" in out:
                            violations.append(f"{where}: range reads {out.splitlines()!r}")

if mode == "real":
    for rel in sorted(set(counts) | set(EXPECTED_COUNTS)):
        if counts[rel] != EXPECTED_COUNTS.get(rel, 0):
            violations.append(f"{rel}: {counts[rel]} terminators, expected {EXPECTED_COUNTS.get(rel, 0)}")
    for rel, end in sorted(COMMENT_ENDS - seen_comment_ends):
        violations.append(f"{rel}: COMMENT_ENDS lists {end} but no such terminator exists")

print("\n".join(violations))
PY
}

# --- The plugin tree ------------------------------------------------------------
real_out=$(check_tree "$PLUGIN_ROOT" real)
real_rc=$?
assert "detector runs on the plugin tree" "0" "$real_rc"
assert "no terminator ends a section only on letters" "" "$real_out"
[ -n "$real_out" ] && printf '%s\n' "$real_out" | sed 's/^/    /'

# --- The detector itself --------------------------------------------------------
# Each old shape must be reported, or a clean result above proves nothing.
SANDBOX="$(make_plain_sandbox)" || { echo "ERROR: make_plain_sandbox failed" >&2; exit 1; }
[ -n "$SANDBOX" ] || { echo "ERROR: make_plain_sandbox returned an empty path" >&2; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/scripts"
cat > "$SANDBOX/scripts/old.sh" <<'EOF'
section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' "$cfg")
max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+k:/{print;exit}' "$cfg")
  /^[a-zA-Z]/ { in_fs = 0 }
  in_x && /^[A-Za-z_]/ { in_x=0 }
EOF
cat > "$SANDBOX/scripts/old.py" <<'EOF'
section = re.search(r"^safety:\s*\n(.*?)(?=^[a-zA-Z]|\Z)", text, re.M | re.S)
EOF
self_out=$(check_tree "$SANDBOX" self)
assert "sed range with a letter-only end is reported" "1" \
  "$(printf '%s\n' "$self_out" | grep -c "old.sh:1 \[sed\].*at '2fa: x'")"
assert "awk guard with a letter-only end is reported" "1" \
  "$(printf '%s\n' "$self_out" | grep -c "old.sh:2 \[awk\].*at '2fa: x'")"
assert "standalone awk pattern with a letter-only end is reported" "1" \
  "$(printf '%s\n' "$self_out" | grep -c "old.sh:3 \[awk\].*at '2fa: x'")"
assert "letter-or-underscore end is reported for the digit-led key" "1" \
  "$(printf '%s\n' "$self_out" | grep -c "old.sh:4 \[awk\].*at '2fa: x'")"
assert "letter-or-underscore end is accepted for the underscore-led key" "0" \
  "$(printf '%s\n' "$self_out" | grep -c "old.sh:4 \[awk\].*at '_x: y'")"
assert "python lookahead with a letter-only end is reported" "1" \
  "$(printf '%s\n' "$self_out" | grep -c "old.py:1 \[python\].*at '2fa: x'")"
assert "sed range leak is observed on the fixture" "1" \
  "$(printf '%s\n' "$self_out" | grep -c "old.sh:1 \[sed\].*range reads")"

print_summary "$(basename "$0")" \
  "Section terminators must end on any line that starts with neither whitespace nor '#'. The rule is written in plugins/rite/references/wiki-patterns.md."
