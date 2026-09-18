"""Persist review diagnostics in the same transaction as the owning review run."""
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


def unchanged_receipt(saved, receipt):
    return digest(receipt) in (saved["review_hash"], saved.get("triaged_hash"))


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
    """The run plus what a set would otherwise drop, so a return can restore it.

    `cycle_count` is stored outright rather than read back from the frozen
    cycle's context, and the cycle itself is stored only when there is one. A run
    that drops an evidence-free cycle keeps no frozen counterpart, and that shape
    still has a counter to bring home; deriving the counter from the cycle would
    leave it the one exit with no way back. On this module's own paths the cycle
    is always present — current() requires the pairing before park() is reached —
    so neither branch is exercised here. Keep them: they cost two untaken
    branches, and the caller that parks the unpaired shape needs no second guard.
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
        # Only a stop outlives the session that left it. A completed or deferred
        # run has spent its counter and observations on a verdict that already
        # landed; handing those back would carry its breaker budget into the next
        # round of review instead of starting one.
        if entry.get("status") != "stopped":
            continue
        # Passing over a parked stop would hand back exactly the fresh run the
        # parking exists to withhold, so a stop this PR cannot restore stops the
        # set rather than falling through to one.
        require(isinstance(entry.get("parked"), dict),
                "archived review run for this PR was parked without its frozen cycle and counter; "
                "its stop cannot be restored in this session")
        require(entry.get("issue_number") == new.get("issue_number")
                and entry.get("session_id") == new.get("session_id"),
                "archived review run for this PR belongs to another Issue or session")
        run = dict(entry)
        parked = run.pop("parked")
        new["review_run"] = run
        new["cycle_count"] = parked["cycle_count"]
        if isinstance(parked.get("review_cycle"), dict):
            new["review_cycle"] = parked["review_cycle"]
        # Every other path that records a stop deactivates the session in the same
        # write. Restoring the reason without the flag would leave a combination
        # no stop produces, and the consumers that branch on `active` would read
        # a frozen run as work in progress. Only a stopped entry reaches here.
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
        return False
    run, context = current(old, old["session_id"], check_head=False)
    require(new.get("session_id") == old["session_id"], "foreign session transition")
    switching = (new.get("issue_number") != old.get("issue_number")
                 or new.get("pr_number") not in (old.get("pr_number"), 0))
    if switching:
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
        if not stopped:
            gate(old, old["session_id"], check_head=False)
        # Ordinary setters merge counters; ownership completion, rather than an
        # optional caller flag, authorizes this new run's initial zero.
        new["cycle_count"] = 0
        new["review_run_history"] = old.get("review_run_history", []) + [park(old, run)]
        return True
    require(new.get("cycle_count", 0) == old.get("cycle_count", 0),
            "cannot reset cycle_count within a review run")
    require(new.get("pr_number") == old.get("pr_number"), "cannot detach the active review run PR")
    if new.get("phase") in ("fix", "ready") and new.get("phase") != old.get("phase"):
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


def retry_consumed(state, run):
    """One grant per run, counted across the archive.

    A run that is switched away from carries its grant into history; starting a
    fresh run on the same PR would otherwise hand out a second one and make the
    limit a formality.
    """
    if "retry" in run:
        return True
    return any(isinstance(past, dict) and past.get("pr_number") == run["pr_number"] and "retry" in past
               for past in state.get("review_run_history", []))


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
    require(not retry_consumed(state, run), "review run has already used its retry")
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


def replan(state, args, directory):
    run, context = current(state, args.session, completed=True)
    plan, issue = read(args.plan), read(args.issue)
    previous = next((item for item in run["replans"] if item["review_context"] == context), None)
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
            "changed HEAD requires completed full fix verification")
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
