### 1.3.S `--nb-sweep` consume（5.S 専用）

`[CONTEXT] NB_SWEEP=1` のときだけ評価する。通常ループでは本節を skip（AC-7）。ステップ 2–4 は評価せず、本節の後に 5.1 へ進む。
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
case "$collect_rc:$sweep_status" in
  0:empty)
    echo "[CONTEXT] NB_SWEEP_RESULT=done; issued=0; recorded=0" >&2
    mkdir -p "$sweep_root/.rite/state" || true
    source {plugin_root}/hooks/gitignore-ensure.sh
    if ! _ensure_dir_gitignore "$sweep_root/.rite/state"; then
      echo "WARNING: $sweep_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
      [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
    fi
    if ! printf 'noop\n' > "$sweep_root/.rite/state/nb-sweep-done-{pr_number}.txt"; then
      echo "WARNING: nb-sweep-done marker を書けませんでした" >&2
      rm -f "$sweep_root/.rite/state/nb-sweep-done-{pr_number}.txt"
    fi
    ;;
  0:ok) ;;
  *)
    echo "ERROR: NB sweep collect failed (rc=$collect_rc status=${sweep_status:-})" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_collect_failed" >&2
    echo "[fix:error]"
    exit 1
    ;;
esac
```

`empty` なら route 適用・persist を skip して 5.1 へ。

2. **route 適用**（helper の判定を変更しない）:

`targets[]` の `route=issued` は `create-issue-with-projects.sh`（`options.source=pr_review`）で起票し、`route=recorded` は機械理由を記録する。`already_rejected[]` は `recorded` として転記する。sweep はコードを変更せず、commit / push を行わない。
rationale: design-rationale.md#nb-sweep-routing

最初に全 target の route を検証する。欠落・未知値で停止し、起票も台帳 persist も開始しない:

```bash
if ! printf '%s' "$collect_out" | jq -e 'all(.targets[]; .route == "issued" or .route == "recorded")' >/dev/null; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_route_missing" >&2
  echo "[fix:error] reason=nb_sweep_route_missing"
  exit 1
fi
```

全 `issued` target について finding の description / suggestion / file:line を本文ファイルに保存し、既存の起票 helper の入力形式に合わせる。`projects` は rite-config.yml の設定を反映する。起票ごとに次のブロックを実行し、成功時の `issue_number` と `issue_url` を当該 finding に対応付ける:

```bash
# issue_args は jq --arg / --argjson で構築した JSON（body_file と options.source=pr_review を含む）。
if ! issue_result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$issue_args") ||
   ! printf '%s' "$issue_result" | jq -e '.issue_number > 0 and (.issue_url | type == "string" and length > 0)' >/dev/null; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_issue_failed" >&2
  echo "[fix:error]"
  exit 1
fi
```

起票失敗時は台帳 persist・done ファイル書込・完了通知へ進まない。全件成功後に entries を生成する（前回の一時ファイルを再利用しない）。`recorded` を silent に落とさない。

3. **台帳 persist**（issued / recorded / already_rejected 全件）:

Write tool で entries を `{tmp}/rite-nb-entries-{pr_number}.md` に保存（列 0。行形式 `| {id} | {file}:{line} | issued|recorded | {起票先 or 機械理由} |`）。`issued` は起票先 `#N` と URL、`recorded` は `severity={sev}; measured={bool}`。`already_rejected` は id=`reviewer`、位置=`file_line`、severity=`original_severity`、measured=false とする。セル内のパイプ・改行はエスケープする。

```bash
entries_file="${TMPDIR:-/tmp}/rite-nb-entries-{pr_number}.md"
if [ ! -s "$entries_file" ]; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_missing" >&2
  echo "[fix:error]"; exit 1
else
  ledger=$(mktemp "${TMPDIR:-/tmp}/rite-nb-ledger-XXXXXX") || { echo "[fix:error]"; exit 1; }
  body=$(mktemp "${TMPDIR:-/tmp}/rite-nb-body-XXXXXX") || { echo "[fix:error]"; exit 1; }
  related={issue_number}
  if [ -n "$related" ] && [ "$related" != "0" ]; then
    gh api "repos/{owner_repo}/issues/${related}/comments" --paginate \
      --jq '.[] | select(.body | startswith("## 📜 rite 非実測指摘の記録")) | .body' > "$body" || {
      echo "ERROR: 6.1.d コメント取得失敗" >&2
      echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_fetch_failed" >&2
      echo "[fix:error]"; exit 1
    }
  fi
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
  if [ "$record_rc" -ne 0 ] || grep -qE 'NONBLOCKING_RECORD_FAILED=1|outcome=failed' "$record_err"; then
    echo "ERROR: 却下台帳 記録失敗 (rc=$record_rc)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_record_failed" >&2
    echo "[fix:error]"; exit 1
  fi
  rm -f -- "$record_err"
fi
```

4. **完了**:

```
[CONTEXT] NB_SWEEP_RESULT=done; issued=K; recorded=M
```

全件の台帳 persist 成功後に 1 行 `done` を書く。sweep は HEAD を変更しないため SHA を追記しない。

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
  if ! printf 'done\n' > "$sweep_done_file"; then
    echo "WARNING: nb-sweep-done marker を書けませんでした" >&2
    rm -f "$sweep_done_file"
  fi
fi
```

ステップ 5.1 が `[fix:sweep-done]` を emit する。`K+M` は collect `count`（already_rejected 転記を含む）と一致する。未消化 0 が正常出口。
