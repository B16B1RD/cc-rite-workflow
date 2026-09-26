#!/usr/bin/env bash
# Integration: real completion checker, measured gate, saver and flow-state CLI.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/.." "$0" "$@" <<'PYTEST'
import copy
import json
import os
from pathlib import Path
import shutil
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


with tempfile.TemporaryDirectory(prefix="rite-review-cycle-") as tmp:
    root = Path(tmp)
    env = dict(os.environ)
    for key in ("CODEX_THREAD_ID", "GROK_SESSION_ID", "CLAUDE_SESSION_ID", "CLAUDE_CODE_SESSION_ID",
                "RITE_HOST", "RITE_STATE_ROOT", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        env.pop(key, None)
    env.update(RITE_HOST="claude", CLAUDE_CODE_SESSION_ID="review-cycle-test", RITE_STATE_ROOT=tmp, TMPDIR=tmp)

    def run(command, ok=True, **kwargs):
        result = subprocess.run(command, cwd=root, env=env, text=True, errors="replace", capture_output=True, **kwargs)
        if ok:
            check(result.returncode == 0, "command failed: " + repr(command) + "\n" + result.stderr)
        return result

    def flow(*args, ok=True):
        return run(["bash", str(hooks / "flow-state.sh"), *map(str, args)], ok)

    run(["git", "init", "-q"])
    run(["git", "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "--allow-empty", "-m", "initial"])
    state_path = root / ".rite/sessions/review-cycle-test.flow-state"
    state = lambda: json.loads(state_path.read_text())
    cycle = lambda: state()["review_cycle"]
    results = root / ".rite/review-results"
    saved_files = lambda: list(results.glob("71-*.json"))

    def rejected(args, label, unchanged=True):
        before = state_path.read_bytes()
        result = flow(*args, ok=False)
        check(result.returncode != 0, label + " must fail")
        check("ERROR:" in result.stderr, label + " diagnostic")
        if unchanged:
            check(state_path.read_bytes() == before, label + " state unchanged")
        return result

    # Omitting review-start entirely cannot advance an existing PR workflow.
    flow("set", "--phase", "pr", "--next", "review", "--pr", 71)
    for phase in ("fix", "ready"):
        rejected(["set", "--phase", phase, "--next", phase], "pr skips review-start to " + phase)
    initial_selection = root / "initial-selection.json"
    dump(initial_selection, ["code-quality-reviewer"])
    flow("review-start", "--selection", initial_selection)
    check(state()["cycle_count"] == 1, "fresh pr starts first review cycle")
    state_path.unlink()  # Separate legacy-state fixture.
    # Old untracked review cannot bypass collection by changing phase or counter.
    flow("set", "--phase", "review", "--next", "review", "--pr", 71, "--cycle-count", 3)
    rejected(["set", "--phase", "fix", "--next", "fix"], "unmanaged review to fix")
    if probe:
        sys.exit(0)
    for phase in ("ready", "lint", "pr"):
        rejected(["set", "--phase", phase, "--next", phase], "unmanaged review to " + phase)
    rejected(["set", "--phase", "review", "--next", "review", "--cycle-count", 4], "unmanaged next cycle")
    flow("set", "--phase", "review", "--next", "diagnose", "--active", "false", "--stop-reason", "review:error")
    selected = ["security-reviewer", "code-quality-reviewer", "acceptance-reviewer"]
    selection = root / "selection.json"
    for invalid in ([], [selected[0], selected[0]], ["bad name"]):
        dump(selection, invalid)
        rejected(["review-start", "--selection", selection], "invalid selection")
    dump(selection, selected)
    flow("review-start", "--selection", selection)
    check(state()["cycle_count"] == 3, "legacy positive cycle adopted exactly once")
    rejected(["review-start", "--selection", selection, "--session", "other-session"], "cannot override runtime identity")
    rejected(["review-start", "--selection", selection, "--state", state_path], "cannot override internal state path")
    first = copy.deepcopy(cycle())
    flow("review-start", "--selection", selection)
    check(cycle() == first, "collecting start replay is unchanged")
    dump(selection, selected[:2])
    rejected(["review-start", "--selection", selection], "cannot shrink finite-wave roster")
    dump(selection, selected)
    other_path = root / ".rite/sessions/other-session.flow-state"
    flow("set", "--session", "other-session", "--phase", "implement", "--next", "implement", "--pr", 88)
    other_before = other_path.read_bytes()
    manifest_file, content_file = root / "manifest.json", root / "result.json"

    def fixtures(blocking=False):
        context = cycle()["review_context"]
        records = []
        for index, name in enumerate(selected):
            raw = root / (name + ".md")
            raw.write_text("### 評価: 可\n### 所見\nChecked.\n### 指摘事項\nNone.\n### 監査ログ\nNone.\n")
            records.append(dict(reviewer=name, agent_id="child-" + str(index), status="completed",
                                started_at="2026-01-01T00:00:00Z", ended_at="2026-01-01T00:01:00Z",
                                output_file=str(raw), review_context=dict(context)))
        manifest = dict(schema_version=1, parent_agent_id="review-cycle-test", selected_reviewers=selected,
                        reviewers=records, review_context=dict(context))
        findings = [dict(id="F-01", reviewer=selected[0], severity="HIGH", file="src/a.py", line=1,
                         description="Verification: repro sample => failed", suggestion="fix", status="open",
                         scope="current-pr")] if blocking else []
        content = dict(schema_version="1.1.0", pr_number=71, timestamp="__RITE_TS_PLACEHOLDER_7f3a9b2c__",
                       commit_sha=context["commit_sha"], reviewers=selected, review_context=dict(context),
                       findings=findings, non_blocking_findings=[], guardrail_audit_log=[])
        dump(content_file, content)
        run(["bash", str(hooks.parent / "scripts/review-measured-gate.sh"), "--input", str(content_file), "--reject-preset-verification"])
        content = json.loads(content_file.read_text())
        dump(manifest_file, manifest)
        return manifest, content

    manifest, content = fixtures(True)
    check(content["verdict"] == "fix-needed", "real measured gate determines blocking verdict")
    finish_args = ["review-finish", "--manifest", manifest_file, "--content-file", content_file]
    for location in ("manifest", "record", "result"):
        for field, invalid in (("session_id", "other-session"), ("run_id", "other-run"), ("pr_number", 72),
                               ("cycle_count", 2), ("commit_sha", "0" * 40)):
            m, c = copy.deepcopy(manifest), copy.deepcopy(content)
            target = m if location == "manifest" else m["reviewers"][0] if location == "record" else c
            target["review_context"][field] = invalid
            dump(manifest_file, m); dump(content_file, c)
            rejected(finish_args, location + " foreign " + field)
    dump(content_file, content)
    for records in (manifest["reviewers"][:1], manifest["reviewers"][:2]):
        m = copy.deepcopy(manifest); m["reviewers"] = records; dump(manifest_file, m)
        error = rejected(finish_args, "partial wave")
        check("acceptance-reviewer" in error.stderr, "missing reviewer named")
    for status in ("running", "failed"):
        m = copy.deepcopy(manifest); m["reviewers"][1]["status"] = status; dump(manifest_file, m)
        error = rejected(finish_args, "reviewer " + status)
        check("code-quality-reviewer" in error.stderr, "incomplete reviewer named")
    dump(manifest_file, manifest)
    for field, invalid in (("verdict", "mergeable"), ("reviewers", selected[:2]), ("commit_sha", "a" * 40)):
        c = copy.deepcopy(content); c[field] = invalid; dump(content_file, c)
        rejected(finish_args, "bad result " + field)
    dump(content_file, content)
    rejected(["set", "--phase", "review", "--next", "review", "--cycle-count", 0], "incomplete counter reset")
    rejected(["set", "--phase", "lint", "--next", "lint"], "intermediate phase bypass")
    # Real saver returns rc=0 on schema failure. Transaction must check actual disk evidence.
    invalid_content = copy.deepcopy(content); invalid_content["guardrail_audit_log"] = [{"wrong": True}]
    dump(content_file, invalid_content)
    error = rejected(finish_args, "nonblocking saver failure", unchanged=False)
    check("JSON_SAVED=false" in error.stderr and not saved_files(), "zero-exit saver did not authorize transition")
    check(cycle()["status"] == "collecting" and state()["cycle_count"] == 3, "save failure preserves cycle")
    check(cycle()["manifest_path"] == str(manifest_file) and cycle()["content_file"] == str(content_file), "recovery evidence paths persisted")
    rejected(["set", "--phase", "fix", "--next", "fix"], "failed save cannot advance")
    dump(content_file, content)
    shutil.rmtree(results)
    results.write_text("unwritable directory fixture")
    error = rejected(finish_args, "filesystem persistence failure", unchanged=False)
    check("JSON_SAVED=false" in error.stderr and cycle()["status"] == "collecting", "physical save failure stays collecting")
    check(json.loads(content_file.read_text()) == content, "save failure preserves collected result")
    results.unlink()
    # Save before state completion emulates interruption exactly at transaction boundary.
    run(["bash", str(hooks / "review-result-save.sh"), "--pr", "71", "--content-file", str(content_file), "--results-dir", str(results)])
    saved_before = {str(path): path.read_bytes() for path in saved_files()}
    broken_foreign = results / "71-unrelated-corrupt.json"
    broken_foreign.write_text("{broken another session history")
    pending = root / "rite-p61a-pending-71-replay"
    pending.write_text("pending")
    replay_result = flow(*finish_args, "--pending-id", "71-replay")
    check(not pending.exists() and "JSON_SAVED=true" in replay_result.stderr
          and "REVIEW_SAVE_DONE=1" in replay_result.stderr, "replay consumes pending marker and emits saver success markers")
    check("[review:" not in replay_result.stdout + replay_result.stderr, "finish never emits outward review sentinel")
    check(broken_foreign.read_text() == "{broken another session history", "unrelated corrupt history remains untouched")
    broken_foreign.unlink()
    check({str(path): path.read_bytes() for path in saved_files()} == saved_before, "saved-before-state replay never saves twice")
    check(cycle()["status"] == "completed" and cycle()["verdict"] == "fix-needed", "finish completed blocking review")
    check(state()["next_action"] == "/rite:fix 71", "finish routes fix")
    flow(*finish_args)
    check(len(saved_files()) == 1 and state()["cycle_count"] == 3, "completed finish replay never adds cycle/result")
    changed_content = copy.deepcopy(content); changed_content["extra"] = "different"; dump(content_file, changed_content)
    rejected(finish_args, "same context different content")
    dump(content_file, content)
    current_receipt = Path(cycle()["result_path"])
    missing_receipt = current_receipt.with_suffix(".missing")
    current_receipt.rename(missing_receipt)
    rejected(["set", "--phase", "fix", "--next", "fix"], "receipt lost before transition")
    rejected(["review-start", "--selection", selection], "receipt lost before next cycle")
    missing_receipt.rename(current_receipt)
    flow("set", "--phase", "fix", "--next", "fix")
    check(cycle()["review_context"] == first["review_context"], "normal set preserves receipt")
    rejected(["set", "--phase", "review", "--next", "review", "--cycle-count", 4], "manual cycle increment")
    rejected(["set", "--phase", "review", "--next", "review"], "completed receipt cannot substitute for next review-start")
    flow("review-start", "--selection", selection)
    check(state()["cycle_count"] == 4 and cycle()["review_context"]["run_id"] == first["review_context"]["run_id"], "next review increments once in same run")
    manifest, content = fixtures()
    content["non_blocking_findings"] = [dict(id="F-02", reviewer=selected[0], severity="LOW", file="src/a.py", line=1,
                                           description="advisory", suggestion="tidy", status="open", scope="nit-noted")]
    dump(content_file, content)
    frozen_head = cycle()["review_context"]["commit_sha"]
    run(["git", "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "--allow-empty", "-m", "changed"])
    rejected(finish_args, "stale finish HEAD")
    rejected(["review-start", "--selection", selection], "stale resume HEAD")
    run(["git", "checkout", "-q", frozen_head])
    flow(*finish_args)
    check(cycle()["verdict"] == "mergeable" and len(saved_files()) == 2, "all reviewers permit mergeable")
    flow("set", "--phase", "fix", "--next", "NB digest sweep")
    run(["git", "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "--allow-empty", "-m", "NB sweep"])
    # State requires the receipt; ready-reviewed-head-gate owns whether this new
    # HEAD has the existing NB sweep marker. No duplicate stricter state gate.
    flow("set", "--phase", "ready", "--next", "merge")
    # Final class policy owns verdict; measured_gate retains the earlier count.
    for partial in (False, True):
        flow("review-start", "--selection", selection)
        manifest, content = fixtures(True)
        if partial:
            second = copy.deepcopy(content["findings"][0]); second["id"] = "F-02"
            content["findings"].append(second)
            dump(content_file, content)
            run(["bash", str(hooks.parent / "scripts/review-measured-gate.sh"), "--input", str(content_file)])
        classification = root / "classes.json"
        classes = [dict(id="F-01", **{"class": "B"}, scenario="documentation consistency")]
        if partial:
            classes.append(dict(id="F-02", **{"class": "B"}, scenario="removed existing requirement", exclusion="existing rule removed"))
        dump(classification, dict(classifications=classes))
        run(["bash", str(hooks.parent / "scripts/review-class-demotion-gate.sh"), "--input", str(content_file), "--classification", str(classification)])
        final = json.loads(content_file.read_text())
        check(final["measured_gate"]["blocking"] > len(final["findings"]), "historical measured count differs from final findings")
        flow(*finish_args)
        check(cycle()["verdict"] == ("fix-needed" if partial else "mergeable"), "class policy verdict preserved")
        count_before = len(saved_files())
        flow(*finish_args)
        check(len(saved_files()) == count_before, "class policy replay does not save twice")
        flow("set", "--phase", "fix" if partial else "ready", "--next", "continue")

    # Existing non-fatal triage deliberately retains the original saved verdict.
    flow("review-start", "--selection", selection)
    manifest, content = fixtures(True)
    content["findings"][0]["severity"] = "MEDIUM"
    content["findings"][0]["consequence_class"] = "B"
    dump(content_file, content)
    flow(*finish_args)
    flow("set", "--phase", "fix", "--next", "triage")
    receipt_path = cycle()["result_path"]
    run(["bash", str(hooks.parent / "scripts/review-findings-maps.sh"), "--review-source", "explicit_file", "--review-source-path", receipt_path])
    triaged = json.loads(Path(receipt_path).read_text())
    check(not triaged["findings"] and triaged["verdict"] == "fix-needed", "real non-fatal triage retains original verdict")
    flow("set", "--phase", "ready", "--next", "merge after sweep")
    flow("set", "--phase", "cleanup", "--next", "cleanup")
    flow("set", "--phase", "completed", "--next", "none", "--active", "false")
    check(other_path.read_bytes() == other_before, "other session byte-identical")
    # Normal/breaker fresh-run reset is only possible after verified completion.
    flow("set", "--phase", "pr", "--next", "review", "--cycle-count", 0)
    flow("review-start", "--selection", selection)
    check(state()["cycle_count"] == 1 and cycle()["review_context"]["run_id"] != first["review_context"]["run_id"], "completed run reset starts new run")
    fixtures()
    flow(*finish_args)
    flow("set", "--phase", "cleanup", "--next", "cleanup")
    shutil.rmtree(results)  # Normal cleanup archives/removes the previous PR JSON.
    flow("set", "--phase", "pr", "--next", "review", "--pr", 72, "--issue", 72, "--cycle-count", 0)
    flow("review-start", "--selection", selection)
    check(cycle()["review_context"]["pr_number"] == 72 and state()["cycle_count"] == 1, "next PR starts after old receipt cleanup")
    check(other_path.read_bytes() == other_before, "next PR still isolates other session")
    # A mutation that removes the runtime guard must make this suite's real CLI probe fail.
    mutant = root / "mutant-hooks"
    shutil.copytree(hooks, mutant)
    helper = mutant / "scripts/lib/review-cycle.py"
    helper.write_text(helper.read_text().replace("def guard_set(path, new, directory):\n", "def guard_set(path, new, directory):\n    return new\n", 1))
    mutation = run(["bash", str(Path(sys.argv[2]).resolve()), "--guard-probe", str(mutant)], ok=False)
    check(mutation.returncode != 0 and "pr skips review-start to fix must fail" in mutation.stderr, "guard-removal mutation fails behavioral regression")
print("review-cycle-transition: " + str(checks) + " checks passed")
PYTEST
