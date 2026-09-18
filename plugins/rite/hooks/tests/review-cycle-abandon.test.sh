#!/usr/bin/env bash
# Integration: review-abandon against the real flow-state CLI and saver.
# Pins T-03..T-07 of Issue "HEAD 変更後の未完了レビューから復帰できるようにする".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/.." "$0" "$@" <<'PYTEST'
import copy
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

hooks = Path(sys.argv[1]).resolve()
probe = len(sys.argv) > 3 and sys.argv[3] == "--guard-probe"
if probe:
    hooks = Path(sys.argv[4])
checks = 0


def check(value, label):
    global checks
    assert value, label
    checks += 1


def dump(path, value):
    path.write_text(json.dumps(value))


with tempfile.TemporaryDirectory(prefix="rite-review-abandon-") as tmp:
    root = Path(tmp)
    env = dict(os.environ)
    for key in ("CODEX_THREAD_ID", "GROK_SESSION_ID", "CLAUDE_SESSION_ID", "CLAUDE_CODE_SESSION_ID",
                "RITE_HOST", "RITE_STATE_ROOT", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        env.pop(key, None)
    env.update(RITE_HOST="claude", CLAUDE_CODE_SESSION_ID="review-abandon-test", RITE_STATE_ROOT=tmp, TMPDIR=tmp)

    def run(command, ok=True, **kwargs):
        result = subprocess.run(command, cwd=root, env=env, text=True, errors="replace", capture_output=True, **kwargs)
        if ok:
            check(result.returncode == 0, "command failed: " + repr(command) + "\n" + result.stderr)
        return result

    def flow(*args, ok=True):
        return run(["bash", str(hooks / "flow-state.sh"), *map(str, args)], ok)

    def commit(message):
        run(["git", "-c", "user.email=test@example.com", "-c", "user.name=test",
             "commit", "-q", "--allow-empty", "-m", message])
        return run(["git", "rev-parse", "HEAD"]).stdout.strip()

    run(["git", "init", "-q"])
    first_head = commit("initial")
    state_path = root / ".rite/sessions/review-abandon-test.flow-state"
    state = lambda: json.loads(state_path.read_text())
    selection = root / "selection.json"
    selected = ["security-reviewer", "code-quality-reviewer"]
    dump(selection, selected)

    def rejected(args, label, unchanged=True):
        before = state_path.read_bytes()
        result = flow(*args, ok=False)
        check(result.returncode != 0, label + " must fail")
        check("ERROR:" in result.stderr, label + " diagnostic")
        if unchanged:
            check(state_path.read_bytes() == before, label + " state unchanged")
        return result

    def fresh_collecting(pr=91, issue=91):
        # Each fixture starts from a clean session file so cases stay independent.
        if state_path.exists():
            state_path.unlink()
        flow("set", "--phase", "pr", "--next", "review", "--pr", pr, "--issue", issue,
             "--branch", "fix/issue-" + str(issue) + "-x", "--worktree", str(root / "wt"))
        flow("review-start", "--selection", selection)
        check(state()["review_cycle"]["status"] == "collecting", "fixture freezes a collecting cycle")

    # --- T-03: an evidence-free cycle can be abandoned, identity survives -----
    fresh_collecting()
    before = state()
    second_head = commit("advance HEAD past the frozen context")
    check(second_head != first_head, "fixture actually moves HEAD")
    result = flow("review-abandon", "--reason", "HEAD changed before any evidence")
    after = state()
    check("review_cycle" not in after, "T-03 abandon clears the incomplete cycle")
    check(len(after["review_cycle_abandoned"]) == 1, "T-03 records exactly one abandonment")
    record = after["review_cycle_abandoned"][0]
    check(record["review_context"] == before["review_cycle"]["review_context"],
          "T-03 retains the frozen context verbatim")
    check(record["selected_reviewers"] == before["review_cycle"]["selected_reviewers"],
          "T-03 retains the frozen roster")
    check(record["reason"] == "HEAD changed before any evidence", "T-03 retains the reason")
    check(record["head_at_abandon"] == second_head, "T-03 records the HEAD it was abandoned at")
    for key in ("session_id", "issue_number", "pr_number", "branch", "worktree", "cycle_count"):
        check(after[key] == before[key], "T-03 preserves " + key)
    check(json.loads(result.stdout)["reason"] == record["reason"], "T-03 prints the appended record")

    # The record has to survive later writes: cmd_set rebuilds the state object
    # from its own field list, so a field nothing carries forward is lost.
    flow("set", "--phase", "pr", "--next", "still here")
    carried = state().get("review_cycle_abandoned")
    check(isinstance(carried, list) and len(carried) == 1, "T-03 record survives a later set")
    check(carried[0]["review_context"] == record["review_context"]
          and carried[0]["reason"] == record["reason"]
          and carried[0]["head_at_abandon"] == record["head_at_abandon"],
          "T-03 record survives a later set intact")

    # --- T-06: phase init for another issue is no longer refused -------------
    flow("set", "--phase", "init", "--issue", 92, "--pr", 0, "--branch", "fix/issue-92-y",
         "--next", "branch")
    check(state()["issue_number"] == 92 and state()["pr_number"] == 0,
          "T-06 another issue can be initialized after abandon")

    # --- T-05: review-start freezes the current HEAD after abandon -----------
    fresh_collecting(pr=93, issue=93)
    frozen = state()["review_cycle"]["review_context"]["commit_sha"]
    count_before = state()["cycle_count"]
    third_head = commit("advance again")
    flow("review-abandon", "--reason", "restart at current HEAD")
    check(state()["cycle_count"] == count_before, "T-05 abandon leaves the counter alone")
    flow("review-start", "--selection", selection)
    restarted = state()["review_cycle"]["review_context"]
    check(restarted["commit_sha"] == third_head != frozen, "T-05 new cycle freezes the current HEAD")
    check(state()["review_cycle"]["status"] == "collecting", "T-05 new cycle is collecting")
    check(len(state()["review_cycle_abandoned"]) == 1, "T-05 keeps the abandonment history")
    # The restart is a new cycle, so review-start advances the counter exactly once
    # and the frozen context agrees with the state it was written from.
    check(state()["cycle_count"] == count_before + 1, "T-05 review-start advances the counter once")
    check(restarted["cycle_count"] == state()["cycle_count"], "T-05 frozen counter matches the state")

    # --- T-04: a cycle holding evidence is refused, state untouched ----------
    for key, value in (("manifest_path", str(root / "manifest.json")),
                       ("content_file", str(root / "result.json")),
                       ("result_path", str(root / "receipt.json"))):
        fresh_collecting(pr=94, issue=94)
        loaded = state()
        loaded["review_cycle"][key] = value
        dump(state_path, loaded)
        refusal = rejected(["review-abandon", "--reason", "should not pass"],
                           "T-04 abandon with " + key)
        check(value in refusal.stderr, "T-04 names the evidence path for " + key)
        # Callers branch on this exact marker to tell a refusal from an environment
        # failure, so a refusal that loses it would be read as "helper unavailable".
        check("ERROR: review-cycle: " in refusal.stderr,
              "T-04 refusal carries the rejection-only marker for " + key)

    # A saved receipt on disk is evidence even when the state forgot its path.
    fresh_collecting(pr=95, issue=95)
    context = state()["review_cycle"]["review_context"]
    results = root / ".rite/review-results"
    results.mkdir(parents=True, exist_ok=True)
    receipt = results / "95-20260101000000.json"
    dump(receipt, dict(schema_version="1.1.0", pr_number=95, timestamp="2026-01-01T00:00:00Z",
                       commit_sha=context["commit_sha"], reviewers=selected,
                       review_context=dict(context), verdict="mergeable",
                       measured_gate=dict(commit_sha=context["commit_sha"]),
                       findings=[], non_blocking_findings=[]))
    refusal = rejected(["review-abandon", "--reason", "should not pass"], "T-04 abandon with saved receipt")
    check(str(receipt) in refusal.stderr, "T-04 names the saved receipt path")
    receipt.unlink()

    # A stagnation-tracked run outlives the cycle it froze. This is the shape the
    # real workflow produces (Issue-linked reviews always pass --stagnation), and
    # everything downstream of the abandon has to keep working on it.
    fresh_collecting(pr=99, issue=99)
    flow("review-start", "--selection", selection, "--stagnation")
    check(state()["review_run"]["status"] == "active", "fixture arms a stagnation run")
    run_id = state()["review_run"]["run_id"]
    counter = state()["cycle_count"]
    commit("move HEAD with a run in flight")
    flow("review-abandon", "--reason", "restart with the run retained")
    check("review_run" in state(), "abandon keeps the stagnation run")

    # The reported breakage: every ordinary set was refused while the run had no
    # frozen cycle, including the one /rite:recover uses to restore `active`.
    flow("deactivate")
    flow("set", "--phase", "pr", "--next", "resume", "--active", "true", "--if-exists")
    check(state()["active"] is True, "recover restores active after abandon")
    flow("set", "--phase", "pr", "--next", "still here")
    check(len(state()["review_cycle_abandoned"]) == 1, "ordinary set keeps the abandonment record")

    # The retry is the same run at the same counter, so the run stays usable.
    resumed_head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    flow("review-start", "--selection", selection, "--stagnation")
    resumed = state()
    check(resumed["review_cycle"]["status"] == "collecting", "review-start works with a retained run")
    check(resumed["review_cycle"]["review_context"]["run_id"] == run_id,
          "the retry inherits the retained run_id")
    check(resumed["review_run"]["run_id"] == run_id, "the run itself is untouched")
    check(resumed["cycle_count"] == counter, "the retry keeps the counter")
    check(resumed["review_cycle"]["review_context"]["commit_sha"] == resumed_head,
          "the retry freezes the current HEAD")
    # A run/context pairing that disagrees makes every later stagnation call fail,
    # so prove one of them actually goes through.
    clock = root / "clock.json"
    dump(clock, dict(review_context=resumed["review_cycle"]["review_context"], segment_id="probe",
                     kind="work", started_at="2026-01-01T00:00:00Z", ended_at="2026-01-01T00:01:00Z"))
    flow("review-clock", "--input", clock)
    check(len(state()["review_run"]["clock"]) == 1, "the resumed run accepts a clock segment")

    # The abandonment record is what makes a cycle-less run legitimate. Without it,
    # or with one that disagrees, the shape is corruption and must be refused —
    # otherwise the tolerance added for abandon becomes a hole in the run guard.
    commit("move HEAD for the corruption probe")
    flow("review-abandon", "--reason", "drop again for the corruption probe")
    abandoned_state = json.loads(state_path.read_text())
    for mutate, label, diagnostic in (
        (lambda s: s.pop("review_cycle_abandoned"), "missing abandonment record",
         "review run without a frozen cycle requires an abandonment record"),
        (lambda s: s.__setitem__("review_cycle_abandoned", []), "empty abandonment history",
         "review run without a frozen cycle requires an abandonment record"),
        (lambda s: s.__setitem__("review_run", "not-a-dict"), "malformed review run",
         "review run must be an object"),
        (lambda s: s["review_cycle_abandoned"][-1].pop("review_context"), "record without a context",
         "abandonment record must carry its review context"),
        (lambda s: s["review_run"].pop("issue_number"), "run missing a cross-checked field",
         "review run is missing issue_number"),
        (lambda s: s["review_cycle_abandoned"][-1]["review_context"].pop("cycle_count"),
         "record missing a cross-checked field", "abandonment record is missing cycle_count"),
        (lambda s: s["review_cycle_abandoned"][-1]["review_context"].update(run_id="bogus"),
         "abandonment record from another run",
         "abandonment record does not match the retained review run"),
        # The equality chain cross-checks five fields; the two below and the run's
        # own issue_number were the ones no shape reached, so each could be
        # deleted with the suite still green. They are what keeps a record
        # written for another session or another PR from legitimizing this run.
        (lambda s: s["review_cycle_abandoned"][-1]["review_context"].update(session_id="other-session"),
         "abandonment record from another session",
         "abandonment record does not match the retained review run"),
        (lambda s: s["review_cycle_abandoned"][-1]["review_context"].update(pr_number=1234),
         "abandonment record from another PR",
         "abandonment record does not match the retained review run"),
        (lambda s: s["review_run"].update(issue_number=1234),
         "run naming another Issue",
         "abandonment record does not match the retained review run"),
        (lambda s: s["review_cycle_abandoned"][-1]["review_context"].update(cycle_count=99),
         "abandonment record from another cycle",
         "abandonment record does not match the retained review run"),
        (lambda s: s["review_run"].update(status="bogus"), "invalid run status",
         "invalid review run status"),
        (lambda s: s["review_run"].pop("observations"), "run missing its history",
         "missing run history: observations"),
        (lambda s: s["review_run"].update(diagnosed_work_seconds=-1), "negative diagnostic clock",
         "invalid diagnostic clock"),
    ):
        corrupted = copy.deepcopy(abandoned_state)
        mutate(corrupted)
        dump(state_path, corrupted)
        refusal = rejected(["set", "--phase", "pr", "--next", "should fail"], label)
        # Pin the reason, not just the refusal: a guard that rejects for an
        # unrelated reason (a KeyError on the way past a dropped check) is not
        # the guard this shape needs.
        check(diagnostic in refusal.stderr, label + " names its reason")
        # These refusals are raised inside review-stagnation, which reaches
        # require() by importing this file under its own name. iterate tells a
        # refusal from an environment failure by the prefix alone, so one that
        # arrives without it is read as a broken plugin and stops the loop on the
        # wrong diagnosis. T-04 pins the prefix on the local path; this is the
        # half that travels through the import.
        check("ERROR: review-cycle: " in refusal.stderr,
              label + " carries the rejection-only marker through the import")
    dump(state_path, abandoned_state)
    flow("set", "--phase", "pr", "--next", "intact again")
    # Two abandonments in one state file: the record is append-only, so replacing
    # the append with a single-element assignment has to be observable. Nothing
    # above reaches a second abandonment on the same file, so pin it here.
    history = state()["review_cycle_abandoned"]
    check(len(history) == 2, "abandonments accumulate rather than replace")
    check([r["reason"] for r in history]
          == ["restart with the run retained", "drop again for the corruption probe"],
          "abandonments accumulate in order")

    # Advancing to fix/ready is still refused — an abandoned cycle leaves no
    # verified receipt — but the run does exist, so the reason must say so.
    refusal = rejected(["set", "--phase", "fix", "--next", "fix"], "fix transition after abandon")
    check("abandoned review has no verified receipt" in refusal.stderr,
          "fix transition after abandon names the missing receipt")

    # T-06 on the shape the real workflow produces. Without this the session is
    # locked out of every other Issue for good, which is the half of the Issue
    # the non-stagnation T-06 above cannot observe.
    flow("set", "--phase", "init", "--issue", 98, "--pr", 0, "--branch", "fix/issue-98-z",
         "--next", "branch")
    switched = state()
    check(switched["issue_number"] == 98 and switched["pr_number"] == 0,
          "T-06 another issue can be initialized after abandon with a run")
    check("review_run" not in switched, "the retained run leaves the live slot on switch")
    check(len(switched["review_run_history"]) == 1, "the retained run is archived, not dropped")
    check(len(switched["review_cycle_abandoned"]) == 2,
          "the abandonment history survives the switch")
    check(switched["cycle_count"] == 0, "the new Issue starts at a zero counter")

    # The counter the abandoned run reached is the only copy: dropping the cycle
    # left no frozen context to read it back from. Parking is what carries it,
    # and coming back is what spends it — without the round trip the breaker
    # budget restarts on a PR that already used part of it.
    archived = switched["review_run_history"][-1]
    check(isinstance(archived.get("parked"), dict),
          "the archived retained run carries its parked counter")
    parked_counter = archived["parked"]["cycle_count"]
    check(parked_counter > 0,
          "parking stores the counter the run reached, not the zero the switch wrote")
    check("review_cycle" not in archived["parked"],
          "a run whose cycle was abandoned parks without one")

    flow("set", "--phase", "pr", "--issue", 99, "--pr", 99, "--branch", "fix/issue-99-x",
         "--next", "review")
    returned = state()
    check(returned["review_run"]["run_id"] == archived["run_id"],
          "returning to the PR brings back the same run rather than minting one")
    check(returned["cycle_count"] == parked_counter, "the counter survives the round trip")
    check(len(returned["review_run"]["observations"]) == len(archived["observations"]),
          "the observations the breaker reads survive with it")
    check(returned.get("stop_reason") is None and returned.get("active") is not False,
          "a run parked while active comes back the way it left")
    check(not returned.get("review_run_history"),
          "the restored run leaves the history rather than being counted twice")

    # The exclusion reads the other way around — anything not settled by close or
    # defer reaches the restore — so the shapes that are neither settled nor
    # legitimate have to be named rather than let through. Park the run again and
    # corrupt the archive to reach them.
    flow("set", "--phase", "init", "--issue", 98, "--pr", 0, "--branch", "fix/issue-98-z",
         "--next", "branch")
    parked_state = state()

    for mutate, label, diagnostic in (
        (lambda s: s["review_run_history"][-1].update(status="bogus"),
         "archived run with an unknown status",
         "archived review run for this PR has an unknown status"),
        (lambda s: s["review_cycle_abandoned"].clear(),
         "active archived run with no abandonment record",
         "archived review run for this PR has no frozen cycle and no abandonment record"),
    ):
        corrupted = copy.deepcopy(parked_state)
        mutate(corrupted)
        dump(state_path, corrupted)
        refusal = rejected(["set", "--phase", "pr", "--issue", 99, "--pr", 99,
                            "--branch", "fix/issue-99-x", "--next", "review"], label)
        check(diagnostic in refusal.stderr, label + " names its reason")
    dump(state_path, parked_state)
    flow("set", "--phase", "pr", "--issue", 99, "--pr", 99, "--branch", "fix/issue-99-x",
         "--next", "review")

    # --- regression: abandon must not become a bypass ------------------------
    # Without abandoning, a HEAD-changed collecting cycle is still refused by
    # review-start. The new escape route is the only way past it, and it is the
    # evidence check above that keeps it from swallowing a real review.
    fresh_collecting(pr=98, issue=98)
    commit("move HEAD without abandoning")
    refusal = rejected(["review-start", "--selection", selection],
                       "HEAD-changed collecting cycle without abandon")
    check("HEAD changed during incomplete review" in refusal.stderr,
          "regression keeps the original HEAD-change diagnostic")

    # --- no-op: nothing to abandon reports and succeeds ----------------------
    flow("review-abandon", "--reason", "drop the cycle")
    before_noop = state_path.read_bytes()
    noop = flow("review-abandon", "--reason", "nothing left")
    check("REVIEW_ABANDON=noop" in noop.stderr, "second abandon reports the no-op")
    check(state_path.read_bytes() == before_noop, "no-op abandon leaves the state byte-identical")

    # --reason is the record; an empty one cannot stand in for it.
    fresh_collecting(pr=96, issue=96)
    for args, label in ((["review-abandon", "--reason", "   "], "blank reason"),
                        (["review-abandon"], "missing reason")):
        refusal = rejected(args, label)
        check("--reason must record why the cycle is abandoned" in refusal.stderr,
              label + " names the reason requirement")

    if probe:
        sys.exit(0)

    # --- T-07: a failed write preserves the previous state -------------------
    fresh_collecting(pr=97, issue=97)
    before_bytes = state_path.read_bytes()
    sessions = state_path.parent
    mode = sessions.stat().st_mode
    os.chmod(sessions, mode & ~stat.S_IWUSR)
    try:
        failed = flow("review-abandon", "--reason", "write will fail", ok=False)
        writable = os.access(sessions, os.W_OK)
    finally:
        os.chmod(sessions, mode)
    if writable:
        # Running as root defeats the permission bit; the case cannot be staged.
        # Say so on stderr — a silent pass here reads identically to a real one.
        print("T-07 SKIPPED: sessions dir stayed writable (running as root?)", file=sys.stderr)
        check(True, "T-07 skipped: directory stayed writable")
    else:
        check(failed.returncode != 0, "T-07 failed write exits nonzero")
        check("ERROR:" in failed.stderr, "T-07 failed write is diagnosed")
        check(state_path.read_bytes() == before_bytes, "T-07 failed write preserves the old state")
        check("review_cycle" in state(), "T-07 the cycle survives a failed abandon")

    # A mutation that drops the evidence guard must make this suite's probe fail.
    mutant = root / "mutant-hooks"
    shutil.copytree(hooks, mutant)
    helper = mutant / "scripts/lib/review-cycle.py"
    helper.write_text(helper.read_text().replace(
        '    receipt = matching_receipt(directory, cycle)\n'
        '    require(receipt is None,',
        '    receipt = None\n'
        '    require(receipt is None,', 1))
    mutation = run(["bash", str(Path(sys.argv[2]).resolve()), "--guard-probe", str(mutant)], ok=False)
    check(mutation.returncode != 0 and "T-04 abandon with saved receipt must fail" in mutation.stderr,
          "receipt-guard removal fails behavioral regression")
print("review-cycle-abandon: " + str(checks) + " checks passed")
PYTEST
