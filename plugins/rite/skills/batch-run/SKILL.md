---
name: batch-run
description: |
  rite workflow のバッチ実行スキル: 複数 Issue に対し /rite:open → /rite:iterate を
  順次・自律実行して draft PR を残す（--merge 指定時のみ ready→merge→cleanup まで完走）。
  ユーザーが明示的に /rite:batch-run で起動する meta-orchestrator。auto-activate しない。
  起動: /rite:batch-run [--merge] <issue_number>...
argument-hint: "[--merge] <issue_number>..."
---

# /rite:batch-run

> 実行開始時は [Autonomous Execution](../rite-workflow/references/autonomous-execution.md) を適用する。

**デフォルトでは** `/rite:open` → `/rite:iterate` を **順次・完全自律（無確認）** して draft PR を残す。`--merge` 時のみ `/rite:ready` → `/rite:merge` → `/rite:cleanup` まで完走する。

成功する限り無確認。失敗は即停止。ただし `[iterate:max-cycles-reached]` は**即停止せず** failed 記録して次へ進む。handoff は **一切 set しない**。継続は flat step 構造。
rationale: references/rationale.md#default-draft
rationale: references/rationale.md#breaker-not-stop
rationale: references/rationale.md#no-handoff

途中停止: 処理中 Issue は `/rite:recover {issue}`、残りキューは引数省略 `/rite:batch-run` で再開（モードも永続化）。中断が直近（`updated_at` から 2 時間以内）かつ cursor 一致なら recover 単体でも残りキューへ自動継続（[recover Phase 5.5](../recover/SKILL.md)）。再開は**同一セッション内**前提。
rationale: references/rationale.md#session-scoped-queue

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version)。run-queue は **`run-queue-{session_id}.json`**（`flow-state.sh path` の basename、`state-path-resolve.sh` の state root）。sandbox で worktree cwd からの書込が拒否された当該 bash のみ `dangerouslyDisableSandbox: true` で再実行してよい（確認不要。[git-worktree-patterns.md](../../references/git-worktree-patterns.md#worktree-cwd-から-main-checkout-配下への書き込みが-sandbox-の-write-許可リストでブロックされる)）。

## Contract

**Input**: `[--merge]` + Issue number(s) — 1 個以上、空白区切り（省略時は自セッションの run-queue からモードごと再開）
**Output**: 全 Issue 処理完了の完了通知（ステップ 7。デフォルトは draft PR 群、`--merge` は merge/cleanup 完走）、または最初の失敗での停止報告（残り Issue 含む、ステップ 8）
**自律度**: 完全自律（無確認）。デフォルトは draft PR まで、`--merge` 時は merge を含め確認を挟まない。失敗時のみ停止。

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

## Arguments

| Argument | Description |
|----------|-------------|
| `--merge` | （任意フラグ）指定すると open→iterate に加え ready→merge→cleanup まで完走する。省略時は各 Issue を draft PR で止める。Issue 番号との順序は問わない（例: `--merge 1527 1528` / `1527 --merge 1528`） |
| `<issue_number>...` | 処理対象の Issue 番号（1 個以上、空白区切り）。省略時は `.rite/state/run-queue-{session_id}.json` の未処理分（cursor 以降）をモードごと再開 |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_numbers}` | 引数 `$ARGUMENTS`（`--merge` フラグ + 空白区切りの Issue 番号群。省略可） |
| `{run_mode}` | ステップ 0 / 1 の `mode=` marker 値（`default` = draft 止まり / `merge` = フルパイプライン） |
| `{summary_issues}` / `{summary_total}` / `{summary_remaining}` / `{summary_per_issue}` / `{summary_est_total}` | ステップ 0.5 の `RUN_SUMMARY` marker（`issues=` / `total=` / `remaining=` / `per_issue=` / `est_total=`。着手前サマリの表示に使う） |
| `{current_issue}` | ステップ 1 の `RUN_NEXT=process; issue=` が指す Issue |
| `{new_cursor}` / `{total}` | ステップ 6 の `RUN_ADVANCE` marker（`cursor=`（前進後のキューを進めた件数）/ `total=`。各 Issue の cursor 前進時の `✅ N/M 件処理済み` 進捗表示に使う。成功件数ではない） |
| `{pr_number}` | ステップ 2 の open 完了通知（`[pr:created:N]`）から抽出 |
| `{branch_name}` | ステップ 2 の open 完了通知「ブランチ: ...」行から抽出（ステップ 6 の cleanup に渡す） |
| `{processed_issues}` | ステップ 7 bash の `processed=`（全完了 Issue 一覧） |
| `{failed_issues}` | ステップ 7 bash の `failed=`（サーキットブレーカー `[iterate:max-cycles-reached]` で非収束となった Issue 一覧。空 `[]` のとき完了通知の該当行を省略） |
| `{outstanding_n}` | ステップ 6 で cleanup 完了報告から読む `[cleanup:outstanding:N]` sentinel の `N` に実際に埋め込まれた数値 |
| `{outstanding_issues}` | ステップ 7 bash の `outstanding=`（未完了事項が残った Issue 一覧。空 `[]` のとき完了通知の該当行を省略） |
| `{done_issues}` / `{remaining_issues}` | ステップ 8 bash の `done=` / `remaining=`（停止時の処理済み / 未処理 Issue） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute |

---

## ステップ 0: キュー初期化 / 再開判定

`.rite/state/run-queue-{session_id}.json`（`{issues, cursor, mode, failed, outstanding, active, updated_at}`。session_id は `flow-state.sh path` の basename。解決できなければ fail-loud — global 名へフォールバックしない）を SoT とする。突き合わせ対象は自セッションのキューのみ。`mode` 欠落は `default`、`failed` / `outstanding` 欠落は `[]`、`active` 欠落は `false`、`updated_at` 欠落は stale。`failed` は `[iterate:max-cycles-reached]` の記録。`outstanding` は `[cleanup:outstanding:N]` で `n > 0` だった Issue。`active` はステップ 0 で `true`、ステップ 8 で `false`。`updated_at` は cursor 前進 / active 設定のたびに更新（ステップ 1 の skip-closed は対象外。[recover Phase 5.5](../recover/SKILL.md)）。
rationale: references/rationale.md#session-scoped-queue

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
mkdir -p "$(dirname "$queue_file")"

# 引数パース（"#1527, 1528" のような記号混在も許容して数値のみ抽出。--merge は位置非依存で検出）
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
  # coarse スキップ: 既に CLOSED の Issue（= 処理済み）は open し直さず cursor を進める
  state=$(gh issue view "$current" -R {owner_repo} --json state --jq '.state' 2>/dev/null || echo "OPEN")
  if [ "$state" = "CLOSED" ]; then
    jq '.cursor += 1' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"
    echo "[CONTEXT] RUN_NEXT=skip-closed; issue=$current; new_cursor=$((cursor+1)); total=$total; mode=$mode"
  else
    echo "[CONTEXT] RUN_NEXT=process; issue=$current; cursor=$cursor; total=$total; mode=$mode"
  fi
fi
```

| `RUN_NEXT` marker | アクション |
|---|---|
| `process` | `issue=` を `{current_issue}`、`mode=` を `{run_mode}` として retain → ステップ 2（open）へ |
| `skip-closed` | この Issue は既に処理済み。ステップ 1 を再実行（次の Issue へ） |
| `all-done` | 残り Issue 無し → ステップ 7（全完了通知）へ |

---

## ステップ 2: /rite:open を invoke

> この skill return 後、停止せずに sentinel を判定してステップ 3 へ進む。本コマンドは handoff を使わないため、継続はこの flat 構造に依存する。

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

> 本コマンドは iterate invoke の **前後で `flow-state.sh set` を呼ばない**（iterate 内部の handoff / FINALIZE 機構を壊さないため）。iterate は内部で review⇄fix を mergeable まで回し、完了通知を出して制御を戻す。`--merge` モードの正常終了では、続くステップ 4 ready の `flow-state.sh set` が残存 FINALIZE handoff を default-clear する。デフォルトモードは ready を経由しないが、残存 FINALIZE handoff は次 Issue の open（ステップ 1.6 の `flow-state.sh set`）が default-clear し、最後の Issue 分はステップ 7 完了通知前の `consume-handoff` が消費する（失敗終了時に残る handoff はステップ 8 で消費する）。

```text
skill: rite:iterate
args: "{pr_number}"
```

iterate の終了 sentinel を `{run_mode}`（ステップ 1 の `mode=` marker）で出し分ける:

| Sentinel + `{run_mode}` | アクション |
|---------|-----------|
| `[review:mergeable]` + `merge` | iterate 収束 → ステップ 4（ready）へ |
| `[review:mergeable]` + `default` | iterate 収束。**ready/merge/cleanup はスキップ**し、draft PR を残したまま **ステップ 6 の cursor 前進 bash へ直行**（cleanup invoke はしない） |
| `[fix:replied-only]` + `merge` | **非収束として失敗扱い** → ステップ 8（段階=iterate）。reply のみで mergeable 未到達のまま merge すると未解決指摘を握り潰すため。停止報告に続行コマンド `/rite:ready {pr_number} && /rite:merge {pr_number}` を案内 |
| `[fix:replied-only]` + `default` | merge しないため即停止は不要。**「Issue #{current_issue} の draft PR #{pr_number} は未解決指摘あり」を会話に明示** したうえで draft PR を残し、**ステップ 6 の cursor 前進 bash へ直行**してキューを次へ進める |
| `[iterate:max-cycles-reached]`（両モード） | **サーキットブレーカー発火 = 当該 Issue 非収束**。即停止（ステップ 8）はせず、ステップ 6 の failed 記録 bash で当該 Issue を `failed[]` に追加 → **ready/merge/cleanup をスキップ**して **ステップ 6 の cursor 前進 bash へ直行**（draft/open PR はレビュー待ちで残す。バッチ全体をストールさせず次 Issue へ進める）。停止しない理由: 非収束 1 件でバッチ全体を止めない設計（AC-2） |
| `[fix:cancelled-by-user]`（両モード） | ユーザー中断 → ステップ 8（段階=iterate） |
| `[fix:error]` / sentinel 不在（両モード） | **失敗** → ステップ 8（段階=iterate） |

<!-- run orchestration: after iterate returns a terminal sentinel, do NOT stop. merge mode + [review:mergeable] -> ステップ 4. default mode + [review:mergeable] or [fix:replied-only] -> ステップ 6 cursor advance (skip ready/merge/cleanup). [iterate:max-cycles-reached] (both modes) -> ステップ 6 failed-record bash + cursor advance (skip ready/merge/cleanup, do NOT stop). -->

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
| `[ready:error]` / sentinel 不在 | **失敗** → ステップ 8（段階=ready） |

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
| `[merge:not-ready]` / `[merge:error]` / sentinel 不在 | **失敗** → ステップ 8（段階=merge） |

<!-- run orchestration: after merge returns, do NOT stop — proceed to ステップ 6 -->

---

## ステップ 6: cleanup（`--merge` 時のみ）→ cursor を進める

**`{run_mode}=merge` のときのみ**、下記で `/rite:cleanup` を invoke する。**デフォルト（draft 止まり）モードはステップ 3 から直接このステップに遷移し、cleanup invoke をスキップして下段の cursor 前進 bash のみ実行する**（draft PR はレビュー待ちのため close せず残す）。**`[iterate:max-cycles-reached]`（サーキットブレーカー）経由の場合は両モードとも cleanup を invoke せず、下段の failed 記録 bash → cursor 前進 bash のみ実行する**（非収束 PR は close/merge せずレビュー待ちで残す）。

```text
skill: rite:cleanup
args: "{branch_name}"
```

> cleanup は branch / worktree 削除・Projects Status → Done・Issue close・未完タスクの follow-up Issue 化 + Projects 登録・Wiki ingest を担う。**follow-up Issue + Projects 登録は cleanup 内部に完全委譲**し、run は関与しない。

| Sentinel（`--merge` 時のみ） | アクション |
|---------|-----------|
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

**（`[iterate:max-cycles-reached]` 経由の場合のみ）** cursor を進める前に当該 Issue を `failed[]` に記録する（ステップ 7 完了通知で報告するため。両モードで実行。`{current_issue}` はステップ 1 の marker 値をリテラル置換）:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
# marker は jq/mv 成功に従属させる（失敗時に「記録済み」と誤主張して完了通知の failed 一覧から
# silent に脱落するのを防ぐ）
if jq --argjson n {current_issue} '.failed = ((.failed // []) + [$n] | unique)' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"; then
  echo "[CONTEXT] RUN_FAILED_RECORDED; issue={current_issue}"
else
  rm -f "$queue_file.tmp"
  echo "WARNING: failed 記録の書込に失敗（完了通知の failed 一覧から漏れる恐れ）" >&2
fi
```

cursor を進める（**両モード共有**。`--merge` 時は cleanup から制御が戻った後、デフォルト時はステップ 3 から直接ここへ、サーキットブレーカー時は上記 failed 記録の後にここへ到達する）:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg now "$now_ts" '.cursor += 1 | .updated_at = $now' "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"
new_cursor=$(jq -r '.cursor' "$queue_file"); total=$(jq -r '.issues | length' "$queue_file")
echo "[CONTEXT] RUN_ADVANCE; cursor=$new_cursor; total=$total"
```

`RUN_ADVANCE` の `cursor=` と `total=` を読み、`✅ {new_cursor}/{total} 件処理済み` を出してから分岐する。**この件数は「キューを進めた件数」であり成功件数ではない**。
rationale: references/rationale.md#cursor-not-success

`new_cursor < total` ならステップ 1 へ戻る（次の Issue を処理）。`new_cursor >= total` ならステップ 7 へ。

<!-- run orchestration: after this cursor advance, do NOT stop — loop back to ステップ 1 (next issue) or go to ステップ 7. (merge mode reaches here after cleanup returns; default mode reaches here directly from ステップ 3.) -->

---

## ステップ 7: 全 Issue 完了通知

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
rm -f "$queue_file"
echo "[CONTEXT] RUN_DONE; processed=$processed; failed=$failed; outstanding=$outstanding; mode=$mode"
```

`mode=`（`{run_mode}`）に応じて、`processed=` の Issue 一覧を `{processed_issues}`、`failed=` の非収束 Issue 一覧を `{failed_issues}` として完了通知を出し分ける。`failed=` が空配列 `[]` でない場合は、完了通知にサーキットブレーカーで failed 扱いとなった Issue を明示する（`[]` のときは該当行を省略する）。`outstanding=` の Issue 一覧を `{outstanding_issues}` として使う（cleanup 完了報告の「未完了事項」をロールアップする。`mode=merge` のときのみ意味を持つ — デフォルトモードは cleanup を invoke しないため `outstanding` は常に空）。

**デフォルト（`mode=default`）**: 各 Issue は draft PR で停止しており **merge していない**:

```
## /rite:batch-run 完了（draft 止まり）

処理した Issue: {processed_issues}
各 Issue を open→iterate まで実行し draft PR を作成しました（**merge していません**。レビュー待ちです）。
レビュー後に進めるには各 PR で `/rite:ready <pr>` → `/rite:merge <pr>`、
または最初からまとめて完走させるなら `/rite:batch-run --merge {processed_issues}` を実行してください。
（未解決指摘ありで通過した draft PR があれば、上記処理中にその旨を明示しています。）
（`failed=` が非空のときのみ）サーキットブレーカーで非収束（failed）となった Issue: {failed_issues} — draft/open PR をレビュー待ちで残しています。

<!-- [run:all-completed] -->
```

**`--merge`（`mode=merge`）**: 全 5 段を完走（ただし failed 扱いの Issue は merge/cleanup をスキップ済）:

```
## /rite:batch-run 完了

処理した Issue: {processed_issues}
全 Issue を処理しました（open→iterate→ready→merge→cleanup を完走）。
（`failed=` が非空のときのみ）サーキットブレーカーで非収束（failed）となり merge/cleanup をスキップした Issue: {failed_issues} — draft/open PR をレビュー待ちで残しています。`/rite:iterate <pr>` で再開できます。
未完了事項: （`outstanding=` が空のとき）なし（全 Issue） / （非空のとき）{outstanding_issues} の cleanup で非ブロッキング失敗が残っています — 各 Issue の cleanup 完了報告（本セッションのログ）を参照するか、`/rite:recover <issue>` で確認してください。

<!-- [run:all-completed] -->
```

---

## ステップ 8: 失敗時の停止報告（即停止）

いずれかのステップで失敗 sentinel を受領したら、run-queue-{session_id}.json を **残したまま**（cursor は失敗 Issue を指したまま）即停止して報告する。

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
[ -n "$session_id" ] || { echo "ERROR: batch-run: session_id を解決できません（run-queue はセッションスコープのため必須）" >&2; exit 1; }
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
# 失敗段が iterate の場合、fix.md が set した FINALIZE handoff が残り Stop hook が
# iterate 完了通知を差し戻しうる。停止報告の前に one-shot 消費して出力順序を確定させる。
bash {plugin_root}/hooks/flow-state.sh consume-handoff >/dev/null 2>&1 || true
# 停止時は active=false にする（run はもう iterate を駆動しない）。これにより停止後に同じ Issue を
# 手動 /rite:iterate した際、iterate ステップ 6 が dormant キューを active batch と誤判定せず
# 対話 AskUserQuestion を出せる（キューは cursor 保持のまま残し、引数省略 /rite:batch-run で再開可能）
now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg now "$now_ts" '.active = false | .updated_at = $now' "$queue_file" > "$queue_file.tmp" 2>/dev/null && mv "$queue_file.tmp" "$queue_file" \
  || { rm -f "$queue_file.tmp"; echo "WARNING: run-queue の active=false 書込に失敗（停止後の手動 iterate が batch と誤判定される恐れ）" >&2; }
cursor=$(jq -r '.cursor // 0' "$queue_file" 2>/dev/null || echo 0)
mode=$(jq -r '.mode // "default"' "$queue_file" 2>/dev/null || echo "default")
done_issues=$(jq -rc ".issues[:$cursor]" "$queue_file" 2>/dev/null || echo "[]")
remaining=$(jq -rc ".issues[$cursor:]" "$queue_file" 2>/dev/null || echo "[]")
echo "[CONTEXT] RUN_STOP; cursor=$cursor; done=$done_issues; remaining=$remaining; mode=$mode"
```

`done=` / `remaining=` / `mode=` を読んで停止報告を出す。デフォルトモードでは失敗段は `open` / `iterate` のいずれかに限られる（ready/merge/cleanup は実行しないため）:

```
## /rite:batch-run 停止

失敗した Issue: #{current_issue}（段階: {open|iterate|ready|merge|cleanup}、モード: {run_mode}）
失敗理由: {受領した失敗 sentinel または「sentinel 不在」}
失敗時の状態: PR #{pr_number}（{draft | open | 未作成}）

処理済み Issue: {done_issues}
未処理 Issue: {remaining_issues}

復旧:
- この Issue を続きから: /rite:recover {current_issue}
- 残りをまとめて再開: /rite:batch-run（引数省略で自セッションの run-queue の cursor とモードから再開。明示再開する場合の `--merge` 併記は下記の補足を参照）

<!-- [run:stopped] -->
```

> 復旧行の `/rite:batch-run` には、`{run_mode}=merge` のときのみ `--merge` を併記する（引数省略再開でも自セッションの run-queue の `mode` が維持されるため必須ではないが、明示再開する場合の指針として示す）。
> `--merge` モードで `[fix:replied-only]` により停止した場合は、停止報告に続行コマンドも併記する: `/rite:ready {pr_number} && /rite:merge {pr_number}`（デフォルトモードでは `[fix:replied-only]` は停止せず draft を残して次へ進むため、この併記は不要）

---

## エラー時の方針

- **失敗は即停止**。失敗 Issue は `/rite:recover {issue}` で個別復帰
- **例外: サーキットブレーカーは即停止しない**。`[iterate:max-cycles-reached]` は `failed[]` に記録して cursor 前進し次へ進む。ステップ 7 で報告（AC-2）
- **session_id 解決不可は fail-loud**: `run-queue-{session_id}.json` を組む前に解決。不可なら global 名へフォールバックせず `exit 1`
- run-queue は停止時に残す。引数省略 `/rite:batch-run` で cursor から再開（同一セッション）
- handoff は使わない。continuation hint と flat step 構造で継続する
- 実装計画承認は batch 中 run-queue 判定で自動承認。closed / 親 Issue / 品質 C-D の入力品質ゲートは batch でも止まる
- recover の active batch 継続でも本方針（失敗は即停止、ブレーカーのみ例外）を適用する

rationale: references/rationale.md#breaker-not-stop
rationale: references/rationale.md#no-handoff
rationale: references/rationale.md#session-scoped-queue
rationale: references/rationale.md#recover-batch-continue
rationale: references/rationale.md#replied-only-mode
rationale: references/rationale.md#no-dedicated-helper
