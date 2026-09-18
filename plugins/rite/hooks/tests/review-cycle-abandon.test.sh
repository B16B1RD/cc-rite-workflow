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

    # A stagnation-tracked run outlives the cycle it froze: abandoning leaves the
    # run with no frozen counterpart, and review-start still has to accept that.
    fresh_collecting(pr=99, issue=99)
    flow("review-start", "--selection", selection, "--stagnation")
    check(state()["review_run"]["status"] == "active", "fixture arms a stagnation run")
    commit("move HEAD with a run in flight")
    flow("review-abandon", "--reason", "restart with the run retained")
    check("review_run" in state(), "abandon keeps the stagnation run")
    flow("review-start", "--selection", selection, "--stagnation")
    check(state()["review_cycle"]["status"] == "collecting", "review-start works with a retained run")

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
    rejected(["review-abandon", "--reason", "   "], "blank reason")
    rejected(["review-abandon"], "missing reason")

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
