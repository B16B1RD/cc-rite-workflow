### 7.2-7.3 採否の出口による処分

ゲートが `reconciliation[]` を返した場合は、親が [共通の裁定手順](../../../references/review-reconciliation.md) で既存候補だけを裁定し、当該 `adoption.records[]` に回答を付けて手順 3 のゲートへ戻る。`hold.detail` / `resume` が再開位置を示す。手順 2 の記録再利用とは別に、裁定は fingerprint の全入力が一致するときだけ再利用する。

`{state_root}` は `bash {plugin_root}/hooks/state-path-resolve.sh` の出力。7.1 の候補が 0 件かつ triage の hold ファイル `{state_root}/.rite/state/adoption-hold-{pr_number}-triage.json` が無いときだけステップ 7 を skip する（**7.7 も skip**）。hold ファイルがあれば候補 0 件でも下の手順でゲートを呼ぶ。候補ごとの処分は採否ゲート（`review-adoption-gate.sh --kind triage`）の出口だけで決める。人間に候補ごとの処分を尋ねない。`PR_REVIEW_IN_E2E` で処分を変えない（候補ごとの確認の有無も変えない）。例外は手順 3 の `{fix_loop}` だけで、`/rite:iterate` からの呼び出しかどうかで ADOPT・origin=pr の fix / hold が分かれる。

1. 7.1 の候補（Source A → Source B の抽出順、dedup 後）に `C-1`, `C-2`, … を振る。triage の hold ファイルがあれば、その `head` が本 cycle の review JSON の `commit_sha` と同じかどうかを問わず（commit を問わず）、その `candidates` の各候補を、id だけ次の `C-n` に振り直して内容は一字も変えずに候補集合へ加える（id を除く全欄が一致する候補が既にあれば加えない）。triage の候補はほかのどこにも残らないため、新しい commit でも合流させて分類役が判定し直す（直っていれば `RESOLVED`）。内容を言い換えるとゲートは同じ候補と認めず、保留が解けない（`held_candidates_dropped`。前の `tracker` を持つ記録の候補がすべて今回の候補から消えたときは、ゲートより前に手順 3 が止める）。
2. 分類役（本手順を実行する LLM）が全候補の判定記録を書く。1 根因 = 1 記録。欄は `review-adoption.py` の docstring に従い、起票（ADOPT pre_existing / 調査）になる記録には `acceptance`（起票する Issue の受入条件の文）を必ず入れる。既存の Issue（前回この手順で作った Issue を含む）が同じ根因を追跡していれば `tracker` に入れる（LINK になり、重ねて起票しない）。判定記録ファイル `{state_root}/.rite/state/adoption-{pr_number}-triage.json` があり、その `head` が本 cycle の review JSON の `commit_sha` と同じなら、その記録（保留後に直された記録）から始める（この head 条件は判定記録ファイルの再利用の条件で、手順 1 の合流の条件ではない）。`C-n` は振り直すため、各記録の `ids` は手順 1 で候補全文が一致した候補（合流させた hold の候補を含む）の新しい id へ移す（前の記録の `ids` が指す全文は判定記録ファイルの `candidates` で引き、hold からは引かない）。`head` が違えば記録を新しく書く。判定記録ファイルがあれば `head` を問わず、その `issued` と `tracker` を持つ記録（`ids` の全文は同じファイルの `candidates` で引く。記録の番号が `issued` の番号より新しい）を読み、既存の Issue が今回の候補と同じ根因を追跡していれば、文面・位置・id が変わっていても記録の `tracker` にその番号を入れる（閉じた Issue の番号は入れない）。手順 3 の bash は、`tracker` の無い記録のうち `issued` と全文（id を除く全欄）が一致する候補を含むものにだけ、その番号を持ち越す。7.4.2 が書き戻した `tracker` は消さない。前の run で異なる `tracker` を持った候補を 1 つの記録にまとめるなら、その記録の `tracker` を明示する（持ち越しは `tracker` の無い記録にだけ働き、複数の候補が衝突すると手順 3 が止まる）。
   台帳の処分を再利用するため、下の bash で却下台帳を読む。候補の `reviewer` と `file_line` が行の `finding_id` と `file:line` に一致する行のうち、最後の `REJECT` / `ADOPT` 行をその候補の記録の `prior`（`{finding_id, file_line, disposition, premise}`。premise は判定文）に写す（prior の違う候補を 1 つの記録にまとめない）。台帳の `REJECT` 行が同じ根因・同じ前提の候補を処分していれば、`reviewer`・`file_line` が違っていてもその行を記録の `prior` に写す（機械的に一致するのは `reviewer` と `file_line` が同じ行だけなので、位置や reviewer が変わった候補はここで紐づける）。前提が有効なら REJECT を再利用し、前提と矛盾する判定は helper が RECONCILE にする。`C-n` は cycle ごとに振り直すので台帳のキーにしない。`file_line` が空の候補には、`reviewer` と `file_line` の一致では prior を写さない（位置の無い候補どうしはキーが一意にならず、無関係な処分が写る）。同じ根因・同じ前提の `REJECT` 行は、位置の無い候補にも上の規則で写す。下の bash が非ゼロで終わったら、判定記録を書かず手順 3 へ進まない。`[review:error]` で止まる（台帳を読めないまま判定すると処分を再利用できない）。

```bash
body=$(mktemp) && err=$(mktemp) || { echo "[review:error]"; exit 1; }
trap 'rm -f "$body" "$err"' EXIT
if bash {plugin_root}/hooks/review-nonblocking-record.sh --print-record-body --pr {pr_number} --owner-repo {owner_repo} > "$body" 2> "$err"; then
  if [ -s "$body" ]; then
    bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$body" || { echo "[review:error]"; exit 1; }
  else
    # 記録コメントがまだ無い（非実測指摘も台帳もまだ無い）。台帳が無ければ prior も無い
    echo "[CONTEXT] TRIAGE_LEDGER=absent; reason=no_record_comment"
  fi
elif grep -q 'reason=related_issue_unresolved' "$err"; then
  echo "[CONTEXT] TRIAGE_LEDGER=absent; reason=related_issue_unresolved"
else
  cat "$err" >&2
  echo "ERROR: 却下台帳を読めません。prior を写さずに判定すると台帳の処分を再利用できないため、判定記録を書かずに止まる" >&2
  echo "[review:error]"; exit 1
fi
```
3. 下の bash を**単一 Bash invocation** で実行する。`{fix_loop}` は、`PR_REVIEW_FROM_ITERATE == true`（ステップ 1.0。`/rite:iterate` が `--from-iterate` を付けて呼んだ review）かつステップ 8.1 の出力表で `[review:mergeable]` に一致する review だけ `yes`（登録は `/rite:iterate` の 5.S 後の check が読み、同じ PR の `/rite:fix` が直す）。受入条件未検証の停止、単独実行、marker が見当たらないときは `no`（登録を読む工程が続かないため、ADOPT・origin=pr は hold になり、保留のまま止まる）。`PR_REVIEW_IN_E2E` は使わない（`/rite:open` の後や単独実行の review でも true になり、呼び出し元を区別できない）。`{records}` は記録の JSON 配列、`{candidates}` は `{"candidates": [{"id": "C-1", "source": "指摘" | "推奨", "file_line", "reviewer", "severity", "content": <全文>}, …]}`。`head` は `--review-result` に渡す review JSON（6.1.a が保存した本 cycle の結果）の `commit_sha` を bash が入れる。

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) && [ -n "$state_root" ] \
  || { echo "ERROR: state root を解決できません" >&2; echo "[CONTEXT] ADOPTION_GATE_RC=2"; exit 1; }
review_json=$(ls -1 "$state_root/.rite/review-results/{pr_number}"-*.json 2>/dev/null | LC_ALL=C sort | tail -1)
head_sha=$(jq -r '.commit_sha // empty' "$review_json" 2>/dev/null)
[ -n "$head_sha" ] || { echo "ERROR: 本 cycle の review JSON を読めません: ${review_json:-なし}" >&2; echo "[CONTEXT] ADOPTION_GATE_RC=2"; exit 1; }
echo "[CONTEXT] TRIAGE_REVIEW_JSON=$(basename "$review_json")"
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cat <<'RECORDS_EOF' > "$work/records.json"
{records}
RECORDS_EOF
cat <<'CANDIDATES_EOF' > "$work/candidates.json"
{candidates}
CANDIDATES_EOF
adoption="$state_root/.rite/state/adoption-{pr_number}-triage.json"
hold_file="$state_root/.rite/state/adoption-hold-{pr_number}-triage.json"
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
      | {adoption: {head: $head, candidates: $c[0].candidates, issued: $issued, records: ($records | map(. as $r
          | if .tracker then . else
              ([$r.ids[] | $new[.] | select(.) | $issued[canon] | select(.)] | unique) as $t
              | if ($t | length) > 1
                then error("記録 \($r.ids) の候補に前の tracker が複数あります: \($t)。手順 2 でこの記録の tracker を明示するか、記録を分けて書き直す")
                elif ($t | length) == 1 then .tracker = $t[0] else . end
            end))}}' "$work/records.json" > "$adoption.tmp" \
  && mv -- "$adoption.tmp" "$adoption" \
  || { rm -f -- "$adoption.tmp"; echo "ERROR: 判定記録を書けません（原因は直前の出力）: $adoption" >&2; echo "[CONTEXT] ADOPTION_GATE_RC=2"; exit 1; }
issue_args=()
[ -z "{source_issue_number}" ] || issue_args=(--issue "{source_issue_number}")
rc=0
bash {plugin_root}/hooks/scripts/review-adoption-gate.sh --pr {pr_number} --kind triage \
  --state-root "$state_root" --candidates "$work/candidates.json" \
  --review-result "$review_json" --base "origin/{base_branch}" --fix-loop "{fix_loop}" "${issue_args[@]}" > "$work/gate.json" || rc=$?
cat "$work/gate.json"
# verdict が fix の根因（ADOPT・origin=pr）を PR 内推奨として登録する（fix が 0 件でもこの commit の登録を空で書き直す）
if [ "$rc" = 0 ]; then
  bash {plugin_root}/scripts/review-pr-recommendations.sh record --pr {pr_number} --review-result "$review_json" \
    --verdicts "$work/gate.json" --candidates "$work/candidates.json" --state-root "$state_root" \
    || { echo "ERROR: PR 内推奨を登録できません（原因は直前の出力）" >&2; rc=2; }
fi
# 7.4.3 / 7.4.4 が書き込み済みかを照合する印の key。出口と候補全文（id 以外、欄の順序によらない）から作る。
# C-n は run ごとに振り直すので使わない。hold の候補は手順 1 が一字も変えずに合流させるので、再実行でも同じ key になる
if [ "$rc" = 0 ]; then
  sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
  keys=""
  materials=$(jq -r --slurpfile c "$work/candidates.json" '
      def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end) | tojson;
      ([$c[0].candidates[] | {key: .id, value: del(.id)}] | from_entries) as $cand
      | .verdicts[] | select(.verdict != "fix")
      | "\(.ids | join(","))\t\([.exit, ([.ids[] | $cand[.] | canon] | sort)] | tojson)"' "$work/gate.json") || rc=2
  while [ "$rc" = 0 ] && IFS=$'\t' read -r ids material; do
    [ -n "$ids" ] || continue
    key=$(printf '%s' "$material" | sha256) && key=${key:0:16} && [[ "$key" =~ ^[0-9a-f]{16}$ ]] || { rc=2; break; }
    keys+="[CONTEXT] TRIAGE_WRITE_KEY=$key; ids=$ids"$'\n'
  done <<< "$materials"
  if [ "$rc" = 0 ]; then printf '%s' "$keys"; else echo "ERROR: 書き込み済みを照合する key を作れません（原因は直前の出力）" >&2; fi
fi
# decided でも 7.4 の外部への書き込みが済むまで、この run の候補を hold に残す（7.4.5 だけが消す）
if [ "$rc" = 0 ]; then
  jq --arg head "$head_sha" --arg rr "$review_json" --argjson pr {pr_number} \
    '{kind: "triage", pr: $pr, head: $head, review_result: $rr, reason: "writes_pending", detail: "",
      held_ids: [], candidates: .candidates,
      resume: "採否の出口は出たが、7.4 の外部への書き込みがまだ済んでいない。/rite:iterate {pr_number} で再レビューし、7.2 から処分をやり直す"}' \
    "$work/candidates.json" > "$hold_file.tmp" && mv -- "$hold_file.tmp" "$hold_file" \
    || { rm -f -- "$hold_file.tmp"; echo "ERROR: triage の候補を hold に残せません: $hold_file" >&2; rc=2; }
fi
echo "[CONTEXT] ADOPTION_GATE_RC=$rc"
```

| `ADOPTION_GATE_RC` | 処置 |
|---|---|
| `0`（decided） | stdout の `verdicts[]` で 7.4 を実行する。7.4 の前に下の sentinel を emit する |
| `3`（held） | 7.4（Decision Log・先送りトークン・Issue 作成・申し送り）から 7.7 までを一切実行しない。sentinel も出さない。下の採否保留の停止を実行し、ステップ 8（8.0.2 を含む）へ進まない |
| それ以外 | `[review:error]` を出して停止する（ステップ 8 へ進まない） |

**採否保留の停止**（`{hold_file}` はゲート stdout の `hold_file`）。FINALIZE などの handoff が残ると Stop hook が完了経路へ差し戻すため、受入条件未検証の停止と同じく `--handoff` なしで set してから止まる:

```bash
# 採否保留の停止 (--handoff を付けず、残存 handoff を default-clear する):
if ! bash {plugin_root}/hooks/flow-state.sh set \
 --phase "review" \
 --active true \
 --next "採否の出口待ち。{hold_file} の resume（ゲートの WARNING にも出る）に従って再開" \
 --if-exists; then
  echo "WARNING: 採否保留の停止で handoff を消せませんでした" >&2
fi
echo "[review:error]"
echo "[CONTEXT] REVIEW_STOP=adoption_held; kind=triage; hold_file={hold_file}"
```

**MANDATORY — ステップ 7.2 disposition-entry sentinel emit**:

sentinel は **ゲートが decided を返した後** に emit する。marker 名は変えない。`mode=` と `choice=` と `reason=` を必須とする。**7.4 は本 sentinel の後でのみ実行する**:

```bash
# LLM (Claude) は以下を Bash tool で実行する前に literal 置換すること:
# - {N} → ステップ 7.1 の candidate_count (Source A + Source B の dedup 後に、合流させた hold の候補を含む)
# - {iteration_id} → ステップ 7.1 で生成した一意 ID (例: pr_number-$(date +%s) 形式)
# - {mode} → auto
# - {choice} → file:{A}/record:{B}/fix:{C}（verdicts[] の verdict 別の件数）。空禁止
# - {reason} → adoption_decided
# Bash 変数 (${candidate_count} 等) は Bash tool 呼び出し間で継承されないため使用不可
echo "[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={iteration_id}; mode={mode}; choice={choice}; reason={reason}" >&2
```

`{N}` は 7.1 の合算。`{iteration_id}` は iteration 一意（推奨: `${pr_number}-$(date +%s)`）。7.7 / 8.0.2 が読む。stderr に MUST emit。

### 7.4 Disposition Execution

ゲートの `verdicts[]`（判定記録 1 件ごと）を上から評価し、最初に一致した行を実行する。`record` 欄（判定記録の全文）が本文の材料になる:

| verdict / exit | Action |
|---|---|
| `fix` | 外部へ書かない。7.2 の bash が PR 内推奨（`R-NN`）として登録済みで、同じ PR の `/rite:fix` が直す（`PR_RECOMMENDATIONS=registered`）。7.4.3 も 7.4.5 の台帳行も書かない |
| `file`、`{source_issue_number}` あり | 7.4.3 を先送りトークン付きで実行する。起票は cleanup ステップ 6.0 の follow-up が行う（ここでは Issue を作らない） |
| `file`、`{source_issue_number}` が空 | トークンの書き先が無いため 7.4.1-7.4.2 で Issue を 1 件作る |
| `record`（`LINK`） | 7.4.4（追跡先 `tracker` への申し送り）を先に必須実行し、記録のみで完了扱いにしない。その後 7.4.3（トークンなし）。`HANDOFF_COMMENT_ALREADY_POSTED=1` は投稿済みとして 7.4.3 へ進む。`HANDOFF_COMMENT_REJECTED=1` のときは 7.4.3 / 7.5 へ進まない |
| `record`（`RESOLVED` / `REJECT`） | 7.4.3（トークンなし） |

全判定記録の処分を終えたら 7.4.5（台帳への記録と保留の解除）を 1 回実行する。

7.4.3 / 7.4.4 は、書いた行・コメントに印 `<!-- rite:triage-write pr={pr_number} key={write_key} -->` を付け、書く前に同じ印を探す。印があれば書かない。このため途中で止まった処分を 7.2 からやり直しても、同じ判定記録の Decision Log 行と申し送りコメントは 1 件のままになる。`{write_key}` は、7.2 の bash が出した `[CONTEXT] TRIAGE_WRITE_KEY=<key>; ids=<ids>` のうち、その判定記録の `ids` の行の値である。
rationale: design-rationale.md#triage-write-mark

`record` で `{source_issue_number}` が空なら 7.4.3 の書き先が無いため、7.5-7.6 の完了レポートに出口と reason を列挙する。
7.4.1-7.4.2 は `gh issue create` + Projects 登録。`/rite:issue-create` Skill は使わない。
Issue creation failure reasons: (`body_tmpfile_write_failure` / `empty_body_tmpfile` / `empty_script_result` / `create_failed` / `tracker_write_failed`)

| reason | Description |
|--------|-------------|
| `body_tmpfile_write_failure` | Issue body heredoc write to tmpfile failed |
| `empty_body_tmpfile` | Issue body tmpfile is empty after write |
| `empty_script_result` | create-issue-with-projects.sh returned empty result |
| `create_failed` | create-issue-with-projects.sh returned an empty `issue_url` or a non-positive `issue_number` |
| `tracker_write_failed` | The created number cannot be written back as the `tracker` of the record (`issue=` names it) |

#### 7.4.1 Generate Issue Title

```
{type}: {summary}
```

| Element | Generation Method |
|---------|-------------------|
| `{type}` | Inferred from the finding content (`fix`, `feat`, `refactor`, `docs`, etc.) |
| `{summary}` | Summarize the finding's description (50 characters or less, starting with a verb) |

#### 7.4.2 Create Issue via Common Script

> **Reference**: [Issue Creation with Projects Integration](../../../references/issue-create-with-projects.md)

heredoc の `{placeholder}` はスクリプト生成前に埋める（shell 変数ではない）。**判定記録ごとに単一 Bash invocation**（同じ記録の候補 `ids` は 1 件にまとめ、違う記録を混ぜない）。
`{record_ids}` はその判定記録の `ids`（JSON 配列）。`{contract}` / `{evidence}` / `{acceptance}` はゲート出力の `record` の `contract`（ref と引用文）/ `evidence` / `acceptance` をそのまま入れる。調査（`action` が `investigate`）は `{evidence}` に `proposition` の claim / reach / reach_source / done も入れる。
Priority: CRITICAL→High, HIGH→Medium, MEDIUM/LOW-MEDIUM/LOW→Low, Source B→Medium。
Complexity: XS = 単箇所、S = 1–2 ファイル。

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `{owner}` |
| `{iteration_mode}` | `rite-config.yml` → `iteration.enabled` が `true` かつ `iteration.auto_assign` が `true` なら `"auto"`、それ以外は `"none"` | `"none"` |
| `{plugin_root}` | [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) | `/home/user/.claude/plugins/rite` |

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

if ! cat <<'BODY_EOF' > "$tmpfile"
**Type**: {type}
**Complexity**: {complexity}

## 概要

{description}

- **契約**: {contract}
- **根拠**: {evidence}
- **受入条件**: {acceptance}

## 背景

この Issue は PR #{pr_number} のレビューで検出されたスコープ外の{source_label}から作成されました。

### 元のレビュー{source_label}
- **ファイル**: {file}:{line}
- **レビュアー**: {reviewer_type}
- **重要度**: {severity}
- **{source_label}内容**: {original_comment}

## 関連

- 元の PR: #{pr_number}
BODY_EOF
then
 echo "ERROR: Issue 本文テンプレートの一時ファイル書き込みに失敗" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=body_tmpfile_write_failure" >&2
 exit 1
fi

if [ ! -s "$tmpfile" ]; then
 echo "ERROR: Issue 本文の生成に失敗" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_body_tmpfile" >&2
 exit 1
fi

# jq -n の出力を stdin で create-issue-with-projects.sh に渡す。
# 旧コードは jq 出力をコマンド置換でスクリプト引数に入れ子展開していたが、パイプ + 1 段の
# コマンド置換に削減して malform 確率を下げた (入れ子コマンド置換の literal 例は除去済)。
result=$(jq -n \
 --arg title "{type}: {summary}" \
 --arg body_file "$tmpfile" \
 --argjson projects_enabled {projects_enabled} \
 --argjson project_number {project_number} \
 --arg owner "{owner}" \
 --arg priority "{priority}" \
 --arg complexity "{complexity}" \
 --arg iter_mode "{iteration_mode}" \
 '{
 issue: { title: $title, body_file: $body_file },
 projects: {
 enabled: $projects_enabled,
 project_number: $project_number,
 owner: $owner,
 status: "todo",
 priority: $priority,
 complexity: $complexity,
 iteration: { mode: $iter_mode }
 },
 options: { source: "pr_review", non_blocking_projects: true }
 }' | bash {plugin_root}/scripts/create-issue-with-projects.sh)

if [ -z "$result" ]; then
 echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_script_result" >&2
 exit 1
fi
# gh の作成失敗は空の issue_url と exit 1 で返る（nb-sweep 手順 2 と同じ検査）
if ! printf '%s' "$result" | jq -e '.issue_number > 0 and (.issue_url | type == "string" and length > 0)' >/dev/null; then
 printf '%s' "$result" | jq -r '.warnings[]?' 2>/dev/null | while read -r w; do echo "⚠️ $w" >&2; done
 echo "ERROR: Issue を作成できませんでした" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=create_failed" >&2
 exit 1
fi
# 作った番号を判定記録の tracker に書き戻す。再実行するとゲートはこの記録を LINK にし、同じ根因を二度起票しない。
# 一致する記録が無いまま成功扱いにすると書き戻しが空振りするので、失敗にする
triage_adoption="$(bash {plugin_root}/hooks/state-path-resolve.sh)/.rite/state/adoption-{pr_number}-triage.json"
created_issue_number=$(printf '%s' "$result" | jq '.issue_number')
if ! jq --argjson ids '{record_ids}' --argjson n "$created_issue_number" \
     'if any(.adoption.records[]; .ids == $ids) then (.adoption.records[] | select(.ids == $ids) | .tracker) = $n
      else error("ids \($ids) の記録がありません") end' "$triage_adoption" > "$triage_adoption.tmp" ||
   ! mv -- "$triage_adoption.tmp" "$triage_adoption"; then
 rm -f -- "$triage_adoption.tmp"
 echo "ERROR: 作成した #$created_issue_number を $triage_adoption の記録の tracker に書き戻せません。書き戻してから再実行する（書かずに再実行すると同じ根因を二度起票する）" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=tracker_write_failed; issue=$created_issue_number" >&2
 exit 1
fi
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Source-aware placeholder values**: The `{source_label}` placeholder in the heredoc template above must be substituted based on the candidate source. When from Source A (findings), use `指摘`. When from Source B (recommendations), use `推奨事項`. The `{severity}` placeholder uses the actual severity for Source A, or `推奨事項（重要度なし）` for Source B. The `{file}:{line}` placeholder uses `特定ファイルなし` for Source B when no file path is mentioned.

**Error handling**:

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` or a non-positive `issue_number` | `ISSUE_CREATE_FAILED=1; reason=create_failed`。残りの記録の作成は続け、失敗は 7.4.5 の `{write_failures}` に数える（7.4.5 が採否保留として止まる） |
| The created number cannot be written back as the record's `tracker` | `ISSUE_CREATE_FAILED=1; reason=tracker_write_failed; issue=N`。同じく 7.4.5 に数え、番号を 7.4.5 の `{untracked_issues}` に渡す（resume が再実行の前に `tracker` へ入れるよう案内する） |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Issue creation itself succeeded |

#### 7.4.3 Decision Log Append

7.4 表が 7.4.3 へ送った判定記録を、元 Issue の Section 9 へ 1 行 append する。番号は Section 9 の内側（見出しの次行から `## ` / `---` / `</details>` まで）の最大 D-NN に 1 を足す。無ければ本文に Section 9 を新設して `D-01` を記録する。本文にこの判定記録の印が既にあれば書かず、`DECISION_LOG_ALREADY_WRITTEN=1` を出す（書き込み済み。失敗に数えない）。
`{decision}` / `{reason}` / `{impact}` / `{deferred_token}` / `{write_key}` を生成前に埋める。**判定記録ごとに単一 Bash invocation**。
rationale: design-rationale.md#decision-log-per-candidate

| verdict | `{decision}` | `{reason}` | `{impact}` |
|---|---|---|---|
| `file` | `{exit} {ids}: {根因の要約}。契約: {contract の ref と引用文}` | `record.evidence`（根拠。調査は `proposition` の claim / reach / reach_source / done も） | `受入条件: {record.acceptance}` |
| `record` | `{exit} {ids}: {根因の要約}` | `record.reason`（`LINK` は `追跡先 #{tracker}` を先頭に付ける。`RESOLVED` は解消の根拠） | 再検討する条件 |

| 候補 | `{deferred_token}` |
|---|---|
| 採否ゲートの verdict が `file` | ` <!-- rite:deferred-defect pr={pr_number} -->`（先頭に半角空白 1 つ。`{pr_number}` は本レビューの PR 番号） |
| それ以外（verdict が `record`） | 空文字列 |

トークン付きの行は cleanup ステップ 6.0 が follow-up Issue へ転記して起票する。
rationale: design-rationale.md#deferred-defect-token

```bash
today=$(date +%Y-%m-%d)

# 印の key が 16 桁の hex でなければ書かない（未置換の印は別の判定記録の行と一致してしまう）
write_key="{write_key}"
if ! [[ "$write_key" =~ ^[0-9a-f]{16}$ ]]; then
  echo "ERROR: 判定記録の key が不正です (write_key='$write_key')。7.2 の TRIAGE_WRITE_KEY の値を入れる" >&2
  echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=write_key_invalid; issue={source_issue_number}" >&2
  exit 0
fi
write_mark="<!-- rite:triage-write pr={pr_number} key=$write_key -->"

# {decision}/{reason}/{impact} は reviewer/レビュー指摘由来の free-text。quoted heredoc
# (`<<'DECISION_EOF'`) でシェル展開を無害化してから読み込む（`line_content="{decision} ..."`
# のような直接代入は backtick / `$(` / `"` 混入時にコマンド置換・文字列破壊を招くため禁止）。
# 印は先送りトークンの直前に置く（トークンは行末のまま）
decision_tmp=$(mktemp)
if ! cat <<'DECISION_EOF' > "$decision_tmp"
{decision} / Reason: {reason} / Impact: {impact} <!-- rite:triage-write pr={pr_number} key={write_key} -->{deferred_token}
DECISION_EOF
then
  echo "ERROR: Decision Log 行テンプレートの一時ファイル書き込みに失敗" >&2
  echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=line_content_write_failure; issue={source_issue_number}" >&2
  rm -f "$decision_tmp"
  exit 1
fi
line_content=$(tr -d '\n' < "$decision_tmp")
rm -f "$decision_tmp"

body=$(gh issue view {source_issue_number} -R {owner_repo} --json body --jq '.body')

if [ -z "$body" ]; then
  echo "WARNING: 元 Issue #{source_issue_number} の body 取得に失敗。Decision Log 記録をスキップします" >&2
  echo "記録予定行（7.4.5 で止まった後の再実行が書くので、手で追記しない）: - ${today} D-NN: ${line_content}" >&2
  echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=body_fetch_failure; issue={source_issue_number}" >&2
elif grep -qF -- "$write_mark" <<< "$body"; then
  echo "[CONTEXT] DECISION_LOG_ALREADY_WRITTEN=1; issue={source_issue_number}; key=$write_key"
elif grep -q '^## 9\. Decision Log' <<< "$body"; then
  # 採番は Section 9 の内側だけを数える。本文の散文（転記されたレビュー指摘等）にある D-NN を
  # 数えると番号が飛ぶ。境界は下の追記 awk と同じ。awk の後ろにパイプを繋ぐと終了コードが
  # 失われるため、awk 単体の出力と終了コードを取ってから D-NN を抽出する。
  awk_rc=0
  section9=$(printf '%s\n' "$body" | awk '
    /^## 9\. Decision Log/ { in_section=1; next }
    in_section && (/^## / || /^---[[:space:]]*$/ || /^<\/details>/) { in_section=0 }
    in_section { print }
  ') || awk_rc=$?
  # `(^|[^A-Za-z])D-[0-9]+` で先頭境界を要求し、`CARD-12` 等の部分文字列誤マッチを防ぐ。
  # 境界の 1 文字も match に含まれるため、`D-[0-9]+` だけを取り出してから数字を読む（`9D-02` の 9 を数えない）
  max_d=$(printf '%s\n' "$section9" | grep -oE '(^|[^A-Za-z])D-[0-9]+' | grep -oE 'D-[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
  [ -n "$max_d" ] || max_d=0
  # 10# で 10 進固定。先頭ゼロ付き 08/09 を 8 進と解釈させない
  next_num=$((10#$max_d + 1))
  next_d=$(printf 'D-%02d' "$next_num")
  # 走査が異常終了した番号は信用できないため、記録予定行でも番号を確定させない
  [ "$awk_rc" -eq 0 ] || next_d=D-NN
  new_line="- ${today} ${next_d}: ${line_content}"

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT
  # `awk -v` はバックスラッシュエスケープを解釈するため（`\n`→改行, `\t`→タブ, `\d`→`d` 等）、
  # $new_line に正規表現例・Windows パス等 backslash を含む free-text が入ると「1 行 append」
  # 不変条件を破って複数行に分割されうる。ENVIRON はエスケープ解釈しないため経由する。
  printf '%s\n' "$body" | NEW_LINE="$new_line" awk '
    /^## 9\. Decision Log/ { print; in_section=1; next }
    in_section && (/^## / || /^---[[:space:]]*$/ || /^<\/details>/) { print ENVIRON["NEW_LINE"]; print; in_section=0; next }
    { print }
    END { if (in_section) print ENVIRON["NEW_LINE"] }
  ' > "$tmpfile" || awk_rc=$?

  # awk 異常終了時（部分出力）で body 全体を切り詰めたまま上書きしないよう、exit code も検査する
  # （full-body PATCH のため `[ -s ]` の非空チェックだけでは途中終了の部分出力を見逃す）。
  if [ "$awk_rc" -eq 0 ] && [ -s "$tmpfile" ] && gh issue edit {source_issue_number} -R {owner_repo} --body-file "$tmpfile"; then
    echo "[CONTEXT] DECISION_LOG_APPENDED=1; issue={source_issue_number}; entry=$next_d"
    echo "記録: $new_line"
  else
    echo "WARNING: 元 Issue #{source_issue_number} への Decision Log append に失敗しました" >&2
    echo "記録予定行（7.4.5 で止まった後の再実行が書くので、手で追記しない）: $new_line" >&2
    echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=gh_edit_failure; issue={source_issue_number}" >&2
  fi
else
  # Section 9 が無い Issue → 本文に Section 9 を新設して D-01 を記録する。
  # 置き場所は Implementation Contract の </details> の直前（pr-create が読む契約層の内側）。
  # 無ければ署名行だけが後に続くフッター区切り `---` の直前、どちらも無ければ本文末尾。
  # 本文の自由記述に混ざる `---` / `</details>` は境界とみなさない。挿入行以外は 1 文字も変えない。
  new_line="- ${today} D-01: ${line_content}"

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT
  awk_rc=0
  # 1 回目で挿入する行番号を決め（0 は本文末尾）、2 回目でその行の直前に挿入する
  insert_at=$(printf '%s\n' "$body" | awk '
    /^<summary>Implementation Contract/ { contract = 1 }
    contract && /^<\/details>/ { details = NR }
    /^---[[:space:]]*$/ { rule = NR; footer = 1; next }
    rule && !/^[[:space:]]*$/ && !/^🤖 / { footer = 0 }
    END { print (details ? details : ((rule && footer) ? rule : 0)) }
  ') || awk_rc=$?
  printf '%s\n' "$body" | NEW_LINE="$new_line" INSERT_AT="$insert_at" awk '
    NR == ENVIRON["INSERT_AT"] + 0 { print "## 9. Decision Log"; print ""; print ENVIRON["NEW_LINE"]; print "" }
    { print }
    END { if (ENVIRON["INSERT_AT"] + 0 == 0) { print ""; print "## 9. Decision Log"; print ""; print ENVIRON["NEW_LINE"] } }
  ' > "$tmpfile" || awk_rc=$?

  # 既存 Section 9 分岐と同じく、awk の異常終了（部分出力）と空出力のどちらでも書き戻さない。
  if [ "$awk_rc" -eq 0 ] && [ -s "$tmpfile" ] && gh issue edit {source_issue_number} -R {owner_repo} --body-file "$tmpfile"; then
    echo "[CONTEXT] DECISION_LOG_APPENDED=1; issue={source_issue_number}; entry=D-01; section=created"
    echo "記録: $new_line"
  else
    echo "WARNING: 元 Issue #{source_issue_number} への Decision Log append に失敗しました" >&2
    echo "記録予定行（7.4.5 で止まった後の再実行が書くので、手で追記しない）: $new_line" >&2
    echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=gh_edit_failure; issue={source_issue_number}" >&2
  fi
fi
```

Decision Log append failure reasons: (`write_key_invalid` / `line_content_write_failure` / `body_fetch_failure` / `gh_edit_failure`)

| reason | Description |
|--------|-------------|
| `write_key_invalid` | `{write_key}` が 16 桁の hex でない（未置換を含む）。書き込み済みかを照合できないため書かない |
| `line_content_write_failure` | Decision Log 行テンプレートの一時ファイル書き込みに失敗 |
| `body_fetch_failure` | 元 Issue の body 取得（`gh issue view`）に失敗。書き込み済みかを照合できないため書かない |
| `gh_edit_failure` | Section 9 の採番走査・行挿入、または Section 9 新設時の本文組み立て（awk）の異常終了 / 空出力、または `gh issue edit` 適用に失敗 |

失敗しても残りの判定記録の 7.4 は続け、失敗は 7.4.5 の `{write_failures}` に数える（7.4.5 が採否保留として止まる）。WARNING と記録予定行を出す（再実行が書くので手で追記しない）。

#### 7.4.4 引き受け先 Issue への申し送りコメント

出口が `LINK` の判定記録ごとに、追跡先 `{assignee_issue}` へ実行する。Decision Log のみでは完了にしない。
rationale: design-rationale.md#assignee-handoff-comment

heredoc の `{placeholder}` はスクリプト生成前に埋める（shell 変数ではない）。**判定記録ごとに単一 Bash invocation**。

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{assignee_issue}` | `LINK` の判定の `tracker`（追跡先の既存 Issue 番号）。`{source_issue_number}`（元 Issue）および 7.2 sentinel の `{N}`（candidate 総数）と混同しない | `12` |
| `{owner_repo}` | [Owner/Repo Resolution](../../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) の slash 形式 | `owner/repo` |
| `{pr_number}` | 本レビューの PR 番号 | `42` |
| `{summary}` | 当該判定記録の根因の要約 | （1 段落） |
| `{check_points}` | 引き受け先で着手するときの確認点 | （箇条書き） |
| `{write_key}` | 7.2 の `TRIAGE_WRITE_KEY` のうち、当該判定記録の `ids` の行の値 | `0123456789abcdef` |

1. `gh issue view {assignee_issue} -R {owner_repo} --json state --jq '.state'`
2. `OPEN` 以外 → 投稿しない。`[CONTEXT] HANDOFF_COMMENT_REJECTED=1; issue={assignee_issue}; reason=closed` を emit し、判定記録の `tracker` を直して 7.2 のゲートからやり直す（7.4.3 / 7.5 へ進まない）
3. `OPEN` → 追跡先のコメントを全ページ読み、この判定記録の印を探す。読めなければ投稿しない（`HANDOFF_COMMENT_FAILED=1; ...; reason=comments_fetch_failure`）。印があれば投稿済みとして投稿しない（`[CONTEXT] HANDOFF_COMMENT_ALREADY_POSTED=1; issue={assignee_issue}; key=...`。失敗に数えない）
4. 印が無ければ `--body-file` で申し送りを投稿（指摘要約・元 PR・着手時確認点・印）。成功は `[CONTEXT] HANDOFF_COMMENT_POSTED=1; issue={assignee_issue}`。失敗は WARNING + `[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue={assignee_issue}; reason=gh_comment_failure`（7.4.5 の `{write_failures}` に数える）

```bash
assignee_issue={assignee_issue}
owner_repo={owner_repo}
# 印の key が 16 桁の hex でなければ投稿しない（未置換の印は別の判定記録のコメントと一致してしまう）
write_key="{write_key}"
if ! [[ "$write_key" =~ ^[0-9a-f]{16}$ ]]; then
  echo "ERROR: 判定記録の key が不正です (write_key='$write_key')。7.2 の TRIAGE_WRITE_KEY の値を入れる" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=write_key_invalid" >&2
  exit 0
fi
write_mark="<!-- rite:triage-write pr={pr_number} key=$write_key -->"

state=$(gh issue view "$assignee_issue" -R "$owner_repo" --json state --jq '.state' 2>/dev/null || echo "")
if [ "$state" != "OPEN" ]; then
  echo "ERROR: 引き受け先 Issue #${assignee_issue} は ${state:-取得失敗} のため引き受け先にできない。triage 判定を 7.2 へ差し戻す" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_REJECTED=1; issue=$assignee_issue; reason=closed" >&2
  exit 0
fi

# 投稿済みかを全ページのコメントで照合する（1 ページ目だけだと古い申し送りを見落として重ねて投稿する）
comments_unreadable() {
  echo "WARNING: 引き受け先 Issue #${assignee_issue} のコメントを読めないため、投稿済みかを照合できず申し送りを投稿しません" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=comments_fetch_failure" >&2
  exit 0
}
comments=$(gh api --paginate --slurp "repos/$owner_repo/issues/$assignee_issue/comments") || comments_unreadable
found_rc=0
jq -e --arg m "$write_mark" 'any(.[][]; (.body // "") | contains($m))' <<< "$comments" > /dev/null || found_rc=$?
case "$found_rc" in
  0) echo "[CONTEXT] HANDOFF_COMMENT_ALREADY_POSTED=1; issue=$assignee_issue; key=$write_key"; exit 0 ;;
  1) ;;
  *) comments_unreadable ;;
esac

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
if ! cat <<'HANDOFF_EOF' > "$tmpfile"
## 申し送り（PR #{pr_number} レビューのスコープ外指摘）

### 指摘の要約
{summary}

### 元 PR
#{pr_number}

### 着手時の確認点
{check_points}

<!-- rite:triage-write pr={pr_number} key={write_key} -->
HANDOFF_EOF
then
  echo "WARNING: 申し送りコメント本文の一時ファイル書き込みに失敗" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=body_write_failure" >&2
  exit 0
fi

if gh issue comment "$assignee_issue" -R "$owner_repo" --body-file "$tmpfile"; then
  echo "[CONTEXT] HANDOFF_COMMENT_POSTED=1; issue=$assignee_issue"
else
  echo "WARNING: 引き受け先 Issue #${assignee_issue} への申し送りコメント投稿に失敗しました" >&2
  echo "[CONTEXT] HANDOFF_COMMENT_FAILED=1; issue=$assignee_issue; reason=gh_comment_failure" >&2
fi
```

Handoff comment failure reasons: (`write_key_invalid` / `closed` / `comments_fetch_failure` / `body_write_failure` / `gh_comment_failure`)

| reason | Description |
|--------|-------------|
| `write_key_invalid` | `{write_key}` が 16 桁の hex でない（未置換を含む）。投稿済みかを照合できないため投稿しない |
| `closed` | 引き受け先 Issue が OPEN でない（CLOSED または state 取得失敗） |
| `comments_fetch_failure` | 引き受け先 Issue のコメント一覧を取得・解析できない。投稿済みかを照合できないため投稿せず、7.4.5 の `{write_failures}` に数える |
| `body_write_failure` | 申し送り本文の一時ファイル書き込みに失敗 |
| `gh_comment_failure` | `gh issue comment` が非ゼロ終了（権限・ネットワーク） |

`HANDOFF_COMMENT_REJECTED=1` を観測したら当該判定記録の 7.4.3 を実行せず 7.5 へ進まない。投稿に失敗しても残りの 7.4 は続け、失敗は 7.4.5 の `{write_failures}` に数える（7.4.5 が採否保留として止まる）。

#### 7.4.5 台帳への記録と保留の解除

全判定記録の 7.4 を実行し終えたら 1 回だけ実行する（`HANDOFF_COMMENT_REJECTED=1` で 7.2 へ戻るときは実行しない）。verdict が `record`（`REJECT` / `RESOLVED` / `LINK`）の記録の候補のうち `file_line` のあるものを、却下台帳へ 1 候補 1 行で書く。`file_line` が空の候補は `REJECT` の行だけを `{file_line}` に `-` を入れて書く（位置の無い候補どうしは台帳のキーが一意にならないので機械的な一致には使わず、再報告されたときに手順 2 の分類役が同じ根因・同じ前提の処分として紐づける）。行形式は `| {reviewer} | {file_line} | {exit} | {判定文} | {review_json_basename} |`。判定文は記録の `reason`（`RESOLVED` で reason が無ければ `evidence`、`LINK` は `追跡先 #{tracker}`）、`{review_json_basename}` は 7.2 の bash が出した `[CONTEXT] TRIAGE_REVIEW_JSON=` の値。セル内のパイプ・改行はエスケープする。書く行が無ければ `{rows}` は空にする。`{write_failures}` は、この 7.4 の実行で出た `ISSUE_CREATE_FAILED=1` / `DECISION_LOG_APPEND_FAILED=1` / `HANDOFF_COMMENT_FAILED=1` の件数。書き込み済みの印を見つけた `DECISION_LOG_ALREADY_WRITTEN=1` / `HANDOFF_COMMENT_ALREADY_POSTED=1` は数えない。`{untracked_issues}` は `reason=tracker_write_failed` の marker の `issue=` を `#N` にして空白で並べたもの（無ければ空）。最後に triage の hold ファイルを消す。hold は 7.2 の bash がゲートの decided の後に必ず書いている（その run の候補の全文）。外部への書き込み（Decision Log・先送りトークン・Issue・申し送り・台帳）がすべて成功するまで hold を残すのは、途中で止まった再実行でも hold の候補を手順 1 が合流させるため。

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) && [ -n "$state_root" ] \
  || { echo "ERROR: state root を解決できません" >&2; echo "[review:error]"; exit 1; }
hold_file="$state_root/.rite/state/adoption-hold-{pr_number}-triage.json"
work=$(mktemp -d) || { echo "[review:error]"; exit 1; }
trap 'rm -rf "$work"' EXIT
cat <<'ROWS_EOF' > "$work/rows.md"
{rows}
ROWS_EOF
# 書き込みが済んでいない。hold を残し、その resume を失敗した書き込みの直し方に書き換えて、採否保留の停止で止まる
triage_stop() {
  echo "[CONTEXT] TRIAGE_LEDGER=failed; reason=$1" >&2
  resume="7.4 の外部への書き込み（$1）が済んでいない。stderr の原因（gh 認証・ネットワーク・権限）を解消してから /rite:iterate {pr_number} で再レビューする。再実行は 7.2 から始まり、同じ候補で 7.4 を最初からやり直す（書き込み済みの Decision Log 行と申し送りコメントは印で照合して書かない）。7.4.1-7.4.2 で作った Issue は判定記録の tracker に書き戻してあり、7.2 が同じ候補の記録へ持ち越すので LINK になる"
  untracked="{untracked_issues}"
  [ -z "$untracked" ] || resume="${resume}。ただし ${untracked} は tracker に書き戻せていない。再実行の前に $state_root/.rite/state/adoption-{pr_number}-triage.json の該当する記録の tracker に入れる（入れずに再実行すると同じ根因を二度起票する）"
  next="$hold_file の resume に従って再開"
  jq --arg r "$resume" '.resume = $r' "$hold_file" > "$hold_file.tmp" && mv "$hold_file.tmp" "$hold_file" \
    || { echo "WARNING: hold ファイルの resume を書き換えられませんでした: ${hold_file}。再開方法: ${resume}" >&2; next="再開方法: ${resume}"; }
  bash {plugin_root}/hooks/flow-state.sh set --phase "review" --active true \
    --next "採否の出口は出たが外部への書き込みが済んでいない。$next" --if-exists \
    || echo "WARNING: 採否保留の停止で handoff を消せませんでした" >&2
  echo "[review:error]"
  echo "[CONTEXT] REVIEW_STOP=adoption_held; kind=triage; hold_file=$hold_file"
  exit 1
}
[ "{write_failures}" = 0 ] || triage_stop writes_incomplete
if grep -q '^| ' "$work/rows.md"; then
  if ! bash {plugin_root}/hooks/review-nonblocking-record.sh --print-record-body --pr {pr_number} \
      --owner-repo {owner_repo} > "$work/body.md" 2> "$work/body.err"; then
    cat "$work/body.err" >&2
    grep -q 'reason=related_issue_unresolved' "$work/body.err" || triage_stop fetch_failed
    # 関連 Issue が無ければ台帳も無い。7.5-7.6 の完了レポートに記録できなかった出口として列挙する
    echo "[CONTEXT] TRIAGE_LEDGER=absent; reason=related_issue_unresolved" >&2
  else
    [ -s "$work/body.md" ] || printf '%s\n\n%s\n\n%s\n%s\n\n%s\n' \
      '## 📜 rite 非実測指摘の記録 (non-blocking)' \
      '本 cycle の非実測指摘: 0 件 (前 cycle の記録内容は本 cycle では再報告されていません)' \
      '📎 non_blocking_count: 0' '📎 reviewed_commit: unknown' '<!-- rite:nbr:v1 -->' > "$work/body.md"
    bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$work/body.md" > "$work/ledger.md" \
      && bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh append --ledger-file "$work/ledger.md" --entries-file "$work/rows.md" \
      && bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh merge-into --body-file "$work/body.md" --ledger-file "$work/ledger.md" \
      || triage_stop ledger_edit_failed
    # 件数の抽出式は review-nonblocking-record.sh の count/body 整合検査と同じ（nb-sweep 手順 3 と同じ）
    count=$(grep -E '^📎 non_blocking_count:[[:space:]]*[0-9]+[[:space:]]*$' "$work/body.md" | tail -1 | grep -oE '[0-9]+')
    [ -n "$count" ] || triage_stop count_unreadable
    rc=0
    bash {plugin_root}/hooks/review-nonblocking-record.sh --pr {pr_number} --owner-repo {owner_repo} --count "$count" \
      --iteration-id "triage-{pr_number}" --content-file "$work/body.md" 2> "$work/record.err" || rc=$?
    cat "$work/record.err" >&2
    outcome=$(sed -n 's/^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; .*outcome=\([^;]*\);.*/\1/p' "$work/record.err" | tail -1)
    case "$rc:$outcome" in 0:created|0:updated) ;; *) triage_stop record_failed ;; esac
    echo "[CONTEXT] TRIAGE_LEDGER=recorded" >&2
  fi
fi
rm -f -- "$hold_file"
```

`TRIAGE_LEDGER=failed`（`writes_incomplete` / `fetch_failed` / `ledger_edit_failed` / `count_unreadable` / `record_failed`）は hold ファイルを残し、その resume を書き換えてから、7.2 と同じ採否保留の停止（`REVIEW_STOP=adoption_held; kind=triage`）で止まる。iterate はこの停止を再試行しない。再実行は 7.2 から始まり、同じ候補で 7.4 を最初からやり直す。書き込み済みの Decision Log 行と申し送りコメントは印で照合して書かず、未完了の書き込みだけが行われる。7.4.1-7.4.2 で作った Issue は判定記録の `tracker` に書き戻してあり、7.2 手順 3 が（HEAD が変わって記録を新しく書いても）判定記録の `issued` から全文の一致する記録へ持ち越すので、再実行でゲートが LINK にし、重ねて起票しない。書き戻せなかった番号（`{untracked_issues}`）は resume（hold に書けなければ stderr の WARNING と flow-state の次アクション）が名指しし、再実行の前に `tracker` へ入れるよう案内する。

### 7.5-7.6 Append to PR & Report

7.4.1-7.4.2 で作った Issue の一覧を PR コメントへ（`mktemp` + `--body-file`）。verdict 別の件数（`file` は cleanup の follow-up で起票される件数、`fix` は同じ PR で直す PR 内推奨の件数）、元 Issue が無く記録できなかった `record` の出口と reason、`DECISION_LOG_APPENDED=1` の件数と `HANDOFF_COMMENT_POSTED=1`、書き込み済みとして書かなかった `DECISION_LOG_ALREADY_WRITTEN=1` / `HANDOFF_COMMENT_ALREADY_POSTED=1` の件数を completion report に転記する（7.4 の書き込みに失敗があれば 7.4.5 が止まり、ここへは来ない）。

### 7.7 Post-condition Gate — Recommendation Disposition Enforcement

本 gate は **mechanical gate**。`candidate_count >= 1` なのに 7.2 の採否ゲートを飛ばして result を emit する silent skip を止める。
**Execution condition**: ステップ 7 に入ったとき（`candidate_count >= 1`）。0 件なら silent skip。7.2 のゲートが held（`ADOPTION_GATE_RC=3`）を返したときは実行しない（採否保留の停止で終わる）。

**Step 1 — Determine candidate count**:

7.1 の `candidate_count` を読む。`0` なら **7.7 全体を skip** して 8.0 へ。
**Step 2 — Grep sentinel from conversation context (latest iteration_id)**:
Search the conversation context (ステップ 7.2 emit site) for the following sentinel pattern:

```
[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={ID}; mode={mode}; choice={choice}; reason={reason}
```

`{N}` は Step 1 の件数、`{ID}` は 7.2 の iteration。複数行なら **最大 iteration_id** を採用する。`mode=` と `choice=` と `reason=` が無い行は未確認の emit として採用しない。

**Step 3 — Routing**:

| Condition | Action |
|-----------|--------|
| Latest sentinel found with `candidates >= 1` AND iteration_id matches current cycle AND `mode=` / `choice=` / `reason=` が全て非空 | Gate passes — proceed to ステップ 8.0 (Defense-in-Depth State Update) |
| Latest sentinel found with matching iteration_id but `mode=` / `choice=` / `reason=` のいずれかが欠落 | **ERROR**: sentinel が確認証跡を欠く（emit-before-evidence）。Execute the ACTION below |
| Latest sentinel NOT found AND candidate_count >= 1 | **ERROR**: ステップ 7.2 was skipped in current cycle. Execute the ACTION below |
| Latest sentinel found but iteration_id is **stale** (matches cycle N-1, not current cycle N) | **ERROR**: ステップ 7.2 was skipped in current cycle (cycle N-1 sentinel false-positive avoided). Execute the ACTION below |
| Sentinel found but `candidates == 0` | Defensive observation: ステップ 7.1 / 7.2 count mismatch (e.g., dedup edge case). Display WARNING and proceed (non-blocking, gate passes); the discrepancy is observability-only. ステップ 7.2-7.3 の「候補 0 件かつ triage の hold ファイルが無いときだけ skip」規約が成立しているため、本行は通常到達不能 dead branch だが defense-in-depth として残す |

**On ERROR** (sentinel not found, candidates >= 1):

```
ERROR: ステップ 7.7 post-condition gate failed.
candidate_count = {N} (>= 1) but no [CONTEXT] PHASE_7_ASKUSER_INVOKED sentinel found.
This means ステップ 7.2 disposition handling was NOT executed — silent skip of recommendation disposition.
ACTION: Return to ステップ 7.2, run the adoption gate, and only when it returns decided emit the sentinel with mode/choice/reason, then re-enter ステップ 7.7. Do not run 7.4 before that sentinel.
⚠️ LLM MUST NOT output [review:mergeable], [review:fix-needed:{n}], or the acceptance-unverified stop [review:error] (REVIEW_STOP=ac_unverified) until ステップ 7.2 has been executed and the sentinel is emitted.
ANTI-PATTERN reference: This gate enforces the prohibition declared in
.rite/wiki/pages/anti-patterns/aggregate-recommendation-label-evasion.md
(if Wiki has not yet ingested this page, see the background section).
Silent skip with aggregate label "推奨 N 件 (全て scope 外)" is the specific
failure mode being blocked here.
```

本 gate は prose。ERROR を認識して 7.2 に戻る。overall_assessment に関係なく発火する。
rationale: design-rationale.md#phase7-gate-notes

---
