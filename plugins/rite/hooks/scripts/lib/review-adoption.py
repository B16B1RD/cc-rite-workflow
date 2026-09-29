#!/usr/bin/env python3
"""Decide one exit per root cause for review candidates that are not fixed as blocking.

The classifier writes one record per root cause into the classification map under
``adoption``. This helper verifies every record against the candidate set, the reviewed
commit, the PR diff and the cited contracts, then returns one exit per record. It never
writes: every input stays byte-identical. Semantic causality and root-cause identity are
the classifier's judgment; this helper checks only that citations, diff positions, the
reviewed commit and the required fields exist.

Usage:
  review-adoption-check.sh --classification MAP --candidates JSON --review-result JSON \
    --base REF [--ac-ids AC-1,AC-2] [--issue-body FILE] [--pr-body FILE] [--ledger FILE] \
    [--repo-root DIR]

  --candidates    {"candidates": [{"id": "F-03", ...}, ...]}. Keys other than id are
                  ignored, so severity and consequence class never change an exit.
  --review-result the saved review JSON; its commit_sha must equal adoption.head.
  --base          the PR base ref; origin=pr diff positions are looked up in
                  `git diff -U0 BASE...HEAD`.
  --ac-ids        the stdout of `acceptance-criteria-check.sh extract` (empty = no AC).
  --ledger        the 却下台帳 section (`nb-sweep-ledger.sh extract` output).

Record (classification map ``adoption.records[]``; ``adoption.head`` = reviewed commit):
  ids          non-empty list of candidate ids sharing one root cause
  V / C / T    true / false / "unknown" (misbehaviour / unmet contract / wrong test)
  contract     {"ref": "AC-N"} | {"ref": "path:line", "text": ...} |
               {"ref": "issue" | "pr", "text": ...}; required when any of V/C/T is true.
               A line carrying `<!-- rite:deferred-defect` cannot be cited.
  evidence     reproduction or static counterexample; required when any of V/C/T is true
               and when present is false
  origin       "pr" | "pre_existing" | "unknown"
  origin_cause required when origin is "pr": {"diff": ["path:+N" | "path:-N", ...],
               "path": <behaviour difference or causal path>} (+N is a line the PR added,
               -N a line it removed), or {"contract": <AC / issue / pr citation of a
               requirement the Issue or PR accepted>}
  present      whether the root cause remains at the reviewed commit (boolean)
  tracker      null or the number of an Issue already tracking this root cause
  prior        null or {"finding_id", "file_line", "disposition", "premise"}: a ledger row
               whose 判定 cell equals disposition. REJECT and ADOPT are the terminal
               dispositions this helper compares against. The sweep writes issued
               (filed), REJECT / RESOLVED / LINK (exits recorded without filing) and
               recorded (guardrail transcription); issued, recorded and the older
               rejected rows are not terminal, and RESOLVED / LINK rows are never a prior.
  reason       why not adopted and when to reconsider; required when any of V/C/T is
               "unknown", and REJECT needs it
  proposition  {"claim", "reach", "reach_source", "done"} for an investigation
  investigate  true when the classifier accepts the record as an investigation

Exits, evaluated top-down per record (a record takes the first that applies):
  RECONCILE  a candidate id is in more than one record, or prior is REJECT while any of
             V/C/T is true, or prior is ADOPT while V=C=T=false
  RESOLVED   present is false
  LINK       tracker is an OPEN Issue (a CLOSED tracker is ignored)
  ADOPT      any of V/C/T is true
  DIAGNOSE   any of V/C/T is "unknown"
  REJECT     V=C=T=false and reason is non-empty
  otherwise  ERROR (reason=no_exit)

stdout on success: {"head": SHA, "decisions": [{"ids", "exit", "origin", "action", "file",
  "pr_blocking", "tracker"}, ...]} in record order, ids in input order.
  action: RECONCILE arbitrate; RESOLVED record_resolved; LINK link; ADOPT fix_in_pr (pr) /
  file_issue (pre_existing) / hold_pr (unknown); DIAGNOSE hold_pr (pr, unknown) /
  investigate (pre_existing with investigate=true and all four proposition items) / hold;
  REJECT record_rejected.
  file is true only for file_issue and investigate: nothing else may be filed externally.
  pr_blocking is true for arbitrate, fix_in_pr and hold_pr, and for LINK when origin is pr
  or unknown: the PR must not be completed while any decision has it.
stdout on ERROR: {"errors": [{"reason", "ids", "detail"}, ...]}.
stderr:
  [CONTEXT] REVIEW_ADOPTION=ok; decisions=N; file=K; pr_blocking=M
  [CONTEXT] REVIEW_ADOPTION=error; reason=REASON; ids=ID,...   (the first error)

Reason SoT:
  input_invalid          unreadable or malformed input, duplicate candidate id
  head_mismatch          adoption.head differs from the review's commit_sha
  git_failed             git ls-tree / show / diff failed for the head, base or cited path
  candidates_uncovered   candidates no record covers (ids lists them)
  unknown_candidate      a record id that is not a candidate
  record_invalid         ids / origin / present / tracker / prior field malformed
  vct_invalid            V, C or T is not true / false / "unknown"
  contract_missing       any of V/C/T is true but contract is absent
  evidence_missing       evidence is empty where it is required
  contract_not_found     the cited AC-N, file line text or body text does not exist
  contract_deferred      the citation is, or quotes, a deferred-token line
  origin_cause_missing   origin is pr without a diff position with a path or a contract
  origin_cause_not_found an origin_cause diff position is not in the PR diff
  reason_missing         any of V/C/T is "unknown" but reason is empty
  tracker_unavailable    the tracker state could not be read
  prior_not_found        prior does not match a ledger row or premise is empty
  no_exit                no exit applies (V=C=T=false without reason)

Exit codes: 0 decided, 1 ERROR, 2 usage.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ORIGINS = ("pr", "pre_existing", "unknown")
PRIORS = ("REJECT", "ADOPT", "issued", "recorded", "rejected")
DEFERRED = re.compile(r"<!--\s*rite:deferred-defect\b")
FILE_LINE = re.compile(r"^(.+):([1-9][0-9]*)$")
DIFF_AT = re.compile(r"^(.+):([+-])([1-9][0-9]*)$")
HUNK = re.compile(r"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@")
PROPOSITION = ("claim", "reach", "reach_source", "done")


class Stop(Exception):
    def __init__(self, reason, ids=(), detail=""):
        super().__init__(reason)
        self.reason, self.ids, self.detail = reason, list(ids), detail


class Errors(Exception):
    def __init__(self, errors):
        super().__init__(errors[0].reason)
        self.errors = errors


def text(value):
    return isinstance(value, str) and value.strip() != ""


def load(path, label):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Stop("input_invalid", detail=f"{label}: {error}") from None


def read_text(path, label):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise Stop("input_invalid", detail=f"{label}: {error}") from None


class Repo:
    def __init__(self, root, head, base):
        self.root, self.head, self.base = root, head, base
        self._files, self._hunks = {}, None

    def git(self, *args):
        result = subprocess.run(["git", "-C", self.root, *args], capture_output=True, text=True)
        if result.returncode != 0:
            raise Stop("git_failed", detail=f"git {' '.join(args)}: {result.stderr.strip()}")
        return result.stdout

    def lines(self, path):
        # None only when the path is not a file at the head; any other git failure is git_failed.
        if path not in self._files:
            # ls-tree lists the children of a directory path, so only an entry named exactly
            # like the path counts: "mode type sha\tname" per NUL-separated entry.
            entries = [e.split("\t", 1) for e in self.git("ls-tree", "-z", self.head, "--", path).split("\0") if e]
            is_file = any(len(e) == 2 and e[1] == path and e[0].split()[1] == "blob" for e in entries)
            self._files[path] = self.git("show", f"{self.head}:{path}").split("\n") if is_file else None
        return self._files[path]

    def hunks(self):
        # (path, side) -> [(first, last)]; side "-" holds removed old lines, "+" added new lines.
        if self._hunks is None:
            self._hunks = {}
            old = new = None
            in_hunk = False
            # The user's diff.noprefix, diff.interHunkContext (merges nearby hunks with the unchanged
            # lines between them) and textconv drivers change the output.
            diff = self.git("-c", "core.quotePath=false", "diff", "-U0", "--inter-hunk-context=0", "--no-color",
                            "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                            f"{self.base}...{self.head}")
            # --- / +++ are file headers only between "diff --git" and the first @@: with -U0 a
            # removed "-- x" or added "++ x" content line also starts with "--- " / "+++ ".
            for line in diff.split("\n"):
                if line.startswith("diff --git "):
                    old = new = None
                    in_hunk = False
                elif not in_hunk and line.startswith("--- "):
                    old = line[6:].split("\t")[0] if line.startswith("--- a/") else None
                elif not in_hunk and line.startswith("+++ "):
                    new = line[6:].split("\t")[0] if line.startswith("+++ b/") else None
                else:
                    match = HUNK.match(line)
                    if not match:
                        continue
                    in_hunk = True
                    for path, side, start, count in ((old, "-", match[1], match[2]),
                                                     (new, "+", match[3], match[4])):
                        size = 1 if count is None else int(count)
                        if path is not None and size > 0:
                            self._hunks.setdefault((path, side), []).append(
                                (int(start), int(start) + size - 1))
        return self._hunks


def check_contract(contract, context, ids, accepted_only=False):
    if not isinstance(contract, dict) or not text(contract.get("ref")):
        raise Stop("contract_not_found", ids, "contract needs a ref")
    ref, quote = contract["ref"], contract.get("text")
    if re.fullmatch(r"AC-[1-9][0-9]*", ref):
        if ref not in context["ac_ids"]:
            raise Stop("contract_not_found", ids, f"{ref} is not in the acceptance criteria")
        return
    if not text(quote):
        raise Stop("contract_not_found", ids, f"{ref} needs the quoted text")
    if DEFERRED.search(quote):
        raise Stop("contract_deferred", ids, f"{ref} quotes a deferred-token line")
    if ref in ("issue", "pr"):
        body = context["bodies"].get(ref)
        found = [line for line in (body or "").split("\n") if quote in line]
        if not found:
            raise Stop("contract_not_found", ids, f"quoted text is not in the {ref} body")
        if any(DEFERRED.search(line) for line in found):
            raise Stop("contract_deferred", ids, f"the {ref} line quoted carries a deferred token")
        return
    match = FILE_LINE.match(ref)
    if accepted_only or not match:
        raise Stop("contract_not_found", ids, f"{ref} is not a citable contract")
    lines = context["repo"].lines(match[1])
    number = int(match[2])
    if lines is None or number > len(lines) or quote not in lines[number - 1]:
        raise Stop("contract_not_found", ids, f"{ref} does not contain the quoted text at the head")
    if DEFERRED.search(lines[number - 1]):
        raise Stop("contract_deferred", ids, f"{ref} carries a deferred token")


def check_origin(record, context, ids):
    cause = record.get("origin_cause")
    if not isinstance(cause, dict):
        raise Stop("origin_cause_missing", ids, "origin=pr needs origin_cause")
    diff = cause.get("diff")
    if isinstance(diff, list) and diff and text(cause.get("path")):
        hunks = context["repo"].hunks()
        for position in diff:
            match = DIFF_AT.match(position) if isinstance(position, str) else None
            if not match:
                raise Stop("origin_cause_missing", ids, f"malformed diff position {position!r}")
            number = int(match[3])
            if not any(first <= number <= last for first, last in hunks.get((match[1], match[2]), ())):
                raise Stop("origin_cause_not_found", ids, f"{position} is not in the PR diff")
        return
    if "contract" in cause:
        ref = cause["contract"].get("ref") if isinstance(cause["contract"], dict) else None
        if not (isinstance(ref, str) and (ref in ("issue", "pr") or re.fullmatch(r"AC-[1-9][0-9]*", ref))):
            raise Stop("origin_cause_missing", ids, "origin_cause.contract must cite an accepted requirement")
        check_contract(cause["contract"], context, ids, accepted_only=True)
        return
    raise Stop("origin_cause_missing", ids, "origin_cause needs a diff position with a path or a contract")


def ledger_rows(ledger):
    rows = set()
    for line in (ledger or "").split("\n"):
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in re.split(r"(?<!\\)\|", line.strip("|"))]
        if len(cells) >= 3 and cells[0] != "finding_id" and not re.fullmatch(r"[-: ]*", cells[0]):
            rows.add((cells[0], cells[1], cells[2]))
    return rows


def validate(record, context):
    ids = record["ids"]
    values = [record.get(axis) for axis in "VCT"]
    if not all(value is True or value is False or value == "unknown" for value in values):
        raise Stop("vct_invalid", ids, "V, C and T must be true, false or \"unknown\"")
    if record.get("origin") not in ORIGINS:
        raise Stop("record_invalid", ids, "origin must be pr, pre_existing or unknown")
    if not isinstance(record.get("present"), bool):
        raise Stop("record_invalid", ids, "present must be a boolean")
    tracker = record.get("tracker")
    if tracker is not None and (isinstance(tracker, bool) or not isinstance(tracker, int) or tracker < 1):
        raise Stop("record_invalid", ids, "tracker must be null or a positive Issue number")
    if True in values:
        if record.get("contract") is None:
            raise Stop("contract_missing", ids, "a true V/C/T needs a contract")
        if not text(record.get("evidence")):
            raise Stop("evidence_missing", ids, "a true V/C/T needs evidence")
    if record.get("contract") is not None:
        check_contract(record["contract"], context, ids)
    if "unknown" in values and not text(record.get("reason")):
        raise Stop("reason_missing", ids, "an unknown V/C/T needs the reason it is undecided")
    if record["present"] is False and not text(record.get("evidence")):
        raise Stop("evidence_missing", ids, "present=false needs the evidence of the resolution")
    if record["origin"] == "pr":
        check_origin(record, context, ids)
    prior = record.get("prior")
    if prior is not None:
        if not isinstance(prior, dict) or prior.get("disposition") not in PRIORS:
            raise Stop("record_invalid", ids, "prior needs a known disposition")
        key = (prior.get("finding_id"), prior.get("file_line"), prior["disposition"])
        if not text(prior.get("premise")) or key not in context["ledger"]:
            raise Stop("prior_not_found", ids, "prior does not match a ledger row with a premise")


def tracker_state(number, context):
    if number not in context["trackers"]:
        result = subprocess.run(["gh", "issue", "view", str(number), "--json", "state", "--jq", ".state"],
                                cwd=context["repo"].root, capture_output=True, text=True)
        state = result.stdout.strip()
        if result.returncode != 0 or state not in ("OPEN", "CLOSED"):
            raise Stop("tracker_unavailable", detail=f"tracker {number}: {result.stderr.strip() or state}")
        context["trackers"][number] = state
    return context["trackers"][number]


def decide(record, contested, context):
    values = [record[axis] for axis in "VCT"]
    origin, prior = record["origin"], record.get("prior")
    disposition = prior["disposition"] if prior else None
    tracker = record.get("tracker")
    if (contested or disposition == "REJECT" and True in values
            or disposition == "ADOPT" and values == [False, False, False]):
        exit, action = "RECONCILE", "arbitrate"
    elif record["present"] is False:
        exit, action = "RESOLVED", "record_resolved"
    elif tracker is not None and tracker_state(tracker, context) == "OPEN":
        exit, action = "LINK", "link"
    elif True in values:
        exit, action = "ADOPT", {"pr": "fix_in_pr", "pre_existing": "file_issue", "unknown": "hold_pr"}[origin]
    elif "unknown" in values:
        exit = "DIAGNOSE"
        proposition = record.get("proposition")
        accepted = (record.get("investigate") is True and isinstance(proposition, dict)
                    and all(text(proposition.get(item)) for item in PROPOSITION))
        action = "hold_pr" if origin != "pre_existing" else "investigate" if accepted else "hold"
    elif text(record.get("reason")):
        exit, action = "REJECT", "record_rejected"
    else:
        raise Stop("no_exit", record["ids"], "V=C=T=false needs a reason to reject")
    blocking = action in ("arbitrate", "fix_in_pr", "hold_pr") or exit == "LINK" and origin != "pre_existing"
    return {"ids": record["ids"], "exit": exit, "origin": origin, "action": action,
            "file": action in ("file_issue", "investigate"), "pr_blocking": blocking,
            "tracker": tracker}


def run(args):
    classification = load(args.classification, "classification")
    adoption = classification.get("adoption") if isinstance(classification, dict) else None
    records = adoption.get("records") if isinstance(adoption, dict) else None
    if not isinstance(records, list) or not text(adoption.get("head")):
        raise Stop("input_invalid", detail="classification needs adoption.head and adoption.records[]")
    document = load(args.candidates, "candidates")
    candidates = document.get("candidates") if isinstance(document, dict) else None
    if not isinstance(candidates, list) or not all(isinstance(item, dict) and text(item.get("id")) for item in candidates):
        raise Stop("input_invalid", detail="candidates needs candidates[] of objects with an id")
    candidate_ids = [item["id"] for item in candidates]
    duplicates = sorted({cid for cid in candidate_ids if candidate_ids.count(cid) > 1})
    if duplicates:
        raise Stop("input_invalid", duplicates, "duplicate candidate id")
    review = load(args.review_result, "review result")
    if not isinstance(review, dict) or review.get("commit_sha") != adoption["head"]:
        raise Stop("head_mismatch", detail="adoption.head differs from the review commit_sha")
    for record in records:
        if not (isinstance(record, dict) and isinstance(record.get("ids"), list) and record["ids"]
                and all(text(cid) for cid in record["ids"])):
            raise Stop("record_invalid", detail="every record needs a non-empty ids list")

    ac_ids = [item for item in (args.ac_ids or "").split(",") if item]
    context = {
        "ac_ids": set(ac_ids),
        "bodies": {"issue": args.issue_body and read_text(args.issue_body, "issue body"),
                   "pr": args.pr_body and read_text(args.pr_body, "pr body")},
        "ledger": ledger_rows(args.ledger and read_text(args.ledger, "ledger")),
        "repo": Repo(args.repo_root, adoption["head"], args.base),
        "trackers": {},
    }
    errors = []
    covered = [cid for record in records for cid in record["ids"]]
    missing = [cid for cid in candidate_ids if cid not in covered]
    if missing:
        errors.append(Stop("candidates_uncovered", missing, "every candidate needs a record"))
    unknown = [cid for cid in dict.fromkeys(covered) if cid not in candidate_ids]
    if unknown:
        errors.append(Stop("unknown_candidate", unknown, "record ids must be candidates"))
    for record in records:
        try:
            validate(record, context)
        except Stop as error:
            error.ids = error.ids or record["ids"]
            errors.append(error)
    if errors:
        raise Errors(errors)
    contested = {cid for cid in covered if covered.count(cid) > 1}
    decisions = []
    for record in records:
        try:
            decisions.append(decide(record, contested & set(record["ids"]), context))
        except Stop as error:
            error.ids = error.ids or record["ids"]
            errors.append(error)
    if errors:
        raise Errors(errors)
    return {"head": adoption["head"], "decisions": decisions}


def main():
    parser = argparse.ArgumentParser(prog="review-adoption-check.sh")
    parser.add_argument("--classification", required=True)
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--review-result", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--ac-ids", default="")
    parser.add_argument("--issue-body")
    parser.add_argument("--pr-body")
    parser.add_argument("--ledger")
    parser.add_argument("--repo-root", default=".")
    args = parser.parse_args()
    try:
        result = run(args)
    except Stop as error:
        errors = [error]
    except Errors as bundle:
        errors = bundle.errors
    else:
        decisions = result["decisions"]
        print(json.dumps(result, ensure_ascii=False))
        print(f"[CONTEXT] REVIEW_ADOPTION=ok; decisions={len(decisions)}; "
              f"file={sum(d['file'] for d in decisions)}; "
              f"pr_blocking={sum(d['pr_blocking'] for d in decisions)}", file=sys.stderr)
        return 0
    print(json.dumps({"errors": [{"reason": e.reason, "ids": e.ids, "detail": e.detail} for e in errors]},
                     ensure_ascii=False))
    for error in errors:
        print(f"ERROR: {error.reason}: {error.detail}", file=sys.stderr)
    first = errors[0]
    print(f"[CONTEXT] REVIEW_ADOPTION=error; reason={first.reason}; ids={','.join(first.ids)}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
