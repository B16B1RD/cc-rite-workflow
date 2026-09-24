#!/usr/bin/env python3
"""Bind a fix plan to a collected review and retain measured verification results."""
import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys

cycle = importlib.import_module("review-cycle")
require, read, atomic_write = cycle.require, cycle.read, cycle.atomic_write


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


# git commit の内容指定。照合した index ではなく作業ツリーを記録する。
_CONTENT_FLAGS = set("aiop")
_REQUIRED_VALUE = set("mFCct")
_OPTIONAL_VALUE = set("uS")
_CONTENT_LONG = {
    "--all", "--include", "--interactive", "--only", "--patch",
    "--pathspec-file-nul", "--pathspec-from-file",
}
_VALUE_LONG = {
    "-C", "-F", "-c", "-m", "-t", "--author", "--cleanup", "--date", "--file",
    "--fixup", "--message", "--reedit-message", "--reuse-message", "--squash",
    "--template", "--trailer",
}


def _scan_short_cluster(body):
    """Read one short cluster from the left, the way git does.

    a/i/o/p are content flags. m/F/C/c/t take a required value: the rest of
    this token, or the next token when nothing remains. u/S take the rest of
    this token as an optional value. Letters inside a value are not flags.
    """
    index_only = True
    i = 0
    while i < len(body):
        ch = body[i]
        if ch in _CONTENT_FLAGS:
            index_only = False
            i += 1
            continue
        if ch in _REQUIRED_VALUE:
            return index_only, body[i + 1:] == ""
        if ch in _OPTIONAL_VALUE:
            return index_only, False
        i += 1
    return index_only, False


def classify_commit_args(args):
    """Return whether these tokens after `commit` are a dry run, and whether
    they record the index. A value glued on with '=' is not a following pathspec.
    `--amend` stays an index commit."""
    dry_run, skip, index_only, dashed = False, False, True, False
    for option in args:
        if dashed:
            index_only = False
            break
        if skip:
            skip = False
            continue
        if option == "--":
            dashed = True
            continue
        if option in ("--dry-run", "--help", "-h"):
            dry_run = True
            continue
        name, eq, _value = option.partition("=")
        if name in _CONTENT_LONG:
            index_only = False
            if eq == "" and name == "--pathspec-from-file":
                skip = True
            continue
        if option.startswith("-") and not option.startswith("--") and eq == "" and len(option) > 1 and option[1].isalpha():
            cluster_index, skip_next = _scan_short_cluster(option[1:])
            if not cluster_index:
                index_only = False
            if skip_next:
                skip = True
            continue
        if name in _VALUE_LONG:
            if eq == "":
                skip = True
            continue
        if option.startswith("-"):
            continue
        index_only = False
    return dry_run, index_only


def text(value):
    return isinstance(value, str) and bool(value.strip())


def path(value):
    require(text(value) and not Path(value).is_absolute() and ".." not in Path(value).parts,
            "paths must be relative without parent traversal")
    result = Path(value)
    require(result.as_posix() not in (".", "") and ".git" not in result.parts,
            "paths must name repository content")
    require(result.resolve().is_relative_to(Path.cwd().resolve()), "path escapes worktree: " + value)
    return result.as_posix().rstrip("/")


def within(value, parent):
    # Resolve aliases as well as spelling so symlinks cannot hide a non-target.
    return Path(value).resolve() == Path(parent).resolve() or Path(parent).resolve() in Path(value).resolve().parents


def validate_context(plan, state, session, directory):
    """Bind a plan to the frozen cycle, its HEAD and its saved receipt.

    Split out from validate() because deciding *whether* a state may move
    (plan_gate) and checking *what* a plan says are separate questions: the
    retry path answers the first one itself and still needs both of these.
    """
    require(state.get("session_id") == session, "foreign session state")
    current = state.get("review_cycle")
    require(isinstance(current, dict) and current.get("status") == "completed", "all reviews must be collected and saved")
    context = current["review_context"]
    require(context["session_id"] == session and context["pr_number"] == state.get("pr_number")
            and context["cycle_count"] == state.get("cycle_count"), "review context differs from current state")
    require(plan.get("review_context") == context and cycle.head() == context["commit_sha"], "stale or foreign review context / HEAD")
    receipt = cycle.matching_receipt(directory, current)
    require(receipt is not None, "saved review receipt missing")
    return receipt


def validate(plan, issue, state, session, root, allow_replan=False):
    receipt = validate_context(plan, state, session, root / ".rite/review-results")
    importlib.import_module("review-stagnation").plan_gate(state, plan, session, allow_replan)
    return validate_plan(plan, issue, state, receipt)


# The one supported way to take the base branch into a reviewed PR branch.
BASE_INTAKE_STEPS = ("git fetch origin <base>, take it in with git merge --no-commit --no-ff origin/<base>, "
                     "resolve and stage it, add a base-intake group to the fix plan, run check and "
                     "verify --kind all, commit, push, then re-run /rite:iterate "
                     "(skills/fix/references/fix-plan.md, section: base 取り込み)")
# The same route, entered with a merge already in progress.
BASE_INTAKE_CONCLUDE = ("if it takes in origin/<base>, resolve and stage it, add a base-intake group to the fix plan, "
                        "run check and verify --kind all, commit, push, then re-run /rite:iterate; otherwise "
                        "git merge --abort and start over (skills/fix/references/fix-plan.md, section: base 取り込み)")


def merge_head():
    """The commit an in-progress merge brings in, or None when no merge is in progress."""
    merge = subprocess.run(["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"], capture_output=True, text=True)
    return merge.stdout.strip() if merge.returncode == 0 and merge.stdout.strip() else None


def base_branch():
    """branch.base from rite-config.yml. It decides what base intake may exempt, so it has no default."""
    located = subprocess.run(["bash", str(Path(__file__).with_name("rite-config-path.sh"))],
                             capture_output=True, text=True)
    require(located.returncode != 1, "rite-config.yml not found: " + located.stderr.strip()
            + "; base intake cannot identify the base branch")
    require(located.returncode == 0, "cannot read rite-config.yml: " + located.stderr.strip())
    config = Path(located.stdout.strip())
    try:
        lines = config.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as error:
        require(False, "cannot read rite-config.yml: " + str(config) + ": " + str(error))
    in_branch = False
    for line in lines:
        if re.match(r"[A-Za-z_]", line):
            in_branch = line.split("#", 1)[0].strip() == "branch:"
            continue
        match = re.match(r"\s+base:\s*(.*)", line)
        if in_branch and match:
            value = re.sub(r"\s#.*", "", match.group(1)).strip().strip("\"'")
            if value and value != "null":
                return value
            break
    require(False, "branch.base is not set in " + str(config) + "; base intake cannot identify the base branch")


def base_intake_paths():
    """Paths the in-progress merge brings in from origin/<branch.base>."""
    other = merge_head()
    require(other, "base intake requires a merge in progress; start it with git merge --no-commit --no-ff origin/<base>")
    base = base_branch()
    remote = "refs/remotes/origin/" + base
    require(subprocess.run(["git", "rev-parse", "-q", "--verify", remote], capture_output=True).returncode == 0,
            "base intake needs origin/" + base + "; run git fetch origin " + base)
    # Only what the base itself carries is exempt: another branch or a side commit is Issue work.
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", other, remote], capture_output=True, text=True)
    require(ancestor.returncode in (0, 1), "git merge-base --is-ancestor failed: " + ancestor.stderr.strip())
    require(ancestor.returncode == 0,
            "the merge in progress is not origin/" + base + " or its ancestor; base intake takes in the base branch only")
    fork = subprocess.check_output(["git", "merge-base", "HEAD", other], text=True).strip()
    names = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", fork, other]).decode()
    return {path(name) for name in names.split("\0") if name}


def validate_plan(plan, issue, state, receipt):
    """Everything a fix plan must say, independent of the transition it enables."""
    require(issue.get("number") == state.get("issue_number") == plan.get("issue_number")
            and text(issue.get("body")) and text(plan.get("issue_body"))
            and cycle.same_specification(plan["issue_body"], issue["body"]), "Issue specification changed or mismatched")
    constraints = plan["constraints"]
    targets = [path(p) for p in constraints["targets"]]
    excluded = [path(p) for p in constraints["non_targets"]]
    require(type(constraints.get("closed_targets")) is bool and text(constraints.get("rationale")), "target interpretation needs rationale")
    # Standard Implementation Contract paths are independently checked; other
    # prose restrictions remain an explicit semantic judgment by the caller.
    section = re.search(r"^### 4\.2 .*?\n(.*?)(?=^#{1,3} |\Z)", issue["body"], re.M | re.S)
    if section:
        explicit = re.findall(r"`([^`\n]+)`", section[1])
        require(all(any(within(path(p), n) for n in excluded) for p in explicit), "explicit Non-Target omitted from constraints")
    tests = plan["verifications"]
    require(isinstance(tests, list) and tests, "verification plan required")
    ids = [t["id"] for t in tests]
    require(all(text(i) for i in ids) and len(set(ids)) == len(ids), "verification IDs must be unique")
    require(any(t["kind"] == "full" for t in tests), "full verification required")
    for test in tests:
        require(test["kind"] in ("related", "full") and text(test["command"]), "invalid verification kind / command")
        require(isinstance(test["inputs"], list) and test["inputs"], "verification content inputs required")
        for entry in test["inputs"]:
            path(entry)
        require(isinstance(test["environment"], list) and all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", e) for e in test["environment"]), "invalid environment keys")
    findings = receipt[1]["findings"]
    blocking = {f["id"] for f in findings if f.get("scope") in ("current-pr", "follow-up")}
    known = {f["id"] for f in findings + receipt[1].get("non_blocking_findings", [])}
    external = plan.get("external_findings", [])
    require(isinstance(external, list), "external findings must be an array")
    for finding in external:
        require(text(finding["id"]) and finding["id"] not in known and text(finding["thread_id"])
                and text(finding["description"]), "invalid external finding provenance")
        known.add(finding["id"])
        blocking.add(finding["id"])
    covered, paths, causes, constrained = [], [], [], []
    require(isinstance(plan["groups"], list) and plan["groups"], "root-cause groups required")
    require(sum(g["action"] == "base-intake" for g in plan["groups"]) <= 1, "combine base intake into one group")
    for group in plan["groups"]:
        require(text(group["root_cause"]) and text(group["rationale"]), "root cause and disposition rationale required")
        causes.append(group["root_cause"])
        require(group["action"] in ("fix", "reply", "accept", "nit-noted", "base-intake"), "invalid disposition")
        require(isinstance(group["finding_ids"], list)
                and (group["finding_ids"] or group["action"] == "base-intake"), "group finding IDs required")
        covered.extend(group["finding_ids"])
        semantic = group["semantic"]
        require(semantic.get("approved") is True and text(semantic.get("acceptance_criteria"))
                and text(semantic.get("out_of_scope")), "semantic scope unresolved or violated; retain rationale and consider in-scope alternative")
        group_paths = [path(p) for p in group["paths"]]
        paths.extend(group_paths)
        require(isinstance(group["verification_ids"], list) and group["verification_ids"]
                and set(group["verification_ids"]) <= set(ids), "every disposition requires verification")
        require(group["action"] != "fix" or group_paths, "fix disposition requires paths")
        if group["action"] == "base-intake":
            # Files the base changed are not this Issue's work, so its target
            # constraints do not apply to them; any other listed path stays checked.
            require(group_paths, "base intake requires the merged paths")
            merged = base_intake_paths()
            constrained.extend(p for p in group_paths if p not in merged)
        else:
            constrained.extend(group_paths)
    require(len(set(causes)) == len(causes), "combine duplicate root-cause groups")
    require(len(covered) == len(set(covered)) and set(covered) <= known and blocking <= set(covered), "all blocking findings need one disposition; unknown or duplicate finding IDs")
    for entry in constrained:
        require(not any(within(entry, p) or within(p, entry) for p in excluded), "Non-Target violation: " + entry)
        require(not constraints["closed_targets"] or any(within(entry, p) for p in targets), "closed target violation: " + entry)
    return receipt[1], sorted(set(paths))


def fingerprint(test):
    contents = {}

    def visit(entry, ancestors):
        path(entry.as_posix())
        link = os.readlink(entry) if entry.is_symlink() else None
        if entry.is_dir():
            resolved = entry.resolve()
            require(resolved not in ancestors, "cyclic verification input: " + str(entry))
            contents[str(entry)] = [entry.stat().st_mode, "directory", link]
            for child in sorted(entry.iterdir()):
                visit(child, ancestors | {resolved})
        elif entry.is_file():
            contents[str(entry)] = [entry.stat().st_mode, hashlib.sha256(entry.read_bytes()).hexdigest(), link]
        else:
            contents[str(entry)] = ["missing", link]

    for name in test["inputs"]:
        visit(Path(path(name)), set())
    environment = {name: os.environ.get(name) for name in test["environment"]}
    runtime = [platform.platform(), sys.version, subprocess.check_output(["bash", "--version"], text=True).splitlines()[0]]
    return digest([test, contents, environment, runtime, str(Path.cwd().resolve())])


def sandbox_mask(value):
    # Same mechanism-based rule as git-status-filtered.sh: a write-block mount is a
    # character device (stat follows the symlink used to simulate it), and its
    # leftover anchor is an empty regular file with every write bit cleared (lstat,
    # so a symlink to such a stub stays a real untracked entry). An unreadable
    # entry stays dirty. Keep both implementations in step when changing the rule.
    try:
        if stat.S_ISCHR(os.stat(value).st_mode):
            return "device"
        info = os.lstat(value)
    except OSError:
        return None
    return "stub" if stat.S_ISREG(info.st_mode) and info.st_size == 0 and not info.st_mode & 0o222 else None


def verify(plan, paths, output, kind):
    changed = subprocess.check_output(["git", "diff", "--no-renames", "HEAD", "--name-only", "-z"]).decode().split("\0")
    untracked = {p: sandbox_mask(p) for p in subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"]).decode().split("\0") if p}
    stubs = [p for p, mask in untracked.items() if mask == "stub"]
    if stubs:
        print("WARNING: review-fix-scope: " + str(len(stubs)) + " sandbox stub file(s) (0 bytes, no write permission) excluded"
              + " from unplanned path check; user action: delete them by hand once no sandboxed command is running: "
              + " ".join(json.dumps(p, ensure_ascii=False) for p in stubs), file=sys.stderr)
    changed += [p for p, mask in untracked.items() if not mask]
    require(all(any(within(path(p), allowed) for allowed in paths) for p in changed if p), "unplanned changed path; revise plan before continuing")
    result = read(output) if output.exists() else {"review_context": plan["review_context"], "results": {}}
    require(result["review_context"]["session_id"] == plan["review_context"]["session_id"], "verification receipt belongs to another session")
    if result["review_context"] != plan["review_context"]:
        result = {"review_context": plan["review_context"], "results": {}}
    for test in plan["verifications"]:
        if kind == "related" and test["kind"] != "related":
            continue
        key = fingerprint(test)
        previous = result["results"].get(test["id"], {})
        if test["kind"] == "related" and previous.get("key") == key and previous.get("exit_code") == 0:
            print("[CONTEXT] FIX_VERIFICATION=reused; id=" + test["id"])
            continue
        measured = subprocess.run(["bash", "-c", test["command"]], text=True, capture_output=True)
        result["results"][test["id"]] = dict(key=key, command=test["command"], exit_code=measured.returncode,
                                              stdout=measured.stdout, stderr=measured.stderr, executed_at=cycle.now())
        atomic_write(output, result)
        require(measured.returncode == 0,
                "verification failed: " + test["id"] + "; actual_rc=" + str(measured.returncode)
                + "; expected_rc=0; evidence=" + str(output)
                + "; expected nonzero exits must be asserted by a wrapper that exits 0 on success")
        require(fingerprint(test) == key, "verification inputs changed during execution: " + test["id"])
        print("[CONTEXT] FIX_VERIFICATION=executed; id=" + test["id"])
    return result


def peel_commit_prefixes(words):
    """Strip a closed wrapper/keyword set. This is not a shell interpreter."""
    prefixes = {"command", "env", "nohup", "time", "exec"}
    keywords = {"if", "then", "else", "elif", "fi", "do", "done", "for", "while", "until", "in", "!", "{", "}"}
    words = list(words)
    peeled = False
    while words:
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]):
            words, peeled = words[1:], True
            continue
        if words[0] in prefixes:
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[1:]
            peeled = True
            continue
        if words[0] in keywords:
            words, peeled = words[1:], True
            continue
        break
    return words, peeled


# The git subcommands that move HEAD and are checked before they run.
_HEAD_MOVERS = ("commit", "merge")
_SEPARATORS = ";&|()\n"


_HEREDOC = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def _skip_heredoc(command, index, delimiters):
    """Index of the line after the heredoc bodies that start at the newline at index."""
    for strip, word in delimiters:
        while True:
            end = command.find("\n", index + 1)
            line = command[index + 1:] if end < 0 else command[index + 1:end]
            if (line.lstrip("\t") if strip else line) == word:
                index = len(command) if end < 0 else end
                break
            require(end >= 0, "unfinished heredoc; run git commit / git merge separately")
            index = end
    return index


def _substitution_end(command, start):
    """Index just past the ')' closing the $( that ends at start. Not a shell interpreter.

    A heredoc body inside the substitution is data, so its quotes and parentheses do not count.
    """
    depth, index, quote, pending = 1, start, None, []
    while index < len(command):
        ch = command[index]
        if quote:
            if ch == quote:
                quote = None
            elif ch == "\\" and quote == '"':
                index += 1
        elif ch in "'\"":
            quote = ch
        elif ch == "\\":
            index += 1
        elif command.startswith("<<", index) and _HEREDOC.match(command, index):
            match = _HEREDOC.match(command, index)
            pending.append((match.group(1) == "-", match.group(3)))
            index = match.end()
            continue
        elif ch == "\n" and pending:
            index = _skip_heredoc(command, index, pending)
            pending = []
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    require(False, "unfinished command substitution; run git commit / git merge separately")


def _without_heredoc_bodies(command):
    """The command with every heredoc body removed; the << operators stay."""
    out, index, pending, quote = [], 0, [], None
    while index < len(command):
        ch = command[index]
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif command.startswith("<<", index) and _HEREDOC.match(command, index):
            match = _HEREDOC.match(command, index)
            pending.append((match.group(1) == "-", match.group(3)))
            out.append(match.group(0))
            index = match.end()
            continue
        elif ch == "\n" and pending:
            out.append("\n")
            index = _skip_heredoc(command, index, pending) + 1
            pending = []
            continue
        out.append(ch)
        index += 1
    return "".join(out)


def shell_segments(command, nested=False):
    """Split a command into (words, nested) simple commands of dequoted words. Not a shell interpreter.

    Quotes are tracked across a whole word, so a separator inside quotes (echo ';',
    NAME="a (b) c") stays in its word, and a quote may open in the middle of a word.
    A command substitution inside double quotes or backquotes runs in a subshell, so
    its commands come back marked nested, ahead of the command that contains it,
    with heredoc bodies (data) left out.
    """
    segments, words, word, quoted, quote = [], [], [], False, None
    index, length = 0, len(command)

    def end_word():
        nonlocal word, quoted
        if word or quoted:
            words.append("".join(word))
        word, quoted = [], False

    def substitution(body):
        segments.extend((inner, True) for inner, _nested in shell_segments(_without_heredoc_bodies(body), True))

    while index < length:
        ch = command[index]
        if quote == "'":
            if ch == "'":
                quote = None
            else:
                word.append(ch)
        elif quote == '"' and command.startswith("$(", index):
            end = _substitution_end(command, index + 2)
            substitution(command[index + 2:end - 1])
            word.append(command[index:end])
            index = end
            continue
        elif ch == "`" and quote in (None, '"'):
            end = command.find("`", index + 1)
            require(end >= 0, "unfinished command substitution; run git commit / git merge separately")
            substitution(command[index + 1:end])
            word.append(command[index:end + 1])
            quoted = True
            index = end + 1
            continue
        elif quote == '"':
            if ch == '"':
                quote = None
            elif ch == "\\" and index + 1 < length and command[index + 1] in '"\\$`\n':
                index += 1
                if command[index] != "\n":
                    word.append(command[index])
            else:
                word.append(ch)
        elif ch in "'\"":
            quote, quoted = ch, True
        elif ch == "\\" and index + 1 < length:
            index += 1
            if command[index] != "\n":
                word.append(command[index])
                quoted = True
        elif ch == "#" and not word and not quoted:
            while index + 1 < length and command[index + 1] != "\n":
                index += 1
        elif ch in " \t\r":
            end_word()
        elif ch in _SEPARATORS:
            end_word()
            if words:
                segments.append((words, nested))
                words = []
        else:
            word.append(ch)
        index += 1
    require(quote is None, "unfinished quoted command; run git commit / git merge separately")
    end_word()
    if words:
        segments.append((words, nested))
    return segments


def git_subcommand_index(words, git_index):
    """Advance past the same git global options the direct path skips."""
    index = git_index + 1
    while index < len(words) and words[index].startswith("-"):
        option = words[index]
        if option in ("-C", "-c"):
            if index + 1 >= len(words):
                return None
            index += 2
        elif option.startswith("-C"):
            index += 1
        elif option.startswith("-c") or option in ("--no-pager", "--no-optional-locks"):
            index += 1
        else:
            return index if any(name in words[index:] for name in _HEAD_MOVERS) else None
    return index if index < len(words) else None


def each_git_target(command, cwd):
    """Yield (subcommand, toplevel, arguments, problem) for each git commit / merge, in order.

    problem names why the target cannot be checked (a wrapper, a command substitution,
    a dynamic cd / -C, an alternate git dir); the caller refuses it only when the command would move HEAD.
    toplevel is None when there is a problem or the target is not a repository.
    """
    cwd, dynamic = Path(cwd).resolve(), False
    for words, nested in shell_segments(command):
        # A substitution runs in a subshell: its cd stays there, and its git is not direct.
        if not nested and words and words[0] == "cd" and len(words) == 2:
            if any(c in words[1] for c in "$`~"):
                dynamic = True
            elif not dynamic or Path(words[1]).is_absolute():
                cwd, dynamic = (cwd / words[1]).resolve(), False
            continue
        words, _peeled = peel_commit_prefixes(words)
        if not words:
            continue
        if nested or Path(words[0]).name != "git":
            if Path(words[0]).name in {"echo", "printf"}:
                continue
            names = [Path(word).name for word in words]
            if "git" in names:
                sub = git_subcommand_index(words, names.index("git"))
                for name in _HEAD_MOVERS:
                    if sub is not None and name in words[sub:]:
                        yield name, None, words[words.index(name, sub) + 1:], \
                            "run " + name + " as a direct command in its own Bash call"
            continue
        target, unknown, index, alternate = cwd, dynamic, 1, False
        while index < len(words) and words[index].startswith("-"):
            option = words[index]
            if option in ("-C", "-c") or option.startswith("-C"):
                joined = option.startswith("-C") and option != "-C"
                if not joined:
                    require(index + 1 < len(words), "incomplete git global option")
                value = option[2:] if joined else words[index + 1]
                if option.startswith("-C"):
                    if any(c in value for c in "$`~"):
                        unknown = True
                    else:
                        target = (target / value).resolve()
                        unknown = unknown and not Path(value).is_absolute()
                index += 1 if joined else 2
            elif option.startswith("-c") or option in ("--no-pager", "--no-optional-locks"):
                index += 1
            else:
                alternate = True
                break
        if alternate:
            for name in _HEAD_MOVERS:
                if name in words[index:]:
                    yield name, None, words[words.index(name, index) + 1:], \
                        "use git -C <worktree> " + name + " without alternate git-dir/work-tree options"
            continue
        if index >= len(words) or words[index] not in _HEAD_MOVERS:
            continue
        name = words[index]
        if unknown:
            yield name, None, words[index + 1:], \
                name + " target is dynamic; run it separately from its resolved worktree"
            continue
        try:
            actual = Path(subprocess.check_output(
                ["git", "-C", str(target), "rev-parse", "--show-toplevel"], text=True, stderr=subprocess.DEVNULL
            ).strip()).resolve()
        except subprocess.CalledProcessError:
            # Not a repository, so it is not the session worktree. commit-target
            # still refuses this; a review check must not turn it into a deny.
            actual = None
        yield name, actual, words[index + 1:], None


def head_move(name, args):
    """How a git commit / merge moves HEAD: "commit" (checked evidence), "merge" (refused) or None."""
    if name == "commit":
        # Option values (notably -m '--dry-run') must not exempt a real commit.
        return None if classify_commit_args(args)[0] else "commit"
    moves = merge_kind(args)
    return {"concludes": "commit", "commits": "merge", "unreadable": "unreadable"}.get(moves)


def each_direct_commit(command, cwd):
    """Yield the toplevel of each direct git commit. This is not a shell interpreter."""
    for name, actual, args, problem in each_git_target(command, cwd):
        if name != "commit" or head_move(name, args) is None:
            continue
        require(problem is None, problem or "")
        yield actual, classify_commit_args(args)[1] if actual is not None else True


_MERGE_VALUE = {"-m", "-F", "-s", "-X", "--message", "--file", "--strategy", "--strategy-option", "--into-name"}
_MERGE_SWITCHES = {"--commit", "--no-commit", "--squash", "--no-squash", "--ff", "--no-ff", "--ff-only",
                   "--continue", "--abort", "--quit"}
_MERGE_LONG = _MERGE_SWITCHES | {option for option in _MERGE_VALUE if option.startswith("--")}


def merge_kind(args):
    """How a git merge moves HEAD: "concludes" (--continue), "commits" (by itself), "unreadable" or None.

    git reads --commit/--no-commit, --squash/--no-squash and --ff/--no-ff/--ff-only
    as last-one-wins, so a later option overrides an earlier exemption. git also takes
    a unique prefix of a long option; an abbreviation of these options cannot be read
    safely, so it is "unreadable" and refused like a merge that commits.
    """
    commits, squash, ff_only, action = True, False, False, None
    index = 0
    while index < len(args):
        word = args[index]
        if word == "--":
            break
        if word in _MERGE_VALUE:
            index += 2
            continue
        if word.startswith("--"):
            name = word.split("=", 1)[0]
            if name not in _MERGE_LONG and any(option.startswith(name) for option in _MERGE_LONG):
                return "unreadable"
            if name in ("--continue", "--abort", "--quit"):
                action = name
            elif name in ("--commit", "--no-commit"):
                commits = name == "--commit"
            elif name in ("--squash", "--no-squash"):
                squash = name == "--squash"
            elif name in ("--ff", "--no-ff", "--ff-only"):
                ff_only = name == "--ff-only"
        elif word.startswith("-") and len(word) > 1:
            # A short cluster ends at its first value-taking letter (-nm msg, -mmsg).
            for position, letter in enumerate(word[1:], 1):
                if letter in "mFsX":
                    if position == len(word) - 1:
                        index += 1
                    break
        index += 1
    if action == "--continue":
        return "concludes"
    if action or not commits or squash or ff_only:
        return None
    return "commits"


def commit_check(args):
    """Read existing evidence before a direct commit; never run tests or write state."""
    state_path = Path(args.state)
    if not state_path.exists() and not state_path.is_symlink():
        return  # A session that has never reviewed still commits normally.
    state = read(state_path)
    require(isinstance(state, dict) and state.get("session_id") == args.session,
            "cannot read a valid session state before commit")
    stagnation = importlib.import_module("review-stagnation")
    retained = None
    if state.get("review_cycle") is None:
        if "review_run" not in state:
            return
        retained = stagnation.retained_run(state, args.session)
    # A merge that concludes with --continue records the same staged state as
    # git commit; a merge that commits by itself cannot be verified beforehand.
    for name, actual, arguments, problem in each_git_target(args.command, args.cwd):
        kind = head_move(name, arguments)
        if kind is None:
            continue  # a dry run, or a merge that leaves HEAD where it is
        require(problem is None, problem or "")
        if actual is None:
            continue
        os.chdir(actual)
        if "worktree" not in state:
            require(actual == Path(args.state_root).resolve(),
                    "session worktree path is missing from state; cannot tell if this commit belongs to the review")
            owner = args.state_root
        else:
            owner = state["worktree"]
        if actual != Path(owner).resolve():
            continue
        if retained is not None:
            require(retained.get("status") != "stopped",
                    "review run stopped: " + str(retained.get("stop_reason")))
            return
        require(kind != "unreadable",
                "an abbreviated git merge option cannot be read during review; spell --commit, --no-commit, "
                "--squash, --ff-only, --abort, --quit and --continue in full")
        require(kind != "merge",
                "a merge that commits by itself cannot be verified during review; " + BASE_INTAKE_STEPS)
        frozen = state.get("review_cycle")
        require(isinstance(frozen, dict), "review run has no frozen cycle; start its review before committing")
        require(frozen.get("status") == "completed",
                "review is incomplete; collect reviewers and run review-finish before committing")
        directory = Path(args.state_root) / ".rite/state"
        approved_path = directory / ("fix-plan-" + args.session + ".json")
        require(approved_path.is_file(),
                "fix plan record missing; run check --plan <plan> --issue <issue> before committing"
                + ("; this concludes a merge: " + BASE_INTAKE_CONCLUDE if merge_head() else ""))
        approved = read(approved_path)
        plan = approved["plan"]
        issue = approved.get("issue")
        require(isinstance(issue, dict) and issue.get("number") == state.get("issue_number")
                and text(issue.get("body")),
                "fix-scope Issue snapshot missing; run check --plan <plan> --issue <issue> before committing")
        receipt, paths = validate(plan, issue, state, args.session, Path(args.state_root))
        require(approved["plan_hash"] == digest(plan) and approved["review_hash"] == digest(receipt),
                "plan or review changed; check scope before committing")
        result = read(directory / ("fix-verification-" + args.session + ".json"))
        require(result.get("review_context") == plan["review_context"], "verification belongs to another review")
        for test in plan["verifications"]:
            measured = result["results"].get(test["id"])
            require(measured and measured.get("exit_code") == 0 and measured.get("key") == fingerprint(test),
                    "run fix-scope verify --kind all before committing; stale/missing verification: " + test["id"])
        # Same unplanned-path condition as verify(), including its sandbox mask: a
        # write-block device or its 0-byte read-only stub is not a real change, so a
        # sandboxed run must not make the commit it just verified unreachable.
        changed = subprocess.check_output(["git", "diff", "--no-renames", "HEAD", "--name-only", "-z"]).decode().split("\0")
        untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"]).decode().split("\0")
        changed += [p for p in untracked if p and not sandbox_mask(p)]
        require(all(any(within(path(p), allowed) for allowed in paths) for p in changed if p),
                "unplanned changed path; check scope and verify before committing")
        if "review_run" in state:
            pending = state["review_run"].get("pending_fix")
            require(isinstance(pending, dict) and pending.get("source_context") == plan["review_context"]
                    and pending.get("plan_hash") == digest(plan)
                    and pending.get("tree_hash") == stagnation.tree_fingerprint(),
                    "fix tree changed; run fix-scope verify --kind all before committing")


def commit_target_main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", required=True)
    parser.add_argument("--cwd", required=True)
    args = parser.parse_args(argv)
    for actual, index_only in each_direct_commit(args.command, args.cwd):
        require(actual is not None, "commit worktree cannot be resolved")
        print(("index" if index_only else "other") + "\t" + str(actual))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "commit-target":
        commit_target_main(sys.argv[2:])
        return
    if len(sys.argv) > 1 and sys.argv[1] == "classify-extras":
        extras = sys.argv[2:]
        if extras[:1] == ["--"]:
            extras = extras[1:]
        dry_run, index_only = classify_commit_args(extras)
        print("dry-run" if dry_run else ("index" if index_only else "other"))
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("check", "verify", "commit-check"))
    for name in ("state", "session", "state-root"):
        parser.add_argument("--" + name, required=True)
    for name in ("plan", "issue", "command", "cwd"):
        parser.add_argument("--" + name)
    parser.add_argument("--kind", choices=("related", "all"), default="all")
    args = parser.parse_args()
    if args.operation == "commit-check":
        require(args.command is not None and args.cwd, "commit-check requires command and cwd")
        commit_check(args)
        return
    require(args.plan and args.issue, "check/verify require plan and issue")
    root = Path(args.state_root)
    directory = root / ".rite/state"
    saved = directory / ("fix-plan-" + args.session + ".json")
    # The check record replaces its target; a plan handed in under that name
    # (by any spelling or symlink) would be destroyed before it could be verified.
    require(Path(args.plan).resolve() != saved.resolve(), "plan input must not be the check record: " + str(saved))
    plan, issue, state = read(args.plan), read(args.issue), read(args.state)
    receipt, paths = validate(plan, issue, state, args.session, root)
    directory.mkdir(parents=True, exist_ok=True)
    record = dict(plan=plan, issue={"number": issue["number"], "body": issue["body"]},
                  plan_hash=digest(plan), review_hash=digest(receipt),
                  mechanical=dict(paths=paths, non_targets=plan["constraints"]["non_targets"]), checked_at=cycle.now())
    # A reverted command can have an old plan hash; bind approval to its audit too.
    for replan in state.get("review_run", {}).get("replans", []):
        if replan["review_context"] == plan["review_context"] and replan.get("amendments"):
            record["amendment_hash"] = digest(replan["amendments"])
    if args.operation == "check":
        atomic_write(saved, record)
        print("[CONTEXT] FIX_SCOPE=pass; record=" + str(saved))
    else:
        approved = read(saved)
        require(approved["plan_hash"] == record["plan_hash"] and approved["review_hash"] == record["review_hash"], "plan or review changed; check scope again")
        require(approved.get("amendment_hash") == record.get("amendment_hash"), "plan amended; check scope again")
        result = verify(plan, paths, directory / ("fix-verification-" + args.session + ".json"), args.kind)
        if args.kind == "all" and "review_run" in state:
            importlib.import_module("review-stagnation").verified(state, plan, result, paths)
            atomic_write(Path(args.state), state)
        print("[CONTEXT] FIX_VERIFICATION=pass; kind=" + args.kind)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.SubprocessError) as error:
        print("ERROR: review-fix-scope: " + json.dumps(str(error), ensure_ascii=False)
              + "; retain plan/evidence and return [fix:error]", file=sys.stderr)
        sys.exit(1)
