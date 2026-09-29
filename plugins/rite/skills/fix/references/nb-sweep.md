### 1.3.S `--nb-sweep` consume（5.S 専用）

`[CONTEXT] NB_SWEEP=1` のときだけ評価する。通常ループでは本節を skip。既存の `nb-sweep-done-{pr_number}.txt` があっても consume を skip しない。成功した書込は 1 行目を上書きする。既存の 2 行目が SHA なら残し、新しい SHA は足さない。入口でファイルの有無を見て return しない。fix/SKILL.md のステップ 2–4 は評価せず、本節の後に fix/SKILL.md の 5.1 へ進む。
rationale: ../../iterate/references/rationale.md#nb-sweep-step

1. **collect**（iterate 5.S と同 helper。冪等）:

```bash
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした" >&2; echo "[fix:error]"; exit 1; }
sweep_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || sweep_root=""
if [ -z "$sweep_root" ]; then
  echo "ERROR: state-path-resolve が空。NB sweep 対象を取得できない" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_state_root_unresolved" >&2
  echo "[fix:error]"
  exit 1
fi
collect_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nb-collect-XXXXXX") || { echo "[fix:error]"; exit 1; }
collect_out=$(bash {plugin_root}/hooks/scripts/nb-sweep-collect.sh --pr {pr_number} --state-root "$sweep_root" 2>"$collect_err") || collect_rc=$?
collect_rc=${collect_rc:-0}
cat "$collect_err" >&2
rm -f -- "$collect_err"
sweep_status=$(printf '%s' "$collect_out" | jq -r '.status // empty') || sweep_status=""
nb_record=$(printf '%s' "$collect_out" | jq -r '.record // empty')
nb_record_base=""
[ -n "$nb_record" ] && nb_record_base=$(basename "$nb_record")
# 残っている entries は台帳 persist で止まった sweep のもので、起票済みの件数を持つ。
# 今回読んだ review JSON の sweep のものでなければ、起票済みの代わりにも今回の件数にもせずに止まる。
nb_entries_file="$sweep_root/.rite/state/nb-sweep-entries-{pr_number}.md"
nb_counts=""
if [ "$collect_rc" -eq 0 ] && [ -f "$nb_entries_file" ]; then
  nb_counts=$(bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh tally --entries-file "$nb_entries_file" \
    --record "$nb_record_base") || {
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_stale" >&2
    echo "[fix:error] reason=nb_sweep_entries_stale"; exit 1
  }
fi
case "$collect_rc:$sweep_status" in
  0:empty)
    nb_kind=noop
    [ -n "$nb_counts" ] && nb_kind=done
    echo "[CONTEXT] NB_SWEEP_RESULT=done; ${nb_counts:-issued=0; recorded=0}" >&2
    mkdir -p "$sweep_root/.rite/state" || true
    source {plugin_root}/hooks/gitignore-ensure.sh
    if ! _ensure_dir_gitignore "$sweep_root/.rite/state"; then
      echo "WARNING: $sweep_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
      [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
    fi
    nb_done_file="$sweep_root/.rite/state/nb-sweep-done-{pr_number}.txt"
    # 台帳に全件載っている。前回の sweep の entries は戻り先として不要
    rm -f "$nb_entries_file"
    nb_keep=""
    if [ -f "$nb_done_file" ]; then
      nb_keep=$(sed -n '2p' "$nb_done_file" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      case "$nb_keep" in ''|*[!0-9a-f]*) nb_keep="" ;; esac
      [ "${#nb_keep}" -ge 7 ] || nb_keep=""
    fi
    if [ -n "$nb_keep" ]; then
      nb_write_ok=$(printf '%s %s\n%s\n' "$nb_kind" "$nb_record_base" "$nb_keep" > "$nb_done_file" && echo ok || true)
    else
      nb_write_ok=$(printf '%s %s\n' "$nb_kind" "$nb_record_base" > "$nb_done_file" && echo ok || true)
    fi
    if [ -z "$nb_record_base" ] || [ "$nb_write_ok" != ok ]; then
      echo "WARNING: nb-sweep-done marker を書けませんでした" >&2
      rm -f "$sweep_root/.rite/state/nb-sweep-done-{pr_number}.txt"
    fi
    ;;
  0:ok)
    if [ -n "$nb_counts" ]; then
      echo "[CONTEXT] NB_SWEEP_ENTRIES=present; path=$nb_entries_file" >&2
    else
      echo "[CONTEXT] NB_SWEEP_ENTRIES=absent; path=$nb_entries_file" >&2
    fi
    printf '%s\n' "$collect_out"
    ;;
  *)
    echo "ERROR: NB sweep collect failed (rc=$collect_rc status=${sweep_status:-})" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_collect_failed" >&2
    echo "[fix:error]"
    exit 1
    ;;
esac
```

`empty` なら手順 2・3 を skip して fix/SKILL.md の 5.1 へ。collect は sweep の hold ファイル（state root の `.rite/state/adoption-hold-{pr_number}-sweep.json`）があれば、その候補のうち今回の target と内容の一致しないものを `candidates[]` に合流させる（元の review JSON の basename を `record` に持ち、id は `<record>#<key>`）。保留した commit を問わず、今回の review JSON の head で判定し直す（直っていれば RESOLVED、PR 起因が残れば保留のまま）。hold ファイルは手順 3 の台帳記録が成功するまで残る（手順 3 の bash が消す）。そのため起票や台帳 persist の途中で止まった再実行でも、持ち越した候補は候補に残る。

`NB_SWEEP_ENTRIES=present` なら、この sweep の起票は前回済んでいて手順 3 で止まっている（entries は手順 2 の全件成功後にだけ作られ、手順 4 か `empty` で消える）。手順 2 を実行せず、手順 3 の後の戻り方で entries を直して手順 3 から続ける。`absent` なら手順 2 へ。`reason=nb_sweep_entries_stale` は、entries の 1 行目（`<!-- nb-sweep-record: ... -->`）が今回の `record=` の basename を名指さない（別の sweep の entries が残っている）。起票も台帳 persist も始めずに止まる。行の出典は照合しない（合流した保留候補の行は元の review JSON を出典に持つ）。1 行目が別の record を名指す entries の行は、前回の sweep が起票したまま台帳に載せられなかった記録であり、1 行目も行の出典も今回の record に書き換えてはならない（書き換えると手順 2 を飛ばし、今回の対象が起票も記録もされない）。記録コメントの `### 却下台帳` に同じ id・位置・出典の行が既にあれば、手順 3 は成功済みなので再実行しない（append は重複を除かず、同じ行が二重に載る）。entries を消して `/rite:iterate {pr_number}` を再実行する。無ければ書き換えずに手順 3 の bash だけを実行して元の出典のまま台帳へ載せ、成功したら entries を消して `/rite:iterate {pr_number}` を再実行する。台帳に載った指摘は collect が除外するので重複起票せず、今回の sweep は手順 2 から始まる。

2. **採否ゲートと起票**（採否は採否判定 helper の出口で決め、重要度・実測で決めない）:

`already_rejected[]` はゲートに掛けず `recorded` として転記する。sweep はコードを変更せず、commit / push を行わない。
rationale: design-rationale.md#nb-sweep-routing

**判定記録**: 手順 1 の stdout の `candidates[]` 全件について、本手順を実行する分類役が根因ごとに 1 件の判定記録を Write tool で state root（`state-path-resolve.sh` の出力）の `.rite/state/adoption-{pr_number}-sweep.json` に保存する（形式と欄は `hooks/scripts/review-adoption-gate.sh` と `hooks/scripts/lib/review-adoption.py` の docstring）。`head` は手順 1 の出力のトップレベル `.record`（今回読んだ review JSON。ゲートの `--review-result`）の `commit_sha`（candidate の `record` ではない）、`ids` は candidate の `id`（target は `key`、合流した保留候補は `<record>#<key>`）。起票になる記録（ADOPT で origin=pre_existing、DIAGNOSE で調査として引き受ける記録）には `acceptance`（起票する Issue の受入条件）を書く。target に `prior` があれば記録の `prior` にそのまま写す（prior の違う target を 1 つの記録にまとめない）。手順 1 の出力の `ledger[]`（台帳の `issued` / `LINK` / `REJECT` 行。`issued` と `LINK` の判定文に起票先・追跡先の `#N` がある）と、判定記録ファイルの `tracker` を持つ記録（`head` を問わない）を読み、既存の Issue が今回の候補と同じ根因を追跡していれば、文面・位置・id が変わっていても記録の `tracker` にその番号を入れる（閉じた Issue の番号は入れない）。`REJECT` 行が同じ根因・同じ前提の候補を処分していれば、その行を記録の `prior`（`{finding_id, file_line, disposition, premise}`。行の `id` を `finding_id`、`loc` を `file_line` に写し、`source` は写さない）に写す。collect が写すのは id と位置が一致する行だけなので、id・文面・位置が変わった候補はここで紐づける。同じ `head` の判定記録が既にあればそこから始め、足りない記録を補い、helper の ERROR で止まった記録は直す。起票が書き戻した `tracker` だけは書き換えない（消さない）。

**ゲート**: 下の bash が collect をもう一度実行し、`candidates[]` から候補ファイルを作ってゲートを呼ぶ。`{base_branch}` は rite-config `branch.base`、無ければステップ 1.1 の `.baseRefName`。

```bash
sweep_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || sweep_root=""
if [ -z "$sweep_root" ] || ! collect_out=$(bash {plugin_root}/hooks/scripts/nb-sweep-collect.sh --pr {pr_number} --state-root "$sweep_root"); then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_collect_failed" >&2
  echo "[fix:error]"; exit 1
fi
nb_candidates=$(mktemp "${TMPDIR:-/tmp}/rite-nb-candidates-XXXXXX") || { echo "[fix:error]"; exit 1; }
trap 'rm -f "$nb_candidates"' EXIT
printf '%s' "$collect_out" | jq '{candidates: .candidates}' > "$nb_candidates" \
  || { echo "[fix:error]"; exit 1; }
gate_rc=0
# 候補 0 件（already_rejected だけ）でもゲートを呼ぶ（前回の保留候補が今回の候補から消えていれば保留する）
nb_issue=$(git branch --show-current 2>/dev/null | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | head -1)
gate_out=$(bash {plugin_root}/hooks/scripts/review-adoption-gate.sh --pr {pr_number} --kind sweep \
  --state-root "$sweep_root" --candidates "$nb_candidates" \
  --review-result "$(printf '%s' "$collect_out" | jq -r '.record')" \
  --base "origin/{base_branch}" --owner-repo {owner_repo} ${nb_issue:+--issue "$nb_issue"}) || gate_rc=$?
case "$gate_rc" in
  0) ;;
  3)
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_adoption_held" >&2
    echo "[fix:error] reason=nb_sweep_adoption_held"; exit 1 ;;
  *)
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_adoption_gate_failed" >&2
    echo "[fix:error] reason=nb_sweep_adoption_gate_failed"; exit 1 ;;
esac
# verdict が欠落・未知値なら、起票も台帳 persist も始めない
if ! printf '%s' "$gate_out" | jq -e '.held == false and (.verdicts | type) == "array"
    and all(.verdicts[]; .verdict == "file" or .verdict == "record")' >/dev/null 2>&1; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_verdict_invalid" >&2
  echo "[fix:error] reason=nb_sweep_verdict_invalid"; exit 1
fi
printf '%s\n' "$gate_out"
```

`[fix:error]` のどれでも、起票も entries も台帳 persist も done の書込もしない。`reason=nb_sweep_adoption_held` は出口の出ていない候補がある（判定記録なし・helper の ERROR・hold の出口）。候補の全文・出典・対象 HEAD・再開位置はゲートが stderr の `hold_file=` に保存済み。保留を REJECT や処分済みに書き換えず、hold ファイルの resume（ゲートの WARNING にも出る）に従って再開する（PR 起因の保留はコードを直して push し再レビューするなど、理由ごとの手段は resume が持つ）。HEAD が変わらない再開では、ステップ 0.7 が 5.S へ戻し本手順から続く。

**起票**: stdout の `verdicts[]` のうち `verdict=file` の記録ごとに 1 件起票する（1 根因 = 1 Issue。違う記録を 1 件にまとめない）。`verdict=record` は起票しない。本文は記録（`verdicts[].record`）から作り、`/rite:open` が複雑度を読む Meta で始め、Projects に渡す `complexity` と同じ値を宣言する。`projects` は rite-config.yml の設定を反映する。起票ごとに次の 3 ブロックを連結して単一 Bash で実行し、成功時の `issue_number` と `issue_url` を当該記録に対応付けて entries に使う:

| Placeholder | Source |
|-------------|--------|
| `{type}` | 根因から推定（`fix` / `refactor` / `docs` 等） |
| `{summary}` | 根因の要約（動詞始まり、50 文字以内） |
| `{overview}` | 根因の説明（何が起きていて何が困るか） |
| `{contract}` / `{evidence}` / `{acceptance}` | 記録の `contract`（`ref` と引用 `text`）/ `evidence` / `acceptance` |
| `{proposition}` | `action=investigate` のとき記録の `proposition` の命題・到達条件・その出所・完了条件。それ以外は `## 調査` 節ごと消す |
| `{observations}` | 記録の `ids` の candidate ごとに `- {file}:{line} {description}`（`suggestion` があれば続ける） |
| `{record_ids}` | 記録の `ids`（JSON 配列） |
| `{projects_enabled}` / `{project_number}` / `{owner}` | `rite-config.yml` → `github.projects.enabled` / `project_number` / `owner` |

```bash
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-nb-issue-XXXXXX") || { echo "[fix:error]"; exit 1; }
trap 'rm -f "$tmpfile"' EXIT
if ! cat <<'BODY_EOF' > "$tmpfile"
**Type**: {type}
**Complexity**: S

## 概要

{overview}

## 契約

{contract}

## 根拠

{evidence}

## 受入条件

{acceptance}

## 調査

{proposition}

## 観測した候補

{observations}

## 関連

- 元の PR: #{pr_number}
BODY_EOF
then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_issue_body_failed" >&2
  echo "[fix:error]"
  exit 1
fi
issue_args=$(jq -n \
  --arg title "{type}: {summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg complexity "S" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: { enabled: $projects_enabled, project_number: $project_number, owner: $owner, status: "todo", complexity: $complexity, iteration: { mode: "none" } },
    options: { source: "pr_review", non_blocking_projects: true }
  }') || { echo "[fix:error]"; exit 1; }
```

```bash
if ! issue_result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$issue_args") ||
   ! printf '%s' "$issue_result" | jq -e '.issue_number > 0 and (.issue_url | type == "string" and length > 0)' >/dev/null; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_issue_failed" >&2
  echo "[fix:error]"
  exit 1
fi
```

```bash
# 起票した番号を判定記録の tracker に書き戻す。途中で止まって再実行すると、ゲートはこの記録を LINK にし、同じ根因を二度起票しない
nb_adoption="$(bash {plugin_root}/hooks/state-path-resolve.sh)/.rite/state/adoption-{pr_number}-sweep.json"
nb_issue_number=$(printf '%s' "$issue_result" | jq '.issue_number')
if ! jq --argjson ids '{record_ids}' --argjson n "$nb_issue_number" \
     'if any(.adoption.records[]; .ids == $ids) then (.adoption.records[] | select(.ids == $ids) | .tracker) = $n
      else error("ids \($ids) の記録がありません") end' "$nb_adoption" > "$nb_adoption.tmp" ||
   ! mv -- "$nb_adoption.tmp" "$nb_adoption"; then
  rm -f -- "$nb_adoption.tmp"
  echo "ERROR: 起票した #$nb_issue_number を $nb_adoption の記録の tracker に書き戻せません。書き戻してから再実行する（書かずに再実行すると同じ根因を二度起票する）" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_tracker_write_failed" >&2
  echo "[fix:error]"; exit 1
fi
printf '%s\n' "$issue_result"
```

起票失敗時は台帳 persist・done ファイル書込・完了通知へ進まない。全件成功後に entries を生成する（手順 3 を再実行するときは、同じ sweep の entries を直して使う。前回の sweep の entries を今回の起票済みとして使わない）。`verdict=record` の記録も `already_rejected` も silent に落とさない。起票の途中で止まったときも再実行は手順 2 の判定記録から続き、書き戻した `tracker` によりゲートは起票済みの記録を LINK にするので、同じ根因を二度起票しない。

3. **台帳 persist**（全 target と already_rejected）:

Write tool で entries を手順 1 の `NB_SWEEP_ENTRIES` の `path=`（`.rite/state/nb-sweep-entries-{pr_number}.md`。会話や再起動をまたいで起票済みの記録を残すため一時ディレクトリに置かない）に保存（1 行目は `<!-- nb-sweep-record: {sweep_record} -->`。`{sweep_record}` は手順 1 の stderr に出る `record=` の値の basename で、手順 1 の tally はこの行でどの sweep の entries かを決める。続けて列 0。candidate 1 件に 1 行。行形式 `| {key} | {file}:{line} | {判定} | {判定文} | {record_basename} |`）。`verdict=file` の記録の candidate は判定 `issued`・判定文に起票先 `#N` と URL。`verdict=record` の記録の candidate は判定に出口名（`REJECT` / `RESOLVED` / `LINK`）、判定文に記録の `reason`（RESOLVED で reason が無ければ `evidence`、LINK は `追跡先 #{tracker}`）。hold は書かない（held なら手順 2 で止まっている）。`already_rejected` は判定 `recorded`・判定文 `severity={sev}; measured={bool}`。`{record_basename}` は candidate の `record`（今回の target は手順 1 の stderr に出る `[CONTEXT] NB_SWEEP_COLLECT=ok; ...; record=` の値の basename、合流した保留候補は元の review JSON の basename）、`already_rejected` は `record=` の値の basename。cleanup の follow-up 起票はこの出典で sweep 起票済みの指摘を同定するため、最終列を欠いた行が 1 行でもあれば、append は entries 全体を `reason=entries_source_invalid` で拒否し、台帳を変更しない。`already_rejected` は id=`reviewer`、位置=`file_line`、severity=`original_severity`、measured=false とする。セル内のパイプ・改行はエスケープする。

```bash
sweep_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || sweep_root=""
entries_file="$sweep_root/.rite/state/nb-sweep-entries-{pr_number}.md"
if [ -z "$sweep_root" ] || [ ! -s "$entries_file" ]; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_missing" >&2
  echo "[fix:error]"; exit 1
else
  ledger=$(mktemp "${TMPDIR:-/tmp}/rite-nb-ledger-XXXXXX") || { echo "[fix:error]"; exit 1; }
  body=$(mktemp "${TMPDIR:-/tmp}/rite-nb-body-XXXXXX") || { echo "[fix:error]"; exit 1; }
  # 既存本文は記録 helper が PATCH する 1 件を、同じ helper の読み取り専用モードで読む（関連 Issue の解決も helper が行う）
  bash {plugin_root}/hooks/review-nonblocking-record.sh --print-record-body \
    --pr {pr_number} --owner-repo {owner_repo} > "$body" || {
    echo "ERROR: 6.1.d コメント取得失敗" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_fetch_failed" >&2
    echo "[fix:error]"; exit 1
  }
  if [ ! -s "$body" ]; then
    printf '%s\n\n%s\n\n%s\n%s\n\n%s\n' \
      '## 📜 rite 非実測指摘の記録 (non-blocking)' \
      '本 cycle の非実測指摘: 0 件 (前 cycle の記録内容は本 cycle では再報告されていません)' \
      '📎 non_blocking_count: 0' \
      '📎 reviewed_commit: unknown' \
      '<!-- rite:nbr:v1 -->' > "$body"
  fi
  bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$body" > "$ledger" || {
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_extract_failed" >&2
    echo "[fix:error]"; exit 1
  }
  bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh append --ledger-file "$ledger" --entries-file "$entries_file" || {
    echo "ERROR: 却下台帳 append 失敗" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_append_failed" >&2
    echo "[fix:error]"; exit 1
  }
  bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh merge-into --body-file "$body" --ledger-file "$ledger" || {
    echo "ERROR: 却下台帳 merge-into 失敗" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_merge_failed" >&2
    echo "[fix:error]"; exit 1
  }
  # 抽出式は review-nonblocking-record.sh の count/body 整合検査と同一にする。この値は直下で
  # 同 helper へ `--count` として渡され、helper が同じ行を再検証するため、述語がずれると
  # producer が通した body を validator が count_body_mismatch で落とす経路が生まれる。
  # awk のフィールド番号で取ってはならない — 行頭の 📎 が第 1 フィールドを占める。
  body_count=$(grep -E '^📎 non_blocking_count:[[:space:]]*[0-9]+[[:space:]]*$' "$body" | tail -1 | grep -oE '[0-9]+')
  case "$body_count" in ''|*[!0-9]*)
    echo "ERROR: merge-into 後の non_blocking_count が読めない" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_count_unreadable" >&2
    echo "[fix:error]"; exit 1
    ;;
  esac
  record_err=$(mktemp "${TMPDIR:-/tmp}/rite-nb-record-XXXXXX") || { echo "[fix:error]"; exit 1; }
  bash {plugin_root}/hooks/review-nonblocking-record.sh \
    --pr {pr_number} --owner-repo {owner_repo} --count "$body_count" \
    --iteration-id "nb-sweep-{pr_number}" --content-file "$body" 2>"$record_err"
  record_rc=$?
  cat "$record_err" >&2
  record_outcome=$(sed -n 's/^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; .*outcome=\([^;]*\);.*/\1/p' "$record_err" | tail -1)
  # entries は常に 1 件以上あるため、skipped は台帳が投稿されなかったことを意味する
  case "$record_rc:$record_outcome" in
    0:created|0:updated) ;;
    *)
      echo "ERROR: 却下台帳 記録失敗 (rc=$record_rc outcome=${record_outcome:-<欠落>})" >&2
      echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_record_failed" >&2
      echo "[fix:error]"; exit 1
      ;;
  esac
  rm -f -- "$record_err"
  # 外部への書き込みはすべて済んだ。持ち越した保留候補はもう要らないので sweep の hold を消す
  rm -f -- "$sweep_root/.rite/state/adoption-hold-{pr_number}-sweep.json"
fi
```

台帳の記録が成功すると、同じ bash が sweep の hold ファイルを消す。

手順 3 が `[fix:error]` で止まったときは、手順 2 の起票をやり直さない。起票は済んでいるが台帳に行が無いため、sweep を最初から実行し直すと同じ指摘を再び起票する。起票済みの Issue は entries の issued 行が持つ。entries（`.rite/state/nb-sweep-entries-{pr_number}.md`）を stderr の理由に合わせて直し、手順 3 だけを再実行する。`reason=entries_source_invalid` の診断は不正行の先頭 3 行しか示さないので、entries の全行について最終列がその行の candidate の `record`（`already_rejected` は手順 1 の `record=` の basename）になっているかを確かめ、欠けた行には最終列として足す。別の record を名指す行は書き換えない（手順 1 の `reason=nb_sweep_entries_stale` の戻り方に従う）。成功したら手順 4 へ進む。この会話で続けられないときは entries を直したうえで `/rite:iterate {pr_number}` を再実行する（別の会話からでもよい）。iterate のステップ 0.7 が再レビューを回さずに 5.S へ戻し、手順 1 が `NB_SWEEP_ENTRIES=present` を出すので手順 2 を飛ばして手順 3 から続く。

4. **完了**:

下の bash が entries の判定列から件数を数えて `[CONTEXT] NB_SWEEP_RESULT=done; issued=K; recorded=M` を出し（K は `issued` 行、M は `REJECT` / `RESOLVED` / `LINK` / `recorded` 行）、台帳に載った entries を消す（別の会話から戻ったときも件数を会話に頼らない）。全件の台帳 persist 成功後に 1 行目を `done <basename>` にする。basename は collect が `--pr` で選ぶのと同じ最新 JSON（`LC_ALL=C` sort の末尾。collect 出力 `.record` の basename と同一）。この bash は別シェルなので `.record` を再計算する。既存の 2 行目が SHA なら残し、新しい SHA は足さない。既存ファイルでも 1 行目は上書きする（ファイルが無いときだけ書く形にはしない）。

```bash
sweep_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || sweep_root=""
if [ -n "$sweep_root" ]; then
  mkdir -p "$sweep_root/.rite/state" || true
  source {plugin_root}/hooks/gitignore-ensure.sh
  if ! _ensure_dir_gitignore "$sweep_root/.rite/state"; then
    echo "WARNING: $sweep_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
    [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
  fi
  sweep_done_file="$sweep_root/.rite/state/nb-sweep-done-{pr_number}.txt"
  nb_record=$(find "$sweep_root/.rite/review-results" -maxdepth 1 -type f -name "{pr_number}-*.json" 2>/dev/null | LC_ALL=C sort | tail -1)
  nb_record_base=""
  [ -n "$nb_record" ] && nb_record_base=$(basename "$nb_record")
  nb_keep=""
  if [ -f "$sweep_done_file" ]; then
    nb_keep=$(sed -n '2p' "$sweep_done_file" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$nb_keep" in ''|*[!0-9a-f]*) nb_keep="" ;; esac
    [ "${#nb_keep}" -ge 7 ] || nb_keep=""
  fi
  if [ -n "$nb_keep" ]; then
    nb_write_ok=$(printf 'done %s\n%s\n' "$nb_record_base" "$nb_keep" > "$sweep_done_file" && echo ok || true)
  else
    nb_write_ok=$(printf 'done %s\n' "$nb_record_base" > "$sweep_done_file" && echo ok || true)
  fi
  if [ -z "$nb_record_base" ] || [ "$nb_write_ok" != ok ]; then
    echo "WARNING: nb-sweep-done marker を書けませんでした" >&2
    rm -f "$sweep_done_file"
  fi
  entries_file="$sweep_root/.rite/state/nb-sweep-entries-{pr_number}.md"
  if nb_counts=$(bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh tally --entries-file "$entries_file"); then
    echo "[CONTEXT] NB_SWEEP_RESULT=done; $nb_counts" >&2
    rm -f "$entries_file"
  else
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_tally_failed" >&2
  fi
fi
```

fix/SKILL.md のステップ 5.1 が `[fix:sweep-done]` を emit する。`K+M` は collect `count`（already_rejected 転記を含む）と一致する。未消化 0 が正常出口。
