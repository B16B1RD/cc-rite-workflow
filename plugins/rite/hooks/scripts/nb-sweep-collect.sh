#!/usr/bin/env bash
# Collect remaining non-blocking findings for iterate's post-mergeable sweep.
#
# Targets:
#   - all non_blocking_findings[]
#   - findings[] with scope == "nit-noted" (blocking-out remainder)
#   - guardrail_audit_log[] copied as already_rejected (record only, no re-judge)
# Collect never decides adoption: severity and measurement do not change what it returns.
# Each target carries `key` (its id, or anon:<file>:<line> when the id is empty): the
# candidate id the adoption gate reads and the finding_id the sweep writes to the ledger.
# --json is an offline transform; pass --pr as well to read the persisted ledger
# (a row matches a target on [id or key, file:line]):
#   - excluded: an `issued` row, or a REJECT / RESOLVED / LINK row whose 出典 is the
#     review JSON read now (this sweep already recorded it). Legacy recorded / rejected
#     rows never exclude a target.
#   - prior: the last REJECT / ADOPT row becomes
#     {finding_id, file_line, disposition, premise (= 判定文)} for the classifier to copy
#     into its adoption record.
#   - already_rejected is excluded by an issued / recorded / rejected row as before.
# candidates[] is what the sweep's adoption gate judges: every target as {id: key,
# finding_id: id, record: <basename of the review JSON>} plus its fields. With --pr, the
# candidates of the sweep hold file (STATE_ROOT/.rite/state/adoption-hold-PR-sweep.json)
# that no target matches by full text without id are carried into candidates[] as saved,
# keeping the record of the review JSON they came from (the ledger 出典 cleanup matches);
# a carried id already taken is renamed with a held- prefix. They are judged again on the
# review JSON read now, whatever commit the hold was saved on.
#
# Usage:
#   bash nb-sweep-collect.sh --json <path>
#   bash nb-sweep-collect.sh --pr <n> --state-root <path>
#
# stdout: JSON {status, count, record, targets[], candidates[], already_rejected[]}
#         count is targets + carried hold candidates + already_rejected.
# stderr: [CONTEXT] NB_SWEEP_COLLECT=ok|empty|failed; count=N; record=PATH
#
# Exit:
#   0  ok (count>=1) or empty (count==0)
#   1  JSON missing / unreadable / invalid (fail-loud)
#   2  argument error
set -euo pipefail

json=""
pr=""
state_root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=${2:-}; shift 2 ;;
    --pr) pr=${2:-}; shift 2 ;;
    --state-root) state_root=${2:-}; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$json" ]; then
  case "$pr" in ''|*[!0-9]*) echo "ERROR: --pr must be a positive integer (or pass --json)" >&2; exit 2 ;; esac
  [ -n "$state_root" ] || { echo "ERROR: --state-root is required when --json is omitted" >&2; exit 2; }
  results_dir="$state_root/.rite/review-results"
  if [ ! -d "$results_dir" ]; then
    echo "ERROR: review results dir missing: $results_dir" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=; reason=results_dir_missing" >&2
    exit 1
  fi
  if ! json=$(find "$results_dir" -maxdepth 1 -type f -name "${pr}-*.json" | LC_ALL=C sort | tail -1); then
    echo "ERROR: review result JSON search failed for PR #$pr" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=; reason=json_search_failed" >&2
    exit 1
  fi
  if [ -z "$json" ]; then
    echo "ERROR: no review JSON for PR #$pr in $results_dir" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=; reason=json_missing" >&2
    exit 1
  fi
fi

if [ ! -f "$json" ] || [ ! -r "$json" ]; then
  echo "ERROR: review JSON unreadable: $json" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=json_unreadable" >&2
  exit 1
fi

if ! jq empty "$json" >/dev/null 2>&1; then
  echo "ERROR: review JSON invalid: $json" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=json_invalid" >&2
  exit 1
fi

# Ledger reads are mandatory in the live --pr path. A failed read must not
# silently re-issue findings already handled by a prior sweep.
ledger_rows='[]'
collect_fail() {
  echo "ERROR: non-blocking ledger read failed: $1" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=$1" >&2
  exit 1
}
if [ -n "$pr" ]; then
  case "$pr" in ''|*[!0-9]*|0) echo "ERROR: --pr must be a positive integer" >&2; exit 2 ;; esac
  owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner') || collect_fail repo_unresolved
  [ -n "$owner_repo" ] || collect_fail repo_unresolved
  # 記録コメントは書き込み経路 (review-nonblocking-record.sh) が PATCH する 1 件だけを読む。
  # 関連 Issue の解決・記録コメントの同定・CRLF の正規化は helper が行う (失敗の詳細は helper の stderr)。
  record_body=$(bash "$(dirname "${BASH_SOURCE[0]}")/../review-nonblocking-record.sh" \
    --print-record-body --pr "$pr" --owner-repo "$owner_repo") || collect_fail comments_unreadable
  # 台帳の行をセルに分ける。セル内のエスケープ済みパイプ (\|) は区切りにしない。出典は 5 列目 (4 列の旧行は空)
  if ! ledger_rows=$(printf '%s' "$record_body" | jq -Rsce '
    def trim: gsub("^\\s+|\\s+$"; "");
    [ split("### 却下台帳\n")[1:][]
        | split("📎 non_blocking_count:")[0] | split("\n### ")[0]
        | split("\n")[] | select(startswith("|"))
        | gsub("\\\\\\|"; "") | split("|") | map(gsub(""; "\\|") | trim)
        | select(length >= 6)
        | {id: .[1], loc: .[2], disposition: .[3], premise: .[4], source: (if length >= 7 then .[5] else "" end)} ]
  '); then collect_fail ledger_invalid; fi
fi

hold='null'
hold_file="$state_root/.rite/state/adoption-hold-$pr-sweep.json"
if [ -n "$pr" ] && [ -e "$hold_file" ]; then
  hold=$(jq -ce 'if type == "object" and (.candidates | type) == "array"
      and all(.candidates[]; type == "object" and (.id | type) == "string" and .id != ""
        and (.record | type) == "string" and .record != "") then . else error("malformed") end' \
    "$hold_file" 2>/dev/null) || collect_fail hold_unreadable
fi

if ! out=$(jq -c --arg record "$json" --argjson ledger "$ledger_rows" --argjson hold "$hold" '
  ($record | split("/") | last) as $record_base
  | def target:
    (.id // "") as $id
    | {
        id: $id,
        key: (if ($id | tostring | length) > 0 then ($id | tostring)
              else "anon:" + ((.file // "") | tostring) + ":" + ((.line // null) | tostring) end),
        source: .source,
        file: (.file // ""),
        line: (.line // null),
        severity: (.severity // "UNKNOWN"),
        scope: (.scope // ""),
        description: (.description // ""),
        suggestion: (.suggestion // ""),
        verification: .verification
      };
  def rows($t):
    ($t.file + ":" + ($t.line | tostring)) as $loc
    | $ledger | map(select(.loc == $loc and (.id == ($t.id | tostring) or .id == $t.key)));
  def pending:
    . as $t
    | rows($t) | any(.disposition == "issued"
        or ((.disposition == "REJECT" or .disposition == "RESOLVED" or .disposition == "LINK")
            and .source == $record_base)) | not;
  def with_prior:
    . as $t
    | (rows($t) | map(select(.disposition == "REJECT" or .disposition == "ADOPT")) | last) as $p
    | if $p == null then .
      else . + {prior: {finding_id: $p.id, file_line: $p.loc, disposition: $p.disposition, premise: $p.premise}}
      end;
  def transcribed($id; $location):
    $ledger | any(.id == $id and .loc == $location
      and (.disposition == "rejected" or .disposition == "recorded" or .disposition == "issued"));
  (.non_blocking_findings // []) as $nb
  | (.findings // []) as $findings
  | ($nb | map(. + {source: "non_blocking_findings"} | target)) as $from_nb
  | ($findings
      | map(select(.scope == "nit-noted") | . + {source: "findings_nit_noted"} | target)
    ) as $from_nit
  | ($from_nb + $from_nit) as $all
  | ($all | map(select(pending) | with_prior)) as $pending
  | (reduce $pending[] as $t ({}; if has($t.key) then . else .[$t.key] = $t end) | [.[]]) as $targets
  | ((.guardrail_audit_log // []) | map({
        source: "guardrail_audit_log",
        severity: (.original_severity // ""),
        verification: {measured: false},
        reviewer: (.reviewer // ""),
        file_line: (.file_line // ""),
        original_severity: (.original_severity // ""),
        description: (.description // ""),
        filter_reason: (.filter_reason // "")
      }) | map(select(transcribed(.reviewer; .file_line) | not))) as $guardrails
  | [$targets[] | . + {finding_id: .id, id: .key, record: $record_base}] as $now
  | [$now[] | del(.id)] as $now_text
  | [$now[].id] as $taken
  | [($hold.candidates // [])[] | select(del(.id) as $x | any($now_text[]; . == $x) | not)
      | .id |= until(. as $i | $taken | index($i) | not; "held-" + .)] as $carried
  | (($targets | length) + ($carried | length) + ($guardrails | length)) as $count
  | {
      status: (if $count == 0 then "empty" else "ok" end),
      count: $count,
      record: $record,
      targets: $targets,
      candidates: ($now + $carried),
      already_rejected: $guardrails
    }
' "$json"); then
  echo "ERROR: review JSON collect transform failed: $json" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=jq_transform_failed" >&2
  exit 1
fi

count=$(printf '%s' "$out" | jq -r '.count')
status=$(printf '%s' "$out" | jq -r '.status')
echo "[CONTEXT] NB_SWEEP_COLLECT=$status; count=$count; record=$json" >&2
printf '%s\n' "$out"
