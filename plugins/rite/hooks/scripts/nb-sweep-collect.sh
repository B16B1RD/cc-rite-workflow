#!/usr/bin/env bash
# Collect remaining non-blocking findings for iterate's post-mergeable sweep.
#
# Targets:
#   - all non_blocking_findings[]
#   - findings[] with scope == "nit-noted" (blocking-out remainder)
#   - guardrail_audit_log[] (rows the review's guardrail filtered out). The guardrail's
#     reason is not an adoption exit, so these rows are judged by the gate like any target.
# Collect never decides adoption: severity and measurement do not change what it returns.
# Each target carries `key` (its id, or anon:<file>:<line> when the id is empty): the
# candidate id the adoption gate reads and the finding_id the sweep writes to the ledger.
# A guardrail row has no id: its id is the reviewer and its key is
# guardrail:<reviewer>:<file_line>, with #<n> appended to the n-th row (n >= 2) of the
# same reviewer and file_line in the JSON, so every row stays its own candidate. Its loc
# is file_line as written (reviewers may write `-`, a bare path or a function name there);
# file and line split it at the last `:` only when it has that shape. A row without
# reviewer or description cannot be judged from its text: collect stops
# (reason=guardrail_row_invalid) instead of dropping it.
# --json is an offline transform; pass --pr as well to read the persisted ledger
# (a row matches a target on [id or key, loc]; a guardrail target is excluded only by
# rows of its key, while a row of its reviewer id can still become its prior):
#   - excluded: an `issued` row, or a REJECT / RESOLVED / LINK row whose 出典 is the
#     review JSON read now (this sweep already recorded it). Legacy recorded / rejected
#     rows never exclude a target.
#   - a legacy recorded / rejected row whose 出典 is a review JSON of this PR (<pr>-...),
#     that matches no finding or guardrail row of the JSON read now, and whose 出典 JSON
#     is in neither the directory of that JSON nor its
#     archive/, has lost the text of its guardrail row: collect stops
#     (reason=guardrail_source_missing) and names the row's reviewer, file_line and 出典.
#   - prior: the last REJECT / ADOPT row becomes
#     {finding_id, file_line, disposition, premise (= 判定文)} for the classifier to copy
#     into its adoption record.
# candidates[] is what the sweep's adoption gate judges: every target as {id: key,
# finding_id: id, record: <basename of the review JSON>} plus its fields. With --pr, the
# candidates of the sweep hold file (STATE_ROOT/.rite/state/adoption-hold-PR-sweep.json)
# that no target matches by full text without id are carried into candidates[] as saved,
# keeping the record of the review JSON they came from (the ledger 出典 cleanup matches).
# A carried candidate's id is <record>#<key>: stable across cycles and never equal to a
# target id (F-NN / anon:<file>:<line>), since review ids restart at F-01 in every JSON.
# They are judged again on the review JSON read now, whatever commit the hold was saved on.
#
# Usage:
#   bash nb-sweep-collect.sh --json <path>
#   bash nb-sweep-collect.sh --pr <n> --state-root <path>
#
# stdout: JSON {status, count, record, targets[], candidates[], ledger[]}
#         ledger[] is the ledger rows judged issued / LINK / REJECT ({id, loc, disposition, premise, source})
#         as read, for the classifier to link a candidate whose id, wording or position changed.
#         count is targets + carried hold candidates.
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

if ! invalid_guardrails=$(jq -c '[(.guardrail_audit_log // [])[]
    | select(((.reviewer // "") | tostring) == "" or ((.description // "") | tostring) == "")]' "$json"); then
  echo "ERROR: review JSON guardrail_audit_log unreadable: $json" >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=guardrail_row_invalid" >&2
  exit 1
fi
if [ -n "$invalid_guardrails" ] && [ "$invalid_guardrails" != "[]" ]; then
  echo "ERROR: guardrail_audit_log rows lack the reviewer or description needed to judge them: $json" >&2
  printf '%s' "$invalid_guardrails" | jq -r '.[] | "  reviewer=\(.reviewer // "") file_line=\(.file_line // "")"' >&2
  echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=guardrail_row_invalid" >&2
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
  # 旧形式の recorded / rejected 行は guardrail 行を原文なしで転記したものを含む。この PR のレビュー結果を
  # 出典に持ち、今回の JSON に同じ [finding_id, file:line] の指摘 (guardrail 行は reviewer と file_line) が
  # 無い行の原文は出典 JSON にしかないので、出典が今回の JSON のディレクトリにも archive/ にも無ければ、
  # その行は判定できないまま消える (台帳は Issue 単位なので、別の PR の行はこの PR の候補ではない)
  if ! unmatched_rows=$(printf '%s' "$ledger_rows" | jq -er --slurpfile cur "$json" --arg pfx "$pr-" '
    ([($cur[0].findings // [])[], ($cur[0].non_blocking_findings // [])[]
        | [((.id // "") | tostring), ((.file // "") + ":" + (.line | tostring))]]
     + [($cur[0].guardrail_audit_log // [])[] | [((.reviewer // "") | tostring), ((.file_line // "") | tostring)]]) as $here
    | [.[] | select((.disposition == "recorded" or .disposition == "rejected") and (.source | startswith($pfx)))
        | select([.id, .loc] as $k | $here | index([$k]) | not)
        | [.id, .loc, .source] | @tsv] | join("\n")'); then
    collect_fail ledger_invalid
  fi
  src_dir=$(dirname "$json")
  lost_rows=""
  while IFS=$'\t' read -r l_id l_loc l_src; do
    [ -n "$l_src" ] || continue
    case "$l_src" in */*) lost=1 ;; *) lost=0; [ -f "$src_dir/$l_src" ] || [ -f "$src_dir/archive/$l_src" ] || lost=1 ;; esac
    [ "$lost" -eq 1 ] && lost_rows="${lost_rows}  reviewer=${l_id} file_line=${l_loc} source=${l_src}"$'\n'
  done <<< "$unmatched_rows"
  if [ -n "$lost_rows" ]; then
    echo "ERROR: legacy recorded / rejected ledger rows match no finding or guardrail row of $json, and their source JSON is in neither $src_dir nor its archive/; their text cannot be judged:" >&2
    printf '%s' "$lost_rows" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=guardrail_source_missing" >&2
    exit 1
  fi
fi

hold='null'
hold_file="$state_root/.rite/state/adoption-hold-$pr-sweep.json"
if [ -n "$pr" ] && [ -n "$state_root" ] && [ -e "$hold_file" ]; then
  if ! hold=$(jq -ce 'if type == "object" and (.candidates | type) == "array"
      and all(.candidates[]; type == "object" and (.id | type) == "string" and .id != ""
        and (.key | type) == "string" and .key != "" and (.record | type) == "string" and .record != "")
      then . else error("candidates need id, key and record") end' "$hold_file" 2>&1); then
    echo "ERROR: the sweep hold file cannot be read; it is kept and nothing is collected: $hold_file" >&2
    printf '  %s\n' "$(printf '%s' "$hold" | head -1)" >&2
    echo "[CONTEXT] NB_SWEEP_COLLECT=failed; count=0; record=$json; reason=hold_unreadable" >&2
    exit 1
  fi
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
    ($t.loc // ($t.file + ":" + ($t.line | tostring))) as $loc
    | $ledger | map(select(.loc == $loc and (.id == ($t.id | tostring) or .id == $t.key)));
  def pending:
    . as $t
    | rows($t) | map(select($t.source != "guardrail_audit_log" or .id == $t.key))
    | any(.disposition == "issued"
        or ((.disposition == "REJECT" or .disposition == "RESOLVED" or .disposition == "LINK")
            and .source == $record_base)) | not;
  def with_prior:
    . as $t
    | (rows($t) | map(select(.disposition == "REJECT" or .disposition == "ADOPT")) | last) as $p
    | if $p == null then .
      else . + {prior: {finding_id: $p.id, file_line: $p.loc, disposition: $p.disposition, premise: $p.premise}}
      end;
  # $n は同じ reviewer・file_line の行のうち何番目か (0 始まり)
  def guardrail($n):
    ((.file_line // "") | tostring) as $fl
    | ($fl | capture("^(?<file>.+):(?<line>[^:]+)$") // {file: $fl, line: null}) as $at
    | {
        id: (.reviewer | tostring),
        key: ("guardrail:" + (.reviewer | tostring) + ":" + $fl + (if $n > 0 then "#\($n + 1)" else "" end)),
        source: "guardrail_audit_log",
        loc: $fl,
        file: $at.file,
        line: $at.line,
        severity: (.original_severity // "UNKNOWN"),
        scope: "",
        description: (.description | tostring),
        suggestion: "",
        verification: {measured: false},
        filter_reason: (.filter_reason // "")
      };
  (.non_blocking_findings // []) as $nb
  | (.findings // []) as $findings
  | ($nb | map(. + {source: "non_blocking_findings"} | target)) as $from_nb
  | ($findings
      | map(select(.scope == "nit-noted") | . + {source: "findings_nit_noted"} | target)
    ) as $from_nit
  | (.guardrail_audit_log // []) as $g
  | [range(0; $g | length) as $i
      | $g[$i] | guardrail([$g[0:$i][] | select(.reviewer == $g[$i].reviewer and .file_line == $g[$i].file_line)] | length)
    ] as $from_guardrail
  | ($from_nb + $from_nit + $from_guardrail) as $all
  | ($all | map(select(pending) | with_prior)) as $pending
  | (reduce $pending[] as $t ({}; if has($t.key) then . else .[$t.key] = $t end) | [.[]]) as $targets
  | [$targets[] | . + {finding_id: .id, id: .key, record: $record_base}] as $now
  | [$now[] | del(.id)] as $now_text
  | [($hold.candidates // [])[] | select(del(.id) as $x | any($now_text[]; . == $x) | not)
      | .id = .record + "#" + .key] as $carried
  | (($targets | length) + ($carried | length)) as $count
  | {
      status: (if $count == 0 then "empty" else "ok" end),
      count: $count,
      record: $record,
      targets: $targets,
      candidates: ($now + $carried),
      ledger: [$ledger[] | select(.disposition == "issued" or .disposition == "LINK" or .disposition == "REJECT")]
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
