#!/usr/bin/env python3
"""Persist promotion candidates in raw and reconcile work through the existing log."""
import argparse
import hashlib
import io
import os
import shutil
import shlex
import textwrap
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from datetime import date
from pathlib import Path

SECTION = re.compile(r"\n## Promotion candidates\n\n```json\n(.*?)\n```\n?", re.S)
EVENT = re.compile(r"<!-- rite-promotion: (.*?) -->")
SELF = "plugins/rite/hooks/scripts/wiki-promotion-candidates.py"


def atomic_write(path, text):
    pending = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".rite-promotion-", suffix=".tmp", delete=False) as stream:
            pending = Path(stream.name)
            stream.write(text)
        if pending.read_text(encoding="utf-8") != text:
            raise ValueError(f"save verification failed: {path}")
        os.replace(pending, path)
    except OSError as error:
        raise OSError(error.errno, f"save failed: {path}: {error}") from error
    finally:
        if pending is not None:
            pending.unlink(missing_ok=True)


def observe_usage(directory, caller, consumer, test, originals):
    targets = [str((Path(directory) / name).resolve()) for name in (caller, consumer)]
    with tempfile.TemporaryDirectory(prefix="rite-promotion-observer-") as probe:
        probe = Path(probe)
        trace = probe / "trace"
        trace.touch()
        bash_env = probe / "bash-env"
        inline_codes = set()
        if caller.endswith(".md"):
            for block in re.findall(r"```(?:bash|sh)\n(.*?)\n[ \t]*```", originals[caller], re.S):
                for body in (block.strip(), textwrap.dedent(block).strip()):
                    for plugin_root in ("plugins/rite", str(Path(directory) / "plugins/rite")):
                        inline_codes.add(body.replace("{plugin_root}", plugin_root))
        inline_case = ""
        if inline_codes:
            patterns = []
            for code in sorted(inline_codes):
                parts = re.split(r"(?<!\$)(\{[a-z][a-z0-9_]*\})", code)
                patterns.append("^" + "".join("[[:alnum:]_./:@=+, %-]+" if re.fullmatch(
                    r"\{[a-z][a-z0-9_]*\}", part) else re.escape(part) for part in parts) + "$")
            inline_case = "\n_rite_promotion_pattern=" + shlex.quote("(" + "|".join(patterns) + ")") + "\n" + (
                "if [[ \"${BASH_EXECUTION_STRING:-}\" =~ $_rite_promotion_pattern ]]; then\n"
                "printf 'doc-exec\\t%s\\t%s\\t%s\\n' \"$BASHPID\" \"$PPID\" \"$RITE_PROMOTION_CALLER\" >> \"$RITE_PROMOTION_TRACE\"\n"
                "fi\n"
            )
        bash_env.write_text("""
_rite_promotion_trace() {
    for _rite_promotion_source in "${BASH_SOURCE[@]}"; do
        printf 'exec\\t%s\\t%s\\t%s\\n' "$BASHPID" "$PPID" "$_rite_promotion_source" >> "$RITE_PROMOTION_TRACE"
    done
""" + inline_case + """
}
trap '_rite_promotion_trace' DEBUG
""")
        observer = """
import os, sys, json
_targets = set(json.loads(os.environ["RITE_PROMOTION_TARGETS"]))
def _note(event, args):
    if event == "cpython.run_file" or event == "open":
        filename = args[0]
        if isinstance(filename, str):
            filename = os.path.realpath(filename)
            if filename in _targets:
                with open(os.environ["RITE_PROMOTION_TRACE"], "a") as stream:
                    stream.write(("exec" if event == "cpython.run_file" else "read") + "\\t" + str(os.getpid()) + "\\t" + str(os.getppid()) + "\\t" + filename + "\\n")
sys.addaudithook(_note)
"""
        (probe / "sitecustomize.py").write_text(observer)
        readers = {name: shutil.which(name) for name in ("cat", "sed")}
        readers = {name: path for name, path in readers.items() if path}
        tool_dir = probe / "bin"
        tool_dir.mkdir()
        for name, executable in readers.items():
            wrapper = tool_dir / name
            wrapper.write_text("#!" + sys.executable + "\n" + """
import json, os, subprocess, sys
result = subprocess.run([EXECUTABLE, *sys.argv[1:]])
if result.returncode == 0:
    targets = set(json.loads(os.environ["RITE_PROMOTION_TARGETS"]))
    arguments = sys.argv[1:]
    files = []
    if NAME == "cat":
        if arguments[:1] == ["--"]:
            arguments = arguments[1:]
        if all(not argument.startswith("-") for argument in arguments):
            files = arguments
    else:
        while arguments and arguments[0] in ("-n", "-E", "-r"):
            arguments = arguments[1:]
        if len(arguments) == 2 and not arguments[0].startswith("-") and not arguments[1].startswith("-"):
            files = arguments[1:]
    for argument in files:
        filename = os.path.realpath(argument)
        if filename in targets:
            with open(os.environ["RITE_PROMOTION_TRACE"], "a") as stream:
                stream.write("read\\t" + str(os.getpid()) + "\\t" + str(os.getppid()) + "\\t" + filename + "\\n")
sys.exit(result.returncode)
""".replace("EXECUTABLE", repr(executable)).replace("NAME", repr(name)))
            wrapper.chmod(0o700)
        environment = dict(os.environ, BASH_ENV=str(bash_env), RITE_PROMOTION_TRACE=str(trace),
                           RITE_PROMOTION_TARGETS=json.dumps(targets), RITE_PROMOTION_CALLER=targets[0])
        environment["PYTHONPATH"] = str(probe) + os.pathsep + environment.get("PYTHONPATH", "")
        environment["PATH"] = str(tool_dir) + os.pathsep + environment.get("PATH", "")
        result = subprocess.run(["bash", test], cwd=directory, env=environment, text=True,
                                capture_output=True)
        if result.returncode:
            raise ValueError(f"verification failed: {test}: {result.stderr.strip() or result.stdout.strip()}")
        events = []
        parents = {}
        for line in trace.read_text().splitlines():
            kind, pid, parent, filename = line.split("\t", 3)
            filename = str((Path(directory) / filename).resolve())
            events.append((kind, pid, parent, filename))
            parents[pid] = parent
        caller_kind = "doc-exec" if caller.endswith(".md") else "exec"
        consumer_kind = "read" if consumer.endswith(".md") else "exec"
        callers = [e for e in events if e[0] == caller_kind and e[3] == targets[0]]
        consumers = [e for e in events if e[0] == consumer_kind and e[3] == targets[1]]
        if not callers:
            raise ValueError("runtime caller use not observed")
        if not consumers:
            raise ValueError("runtime consumer use not observed")
        if caller.endswith(".md") and not any(e[0] == "read" and e[3] == targets[0] for e in events):
            raise ValueError("caller instructions were not read")
        owner_pids = {e[1] for e in callers}
        reached = False
        for event in consumers:
            pid = event[1]
            seen = set()
            while pid not in seen:
                if pid in owner_pids:
                    reached = True
                    break
                seen.add(pid)
                if pid not in parents:
                    break
                pid = parents[pid]
        if not reached:
            raise ValueError("consumer was not used through the caller")
        for name, body in originals.items():
            if (Path(directory) / name).read_text() != body:
                raise ValueError(f"verification changed merged source: {name}")


def command(args, cwd=None):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f"{' '.join(args[:4])}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def local_path(root, relative):
    path = root / relative
    if Path(relative).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"path outside Wiki: {relative}")
    return path


def read_raw(root, raw):
    if not raw.startswith("raw/") or not raw.endswith(".md"):
        raise ValueError(f"expected raw Markdown path: {raw}")
    text = local_path(root, raw).read_text()
    if not text.startswith("---\n") or "\n---\n" not in text[4:]:
        raise ValueError(f"invalid raw frontmatter: {raw}")
    return text


def field(text, name):
    match = re.search(rf"^{name}: (.*)$", text.split("\n---\n", 1)[0], re.M)
    if not match:
        return ""
    value = match[1]
    if value.startswith('"'):
        return json.loads(value)
    return value


def set_field(text, name, value):
    front, body = text.split("\n---\n", 1)
    line = f"{name}: {value}"
    if re.search(rf"^{name}:.*$", front, re.M):
        front = re.sub(rf"^{name}:.*$", lambda _: line, front, flags=re.M)
    else:
        front += "\n" + line
    return front + "\n---\n" + body


def routing(text):
    matches = list(SECTION.finditer(text))
    if len(matches) > 1:
        raise ValueError("duplicate Promotion candidates sections")
    return json.loads(matches[0][1]) if matches else None


def candidate(raw, text, item):
    for name in ("summary", "condition", "consumer"):
        if not isinstance(item.get(name), str) or not item[name].strip():
            raise ValueError(f"{raw}: missing candidate {name}")
    lines = SECTION.sub("", text).split("\n---\n", 1)[1].strip("\n").splitlines()
    source = item.get("source", {})
    start, end = source.get("start_line"), source.get("end_line")
    if type(start) is not int or type(end) is not int or not 1 <= start <= end <= len(lines):
        raise ValueError(f"{raw}: invalid original source range")
    excerpt = "\n".join(lines[start - 1:end])
    identity = [raw, start, end, excerpt, item["condition"], item["consumer"]]
    key = hashlib.sha256(json.dumps(identity, ensure_ascii=False).encode()).hexdigest()
    if item.get("id", key) != key or item.get("excerpt", excerpt) != excerpt:
        raise ValueError(f"{raw}: candidate source changed")
    return dict(item, id=key, raw=raw, source=source, excerpt=excerpt)


def raw_candidates(root, raw):
    text = read_raw(root, raw)
    data = routing(text)
    result = [candidate(raw, text, item) for item in data["candidates"]] if data else []
    reason = data.get("legacy_reason", "") if data else field(text, "skip_reason")
    if reason.startswith(("detector-candidate:", "promotion-candidate:")):
        body = SECTION.sub("", text).split("\n---\n", 1)[1].strip("\n")
        # Legacy entries retain the original range; AI fills condition and consumer before linking.
        result.append(dict(id=hashlib.sha256((raw + reason).encode()).hexdigest(), raw=raw,
                     summary=reason.split(":", 1)[1].strip(), source={"start_line": 1,
                     "end_line": len(body.splitlines())}, excerpt=body,
                     condition="", consumer="", legacy=True))
    return result


def events(root):
    path = root / "log.md"
    if not path.exists():
        return []
    return [json.loads(match[1]) for match in EVENT.finditer(path.read_text())]


def log_event(root, item):
    path = root / "log.md"
    text = path.read_text() if path.exists() else "# Directory Update Log\n"
    encoded = json.dumps(item, ensure_ascii=False, sort_keys=True).replace("<", "\\u003c").replace(">", "\\u003e")
    marker = f"<!-- rite-promotion: {encoded} -->"
    prior = [event for event in events(root)
             if event["raw"] == item["raw"] and event["candidate"] == item["candidate"]]
    if prior and prior[0] == item:
        return
    day = f"## {date.today().isoformat()}\n"
    bullet = f"* **Promotion**: [候補の出典]({item['raw']}) — {item['status']} {marker}\n"
    if day in text:
        text = text.replace(day, day + bullet, 1)
    else:
        head, separator, rest = text.partition("\n")
        text = head + "\n\n" + day + bullet + rest
    atomic_write(path, text)
    if marker not in path.read_text():
        raise ValueError(f"log save verification failed: {path}")


def record(root, raw, input_path):
    text = read_raw(root, raw)
    data = json.loads(Path(input_path).read_text())
    data["candidates"] = [candidate(raw, text, item) for item in data["candidates"]]
    previous = routing(text)
    if previous:
        retained = {item["id"]: candidate(raw, text, item) for item in previous["candidates"]}
        retained.update({item["id"]: item for item in data["candidates"]})
        data["candidates"] = list(retained.values())
        if previous.get("legacy_reason"):
            data["legacy_reason"] = previous["legacy_reason"]
    elif field(text, "skip_reason").startswith("detector-candidate:"):
        data["legacy_reason"] = field(text, "skip_reason")
    pages = data.get("pages", [])
    if not isinstance(pages, list) or not all(isinstance(p, str) and p.startswith("pages/") for p in pages):
        raise ValueError("pages must be domain page paths")
    if not data["candidates"] and not pages and not data.get("skip_reason"):
        raise ValueError("empty routing requires a skip reason")
    data["pages"] = pages
    payload = "\n## Promotion candidates\n\n```json\n" + json.dumps(data, ensure_ascii=False, indent=2) + "\n```\n"
    text = SECTION.sub("", text).rstrip("\n") + "\n" + payload
    # A partial save remains extractable even if a later log/page write fails.
    text = set_field(text, "ingested", "false")
    if data["candidates"] or data.get("legacy_reason"):
        text = set_field(text, "ingest_status", "partial" if pages else "skipped")
        text = set_field(text, "skip_reason", json.dumps("promotion-candidate: " +
                         ("; ".join(x["summary"] for x in data["candidates"]) or data["legacy_reason"]), ensure_ascii=False))
    elif data.get("skip_reason"):
        text = set_field(text, "ingest_status", "skipped")
        text = set_field(text, "skip_reason", json.dumps(data["skip_reason"], ensure_ascii=False))
    atomic_write(local_path(root, raw), text)
    if routing(read_raw(root, raw)) != data:
        raise ValueError(f"candidate save verification failed: {raw}")
    for item in raw_candidates(root, raw):
        if not any(event["candidate"] == item["id"] and event["raw"] == raw for event in events(root)):
            log_event(root, {"candidate": item["id"], "raw": raw, "status": "unresolved",
                            "reason": "caller, verification and merge evidence required"})
    if not data["candidates"] and not pages:
        log_event(root, {"candidate": "", "raw": raw, "status": "skipped", "reason": data["skip_reason"]})
    print(json.dumps(data, ensure_ascii=False))


def finish(root, raw):
    text = read_raw(root, raw)
    data = routing(text)
    if data is None:
        raise ValueError(f"{raw}: routing has not been saved")
    history = events(root)
    for item in raw_candidates(root, raw):
        if not any(e["candidate"] == item["id"] and e["raw"] == raw for e in history):
            raise ValueError(f"{raw}: candidate log missing")
    for page in data["pages"]:
        body = local_path(root, page).read_text()
        resource = re.compile(r"^\s+resource:\s*[\"']?" + re.escape(raw) + r"[\"']?\s*$", re.M)
        if not resource.search(body.split("\n---\n", 1)[0] + "\n"):
            raise ValueError(f"{page}: raw source reference missing")
        log = (root / "log.md").read_text()
        if page not in (root / "index.md").read_text() or not any(page in line and raw in line for line in log.splitlines()):
            raise ValueError(f"{page}: index/log save missing")
    if not data["candidates"] and not data["pages"] and not any(e["raw"] == raw for e in history):
        raise ValueError(f"{raw}: skip log missing")
    updated = set_field(text, "ingested", "true")
    atomic_write(local_path(root, raw), updated)
    if read_raw(root, raw) != updated:
        raise ValueError(f"raw extraction save verification failed: {raw}")
    print(f"PROMOTION_SAVED={raw}")


def listed(root):
    history = events(root)
    result = []
    for path in sorted((root / "raw").rglob("*.md")):
        for item in raw_candidates(root, path.relative_to(root).as_posix()):
            matched = [e for e in history if e["candidate"] == item["id"] and e["raw"] == item["raw"]]
            # A previous complete event is evidence to recheck, never a reason to hide a candidate.
            result.append(dict(item, work=matched[0] if matched else {}, status="unresolved"))
    return result


def maintainer(cwd, repo):
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", repo):
        raise ValueError("owner/repo is required")
    command(["git", "ls-files", "--error-unmatch", SELF], cwd)
    source_root = Path(__file__).resolve().parents[4]
    source_git = command(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], source_root).strip()
    target_git = command(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd).strip()
    if source_git != target_git:
        raise ValueError("consumption requires the repository's tracked plugin source")
    origin = command(["git", "remote", "get-url", "origin"], cwd).strip().removesuffix(".git")
    if not origin.endswith("/" + repo) and not origin.endswith(":" + repo):
        # Use the existing remote parser for SSH host aliases.
        remote = command(["bash", str(cwd / "plugins/rite/hooks/scripts/lib/git-remote.sh"),
                          "resolve-owner-repo"], cwd).strip().replace("\t", "/")
        if remote != repo:
            raise ValueError("repository identity mismatch")


def link(root, input_path):
    works = json.loads(Path(input_path).read_text())
    candidates = {(x["raw"], x["id"]): x for x in listed(root)}
    for work in works:
        item = candidates[(work["raw"], work["candidate"])]
        for name in ("issue_url", "consumer", "condition"):
            if not work.get(name):
                raise ValueError(f"missing work {name}")
        if item.get("consumer") and work["consumer"] != item["consumer"]:
            raise ValueError("work consumer differs from candidate")
        if item.get("condition") and work["condition"] != item["condition"]:
            raise ValueError("work condition differs from candidate")
        log_event(root, dict(work, status="linked"))
    print("PROMOTION_LINKED=" + str(len(works)))


def proof(cwd, repo, item):
    work = item["work"]
    for key in ("pr_url", "issue_url", "consumer", "caller", "test", "revision"):
        if not work.get(key):
            raise ValueError(f"missing {key}")
    for key in ("pr_url", "issue_url"):
        kind = "pull" if key == "pr_url" else "issues"
        if not re.fullmatch(rf"https://github\.com/{re.escape(repo)}/{kind}/[0-9]+", work[key]):
            raise ValueError(f"{key} belongs to another repository")
    pr = json.loads(command(["gh", "pr", "view", work["pr_url"], "--repo", repo, "--json",
                             "state,isDraft,mergeCommit,closingIssuesReferences"]))
    if pr["state"] != "MERGED" or pr["isDraft"] or not pr.get("mergeCommit"):
        raise ValueError("merge not confirmed")
    revision = pr["mergeCommit"]["oid"]
    if work["revision"] != revision:
        raise ValueError("verification revision is not the merged revision")
    if work["issue_url"] not in [x.get("url") for x in pr["closingIssuesReferences"]]:
        raise ValueError("PR does not close the linked Issue")
    if item.get("consumer") and item["consumer"] != work["consumer"]:
        raise ValueError("candidate consumer mismatch")
    if item.get("condition") and item["condition"] != work.get("condition"):
        raise ValueError("candidate condition mismatch")
    try:
        command(["git", "cat-file", "-e", revision + "^{commit}"], cwd)
    except ValueError:
        command(["git", "fetch", "origin", revision], cwd)
    consumer, caller, test = (work[x] for x in ("consumer", "caller", "test"))
    for path in (consumer, caller, test):
        if Path(path).is_absolute() or ".." in Path(path).parts:
            raise ValueError("proof paths must be repository relative")
    consumer_body = command(["git", "show", revision + ":" + consumer], cwd)
    caller_body = command(["git", "show", revision + ":" + caller], cwd)
    test_body = command(["git", "show", revision + ":" + test], cwd)
    if not consumer_body.strip() or consumer == caller:
        raise ValueError("consumer is empty")
    if consumer.endswith(".md") and caller.endswith(".md"):
        relative = consumer.removeprefix("plugins/rite/")
        if not re.search(r"(?:Read|読み込む|読取)[^\n]*" + re.escape(relative), caller_body):
            raise ValueError("reference read instruction missing")
    if not test.endswith(".test.sh"):
        raise ValueError("expected a repository shell test")
    archive = subprocess.run(["git", "archive", revision], cwd=cwd, capture_output=True, check=True).stdout
    with tempfile.TemporaryDirectory(prefix="rite-promotion-check-") as directory:
        with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
            bundle.extractall(directory, filter="data")
        # Tests often resolve the repository with git. A detached snapshot fixes their revision.
        command(["git", "init", "-q"], directory)
        command(["git", "add", "."], directory)
        command(["git", "-c", "user.name=rite", "-c", "user.email=rite@localhost",
                 "commit", "-qm", "verification snapshot"], directory)
        observe_usage(directory, caller, consumer, test, {consumer: consumer_body, caller: caller_body, test: test_body})
    return revision


def reconcile(root, cwd, repo):
    maintainer(cwd, repo)
    result = []
    for item in listed(root):
        try:
            revision = proof(cwd, repo, item)
            status, reason = "complete", "caller invocation and verification passed at merged revision"
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            revision, status, reason = "", "unresolved", str(error)
        event = dict(item["work"], candidate=item["id"], raw=item["raw"], status=status,
                     reason=reason)
        if revision:
            event["revision"] = revision
        log_event(root, event)
        result.append(dict(item, status=status, reason=reason, work=event))
    print(json.dumps(result, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["record", "finish", "list", "link", "reconcile"])
    parser.add_argument("--wiki-root", required=True, type=Path)
    parser.add_argument("--raw")
    parser.add_argument("--input")
    parser.add_argument("--cwd", type=Path)
    parser.add_argument("--repo")
    args = parser.parse_args()
    root = args.wiki_root.resolve()
    if not root.is_dir():
        raise ValueError(f"Wiki root missing: {root}")
    if args.action in ("record", "finish") and not args.raw:
        raise ValueError("--raw is required")
    if args.action in ("record", "link") and not args.input:
        raise ValueError("--input is required")
    if args.action == "record":
        record(root, args.raw, args.input)
    elif args.action == "finish":
        finish(root, args.raw)
    elif args.action == "list":
        print(json.dumps(listed(root), ensure_ascii=False, indent=2))
    elif args.action == "link":
        if not args.cwd or not args.repo:
            raise ValueError("--cwd and --repo are required for consumption")
        maintainer(args.cwd.resolve(), args.repo)
        link(root, args.input)
    else:
        if not args.cwd or not args.repo:
            raise ValueError("--cwd and --repo are required for consumption")
        reconcile(root, args.cwd.resolve(), args.repo)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"ERROR: wiki promotion: {error}", file=sys.stderr)
        sys.exit(1)
