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


class _Redirection(str):
    """A word shell_segments read as an unquoted redirection (>out, 2>&1, &>log, >)."""


# A redirection word with no target in it (>, 2>, &>, <&); the shell takes the next word as its target.
_BARE_REDIRECTION = re.compile(r"(?:[0-9]*|&)[<>&]+")


def _redirection_end(words, index):
    """Index past the redirection at index, together with the target a bare operator takes."""
    if _BARE_REDIRECTION.fullmatch(words[index]) and index + 1 < len(words):
        return index + 2
    return index + 1


def _without_redirections(args):
    """Drop the redirections; a bare operator (>, 2>, &>) also drops the target after it.
    A bare operator with nothing after it stays, so it is still read as a pathspec."""
    kept, index = [], 0
    while index < len(args):
        word = args[index]
        if isinstance(word, _Redirection):
            if not _BARE_REDIRECTION.fullmatch(word):
                index += 1
                continue
            if index + 1 < len(args):
                index += 2
                continue
        kept.append(word)
        index += 1
    return kept


def classify_commit_args(args):
    """Return whether these tokens after `commit` are a dry run, and whether
    they record the index. A value glued on with '=' is not a following pathspec.
    `--amend` stays an index commit. A redirection word (one whose first unquoted
    `<` or `>` has only a file-descriptor number or the `&` of `&>` before it) is
    not an argument, and neither is the word after it when the redirection word is
    only an optional fd number or `&` followed by `<`, `>` and `&`; these are dropped
    before any option takes its value. As shell_segments reads a command, a bare
    operator with no word after it still counts: in `>|` the pipe ends the
    command, so nothing follows its `>`. `{fd}>out` is not a redirection word and
    also still counts."""
    args = _without_redirections(args)
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


def planned(changed, plan, paths):
    """Whether a changed path is covered by the plan's paths."""
    # A symlink listed only for the base intake skips the target checks, so it
    # covers the link itself and never the tree behind it.
    others = {path(p) for g in plan["groups"] if g["action"] != "base-intake" for p in g["paths"]}
    exact = {path(p) for g in plan["groups"] if g["action"] == "base-intake" for p in g["paths"]
             if Path(p).is_symlink() and path(p) not in others}
    return any(changed == allowed if allowed in exact else within(changed, allowed) for allowed in paths)


def validate_context(plan, state, session, directory):
    """Bind a plan to the frozen cycle, its HEAD and its saved receipt.

    Split out from validate() because deciding *whether* a state may move
    (plan_gate) and checking *what* a plan says are separate questions: the
    retry path answers the first one itself and still needs both of these.
    """
    cycle.require_session_worktree(state)
    require(state.get("session_id") == session, "foreign session state")
    current = state.get("review_cycle")
    require(isinstance(current, dict) and current.get("status") == "completed", "all reviews must be collected and saved")
    context = current["review_context"]
    require(context["session_id"] == session and context["pr_number"] == state.get("pr_number")
            and context["cycle_count"] == state.get("cycle_count"), "review context differs from current state")
    require(plan.get("review_context") == context and cycle.head() == context["commit_sha"], "stale or foreign review context / HEAD")
    receipt = cycle.matching_receipt(directory, current)
    require(receipt is not None, "saved review receipt missing")
    # The saved receipt is never rewritten, so the in-PR recommendations the review's triage
    # registered on this commit (review-pr-recommendations.sh record) travel beside it.
    registered = directory.parent / "state" / ("pr-recommendations-%s.json" % receipt[1]["pr_number"])
    recommendations = []
    if registered.exists():
        data = read(registered)
        require(isinstance(data, dict) and isinstance(data.get("recommendations"), list),
                "in-PR recommendations are unreadable: " + str(registered))
        if data.get("commit_sha") == receipt[1]["commit_sha"]:
            recommendations = data["recommendations"]
    return receipt[0], dict(receipt[1], pr_recommendations=recommendations)


def validate(plan, issue, state, session, root, allow_replan=False):
    receipt = validate_context(plan, state, session, root / ".rite/review-results")
    importlib.import_module("review-stagnation").plan_gate(state, plan, session, allow_replan)
    return validate_plan(plan, issue, state, receipt)


# The one supported way to take the base branch into a reviewed PR branch.
BASE_INTAKE_STEPS = ("git fetch origin <base>, take it in with git merge --no-commit --no-ff origin/<base>, "
                     "resolve and stage it, add a base-intake group to the fix plan, run check and "
                     "verify --kind all, re-capture the wiki apply record, commit, advance the record's head, "
                     "push, then re-run /rite:iterate "
                     "(skills/fix/references/fix-plan.md, section: base 取り込み)")
# The same route, entered with a merge already in progress.
BASE_INTAKE_CONCLUDE = ("if it takes in origin/<base>, resolve and stage it, add a base-intake group to the fix plan, "
                        "run check and verify --kind all, re-capture the wiki apply record, commit, advance the record's head, "
                        "push, then re-run /rite:iterate; otherwise "
                        "git merge --abort and start over (skills/fix/references/fix-plan.md, section: base 取り込み)")
# The same route, entered while the review still waits for CI that a base conflict keeps from starting.
BASE_INTAKE_WAITING = ("if the review waits for CI while the PR conflicts with its base, re-run the review (/rite:iterate); "
                       "on REVIEW_CI_FINAL=blocked; reason=base_conflict pr-review abandons the cycle, and the merge "
                       "can then be committed (skills/fix/references/fix-plan.md, section: base 取り込み, CI 待ちの cycle を閉じた後)")


def merge_head():
    """The commit an in-progress merge brings in, or None when no merge is in progress."""
    merge = subprocess.run(["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"], capture_output=True, text=True)
    return merge.stdout.strip() if merge.returncode == 0 and merge.stdout.strip() else None


def configured_base():
    """branch.base from rite-config.yml, or None when the file is absent or the key is unset.

    An unreadable config is an error, not an unset key.
    """
    located = subprocess.run(["bash", str(Path(__file__).with_name("rite-config-path.sh"))],
                             capture_output=True, text=True)
    if located.returncode == 1:
        return None
    require(located.returncode == 0, "cannot read rite-config.yml: " + located.stderr.strip())
    config = Path(located.stdout.strip())
    try:
        lines = config.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as error:
        require(False, "cannot read rite-config.yml: " + str(config) + ": " + str(error))
    in_branch = False
    for line in lines:
        if re.match(r"[^ ]", line):
            in_branch = line.split("#", 1)[0].strip() == "branch:"
            continue
        match = re.match(r"\s+base:\s*(.*)", line)
        if in_branch and match:
            value = re.sub(r"\s#.*", "", match.group(1)).strip().strip("\"'")
            if value and value != "null":
                return value
            break
    return None


def base_branch(pr_number):
    """The PR's own base branch (baseRefName). It decides what base intake may exempt, so it has no default.

    A branch.base set in rite-config.yml is checked against it, never used in its place.
    """
    require(type(pr_number) is int and pr_number > 0,
            "base intake needs the PR number from the flow state; got " + repr(pr_number))
    found = subprocess.run(["gh", "pr", "view", str(pr_number), "--json", "baseRefName", "--jq", ".baseRefName"],
                           capture_output=True, text=True)
    require(found.returncode == 0,
            "cannot read baseRefName of PR " + str(pr_number) + " with gh pr view: " + found.stderr.strip())
    base = found.stdout.strip()
    require(base, "PR " + str(pr_number) + " has an empty baseRefName; base intake cannot identify the base branch")
    configured = configured_base()
    require(configured is None or configured == base,
            "branch.base in rite-config.yml is " + repr(configured) + " but PR " + str(pr_number)
            + " targets baseRefName " + repr(base) + "; fix the setting or retarget the PR")
    return base


def base_intake_paths(state):
    """Paths the in-progress merge brings in from origin/<the PR's base branch>."""
    other = merge_head()
    require(other, "base intake requires a merge in progress; start it with git merge --no-commit --no-ff origin/<base>")
    base = base_branch(state.get("pr_number"))
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
            and cycle.same_specification(plan["issue_body"], issue["body"]),
            "Issue specification changed or mismatched" + cycle.spec_change_hint(state, issue.get("body") or ""))
    constraints = plan["constraints"]
    targets = [path(p) for p in constraints["targets"]]
    excluded = [path(p) for p in constraints["non_targets"]]
    require(type(constraints.get("closed_targets")) is bool and text(constraints.get("rationale")), "target interpretation needs rationale")
    # Standard Implementation Contract paths are independently checked; other
    # prose restrictions remain an explicit semantic judgment by the caller.
    section = re.search(r"^### 4\.2 .*?\n(.*?)(?=^#{1,3} |\Z)", issue["body"], re.M | re.S)
    if section:
        explicit = [p for p in re.findall(r"`([^`\n]+)`", section[1]) if Path(p).exists()]
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
    # In-PR recommendations (adopted PR-origin root causes) each need one
    # disposition, like a blocking finding, so none is silently dropped.
    recommended = {r["id"] for r in receipt[1]["pr_recommendations"]}
    # So do purpose deviations recorded against this review with review-deviate.
    recommended |= {d["id"] for d in importlib.import_module("review-stagnation").deviations(
        state, receipt[1]["review_context"])}
    known |= recommended
    blocking |= recommended
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
            # A symlink among them covers only itself when changes are matched (planned).
            require(group_paths, "base intake requires the merged paths")
            merged = base_intake_paths(state)
            constrained.extend(p for p in group_paths if p not in merged)
        else:
            constrained.extend(group_paths)
    require(len(set(causes)) == len(causes), "combine duplicate root-cause groups")
    require(len(covered) == len(set(covered)) and set(covered) <= known and blocking <= set(covered), "all blocking findings need one disposition; unknown or duplicate finding IDs")
    for entry in constrained:
        require(not any(within(entry, p) or within(p, entry) for p in excluded), "Non-Target violation: " + entry)
    for entry in constrained:
        require(not constraints["closed_targets"] or any(within(entry, p) for p in targets), "closed target violation: " + entry)
    return receipt[1], sorted(set(paths))


def bytecode_cache(entry):
    # Running the tests rewrites these, so hashing them would make every later
    # test run look like an input change. A symlink is never skipped: it still
    # goes through the worktree-escape check.
    if entry.is_symlink():
        return False
    return (entry.name == "__pycache__" and entry.is_dir()) or (entry.suffix == ".pyc" and entry.is_file())


def fingerprint(test):
    contents = {}

    def visit(entry, ancestors, skip_cache):
        path(entry.as_posix())
        link = os.readlink(entry) if entry.is_symlink() else None
        if entry.is_dir():
            resolved = entry.resolve()
            require(resolved not in ancestors, "cyclic verification input: " + str(entry))
            contents[str(entry)] = [entry.stat().st_mode, "directory", link]
            for child in sorted(entry.iterdir()):
                if not (skip_cache and bytecode_cache(child)):
                    visit(child, ancestors | {resolved}, skip_cache)
        elif entry.is_file():
            contents[str(entry)] = [entry.stat().st_mode, hashlib.sha256(entry.read_bytes()).hexdigest(), link]
        else:
            contents[str(entry)] = ["missing", link]

    for name in test["inputs"]:
        entry = Path(path(name))
        # A cache named as an input is checked in full.
        visit(entry, set(), not bytecode_cache(entry))
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
    require(all(planned(path(p), plan, paths) for p in changed if p), "unplanned changed path; revise plan before continuing")
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


_KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "for", "while", "until", "in", "!", "{", "}"}


def _prefix_end(words, index=0):
    """Index of the first word past assignments, keywords and a closed wrapper set."""
    prefixes = {"command", "env", "nohup", "time", "exec"}
    while index < len(words):
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[index]) or words[index] in _KEYWORDS:
            index += 1
            continue
        if words[index] in prefixes:
            index += 1
            while index < len(words) and words[index].startswith("-"):
                index += 1
            continue
        break
    return index


def peel_commit_prefixes(words):
    """Strip a closed wrapper/keyword set. This is not a shell interpreter."""
    index = _prefix_end(words)
    return list(words[index:]), index > 0


# The builtins that change the working directory.
_DIRECTORY_MOVERS = {"cd", "pushd", "popd"}


def moves_directory(words):
    """True when words run a directory change, past assignments, keywords and wrappers."""
    index = _prefix_end(words)
    while index < len(words) and words[index] == "builtin":
        index += 1
        if index < len(words) and words[index] == "--":
            index += 1
        index = _prefix_end(words, index)
    return index < len(words) and words[index] in _DIRECTORY_MOVERS


# The git subcommands that move HEAD and are checked before they run.
_HEAD_MOVERS = ("commit", "merge")
_SEPARATORS = ";&|\n"
# Words that open a compound command or a function; a cd inside one runs only when the shell gets there.
_COMPOUND = {"if", "while", "until", "for", "case", "select", "{", "function", "coproc"}


# A parse the check cannot finish is refused; the message form below always parses.
# Limits on the costs of one parse beyond reading its input once: each substitution level
# scans its text again, and each cd / -C resolves the whole directory path built so far.
# Past a limit the parse goes on without that work: a deeper substitution is not parsed
# (and is refused when its text could spell git and commit / merge), and a later cd / -C
# leaves a dynamic target. Only a cd / -C makes a new commit / merge
# target, so this also bounds the git processes that resolve targets.
MAX_SUBSTITUTION_DEPTH = 64
MAX_DIRECTORY_CHANGES = 16
_PARSE_HINT = "; write the message to a file outside the work tree and commit with git commit -F <message-file>"
# The standard message form: a substitution that is exactly cat of one heredoc.
_MESSAGE = re.compile(r"\$\([ \t]*cat[ \t]+<<(-?)[ \t]*(?:'([^'\n]+)'|\"([^\"\n]+)\"|\\([A-Za-z_][A-Za-z0-9_]*)"
                      r"|([A-Za-z_][A-Za-z0-9_]*))[ \t]*\n")
_MESSAGE_CLOSE = re.compile(r"[ \t\n]*\)")


def _message_end(command, index):
    """Index just past a $( at index that is the standard message form, else None.

    bash ends a heredoc at its first delimiter line, so only whitespace may follow that
    line before the ')'. An unquoted delimiter lets bash expand the body, so such a body
    is data only when it holds no command substitution.
    """
    match = _MESSAGE.match(command, index)
    if not match:
        return None
    strip = match.group(1) == "-"
    delimiter = next(group for group in match.group(2, 3, 4, 5) if group is not None)
    start = line_start = match.end()
    while True:
        end = command.find("\n", line_start)
        if end < 0:
            return None
        line = command[line_start:end]
        if (line.lstrip("\t") if strip else line) == delimiter:
            break
        line_start = end + 1
    if match.group(5) is not None and ("$(" in command[start:line_start] or "`" in command[start:line_start]):
        return None
    close = _MESSAGE_CLOSE.match(command, end + 1)
    return close.end() if close else None


def _substitution_end(command, start):
    """Index just past the ')' closing the $( that ends at start. Not a shell interpreter."""
    depth, index, quote = 1, start, None
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
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    require(False, "unfinished command substitution" + _PARSE_HINT)


def shell_segments(command, level=0, group_ids=False, omit_case_patterns=False):
    """Split a command into (words, nested, before, after) simple commands of dequoted words.
    Not a shell interpreter.

    Quotes are tracked across a whole word, so a separator inside quotes (echo ';',
    NAME="a (b) c") stays in its word, and a quote may open in the middle of a word.
    A command substitution or a ( ) group runs in a subshell, so its commands come back
    marked nested (True for a substitution, "group" for a group); a substitution's commands
    come ahead of the command that contains it. With group_ids, a group's commands come
    back marked ("group", ids) instead, ids naming each enclosing group from the outermost,
    so separate groups can be told apart.
    The standard message form $(cat <<DELIM ... DELIM) is data and stays in its word.
    before / after are the control operators around a command: ";" (also a newline),
    "&&", "||", "|" (also |&), "&", or "" at the start, the end and around a substitution.
    A newline right after &&, || or | continues the list. The & of a redirection
    (&>, >&, <&) stays in its word. A word whose first unquoted < or > has only an
    unquoted fd number or the & of &> before it comes back as a _Redirection.
    omit_case_patterns removes case pattern words and their delimiters while
    retaining the case header, esac, arm commands and pattern substitutions.
    """
    if level > MAX_SUBSTITUTION_DEPTH:
        # The text is not parsed, so its words are read with quotes and backslashes (and line
        # continuations) dropped; text whose words could spell git and commit / merge is refused.
        flat = re.sub(r"\\\n|[\"'\\]", "", command)
        require("git" not in flat or not any(name in flat for name in _HEAD_MOVERS),
                "command substitutions are nested more than " + str(MAX_SUBSTITUTION_DEPTH)
                + " deep to inspect; split the command")
        return []
    segments, words, word, quoted, quote, depth = [], [], [], False, None, 0
    index, length, pending, redirect, redirection, signed = 0, len(command), "", -2, False, False
    groups, opened = [], 0
    # The cwd reader needs pattern boundaries before dequoting loses them. Other
    # users retain the existing segment representation unless they opt in.
    cases = []

    def end_word():
        nonlocal word, quoted, redirection, signed
        flush_header = False
        if word or quoted:
            value = "".join(word)
            keep = True
            command_start = not words or all(w in _KEYWORDS for w in words)
            if omit_case_patterns:
                if cases and cases[-1][0] == "subject":
                    cases[-1][0] = "in"
                elif cases and cases[-1][0] == "in":
                    if value == "in" and not quoted:
                        cases[-1][0] = "pattern"
                        flush_header = True
                elif cases and cases[-1][0] == "pattern":
                    if value == "esac" and not quoted and not cases[-1][1]:
                        cases.pop()
                    else:
                        cases[-1][1] = True
                        keep = False
                elif not quoted and command_start:
                    if value == "case":
                        cases.append(["subject", False, 0])
                    elif value == "esac" and cases:
                        cases.pop()
            if keep:
                words.append((_Redirection if redirection else str)(value))
        word, quoted, redirection, signed = [], False, False, False
        if flush_header:
            end_segment()

    def end_segment(operator=""):
        nonlocal words, pending
        end_word()
        if words:
            marker = ("group", tuple(groups)) if group_ids and groups else "group"
            segments.append((words, marker if depth else False, pending, operator))
            pending = operator
        elif operator and pending not in ("&&", "||", "|"):
            # A newline right after && / || / | continues the list.
            pending = operator
        words = []

    while index < length:
        ch = command[index]
        if quote == "'":
            if ch == "'":
                quote = None
            else:
                word.append(ch)
        elif quote in (None, '"') and command.startswith("$(", index):
            end = _message_end(command, index)
            if end is None:
                end = _substitution_end(command, index + 2)
                segments.extend((inner, True, "", "") for inner, *_rest in
                                shell_segments(command[index + 2:end - 1], level + 1,
                                               omit_case_patterns=omit_case_patterns))
            word.append(command[index:end])
            quoted = True
            index = end
            continue
        elif ch == "`" and quote in (None, '"'):
            end = command.find("`", index + 1)
            require(end >= 0, "unfinished command substitution" + _PARSE_HINT)
            segments.extend((inner, True, "", "") for inner, *_rest in
                            shell_segments(command[index + 1:end], level + 1,
                                           omit_case_patterns=omit_case_patterns))
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
        elif cases and cases[-1][0] == "pattern" and ch in "()|":
            end_word()
            if ch == "(":
                # An optional leading '(' belongs to the pattern, as do extglob
                # parentheses following its first word.
                if cases[-1][1]:
                    cases[-1][2] += 1
                cases[-1][1] = True
            elif ch == ")":
                if cases[-1][2]:
                    cases[-1][2] -= 1
                else:
                    cases[-1][0] = "body"
                    end_segment()
            else:
                cases[-1][1] = True
        elif ch == "(":
            end_segment()
            depth += 1
            opened += 1
            groups.append(opened)
        elif ch == ")":
            end_segment()
            depth = max(depth - 1, 0)
            groups = groups[:depth]
        elif ch == "&" and (command.startswith(">", index + 1) or redirect == index - 1):
            word.append(ch)
        elif ch in _SEPARATORS:
            operator = ";" if ch == "\n" else ch
            if ch in "&|;" and command.startswith(ch, index + 1):
                index += 1
                operator = ";" if ch == ";" else ch * 2
            elif ch == "|" and command.startswith("&", index + 1):
                index += 1
            end_segment(operator)
            if cases and cases[-1][0] == "body" and ch == ";" and (
                    command[index - 1:index + 1] == ";;" or command[index:index + 2] == ";&"):
                cases[-1] = ["pattern", False, 0]
                if command[index + 1:index + 2] == "&":
                    index += 1
        else:
            if ch in "<>":
                redirect = index  # an unquoted, unescaped redirection sign
                # Any other prefix (file>out, "2">out) stays unmarked and still counts as a pathspec.
                # Only the first sign decides: later prefixes hold a sign and cannot match, so the
                # prefix is joined once per word.
                if not signed:
                    signed = True
                    redirection = not quoted and re.fullmatch(r"[0-9]*|&", "".join(word)) is not None
            word.append(ch)
        index += 1
    require(quote is None, "unfinished quoted command" + _PARSE_HINT)
    end_segment()
    return segments


# The git global options that take their value as the next word.
_GIT_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                      "--super-prefix", "--attr-source", "--shallow-file"}


def git_global_options(words, git_index=0):
    """Walk the global options after the git at words[git_index]: (index, steps, alternate).

    index is the subcommand word (len(words) when nothing follows), or None when an option
    that takes the next word as its value has none. steps lists, in order, ("-C", directory)
    for each -C and ("dynamic", word) for each variable or command substitution, which may
    expand to nothing or to global options, so the next word may still be the subcommand.
    alternate is the index of the first option other than -C / -c / --no-pager /
    --no-optional-locks (an alternate git dir or work tree, or any other), or None; steps
    after it are not listed.
    The shell removes redirections before git sees its arguments, so one between git and
    the subcommand, or between an option and its value, is skipped.
    """
    steps, alternate, index = [], None, git_index + 1
    while index < len(words) and (words[index].startswith("-") or isinstance(words[index], _Redirection)
                                  or any(c in words[index] for c in "$`")):
        option = words[index]
        if isinstance(option, _Redirection):
            index = _redirection_end(words, index)
            continue
        if not option.startswith("-"):
            if alternate is None:
                steps.append(("dynamic", option))
            index += 1
            continue
        if option not in ("-C", "-c", "--no-pager", "--no-optional-locks") \
                and not option.startswith(("-C", "-c")) and alternate is None:
            alternate = index
        if option in _GIT_VALUE_OPTIONS:
            value_index = index + 1
            while value_index < len(words) and isinstance(words[value_index], _Redirection):
                value_index = _redirection_end(words, value_index)
            if value_index >= len(words):
                return None, steps, alternate
            value, index = words[value_index], value_index + 1
        else:
            value, index = option[2:], index + 1
        if option.startswith("-C") and not option.startswith("--") and alternate is None:
            steps.append(("-C", value))
    return index, steps, alternate


def git_subcommand_index(words, git_index):
    """The subcommand index of a git that is not the command itself, or None when it has none.
    Past an alternate option, the option's own index when a commit / merge follows it."""
    index, _steps, alternate = git_global_options(words, git_index)
    if alternate is not None:
        return alternate if any(name in words[alternate:] for name in _HEAD_MOVERS) else None
    return index if index is not None and index < len(words) else None


def each_git_target(command, cwd):
    """Yield (subcommand, toplevel, arguments, problem) for each git commit / merge, in order.

    problem names why the target cannot be checked (a wrapper, a command substitution,
    a dynamic cd / -C, a variable before the subcommand, a target that does not resolve to a repository, an alternate git dir); the caller
    refuses it only when the command would move HEAD. toplevel is None exactly when there is a problem.

    A cd moves the target only where the shell is known to run it: a plain cd <literal> that
    starts a list (after ; / a newline or at the start), or one in an && chain, which
    reaches only the rest of that chain, in a command with no ( ) group, compound command,
    function or background &. Any other cd (after ||, in a pipeline, cd -, with options,
    redirections or no directory, behind an assignment or a builtin / command / time
    wrapper, or anywhere in a command with one of those) and any pushd / popd make the
    target dynamic, and later lists cannot know it either.
    """
    segments = shell_segments(command)
    structured = any(nested == "group" or (not nested and (after == "&" or not _COMPOUND.isdisjoint(words)))
                     for words, nested, _before, after in segments)
    cwd, dynamic = Path(cwd).resolve(), False  # where the next list starts
    here, unsure, first, alternative, moved = cwd, dynamic, True, False, False
    toplevels = {}  # target -> its toplevel, or None when it does not resolve
    changes = 0

    def change(base, value):
        """The resolved directory, or None when the limit is used up and it stays unknown."""
        nonlocal changes
        if changes >= MAX_DIRECTORY_CHANGES:
            return None
        changes += 1
        return (base / value).resolve()

    for words, nested, before, after in segments:
        # A subshell keeps its cd, and its git is not direct.
        if not nested:
            if before in ("", ";", "&"):
                here, unsure, first, alternative, moved = cwd, dynamic, True, False, False
            elif before == "||":
                alternative = True
        starts = first and not nested
        if not nested:
            first = False
        if structured and not nested and not _DIRECTORY_MOVERS.isdisjoint(words):
            unsure = dynamic = moved = True
        start = 0
        while not nested and start < len(words) and words[start] in _KEYWORDS:
            start += 1
        bare = words[start:] if start else words
        if not nested and moves_directory(bare):
            plain = (bare is words and len(words) == 2 and words[0] == "cd" and words[1] != "-"
                     and not any(c in words[1] for c in "$`~"))
            if plain and not structured and not alternative and after != "|" and before != "|":
                if not unsure or Path(words[1]).is_absolute():
                    moved_to = change(here, words[1])
                    here, unsure = (here, True) if moved_to is None else (moved_to, False)
            else:
                unsure = True
            if starts:
                cwd, dynamic = here, unsure
            else:
                dynamic = True
            moved = True
            continue
        words, _peeled = peel_commit_prefixes(words)
        if not words:
            continue
        if Path(words[0]).name != "git":
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
        # After ||, a git runs only when something before it failed, perhaps the cd.
        target, unknown = here, unsure or (alternative and moved)
        index, steps, alternate = git_global_options(words)
        require(alternate is not None or index is not None, "incomplete git global option")
        for kind, value in steps:
            # A variable or command substitution may expand to global options, so the target
            # cannot be known.
            if kind == "dynamic" or any(c in value for c in "$`~"):
                unknown = True
                continue
            moved_to = change(target, value)
            if moved_to is None:
                unknown = True
            else:
                target = moved_to
                unknown = unknown and not Path(value).is_absolute()
        if alternate is not None:
            for name in _HEAD_MOVERS:
                if name in words[alternate:]:
                    yield name, None, words[words.index(name, alternate) + 1:], \
                        "use git -C <worktree> " + name + " without alternate git-dir/work-tree options"
            continue
        if index >= len(words) or words[index] not in _HEAD_MOVERS:
            continue
        name = words[index]
        if nested:
            yield name, None, words[index + 1:], "run " + name + " as a direct command in its own Bash call"
            continue
        if unknown:
            yield name, None, words[index + 1:], \
                name + " target is dynamic; run it separately from its resolved worktree"
            continue
        # A target that does not resolve to a repository (missing, unenterable or not
        # a repository) cannot be matched to a worktree; a failed cd may even leave
        # bash in the reviewed one.
        if target not in toplevels:
            resolved = subprocess.run(["git", "-C", str(target), "rev-parse", "--show-toplevel"],
                                      capture_output=True, text=True)
            toplevels[target] = Path(resolved.stdout.strip()).resolve() if resolved.returncode == 0 else None
        if toplevels[target] is None:
            yield name, None, words[index + 1:], \
                name + " target cannot be resolved to a repository: " + str(target) + "; run it from an existing worktree"
            continue
        yield name, toplevels[target], words[index + 1:], None


def head_move(name, args):
    """How a git commit / merge moves HEAD: "commit" (checked evidence), "merge" (refused),
    "unreadable" (refused: an abbreviated merge option) or None."""
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
        yield actual, classify_commit_args(args)[1]


_MERGE_VALUE = {"-m", "-F", "-s", "-X", "--message", "--file", "--strategy", "--strategy-option", "--into-name"}
_MERGE_SWITCHES = {"--commit", "--no-commit", "--squash", "--no-squash", "--ff", "--no-ff", "--ff-only",
                   "--continue", "--abort", "--quit"}
_MERGE_LONG = _MERGE_SWITCHES | {option for option in _MERGE_VALUE if option.startswith("--")}


def abbreviated_merge_option(name):
    """True for a unique-prefix spelling of a long merge option, which git accepts."""
    return name not in _MERGE_LONG and any(option.startswith(name) for option in _MERGE_LONG)


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
            if abbreviated_merge_option(name):
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
            # S takes only the rest of this word (-S, -SKEYID), never the next word.
            for position, letter in enumerate(word[1:], 1):
                if letter == "S":
                    break
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
                "abbreviated git merge option " + ", ".join(
                    word.split("=", 1)[0] for word in arguments
                    if word.startswith("--") and abbreviated_merge_option(word.split("=", 1)[0]))
                + " cannot be read during review; spell every long merge option in full")
        require(kind != "merge",
                "a merge that commits by itself cannot be verified during review; " + BASE_INTAKE_STEPS)
        frozen = state.get("review_cycle")
        require(isinstance(frozen, dict), "review run has no frozen cycle; start its review before committing")
        require(frozen.get("status") == "completed",
                "review is incomplete; collect reviewers and run review-finish before committing"
                + ("; this concludes a merge: " + BASE_INTAKE_WAITING if merge_head() else ""))
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
        require(all(planned(path(p), plan, paths) for p in changed if p),
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
        print(("index" if index_only else "other") + "\t" + str(actual))


# A word that starts a redirection once quotes are gone: an optional fd number or &, then < or >.
_REDIRECTION_WORD = re.compile(r"(?:[0-9]*|&)[<>]")


def git_subcommand_main():
    """For each stdin line (the words after one git, separated by \\x1f, quotes already
    removed), print its subcommand and the word after it, separated by a tab, in input
    order; both fields are empty when no subcommand follows."""
    for line in sys.stdin.read().splitlines():
        words = ["git"] + [_Redirection(word) if _REDIRECTION_WORD.match(word) else word
                           for word in line.split("\x1f") if word]
        index, _steps, _alternate = git_global_options(words)
        if index is None or index >= len(words):
            print("\t")
        else:
            print(words[index] + "\t" + (words[index + 1] if index + 1 < len(words) else ""))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "commit-target":
        commit_target_main(sys.argv[2:])
        return
    if len(sys.argv) > 1 and sys.argv[1] == "git-subcommand":
        git_subcommand_main()
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
