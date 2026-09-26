"""Persist review diagnostics in the same transaction as the owning review run."""
import copy
import datetime
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import uuid

cycle = importlib.import_module("review-cycle")
require, read = cycle.require, cycle.read


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def text(value):
    return isinstance(value, str) and bool(value.strip())


def root_key(root):
    return digest([root["defect"], root["trigger"], root["violated_contract"]])


def initialize(state):
    context = state["review_cycle"]["review_context"]
    state["review_run"] = dict(
        run_id=context["run_id"], session_id=context["session_id"], pr_number=context["pr_number"],
        issue_number=state["issue_number"], first_cycle=context["cycle_count"], status="active", clock=[], observations=[],
        fixes=[], replans=[], diagnosed_work_seconds=0,
        current_decision=dict(action="observe", reasons=[]))


def current(state, session, completed=False, check_head=True):
    require(state.get("session_id") == session, "foreign session state")
    run = state.get("review_run")
    frozen = state.get("review_cycle")
    require(isinstance(run, dict) and isinstance(frozen, dict), "stagnation-enabled review run required")
    context = frozen["review_context"]
    require(run["session_id"] == context["session_id"] == session
            and run["pr_number"] == context["pr_number"] == state.get("pr_number")
            and run["run_id"] == context["run_id"]
            and run["issue_number"] == state.get("issue_number")
            and context["cycle_count"] == state.get("cycle_count"), "run / review context mismatch")
    require(run["status"] in ("active", "stopped"), "invalid review run status")
    for name in ("clock", "observations", "fixes", "replans"):
        require(isinstance(run.get(name), list), "missing run history: " + name)
    require(type(run.get("diagnosed_work_seconds")) in (int, float)
            and run["diagnosed_work_seconds"] >= 0, "invalid diagnostic clock")
    if completed:
        require(frozen.get("status") == "completed", "all reviewers must be collected and saved")
    if check_head:
        require(cycle.head() == context["commit_sha"], "HEAD differs from review context")
    return run, context


def retained_run(state, session):
    """The one shape where a run legitimately outlives the cycle it froze.

    `review-abandon` drops an evidence-free cycle and keeps the run, so the
    pairing `current()` requires is absent. The abandonment record is what makes
    that absence legitimate: without it a run with no cycle is corruption, so
    every check `current()` makes is repeated here against the record instead of
    the frozen cycle — except the HEAD comparison, which compares a frozen cycle
    against the current HEAD and so has nothing to compare in a shape that has no
    cycle. Abandoning does not itself require a moved HEAD.
    """
    if "review_run" not in state or isinstance(state.get("review_cycle"), dict):
        return None
    run = state["review_run"]
    require(isinstance(run, dict), "review run must be an object")
    history = state.get("review_cycle_abandoned")
    require(isinstance(history, list) and history,
            "review run without a frozen cycle requires an abandonment record")
    require(all(isinstance(record, dict) and isinstance(record.get("review_context"), dict)
                for record in history), "abandonment record must carry its review context")
    # Select by run identity first, then validate the newest record. Never fall
    # back to an older valid context when this run's latest record is invalid.
    context = next((record["review_context"] for record in reversed(history)
                    if record["review_context"].get("run_id") == run.get("run_id")), None)
    require(context is not None, "abandonment record does not match the retained review run")
    for name in ("session_id", "pr_number", "run_id", "issue_number"):
        require(name in run, "review run is missing " + name)
    for name in ("session_id", "pr_number", "run_id", "cycle_count"):
        require(name in context, "abandonment record is missing " + name)
    require(run["session_id"] == context["session_id"] == session == state.get("session_id")
            and run["pr_number"] == context["pr_number"] == state.get("pr_number")
            and run["run_id"] == context["run_id"]
            and run["issue_number"] == state.get("issue_number")
            and context["cycle_count"] == state.get("cycle_count"),
            "abandonment record does not match the retained review run")
    require(run.get("status") in ("active", "stopped"), "invalid review run status")
    for name in ("clock", "observations", "fixes", "replans"):
        require(isinstance(run.get(name), list), "missing run history: " + name)
    require(type(run.get("diagnosed_work_seconds")) in (int, float)
            and run["diagnosed_work_seconds"] >= 0, "invalid diagnostic clock")
    return run


def observation(run, context):
    return next((item for item in run["observations"] if item["input"]["review_context"] == context), None)


def triaged_hash(receipt):
    """Freeze the one permitted derivative using the existing classification policy."""
    helper = Path(__file__).resolve().parents[3] / "scripts/review-findings-maps.sh"
    with tempfile.TemporaryDirectory(prefix="rite-review-triage-") as temporary:
        path = Path(temporary, "review.json")
        path.write_text(json.dumps(receipt), encoding="utf-8")
        result = subprocess.run(["bash", str(helper), "--review-source", "explicit_file",
                                 "--review-source-path", str(path)], text=True, capture_output=True)
        require(result.returncode == 0, "review receipt classification failed: " + result.stdout + result.stderr)
        return digest(read(path))


def same_observation(saved, data):
    # A replayed observation keeps its raw Issue body; only the specification identity must match.
    left = {k: v for k, v in saved.items() if k != "issue_body"}
    right = {k: v for k, v in data.items() if k != "issue_body"}
    return left == right and cycle.same_specification(saved.get("issue_body", ""), data.get("issue_body", ""))


def without_attestation(receipt):
    """Undo the ready / merge helper's human attestation of unverified criteria.

    The helper rewrites exactly status, head and at on the rows it attests, and
    only for the reviewed HEAD. Anything else still changes the digest.
    """
    table = receipt.get("acceptance_criteria")
    if not isinstance(table, list):
        return receipt
    restored = copy.deepcopy(receipt)
    for row in restored["acceptance_criteria"]:
        if (isinstance(row, dict) and row.get("status") == "human-verified"
                and row.get("head") == receipt.get("commit_sha")):
            row["status"] = "unverified"
            row.pop("head", None)
            row.pop("at", None)
    return restored


def unchanged_receipt(saved, receipt):
    known = (saved["review_hash"], saved.get("triaged_hash"))
    return digest(receipt) in known or digest(without_attestation(receipt)) in known


def gate(state, session, allow_replan=False, check_head=True):
    if "review_run" not in state:
        return
    run, context = current(state, session, completed=True, check_head=check_head)
    require(run["status"] != "stopped", "review run stopped: " + str(run.get("stop_reason")))
    saved = observation(run, context)
    require(saved is not None, "saved stagnation observation required before fix / next review")
    require(unchanged_receipt(saved, read(saved["result_path"])), "observed review receipt is missing or changed")
    require(allow_replan or run["current_decision"]["action"] != "replan",
            "required review-replan must complete before fix / next review")


def park(old, run):
    """Preserve the run, counter and optional cycle across an Issue or PR switch.

    A retained run has no frozen cycle, so its counter must be saved separately.
    Its abandonment record remains in the session history for restore validation.
    """
    parked = dict(run, parked=dict(cycle_count=old.get("cycle_count", 0)))
    frozen = old.get("review_cycle")
    if isinstance(frozen, dict):
        parked["parked"]["review_cycle"] = frozen
    return parked


def restore(old, new):
    """Returning to a parked PR brings its run back rather than starting a new one.

    Without this, the exit doubles as a breaker reset: a fresh run on the same
    PR would arrive with a zeroed counter and no observations, and every stop
    reason would clear by leaving and coming back.
    """
    history = list(old.get("review_run_history", []))
    for index in range(len(history) - 1, -1, -1):
        entry = history[index]
        if not (isinstance(entry, dict) and entry.get("pr_number") == new.get("pr_number")):
            continue
        require(entry.get("status") in ("active", "stopped"),
                "archived review run for this PR has an unknown status: " + str(entry.get("status")))
        # Without the parked context, an old marker cannot prove this run ended.
        require(isinstance(entry.get("parked"), dict),
                "archived review run for this PR was parked without its frozen cycle and counter; "
                "its review state cannot be restored in this session")
        frozen = entry["parked"].get("review_cycle")
        context = frozen.get("review_context") if isinstance(frozen, dict) else None
        # Only close/defer of the parked completed cycle settles an active run.
        # A later retained cycle has no frozen context, so historical markers
        # cannot discharge its counter or observations. Stops always survive.
        if (entry["status"] != "stopped" and isinstance(context, dict) and context
                and frozen.get("status") == "completed"
                and (entry.get("completed_context") == context or entry.get("deferred_context") == context)):
            continue
        parked_meta = entry.get("parked")
        superseded = parked_meta.get("superseded_by") if isinstance(parked_meta, dict) else None
        if text(superseded):
            record = parked_meta.get("restart")
            frozen_ctx = None
            if isinstance(parked_meta.get("review_cycle"), dict):
                frozen_ctx = parked_meta["review_cycle"].get("review_context")
            require(isinstance(record, dict)
                    and record.get("old_run_id") == entry.get("run_id")
                    and record.get("old_context") == frozen_ctx
                    and text(record.get("reason")) and text(record.get("requested_at"))
                    and record.get("new_run_id") == superseded,
                    "archived review run for this PR has an invalid supersession record")
            continue
        require(entry.get("issue_number") == new.get("issue_number")
                and entry.get("session_id") == new.get("session_id"),
                "archived review run for this PR belongs to another Issue or session")
        run = dict(entry)
        parked = run.pop("parked")
        new["review_run"] = run
        new["cycle_count"] = parked["cycle_count"]
        if isinstance(parked.get("review_cycle"), dict):
            new["review_cycle"] = parked["review_cycle"]
        elif run["status"] == "active":
            # Use the same full validation as every later retained consumer,
            # with the newest abandonment belonging to this run, not any match.
            require(isinstance(old.get("review_cycle_abandoned"), list)
                    and old["review_cycle_abandoned"],
                    "archived review run for this PR has no frozen cycle and no abandonment record")
            retained_run(dict(new, review_cycle_abandoned=old["review_cycle_abandoned"]),
                         new["session_id"])
        # Every other path that records a stop deactivates the session in the same
        # write. Restoring the reason without the flag would leave a combination
        # no stop produces, and the consumers that branch on `active` would read
        # a frozen run as work in progress. A run parked while still active never
        # recorded either, so it comes back the way it left.
        if run["status"] == "stopped":
            new["stop_reason"] = run["stop_reason"]
            new["active"] = False
        history.pop(index)
        new["review_run_history"] = history
        return


def guard_set(old, new):
    if "review_run_history" in old:
        new["review_run_history"] = old["review_run_history"]
    if "review_run" not in old:
        restore(old, new)
        if "review_run" in new:
            # Restoration owns the destination pairing. The outer cycle guard
            # must not overwrite it with the standalone source's completed cycle.
            frozen = old.get("review_cycle")
            require(frozen is None or (isinstance(frozen, dict) and frozen.get("status") == "completed"),
                    "cannot restore a review run while a standalone review is incomplete")
            return True
        return False
    # An abandoned cycle leaves the run without a frozen counterpart. Routing that
    # shape into current() would reject every ordinary set, including the one
    # /rite:recover uses to restore `active`.
    retained = retained_run(old, old["session_id"])
    if retained is not None:
        # No context is bound here on purpose: the retained shape has no frozen
        # cycle to compare against, and a None standing in for one would match a
        # run that simply lacks the key if the comparison below ever moved.
        run = retained
    else:
        run, context = current(old, old["session_id"], check_head=False)
    require(new.get("session_id") == old["session_id"], "foreign session transition")
    switching = (new.get("issue_number") != old.get("issue_number")
                 or new.get("pr_number") not in (old.get("pr_number"), 0))
    if switching:
        if retained is not None:
            # Abandoning strands no verified work — the record states why the cycle
            # was dropped — so the run follows it into history instead of locking
            # the session out of every other Issue for good. It parks like any
            # other run: the counter it carries is the only copy, since dropping
            # the cycle left no frozen context to read it back from, and restore()
            # refuses an archived run that arrives without its parked wrapper.
            new["cycle_count"] = 0
            new["review_run_history"] = old.get("review_run_history", []) + [park(old, run)]
            # A direct PR switch must restore its destination in this same write.
            restore(new, new)
            return True
        closed = (run.get("completed_context") == context
                  or run.get("deferred_context") == context)
        # A stop is already the decision that this run takes no further cycle, so
        # it releases the session exactly as a completed or deferred one does.
        # Requiring ownership cleanup first would leave the lockout in place at
        # the entry that matters: the switching set new-Issue entry performs has
        # no cleanup step, and clear-worktree never reaches cmd_set.
        stopped = run["status"] == "stopped"
        require(closed or stopped
                or (old.get("phase") in ("cleanup", "completed") and old.get("active") is False),
                "new Issue / PR requires completed or deferred review, or ownership cleanup")
        # Releasing the session is not discharging the stop: the archived run
        # keeps its status, reason and spent retry, and close() still refuses it
        # because gate() itself is untouched.
        # A closed run already passed gate() when close / defer recorded it, and
        # restore() never resumes it, so leaving does not re-read its receipt:
        # cleanup deletes that file once the review has ended.
        if not (stopped or closed):
            gate(old, old["session_id"], check_head=False)
        # Ordinary setters merge counters; ownership completion, rather than an
        # optional caller flag, authorizes this new run's initial zero.
        new["cycle_count"] = 0
        new["review_run_history"] = old.get("review_run_history", []) + [park(old, run)]
        restore(new, new)
        return True
    require(new.get("cycle_count", 0) == old.get("cycle_count", 0),
            "cannot reset cycle_count within a review run")
    require(new.get("pr_number") == old.get("pr_number"), "cannot detach the active review run PR")
    if new.get("phase") in ("fix", "ready") and new.get("phase") != old.get("phase"):
        # Refusing is right — an abandoned cycle leaves no verified receipt at this
        # counter — but the run does exist, so gate()'s "no run" wording would send
        # the operator looking for the wrong thing.
        require(retained is None,
                "abandoned review has no verified receipt; start a new review before fix / ready")
        gate(old, old["session_id"], allow_replan=new.get("phase") == "fix", check_head=False)
    reason = new.get("stop_reason", "")
    if reason.startswith("circuit-breaker:") and run["status"] != "stopped":
        run.update(status="stopped", stop_reason=reason,
                   current_decision=dict(action="stop", reasons=[reason]))
    if run["status"] == "stopped":
        new["stop_reason"] = run["stop_reason"]
        require(new.get("active") is False, "stopped review run cannot be restarted")
    new["review_run"] = run
    if "review_run_history" in old:
        new["review_run_history"] = old["review_run_history"]
    return False


def retry_consumed(run):
    """One grant per run. The archive is not scanned.

    A parked run comes back through restore() rather than being replaced by a
    fresh one, so a spent grant returns attached to the run that spent it. The
    limit therefore holds at the run, and a second reading of the same rule from
    the history would be a backstop for a case the return no longer produces.
    """
    return "retry" in run


def retry(state, args, directory):
    """Grant a divergence-stopped run one bounded re-entry against a checked plan.

    Not an acquittal of the stop: the plan proves every blocking finding has a
    disposition and a verification, nothing proves the run will converge. The
    reason moves into the grant rather than being erased, and conclude_retry
    ends the attempt one review later.
    """
    run, context = current(state, args.session, completed=True)
    require(run["status"] == "stopped", "review run is not stopped")
    require(run.get("stop_reason") == "circuit-breaker:divergence",
            "only circuit-breaker:divergence can be retried; stopped: " + str(run.get("stop_reason")))
    require(not retry_consumed(run), "review run has already used its retry")
    saved = observation(run, context)
    require(saved is not None, "saved stagnation observation required before retry")
    require(unchanged_receipt(saved, read(saved["result_path"])), "observed review receipt is missing or changed")
    scope = importlib.import_module("review-fix-scope")
    plan, issue = read(args.plan), read(args.issue)
    receipt = scope.validate_context(plan, state, args.session, directory)
    plan_specification(state, plan)
    scope.validate_plan(plan, issue, state, receipt)
    run["retry"] = dict(stop_context=context.copy(), stop_reason=run["stop_reason"],
                        plan_hash=digest(plan), outcome=None)
    run.pop("stop_reason", None)
    run.update(status="active", current_decision=dict(action="observe", reasons=[]))
    state.pop("stop_reason", None)
    state.update(active=True, updated_at=cycle.now())
    return state


ALLOWED_RESTART_REASONS = ("circuit-breaker:divergence", "circuit-breaker:max-cycles")


def restart(state, args, directory):
    """Archive a stopped run and freeze a new cycle-1 run against an explicit approval.

    Distinct from retry(): a new run_id and counter, not the same run reopened.
    The approval record is stored on the parked run so the tmp input can vanish.
    """
    approval = read(args.approval)
    require(isinstance(approval, dict), "approval must be a JSON object")
    require(approval.get("kind") == "explicit-fresh-entry", "approval kind must be explicit-fresh-entry")
    require(text(approval.get("reason")), "approval reason required")
    require(text(approval.get("requested_at")), "approval requested_at required")
    require(isinstance(approval.get("review_context"), dict), "approval review_context required")
    require(type(approval.get("issue_number")) is int and approval["issue_number"] > 0,
            "approval issue_number must be a positive integer")
    require(type(approval.get("pr_number")) is int and approval["pr_number"] > 0,
            "approval pr_number must be a positive integer")
    require(text(getattr(args, "expected_run_id", "")), "expected run id required")
    selected = cycle.read(args.selection)
    cycle.roster(selected)

    history = list(state.get("review_run_history", []))
    live = state.get("review_run")
    if isinstance(live, dict) and live.get("status") == "active":
        for entry in reversed(history):
            parked = entry.get("parked") if isinstance(entry, dict) else None
            record = parked.get("restart") if isinstance(parked, dict) else None
            if (isinstance(parked, dict) and parked.get("superseded_by") == live.get("run_id")
                    and isinstance(record, dict)
                    and record.get("old_run_id") == args.expected_run_id
                    and record.get("reason") == approval["reason"]
                    and record.get("requested_at") == approval["requested_at"]
                    and record.get("old_context") == approval["review_context"]):
                return state

    run, context = current(state, args.session, completed=True, check_head=False)
    require(run["status"] == "stopped", "review run is not stopped")
    require(run["run_id"] == args.expected_run_id, "expected run id does not match the stopped run")
    require(run.get("stop_reason") in ALLOWED_RESTART_REASONS,
            "only circuit-breaker:divergence or circuit-breaker:max-cycles can restart; stopped: "
            + str(run.get("stop_reason")))
    require(run.get("current_decision", {}).get("action") == "stop",
            "stopped run is missing a stop decision")
    require(approval.get("run_id") == run["run_id"] == context["run_id"],
            "approval run id does not match the stopped run")
    require(approval["review_context"] == context,
            "approval review_context does not match the frozen context")
    require(approval["issue_number"] == state.get("issue_number") == run["issue_number"],
            "approval issue does not match the stopped run")
    require(approval["pr_number"] == state.get("pr_number") == run["pr_number"] == context["pr_number"],
            "approval PR does not match the stopped run")
    saved = observation(run, context)
    require(saved is not None, "saved stagnation observation required before restart")
    require(unchanged_receipt(saved, read(saved["result_path"])),
            "observed review receipt is missing or changed")
    tracked = subprocess.run(["git", "status", "--porcelain", "-uno"],
                             capture_output=True, text=True)
    untracked = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"],
                               capture_output=True, text=True)
    require(tracked.returncode == 0 and untracked.returncode == 0,
            "git status failed; cannot verify a clean tree before restart")
    require(not tracked.stdout.strip() and not untracked.stdout.strip(),
            "working tree is dirty; commit or restore before restart")
    root = os.environ.get("RITE_STATE_ROOT", "")
    if root:
        clock_file = Path(root) / ".rite" / "state" / ("review-clock-" + args.session + ".json")
        require(not clock_file.exists(), "unresolved review clock is open; close or recover it first")

    new_run_id = str(uuid.uuid4())
    parked_run = park(state, copy.deepcopy(run))
    parked_run["parked"]["superseded_by"] = new_run_id
    parked_run["parked"]["restart"] = dict(
        old_run_id=run["run_id"], old_context=copy.deepcopy(context),
        reason=approval["reason"], requested_at=approval["requested_at"],
        new_run_id=new_run_id, head=cycle.head(), at=cycle.now())
    history.append(parked_run)
    new_context = dict(session_id=args.session, run_id=new_run_id, pr_number=state["pr_number"],
                       cycle_count=1, commit_sha=cycle.head())
    state.update(phase="review", cycle_count=1, active=True, updated_at=cycle.now(),
                 next_action="/rite:pr-review " + str(state["pr_number"]),
                 review_cycle=dict(review_context=new_context, selected_reviewers=selected,
                                   status="collecting"),
                 review_run_history=history)
    state.pop("stop_reason", None)
    state.pop("handoff", None)
    initialize(state)
    return state


def conclude_retry(run, receipt):
    """A grant buys one review. Blocking findings at its end restore the stop."""
    grant = run.get("retry")
    if not grant or grant["outcome"] is not None:
        return None
    blocking = any(f.get("scope") in ("current-pr", "follow-up") for f in receipt["findings"])
    grant["outcome"] = "unresolved" if blocking else "resolved"
    return dict(action="stop", reasons=["retry-unresolved"]) if blocking else None


def close(state, args, directory):
    """Record the successful iterate boundary without resetting the owning run."""
    gate(state, args.session)
    run, context = current(state, args.session, completed=True)
    receipt = cycle.matching_receipt(directory, state["review_cycle"])
    require(receipt is not None, "saved review receipt missing")
    saved = receipt[1]
    require(not any(f.get("scope") in ("current-pr", "follow-up") for f in saved["findings"]),
            "cannot close review with unresolved blocking findings")
    table = saved.get("acceptance_criteria")
    require((isinstance(table, dict) and table.get("skipped") in ("no_issue", "no_ac_section"))
            or (isinstance(table, list) and all(row.get("status") == "satisfied"
                or (row.get("status") == "human-verified" and row.get("head") == context["commit_sha"])
                for row in table)), "cannot close review with unmet or unverified acceptance criteria")
    if run.get("completed_context") != context:
        run["completed_context"] = context.copy()
        state["updated_at"] = cycle.now()
    return state


def defer(state, args, directory):
    """Retain an unresolved draft without declaring the review successful."""
    gate(state, args.session)
    run, context = current(state, args.session, completed=True)
    require(cycle.matching_receipt(directory, state["review_cycle"]) is not None,
            "saved review receipt missing")
    if run.get("deferred_context") != context:
        run["deferred_context"] = context.copy()
        run["deferred_reason"] = "replied-only"
        state["updated_at"] = cycle.now()
    return state


def instant(value):
    require(text(value), "clock timestamp required")
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "clock timestamp must include timezone")
    return parsed.timestamp()


def clock(state, args):
    run, context = current(state, args.session, check_head=False)
    data = read(args.input)
    require(data.get("review_context") == context, "clock context mismatch")
    require(text(data.get("segment_id")), "clock segment_id required")
    previous = next((entry for entry in run["clock"] if entry["segment_id"] == data["segment_id"]), None)
    if previous:
        require(previous == data, "clock segment replay has different content")
        return state
    require(run["status"] != "stopped", "stopped review clock is immutable")
    require(data.get("kind") in ("work", "external_wait", "interruption"), "invalid clock kind")
    begin, end = instant(data.get("started_at")), instant(data.get("ended_at"))
    require(end >= begin, "clock segment ends before it starts")
    for entry in run["clock"]:
        require(end <= instant(entry["started_at"]) or begin >= instant(entry["ended_at"]),
                "clock segments must not overlap")
    run["clock"].append(data)
    state["updated_at"] = cycle.now()
    return state


def work_seconds(run):
    return sum(instant(item["ended_at"]) - instant(item["started_at"])
               for item in run["clock"] if item["kind"] == "work")


def validate_input(state, args, data, receipt):
    require(data.get("review_context") == state["review_cycle"]["review_context"], "observation context mismatch")
    issue = read(args.issue)
    require(issue.get("number") == data.get("issue_number") == state.get("issue_number")
            and text(issue.get("body")) and text(data.get("issue_body"))
            and cycle.same_specification(data["issue_body"], issue["body"]),
            "latest Issue specification differs from observation")
    roots = data.get("roots")
    require(isinstance(roots, list), "root observations must be an array")
    findings = {f["id"]: f for f in receipt["findings"] + receipt.get("non_blocking_findings", [])}
    blocking = {f["id"] for f in receipt["findings"] if f.get("scope") in ("current-pr", "follow-up")}
    covered, keys, normalized = [], [], []
    for root in roots:
        require(isinstance(root, dict) and all(text(root.get(k)) for k in ("defect", "trigger", "violated_contract")),
                "root identity requires defect, trigger and violated_contract")
        ids = root.get("finding_ids")
        require(isinstance(ids, list) and ids and all(text(i) and i in findings for i in ids),
                "root must reference saved finding IDs")
        evidence = []
        for fid in ids:
            measured = findings[fid].get("verification")
            require(isinstance(measured, dict) and measured.get("measured") is True
                    and any(text(measured.get(k)) for k in ("repro", "failing_test")),
                    "root requires saved measured reproduction evidence: " + fid)
            evidence.append(dict(finding_id=fid, verification=measured))
        covered.extend(ids)
        keys.append(root_key(root))
        normalized.append(dict(identity={k: root[k] for k in ("defect", "trigger", "violated_contract")},
                               key=keys[-1], evidence=evidence, finding_ids=ids))
    require(len(covered) == len(set(covered)) and blocking <= set(covered),
            "every blocking finding must appear in exactly one root")
    require(len(keys) == len(set(keys)), "combine identical root identities")
    acceptance = data.get("acceptance")
    require(isinstance(acceptance, dict) and isinstance(acceptance.get("satisfied"), list)
            and all(text(item) for item in acceptance["satisfied"])
            and len(acceptance["satisfied"]) == len(set(acceptance["satisfied"]))
            and text(acceptance.get("evidence")), "acceptance progress needs unique criteria and evidence")
    table = receipt.get("acceptance_criteria")
    if isinstance(table, list):
        require(all(isinstance(row, dict) and text(row.get("id")) and text(row.get("evidence"))
                    and row.get("status") in ("satisfied", "unmet", "unverified", "human-verified")
                    for row in table), "saved acceptance evidence is invalid")
        satisfied = {row["id"] for row in table if row["status"] == "satisfied"
                     or (row["status"] == "human-verified" and row.get("head") == receipt["commit_sha"])}
    else:
        require(isinstance(table, dict) and table.get("skipped") in ("no_issue", "no_ac_section"),
                "saved acceptance evidence is missing")
        satisfied = set()
    require(set(acceptance["satisfied"]) == satisfied, "acceptance progress differs from saved receipt")
    return normalized


def fixes_between(run, left, right, key):
    return {fix["commit_sha"] for fix in run["fixes"]
            if left["input"]["review_context"]["cycle_count"] <= fix["source_context"]["cycle_count"]
            < right["input"]["review_context"]["cycle_count"] and key in fix["roots"]}


def recurrence(run, key, start=None):
    sightings = [entry for entry in run["observations"]
                 if any(root["key"] == key for root in entry["roots"])
                 and (start is None or entry["input"]["review_context"]["cycle_count"] >= start)]
    # Rereviews of one HEAD replace its sighting without adding a repair attempt.
    by_head = {entry["input"]["review_context"]["commit_sha"]: entry for entry in sightings}
    sightings = sorted(by_head.values(), key=lambda entry: entry["input"]["review_context"]["cycle_count"])
    if len(sightings) < 3:
        return False
    window = sightings[-3:]
    first = fixes_between(run, window[0], window[1], key)
    second = fixes_between(run, window[1], window[2], key)
    return bool(first and second and len(first | second) >= 2)


def observe(state, args, directory):
    run, context = current(state, args.session, completed=True)
    receipt = cycle.matching_receipt(directory, state["review_cycle"])
    require(receipt is not None, "saved review receipt missing")
    data = read(args.input)
    roots = validate_input(state, args, data, receipt[1])
    require(all(cycle.same_specification(entry["input"]["issue_body"], data["issue_body"]) for entry in run["observations"]),
            "Issue specification changed within run; retain history and reconcile before continuing")
    previous = observation(run, context)
    if previous:
        require(same_observation(previous["input"], data) and unchanged_receipt(previous, receipt[1]),
                "same observation cannot be overwritten with different content")
        return state
    require(run["status"] != "stopped", "review run stopped: " + str(run.get("stop_reason")))
    require(any(entry["review_context"] == context for entry in run["clock"]),
            "explicit clock segment required for this review observation")
    entry = dict(input=data, roots=roots, review_hash=digest(receipt[1]),
                 triaged_hash=triaged_hash(receipt[1]), result_path=str(receipt[0]))
    run["observations"].append(entry)
    # existing_breaker re-reads every saved receipt and checks the observation
    # series for gaps before it decides anything, so it runs on every path. Only
    # which stop is recorded depends on the grant.
    breaker = existing_breaker(state, run)
    concluded = conclude_retry(run, receipt[1])
    if concluded:
        entry["decision"] = concluded.copy()
        run.update(status="stopped", stop_reason=run["retry"]["stop_reason"], current_decision=concluded)
        state.update(active=False, stop_reason=run["stop_reason"], updated_at=cycle.now())
        return state
    if breaker:
        decision = dict(action="stop", reasons=[breaker])
        entry["decision"] = decision.copy()
        run.update(status="stopped", stop_reason="circuit-breaker:" + breaker, current_decision=decision)
        state.update(active=False, stop_reason=run["stop_reason"], updated_at=cycle.now())
        return state
    repeated = [root["key"] for root in roots if recurrence(run, root["key"])]
    renewed = []
    for key in repeated:
        previous_replans = [item for item in run["replans"] if key in item["roots"]]
        if not previous_replans or recurrence(run, key, previous_replans[-1]["review_context"]["cycle_count"]):
            renewed.append(key)
    elapsed = work_seconds(run)
    reasons = (["work-time"] if elapsed - run["diagnosed_work_seconds"] > 1800 else [])
    if renewed:
        reasons.append("root-recurrence")
    action = "continue"
    for replan in run["replans"]:
        start = replan["review_context"]["cycle_count"]
        present = set(data["acceptance"]["satisfied"])
        baseline = set(replan["acceptance_satisfied"])
        intervening = [obs for obs in run["observations"]
                       if obs["input"]["review_context"]["cycle_count"] >= start]
        progressed = any(set(obs["input"]["acceptance"]["satisfied"]) - baseline for obs in intervening)
        unresolved = set(replan["roots"]) & set(repeated)
        if not progressed and not (present - baseline) and any(recurrence(run, key, start) for key in unresolved):
            action, reasons = "stop", ["non-convergent-root"]
            break
    if action != "stop" and reasons:
        # A diagnostic window advances even if the finite replan allowance is
        # exhausted. Time alone never becomes a stop.
        run["diagnosed_work_seconds"] = elapsed
        if len(run["replans"]) < 2 and roots:
            action = "replan"
    decision = dict(action=action, reasons=reasons)
    entry["decision"] = decision.copy()
    run["current_decision"] = decision
    if action == "stop":
        run.update(status="stopped", stop_reason="stagnation:non-convergent")
        state.update(active=False, stop_reason=run["stop_reason"])
    state["updated_at"] = cycle.now()
    return state


def existing_breaker(state, run):
    """Validate all receipts, then reuse the established trend policy on this run only."""
    records = run["observations"]
    expected = list(range(run["first_cycle"], state["cycle_count"] + 1))
    require([item["input"]["review_context"]["cycle_count"] for item in records] == expected,
            "completed review observation history has gaps; repair saved receipts first")
    with tempfile.TemporaryDirectory(prefix="rite-review-trend-") as temporary:
        for index, item in enumerate(records):
            saved = read(item["result_path"])
            require(saved.get("review_context") == item["input"]["review_context"]
                    and unchanged_receipt(item, saved), "saved historical receipt is missing or changed")
            Path(temporary, str(state["pr_number"]) + "-" + str(index).zfill(8) + ".json").write_text(json.dumps(saved))
        helper = Path(__file__).resolve().parent.parent / "review-trend-divergence.sh"
        result = subprocess.run(["bash", str(helper), "--pr", str(state["pr_number"]),
                                 "--cycle-count", str(len(records)), "--results-dir", temporary],
                                check=True, text=True, capture_output=True)
    marker = dict(re.findall(r"(?:^|; )([A-Za-z_]+)=([^;\n]*)", result.stdout.replace("[CONTEXT] ", "")))
    require(marker.get("TREND_DIVERGENCE") in ("ok", "fire")
            or (marker.get("TREND_DIVERGENCE") == "insufficient" and marker.get("reason") == "need_3_cycles"),
            "existing trend gate could not validate saved receipts: " + result.stdout.strip())
    require(marker.get("lost") == "0", "existing trend gate reports missing receipts")
    run["trend"] = marker
    # A completed mergeable review proceeds to the unchanged quality gates.
    if state["review_cycle"]["verdict"] == "mergeable":
        return None
    maximum = 15
    config = Path("rite-config.yml")
    if config.exists():
        section = re.search(r"^safety:\s*\n(.*?)(?=^[a-zA-Z]|\Z)", config.read_text(), re.M | re.S)
        if section:
            setting = re.search(r"^\s+max_review_cycles:\s*(.*)$", section[1], re.M)
            if setting:
                value = re.sub(r"\s+#.*", "", setting[1]).strip().strip("\"'")
                if value.isdecimal() and int(value) > 0:
                    maximum = int(value)
    if state["cycle_count"] >= maximum:
        return "max-cycles"
    return "divergence" if marker["TREND_DIVERGENCE"] == "fire" else None


def amend_replan(state, args, directory, run, context, plan, issue, previous):
    # Correction changes execution instructions, not the diagnosed scope or budget.
    gate(state, args.session)
    require(previous is not None, "no registered replan to amend")
    require(text(args.reason), "--reason must explain the command correction")
    scope = importlib.import_module("review-fix-scope")
    scope.validate(plan, issue, state, args.session, directory.parent.parent, allow_replan=True)
    history = previous.get("amendments", [])
    plan_hash = digest(plan)
    if history and previous["plan_hash"] == plan_hash:
        require(history[-1]["reason"] == args.reason, "amendment replay reason differs")
        return state
    for entry in history:
        if entry.get("new_plan_hash") == plan_hash and entry.get("reason") == args.reason:
            require(False, "superseded amendment cannot be replayed")
    original, changed = copy.deepcopy(previous["plan"]), copy.deepcopy(plan)
    require(cycle.same_specification(original["issue_body"], changed["issue_body"]),
            "amendment changes Issue specification")
    changed["issue_body"] = original["issue_body"]
    for candidate in (original, changed):
        for test in candidate["verifications"]:
            test.pop("command", None)
    require(original == changed, "amendment may change only verification commands")
    require(previous["plan"].get("verifications") != plan.get("verifications"),
            "amendment requires a command correction")
    evidence = {}
    for name in ("fix-plan", "fix-verification"):
        path = directory.parent / "state" / (name + "-" + args.session + ".json")
        if not path.exists():
            evidence[name] = None
            continue
        payload = read(path)
        if name == "fix-verification":
            require(isinstance(payload, dict) and payload.get("review_context") == context,
                    "verification receipt context differs")
        evidence[name] = payload
    entry = dict(old_plan=previous["plan"], old_plan_hash=previous["plan_hash"],
                 new_plan_hash=plan_hash, reason=args.reason, evidence=evidence,
                 pending_fix=run.get("pending_fix"), recorded_at=cycle.now())
    previous["amendments"] = history + [entry]
    previous.update(plan=plan, plan_hash=plan_hash)
    run.pop("pending_fix", None)
    state["updated_at"] = cycle.now()
    return state


def replan(state, args, directory):
    run, context = current(state, args.session, completed=True)
    plan, issue = read(args.plan), read(args.issue)
    previous = next((item for item in run["replans"] if item["review_context"] == context), None)
    if getattr(args, "amend", False):
        return amend_replan(state, args, directory, run, context, plan, issue, previous)
    require(not args.reason, "--reason requires --amend")
    if previous:
        require(previous["plan_hash"] == digest(plan), "same replan cannot be overwritten")
        require(text(plan.get("issue_body")) and text(issue.get("body"))
                and cycle.same_specification(plan["issue_body"], issue["body"])
                and issue.get("number") == state.get("issue_number"),
                "latest Issue specification differs from replan")
        receipt = cycle.matching_receipt(directory, state["review_cycle"])
        require(receipt is not None, "saved receipt missing")
        require(unchanged_receipt(observation(run, context), receipt[1]), "observed review receipt is missing or changed")
        return state
    gate(state, args.session, allow_replan=True)
    require(run["current_decision"]["action"] == "replan", "no required replan for this observation")
    require(len(run["replans"]) < 2, "replan allowance exhausted")
    scope = importlib.import_module("review-fix-scope")
    saved, _ = scope.validate(plan, issue, state, args.session, directory.parent.parent, allow_replan=True)
    all_findings = {finding["id"] for finding in saved["findings"] + saved.get("non_blocking_findings", [])}
    dispositions = {finding_id for group in plan["groups"] for finding_id in group["finding_ids"]}
    require(all_findings <= dispositions, "replan must reconsider every saved finding, including non-blocking findings")
    detail = plan.get("replan")
    require(isinstance(detail, dict), "replan alternatives required")
    alternatives = detail.get("alternatives")
    require(isinstance(alternatives, list) and len(alternatives) >= 2, "at least two alternatives required")
    ids = []
    selected = detail.get("selected_id")
    require(detail.get("outcome") in ("continue", "insoluble") and text(detail.get("selection_reason")),
            "replan outcome and selection reason required")
    excluded = plan["constraints"]["non_targets"]
    for alternative in alternatives:
        require(all(text(alternative.get(k)) for k in ("id", "description", "recurrence_prevention")),
                "alternative identity, description and prevention verification required")
        ids.append(alternative["id"])
        paths = alternative.get("paths")
        require(isinstance(paths, list), "alternative planned paths required")
        for value in paths:
            value = scope.path(value)
            require(not any(scope.within(value, p) or scope.within(p, value) for p in excluded),
                    "alternative violates Non-Target")
            require(not plan["constraints"]["closed_targets"]
                    or any(scope.within(value, p) for p in plan["constraints"]["targets"]),
                    "alternative violates closed targets")
        require(alternative["id"] == selected or text(alternative.get("rejection_reason")),
                "rejected alternative needs contractual reason")
    require(len(ids) == len(set(ids)), "alternative IDs must be unique")
    require((detail["outcome"] == "continue" and selected in ids)
            or (detail["outcome"] == "insoluble" and selected is None), "invalid selected alternative")
    if detail["outcome"] == "continue":
        chosen = next(item for item in alternatives if item["id"] == selected)
        planned_paths = {p for group in plan["groups"] for p in group["paths"]}
        require(set(chosen["paths"]) == planned_paths, "selected alternative paths differ from fix plan")
    observed = observation(run, context)
    record = dict(review_context=context, plan_hash=digest(plan), plan=plan,
                  roots=[root["key"] for root in observed["roots"]],
                  acceptance_satisfied=observed["input"]["acceptance"]["satisfied"],
                  reasons=run["current_decision"]["reasons"], recorded_at=cycle.now())
    run["replans"].append(record)
    run["current_decision"] = dict(action="continue", reasons=["replanned"])
    if detail["outcome"] == "insoluble":
        run.update(status="stopped", stop_reason="stagnation:scope-insoluble",
                   current_decision=dict(action="stop", reasons=["scope-insoluble"]))
        state.update(active=False, stop_reason=run["stop_reason"])
    state["updated_at"] = cycle.now()
    return state


def plan_specification(state, plan, allow_replan=False):
    """Bind a plan to the run that diagnosed it, without permitting a transition.

    Everything plan_gate asserts about the plan itself, so the retry path — which
    decides its own admissibility — reuses it instead of restating it.
    """
    if "review_run" not in state:
        return
    run = state["review_run"]
    observed = observation(run, plan["review_context"])
    require(observed is not None and text(plan.get("issue_body"))
            and cycle.same_specification(plan["issue_body"], observed["input"]["issue_body"]),
            "fix specification differs from diagnosed observation")
    if allow_replan:
        return
    for record in run["replans"]:
        if record["review_context"] == plan["review_context"]:
            require(record["plan_hash"] == digest(plan), "fix plan differs from required replan")


def plan_gate(state, plan, session, allow_replan=False):
    gate(state, session, allow_replan=allow_replan)
    plan_specification(state, plan, allow_replan)


def tree_fingerprint():
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]).decode().split("\0")
    entries = []
    for name in sorted(set(names) - {""}):
        path = Path(name)
        if path.is_symlink():
            entries.append([name, "link", os.readlink(path)])
        elif path.is_file():
            entries.append([name, bool(path.stat().st_mode & stat.S_IXUSR), hashlib.sha256(path.read_bytes()).hexdigest()])
        elif not path.exists():
            continue
        else:
            # Submodule contents are not independently proven by this snapshot.
            require(False, "unsupported verification tree entry: " + name)
    return digest(entries)


def verified(state, plan, result, paths):
    if "review_run" not in state:
        return
    run, context = current(state, state["session_id"], completed=True)
    observed = observation(run, context)
    require(observed is not None, "missing observation at fix verification")
    fixed_ids = {fid for group in plan["groups"] if group["action"] == "fix" for fid in group["finding_ids"]}
    scope = importlib.import_module("review-fix-scope")
    run["pending_fix"] = dict(
        source_context=context, plan_hash=digest(plan), paths=paths,
        roots=[root["key"] for root in observed["roots"] if set(root["finding_ids"]) <= fixed_ids],
        tree_hash=tree_fingerprint(), verification=result,
        tests=plan["verifications"],
        input_keys={test["id"]: scope.fingerprint(test) for test in plan["verifications"]})
    state["updated_at"] = cycle.now()


def advance(state, session, current_head):
    run, context = current(state, session, completed=True, check_head=False)
    gate(state, session, check_head=False)
    require(not subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"]).strip(),
            "next review requires a committed clean verified tree")
    if current_head == context["commit_sha"]:
        # A rereview of the same commit cannot count as another fix.
        return
    pending = run.get("pending_fix")
    require(isinstance(pending, dict) and pending.get("source_context") == context,
            "changed HEAD requires completed full fix verification; taking in the base branch"
            " goes through a base-intake fix plan before its commit (skills/fix/references/fix-plan.md, section: base 取り込み)")
    require(pending["tree_hash"] == tree_fingerprint(), "HEAD content differs from verified fix tree")
    scope = importlib.import_module("review-fix-scope")
    for test in pending["tests"]:
        measured = pending["verification"]["results"].get(test["id"])
        require(measured and measured.get("exit_code") == 0
                and measured.get("key") == pending["input_keys"][test["id"]] == scope.fingerprint(test),
                "fix verification inputs or receipt changed")
    require(current_head not in {fix["commit_sha"] for fix in run["fixes"]},
            "previously counted fix HEAD cannot be counted again")
    run["fixes"].append(dict(pending, commit_sha=current_head))
    run.pop("pending_fix", None)
