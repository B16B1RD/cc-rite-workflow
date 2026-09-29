#!/usr/bin/env python3
"""Collect the cross-Issue view of a repository and dispose only what the rules decide.

`collect` reads the open Issues, the PRs merged into the base branch, the surviving
follow-up judgment records and the Issue claims, and prints a snapshot. It never writes.
`dispose` recomputes the same disposition set from the same sources (it takes no Issue
numbers) and closes those Issues with the evidence copied verbatim into the closing
comment. Everything else in the snapshot is input for proposals and is never acted on.

Usage:
  issue-audit.sh collect --repo OWNER/REPO --base BRANCH
  issue-audit.sh dispose --repo OWNER/REPO --base BRANCH

Snapshot (collect stdout):
  open_issues    [{number, title, updated_at, stale}] — stale: not updated for STALE_DAYS
  lineage        {"edges": [{child, parent, via}], "chains": [[root, ..., leaf], ...]}
                 via is "issue" (`- 元 Issue: #N`) or "pr:N" (follow-up marker or
                 `- 元 PR: #N` / `- 元の PR: #N`, resolved to the Issues that PR closes).
                 A chain is listed when it holds CHAIN_MIN Issues or more and is not a
                 prefix of another listed chain.
  concentration  [{kind: "file" | "origin_pr", key, issues}] — two or more open Issues
                 that name the same file path or derive from the same PR
  dispositions   [{issue, reason, rule, evidence, duplicate_of}] — see Rules
  excluded       [{issue, rule, why}] — a rule matched but the Issue is not disposed

Rules (the only dispositions; reason is the `gh issue close` reason):
  duplicate_key       two or more open Issues labelled `follow-up` have the same marker
                      `<!-- [rite-follow-up-from-pr:<pr>:<ids>] -->` as their first body line
                      (the line the follow-up filer writes; ids use the filer's characters —
                      letters, digits, `.`, `_`, `-`, `#`, `~` — joined by commas); the lowest
                      number stays open and the others close as duplicate of it
  merged_closing_pr   a PR merged into the base branch says Closes / Fixes / Resolves #N
                      while #N is still open → completed
  record_resolved     a surviving follow-up record has present=false and tracker=N → completed
  record_rejected     a surviving follow-up record has present not false, V=C=T=false, a
                      reason and tracker=N → not planned
  Surviving records are the files named adoption-<pr>-followup.json. A record rule is skipped
  when another record with the same tracker matches neither rule and has V, C or T true or
  "unknown" (excluded as conflicting_records). An Issue matched by rules with different
  reasons is excluded as conflicting_rules; one reopened by hand (stateReason REOPENED) as
  reopened; one claimed by another live session as claimed_by_other_session.

dispose stdout: {"results": [{issue, reason, rule, closed, status}]}; status is the
  projects-status-update.sh result, "skipped_projects_disabled", or "not_attempted" when the
  close failed. dispose stops before closing anything when github.projects.enabled is true
  and project_number is not a number.
stderr:
  [CONTEXT] ISSUE_AUDIT=ok; open=N; chains=N; concentration=N; dispositions=N; excluded=N
  [CONTEXT] ISSUE_AUDIT_DISPOSE=ok|failed; closed=N; failed=N
  [CONTEXT] ISSUE_AUDIT=error; reason=REASON

Exit codes: 0 ok, 1 error or a failed disposition, 2 usage.
"""
import argparse
import datetime
import glob
import json
import os
from pathlib import Path
import re
import subprocess
import sys

STALE_DAYS = 30
CHAIN_MIN = 3
MERGED_PR_LIMIT = 200
PLUGIN_ROOT = Path(__file__).resolve().parents[3]

DUP_MARKER = re.compile(r"<!-- \[rite-follow-up-from-pr:[0-9]+:[A-Za-z0-9._#~-]+(?:,[A-Za-z0-9._#~-]+)*\] -->")
RECORD_FILE = re.compile(r"adoption-[0-9]+-followup\.json")
UNSET = ("", "null", "~")
FOLLOW_UP = re.compile(r"<!--\s*\[rite-follow-up-from-pr:([0-9]+)(?::([^\]]+))?\]\s*-->")
ORIGIN_PR = re.compile(r"^\s*-\s*元の?\s*PR:\s*#([0-9]+)", re.M)
ORIGIN_ISSUE = re.compile(r"^\s*-\s*元\s*Issue:\s*#([0-9]+)", re.M)
CLOSING = re.compile(r"(?<![\w/])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#([0-9]+)\b", re.I)
FILE_PATH = re.compile(r"(?<![\w./-])((?:[\w.-]+/)+[\w.-]+\.(?:sh|py|md|json|ya?ml|js|ts))\b")
REASON_ARG = {"duplicate": "duplicate", "not_planned": "not planned", "completed": "completed"}
ROLE = {"duplicate": "cancelled", "not_planned": "cancelled", "completed": "done"}


class Stop(Exception):
    pass


def run(cmd, cwd=None):
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if result.returncode != 0:
        raise Stop(f"{' '.join(cmd[:3])} failed: {result.stderr.strip()[:300]}")
    return result.stdout


def gh_json(*args):
    try:
        return json.loads(run(["gh", *args]))
    except ValueError as error:
        raise Stop(f"gh {' '.join(args[:2])}: invalid JSON: {error}") from None


class Source:
    """Read-only access to the repository, cached per run."""

    def __init__(self, repo, base):
        self.repo, self.base = repo, base
        self.issues, self.prs = {}, {}

    def open_issues(self):
        rows = gh_json("issue", "list", "-R", self.repo, "--state", "open", "--limit", "1000",
                       "--json", "number,title,body,updatedAt,stateReason,labels")
        for row in rows:
            self.issues[row["number"]] = row
        return sorted(rows, key=lambda r: r["number"])

    def merged_prs(self):
        rows = gh_json("pr", "list", "-R", self.repo, "--state", "merged",
                       "--limit", str(MERGED_PR_LIMIT), "--json", "number,body,baseRefName")
        for row in rows:
            self.prs[row["number"]] = row
        return [row for row in rows if row.get("baseRefName") == self.base]

    def issue(self, number):
        if number not in self.issues:
            self.issues[number] = gh_json("issue", "view", str(number), "-R", self.repo,
                                          "--json", "number,title,body,state")
        return self.issues[number]

    def pr(self, number):
        if number not in self.prs:
            self.prs[number] = gh_json("pr", "view", str(number), "-R", self.repo, "--json", "number,body")
        return self.prs[number]


def closing_refs(body):
    return sorted({int(n) for n in CLOSING.findall(body or "")})


def parents(issue, source):
    """(parent Issue, via) pairs of one Issue, from the lineage markers in its body."""
    body = issue.get("body") or ""
    found = [(int(n), "issue") for n in ORIGIN_ISSUE.findall(body)]
    prs = {int(m.group(1)) for m in FOLLOW_UP.finditer(body)} | {int(n) for n in ORIGIN_PR.findall(body)}
    for pr in sorted(prs):
        found += [(n, f"pr:{pr}") for n in closing_refs(source.pr(pr).get("body"))]
    return [(n, via) for n, via in dict.fromkeys(found) if n != issue["number"]]


def lineage(open_rows, source):
    edges, first_parent, seen = [], {}, set()
    pending = [row["number"] for row in open_rows]
    while pending:
        number = pending.pop()
        if number in seen:
            continue
        seen.add(number)
        for parent, via in parents(source.issue(number), source):
            edges.append({"child": number, "parent": parent, "via": via})
            first_parent.setdefault(number, parent)
            pending.append(parent)
    chains = []
    for row in open_rows:
        chain, node = [row["number"]], row["number"]
        while node in first_parent and first_parent[node] not in chain:
            node = first_parent[node]
            chain.insert(0, node)
        if len(chain) >= CHAIN_MIN:
            chains.append(chain)
    chains = [c for c in chains if not any(o != c and o[:len(c)] == c for o in chains)]
    edges.sort(key=lambda e: (e["child"], e["parent"], e["via"]))
    return {"edges": edges, "chains": sorted(chains)}


def concentration(open_rows):
    groups = {}
    for row in open_rows:
        body = row.get("body") or ""
        for path in set(FILE_PATH.findall(body)):
            groups.setdefault(("file", path), set()).add(row["number"])
        for pr in {m.group(1) for m in FOLLOW_UP.finditer(body)} | set(ORIGIN_PR.findall(body)):
            groups.setdefault(("origin_pr", pr), set()).add(row["number"])
    return [{"kind": kind, "key": key, "issues": sorted(nums)}
            for (kind, key), nums in sorted(groups.items()) if len(nums) >= 2]


def state_root():
    root = os.environ.get("RITE_STATE_ROOT")
    if root:
        return root
    return run(["bash", str(PLUGIN_ROOT / "hooks" / "state-path-resolve.sh")]).strip()


def followup_records():
    records = []
    for path in sorted(glob.glob(os.path.join(state_root(), ".rite", "state", "adoption-*-followup.json"))):
        if not RECORD_FILE.fullmatch(os.path.basename(path)):
            continue
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
            rows = data["adoption"]["records"]
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise Stop(f"{os.path.basename(path)}: unreadable follow-up record: {error}") from None
        records += [(os.path.basename(path), row) for row in rows if isinstance(row, dict)]
    return records


def claimed_by_other(number):
    out = run(["bash", str(PLUGIN_ROOT / "hooks" / "issue-claim.sh"), "check", "--issue", str(number)])
    return out.strip() == "other"


def record_decision(name, rec):
    """(reason, rule, evidence) of one record, or None when neither record rule applies."""
    ids = ",".join(str(i) for i in rec.get("ids") or [])
    if rec.get("present") is False:
        return "completed", "record_resolved", f"{name} ids={ids} present=false evidence: {rec.get('evidence') or ''}"
    if all(rec.get(k) is False for k in "VCT") and str(rec.get("reason") or "").strip():
        return "not_planned", "record_rejected", f"{name} ids={ids} V=C=T=false reason: {rec['reason']}"
    return None


def record_rules(records):
    by_tracker = {}
    for name, rec in records:
        if isinstance(rec.get("tracker"), int):
            by_tracker.setdefault(rec["tracker"], []).append((name, rec))
    found, excluded = [], []
    for tracker, recs in sorted(by_tracker.items()):
        decided = [d for d in (record_decision(name, rec) for name, rec in recs) if d]
        contested = any(record_decision(name, rec) is None and
                        any(rec.get(k) is True or rec.get(k) == "unknown" for k in "VCT") for name, rec in recs)
        if decided and contested:
            excluded.append({"issue": tracker, "rule": "record", "why": "conflicting_records"})
        elif decided:
            found += [(tracker, *d) for d in decided]
    return found, excluded


def dispositions(open_rows, merged, records):
    open_numbers = {row["number"] for row in open_rows}
    found, dup_of = [], {}
    keys = {}
    for row in open_rows:
        first = (row.get("body") or "").split("\n", 1)[0].strip()
        if DUP_MARKER.fullmatch(first) and "follow-up" in {l.get("name") for l in row.get("labels") or []}:
            keys.setdefault(first, set()).add(row["number"])
    for marker, nums in sorted(keys.items()):
        keep = min(nums)
        for n in sorted(nums - {keep}):
            found.append((n, "duplicate", "duplicate_key", f"#{keep} と同じ根因キー: {marker}"))
            dup_of[n] = keep
    for pr in merged:
        for n in closing_refs(pr.get("body")):
            if n in open_numbers:
                line = next((l.strip() for l in (pr.get("body") or "").splitlines()
                             if n in closing_refs(l)), "")
                found.append((n, "completed", "merged_closing_pr", f"PR #{pr['number']} の本文: {line}"))
    rec_found, excluded = record_rules(records)
    found += [f for f in rec_found if f[0] in open_numbers]
    excluded = [e for e in excluded if e["issue"] in open_numbers]
    by_issue = {}
    for n, reason, rule, evidence in found:
        by_issue.setdefault(n, []).append((reason, rule, evidence))
    rows = {row["number"]: row for row in open_rows}
    result = []
    for n, hits in sorted(by_issue.items()):
        rules = ",".join(sorted({h[1] for h in hits}))
        if len({h[0] for h in hits}) > 1:
            excluded.append({"issue": n, "rule": rules, "why": "conflicting_rules"})
        elif rows[n].get("stateReason") == "REOPENED":
            excluded.append({"issue": n, "rule": rules, "why": "reopened"})
        elif claimed_by_other(n):
            excluded.append({"issue": n, "rule": rules, "why": "claimed_by_other_session"})
        else:
            result.append({"issue": n, "reason": hits[0][0], "rule": rules,
                           "evidence": [h[2] for h in hits], "duplicate_of": dup_of.get(n)})
    return result, sorted(excluded, key=lambda e: e["issue"])


def snapshot(repo, base):
    source = Source(repo, base)
    open_rows = source.open_issues()
    merged = source.merged_prs()
    now = datetime.datetime.now(datetime.timezone.utc)
    issues = []
    for row in open_rows:
        updated = datetime.datetime.fromisoformat(row["updatedAt"].replace("Z", "+00:00"))
        issues.append({"number": row["number"], "title": row["title"], "updated_at": row["updatedAt"],
                       "stale": (now - updated).days >= STALE_DAYS})
    disp, excluded = dispositions(open_rows, merged, followup_records())
    return {"repo": repo, "base": base, "open_issues": issues, "lineage": lineage(open_rows, source),
            "concentration": concentration(open_rows), "dispositions": disp, "excluded": excluded}


def projects_config():
    result = subprocess.run(["bash", str(PLUGIN_ROOT / "hooks" / "scripts" / "lib" / "rite-config-path.sh")],
                            capture_output=True, text=True)
    if result.returncode == 1:
        return None
    if result.returncode != 0:
        raise Stop(f"rite-config.yml: {result.stderr.strip()}")
    section, values = None, {}
    for line in Path(result.stdout.strip()).read_text(encoding="utf-8").splitlines():
        if re.match(r"^\S", line):
            section = "github" if line.startswith("github:") else None
        elif section == "github" and re.match(r"^  \S", line):
            section = "projects" if line.strip() == "projects:" else "github"
        elif section == "projects":
            m = re.match(r"^    (enabled|project_number|owner):\s*\"?([^\"#\s]*)", line)
            if m and m.group(2) not in UNSET:
                values.setdefault(m.group(1), m.group(2))
    if values.get("enabled") != "true":
        return None
    if not values.get("project_number", "").isdigit():
        raise Stop(f"rite-config.yml: github.projects.enabled is true but project_number is not a number "
                   f"({values.get('project_number', 'unset')}); set it or disable Projects")
    return values


def close_comment(item):
    lines = ["🧹 Issue 監査（/rite:issue-audit）が採否規則に従って処分しました。",
             "", f"- 規則: `{item['rule']}`", f"- 処分: {REASON_ARG[item['reason']]}"]
    if item["duplicate_of"]:
        lines.append(f"- 重複先: #{item['duplicate_of']}")
    lines += ["", "根拠:"] + [f"- {e}" for e in item["evidence"]]
    return "\n".join(lines)


def dispose(repo, base):
    projects = projects_config()
    snap = snapshot(repo, base)
    owner = (projects or {}).get("owner") or repo.split("/")[0]
    results, failed = [], 0
    for item in snap["dispositions"]:
        n = str(item["issue"])
        cmd = ["gh", "issue", "close", n, "-R", repo, "--comment", close_comment(item)]
        cmd += ["--duplicate-of", str(item["duplicate_of"])] if item["duplicate_of"] else \
               ["--reason", REASON_ARG[item["reason"]]]
        closed = subprocess.run(cmd, capture_output=True, text=True)
        entry = {"issue": item["issue"], "reason": item["reason"], "rule": item["rule"],
                 "closed": closed.returncode == 0, "status": "skipped_projects_disabled"}
        if closed.returncode != 0:
            print(f"WARNING: #{n} を close できません: {closed.stderr.strip()[:300]}", file=sys.stderr)
            entry["status"] = "not_attempted"
        elif projects:
            args = json.dumps({"issue_number": item["issue"], "owner": owner, "repo": repo.split("/")[1],
                               "project_number": int(projects["project_number"]),
                               "status_role": ROLE[item["reason"]], "auto_add": False, "non_blocking": True})
            out = subprocess.run(["bash", str(PLUGIN_ROOT / "scripts" / "projects-status-update.sh"), args],
                                 capture_output=True, text=True)
            try:
                payload = json.loads(out.stdout)
            except ValueError:
                payload = {}
            entry["status"] = payload.get("result", "failed")
            if entry["status"] != "updated":
                for w in payload.get("warnings") or []:
                    print(f"WARNING: #{n} の Status を更新できません: {w}", file=sys.stderr)
                if out.returncode != 0 or not payload:
                    print(f"WARNING: #{n} projects-status-update.sh rc={out.returncode}: "
                          f"{out.stderr.strip()[:300]}", file=sys.stderr)
        if not entry["closed"] or entry["status"] in ("failed", "skipped_terminal_conflict"):
            failed += 1
        results.append(entry)
    print(json.dumps({"results": results}, ensure_ascii=False, indent=2))
    closed_n = sum(1 for r in results if r["closed"])
    print(f"[CONTEXT] ISSUE_AUDIT_DISPOSE={'failed' if failed else 'ok'}; closed={closed_n}; failed={failed}",
          file=sys.stderr)
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(prog="issue-audit.sh")
    parser.add_argument("command", choices=("collect", "dispose"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        parser.error("--repo must be OWNER/REPO")
    try:
        if args.command == "dispose":
            return dispose(args.repo, args.base)
        snap = snapshot(args.repo, args.base)
        print(json.dumps(snap, ensure_ascii=False, indent=2))
        print(f"[CONTEXT] ISSUE_AUDIT=ok; open={len(snap['open_issues'])}; "
              f"chains={len(snap['lineage']['chains'])}; concentration={len(snap['concentration'])}; "
              f"dispositions={len(snap['dispositions'])}; excluded={len(snap['excluded'])}", file=sys.stderr)
        return 0
    except Stop as error:
        print(f"ERROR: issue-audit: {error}", file=sys.stderr)
        print("[CONTEXT] ISSUE_AUDIT=error; reason=source_unreadable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
