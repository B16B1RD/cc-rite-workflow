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

`/rite:pr-review` ↔ `/rite:fix` を **blocking 指摘ゼロ（mergeable）になるまでループ** する（blocking の定義は [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) が SoT。実測なし（`measured=false`）と判定された指摘は non-blocking として記録されたまま残存し、その状態で正常出口に到達しうる）。ただし `safety.max_review_cycles`（既定 5）を上限とする **サーキットブレーカー** を備え、reviewer の非決定的な振動や非収束 PR による無限ループを構造的に防ぐ。やることは以下のシーケンシャルなタスク列:

0. flow-state から issue_number / branch_name を復元
0.6. cycle counter を初期化（fresh は 0 にリセット / resume は継続。ただし発火済みマーカー `cycle_count > max_review_cycles` を検出したら phase に依らず fresh）+ `safety.max_review_cycles` を読込・検証
1. cycle 上限チェック → 未到達なら counter を +1 して `/rite:pr-review` を invoke / 到達なら サーキットブレーカー（ステップ 6）へ
2. review sentinel を判定（`[review:mergeable]` → 終了 / `[review:fix-needed:N]` → ステップ 3 / その他 → AskUserQuestion）
3. `/rite:fix` を invoke
4. fix sentinel を判定（`[fix:pushed]` → ステップ 1 に戻る / `[fix:replied-only]` `[fix:cancelled-by-user]` → 終了 / `[fix:error]` → AskUserQuestion）
5. 完了通知を出す
6. （cycle 上限到達時のみ）サーキットブレーカー: batch / 対話とも人間に問わず機械的に停止する。バッチ実行（`/rite:batch-run`）は `[iterate:max-cycles-reached]` を emit して当該 Issue を failed 扱いにさせ、対話実行は `[iterate:max-cycles-stopped]` の停止通知を出して終了する

**サーキットブレーカー**（`safety.max_review_cycles`、既定 5）が唯一の自動安全網。**発火＝失敗の機械的記録**であり、上限到達時は batch / 対話とも同構造（failed 記録 + draft 残し + 停止通知 + handoff クリア維持）で停止する — 人間に継続可否を問う経路は持たず、発火からマージへ到達する分岐も存在しない。`/rite:batch-run` バッチ実行では当該 Issue を failed 扱いにする sentinel を emit して次 Issue へ進ませる（バッチ全体のストール防止）。ループを再開する唯一の経路は人間が明示的に `/rite:iterate {pr}`（または `/rite:recover`）を再実行することである。cycle_count は flow-state に永続化され resume を跨いで継続するが（AC-3）、**発火済みマーカー**（fire 分岐が書く `cycle_count = max_review_cycles + 1`）で起動されたときだけはステップ 0.6 が phase に依らず 0 にリセットする。両者は排他で、境界は「発火したか」であって「上限に達しているか」ではない — 最終 cycle の実行中は `cycle_count == max_review_cycles` が通常状態として成立するため、そこでの中断からの resume は counter を継続し、ステップ 1 で正しく発火する。それ以外の中断経路は 2 種類: (a) ユーザーが fix.md 内 AskUserQuestion で「中止」を選択 → `[fix:cancelled-by-user]` emit + ループ終了、(b) ユーザーが Ctrl+C で中断 → flow-state phase 残存。どちらも `/rite:recover` で再開可。

途中で止まったら flow-state に現 phase (review or fix) が残るので `/rite:recover` で再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number (required)
**Output**: 完了通知（`[review:mergeable]` 到達 or `[fix:replied-only]` 終了 or `[fix:cancelled-by-user]` 中断 or サーキットブレーカー発火（`[iterate:max-cycles-reached]` バッチ / `[iterate:max-cycles-stopped]` 対話。いずれも非収束による失敗で、マージには進まない）or Ctrl+C 中断）

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
| `{cycle_count}` | flow-state `cycle_count` field（review⇄fix cycle の消化数。ステップ 1 で increment、fresh entry で 0 リセット。発火時は fire 分岐が `max_review_cycles + 1` を書いて発火済みを記録し、次回起動でステップ 0.6 の override が phase に依らず 0 リセットする） |
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
#     ただし発火済みマーカー（cycle_count > max_cycles）を検出した場合は phase に依らず fresh に倒す（下記 override）。
cur_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || cur_phase=""
cur_cc=$(bash {plugin_root}/hooks/flow-state.sh get --field cycle_count --default 0) || cur_cc=0
case "$cur_cc" in ''|*[!0-9]*) cur_cc=0 ;; esac   # 読めない / 不正なら 0 から（安全側: 既定上限で必ず止まる）
case "$cur_phase" in
  review|fix) cb_mode_init=resume ;;
  *)          cb_mode_init=fresh ;;
esac
# 発火後再実行 override: ステップ 1 の fire 分岐が書いた**発火済みマーカー**
# （cycle_count = max_cycles + 1）を検出したら、前回ブレーカーが発火して停止した後の再実行と
# 判定し phase に依らず fresh に倒す。fire 分岐は phase=review で set するため phase だけでは
# 「発火後停止」と「review 途中の中断」を区別できず、resume 判定のままだと再実行が即再発火して
# ループを再開できない（継続経路の消滅）。ブレーカー発火時に handoff は default-clear され、
# stop-loop-continuation.sh は handoff の有無のみで block を決めるため、発火後に iterate へ
# 再入場する経路は人間の明示コマンド（/rite:iterate 再実行 / /rite:recover）だけであり、
# ここで fresh に倒しても自動継続は発生しない。
# **判定に上限との一致（-ge）を使ってはならない**: cycle_count == max_cycles は、ステップ 1 の
# ok 分岐が review を invoke する前に counter を書くため、最終 cycle の review + fix を実行中
# ずっと成立する通常状態でもある。-ge で判定すると最終 cycle 途中の Ctrl+C → /rite:recover が
# 発火後の再実行と誤認され、ブレーカーが一度も発火しない（失敗記録も停止通知も出ない）まま
# 上限がもう max_review_cycles 分延びる（#2026 §4.4 MUST NOT「max_review_cycles を無効化しない」）。
cb_fired=0
if [ "$cur_cc" -gt "$max_cycles" ] 2>/dev/null; then
  cb_mode_init=fresh
  cb_fired=1
fi
# reset に失敗して counter が残ったとき、ステップ 1 が即座に fire するか（上限以上なら fire）。
# 発火済みか否か（cb_fired）とは別の述語で、ステップ 6.2 の注意行の付加条件はこちらが決める
# （fresh entry に上限ちょうどの stale counter が漏れた場合も、reset 失敗すれば即再発火する）。
cb_will_refire=0
if [ "$cur_cc" -ge "$max_cycles" ] 2>/dev/null; then
  cb_will_refire=1
fi
reset_status=none
if [ "$cb_mode_init" = fresh ] && [ "$cur_cc" -gt 0 ] 2>/dev/null; then
  # stale counter を除去（--cycle-count 0 は key 自体を削除。他フィールドは merge-preserve）。
  # reset 失敗を握り潰さず WARNING を surface する（stale counter が残るとブレーカーが早期発火し
  # うるため）。非ブロッキング（iterate は止めない）。ステップ 1 の fire / ok 分岐の set と対称。
  # stderr は捨てずに退避する。捨てると flow-state.sh が原因別に出す診断（flock timeout /
  # corrupt state / write failed 等）が消え、ステップ 6.2 の停止通知が原因を推測で埋めることになる
  # （pr-review.md ステップ 6.2 / fix.md ステップ 4.5 と同型の canonical な stderr 退避パターン）。
  reset_err=$(mktemp "${TMPDIR:-/tmp}/rite-iterate-reset-err-XXXXXX" 2>/dev/null) || reset_err=""
  if bash {plugin_root}/hooks/flow-state.sh set --phase "${cur_phase:-pr}" \
    --next "review⇄fix ループ開始（cycle counter reset）" --cycle-count 0 >/dev/null 2>"${reset_err:-/dev/null}"; then
    reset_status=ok
  else
    # 即再発火（cb_will_refire=1 = counter が上限以上のまま残る）と stale leak
    # （0 < cur_cc < max_cycles）を別値に分ける。ステップ 1 で即再発火するのは前者だけであり、
    # ステップ 6.2 の注意行を後者にも付けると「review は 1 cycle も回っていません」が偽になり、
    # 真の非収束を書き込み権限の問題へ誤誘導する。
    # さらに即再発火側は **診断を捕捉できたか** で 2 値に割る。mktemp 失敗や helper が rc≠0 かつ
    # stderr 空で終わった場合は診断が 1 行も残らないため、これを同一 token にすると
    # ステップ 6.2 が「診断を確認してから再実行」と存在しない出力を探させることになる。
    if [ "$cb_will_refire" = 1 ]; then
      if [ -n "$reset_err" ] && [ -s "$reset_err" ]; then
        reset_status=failed-refire
      else
        reset_status=failed-refire-nodiag
      fi
    else
      reset_status=failed-stale
    fi
    echo "WARNING: cycle counter reset に失敗（stale counter が残りブレーカー早期発火の恐れ）" >&2
    [ -n "$reset_err" ] && [ -s "$reset_err" ] && head -5 "$reset_err" | sed 's/^/  /' >&2
  fi
  [ -n "$reset_err" ] && rm -f "$reset_err"
  cur_cc=0
fi
echo "[CONTEXT] ITERATE_CYCLE_MAX=$max_cycles; ITERATE_CYCLE=$cur_cc; ITERATE_CYCLE_MODE=$cb_mode_init; RESET=$reset_status"
```

`ITERATE_CYCLE_MAX` / `ITERATE_CYCLE` を retain してステップ 1 の上限チェックに渡す。

`RESET` は reset の実施結果で、ステップ 6 の停止通知が「即時再発火」を説明するために読む:

| `RESET` | 意味 |
|---|---|
| `none` | reset 不要だった（counter が既に 0、または resume 継続） |
| `ok` | counter を 0 にリセット済み |
| `failed-refire` | reset が失敗し counter が**上限以上**のまま残存（`cycle_count >= max_review_cycles`）。**ステップ 1 で即座にブレーカーが再発火する**。WARNING に加え flow-state.sh の診断を捕捉・表示**できた**。ステップ 6 の停止通知に注意行（診断を確認する版）を含める |
| `failed-refire-nodiag` | 同上（即再発火する）が、`reset_err` の mktemp 失敗、または helper が rc≠0 かつ stderr 空で終わったため **flow-state.sh の診断を 1 行も捕捉できなかった**。ステップ 6 の停止通知には注意行の**診断なし版**を含める（「診断を確認せよ」と案内すると存在しない出力を探させることになるため） |
| `failed-stale` | **stale counter 除去**（`0 < cycle_count < max_review_cycles`。run バッチの Issue 間リーク等）の reset が失敗し counter が残存。上限未満なので即座には再発火せず、残 cycle が目減りした状態でループが回る。ステップ 6 の停止通知に注意行は**含めない**（含めると真の非収束停止に「review は 1 cycle も回っていません」という偽の説明が付く） |

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
  # クリアして clean terminal になるのと同じ役割。
  # あわせて cycle_count に max_cycles + 1 を書き、**発火済み**を状態として記録する。上限との
  # 一致（cycle_count == max_cycles）は最終 cycle の review/fix を実行中ずっと成立する通常状態
  # でもあるため、それを「発火後」の代用にするとステップ 0.6 の override が最終 cycle 途中の
  # Ctrl+C → /rite:recover を発火後の再実行と誤認し、ブレーカーが一度も発火しないまま上限を
  # もう 1 巡分延ばす。境界値の一致ではなく到達した事実そのもので終端状態を表す。
  bash {plugin_root}/hooks/flow-state.sh set \
    --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
    --next "サーキットブレーカー発火 (cycle 上限 $max_cycles 到達)" --cycle-count "$((cc + 1))" \
    || echo "WARNING: サーキットブレーカー発火時の handoff クリア / 発火済みマーカー書込に失敗（Stop hook が /rite:pr-review を再注入しブレーカーを迂回する恐れ。マーカー未書込の場合は次回起動でステップ 0.6 が resume 判定となり即再発火する = 安全側）" >&2
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

> **発火＝失敗・マージ不可（hard invariant）**: ブレーカー発火は「review⇄fix が非収束のまま上限に達した」という**失敗の機械的記録**であり、成功・完了ではない。本ステップ以降に `/rite:merge` 相当へ到達する分岐は **batch / 対話とも存在しない**（6.1 は制御を `/rite:batch-run` に返し、run 側は `[iterate:max-cycles-reached]` を受けて ready/merge/cleanup を**スキップ**して次 Issue へ進む。6.2 は停止通知を出して終了する）。発火を成功として報告してはならない。
>
> 停止通知に記す `/rite:ready {pr_number}` は、人間が draft PR をレビューに出すために**明示的に叩く経路外のアクション**であり、本ステップの自動フローが辿る分岐ではない（かつ `/rite:ready` は Ready 化のみでマージしない）。発火から自動的にマージへ至る経路が無いという上記 invariant はこれによって崩れない。
>
> 発火後にループを再開する唯一の経路は、人間が明示的に `/rite:iterate {pr}`（または `/rite:recover`）を再実行することである。再実行時はステップ 0.6 の発火後再実行 override が cycle counter を 0 にリセットするため、即時再発火せずループが再開する。

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
| `interactive` | ステップ 6.2（機械的停止通知）|

**両分岐は挙動として同構造**（failed 記録 + draft 残し + 停止通知 + handoff クリア維持。人間への問い合わせは行わない）であり、差は次の 2 点だけである:

1. **sentinel の消費者**: `[iterate:max-cycles-reached]` は `/rite:batch-run` が grep して当該 Issue を `failed[]` に記録し次 Issue へ進むために消費する。`[iterate:max-cycles-stopped]` は消費者を持たない iterate 内部完結の最終状態表示。
2. **`RESET=failed-refire*` 注意行の有無**: ステップ 6.2（対話）のみが持つ。6.1（batch）は Issue #2026 §4.2 の Non-Target（MUST NOT modify）のため本スキルでは対称化しない。結果として batch では、前 Issue から漏れた stale counter の reset に失敗した場合、review を 1 cycle も回していない Issue が `failed[]` に「上限到達（非収束）」として記録されうる。対称化は別 Issue で扱う。

どちらの経路もマージには到達しない（上記 invariant）。

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

### ステップ 6.2: 対話実行 — 機械的停止通知を出力

`AskUserQuestion` は**使わない**。当該 PR を非収束（failed）として機械的に記録し、draft/open PR をレビュー待ちで残して停止する。6.1（batch）と同構造であり、品質ゲートの履行を人間の裁量に委ねない（発火は失敗であって、人間に選ばせて counter をリセットし続行できる例外を作らない）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない。

下記の停止通知を出力してループを終了する（`{max_review_cycles}` 等はリテラル置換する）:

```
## /rite:iterate サーキットブレーカー発火（対話・停止）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: review⇄fix cycle が上限 {max_review_cycles} に到達（非収束）
- 措置: 当該 PR を非収束として失敗記録し、draft/open PR をレビュー待ちで残します（マージには進みません）

再開方法:
- ループを再開する: /rite:iterate {pr_number} を明示的に再実行する（cycle counter がリセットされ、
  もう {max_review_cycles} cycle 回る）。/rite:recover 経由の再開も同じ経路
- Ready 化して人間のレビューに委ねる: /rite:ready {pr_number}

<!-- [iterate:max-cycles-stopped] -->
```

ステップ 0.6 の `[CONTEXT] ... RESET=` を context で観測している場合、値に応じて上記「理由」行の直後に次の 1 行を追加する（§4.5 の error handling。同じ文面の停止通知が真の非収束と区別できなくなるのを防ぐ）。`RESET=failed-stale`（上限未満での reset 失敗）と `ok` / `none` では review が実際に回ってから到達しているため**追加しない**。値の照合は完全一致で行うこと（`failed` の部分一致は 3 値すべてに当たる）:

`RESET=failed-refire` のとき（診断を捕捉できている）:

```
- 注意: cycle counter のリセットに失敗し上限値のまま即時再発火しました（review は 1 cycle も回っていません）。ステップ 0.6 の WARNING 直後に出力された flow-state.sh の診断（flock timeout / corrupt state / write failed 等）を確認してから再実行してください
```

`RESET=failed-refire-nodiag` のとき（診断を捕捉できていない）:

```
- 注意: cycle counter のリセットに失敗し上限値のまま即時再発火しました（review は 1 cycle も回っていません）。flow-state.sh の診断は退避に失敗したため取得できていません。$TMPDIR の空き容量・書込権限と flow-state ファイルの状態を確認してから再実行してください
```

---

## エラー時の方針

- ユーザーが Ctrl+C で中断した場合: flow-state に現 phase (review or fix) が残るので `/rite:recover` で本コマンドが再起動する (詳細な phase → command routing は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 5.3 を参照)
- `[fix:error]` 時: 自動継続せず必ず AskUserQuestion で確認 (silent regression 防止)
- reviewer が non-deterministic に振動 (毎 cycle で別の指摘) する場合: `safety.max_review_cycles`（既定 5）到達でサーキットブレーカーが発火する（ステップ 6）。batch / 対話とも人間に問わず機械的に停止し（発火＝失敗の記録）、`/rite:batch-run` バッチ実行は `[iterate:max-cycles-reached]` を emit して当該 Issue を failed 扱いにし次 Issue へ進み、対話実行は `[iterate:max-cycles-stopped]` の停止通知で終了する。再開は人間による `/rite:iterate {pr}` の明示的な再実行のみ。Ctrl+C による手動中断も従来どおり可能

---

## ループ継続・終了の構造的保証

継続点・終了点で sub-skill が one-shot handoff (`/rite:...` / `FINALIZE:{result}:{pr}`) を flow-state にセットし、turn 早期終了時は Stop hook (`stop-loop-continuation.sh`) が consume + prefix 分岐で停止を差し戻す。`[fix:error]` とサーキットブレーカー fire 分岐は handoff を持たない/能動クリアする (Stop hook は停止を許可)。機構の全体解説・sentinel → handoff 対応表・無限 block 防止の設計:
rationale: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism)

## 設計判断

- **blocking 指摘ゼロ（mergeable）到達が正常出口** — blocking の定義式は本ファイルに複製せず [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) を SoT とする（同 § は reviewer finding に閉じた canonical 式と fix loop 全体を対象とする consumer 式の差を「適用範囲」で意図的なスコープ差として定義している。本スキルはループ側なので後者に従い、実測の有無を判定できない指摘は blocking のまま扱う）。実測を伴わない指摘は non-blocking として `/rite:pr-review` ステップ 6.1.d の PR 記録コメント・ステップ 5.4 統合レポート・永続 JSON に記録されたまま残存するため、**非実測指摘が N 件残った状態でも `[review:mergeable]` に到達してループが正常終了しうる**（#2024）— 残存分は draft PR の人間レビューに委ねる設計。加えて `safety.max_review_cycles`（既定 5）到達で発火するサーキットブレーカーを唯一の自動安全網として持つ（#1701）。reviewer の非決定的振動や非収束 PR による無限ループを構造的に防ぐ。同一 finding 検出 / quality signal escalation といった細粒度の安全網は依然として持たず、cycle 上限のみに絞る（CLAUDE.md「シンプルさを死守」）
- **発火＝失敗の機械的記録（batch / 対話で同一）**: 上限到達時は両モードとも人間に問わず停止する（#2026）。導入時（#1701）は対話モードの UX として AskUserQuestion（継続 / 中止 / draft のまま停止）を残していたが、人間の裁量で counter をリセットして続行できる経路は「品質ゲートを機械的に履行する」方針に対する例外であり、人間エスカレーションは責任転嫁で終端にならない。継続は人間が明示的に `/rite:iterate {pr}` を再実行する経路のみに絞り、そのときステップ 0.6 の発火後再実行 override が counter をリセットする。`/rite:batch-run` バッチ実行は従来どおり failed 扱いで次 Issue へ自動遷移する（バッチ全体のストール防止）
- **cycle counter は flow-state に保持**: 専用 state file (`.rite/state/*.count` 等) は持たず、`cycle_count` を flow-state の merge-preserve フィールドとして永続化する（`worktree` と同じ additive パターン）。resume を跨いで継続し（AC-3）、fresh entry（phase が review/fix 以外）で 0 リセットして run バッチの Issue 間リークを防ぐ。加えて発火時は fire 分岐が `cycle_count = max_review_cycles + 1` を書いて**発火済み**を状態として記録し、次回起動でステップ 0.6 の override が phase に依らず 0 リセットする（発火後再実行 override）— ブレーカー発火後は継続 handoff が default-clear されて自動再入場の経路が無くなるため、この状態で iterate が動いているのは人間が明示的に再実行したときだけであり、リセットしないと再実行が即再発火してループを再開する術が無くなる。判定に上限との一致（`>=`）を使わないのは、`cycle_count == max_review_cycles` が最終 cycle の実行中ずっと成立する通常状態でもあり、そこでの中断からの resume を発火後と誤認すると、ブレーカーが一度も発火しないまま上限が無通知で 2 巡分に緩むため（#2026）。Stop hook の handoff とは独立（handoff は one-shot consume される継続マーカー、cycle_count は accumulate されるカウンタ）
- 別 Issue 化経路は廃止済み (commit 1a で fix.md Phase 4.3 削除) — 「別 Issue にスキップして loop 終了」の抜け穴は塞がれている
