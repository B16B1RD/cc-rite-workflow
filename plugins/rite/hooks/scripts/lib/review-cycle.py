#!/usr/bin/env python3
"""Review-cycle transaction used only through flow-state.sh.

The state owns identity/selection; existing completion and save helpers own their
validation. A saved result is the receipt, including on replay after interruption.
"""
import argparse
import datetime
import importlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid


class InvalidReview(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidReview(message)


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique_keys)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def head():
    return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()


def roster(value):
    require(isinstance(value, list) and bool(value)
            and all(isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9-]*-reviewer", name) for name in value)
            and len(value) == len(set(value)), "selection must contain unique reviewer names")
    return sorted(value)


def atomic_write(path, state):
    # Same-directory replacement keeps the last complete state on write failure.
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            name = stream.name
            json.dump(state, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(name, path)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)


def same_json(left, right):
    return json.dumps(left, sort_keys=True) == json.dumps(right, sort_keys=True)


DECISION_LOG_HEADING = re.compile(r"^## 9\. Decision Log\s*$")
DECISION_LOG_END = re.compile(r"^(## |---\s*$|</details>)")
DECISION_LOG_ROW = re.compile(r"^- \d{4}-\d{2}-\d{2} D-\d{2,}: .+ / Reason: .+ / Impact: .+$")
# Same line shape the non-blocking record helper accepts as its own marker.
NBR_MARKER_LINE = re.compile(r"^\s*<!-- rite:nbr:comment-id:.*-->\s*$")
FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}(?=[^`]*$)|~{3,})")


def normalize_issue_body(body):
    # Specification identity ignores what rite itself appends to the Issue body
    # during a run: Decision Log rows in the triage format (inside section 9 only,
    # whatever wrote them) and the non-blocking record's comment-id marker line.
    # Everything else, including blank lines inside the specification sections
    # and anything inside a code fence, is compared verbatim; only the gaps left
    # by a removed line and trailing line breaks are closed. A body whose section
    # boundary cannot be decided (the heading occurs more than once outside code
    # fences) is compared
    # verbatim, loudly, instead of guessing which section is the log.
    require(isinstance(body, str), "Issue body must be a string")
    lines = body.split("\n")
    fenced = []
    fence = None
    for line in lines:
        if fence is None:
            opened = FENCE_OPEN.match(line)
            if opened:
                fence = opened.group(1)
            fenced.append(fence is not None)
        else:
            fenced.append(True)
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", line):
                fence = None
    headings = sum(1 for line, inside in zip(lines, fenced) if not inside and DECISION_LOG_HEADING.match(line))
    if headings > 1:
        print("WARNING: review-cycle: Decision Log heading appears " + str(headings)
              + " times; boundary undecidable, comparing the Issue body verbatim", file=sys.stderr)
        return body.rstrip("\r\n")
    keep, removed_at = [], set()
    section, start = False, None
    for line, inside in zip(lines, fenced):
        if inside:
            keep.append(line)
            continue
        if section and DECISION_LOG_END.match(line):
            section = False
            if all(not keep[i].strip() for i in range(start + 1, len(keep))):
                del keep[start:]
                removed_at = {i for i in removed_at if i < start} | {start}
        if DECISION_LOG_HEADING.match(line):
            section, start = True, len(keep)
        elif (section and DECISION_LOG_ROW.match(line)) or NBR_MARKER_LINE.match(line):
            removed_at.add(len(keep))
            continue
        keep.append(line)
    if section and all(not keep[i].strip() for i in range(start + 1, len(keep))):
        del keep[start:]
        removed_at = {i for i in removed_at if i < start} | {start}
    for index in sorted(removed_at, reverse=True):
        while 0 < index < len(keep) and not keep[index - 1].strip() and not keep[index].strip():
            del keep[index]
    return "\n".join(keep).rstrip("\r\n")


def same_specification(left, right):
    return normalize_issue_body(left) == normalize_issue_body(right)


def without_timestamp(result):
    return {key: value for key, value in result.items() if key != "timestamp"}


def matching_receipt(directory, cycle, content=None):
    context = cycle["review_context"]
    for path in sorted(directory.glob(str(context["pr_number"]) + "-*.json")):
        try:
            saved = read(path)
        except (OSError, ValueError):
            # An unrelated session's damaged history is not this cycle's receipt.
            # A recorded current receipt must remain readable; collecting cycles
            # with no matching receipt still have to pass the real saver below.
            require(str(path) != cycle.get("result_path"), "saved review receipt is unreadable")
            continue
        if not isinstance(saved, dict) or not same_json(saved.get("review_context"), context):
            continue
        require(roster(saved.get("reviewers")) == roster(cycle["selected_reviewers"]),
                "saved reviewer roster differs from frozen selection")
        require(saved.get("commit_sha") == context["commit_sha"]
                and isinstance(saved.get("measured_gate"), dict)
                and saved["measured_gate"].get("commit_sha") == context["commit_sha"]
                and saved.get("verdict") in ("mergeable", "fix-needed"), "saved receipt is invalid")
        require(isinstance(saved.get("timestamp"), str)
                and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", saved["timestamp"]),
                "saved receipt has no injected timestamp")
        if content is not None:
            require(same_json(without_timestamp(saved), without_timestamp(content)),
                    "saved content differs for the same review context; retain both inputs and recover")
        return path, saved
    return None


def guard_set(path, new, directory):
    if not path.exists():
        return new
    try:
        old = read(path)
    except (OSError, ValueError) as error:
        # Corruption cannot establish that a run has no retained review history.
        raise InvalidReview("existing state is unreadable; preserve it and recover before set") from error
    # Carry the abandonment history before the stagnation guard can return: its
    # switching branch returns early, and a record dropped there would take the
    # only statement of why a cycle was abandoned with it.
    history = old.get("review_cycle_abandoned")
    if history:
        new["review_cycle_abandoned"] = history
    if importlib.import_module("review-stagnation").guard_set(old, new):
        return new
    require(new.get("phase") != "review" or old.get("phase") == "review",
            "enter review through review-start; ordinary set cannot begin another review")
    cycle = old.get("review_cycle")
    old_count, new_count = old.get("cycle_count", 0), new.get("cycle_count", 0)
    # A PR switch is legitimate after cleanup; it cannot abandon a pending review.
    pending = old.get("phase") == "review" and (not cycle or cycle.get("status") != "completed")
    pending = pending or bool(cycle and cycle.get("status") != "completed")
    if pending:
        require(new.get("phase") == old.get("phase")
                and new_count == old_count and new.get("pr_number") == old.get("pr_number"),
                "unverified review transition; run review-start/review-finish before advancing")
    needs_receipt = new.get("phase") in ("fix", "ready") and (new.get("phase") != old.get("phase") or new.get("pr_number") != old.get("pr_number")) and old.get("pr_number", 0) > 0
    if old.get("phase") in ("review", "fix") or new.get("phase") == "review" or cycle or needs_receipt:
        require(new_count == old_count or (new_count == 0 and not pending),
                "cycle_count advances only through review-start")
        if not pending and needs_receipt:
            require(cycle and cycle.get("status") == "completed", "verified review receipt required")
            require(new.get("pr_number") == cycle["review_context"]["pr_number"], "receipt belongs to a different PR")
            receipt = matching_receipt(directory, cycle)
            require(receipt is not None, "saved review receipt is missing")
            # A mergeable result may still enter fix for the established NB sweep.
            # ready's existing HEAD/AC gate owns its reviewed-HEAD exception.
    if cycle:
        new["review_cycle"] = cycle
    return new


def start(state, args, directory):
    selected = read(args.selection)
    roster(selected)
    cycle = state.get("review_cycle")
    current_head = head()
    stagnation = importlib.import_module("review-stagnation")
    resumed_run = None
    if "review_run" in state:
        if cycle:
            run, _ = stagnation.current(state, args.session, check_head=False)
        else:
            # An abandoned cycle leaves the run with no frozen counterpart. The
            # abandonment record is what makes that shape legitimate, so validate
            # against it rather than trusting the run alone.
            resumed_run = stagnation.retained_run(state, args.session)
            run = resumed_run
        require(run["status"] != "stopped", "review run stopped: " + str(run.get("stop_reason")))
    count = state.get("cycle_count", 0)
    require(type(count) is int and count >= 0, "cycle_count must be a nonnegative integer")
    require(type(state.get("pr_number")) is int and state["pr_number"] > 0, "positive pr_number required")
    if cycle and cycle.get("status") == "collecting":
        context = cycle["review_context"]
        require(context["session_id"] == args.session and context["pr_number"] == state["pr_number"]
                and context["cycle_count"] == count, "frozen review context differs from state")
        require(current_head == context["commit_sha"], "HEAD changed during incomplete review; retain evidence and recover")
        require(roster(selected) == roster(cycle["selected_reviewers"]), "cannot change incomplete review selection")
        if args.stagnation and "review_run" not in state:
            stagnation.initialize(state)
        return state
    require(state.get("phase") in ("pr", "review", "fix", "ready", "ready_error"),
            "review-start requires a PR review phase")
    if cycle and count > 0:
        require(cycle["review_context"]["pr_number"] == state["pr_number"], "new PR requires a fresh run (cycle_count 0)")
        require(cycle.get("status") == "completed" and matching_receipt(directory, cycle) is not None,
                "previous review has no verified saved receipt")
        if "review_run" in state:
            stagnation.advance(state, args.session, current_head)
    if resumed_run is not None:
        # Retrying an abandoned cycle is the same run at the same counter on a new
        # HEAD. A fresh run_id would strand review_run; a bumped counter would put
        # a hole in the observation history the stagnation gates read as a series.
        run_id = resumed_run["run_id"]
    else:
        # Legacy callers already incremented before entering review. Adopt that count
        # once; new runs and completed cycles increment here exclusively.
        count = count if not cycle and state.get("phase") == "review" and count > 0 else count + 1
        run_id = cycle["review_context"]["run_id"] if cycle and state.get("cycle_count", 0) > 0 else str(uuid.uuid4())
    context = dict(session_id=args.session, run_id=run_id, pr_number=state["pr_number"],
                   cycle_count=count, commit_sha=current_head)
    state.update(phase="review", cycle_count=count, active=True, updated_at=now(),
                 next_action="/rite:pr-review " + str(state["pr_number"]),
                 review_cycle=dict(review_context=context, selected_reviewers=selected, status="collecting"))
    if args.stagnation and "review_run" not in state:
        stagnation.initialize(state)
    elif "review_run" in state:
        state["review_run"]["current_decision"] = dict(action="observe", reasons=[])
    state.pop("stop_reason", None)
    state.pop("handoff", None)
    return state


def finish(state, args, path, directory):
    cycle = state.get("review_cycle")
    require(isinstance(cycle, dict), "review-start must freeze the selection before review-finish")
    context = cycle["review_context"]
    require(context["session_id"] == args.session and context["pr_number"] == state["pr_number"]
            and context["cycle_count"] == state.get("cycle_count"), "frozen review context differs from state")
    require(head() == context["commit_sha"], "HEAD differs from reviewed commit")
    manifest, content = read(args.manifest), read(args.content_file)
    require(isinstance(manifest, dict) and isinstance(content, dict), "manifest and result must be JSON objects")
    require(same_json(manifest.get("review_context"), context) and same_json(content.get("review_context"), context),
            "manifest/result review_context does not match the frozen review")
    require(roster(manifest.get("selected_reviewers")) == roster(cycle["selected_reviewers"])
            and roster(content.get("reviewers")) == roster(cycle["selected_reviewers"]),
            "manifest/result roster does not match frozen selection")
    records = manifest.get("reviewers")
    require(isinstance(records, list), "reviewers must be completion records")
    missing = set(cycle["selected_reviewers"]) - {record.get("reviewer") for record in records if isinstance(record, dict)}
    require(not missing, "incomplete reviewers: " + ", ".join(sorted(missing)))
    for record in records:
        require(isinstance(record, dict) and same_json(record.get("review_context"), context),
                "reviewer context mismatch: " + str(record.get("reviewer") if isinstance(record, dict) else record))
    require(content.get("pr_number") == context["pr_number"] and content.get("commit_sha") == context["commit_sha"],
            "result PR/HEAD mismatch")
    gate = content.get("measured_gate")
    require(isinstance(gate, dict) and type(gate.get("blocking")) is int
            and gate["blocking"] >= 0 and gate.get("anchor_undetermined") == 0,
            "measured gate must have resolved all anchors")
    # Class demotion can change the final verdict after the measured receipt.
    findings = content.get("findings")
    require(isinstance(findings, list), "findings must be an array")
    blocking = any(finding.get("scope") in ("current-pr", "follow-up") for finding in findings)
    require(content.get("verdict") == ("fix-needed" if blocking else "mergeable"),
            "verdict disagrees with final findings")
    hooks = Path(__file__).resolve().parents[2]
    subprocess.run(["bash", str(hooks / "scripts/reviewer-completion-check.sh"), "--input", args.manifest],
                   check=True, stdout=sys.stderr)
    pending_id = args.pending_id or cycle.get("pending_id")
    require(not pending_id or re.fullmatch(r"[A-Za-z0-9._-]+", pending_id), "invalid pending-id")
    receipt = matching_receipt(directory, cycle, content)
    replay = receipt is not None
    if receipt is None:
        # Keep the evidence locations before invoking the nonblocking saver. A
        # crash after save can rediscover its receipt without another save.
        cycle.update(manifest_path=args.manifest, content_file=args.content_file)
        if pending_id:
            cycle["pending_id"] = pending_id
        state["updated_at"] = now()
        atomic_write(path, state)
        command = ["bash", str(hooks / "review-result-save.sh"), "--pr", str(context["pr_number"]),
                   "--content-file", args.content_file, "--results-dir", str(directory)]
        if pending_id:
            command += ["--pending-id", pending_id]
        subprocess.run(command, check=True, stdout=sys.stderr)
        receipt = matching_receipt(directory, cycle, content)
        require(receipt is not None, "result persistence failed; evidence retained; retry review-finish with the recorded paths")
    if replay:
        # The saver already ran before interruption; reproduce its observable
        # success without another file or another cycle. Pending markers identify
        # the same invocation and use the saver's token/path contract.
        marker = ""
        if pending_id:
            marker = Path(os.environ.get("TMPDIR") or "/tmp") / ("rite-p61a-pending-" + pending_id)
            marker.unlink(missing_ok=True)
        print("[CONTEXT] REVIEW_SAVE_DONE=1; pr=" + str(context["pr_number"])
              + "; marker=" + str(marker) + "; saved=true", file=sys.stderr)
        print("[CONTEXT] FILE_TIMESTAMP=" + receipt[0].stem.split("-", 1)[1].split("~", 1)[0], file=sys.stderr)
        print("[CONTEXT] ISO_TIMESTAMP=" + receipt[1]["timestamp"], file=sys.stderr)
        print("[CONTEXT] JSON_SAVED=true", file=sys.stderr)
    cycle.update(status="completed", manifest_path=args.manifest, content_file=args.content_file,
                 result_path=str(receipt[0]), verdict=receipt[1]["verdict"])
    target = "fix" if cycle["verdict"] == "fix-needed" else "ready"
    state.update(next_action="/rite:" + target + " " + str(context["pr_number"]), updated_at=now())
    return state


def abandon(state, args, directory):
    cycle = state.get("review_cycle")
    if not cycle:
        print("[CONTEXT] REVIEW_ABANDON=noop; reason=no_incomplete_cycle", file=sys.stderr)
        return state
    require(cycle.get("status") == "collecting",
            "only a collecting cycle can be abandoned; status is " + str(cycle.get("status")))
    for key in ("review_context", "selected_reviewers"):
        require(key in cycle, "collecting cycle is missing " + key + "; preserve the state and recover")
    for key in ("manifest_path", "content_file", "result_path"):
        require(not cycle.get(key), "cycle retains evidence at " + key + "=" + str(cycle.get(key))
                + "; recover it instead of abandoning")
    receipt = matching_receipt(directory, cycle)
    require(receipt is None, "a saved receipt matches this cycle at "
            + (str(receipt[0]) if receipt else "") + "; recover it instead of abandoning")
    record = dict(review_context=cycle["review_context"], selected_reviewers=cycle["selected_reviewers"],
                  reason=args.reason, abandoned_at=now(), head_at_abandon=head())
    # Identity (session/issue/pr/branch/worktree) and cycle_count stay untouched:
    # abandoning an empty record is not a counter or ownership change.
    state.setdefault("review_cycle_abandoned", []).append(record)
    state.pop("review_cycle", None)
    # Abandoning ends the review itself, so the phase must stop claiming one:
    # guard_set treats phase=review without a completed cycle as still pending,
    # which would keep blocking the very transitions this operation unblocks.
    state.update(phase="pr", updated_at=now(),
                 next_action="review-start で現 HEAD から新しい cycle を開始する")
    return state


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("start", "finish", "guard-set", "clock", "observe", "replan", "retry", "close", "defer", "abandon"))
    parser.add_argument("--state", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--results-dir", required=True)
    parser.add_argument("--selection")
    parser.add_argument("--manifest")
    parser.add_argument("--content-file")
    parser.add_argument("--pending-id")
    parser.add_argument("--stagnation", action="store_true")
    parser.add_argument("--input")
    parser.add_argument("--issue")
    parser.add_argument("--plan")
    parser.add_argument("--reason")
    parser.add_argument("--amend", action="store_true")
    args = parser.parse_args()
    path, directory = Path(args.state), Path(args.results_dir)
    if args.operation == "guard-set":
        print(json.dumps(guard_set(path, json.load(sys.stdin), directory)))
        return
    required = dict(start=["selection"], finish=["manifest", "content_file"],
                    clock=["input"], observe=["input", "issue"], replan=["plan", "issue"],
                    retry=["plan", "issue"], close=[], defer=[], abandon=[])
    for name in required[args.operation]:
        value = getattr(args, name)
        require(value and Path(value).is_absolute(), name + " must be an absolute file path")
    if args.operation == "abandon":
        require(args.reason and args.reason.strip(), "--reason must record why the cycle is abandoned")
    state = read(path)
    require(state.get("session_id") == args.session, "state session_id differs from current session")
    if args.operation == "start":
        updated = start(state, args, directory)
    elif args.operation == "finish":
        updated = finish(state, args, path, directory)
    elif args.operation == "abandon":
        updated = abandon(state, args, directory)
    else:
        stagnation = importlib.import_module("review-stagnation")
        updated = stagnation.clock(state, args) if args.operation == "clock" else getattr(stagnation, args.operation)(state, args, directory)
    print(json.dumps(updated, ensure_ascii=False))


if __name__ == "__main__":
    # review-stagnation imports this file by name. Claiming that name for the
    # module already running keeps importlib from loading a second copy, so the
    # refusal it raises is this very InvalidReview rather than a twin the handler
    # below would miss.
    sys.modules.setdefault("review-cycle", sys.modules["__main__"])
    try:
        main()
    except InvalidReview as error:
        # `ERROR: review-cycle:` means "this helper judged the input and refused".
        # Callers branch on it to tell a refusal from an environment failure, so
        # nothing but a require() violation may carry it.
        print("ERROR: review-cycle: " + json.dumps(str(error), ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("ERROR: review-cycle failed: " + json.dumps(str(error), ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
