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
import shlex
import stat
import subprocess
import sys

cycle = importlib.import_module("review-cycle")
require, read, atomic_write = cycle.require, cycle.read, cycle.atomic_write


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


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
    covered, paths, causes = [], [], []
    require(isinstance(plan["groups"], list) and plan["groups"], "root-cause groups required")
    for group in plan["groups"]:
        require(text(group["root_cause"]) and text(group["rationale"]), "root cause and disposition rationale required")
        causes.append(group["root_cause"])
        require(group["action"] in ("fix", "reply", "accept", "nit-noted"), "invalid disposition")
        require(isinstance(group["finding_ids"], list) and group["finding_ids"], "group finding IDs required")
        covered.extend(group["finding_ids"])
        semantic = group["semantic"]
        require(semantic.get("approved") is True and text(semantic.get("acceptance_criteria"))
                and text(semantic.get("out_of_scope")), "semantic scope unresolved or violated; retain rationale and consider in-scope alternative")
        group_paths = [path(p) for p in group["paths"]]
        paths.extend(group_paths)
        require(isinstance(group["verification_ids"], list) and group["verification_ids"]
                and set(group["verification_ids"]) <= set(ids), "every disposition requires verification")
        require(group["action"] != "fix" or group_paths, "fix disposition requires paths")
    require(len(set(causes)) == len(causes), "combine duplicate root-cause groups")
    require(len(covered) == len(set(covered)) and set(covered) <= known and blocking <= set(covered), "all blocking findings need one disposition; unknown or duplicate finding IDs")
    for entry in paths:
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


def git_subcommand_index(words, git_index):
    """Advance past the same git global options the direct-commit path skips."""
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
            return index if "commit" in words[index:] else None
    return index if index < len(words) else None


def each_direct_commit(command, cwd):
    """Yield the toplevel of each direct git commit. This is not a shell interpreter."""
    lexer = shlex.shlex(command, posix=False, punctuation_chars=";&|()\n")
    lexer.whitespace = " \t\r"
    segments, segment = [], []
    for token in lexer:
        if token and all(ch in ";&|()\n" for ch in token):
            if segment:
                segments.append(segment)
                segment = []
        else:
            # Keep quote information until separators have been classified:
            # echo ';' git commit is one harmless command, not two commands.
            # shlex's non-POSIX mode may split a quote beginning inside -mTEXT;
            # join only that unfinished quoted word, then dequote with shlex.
            while True:
                try:
                    values = shlex.split(token)
                    break
                except ValueError:
                    tail = lexer.get_token()
                    require(tail, "unfinished quoted commit command")
                    token += " " + tail
            require(len(values) == 1, "ambiguous shell word; run commit separately")
            segment.append(values[0])
    if segment:
        segments.append(segment)
    cwd = Path(cwd).resolve()
    for words in segments:
        if words and words[0] == "cd" and len(words) == 2:
            require(not any(c in words[1] for c in "$`~"),
                    "commit target is dynamic; run commit separately from its resolved worktree")
            cwd = (cwd / words[1]).resolve()
            continue
        words, peeled = peel_commit_prefixes(words)
        if not words:
            continue
        if Path(words[0]).name != "git":
            if Path(words[0]).name in {"echo", "printf"}:
                continue
            names = [Path(word).name for word in words]
            if "git" in names:
                sub = git_subcommand_index(words, names.index("git"))
                if sub is not None and "commit" in words[sub:]:
                    require(False, "run commit as a direct command in its own Bash call")
            continue
        target, index = cwd, 1
        while index < len(words) and words[index].startswith("-"):
            option = words[index]
            if option in ("-C", "-c"):
                require(index + 1 < len(words), "incomplete git global option")
                value = words[index + 1]
                if option == "-C":
                    require(not any(c in value for c in "$`~"), "commit target must be a literal worktree")
                    target = (target / value).resolve()
                index += 2
            elif option.startswith("-C"):
                target = (target / option[2:]).resolve()
                index += 1
            elif option.startswith("-c") or option in ("--no-pager", "--no-optional-locks"):
                index += 1
            else:
                require("commit" not in words[index:],
                        "use git -C <worktree> commit without alternate git-dir/work-tree options")
                break
        if index >= len(words) or words[index] != "commit":
            continue
        # Option values (notably -m '--dry-run') must not exempt a real commit.
        # -a / --all / a pathspec commit the worktree, not the index the gate hashed.
        dry_run, skip, index_only, dashed = False, False, True, False
        for option in words[index + 1:]:
            if dashed:
                index_only = False
                break
            if skip:
                skip = False
                continue
            if option == "--":
                dashed = True
                continue
            if option in ("-a", "--all"):
                index_only = False
            elif option in ("--dry-run", "--help", "-h"):
                dry_run = True
            elif re.fullmatch(r"-[A-Za-z]*[mFCct]", option) or option in ("-m", "--message", "-F", "--file", "-C", "--reuse-message", "-c", "--reedit-message", "--author", "--date", "--fixup", "--squash", "--cleanup", "-t", "--template", "--trailer"):
                if re.fullmatch(r"-[A-Za-z]*a[A-Za-z]*", option):
                    index_only = False
                skip = True
            elif option.startswith("-"):
                pass
            else:
                index_only = False
        if dry_run:
            continue
        os.chdir(target)
        try:
            actual = Path(subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"], text=True, stderr=subprocess.DEVNULL
            ).strip()).resolve()
        except subprocess.CalledProcessError:
            # Not a repository, so it is not the session worktree. commit-target
            # still refuses this; a review check must not turn it into a deny.
            yield None, True
            continue
        yield actual, index_only


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
    for actual, _index_only in each_direct_commit(args.command, args.cwd):
        if actual is None:
            continue
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
        frozen = state.get("review_cycle")
        require(isinstance(frozen, dict), "review run has no frozen cycle; start its review before committing")
        require(frozen.get("status") == "completed",
                "review is incomplete; collect reviewers and run review-finish before committing")
        directory = Path(args.state_root) / ".rite/state"
        approved_path = directory / ("fix-plan-" + args.session + ".json")
        require(approved_path.is_file(),
                "fix plan record missing; run check --plan <plan> --issue <issue> before committing")
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
