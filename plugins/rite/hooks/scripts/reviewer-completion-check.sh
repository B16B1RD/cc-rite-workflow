#!/usr/bin/env bash
# Verify collected reviewer evidence before consolidation or a success sentinel.
# Usage: reviewer-completion-check.sh --input <manifest.json>
#
# Input (schema_version is independent of the persisted review-result schema):
# {"schema_version":1,"parent_agent_id":"parent-id",
#  "selected_reviewers":["security-reviewer"],
#  "reviewers":[{"reviewer":"security-reviewer","agent_id":"child-id",
#    "status":"completed","started_at":"2026-09-08T01:00:00Z",
#    "ended_at":"2026-09-08T01:02:00Z","output_file":"/absolute/raw.md"}]}
#
# The caller records the actual host child ID and completion output, without
# rewriting it. A retry replaces that reviewer's completion record with the
# actual retry ID/output, while started_at retains the first spawn time used by
# review-spawn-spread-check.sh. Keep retry history in work memory. Selection is
# fixed before spawning; do not remove a failed reviewer to make this gate pass.
# parent_agent_id is the host's parent agent/session identity, not a child ID.
#
# This read-only check proves manifest consistency and output structure, not
# tool provenance, read-only enforcement, review quality, or actual parallelism.
# Those remain host/caller responsibilities; spawn spread has its own helper.
# No review-result JSON is written and no mergeable sentinel is generated.
# Exit: 0 = every selected reviewer completed; 1 = incomplete/invalid evidence;
#       2 = invalid arguments or missing runtime dependency. Never skip failure.
set -uo pipefail

if [ "$#" -ne 2 ] || [ "${1:-}" != "--input" ] || [ -z "${2:-}" ]; then
  echo 'ERROR: reviewer-completion-check: use --input <manifest.json>; return [review:error]' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo 'ERROR: reviewer-completion-check: python3 is required; return [review:error]' >&2
  exit 2
fi

exec python3 - "$2" <<'PY'
import datetime
import json
import pathlib
import re
import sys


def reject(reason, detail):
    # JSON quoting prevents malformed input from injecting diagnostic lines.
    print("ERROR: reviewer-completion-check: " + json.dumps(detail, ensure_ascii=False)
          + "; retain evidence and return [review:error]", file=sys.stderr)
    print("[CONTEXT] REVIEWER_COMPLETION=error; reason=" + reason, file=sys.stderr)
    raise SystemExit(1)


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def token(value):
    return (isinstance(value, str) and bool(value)
            and not any(c.isspace() or ord(c) < 32 or 127 <= ord(c) <= 159 for c in value))


def timestamp(value, reviewer, field):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        reject("timing_invalid", reviewer + ": " + field + " must be a recorded UTC timestamp")
    try:
        return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        reject("timing_invalid", reviewer + ": " + field + " is not a valid calendar time")


def check_output(path, reviewer):
    if not isinstance(path, str) or not pathlib.Path(path).is_absolute():
        reject("output_path_invalid", reviewer + ": output_file must be an absolute path")
    try:
        output = pathlib.Path(path)
        if not output.is_file():
            reject("output_unavailable", reviewer + ": result is not a regular file: " + path)
        stat = output.stat()
        content = output.read_text(encoding="utf-8")
    except (OSError, ValueError, UnicodeError) as error:
        reject("output_unavailable", reviewer + ": cannot read result: " + str(error))
    if not content.strip():
        reject("output_empty", reviewer + ": result is empty")

    # Only top-level output headings count. A quoted template inside a fenced
    # example cannot substitute for the actual report. Table semantics and the
    # truth of findings are deliberately left to the existing review pipeline.
    visible = []
    fence = None
    for line in content.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if marker:
            run = marker.group(1)
            if fence is None:
                fence = run
            elif run[0] == fence[0] and len(run) >= len(fence):
                fence = None
            continue
        if fence is None:
            visible.append(line)

    patterns = [r"### 評価: (可|条件付き|要修正)\s*", r"### 所見\s*",
                r"### 指摘事項\s*", r"### 監査ログ\s*"]
    positions = []
    for pattern in patterns:
        found = [index for index, line in enumerate(visible) if re.fullmatch(pattern, line)]
        if len(found) != 1:
            reject("output_format_invalid", reviewer + ": expected one each of 評価/所見/指摘事項/監査ログ")
        positions.append(found[0])
    if positions != sorted(positions):
        reject("output_format_invalid", reviewer + ": report sections are out of order")
    for start, end in zip(positions[1:], positions[2:] + [len(visible)]):
        if not any(line.strip() for line in visible[start + 1:end]):
            reject("output_format_invalid", reviewer + ": empty report section")
    return stat.st_dev, stat.st_ino


try:
    manifest_path = pathlib.Path(sys.argv[1])
    if not manifest_path.is_file():
        reject("manifest_unavailable", "manifest is not a regular file")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys)
except (OSError, ValueError, UnicodeError) as error:
    reject("manifest_invalid", "cannot read manifest: " + str(error))

if not isinstance(manifest, dict) or type(manifest.get("schema_version")) is not int or manifest["schema_version"] != 1:
    reject("manifest_invalid", "schema_version must be 1")
parent = manifest.get("parent_agent_id")
if not token(parent):
    reject("parent_identity_invalid", "parent_agent_id must identify the actual parent")
selected = manifest.get("selected_reviewers")
if (not isinstance(selected, list) or not selected
        or not all(isinstance(name, str) and re.fullmatch(r"[a-z][a-z0-9-]*-reviewer", name) for name in selected)
        or len(selected) != len(set(selected))):
    reject("selection_invalid", "selected_reviewers must be nonempty, unique reviewer names")
records = manifest.get("reviewers")
if not isinstance(records, list) or not all(isinstance(record, dict) for record in records):
    reject("records_invalid", "reviewers must be an array of completion records")
names = [record.get("reviewer") for record in records]
if (not all(isinstance(name, str) for name in names) or len(names) != len(set(names))
        or set(names) != set(selected)):
    reject("selection_mismatch", "completion records must match every selected reviewer exactly once")

agent_ids = set()
outputs = set()
for record in records:
    reviewer = record["reviewer"]
    agent_id = record.get("agent_id")
    if not token(agent_id):
        reject("agent_identity_invalid", reviewer + ": missing or invalid actual spawn ID")
    if agent_id == parent or agent_id in agent_ids:
        reject("agent_identity_reused", reviewer + ": parent or duplicate spawn ID cannot count as an independent reviewer")
    agent_ids.add(agent_id)
    if record.get("status") != "completed":
        reject("reviewer_incomplete", reviewer + ": actual completion has not been collected")
    started = timestamp(record.get("started_at"), reviewer, "started_at")
    ended = timestamp(record.get("ended_at"), reviewer, "ended_at")
    if ended < started:
        reject("timing_reversed", reviewer + ": completion precedes spawn")
    identity = check_output(record.get("output_file"), reviewer)
    if identity in outputs:
        reject("output_reused", reviewer + ": another reviewer already uses this raw output file")
    outputs.add(identity)

print("[CONTEXT] REVIEWER_COMPLETION=pass; reviewers=" + str(len(selected)))
PY
