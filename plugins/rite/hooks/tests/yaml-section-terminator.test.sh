#!/bin/bash
# Contract test for the line that ends a YAML section.
#
# Readers of rite-config.yml sections and of page frontmatter `sources:` stop at
# the next line that starts a new top-level key. A terminator that only accepts
# letters (`^[a-zA-Z]`, `^[A-Za-z_]`) misses keys that start with a digit or an
# underscore, and the values under such a key are read as values of the section.
#
# The test finds every terminator in the plugin (tests excluded) by its shape,
# not by the code around it:
#   - a regex literal whose whole body is a line-anchored bracket class,
#     `/^[...]/`, whatever the quoting, range or action around it
#     (sed ranges, awk `{ exit }`, `{ exit 0 }`, `{ var=0; next }`, ...)
#   - a Python lookahead `(?=^[...]|...)`
# NOT_TERMINATORS lists the literals of that shape that do not end a section.
#
# Each terminator is evaluated by the engine that runs it (sed for lines that
# call sed, Python for lookaheads, awk otherwise). `\s` inside a bracket means
# different things in Python and in POSIX tools, so no stand-in engine is used.
#
# Required of every terminator:
#   - it matches `2fa: x`, `_x: y`, `safety: x` and `wiki: x` (any top-level key)
#   - it matches neither an empty line nor an indented line `  k: v`
#   - it does not match `# c`, unless the file and terminator are in COMMENT_ENDS
# The last two do not apply to NON_YAML_ENDS, which end something other than a
# YAML section.
# sed ranges whose start key is literal are also run whole on a fixture where
# the target key sits after a comment inside the section and again under the
# following digit-led and letter-led keys, so a leak shows up as output.
#
# A literal with more after the bracket, `/^[...]<rest>/` (`/^[a-zA-Z]+:/`,
# `/^[a-zA-Z_]*:/`), is checked for one thing only: if it matches some of the
# top-level keys above, it must match all of them.
#
# EXPECTED_COUNTS pins how many bracket-only terminators each file has, so a
# terminator that is added, removed or moved to another file changes the table.
# A terminator written without a `/^[...` literal (a grep pattern, an awk string
# regex, a Python `re.match`) is not extracted and is not checked.

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

# $1: tree to scan, $2: "real" to also check the tables against the tree.
# Prints one line per violation; prints nothing when the tree is clean.
check_tree() {
  python3 - "$1" "$2" <<'PY'
import collections, os, re, subprocess, sys

root, mode = sys.argv[1], sys.argv[2]

# No `/` inside the literal, so an extracted end cannot close a sed address.
BRACKET = r"\^\[(?:\[:[a-z]+:\]|[^\]\\/]|\\[^/])*\]"
LITERAL = re.compile(r"/(" + BRACKET + r"[^/]*)/")
LOOKAHEAD = re.compile(r"\(\?=(" + BRACKET + r")\|")
SED_RANGE_START = re.compile(r"/\^([A-Za-z0-9_]+):/,/$")

# Literals of the terminator shape that do not end a section.
NOT_TERMINATORS = {
    # A YAML value-syntax check on a scalar, not a line of the file.
    ("hooks/scripts/lib/projects-status-config.sh", "^[!&*|>@`\\047\"{}\\[\\],?]"),
    # Key matchers of indentation-tracking parsers; they find keys, not the end.
    ("hooks/scripts/lib/projects-status-config.sh", "^[a-z_]+[ \\t]*:"),
    ("hooks/scripts/lib/projects-status-config.sh", "^[a-z_]+[ \\t]*:[ \\t]*"),
    ("hooks/scripts/lib/projects-status-config.sh", "^[a-zA-Z_][a-zA-Z_0-9-]*[ \\t]*:"),
    ("skills/setup/SKILL.md", "^[a-zA-Z_][a-zA-Z_0-9-]*[ \\t]*:"),
}

# Terminators allowed to end a section on a column-0 comment. They are not
# letter-only, so they still end on digit- and underscore-led keys.
COMMENT_ENDS = {
    ("hooks/scripts/wiki-apply-capture.sh", "^[^ ]"),
    ("hooks/scripts/wiki-apply-gate.sh", "^[^ ]"),
    ("hooks/scripts/wiki-growth-check.sh", "^[^ ]"),
    ("scripts/fix-work-memory-update.sh", "^[^ ]"),
    ("hooks/scripts/wiki-lint-descriptive-refs.sh", "^[^[:space:]]"),
}

# Terminators that end something other than a YAML section.
NON_YAML_ENDS = {
    # Ends a markdown table.
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
    "references/wiki-patterns.md": 7,
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

ENDS = ("2fa: x", "_x: y", "safety: x", "wiki: x")
CONTINUES = ("", "  k: v")


def run(cmd, text):
    out = subprocess.run(cmd, input=text, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("cannot run " + " ".join(cmd) + ": " + out.stderr.strip())
    return out.stdout


def matches(engine, end, line):
    if engine == "python":
        return re.match(end, line) is not None
    if engine == "sed":
        return run(["sed", "-n", "/" + end + "/p"], line + "\n") != ""
    return run(["awk", "/" + end + "/ { print }"], line + "\n") != ""


def terminators(line):
    for m in LOOKAHEAD.finditer(line):
        yield "python", m.group(1), None
    engine = "sed" if re.search(r"\bsed\b", line) else "awk"
    for m in LITERAL.finditer(line):
        start = SED_RANGE_START.search(line[:m.start() + 1])
        yield engine, m.group(1), start.group(1) if engine == "sed" and start else None


violations, counts, seen = [], collections.Counter(), set()
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
            for engine, end, name in terminators(line):
                key = (rel, end)
                if key in NOT_TERMINATORS:
                    seen.add(key)
                    continue
                where = f"{rel}:{n} [{engine}] {end}"
                if not re.fullmatch(BRACKET, end):
                    hits = [matches(engine, end, probe) for probe in ENDS]
                    if any(hits):
                        for probe, hit in zip(ENDS, hits):
                            if not hit:
                                violations.append(f"{where}: does not end the section at '{probe}'")
                    continue
                counts[rel] += 1
                for probe in ENDS:
                    if not matches(engine, end, probe):
                        violations.append(f"{where}: does not end the section at '{probe}'")
                if key in NON_YAML_ENDS:
                    seen.add(key)
                    continue
                for probe in CONTINUES:
                    if matches(engine, end, probe):
                        violations.append(f"{where}: ends the section at '{probe}'")
                if key in COMMENT_ENDS:
                    seen.add(key)
                elif matches(engine, end, "# c"):
                    violations.append(f"{where}: ends the section at a column-0 comment")
                if name:
                    fixture = f"{name}:\n  a: 1\n# c\n  k: in\n2fa:\n  k: leak\nsafety:\n  k: leak\n"
                    out = run(["sed", "-n", f"/^{name}:/,/{end}/p"], fixture)
                    if "k: in" not in out or "leak" in out:
                        violations.append(f"{where}: range reads {out.splitlines()!r}")

if mode == "real":
    for rel in sorted(set(counts) | set(EXPECTED_COUNTS)):
        if counts[rel] != EXPECTED_COUNTS.get(rel, 0):
            violations.append(f"{rel}: {counts[rel]} terminators, expected {EXPECTED_COUNTS.get(rel, 0)}")
    for table, name in ((NOT_TERMINATORS, "NOT_TERMINATORS"), (COMMENT_ENDS, "COMMENT_ENDS"), (NON_YAML_ENDS, "NON_YAML_ENDS")):
        for rel, end in sorted(table - seen):
            violations.append(f"{rel}: {name} lists {end} but no such literal exists")

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
# Each broken shape must be reported, or a clean result above proves nothing.
SANDBOX="$(make_plain_sandbox)" || { echo "ERROR: make_plain_sandbox failed" >&2; exit 1; }
[ -n "$SANDBOX" ] || { echo "ERROR: make_plain_sandbox returned an empty path" >&2; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/scripts"
cat > "$SANDBOX/scripts/old.sh" <<'EOF'
section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' "$cfg")
max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+k:/{print;exit}' "$cfg")
  /^[a-zA-Z]/ { in_fs = 0 }
  in_x && /^[A-Za-z_]/ { in_x=0 }
section=$(sed -n "/^wiki:/,/^[a-zA-Z]/p" "$cfg")
  in_x && /^[a-zA-Z]/ { in_x=0; next }
max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit 0}' "$cfg")
section=$(sed -n '/^wiki:/,/^[0-9_]/p' "$cfg")
section=$(sed -n '/^wiki:/,/^[^\s#]/p' "$cfg")
section=$(sed -n '/^wiki:/,/^[^ ]/p' "$cfg")
max=$(awk '/^safety:/{s=1;next} s && /^[a-zA-Z]+:/ {exit} s && /k:/{print;exit}' "$cfg")
section=$(sed -n '/^wiki:/,/^[a-zA-Z_]*:/p' "$cfg")
EOF
cat > "$SANDBOX/scripts/old.py" <<'EOF'
section = re.search(r"^safety:\s*\n(.*?)(?=^[a-zA-Z]|\Z)", text, re.M | re.S)
EOF
self_out=$(check_tree "$SANDBOX" self)
self_rc=$?
assert "detector runs on the sandbox" "0" "$self_rc"
count_of() { printf '%s\n' "$self_out" | grep -c -- "$1"; }
assert "sed range with a letter-only end is reported" "1" "$(count_of "old.sh:1 \[sed\].*at '2fa: x'")"
assert "awk guard with a letter-only end is reported" "1" "$(count_of "old.sh:2 \[awk\].*at '2fa: x'")"
assert "standalone awk pattern with a letter-only end is reported" "1" "$(count_of "old.sh:3 \[awk\].*at '2fa: x'")"
assert "letter-or-underscore end is reported for the digit-led key" "1" "$(count_of "old.sh:4 \[awk\].*at '2fa: x'")"
assert "letter-or-underscore end is accepted for the underscore-led key" "0" "$(count_of "old.sh:4 \[awk\].*at '_x: y'")"
assert "double-quoted sed range is reported" "1" "$(count_of "old.sh:5 \[sed\].*at '2fa: x'")"
assert "awk guard with '; next' is reported" "1" "$(count_of "old.sh:6 \[awk\].*at '2fa: x'")"
assert "awk guard with 'exit 0' is reported" "1" "$(count_of "old.sh:7 \[awk\].*at '2fa: x'")"
assert "digit-or-underscore end is reported for a letter-led key" "1" "$(count_of "old.sh:8 \[sed\].*at 'safety: x'")"
assert "POSIX end written with Python \\s is reported for an indented line" "1" "$(count_of "old.sh:9 \[sed\].*at '  k: v'")"
assert "space-only end is reported for a column-0 comment" "1" "$(count_of "old.sh:10 \[sed\].*column-0 comment")"
assert "letter-only end with more after the bracket is reported" "1" "$(count_of "old.sh:11 \[awk\].*at '2fa: x'")"
assert "sed range end with more after the bracket is reported" "1" "$(count_of "old.sh:12 \[sed\].*at '2fa: x'")"
assert "python lookahead with a letter-only end is reported" "1" "$(count_of "old.py:1 \[python\].*at '2fa: x'")"
assert "sed range leak is observed on the fixture" "1" "$(count_of "old.sh:1 \[sed\].*range reads")"

# The table checks run only against the plugin tree, so a sandbox checked as
# "real" must report the missing files and the stale table entries.
table_out=$(check_tree "$SANDBOX" real)
assert "count table mismatch is reported" "1" \
  "$(printf '%s\n' "$table_out" | grep -c -- "^references/wiki-patterns.md: 0 terminators, expected 7$")"
assert "stale COMMENT_ENDS entry is reported" "1" \
  "$(printf '%s\n' "$table_out" | grep -c -- "^scripts/fix-work-memory-update.sh: COMMENT_ENDS lists")"

print_summary "$(basename "$0")" \
  "Section terminators must end on any top-level key and on neither an empty nor an indented line. The rule for rite-config.yml sections is written in plugins/rite/references/wiki-patterns.md."
