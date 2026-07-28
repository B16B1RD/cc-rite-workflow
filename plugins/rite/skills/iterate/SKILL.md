---
name: iterate
description: |
  rite workflow のレビュー/修正ループ: 指定 PR を /rite:pr-review ⇄ /rite:fix で mergeable まで
  自律的に回す。/rite:open・/rite:batch-run から呼ばれる sub-step、または手動 /rite:iterate <pr>。
  汎用の「PR を直す」ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:iterate <pr_number>
argument-hint: "<pr_number>"
---

# /rite:iterate

`/rite:pr-review` ↔ `/rite:fix` を **blocking 指摘ゼロ（mergeable）になるまでループ** する（blocking の定義は [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) が SoT。実測を伴わない指摘は non-blocking として `/rite:pr-review` ステップ 5.4 に記録されたまま残存し、その状態で正常出口に到達しうる）。ただし `safety.max_review_cycles`（既定 5）を上限とする **サーキットブレーカー** を備え、reviewer の非決定的な振動や非収束 PR による無限ループを構造的に防ぐ。やることは以下のシーケンシャルなタスク列:

0. flow-state から issue_number / branch_name を復元
0.6. cycle counter を初期化（fresh は 0 にリセット / resume は継続）+ `safety.max_review_cycles` を読込・検証
1. cycle 上限チェック → 未到達なら counter を +1 して `/rite:pr-review` を invoke / 到達なら サーキットブレーカー（ステップ 6）へ
2. review sentinel を判定（`[review:mergeable]` → 終了 / `[review:fix-needed:N]` → ステップ 3 / その他 → AskUserQuestion）
3. `/rite:fix` を invoke
4. fix sentinel を判定（`[fix:pushed]` → ステップ 1 に戻る / `[fix:replied-only]` `[fix:cancelled-by-user]` → 終了 / `[fix:error]` → AskUserQuestion）
5. 完了通知を出す
6. （cycle 上限到達時のみ）サーキットブレーカー: バッチ実行（`/rite:batch-run`）は `[iterate:max-cycles-reached]` を emit して当該 Issue を failed 扱いにさせ、対話実行は AskUserQuestion（さらに N cycle 継続 / 中止 / draft のまま停止）でユーザーに判断を委ねる

**サーキットブレーカー**（`safety.max_review_cycles`、既定 5）が唯一の自動安全網。上限到達時は、対話実行では AskUserQuestion（さらに N cycle 継続 / 中止 / draft のまま停止）でユーザーに判断を委ね（自動でループを継続しない）、`/rite:batch-run` バッチ実行では当該 Issue を failed 扱いにする sentinel を emit して次 Issue へ進ませる（バッチ全体のストール防止）。cycle_count は flow-state に永続化され resume 後も継続する（AC-3）。それ以外の中断経路は 2 種類: (a) ユーザーが fix.md 内 AskUserQuestion で「中止」を選択 → `[fix:cancelled-by-user]` emit + ループ終了、(b) ユーザーが Ctrl+C で中断 → flow-state phase 残存。どちらも `/rite:recover` で再開可。

途中で止まったら flow-state に現 phase (review or fix) が残るので `/rite:recover` で再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number (required)
**Output**: 完了通知（`[review:mergeable]` 到達 or `[fix:replied-only]` 終了 or `[fix:cancelled-by-user]` 中断 or サーキットブレーカー発火（`[iterate:max-cycles-reached]` バッチ / `[iterate:max-cycles-stopped]` 対話中止）or Ctrl+C 中断）

## Arguments

| Argument | Description |
|----------|-------------|
| `<pr_number>` | レビュー/修正対象の PR 番号 (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{pr_number}` | 引数 |
| `{issue_number}` | flow-state `issue_number` field |
| `{branch_name}` | flow-state `branch` field |
| `{max_review_cycles}` | `safety.max_review_cycles` in `rite-config.yml`（既定 5、無効値は既定へフォールバック） |
| `{cycle_count}` | flow-state `cycle_count` field（review⇄fix cycle の消化数。ステップ 1 で increment、fresh entry で 0 リセット） |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 0: flow-state から issue_number / branch_name を復元

`{issue_number}` / `{branch_name}` は standalone 起動でも flow-state set 呼び出しで必須のため、本コマンド冒頭で flow-state から復元する。skills/open/SKILL.md Step 0 の canonical pattern (一行 + `|| var=""` fallback) と対称化する。

```bash
iterate_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "") || iterate_issue=""
iterate_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "") || iterate_branch=""
echo "[CONTEXT] ITERATE_ISSUE=$iterate_issue; ITERATE_BRANCH=$iterate_branch"
```

LLM は `[CONTEXT] ITERATE_ISSUE` / `ITERATE_BRANCH` から値を読み、後続の flow-state.sh set 呼び出しで `--issue` / `--branch` に literal substitute する。値が空の場合は AskUserQuestion で「Issue 番号 / ブランチ名を入力 / 中止」を提示。

### ステップ 0.5: セッション worktree 健全性の保証（multi_session 有効時 / AC-2 #1676）

ループに入る前に、対象作業ブランチの session worktree を保証する。これがないと、worktree 不在（resume / context 圧縮 / 別セッション跨ぎで欠落）のまま review/fix を invoke し、メインツリー（develop）上で PR 変更を読めないまま degraded に回り続ける（本 Issue の As-Is）。共通ヘルパー `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)）で検出・再構築する（`{issue_number}` / `{branch_name}` は ステップ 0 の `ITERATE_ISSUE` / `ITERATE_BRANCH` marker の値）:

```bash
bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue {issue_number} --branch {branch_name}
```

> `--branch {branch_name}` を明示することで（review/fix の `--branch {head_ref}` 渡しと対称）、helper が issue-N の ref から branch を自動推定する経路を回避し、同一 issue に複数ブランチが存在する場合でも決定的に対象ブランチを選ぶ。`ITERATE_BRANCH` が空の場合は省略してよい（helper が ref 推定にフォールバックする）。

`[CONTEXT] WT_ENSURE=` marker の分岐は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 3.1.5 の **WT_ENSURE 分岐表（SoT）** に従う:

- `disabled` / `already_in` → no-op、ステップ 1 へ。
- `reenter` / `reconstructed` → `EnterWorktree` ツールを `path: {path}`（marker の `path=` 値）で呼び出してからステップ 1 へ。`reconstructed` は helper が `git worktree add` 済み。EnterWorktree 失敗時の切り分けは recover.md Phase 3.1.5 / /rite:open Step 2.3-W と同じ（silent に新規扱いしない）。
- `residue` → AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` を表示）。
- `branch_absent` → 対象ブランチが実在しない。**develop 上で続行しない**。AskUserQuestion で「Issue 番号 / ブランチを確認して再実行 / 中止」を提示（誤再構築しない）。
- `failed` → 再構築失敗（helper rc=1, stderr に原因 + 復旧手順）。**silent fallback せず明示停止**。develop 上で review/fix を回さない。

> 各 review/fix cycle の入場でも `/rite:pr-review` / `/rite:fix` が各自の入場ゲートで同じ helper を通すため、cycle 途中で worktree が失われても次 cycle 頭で再保証される（AC-2 の「cycle 前段で worktree-ensure が通る」を多層で担保）。本ステップ 0.5 はループ全体の前段ゲート。

---

## ステップ 0.6: cycle counter の初期化 + max_review_cycles の検証

ループに入る前に、review⇄fix サーキットブレーカーの cycle counter を初期化し、上限値を検証する（#1701）。counter は flow-state の `cycle_count` に永続化され、resume を跨いで継続する（AC-3）。

`{issue_number}` / `{branch_name}` は ステップ 0 の `ITERATE_ISSUE` / `ITERATE_BRANCH` marker の値をリテラル置換する:

```bash
# (1) max_review_cycles を rite-config.yml から読取・検証（AC-4）。無効値（0 以下 / 非数値）は WARNING + 既定値 5
raw_max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$raw_max" in
  '')            max_cycles=5 ;;                                   # キー欠落 = 既定（正常系、WARNING なし）
  0|*[!0-9]*)    max_cycles=5; echo "WARNING: safety.max_review_cycles='$raw_max' は無効（0 以下 / 非数値）。既定値 5 を使用します" >&2 ;;
  *)             max_cycles=$raw_max ;;
esac

# (2) fresh / resume 判定: iterate 起動時の phase が review/fix なら resume（counter 継続）、それ以外は fresh（0 リセット）。
#     run バッチで前 Issue の cycle_count が同一セッション flow-state に merge-preserve され次 Issue に漏れるのを防ぐ。
cur_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || cur_phase=""
cur_cc=$(bash {plugin_root}/hooks/flow-state.sh get --field cycle_count --default 0) || cur_cc=0
case "$cur_cc" in ''|*[!0-9]*) cur_cc=0 ;; esac   # 読めない / 不正なら 0 から（安全側: 既定上限で必ず止まる）
case "$cur_phase" in
  review|fix) cb_mode_init=resume ;;
  *)          cb_mode_init=fresh ;;
esac
if [ "$cb_mode_init" = fresh ] && [ "$cur_cc" -gt 0 ] 2>/dev/null; then
  # stale counter を除去（--cycle-count 0 は key 自体を削除。他フィールドは merge-preserve）。
  # reset 失敗を握り潰さず WARNING を surface する（stale counter が残るとブレーカーが早期発火し
  # うるため）。非ブロッキング（iterate は止めない）。ステップ 6.2 継続経路の reset と対称。
  bash {plugin_root}/hooks/flow-state.sh set --phase "${cur_phase:-pr}" \
    --next "review⇄fix ループ開始（cycle counter reset）" --cycle-count 0 >/dev/null 2>&1 \
    || echo "WARNING: cycle counter reset に失敗（stale counter が残りブレーカー早期発火の恐れ）" >&2
  cur_cc=0
fi
echo "[CONTEXT] ITERATE_CYCLE_MAX=$max_cycles; ITERATE_CYCLE=$cur_cc; ITERATE_CYCLE_MODE=$cb_mode_init"
```

`ITERATE_CYCLE_MAX` / `ITERATE_CYCLE` を retain してステップ 1 の上限チェックに渡す。

---

## ステップ 1: cycle 上限チェック → /rite:pr-review を invoke

ループ頭で cycle_count を上限と比較する。**未到達なら** counter を +1 して `phase=review` に更新後 `/rite:pr-review` を invoke、**到達済みなら** サーキットブレーカー（ステップ 6）へ分岐する。`max_review_cycles` は marker 依存を避けるため config から silent 再読込する（検証・WARNING はステップ 0.6 で実施済）:

```bash
cc=$(bash {plugin_root}/hooks/flow-state.sh get --field cycle_count --default 0) || cc=0
case "$cc" in ''|*[!0-9]*) cc=0 ;; esac
raw_max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$raw_max" in ''|0|*[!0-9]*) max_cycles=5 ;; *) max_cycles=$raw_max ;; esac  # 検証済。ここは silent fallback

if [ "$cc" -ge "$max_cycles" ] 2>/dev/null; then
  # 直前の [fix:pushed] が fix.md ステップ5.1 で set した継続 handoff (`/rite:pr-review {pr}`) を
  # default-clear する（`--handoff` を伴わない set は handoff を消す）。これをしないと、fire 後に
  # turn が終わったとき stop-loop-continuation.sh が残存 handoff を consume して `/rite:pr-review` を
  # 再注入し、サーキットブレーカーを無視してループが継続する。`[fix:error]` が set で handoff を
  # クリアして clean terminal になるのと同じ役割（cycle_count は merge-preserve で上限のまま維持）。
  bash {plugin_root}/hooks/flow-state.sh set \
    --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
    --next "サーキットブレーカー発火 (cycle 上限 $max_cycles 到達)" \
    || echo "WARNING: サーキットブレーカー発火時の handoff クリアに失敗（Stop hook が /rite:pr-review を再注入しブレーカーを迂回する恐れ）" >&2
  echo "[CONTEXT] ITERATE_CB=fire; cycle=$cc; max=$max_cycles"
else
  new_cc=$((cc + 1))
  # counter increment（ブレーカーを前進させる主経路）の set も fail-observable にする。silent に
  # 失敗すると cycle_count が increment されず counter が stuck → ブレーカーが永久に発火せず
  # 無限ループ化する（fire 分岐の handoff クリア失敗と同種の「ブレーカー無効化」方向）。非ブロッキング。
  bash {plugin_root}/hooks/flow-state.sh set \
    --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
    --next "review 実行中 (cycle $new_cc/$max_cycles)" --cycle-count "$new_cc" \
    || echo "WARNING: cycle counter increment に失敗（counter 未前進でブレーカーが発火せず無限ループ化の恐れ）" >&2
  echo "[CONTEXT] ITERATE_CB=ok; cycle=$new_cc; max=$max_cycles"
fi
```

| `ITERATE_CB` marker | アクション |
|---------|-----------|
| `ok` | counter を +1 済。`/rite:pr-review` を invoke（下記）してステップ 2 へ |
| `fire` | cycle 上限到達。**review を invoke せず** サーキットブレーカー（ステップ 6）へ直行（mergeable 判定済 PR には発火しない = ステップ 2 で先に `[review:mergeable]` 終了するため到達しない、AC-5） |

`ITERATE_CB=ok` のとき `/rite:pr-review` を invoke:

```text
skill: rite:pr-review
args: "{pr_number}"
```

---

## ステップ 2: review sentinel を判定

| Sentinel | アクション |
|---------|-----------|
| `[review:mergeable]` | **ループ終了**（完了通知へ） |
| `[review:fix-needed:N]` | ステップ 3 (fix invoke) へ |
| `[review:error]` | AskUserQuestion で「再試行 / 中止」を提示 (sentinel 不在とは別経路で reviewer 側エラーを明示) |
| sentinel 不在 | AskUserQuestion で「再試行 / 中止」を提示 |

---

## ステップ 3: /rite:fix を invoke

flow-state を `phase=fix` に更新後、`/rite:fix` を invoke:

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase fix --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "fix 実行中"
```

```text
skill: rite:fix
args: "{pr_number}"
```

---

## ステップ 4: fix sentinel を判定

| Sentinel | アクション |
|---------|-----------|
| `[fix:pushed]` | ステップ 1 (cycle 上限チェック → review 再実行) に戻る — **ループ継続**（上限到達ならステップ 6 サーキットブレーカーへ） |
| `[fix:pushed-wm-stale]` | ステップ 1 に戻る (WM stale 警告は表示するが loop は継続。上限チェックはステップ 1 が実施) |
| `[fix:replied-only]` | **ループ終了**（reply のみで完結） |
| `[fix:cancelled-by-user]` | **ループ終了**（ユーザーが fix.md 内 cancel 経路 — ステップ 1.4 Cancel option / Fast Path Cancel handoff 等 — で中止選択。`/rite:recover` で再開可） |
| `[fix:error]` | AskUserQuestion で「再試行 / 中止」を提示 |
| sentinel 不在 | AskUserQuestion で「再試行 / 中止」を提示 (どの sentinel が期待されていたか、直近の fix 出力 100 行、flow-state phase を表示) |

---

## ステップ 5: 完了通知

> **構造的保証**: 終了 sentinel (`[review:mergeable]` / `[fix:replied-only]` / `[fix:cancelled-by-user]`) 到達時、sub-skill が `FINALIZE:...` handoff をセットしており、`Stop` hook が本ステップの完了通知を出力せず turn を終えようとする停止を **1 回だけ** 差し戻す。詳細は「ループ継続・終了の構造的保証」節を参照。完了通知は必ず出力すること。

### ステップ 5.0: 一時残骸の最終回収 (terminal cleanup)

完了通知を出力する**前に**、本ループが残した一時ブランチ・worktree を回収する。`pr-cycle-cleanup.sh` は review entry (pr-review.md ステップ 1.0.0 PR Cycle Branch Cleanup) でも走るが、それは各 review **開始時** の発火であり、**最後の** review/fix cycle が残した残骸 (例: 最終 cycle の `rite-review-mutation-*` / `rite-revert-test-*` detached worktree、外部 checkout 由来の bare `pr-{N}` ブランチ) を sweep する後続 review が存在しない。本ループの終端で明示的に発火させ、回収の到達性を担保する (Issue #1526 AC-2)。non-blocking — 失敗してもループ完了を妨げない (AC-5):

```bash
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

これは正常終了・ユーザー中断の**両経路**で実行する (どちらの出口でも残骸の累積を防ぐ)。出力 status 行 (`[pr-cycle-cleanup] status=...`) はそのまま表示し、何を回収したかを可視化する。

> **24h age guard との関係**: `rite-review-mutation-*` / `rite-revert-test-*` detached worktree は cross-session in-flight 保護のため mtime 24h 未満は保護される (`pr-cycle-cleanup.sh` Step 4)。よって本ループが直前に作った若い worktree はこの発火では消えず、次回 cleanup (24h 経過後) で確実に回収される。即時 0 残骸ではなく **確実な最終回収** を担保する設計 (Issue #1526 D-04)。即時回収には reviewer 側の session-scoped 記録が必要だが reviewer (`agents/_reviewer-base.md`) は本 Issue の Non-Target。

### 正常終了 (`[review:mergeable]` or `[fix:replied-only]`)

```
## /rite:iterate 完了

- PR: #{pr_number}
- 終了理由: {review:mergeable | fix:replied-only}
- ブランチ: {branch_name}

次のステップ:
- Ready 化: /rite:ready {pr_number}
- マージ (Ready 後): /rite:merge {pr_number}

flow-state は phase={review|fix} のままです。`/rite:ready` 実行時に phase=ready に遷移します。
```

### ユーザー中断 (`[fix:cancelled-by-user]`)

```
## /rite:iterate 中断

- PR: #{pr_number}
- 終了理由: fix:cancelled-by-user (fix.md 内 AskUserQuestion で中止選択)
- ブランチ: {branch_name}

再開方法:
- /rite:recover で本コマンドが再起動 (flow-state phase=fix のため fix invoke から再開)
- 手動で /rite:iterate {pr_number} を再実行することも可
```

---

## ステップ 6: サーキットブレーカー（cycle 上限到達時のみ）

ステップ 1 で `ITERATE_CB=fire`（`cycle_count >= max_review_cycles`）となったときのみ到達する。まず batch 実行（`/rite:batch-run` 経由）か対話実行かを **自セッションの** run-queue（`run-queue-{session_id}.json`）から判定する。`/rite:batch-run` は駆動中に `active=true` を立て、cursor が処理中 Issue を指す。iterate は batch-run から**同一セッションで invoke される**ため、driving 中なら本 iterate の ambient session_id と run-queue の session_id は一致し、自セッションのキューだけを参照する（他セッションのキューは別ファイルのため構造的に読まない、Issue #1859 AC-2）。よって **`active == true` かつ** cursor の Issue が本 iterate の対象と一致すれば batch と判定する（`active` 条件は、停止済み dormant キューが cursor 一致だけで active batch と誤判定されるのを防ぐ。read-only 参照。`{issue_number}` はステップ 0 の marker 値をリテラル置換）:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
cb_mode=interactive
# session_id 解決不可（空）→ 自セッションのキューを特定できないため安全側 interactive のまま
# （read-only なので fail-loud はせず、batch と誤判定しない安全側に倒す）
if [ -n "$session_id" ] && [ -f "$queue_file" ]; then
  q_active=$(jq -r '.active // false' "$queue_file" 2>/dev/null)   # active 欠落の旧形式は false（安全側 = interactive）
  q_cursor=$(jq -r '.cursor // 0' "$queue_file" 2>/dev/null)
  q_total=$(jq -r '.issues | length' "$queue_file" 2>/dev/null)
  q_issue=$(jq -r ".issues[$q_cursor] // empty" "$queue_file" 2>/dev/null)
  if [ "$q_active" = "true" ] && [ "$q_cursor" -lt "${q_total:-0}" ] 2>/dev/null && [ "$q_issue" = "{issue_number}" ]; then
    cb_mode=batch
  fi
fi
echo "[CONTEXT] ITERATE_CB_MODE=$cb_mode; issue={issue_number}; pr={pr_number}"
```

| `ITERATE_CB_MODE` | アクション |
|---|---|
| `batch` | ステップ 6.1（failed sentinel emit）|
| `interactive` | ステップ 6.2（AskUserQuestion）|

### ステップ 6.1: バッチ実行 — failed sentinel を emit

review を回さず、当該 Issue を非収束（failed）として `/rite:batch-run` に返す。`/rite:batch-run` はこの sentinel を受けて当該 Issue を failed 記録し、次の Issue へ進む（ready/merge/cleanup はスキップ、draft/open PR はレビュー待ちで残す）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない（`[fix:error]` が set で handoff をクリアして clean terminal になるのと同じ。以降は run の flat 構造 + HTML hint で継続）:

```
## /rite:iterate サーキットブレーカー発火（バッチ）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: review⇄fix cycle が上限 {max_review_cycles} に到達（非収束）
- 措置: 当該 Issue を failed 扱いとし、draft/open PR をレビュー待ちで残します（`/rite:batch-run` が残りキューを続行、最終 Issue なら完了通知へ）

<!-- [iterate:max-cycles-reached] -->
```

制御を `/rite:batch-run` に戻す（run 側で cursor 前進）。

### ステップ 6.2: 対話実行 — AskUserQuestion

`AskUserQuestion` で以下 3 択を提示する。設問には残 findings 数の推移など観察材料を添えると判断しやすい（Scenario 2）。設問文・選択肢の `{max_review_cycles}` はリテラル置換する:

- **さらに {max_review_cycles} cycle 継続**: counter を 0 にリセットしてループを再開し、もう {max_review_cycles} cycle 回す
- **中止**: ループを終了（flow-state phase 保持、`/rite:recover` で再開可）
- **draft のまま停止**: ループを終了し draft PR をレビュー待ちで残す（`/rite:recover` で再開可）

回答に応じて分岐する:

| 選択 | アクション |
|---|---|
| さらに {max_review_cycles} cycle 継続 | 下記で counter を 0 リセット後、**ステップ 1 へ戻る**（もう {max_review_cycles} cycle 実行） |
| 中止 / draft のまま停止 | 下記の停止通知を出力してループ終了 |

**継続時**（counter リセット → ステップ 1 へ）:

```bash
# reset の silent 失敗を可視化する（ステップ 0.6 / fire / ok の 3 set と対称の 4 つ目）。
# 失敗すると cycle_count が上限のまま残り、「継続」を選んでもステップ 1 で即再発火して同じ
# AskUserQuestion に戻る（fail-safe だが継続選択が無言で無効化される）。非ブロッキング。
bash {plugin_root}/hooks/flow-state.sh set \
  --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "review⇄fix ループ継続（cycle counter reset、ユーザー承認）" --cycle-count 0 \
  || echo "WARNING: cycle counter reset に失敗（継続選択が反映されず再度ブレーカー発火の恐れ）" >&2
```

**中止 / draft のまま停止時**（停止通知を出力して終了）:

```
## /rite:iterate サーキットブレーカー発火（対話・停止）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: review⇄fix cycle が上限 {max_review_cycles} に到達
- 選択: {中止 | draft のまま停止}

再開方法:
- /rite:recover で本コマンドが再起動（flow-state phase 保持）。cycle_count は上限のまま保持されるため、
  再開直後に再びサーキットブレーカーが発火する（安全側: 上限を越えて自動継続しない）。継続する場合は
  発火時の AskUserQuestion で「継続」を選ぶ
- Ready 化して手動でレビューを完了させる: /rite:ready {pr_number}

<!-- [iterate:max-cycles-stopped] -->
```

---

## エラー時の方針

- ユーザーが Ctrl+C で中断した場合: flow-state に現 phase (review or fix) が残るので `/rite:recover` で本コマンドが再起動する (詳細な phase → command routing は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 5.3 を参照)
- `[fix:error]` 時: 自動継続せず必ず AskUserQuestion で確認 (silent regression 防止)
- reviewer が non-deterministic に振動 (毎 cycle で別の指摘) する場合: `safety.max_review_cycles`（既定 5）到達でサーキットブレーカーが発火する（ステップ 6）。対話実行は AskUserQuestion（継続 / 中止 / draft のまま停止）でユーザーに判断を委ね、`/rite:batch-run` バッチ実行は `[iterate:max-cycles-reached]` を emit して当該 Issue を failed 扱いにし次 Issue へ進む。Ctrl+C による手動中断も従来どおり可能

---

## ループ継続・終了の構造的保証

継続点・終了点で sub-skill が one-shot handoff (`/rite:...` / `FINALIZE:{result}:{pr}`) を flow-state にセットし、turn 早期終了時は Stop hook (`stop-loop-continuation.sh`) が consume + prefix 分岐で停止を差し戻す。`[fix:error]` とサーキットブレーカー fire 分岐は handoff を持たない/能動クリアする (Stop hook は停止を許可)。機構の全体解説・sentinel → handoff 対応表・無限 block 防止の設計:
rationale: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism)

## 設計判断

- **blocking 指摘ゼロ（mergeable）到達が正常出口** — blocking の定義式は本ファイルに複製せず [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) を SoT とする（同 § は reviewer finding に閉じた canonical 式と fix loop 全体を対象とする consumer 式の差を「適用範囲」で意図的なスコープ差として定義している。本スキルはループ側なので後者に従い、実測の有無を判定できない指摘は blocking のまま扱う）。実測を伴わない指摘は non-blocking として `/rite:pr-review` ステップ 6.1.d の PR 記録コメント（`pr_review.post_comment` 非依存で draft PR 上に残る）・ステップ 5.4 統合レポート・永続 JSON に記録されたまま残存するため、**非実測指摘が N 件残った状態でも `[review:mergeable]` に到達してループが正常終了しうる**（#2024）— 残存分は draft PR の人間レビューに委ねる設計。加えて `safety.max_review_cycles`（既定 5）到達で発火するサーキットブレーカーを唯一の自動安全網として持つ（#1701）。reviewer の非決定的振動や非収束 PR による無限ループを構造的に防ぐ。同一 finding 検出 / quality signal escalation といった細粒度の安全網は依然として持たず、cycle 上限のみに絞る（CLAUDE.md「シンプルさを死守」）
- **上限到達時も自動中止しない**: 対話実行は AskUserQuestion でユーザーに判断を委ね（自律実行の哲学を維持）、`/rite:batch-run` バッチ実行のみ failed 扱いで次 Issue へ自動遷移する（バッチ全体のストール防止）
- **cycle counter は flow-state に保持**: 専用 state file (`.rite/state/*.count` 等) は持たず、`cycle_count` を flow-state の merge-preserve フィールドとして永続化する（`worktree` と同じ additive パターン）。resume を跨いで継続し（AC-3）、fresh entry（phase が review/fix 以外）で 0 リセットして run バッチの Issue 間リークを防ぐ。Stop hook の handoff とは独立（handoff は one-shot consume される継続マーカー、cycle_count は accumulate されるカウンタ）
- 別 Issue 化経路は廃止済み (commit 1a で fix.md Phase 4.3 削除) — 「別 Issue にスキップして loop 終了」の抜け穴は塞がれている
