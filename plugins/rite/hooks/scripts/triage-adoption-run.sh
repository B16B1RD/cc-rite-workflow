#!/bin/bash
# 採否手順の本体。records と candidates はファイルで渡す。
# pipefail は付けない。review JSON が無いときの ls 失敗は空結果のままにする。

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_root=$(cd "$script_dir/../.." && pwd)

pr=""
base=""
fix_loop=""
records_file=""
candidates_file=""
issue=""
issue_given=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr|--base|--fix-loop|--records-file|--candidates-file|--issue)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: $1 に値がありません" >&2
        exit 2
      fi
      ;;
  esac
  case "$1" in
    --pr) pr=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --fix-loop) fix_loop=$2; shift 2 ;;
    --records-file) records_file=$2; shift 2 ;;
    --candidates-file) candidates_file=$2; shift 2 ;;
    --issue) issue=$2; issue_given=1; shift 2 ;;
    *) echo "ERROR: 不明な引数です: $1" >&2; exit 2 ;;
  esac
done
for _val in "$pr" "$base" "$fix_loop" "$records_file" "$candidates_file" "$issue"; do
  if [[ "$_val" =~ \{[A-Za-z_][A-Za-z0-9_]*\} ]]; then
    echo "ERROR: 未置換の placeholder があります" >&2
    exit 2
  fi
done
if [ -z "$pr" ] || [ -z "$base" ] || [ -z "$fix_loop" ] || [ -z "$records_file" ] || [ -z "$candidates_file" ]; then
  echo "ERROR: --pr --base --fix-loop --records-file --candidates-file は必須です" >&2
  exit 2
fi
case "$pr" in
  *[!0-9]*) echo "ERROR: --pr は数値です" >&2; exit 2 ;;
esac
case "$fix_loop" in
  yes|no) ;;
  *) echo "ERROR: --fix-loop は yes か no です" >&2; exit 2 ;;
esac
if [ "$issue_given" -eq 1 ] && [ -z "$issue" ]; then
  echo "ERROR: --issue が空です" >&2
  exit 2
fi
if [ ! -f "$records_file" ]; then
  echo "ERROR: records ファイルがありません: $records_file" >&2
  exit 2
fi
if [ ! -f "$candidates_file" ]; then
  echo "ERROR: candidates ファイルがありません: $candidates_file" >&2
  exit 2
fi

state_root=$(bash "$plugin_root/hooks/state-path-resolve.sh") && [ -n "$state_root" ] \
  || { echo "ERROR: state root を解決できません" >&2; echo "[CONTEXT] ADOPTION_GATE_RC=2"; exit 1; }
review_json=$(ls -1 "$state_root/.rite/review-results/$pr"-*.json 2>/dev/null | LC_ALL=C sort | tail -1)
head_sha=$(jq -r '.commit_sha // empty' "$review_json" 2>/dev/null)
[ -n "$head_sha" ] || { echo "ERROR: 本 cycle の review JSON を読めません: ${review_json:-なし}" >&2; echo "[CONTEXT] ADOPTION_GATE_RC=2"; exit 1; }
echo "[CONTEXT] TRIAGE_REVIEW_JSON=$(basename "$review_json")"
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp -- "$records_file" "$work/records.json"
cp -- "$candidates_file" "$work/candidates.json"
adoption="$state_root/.rite/state/adoption-$pr-triage.json"
hold_file="$state_root/.rite/state/adoption-hold-$pr-triage.json"
# 判定記録にはその ids が指す候補の全文を同梱する（hold とは別に書かれるので、id の意味を hold から引かない）。
# issued は候補の全文（id 以外）ごとに最後に付いた tracker を run をまたいで残す（今回の候補に無い run を挟んでも消さない。
# 前の run の記録が付けた番号が古い番号を上書きする。キーは欄の順序によらない）。tracker の無い記録へは、全文が一致する候補の番号だけを持ち越す。
# 写せない tracker で止まるのは hold にある候補（手順 1 が一字も変えずに合流させる候補）だけ
prev_a=/dev/null; prev_h=/dev/null
[ -e "$adoption" ] && prev_a=$adoption
[ -e "$hold_file" ] && prev_h=$hold_file
mkdir -p "$state_root/.rite/state" \
  && jq --arg head "$head_sha" --slurpfile a "$prev_a" --slurpfile h "$prev_h" --slurpfile c "$work/candidates.json" '
      def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson;
      . as $records
      | (if ($a | length) > 0 then $a[0].adoption else {records: [], candidates: [], issued: {}} end) as $p
      | ([$p.candidates[] | {key: .id, value: del(.id)}] | from_entries) as $old
      | ($p.issued + ([$p.records[] | select(.tracker) | .tracker as $n
          | .ids[] | $old[.] | select(.) | {key: canon, value: $n}] | from_entries)) as $issued
      | ([$c[0].candidates[] | {key: .id, value: del(.id)}] | from_entries) as $new
      | [$c[0].candidates[] | del(.id)] as $now
      | [$h[].candidates[] | del(.id)] as $held
      | [$p.records[] | select(.tracker)
          | select(any(.ids[]; $old[.] as $o | $o and any($held[]; . == $o)))
          | select(all(.ids[]; $old[.] as $o | ($o | not) or (any($now[]; . == $o) | not)))
          | .tracker] as $lost
      | if ($lost | length) > 0
        then error("前の tracker \($lost) の候補が今回の候補にありません。hold の候補を一字も変えずに合流させて（手順 1）記録を書き直す") else . end
      | {adoption: {head: $head, candidates: $c[0].candidates, issued: $issued, write_keys: ($p.write_keys // {}), records: ($records | map(. as $r
          | if .tracker then . else
              ([$r.ids[] | $new[.] | select(.) | $issued[canon] | select(.)] | unique) as $t
              | if ($t | length) > 1
                then error("記録 \($r.ids) の候補に前の tracker が複数あります: \($t)。手順 2 でこの記録の tracker を明示するか、記録を分けて書き直す")
                elif ($t | length) == 1 then .tracker = $t[0] else . end
            end))}}' "$work/records.json" > "$adoption.tmp" \
  && mv -- "$adoption.tmp" "$adoption" \
  || { rm -f -- "$adoption.tmp"; echo "ERROR: 判定記録を書けません（原因は直前の出力）: $adoption" >&2; echo "[CONTEXT] ADOPTION_GATE_RC=2"; exit 1; }
issue_args=()
[ -z "$issue" ] || issue_args=(--issue "$issue")
rc=0
bash "$plugin_root"/hooks/scripts/review-adoption-gate.sh --pr "$pr" --kind triage \
  --state-root "$state_root" --candidates "$work/candidates.json" \
  --review-result "$review_json" --base "$base" --fix-loop "$fix_loop" "${issue_args[@]}" > "$work/gate.json" || rc=$?
cat "$work/gate.json"
# verdict が fix の根因（ADOPT・origin=pr）を PR 内推奨として登録する（fix が 0 件でもこの commit の登録を空で書き直す）
if [ "$rc" = 0 ]; then
  bash "$plugin_root/scripts/review-pr-recommendations.sh" record --pr "$pr" --review-result "$review_json" \
    --verdicts "$work/gate.json" --candidates "$work/candidates.json" --state-root "$state_root" \
    || { echo "ERROR: PR 内推奨を登録できません（原因は直前の出力）" >&2; rc=2; }
fi
# 7.4.3 / 7.4.4 が書き込み済みかを照合する印の key。C-n は run ごとに振り直すので使わない。
# 前の run で key を付けた候補（出口と全文が一致。id 以外、欄の順序によらない）を含む記録はその key を使い、無ければ出口と全候補の全文から作る。
# 付けた key は判定記録ファイルの write_keys に候補ごとに残す。再レビューが同じ根因を言い換えた候補を同じ記録に足しても、以後の run で key は変わらない。
# 記録の単位を前の run と変えると（別々の key を 1 記録に束ねる、1 つの key を複数記録に分ける）、どちらの印で照合するかを決められないので止める
if [ "$rc" = 0 ]; then
  sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
  keys="" written="{}"
  declare -A seen=()
  materials=$(jq -r --slurpfile c "$work/candidates.json" --slurpfile a "$adoption" '
      def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson;
      ([$c[0].candidates[] | {key: .id, value: del(.id)}] | from_entries) as $cand
      | $a[0].adoption.write_keys as $saved
      | .verdicts[] | select(.verdict != "fix") | .exit as $exit
      | [.ids[] | $cand[.] | canon] as $all
      | [$all[] | [$exit, .] | tojson] as $slots
      | ([$slots[] | $saved[.] | select(.)] | unique) as $prior
      | if ($prior | length) > 1
        then error("記録 \(.ids) の候補に前の run の key が複数あります（候補ごとの前の key: \([range(0; .ids | length) as $n | "\(.ids[$n])=\($saved[$slots[$n]] // "-")"] | join(", "))）。前の run と同じ単位に記録を分けて書き直す（手順 2）") else . end
      | "\(.ids | join(","))\t\($prior[0] // "-")\t\($slots | tojson)\t\([$exit, ($all | sort)] | tojson)"' "$work/gate.json") || rc=2
  while [ "$rc" = 0 ] && IFS=$'\t' read -r ids key slots material; do
    [ -n "$ids" ] || continue
    if [ "$key" = - ]; then key=$(printf '%s' "$material" | sha256) && key=${key:0:16} || { rc=2; break; }; fi
    [[ "$key" =~ ^[0-9a-f]{16}$ ]] || { rc=2; break; }
    if [ -n "${seen[$key]:-}" ]; then
      echo "ERROR: 記録 $ids と記録 ${seen[$key]} の候補は前の run で 1 つの記録でした（key $key）。前の run と同じ単位に記録を束ねて書き直す（手順 2）" >&2
      rc=2; break
    fi
    seen[$key]=$ids
    written=$(jq -c --arg k "$key" --argjson s "$slots" '. + ([$s[] | {key: ., value: $k}] | from_entries)' <<< "$written") || { rc=2; break; }
    keys+="[CONTEXT] TRIAGE_WRITE_KEY=$key; ids=$ids"$'\n'
  done <<< "$materials"
  if [ "$rc" = 0 ]; then
    jq --argjson w "$written" '.adoption.write_keys += $w' "$adoption" > "$adoption.tmp" && mv -- "$adoption.tmp" "$adoption" \
      || { rm -f -- "$adoption.tmp"; rc=2; }
  fi
  if [ "$rc" = 0 ]; then printf '%s' "$keys"; else echo "ERROR: 書き込み済みを照合する key を作れないか、判定記録ファイルに残せません（原因は直前の出力）" >&2; fi
fi
# decided でも 7.4 の外部への書き込みが済むまで、この run の候補を hold に残す（7.4.5 だけが消す）
if [ "$rc" = 0 ]; then
  jq --arg head "$head_sha" --arg rr "$review_json" --argjson pr "$pr" --arg pr_text "$pr" \
    '{kind: "triage", pr: $pr, head: $head, review_result: $rr, reason: "writes_pending", detail: "",
      held_ids: [], candidates: .candidates,
      resume: ("採否の出口は出たが、7.4 の外部への書き込みがまだ済んでいない。/rite:iterate " + $pr_text + " で再レビューし、7.2 から処分をやり直す")}' \
    "$work/candidates.json" > "$hold_file.tmp" && mv -- "$hold_file.tmp" "$hold_file" \
    || { rm -f -- "$hold_file.tmp"; echo "ERROR: triage の候補を hold に残せません: $hold_file" >&2; rc=2; }
fi
echo "[CONTEXT] ADOPTION_GATE_RC=$rc"
