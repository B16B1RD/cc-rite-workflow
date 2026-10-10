---
name: batch-run
description: |
  rite workflow のバッチ実行スキル: 複数 Issue に対し /rite:open → /rite:iterate を
  順次・自律実行して draft PR を残す（--merge 指定時のみ ready→merge→cleanup まで完走）。
  完了時に /rite:issue-audit を 1 回実行し、完了報告に監査レポートへの参照を載せる。
  ユーザーが明示的に /rite:batch-run で起動する meta-orchestrator。auto-activate しない。
  起動: /rite:batch-run [--merge] <issue_number>...
argument-hint: "[--merge] <issue_number>... | --promotions [--merge]"
---

# /rite:batch-run

> 実行入口と工程境界は [Host Runtime Contract](../../references/host-runtime-contract.md#入口と工程境界)、native Skill / Task がない場合の実行は [Host workflow operations](../../references/host-workflow-operations.md) に従う。nested 呼出しは caller の runtime 選択を引き継ぐ。

> 実行開始時は [Autonomous Execution](../rite-workflow/references/autonomous-execution.md) を適用する。

**デフォルトでは** `/rite:open` → `/rite:iterate` を **順次・完全自律（無確認）** して draft PR を残す。`--merge` 時のみ `/rite:ready` → `/rite:merge` → `/rite:cleanup` まで完走する。

成功する限り無確認。失敗は即停止。`[iterate:max-cycles-reached]` も failed 記録して即停止する。handoff は **一切 set しない**。継続は flat step 構造。
rationale: references/rationale.md#default-draft
rationale: references/rationale.md#breaker-stop
rationale: references/rationale.md#no-handoff

途中停止: 処理中 Issue は `/rite:recover {issue}`、残りキューは引数省略 `/rite:batch-run` で再開（モードも永続化）。キューが `active=true` で中断が直近（`updated_at` から 2 時間以内）かつ cursor 一致なら recover 単体でも残りキューへ自動継続（[recover Phase 5.5](../recover/SKILL.md)）。再開は**同一セッション内**前提。利用者の求めで一時停止するときは `flow-state.sh pause`、続けるときは `flow-state.sh resume`（記録があるあいだ Stop hook は差し戻さず、SessionStart が起動のたびにその旨と再開方法を表示する。位置は run-queue と flow-state が保つ）。
rationale: references/rationale.md#session-scoped-queue

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version)。run-queue は **`run-queue-{session_id}.json`**（`flow-state.sh path` の basename、`state-path-resolve.sh` の state root）。sandbox で worktree cwd からの書込が拒否された当該 bash のみ `dangerouslyDisableSandbox: true` で再実行してよい（確認不要。[git-worktree-patterns.md](../../references/git-worktree-patterns.md#worktree-cwd-から-main-checkout-配下への書き込みが-sandbox-の-write-許可リストでブロックされる)）。

## Contract

**Input**: `[--merge]` + Issue number(s) — 1 個以上、空白区切り（省略時は自セッションの run-queue からモードごと再開）
**Output**: 全 Issue 処理完了の完了通知（ステップ 7。デフォルトは draft PR 群、`--merge` は merge/cleanup 完走。どちらも監査レポートへの参照を含む）、または最初の失敗での停止報告（残り Issue 含む、ステップ 8）
**自律度**: 完全自律（無確認）。デフォルトは draft PR まで、`--merge` 時は merge を含め確認を挟まない。失敗時のみ停止。

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

## Arguments

| Argument | Description |
|----------|-------------|
| `--merge` | （任意フラグ）指定すると open→iterate に加え ready→merge→cleanup まで完走する。省略時は各 Issue を draft PR で止める。Issue 番号との順序は問わない（例: `--merge 1527 1528` / `1527 --merge 1528`） |
| `--promotions` | 保守リポジトリの raw 昇格候補を AI が列挙・集約し、既存 Issue または issue-create を経て通常の open → iterate に接続する。Issue 番号との併用不可。新しい候補 queue は作らない |
| `<issue_number>...` | 処理対象の Issue 番号（1 個以上、空白区切り）。省略時は `.rite/state/run-queue-{session_id}.json` の未処理分（cursor 以降）をモードごと再開 |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_numbers}` | 引数 `$ARGUMENTS`（`--merge` フラグ + 空白区切りの Issue 番号群。省略可） |
| `{run_mode}` | ステップ 0 / 1 の `mode=` marker 値（`default` = draft 止まり / `merge` = フルパイプライン） |
| `{summary_issues}` / `{summary_total}` / `{summary_remaining}` / `{summary_per_issue}` / `{summary_est_total}` | ステップ 0.5 の `RUN_SUMMARY` marker（`issues=` / `total=` / `remaining=` / `per_issue=` / `est_total=`。着手前サマリの表示に使う） |
| `{current_issue}` | ステップ 1 の `RUN_NEXT=process; issue=` が指す Issue |
| `{new_cursor}` / `{total}` | ステップ 6 の `RUN_ADVANCE` marker（`cursor=`（前進後のキューを進めた件数）/ `total=`。各 Issue の cursor 前進時の `✅ N/M 件処理済み` 進捗表示に使う。成功件数ではない） |
| `{pr_number}` | ステップ 2 の open 完了通知（`[pr:created:N]`）から抽出。ステップ 1.5 で open を飛ばした場合は同 marker の `pr=` |
| `{branch_name}` | ステップ 2 の open 完了通知「ブランチ: ...」行から抽出（ステップ 6 の cleanup に渡す）。ステップ 1.5 で open を飛ばした場合は同 marker の `branch=` |
| `{processed_issues}` | ステップ 7 bash の `processed=`（全完了 Issue 一覧） |
| `{breaker_failed}` | ステップ 8: `[iterate:max-cycles-reached]` 受領なら `true`、それ以外は `false` |
| `{failed_issues}` | ステップ 7 bash の `failed=`（サーキットブレーカー `[iterate:max-cycles-reached]` で非収束となった Issue 一覧。空 `[]` のとき完了通知の該当行を省略） |
| `{outstanding_n}` | ステップ 6 で cleanup 完了報告から読む `[cleanup:outstanding:N]` sentinel の `N` に実際に埋め込まれた数値 |
| `{action_items}` | 本 run の bash 出力に残った、ユーザーの操作が必要な WARNING / ERROR（ステップ 8 では、`失敗理由:` に 4 要素で書いた人間にしか確認できない事項の 1 行要約を含む）。ステップ 7 完了通知 / ステップ 8 停止報告の `要対応:` 欄へ転記する（0 件なら欄ごと省略） |
| `{audit_report}` | ステップ 7 の `/rite:issue-audit` 完了報告の `監査レポート:` 行の path |
| `{outstanding_issues}` | ステップ 7 bash の `outstanding=`（未完了事項が残った Issue 一覧。空 `[]` のとき完了通知の該当行を省略） |
| `{done_issues}` / `{remaining_issues}` | ステップ 8 bash の `done=` / `remaining=`（停止時の処理済み / 未処理 Issue） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute |

---

## 入口: 一時停止の解除

状態の復元・変更より先に実行する。非 0 なら診断を表示して停止し、後続へ進まない。

```bash
# loop-entry-resume
bash {plugin_root}/hooks/scripts/loop-entry-resume.sh || exit 1
```

`LOOP_ENTRY_RESUME=resumed` のときは「同じセッションからの再入により一時停止を解除し、継続ガードを再開しました」と利用者へ表示して続行する。`none` なら通常手順へ進む。
rationale: ../../references/stop-loop-continuation-contract.md#loop-skill-reentry

---

## 昇格候補の消化（`--promotions`）

Issue 番号を指定する通常入口と分け、保守リポジトリで明示された `--promotions` の場合だけステップ 0 の前に実行する。Issue 番号との併用はエラー。配布先では候補を保存・報告するだけで、外部送信や配布物編集をしない。source helper と保持した owner/repo の照合が失敗したら停止する。`{wiki_root_abs}` は既存 Wiki のブランチ戦略から解決する（separate_branch は登録済み Wiki worktree、same_branch は実 checkout の .rite/wiki）。

1. **列挙・突合**: 次を実行し、JSON 全件を読む。既存の `ingested: true` や過去の complete 記録で除外しない。helper は現在の merge/caller/test 証拠を再照合し、不足は raw パスと理由付きで未解決とする。raw/log の取得・保存失敗は停止する。

   ```bash
   bash {plugin_root}/hooks/scripts/wiki-promotion-candidates.sh reconcile --wiki-root "{wiki_root_abs}" --cwd "{execution_cwd}" --repo {owner_repo}
   ```

2. **分類・集約**: AI が原文範囲と反例を読み、条件・消費先で同じ責務へまとめる。旧 `detector-candidate:` の空の条件/消費先は原文と現在のコードから具体化する。独自の条件と出典を削らない。complete は実装対象から外し、未解決は既存 log と全状態の Issue/PR を照合する。起票済み Issue が log 未記録でも、raw パスと知見の原文範囲・条件・消費先を含む本文を検索して再利用する。CLOSED だけでは完了とせず、未解決な閉じた作業は必要な差分の契約として起票する。
3. **既存経路で起票**: 対応する OPEN Issue が無ければ、候補の各 `id/raw/source/condition/consumer` と要約を入力にして次を invoke する。caller context は `promotion_caller=batch-run`。候補の選択・分類・起票判断を毎回人間に戻さず、相反する仕様だけ確認する。

   ```text
   skill: rite:issue-create
   args: "{promotion_contract}"
   ```

   `[create:returned-to-caller:N]` を回収し、Issue の存在と本文の出典、Projects 登録の実結果を照合する。未登録・起票失敗・sentinel 不在なら作成済み Issue の有無を調べ、raw を保持して停止する。helper の直接起票で代用しない。
4. **対応保存**: [候補データ契約](../../references/wiki-patterns.md#昇格候補)の work 配列を `{promotion_work_file}` へ Write し、次で既存 log に保存する。候補理由は raw に残す。記録が失敗したら後続を起動せず、次回の手順 2 で GitHub を再照合する。

   ```bash
   bash {plugin_root}/hooks/scripts/wiki-promotion-candidates.sh link --wiki-root "{wiki_root_abs}" --cwd "{execution_cwd}" --repo {owner_repo} --input "{promotion_work_file}"
   ```

5. **既存ループへ接続**: 対応 OPEN Issue の番号を重複排除して `{issue_numbers}` に置換し、通常のステップ 0 → open → iterate を続行する。`--merge` を明示したときのみ既存 merge 経路へ進む。他の未完了キューを上書きせず、先にそのキューを再開する。同じ Issue 群なら既存 cursor を維持する。対象 0 件なら候補の complete/未解決と理由を報告し、キューを新設しない。

**結果の突合と再開**: 消化対象かは既存 log の対応 Issue で確認する（新しい状態フィールドを作らない）。通常起動・recover のいずれも、ステップ 6 の cursor 前進前、CLOSED の skip 前、全完了通知前に同じ reconcile を呼ぶ。merge が見つかる場合は、その merge commit の consumer/caller/test パスと `revision` を work に追記して link で保存してから照合する。helper は同じ候補・対応 Issue/PR・条件・消費先に属する、マージ済み revision の caller 利用と検証成功を要求する。実体が reference/原則なら caller の明示読取と対応試験を確認する。draft、未利用、検証失敗、取得失敗は未解決のまま。失敗理由は log と完了報告に残し、cursor の作業完了を候補の昇格完了と混同しない。API 作成/マージを試験で mock にしたことと実確認を区別する。

候補の記録・domain ページの変更・log 更新は既存 ingest lock、番号参照検査、commit/lint/push を両ブランチ戦略で通す。lock/pending を再初期化しない。未 commit の記録がある再開は、既存保存回収手順で確認してから進む。

## ステップ 0: キュー初期化 / 再開判定

`.rite/state/run-queue-{session_id}.json`（`{issues, cursor, mode, failed, outstanding, active, updated_at}`。session_id は `flow-state.sh path` の basename。解決できなければ fail-loud — global 名へフォールバックしない）を SoT とする。突き合わせ対象は自セッションのキューのみ。`mode` 欠落は `default`、`failed` / `outstanding` 欠落は `[]`、`active` 欠落は `false`、`updated_at` 欠落は stale。`failed` は `[iterate:max-cycles-reached]` の未解消記録（再開後のステップ 6 前進時に当該 Issue を除去）。`outstanding` は `[cleanup:outstanding:N]` で `n > 0` だった Issue。`active` はステップ 0 で `true`、ステップ 8 で `false`。`updated_at` は cursor 前進 / active 設定のたびに更新（ステップ 1 の skip-closed は対象外。[recover Phase 5.5](../recover/SKILL.md)）。
rationale: references/rationale.md#session-scoped-queue

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
mkdir -p "$(dirname "$queue_file")"

# 引数パース（"#12, 34" のような記号混在も許容して数値のみ抽出。--merge は位置非依存で検出）
arg_str="{issue_numbers}"
case "$arg_str" in *--merge*) arg_mode=merge ;; *) arg_mode=default ;; esac
arg_issues_json=$(printf '%s' "$arg_str" | grep -oE '[0-9]+' | jq -R 'tonumber' | jq -s '.' 2>/dev/null || echo '[]')
arg_count=$(echo "$arg_issues_json" | jq 'length')

if [ "$arg_count" -gt 0 ]; then
  if [ -f "$queue_file" ] && \
     [ "$(jq -cS '.issues' "$queue_file" 2>/dev/null)" = "$(echo "$arg_issues_json" | jq -cS '.')" ]; then
    # 同一 Issue 群での再開: cursor は保ちつつ、今回指定のモードを権威として上書きする。
    # `active=true` を立て直す（run が iterate を駆動中であることを示す。iterate ステップ 6 の
    # batch 判定が停止済み dormant キューを active batch と誤判定しないための signal）
    cursor=$(jq -r '.cursor // 0' "$queue_file")
    now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq --arg mode "$arg_mode" --arg now "$now_ts" '.mode = $mode | .active = true | .updated_at = $now' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file" \
      || { rm -f "$queue_file.tmp"; echo "WARNING: run-queue の mode/active=true 書込に失敗（active 未設定なら iterate は安全側 interactive）" >&2; }
    echo "[CONTEXT] RUN_QUEUE=resume_match; cursor=$cursor; total=$arg_count; mode=$arg_mode"
  else
    # 新規 / 既存と不一致 → 上書き（古いキューは破棄）。`active=true` で駆動中を明示
    now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n --argjson issues "$arg_issues_json" --arg mode "$arg_mode" --arg now "$now_ts" '{issues:$issues, cursor:0, mode:$mode, failed:[], outstanding:[], active:true, updated_at:$now}' > "$queue_file"
    echo "[CONTEXT] RUN_QUEUE=initialized; cursor=0; total=$arg_count; mode=$arg_mode"
  fi
else
  if [ -f "$queue_file" ]; then
    # 引数省略の再開: run が再び iterate を駆動するため active=true を立て直す
    now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq --arg now "$now_ts" '.active = true | .updated_at = $now' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file" \
      || { rm -f "$queue_file.tmp"; echo "WARNING: run-queue の active=true 書込に失敗（active 未設定なら iterate は安全側 interactive）" >&2; }
    cursor=$(jq -r '.cursor // 0' "$queue_file"); total=$(jq -r '.issues | length' "$queue_file")
    mode=$(jq -r '.mode // "default"' "$queue_file")   # 旧形式 (mode 欠落) は default 互換
    echo "[CONTEXT] RUN_QUEUE=resume_no_args; cursor=$cursor; total=$total; mode=$mode"
  else
    echo "[CONTEXT] RUN_QUEUE=empty"
  fi
fi
```

| `RUN_QUEUE` marker | アクション |
|---|---|
| `initialized` / `resume_match` / `resume_no_args` | `mode=` を `{run_mode}` として retain → **ステップ 0.5（着手前サマリ）へ進む**（ステップ 0.5 が表示後にステップ 1 へ送る） |
| `empty` | 引数もキューも無い。使い方 `/rite:batch-run [--merge] <issue_number>...` を案内して終了 |

> `RUN_QUEUE=empty` のときは本ステップ 0.5 に到達しない（サマリを出さずステップ 0 で終了する）。

---

## ステップ 0.5: 着手前サマリ表示（キュー確定直後・最初の open 前に 1 回）

キュー確定後、**最初の `/rite:open` の前に 1 回だけ**サマリを出す。ステップ 1 再入では再表示しない。`RUN_QUEUE=resume_no_args` もその run の最初の open 前に 1 回。

**AskUserQuestion は挟まない**。
rationale: references/rationale.md#pre-summary-no-ask

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
issues=$(jq -rc '.issues' "$queue_file")
total=$(jq -r '.issues | length' "$queue_file")
cursor=$(jq -r '.cursor // 0' "$queue_file")
mode=$(jq -r '.mode // "default"' "$queue_file")
remaining=$((total - cursor)); [ "$remaining" -lt 0 ] && remaining=0
# 件数ベースの粗い目安（1 Issue あたりの所要レンジ・分）。モードで出し分ける
# （merge はデフォルトの open→iterate に加え ready→merge→cleanup を回すぶん幅を広めに取る）
if [ "$mode" = "merge" ]; then per_low=15; per_high=35; else per_low=10; per_high=25; fi
est_low=$((remaining * per_low)); est_high=$((remaining * per_high))
echo "[CONTEXT] RUN_SUMMARY; issues=$issues; total=$total; remaining=$remaining; cursor=$cursor; mode=$mode; per_issue=${per_low}-${per_high}min; est_total=${est_low}-${est_high}min"
```

`RUN_SUMMARY` marker の各フィールドをリテラル置換し、`mode=` で文言を出し分けてサマリを **1 回だけ**表示する。`cursor > 0`（再開）のときは対象件数に「残り {summary_remaining} 件」を併記する。

**デフォルト（`mode=default`, draft 止まり）**:

```
## /rite:batch-run 実行サマリ

- 対象 Issue: {summary_total} 件 {summary_issues}（`cursor > 0` の再開時のみ「残り {summary_remaining} 件」を併記する。新規実行では併記しない）
- 実行モード: draft 止まり（各 Issue を open→iterate まで自律処理し、**merge せず** draft PR をレビュー待ちで残します）
- 目安時間: 1 Issue あたり約 {summary_per_issue}（件数ベースの粗い目安。レビュー往復・実装規模で変動）→ 合計約 {summary_est_total}
- 中断/再開: 中断は Ctrl+C。中断後は個別 Issue を `/rite:recover <issue>`、残りキュー全体は引数省略の `/rite:batch-run` で再開できます（自セッションの run-queue に cursor とモードを永続化）

このまま確認なしで最初の Issue の処理を開始します。
```

**`--merge`（`mode=merge`, フル完走）**:

```
## /rite:batch-run 実行サマリ

- 対象 Issue: {summary_total} 件 {summary_issues}（`cursor > 0` の再開時のみ「残り {summary_remaining} 件」を併記する。新規実行では併記しない）
- 実行モード: フル完走（各 Issue を open→iterate→ready→merge→cleanup まで進め、**merge まで完走**します）
- 目安時間: 1 Issue あたり約 {summary_per_issue}（件数ベースの粗い目安。レビュー往復・実装規模で変動）→ 合計約 {summary_est_total}
- 中断/再開: 中断は Ctrl+C。中断後は個別 Issue を `/rite:recover <issue>`、残りキュー全体は引数省略の `/rite:batch-run` で再開できます（自セッションの run-queue に cursor とモード=merge を永続化）

このまま確認なしで最初の Issue の処理を開始します。
```

表示後、AskUserQuestion を挟まずそのままステップ 1 へ進む。

<!-- run orchestration: after emitting the summary, do NOT stop and do NOT ask — proceed directly to ステップ 1 (first issue). This summary is shown exactly once per run invocation, before the first open. -->

---

## ステップ 1: 次の Issue を取り出す（coarse スキップ判定込み）

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
cursor=$(jq -r '.cursor // 0' "$queue_file")
total=$(jq -r '.issues | length' "$queue_file")
mode=$(jq -r '.mode // "default"' "$queue_file")   # 旧形式は default 互換。ステップ 3 の分岐判定に使う

if [ "$cursor" -ge "$total" ]; then
  echo "[CONTEXT] RUN_NEXT=all-done; mode=$mode"
else
  current=$(jq -r ".issues[$cursor]" "$queue_file")
  # マージで Issue が閉じても、現在位置の cleanup が未完了なら先に再開する。
  cleanup_pending=false
  if [ -e "$fs_path" ]; then
    cleanup_pending=$(jq -r --argjson issue "$current" '
      .issue_number == $issue and .phase == "cleanup" and .active == true' "$fs_path") || exit 1
  fi
  # coarse スキップ: cleanup 未完了の現在位置以外の CLOSED Issue は処理済み。
  state=$(gh issue view "$current" -R {owner_repo} --json state --jq '.state' 2>/dev/null || echo "OPEN")
  if [ "$state" = "CLOSED" ] && [ "$cleanup_pending" != "true" ]; then
    jq '.cursor += 1' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"
    echo "[CONTEXT] RUN_NEXT=skip-closed; issue=$current; new_cursor=$((cursor+1)); total=$total; mode=$mode"
  else
    echo "[CONTEXT] RUN_NEXT=process; issue=$current; cursor=$cursor; total=$total; mode=$mode"
  fi
fi
```

| `RUN_NEXT` marker | アクション |
|---|---|
| `process` | `issue=` を `{current_issue}`、`mode=` を `{run_mode}` として retain。run 起動後の最初の `process` はステップ 1.5（再開段階の振り分け）へ、ステップ 6 からの再入はステップ 2（open）へ |
| `skip-closed` | この Issue は既に処理済み。ステップ 1 を再実行（次の Issue へ） |
| `all-done` | 残り Issue 無し → ステップ 7（全完了通知）へ |

---

## ステップ 1.5: 再開段階の振り分け（run 起動あたり 1 回だけ）

open 以外の段階で止まった Issue を、止まった段階から続けるための振り分け。**run 起動後の最初の `RUN_NEXT=process` でのみ評価する**（`RUN_QUEUE` が `resume_no_args` / `resume_match` / `initialized` のいずれでも同じ。ステップ 6 の cursor 前進からステップ 1 へ戻る再入では実行せず、常に `open` として扱う）。判定は flow-state のローカル読み出しだけで完結し、`gh` 等のネットワーク呼び出しを含めない。phase→スキルの対応は [recover Phase 5.3](../recover/SKILL.md) が SoT で、本ステップは phase→本コマンドのステップへの入口だけを持つ。
rationale: references/rationale.md#resume-stage-dispatch

```bash
# batch-run-resume-stage
# flow-state.sh get は JSON 破損でも default を返して rc=0 で戻るため、ファイルの可読性は先に直接検査する
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path) || { echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=state_read_failed; issue={current_issue}"; exit 0; }
if [ -f "$fs_path" ] && ! jq -e . "$fs_path" >/dev/null 2>&1; then
  echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=state_read_failed; issue={current_issue}"; exit 0
fi
fs_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "") || { echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=state_read_failed; issue={current_issue}"; exit 0; }
fs_active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default "") || { echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=state_read_failed; issue={current_issue}"; exit 0; }
fs_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || { echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=state_read_failed; issue={current_issue}"; exit 0; }
fs_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0") || { echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=state_read_failed; issue={current_issue}"; exit 0; }
fs_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "") || { echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=state_read_failed; issue={current_issue}"; exit 0; }

# A stopped diagnostic run retains its identity even while inactive.
if [ "$fs_issue" = "{current_issue}" ] && [ -f "$fs_path" ] && \
   jq -e '.review_run.status == "stopped"' "$fs_path" >/dev/null; then
  echo "[CONTEXT] RUN_RESUME_STAGE=stop; reason=stagnation_stopped; issue={current_issue}; pr=$fs_pr; branch=$fs_branch"
  exit 0
fi

# 別 Issue / 非 active の state は本 Issue の再開材料にならない → 従来どおり open
if [ "$fs_active" != "true" ] || [ "$fs_issue" != "{current_issue}" ]; then
  echo "[CONTEXT] RUN_RESUME_STAGE=open; reason=fresh_or_mismatched; issue={current_issue}"
  exit 0
fi

case "$fs_phase" in
  init|branch|plan|implement|lint|pr) stage=open ;;
  review|fix)                        stage=iterate ;;
  ready)                             stage=merge ;;   # ready 化は完了済み。/rite:ready は既 Ready の PR で sentinel を出さないため merge から続ける
  ready_error)                       stage=ready ;;
  cleanup)                           stage=cleanup ;;
  ingest|completed)                  stage=stop ;;    # recover 5.3 では wiki-ingest 再呼び出し / 完結済み。run のステップに対応が無い
  *)                                 stage=stop ;;
esac

# PR 以降の段階なのに PR 番号が無い → 推測せず停止
if [ "$stage" != open ] && [ "$stage" != stop ]; then
  case "$fs_pr" in ''|0|*[!0-9]*) stage=stop; reason=pr_number_missing ;; esac
fi
# cleanup は {branch_name} を要するため、merge モードで branch が空なら停止
if [ "$stage" = cleanup ] && [ "{run_mode}" = merge ] && [ -z "$fs_branch" ]; then
  stage=stop; reason=branch_missing
fi
# default モードは ready / merge / cleanup を実行しない → draft のまま次へ
if [ "{run_mode}" = default ] && { [ "$stage" = ready ] || [ "$stage" = merge ] || [ "$stage" = cleanup ]; }; then
  stage=advance
fi
echo "[CONTEXT] RUN_RESUME_STAGE=$stage; reason=${reason:-phase_$fs_phase}; issue={current_issue}; pr=$fs_pr; branch=$fs_branch"
```

| `RUN_RESUME_STAGE` | アクション |
|---|---|
| `open` | ステップ 2（従来どおり `/rite:open`） |
| `iterate` | `pr=` を `{pr_number}`、`branch=` を `{branch_name}` として retain し、ステップ 2 を飛ばしてステップ 3（iterate）へ |
| `ready` | 同上で retain し、ステップ 4（ready）へ（`ready_error` からの再試行。`/rite:ready` の E2E 判定は phase=`ready_error` を standalone 扱いするため確認を求められうる） |
| `merge` | 同上で retain し、ステップ 5（merge）へ（ready 化は完了済み） |
| `cleanup` | 同上で retain し、ステップ 6（cleanup）へ |
| `advance` | `default` モードで ready / merge / cleanup 段階に達している。ready / merge / cleanup は実行せず、ステップ 6 の cursor 前進 bash へ直行 |
| `stop` | 段階を決められない（`reason=` に `state_read_failed` / `pr_number_missing` / `branch_missing` / `phase_ingest` / `phase_completed` / 未知 phase）。open も iterate も invoke せず、ステップ 8（段階=resume）で停止し `/rite:recover {current_issue}` を案内 |

---

## ステップ 2: /rite:open を invoke

配下の lint が `commands.lint` 未設定かつ自動検出も未該当なら、[lint 1.3](../lint/SKILL.md#13-when-command-cannot-be-detected) の `[lint:skipped]` 経路を質問なしで選ぶ。未実行の理由・設定案内は省略しない。open が既存 sentinel 契約で PR 作成へ進み、設定済みコマンドの失敗はこのスキップに変換しない。

> ステップ 1.5 の marker が `open` のときのみ実行する（`iterate` / `ready` / `merge` / `cleanup` / `advance` は各段階へ直行済み、`stop` はステップ 8 へ）。この skill return 後、停止せずに sentinel を判定してステップ 3 へ進む。本コマンドは handoff を使わないため、継続はこの flat 構造に依存する。

```text
skill: rite:open
args: "{current_issue}"
```

| Sentinel | アクション |
|---------|-----------|
| open 完了通知（`[pr:created:N]` と「ブランチ: ...」行） | PR 番号 `N` を `{pr_number}`、ブランチ名を `{branch_name}` として retain → ステップ 3 へ |
| `[pr-create-failed]` / 完了通知に PR 番号が無い / sentinel 不在 | **失敗** → ステップ 8（段階=open） |

<!-- run orchestration: after open returns, do NOT stop — retain {pr_number}/{branch_name} and proceed to ステップ 3 -->

---

## ステップ 3: /rite:iterate を invoke

> 本コマンドは iterate invoke の **前後で `flow-state.sh set` を呼ばない**（iterate 内部の handoff / FINALIZE 機構を壊さないため）。唯一の例外はステップ 5「競合の解消」の `--phase fix` で、ready が handoff を消費した後の merge 段から戻るときにだけ行う。iterate は内部で review⇄fix を mergeable まで回し、完了通知を出して制御を戻す。`--merge` モードの正常終了では、続くステップ 4 ready の `flow-state.sh set` が残存 FINALIZE handoff を default-clear する。デフォルトモードは ready を経由しないが、残存 FINALIZE handoff は次 Issue の open（ステップ 1.6 の `flow-state.sh set`）が default-clear し、最後の Issue 分はステップ 7 完了通知前の `consume-handoff` が消費する（失敗終了時に残る handoff はステップ 8 で消費する）。

```text
skill: rite:iterate
args: "{pr_number}"
```

iterate の終了 sentinel を `{run_mode}`（ステップ 1 の `mode=` marker）で出し分ける:

停滞の見直し中は iterate 内で継続する。見直し後の非収束も既存の `[iterate:max-cycles-reached]` に返り、下表の停止経路を使う。診断・保存・権限の失敗を成功扱いせず、同一 run の再開で cycle や見直し履歴をリセットしない。

| Sentinel + `{run_mode}` | アクション |
|---------|-----------|
| `[review:error]` + `REVIEW_STOP=purpose_unaligned`（両モード） | **失敗** → ステップ 8（段階=iterate）。内側の `[review:mergeable]` は iterate 終端ではない |
| `[review:error]` + `REVIEW_STOP=adoption_held`（両モード） | **失敗** → ステップ 8（段階=iterate）。採否の出口待ちで外部へ何も書かずに止まっているか、スコープ外処分の外部への書き込み（Issue・Decision Log・申し送り・台帳）が途中で失敗して止まっている（後者は一部が書き込み済み）。停止報告に `hold_file` とその resume（再開方法）を載せる。hold に書けなかったときは stderr の WARNING の `再開方法:` を載せる |
| `[review:error]` + `REVIEW_STOP=base_conflict`（両モード） | **失敗** → ステップ 8（段階=iterate）。iterate は base 競合を 1 回取り込んで再レビューするため、ここへ戻るのは取り込み後も再び競合したか、取り込みを解消できずに止まったとき。停止報告に iterate の停止通知（競合したファイルと理由）を載せる |
| `[review:error]` + `REVIEW_STOP=ac_unverified`（`merge`） | → ステップ 4（ready）へ。ready が実行して確かめられる条件を確かめ、その結果と人間にしか確かめられない条件を停止理由に示す |
| `[review:error]` + `REVIEW_STOP=ac_unverified`（`default`） | ready を実行しないため未検証の受入条件を確かめられない。**失敗** → ステップ 8（段階=iterate）。draft PR は残る。停止報告に未検証の受入条件（iterate の停止通知の内容）を載せる |
| `[review:mergeable]` + `merge` | iterate 収束 → ステップ 4（ready）へ |
| `[review:mergeable]` + `default` | iterate 収束。**ready/merge/cleanup はスキップ**し、draft PR を残したまま **ステップ 6 の cursor 前進 bash へ直行**（cleanup invoke はしない） |
| `[fix:replied-only]` + `merge` | **非収束として失敗扱い** → ステップ 8（段階=iterate）。reply のみで mergeable 未到達のまま merge すると未解決指摘を握り潰すため。停止報告に続行コマンド `/rite:ready {pr_number} && /rite:merge {pr_number}` を案内 |
| `[fix:replied-only]` + `default` | merge しないため即停止は不要。**「Issue #{current_issue} の draft PR #{pr_number} は未解決指摘あり」を会話に明示** したうえで draft PR を残し、**ステップ 6 の cursor 前進 bash へ直行**してキューを次へ進める |
| `[iterate:max-cycles-reached]`（両モード） | **非収束として失敗** → ステップ 8（段階=iterate）。`failed[]` 記録と `active=false` 更新を行い、cursor は当該 Issue に保持する。ready/merge/cleanup と後続 Issue は実行しない。 |
| `[fix:cancelled-by-user]`（両モード） | ユーザー中断 → ステップ 8（段階=iterate） |
| `[iterate:nb-sweep-error]` / `[fix:error]` / sentinel 不在（両モード） | **失敗** → ステップ 8（段階=iterate） |

<!-- run orchestration: after iterate returns a terminal sentinel, do NOT stop. [review:error] + REVIEW_STOP=purpose_unaligned (both modes) -> ステップ 8; 内側の [review:mergeable] は iterate 終端ではない. [review:error] + REVIEW_STOP=adoption_held (both modes) -> ステップ 8 (held, or the out-of-scope writes stopped part way; see hold_file resume, or the stderr WARNING 再開方法: when the hold could not be written). [review:error] + REVIEW_STOP=base_conflict (both modes) -> ステップ 8 (iterate already took the base in once). [review:error] + REVIEW_STOP=ac_unverified: merge mode -> ステップ 4, default mode -> ステップ 8. merge mode + [review:mergeable] (purpose_unaligned なし) -> ステップ 4. default mode + [review:mergeable] or [fix:replied-only] -> ステップ 6 cursor advance (skip ready/merge/cleanup). [iterate:max-cycles-reached] (both modes) -> ステップ 8 (record failure and stop; do NOT advance cursor). -->

---

## ステップ 4: /rite:ready を invoke（`--merge` 時のみ）

> **`{run_mode}=merge` のときだけ実行する。デフォルトモードはステップ 3 から直接ステップ 6 の cursor 前進へ遷移済みのため、本ステップには到達しない。**
>
> iterate 完走後は flow-state phase が `review`/`fix` のままのため、ready は E2E flow と判定し standalone 確認をスキップする（= 無確認自律）。run 側の追加操作は不要。

```text
skill: rite:ready
args: "{pr_number}"
```

| Sentinel | アクション |
|---------|-----------|
| `[ready:returned-to-caller]` | ステップ 5 へ |
| `[ready:error]` / sentinel 不在 | **失敗** → ステップ 8（段階=ready）。ready が未検証の受入条件で止まったときは、その停止理由（人間のみの条件ごとの 4 要素 = 何を確かめるか / なぜ AI では確かめられないか / どう確かめるか / 期待する結果、AI で確かめた行の `実行したコマンド => 観測結果`）を省略せず失敗理由欄へ転記する |

<!-- run orchestration: after ready returns, do NOT stop — proceed to ステップ 5 -->

---

## ステップ 5: /rite:merge を invoke（`--merge` 時のみ）

> **`{run_mode}=merge` のときだけ実行する。** デフォルトモードは本ステップに到達しない。

```text
skill: rite:merge
args: "{pr_number}"
```

| Sentinel | アクション |
|---------|-----------|
| `[merge:returned-to-caller]` | ステップ 6 へ |
| `[merge:not-ready]` + `[CONTEXT] MERGE_NOT_READY=conflicting` | base と競合。停止せず下記「競合の解消」を行い、ステップ 3 へ戻る |
| `[merge:error]` + `[CONTEXT] MERGE_ERROR=behind` | **失敗** → ステップ 8（段階=merge）。BEHIND の解消手順を復旧欄に載せる |
| `[merge:error]` + `[CONTEXT] MERGE_METHOD=invalid` | **失敗** → ステップ 8（段階=merge）。復旧欄の先頭に「rite-config.yml の `merge.method` を squash / merge のどちらかに直してから再開する」を載せる（マージは実行されていない） |
| `MERGE_NOT_READY=conflicting` を伴わない `[merge:not-ready]` / `[merge:error]` / sentinel 不在 | **失敗** → ステップ 8（段階=merge） |

**競合の解消**（上表の競合行のときだけ）:

1. `gh pr ready {pr_number} -R {owner_repo} --undo` で PR を draft に戻し、`bash {plugin_root}/hooks/flow-state.sh set --phase fix --issue {current_issue} --branch {branch_name} --pr {pr_number} --next "base 取り込み後に /rite:iterate {pr_number}"` を実行する（途中で止まっても再開がステップ 1.5 の `fix` → iterate に振られる）。どちらかが失敗したら **失敗** → ステップ 8（段階=merge）
2. [fix-plan の base 取り込み](../fix/references/fix-plan.md#base-取り込み) の手順 1〜5（取り込み・検証・Wiki 適用証跡の取り直し・commit・head 更新・push）を、flow-state の `worktree`（セッション worktree）で行う。`{fix_plan_file}` / `{fix_issue_file}` は同 reference の JSON 契約に従い、mergeable を判定した保存済みレビュー結果の `review_context` と最新 Issue 本文から作る（`base-intake` の 1 グループと全体検証だけを持つ）。検証は `bash {plugin_root}/hooks/scripts/review-fix-scope-check.sh check` / `verify --kind all`（いずれも `--plan "{fix_plan_file}" --issue "{fix_issue_file}"`）で行う。同節の停止条件（push 済み commit の巻き戻しが要る等）に当たったとき、および helper・git の非ゼロ終了は、その状況を失敗理由として **失敗** → ステップ 8（段階=merge）
3. ステップ 3（iterate）へ戻る。以降は既存の表どおり iterate → ready → merge と進み、reviewed HEAD と受入条件の照合は ready / merge が行う。再レビューがサーキットブレーカーで止まればステップ 3 の表でステップ 8 に合流する。競合の差し戻し回数に上限は設けない（再突入のたびにレビュー cycle が進み、ブレーカーの判定に入る）

rationale: references/rationale.md#merge-conflict-route

<!-- run orchestration: after merge returns, do NOT stop. [merge:not-ready] + MERGE_NOT_READY=conflicting -> revert to draft, base intake, then ステップ 3. Any other not-ready / error / missing sentinel -> ステップ 8. [merge:returned-to-caller] -> ステップ 6 -->

---

## ステップ 6: cleanup（`--merge` 時のみ）→ cursor を進める

昇格候補に対応する Issue は、上の「結果の突合と再開」を先に実行する。draft の作業完了だけでは候補を完了にしない。

**`{run_mode}=merge` のときのみ**、下記で `/rite:cleanup` を invoke する。**デフォルト（draft 止まり）モードはステップ 3 から直接このステップに遷移し、cleanup invoke をスキップして下段の cursor 前進 bash のみ実行する**（draft PR はレビュー待ちのため close せず残す）。

```text
skill: rite:cleanup
args: "{branch_name}"
```

> cleanup は branch / worktree 削除・Projects Status → Done・Issue close・未完タスクの follow-up Issue 化 + Projects 登録・Wiki ingest を担う。**follow-up Issue + Projects 登録は cleanup 内部に完全委譲**し、run は関与しない。

| Sentinel（`--merge` 時のみ） | アクション |
|---------|-----------|
| `WIKI_CONTRADICTION_CHECK=failed` | **最優先の失敗** → ステップ 8（段階=cleanup）。cleanup が保存した inactive キューを保持し、cursor を進めず後続 Issue を開始しない |
| `[cleanup:returned-to-caller]` | この Issue 完了。下記 bash で cursor を +1 してステップ 1 へループ |
| sentinel 不在（cleanup 途中で停止） | merge は既に完了済み（成功扱い）。下記 bash で cursor を +1 してステップ 1 へ進む（cleanup の未完分は `/rite:recover {current_issue}` で個別補完できる旨を表示） |

**（`[cleanup:returned-to-caller]` 経由の場合のみ）** cursor を進める前に、cleanup の完了報告に含まれる `[cleanup:outstanding:N]` sentinel（非ブロッキング失敗の集約値）を読み、`{outstanding_n}` が `0` より大きければ当該 Issue を `outstanding[]` に記録する（ステップ 7 完了通知のロールアップに使うため。`failed[]` と同じ記録パターン）。sentinel 不在（cleanup 途中停止）の場合は判定不能なので記録しない — silent に「outstanding 無し」と誤記録しない（`{current_issue}` / `{outstanding_n}` はステップ 1 の marker 値・cleanup 完了報告の sentinel 値をそれぞれリテラル置換）:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
outstanding_n={outstanding_n}
if [ "$outstanding_n" -gt 0 ] 2>/dev/null; then
  if jq --argjson n {current_issue} '.outstanding = ((.outstanding // []) + [$n] | unique)' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"; then
    echo "[CONTEXT] RUN_OUTSTANDING_RECORDED; issue={current_issue}; n=$outstanding_n"
  else
    rm -f "$queue_file.tmp"
    echo "WARNING: outstanding 記録の書込に失敗（完了通知の未完了事項一覧から漏れる恐れ）" >&2
  fi
fi
```

cursor を進める（**両モード共有**。`--merge` 時は cleanup から制御が戻った後、デフォルト時はステップ 3 から直接ここへ。サーキットブレーカー時はここへ到達しない）:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg now "$now_ts" '.issues[.cursor] as $issue | .failed = ((.failed // []) - [$issue]) | .cursor += 1 | .updated_at = $now' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"
new_cursor=$(jq -r '.cursor' "$queue_file"); total=$(jq -r '.issues | length' "$queue_file")
echo "[CONTEXT] RUN_ADVANCE; cursor=$new_cursor; total=$total"
```

`RUN_ADVANCE` の `cursor=` と `total=` を読み、`✅ {new_cursor}/{total} 件処理済み` を出してから分岐する。**この件数は「キューを進めた件数」であり成功件数ではない**。
rationale: references/rationale.md#cursor-not-success

`new_cursor < total` ならステップ 1 へ戻る（次の Issue を処理）。`new_cursor >= total` ならステップ 7 へ。

<!-- run orchestration: after this cursor advance, do NOT stop — loop back to ステップ 1 (next issue) or go to ステップ 7. (merge mode reaches here after cleanup returns; default mode reaches here directly from ステップ 3.) -->

---

## ステップ 7: 全 Issue 完了通知

候補消化では全候補を再突合し、complete と未解決の raw パス・理由を通知へ含める。Issue の処理完了件数を昇格完了件数として使わない。

全 Issue を処理し終えたら、残存する終了 handoff を消費してから run-queue-{session_id}.json を削除して完了を報告する:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
# デフォルトモードでは最後の Issue の iterate が残した FINALIZE handoff が未消費で残りうる
# （merge モードは ready の flow-state set が消費済み）。完了通知前に one-shot 消費して
# Stop hook による差し戻しを防ぐ。merge モードでは既に空のため harmless no-op。
bash {plugin_root}/hooks/flow-state.sh consume-handoff >/dev/null 2>&1 || true
mode=$(jq -r '.mode // "default"' "$queue_file" 2>/dev/null || echo "default")
processed=$(jq -rc '.issues' "$queue_file" 2>/dev/null || echo "[]")
failed=$(jq -rc '.failed // []' "$queue_file" 2>/dev/null || echo "[]")
outstanding=$(jq -rc '.outstanding // []' "$queue_file" 2>/dev/null || echo "[]")
rm -f "$queue_file" "${queue_file%.json}.watchdog"
echo "[CONTEXT] RUN_DONE; processed=$processed; failed=$failed; outstanding=$outstanding; mode=$mode"
```

続けて Issue 監査を 1 回実行する:

```text
skill: rite:issue-audit
```

| Sentinel | 次のアクション |
|---------|--------------|
| `[issue-audit:returned-to-caller]` | `監査レポート:` 行の path を `{audit_report}` として retain し、完了通知へ |
| `[issue-audit:failed]` | `監査レポート:` 行があれば `{audit_report}` に retain する（無ければ `なし`）。失敗理由を `{action_items}` に 1 行載せて完了通知へ（再 invoke しない） |
| sentinel 不在 | `{audit_report}` を `なし` とし、`issue-audit が完了報告を返しませんでした — /rite:issue-audit を手動で実行してください` を `{action_items}` に載せて完了通知へ |

<!-- run orchestration: after issue-audit returns, do NOT stop — retain {audit_report} and emit the ステップ 7 完了通知 below. -->

`mode=`（`{run_mode}`）に応じて、`processed=` の Issue 一覧を `{processed_issues}`、`failed=` の非収束 Issue 一覧を `{failed_issues}` として完了通知を出し分ける。`failed=` が空配列 `[]` でない場合は、完了通知にサーキットブレーカーで failed 扱いとなった Issue を明示する（`[]` のときは該当行を省略する）。`outstanding=` の Issue 一覧を `{outstanding_issues}` として使う（cleanup 完了報告の「未完了事項」をロールアップする。`mode=merge` のときのみ意味を持つ — デフォルトモードは cleanup を invoke しないため `outstanding` は常に空）。

`{action_items}`（ステップ 7 の 2 テンプレとステップ 8 停止報告に共通）: 本 run の bash 出力に残った WARNING / ERROR のうち、ユーザーが操作しない限り残り続ける行を 1 行ずつ列挙する。最終試行と重複の判定は [Autonomous Execution](../rite-workflow/references/autonomous-execution.md) に従う。成功した迂回・リトライは載せない。ステップ 8 の停止報告では、`失敗理由:` に 4 要素で書いた人間にしか確認できない事項の 1 行要約も同じ欄に列挙する。**0 件なら `要対応:` 行ごと省略する**。cleanup 由来の非ブロッキング失敗をロールアップする `未完了事項:` 行とは別欄で、0 件時の扱いも異なる（`未完了事項:` は常に出す）。

**デフォルト（`mode=default`）**: 各 Issue は draft PR で停止しており **merge していない**:

```
## /rite:batch-run 完了（draft 止まり）

処理した Issue: {processed_issues}
各 Issue を open→iterate まで実行し draft PR を作成しました（**merge していません**。レビュー待ちです）。
レビュー後に進めるには各 PR で `/rite:ready <pr>` → `/rite:merge <pr>`、
または最初からまとめて完走させるなら `/rite:batch-run --merge {processed_issues}` を実行してください。
（未解決指摘ありで通過した draft PR があれば、上記処理中にその旨を明示しています。）
（旧キューの `failed=` が非空のときのみ）サーキットブレーカーで非収束（failed）となった Issue: {failed_issues} — draft/open PR をレビュー待ちで残しています。
監査レポート: {audit_report}

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

<!-- [run:all-completed] -->
```

**`--merge`（`mode=merge`）**: 全 5 段を完走（旧キューに残る failed は下記で別途報告）:

```
## /rite:batch-run 完了

処理した Issue: {processed_issues}
全 Issue を処理しました（open→iterate→ready→merge→cleanup を完走）。
（旧キューの `failed=` が非空のときのみ）サーキットブレーカーで非収束（failed）となり merge/cleanup をスキップした Issue: {failed_issues} — draft/open PR をレビュー待ちで残しています。`/rite:iterate <pr>` で再開できます。
未完了事項: （`outstanding=` が空のとき）なし（全 Issue） / （非空のとき）{outstanding_issues} の cleanup で非ブロッキング失敗が残っています — 各 Issue の cleanup 完了報告（本セッションのログ）を参照するか、`/rite:recover <issue>` で確認してください。
監査レポート: {audit_report}

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

<!-- [run:all-completed] -->
```

---

## ステップ 8: 失敗時の停止報告（即停止）

いずれかのステップで失敗 sentinel を受領したら、run-queue-{session_id}.json を **残したまま**（cursor は失敗 Issue を指したまま）即停止して報告する。`{breaker_failed}` は `[iterate:max-cycles-reached]` なら `true`、それ以外（sentinel 不在を含む）は `false` にリテラル置換する。ブレーカー時も後続 Issue は開始せず、PR / branch / worktree を保持する。

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
# batch-run-stop
# 失敗段が iterate の場合、fix.md が set した FINALIZE handoff が残り Stop hook が
# iterate 完了通知を差し戻しうる。停止報告の前に one-shot 消費して出力順序を確定させる。
bash {plugin_root}/hooks/flow-state.sh consume-handoff >/dev/null 2>&1 || true
# 停止時は active=false にする（run はもう iterate を駆動しない）。これにより停止後に同じ Issue を
# 手動 /rite:iterate した際、iterate ステップ 6 が dormant キューを active batch と誤判定せず
# 対話用の停止通知を出せる（キューは cursor 保持のまま残し、引数省略 /rite:batch-run で再開可能）
now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg now "$now_ts" --argjson breaker {breaker_failed} '
  .active = false | .updated_at = $now |
  if $breaker then .issues[.cursor] as $issue | .failed = ((.failed // []) + [$issue] | unique) else . end' "$queue_file" > "$queue_file.tmp" 2>/dev/null && mv "$queue_file.tmp" "$queue_file" \
  || { rm -f "$queue_file.tmp"; echo "WARNING: run-queue の停止状態の書込に失敗（active=false / failed 記録を確認できず、停止後に batch が再駆動される恐れ）" >&2; }
cursor=$(jq -r '.cursor // 0' "$queue_file" 2>/dev/null || echo 0)
mode=$(jq -r '.mode // "default"' "$queue_file" 2>/dev/null || echo "default")
done_issues=$(jq -rc ".issues[:$cursor]" "$queue_file" 2>/dev/null || echo "[]")
remaining=$(jq -rc ".issues[$cursor:]" "$queue_file" 2>/dev/null || echo "[]")
echo "[CONTEXT] RUN_STOP; cursor=$cursor; done=$done_issues; remaining=$remaining; mode=$mode"
```

`done=` / `remaining=` / `mode=` を読んで停止報告を出す。デフォルトモードでは失敗段は `resume` / `open` / `iterate` のいずれかに限られる（ready/merge/cleanup は実行しないため）:

```
## /rite:batch-run 停止

失敗した Issue: #{current_issue}（段階: {resume|open|iterate|ready|merge|cleanup}、モード: {run_mode}）
失敗理由: {受領した失敗 sentinel または「sentinel 不在」。段階=resume では RUN_RESUME_STAGE=stop の reason= 値。受入条件未検証（ready の停止）では、人間のみの条件ごとの 4 要素と AI で確かめた行の `実行したコマンド => 観測結果` を続けて書く。default の `REVIEW_STOP=ac_unverified` では iterate の停止通知の内容（`ac=` の ID と人間のみの条件ごとの 4 要素）を書く}
失敗時の状態: PR #{pr_number}（{draft | open | 未作成}。段階=resume で PR 番号を確定できないときは「PR 未確定」）

処理済み Issue: {done_issues}
未処理 Issue: {remaining_issues}

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

復旧:
- この Issue を続きから: /rite:recover {current_issue}
- 残りをまとめて再開: /rite:batch-run（引数省略で自セッションの run-queue の cursor とモードから再開する。この Issue はステップ 1.5 が flow-state の phase から再開段階を決める。明示再開する場合の `--merge` 併記は下記の補足を参照）

<!-- [run:stopped] -->
```

> **停止報告の欄**: 上のテンプレートの欄だけで構成し、独自の見出し・欄（「決めてほしいこと」等）を足さない。人間への依頼は `要対応:` に限る。推奨案があり元に戻せる判断（PR 内で直せる修正の実行など）は「〜してよいか」と質問せず、`復旧:` に推奨手順として書く。人間にしか確認できない事項だけを、[question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) 規則 6 の 4 要素（何を・なぜ AI では確かめられないか・どう確かめるか・期待する結果）で `失敗理由:` に書き、同じ事項を `要対応:` に 1 行ずつ要約して載せる。
>
> 復旧行の `/rite:batch-run` には、`{run_mode}=merge` のときのみ `--merge` を併記する（引数省略再開でも自セッションの run-queue の `mode` が維持されるため必須ではないが、明示再開する場合の指針として示す）。
> `[merge:error]` + `MERGE_ERROR=behind` の停止では、上の汎用復旧 2 行を以下で**置き換える**。base を取り込む前に recover / batch-run で同じ merge を再試行させない:
>
> 1. `BEHIND: マージ失敗後も base に遅れています` と表示し、ステップ 5「競合の解消」の手順 1〜2と同じ draft 戻し → phase=fix → [fix-plan の base 取り込み](../fix/references/fix-plan.md#base-取り込み)（取り込み・検証・Wiki 適用証跡の取り直し・commit・head 更新・push）を案内する。実際に競合しているとは扱わず、保護設定を変更しない。
> 2. `/rite:iterate {pr_number}` で変更後の HEAD を再レビューし、mergeable を確認する。全 CI job の完了・成功を確認して `/rite:ready {pr_number}` を実行する。
> 3. 取り込み・再レビュー・CI 確認・ready を完了した後に `/rite:batch-run --merge`（引数省略）でキューを再開する。失敗中の手順があれば、その手順の対処を示して停止し、未完のままキューを再開しない。
> `--merge` モードで `[fix:replied-only]` により停止した場合は、停止報告に続行コマンドも併記する: `/rite:ready {pr_number} && /rite:merge {pr_number}`（デフォルトモードでは `[fix:replied-only]` は停止せず draft を残して次へ進むため、この併記は不要）

---

## エラー時の方針

- **失敗は即停止**。`MERGE_ERROR=behind` はステップ 8 の専用復旧手順を先に実施し、それ以外の失敗 Issue は `/rite:recover {issue}` で個別復帰。merge 時の base との競合（`MERGE_NOT_READY=conflicting`）は失敗ではなく、ステップ 5 の「競合の解消」でステップ 3 へ戻る
- **サーキットブレーカーも即停止**。`[iterate:max-cycles-reached]` はステップ 8 で `failed[]` に記録し、cursor を保持する。再開後に当該 Issue がステップ 6 まで到達したら、その failed 記録を除去して前進する
- **session_id 解決不可は fail-loud**: `run-queue-{session_id}.json` を組む前に解決。不可なら global 名へフォールバックせず `exit 1`
- run-queue は停止時に残す。引数省略 `/rite:batch-run` で cursor から再開（同一セッション）
- handoff は使わない。continuation hint と flat step 構造で継続する
- 実装計画承認は batch 中 run-queue 判定で自動承認。closed / 親 Issue / 品質 C-D の入力品質ゲートは batch でも止まる
- recover の active batch 継続でも本方針（ブレーカーを含め失敗は即停止）を適用する

rationale: references/rationale.md#breaker-stop
rationale: references/rationale.md#no-handoff
rationale: references/rationale.md#session-scoped-queue
rationale: references/rationale.md#recover-batch-continue
rationale: references/rationale.md#replied-only-mode
rationale: references/rationale.md#no-dedicated-helper
