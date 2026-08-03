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

`/rite:pr-review` ↔ `/rite:fix` を **blocking 指摘ゼロ（mergeable）になるまでループ** する（blocking の定義は [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) が SoT。実測なし（`measured=false`）と判定された指摘は non-blocking として記録されたまま残存し、その状態で正常出口に到達しうる）。ただし **サーキットブレーカー** を備え、reviewer の非決定的な振動や非収束 PR による無限ループを構造的に防ぐ。やることは以下のシーケンシャルなタスク列:

0. flow-state から issue_number / branch_name を復元
0.6. cycle counter を初期化（fresh は 0 にリセット / resume は継続）+ `safety.max_review_cycles` を読込・検証
1. 発火条件チェック（収束トレンドの発散 / `max_review_cycles` 到達）→ 不成立なら counter を +1 して `/rite:pr-review` を invoke / 成立なら サーキットブレーカー（ステップ 6）へ
2. review sentinel を判定（`[review:mergeable]` → 終了 / `[review:fix-needed:N]` → ステップ 3 / その他 → AskUserQuestion）
3. `/rite:fix` を invoke
4. fix sentinel を判定（`[fix:pushed]` → ステップ 1 に戻る / `[fix:replied-only]` `[fix:cancelled-by-user]` → 終了 / `[fix:error]` → AskUserQuestion）
5. 完了通知を出す
6. （発火時のみ）サーキットブレーカー: batch / 対話とも人間に問わず機械的に停止する。バッチ実行（`/rite:batch-run`）は `[iterate:max-cycles-reached]` を emit して当該 Issue を failed 扱いにさせ、対話実行は `[iterate:max-cycles-stopped]` の停止通知を出して終了する

**サーキットブレーカーの発火条件は 2 つ**:

- **収束トレンドの発散**（主経路）: 永続レビュー JSON の per-cycle blocking 件数から `hooks/scripts/review-trend-divergence.sh` が発散を機械判定する。「直近 2 値がともに過去の最良水準を超え、かつ下降中でもない」を発散とし、健全に収束中のループは cycle 数に縛られず走り切れる。判定式の較正根拠（直近 5 PR の実トラジェクトリによる backtest）は helper の header が SoT
- **`safety.max_review_cycles`（既定 5）到達**（保険）: 発散判定をすり抜ける遅い非収束（漸減が続くが 0 に達しない、最良水準での平坦等）を受け止める遠い backstop。**滅多に発火しない純粋な保険**であり、収束中のループを予算で殺すための上限ではない

> **Why**: cycle 数上限は努力と無駄を区別できない — 健全に収束中のループも残り数件のところで予算切れになり、発散しているループも上限まで燃やしてしまう（どちらも実運用で観測済み）。「品質を予算で縛らない・無駄は排除する」（CLAUDE.md プロジェクト原則）に従い、切るのは発散であって収束に向かう実サイクルではない。

**発火＝失敗の機械的記録**であり、**発火理由に依らず** batch / 対話とも同構造（failed 記録 + draft 残し + 停止通知 + handoff クリア維持。ただし failed 記録が外部に永続するのは batch のみ — 対話側は消費者を持たない sentinel が出るだけで、reset 後の state は fresh な review と区別できない。ステップ 6 参照）で停止する — 人間に継続可否を問う経路は持たず、発火からマージへ到達する分岐も存在しない。`/rite:batch-run` バッチ実行では当該 Issue を failed 扱いにする sentinel を emit して次 Issue へ進ませる（バッチ全体のストール防止）。ループを再開する唯一の経路は人間が明示的に `/rite:iterate {pr}`（または `/rite:recover`）を再実行することである。cycle_count は flow-state に永続化され resume を跨いで継続する（AC-3）。**counter のリセットは発火が sentinel として記録される直前（ステップ 6 の共有前段）で行う** — 発火後の再実行はステップ 0.6 で何もしなくても cycle 1 から再開する（発火済みを別マーカーとして覚えない）。ステップ 1 の fire 分岐で先にリセットしない理由は、発火が無記録のまま counter だけ 0 になる窓を狭めるため（その状態から `/rite:recover` すると満額の cycle 予算でループが再開してしまう）。**窓は消えていない** — 共有前段の実行後・sentinel 出力前に turn が終わればこの組み合わせは成立する。fire 分岐に置くより窓が狭いだけで、構造的な閉塞は別 Issue（sentinel 出力を強制する handoff 機構が必要で、それは Non-Target の Stop hook 改修を伴う）。最終 cycle の実行中は `cycle_count == max_review_cycles` が通常状態として成立するが、そこでの中断からの resume は fire 分岐を通らないため counter が上限のまま残り、ステップ 1 で正しく発火する。それ以外の中断経路は 2 種類: (a) ユーザーが fix.md 内 AskUserQuestion で「中止」を選択 → `[fix:cancelled-by-user]` emit + ループ終了、(b) ユーザーが Ctrl+C で中断 → flow-state phase 残存。どちらも `/rite:recover` で再開可。

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
| `{max_review_cycles}` | `safety.max_review_cycles` in `rite-config.yml`（既定 5、無効値は既定へフォールバック）。**発散判定をすり抜けた非収束を受け止める backstop** であり、収束中のループを止める上限ではない |
| `{fire_reason_line}` | ステップ 6.1 / 6.2 の「理由」行。ステップ 1 の `[CONTEXT] ITERATE_CB=fire` marker の `CB_REASON=` から ステップ 6.2「発火理由の文面」表で決める |
| `{trend}` | ステップ 1 の `[CONTEXT] ITERATE_CB=fire` marker の `TREND=`（カンマ区切りの per-cycle blocking 件数）。停止通知では `→` 区切りへ整形して表示する。空のときの扱いは ステップ 6.2「発火理由の文面」を参照 |
| `{cycle_count}` | flow-state `cycle_count` field（review⇄fix cycle の消化数。ステップ 1 で increment、fresh entry で 0 リセット。発火時はステップ 6 の共有前段が 0 にリセットする） |
| `{state_root}` | ステップ 6 共有前段の `[CONTEXT] STATE_ROOT=` marker の値（`hooks/state-path-resolve.sh` の解決結果。未解決時は sentinel `unresolved`）。ステップ 6.2 注意行 (b) の手動リセットコマンドでのみ使い、値が得られないときは同節の pre-fill 表に従って解決手順へ置き換える |
| `{session_id}` | ステップ 6 共有前段の `[CONTEXT] SESSION_ID=` marker の値（`flow-state.sh path` の basename）。用途と未解決時の扱いは `{state_root}` と同じ |
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
# (0) 診断スニペット用 helper を読み込む。SoT は control-char-neutralize.sh の header
# （`head -N ... | neutralize_ctrl --keep-newline | sed ... >&2` が全 emission site の canonical idiom）。
# capture 側の helper 呼び出しには `LC_ALL=C` を付ける（本ブロック / ステップ 1 / ステップ 6 共有前段の
# 4 サイト共通）。neutralize_ctrl は 0x80-0x9f を**バイト単位**で `?` に潰すため、mktemp / mv / flock 等
# 外部コマンドがロケール依存の多バイト診断を返すと原因語ごと判読不能になる。flow-state.sh が rc だけを
# 返し外部コマンドの stderr が唯一の原因行になる経路（`_atomic_write` の mktemp / mv 失敗）では、
# capture を導入した目的そのもの——停止通知が原因を推測で埋めないこと——が失われる。
# 未定義のまま pipe すると診断本文ごと消えるため不在時は素通しへ縮退させるが、**縮退は必ず
# WARNING で告知する**（無言で縮退させると、この helper を通す目的である「制御文字の素通し」が
# 無通知で復活し、本ブロックが reset_out の stderr を捨てずに capture している理由と矛盾する）。
# source の stderr も抑止しない（抑止すると helper 不在の原因が消える）。
source {plugin_root}/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi

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
#     発火時はステップ 6 の共有前段が counter を 0 にリセットするため、発火後の再実行は本ステップで
#     何もしなくても cycle 1 から再開する（発火済みを覚えておく必要がない = override を持たない）。
cur_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || cur_phase=""
cur_cc=$(bash {plugin_root}/hooks/flow-state.sh get --field cycle_count --default 0) || cur_cc=0
case "$cur_cc" in ''|*[!0-9]*) cur_cc=0 ;; esac   # 読めない / 不正なら 0 から（安全側: 既定上限で必ず止まる）
case "$cur_phase" in
  review|fix) cb_mode_init=resume ;;
  *)          cb_mode_init=fresh ;;
esac
# **この起動でステップ 1 が review を回さずに fire するか**（上限以上なら fire）。ステップ 6.2 の
# 注意行 (a) の付加条件をこの述語が決める。ここでは reset 試行**前**の値で暫定的に立て、
# reset に成功したら下の分岐で 0 に落とす（実効 counter に合わせる）。
cb_will_refire=0
if [ "$cur_cc" -ge "$max_cycles" ] 2>/dev/null; then
  cb_will_refire=1
fi
reset_status=none
if [ "$cb_mode_init" = fresh ] && [ "$cur_cc" -gt 0 ] 2>/dev/null; then
  # stale counter を除去（--cycle-count 0 は key 自体を削除。他フィールドは merge-preserve）。
  # reset 失敗を握り潰さず WARNING を surface する（stale counter が残るとブレーカーが早期発火し
  # うるため）。非ブロッキング（iterate は止めない）。ステップ 1 の fire / ok 分岐の set と対称。
  # stderr は捨てずに変数へ受ける。捨てると flow-state.sh が原因別に出す診断（flock timeout /
  # corrupt state / write failed 等）が消え、ステップ 6.2 の停止通知が原因を推測で埋めることになる。
  # tempfile ではなく `2>&1` capture を使うのは、tempfile 方式では mktemp 自体が失敗したときに
  # 診断の退避先を失って結局捨てることになるため（helper は成功時 stdout に何も出さないので
  # stdout の混入は無害）。
  if reset_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set --phase "${cur_phase:-pr}" \
    --next "review⇄fix ループ開始（cycle counter reset）" --cycle-count 0 2>&1); then
    reset_status=ok
    # reset 成功 = 起動時の stale counter は消えた。ステップ 1 は即 fire しないので述語を落とし、
    # marker に載せる counter も実効値（0）へ揃える
    # （cb_will_refire は reset 試行**前**の cur_cc で立つため、ここで再評価しないと
    #   「counter は 0 に戻ったのに REFIRE=1」という自己矛盾した marker が出る）。
    cb_will_refire=0
    cur_cc=0
  else
    # 即再発火（cb_will_refire=1 = counter が上限以上のまま残る）と stale leak
    # （0 < cur_cc < max_cycles）を別値に分ける。**停止通知の注意行の条件は REFIRE であって
    # 本値ではない**（下の RESET 表を参照）。分割の目的は、reset 失敗時に残った counter が
    # 上限以上か未満か——すなわち即再発火するのか残 cycle が目減りするだけなのか——を、
    # 人間が診断値だけで切り分けられるようにすることにある。
    if [ "$cb_will_refire" = 1 ]; then reset_status=failed-refire; else reset_status=failed-stale; fi
    echo "WARNING: cycle counter reset に失敗（stale counter が残りブレーカー早期発火の恐れ）" >&2
    # ここでは cur_cc を 0 に落とさない。永続 counter は元の値のまま残っているため、marker の
    # ITERATE_CYCLE を 0 にすると `ITERATE_CYCLE=0; RESET=failed-refire; REFIRE=1` のように
    # 「counter は 0 なのに review を回さず発火する」という自己矛盾した観測値になる（成功側で
    # cb_will_refire を再評価しているのと同じ理由の鏡像）。本ブロック直後の散文が ITERATE_CYCLE を
    # 「ステップ 1 の上限チェックに渡す値」と規定している以上、実効 counter と一致させる。
  fi
  # 診断の表示は rc に紐付けない。flow-state.sh は破損 state をデフォルト値でマージ書き込みする等、
  # **rc=0 のまま WARNING を出す経路**を持つため、rc!=0 のときだけ表示すると capture 導入前
  # （無リダイレクト）より観測性が落ちる。成功時の capture は空なので下の -n guard が
  # ノイズを抑止する。neutralize_ctrl は hooks/ の canonical 診断スニペット idiom（SoT:
  # control-char-neutralize.sh header）。素の pipe だと helper stderr の制御文字が端末に素通しする。
  [ -n "$reset_out" ] && printf '%s\n' "$reset_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
fi
echo "[CONTEXT] ITERATE_CYCLE_MAX=$max_cycles; ITERATE_CYCLE=$cur_cc; ITERATE_CYCLE_MODE=$cb_mode_init; RESET=$reset_status; REFIRE=$cb_will_refire"
```

`ITERATE_CYCLE_MAX` / `ITERATE_CYCLE` を retain してステップ 1 の上限チェックに渡す。

`RESET` は reset を**試行した場合**の結果記録で、人間が失敗原因を追うための診断値。**停止通知の注意行の条件には使わない**（条件はステップ 0.6 の `REFIRE` とステップ 6 共有前段の `FIRE_RESET`）:

| `RESET` | 意味 |
|---|---|
| `none` | reset 不要だった（counter が既に 0、または resume 継続） |
| `ok` | counter を 0 にリセット済み |
| `failed-refire` | reset が失敗し counter が**上限以上**のまま残存（`cycle_count >= max_review_cycles`）。ステップ 1 で即座にブレーカーが再発火する。WARNING と flow-state.sh の診断（helper が出力していれば）は emit 済み。停止通知の注意行は本値ではなく **`REFIRE=1`** が条件（reset を試行しない resume 経路でも即再発火しうるため） |
| `failed-stale` | **stale counter 除去**（`0 < cycle_count < max_review_cycles`。run バッチの Issue 間リーク等）の reset が失敗し counter が残存。上限未満なので即座には再発火せず、残 cycle が目減りした状態でループが回る。ステップ 6 の停止通知に注意行は**含めない**（含めると真の非収束停止に「review は 1 cycle も回っていません」という偽の説明が付く） |

`REFIRE` は**この起動でステップ 1 が review を回さずに fire するか**の述語で、ステップ 6.2 の注意行 (a) の条件そのもの:

| `REFIRE` | 意味 |
|---|---|
| `0` | 起動時点の counter が上限未満、または reset に成功して 0 に戻った。ステップ 1 は review を回してから進む |
| `1` | counter が上限以上のまま残っている。**ステップ 1 はこの起動で review を 1 回も回さずに fire する**（前回の最終 cycle 途中での中断からの正常な発火と、counter リセット失敗による再発火の両方を含む） |

---

## ステップ 1: 発火条件チェック → /rite:pr-review を invoke

ループ頭でサーキットブレーカーの **2 つの発火条件** を評価する。**どちらも不成立なら** counter を +1 して `phase=review` に更新後 `/rite:pr-review` を invoke、**いずれかが成立したら** サーキットブレーカー（ステップ 6）へ分岐する:

1. **収束トレンドの発散**（主経路）— `hooks/scripts/review-trend-divergence.sh` が永続レビュー JSON から現 run の per-cycle blocking 列を復元し発散と判定した場合。`cycle_count` が上限未満でも発火する
2. **`max_review_cycles` 到達**（保険）— 発散判定をすり抜けた遅い非収束を受け止める遠い backstop

`max_review_cycles` は marker 依存を避けるため config から silent 再読込する（検証・WARNING はステップ 0.6 で実施済）:

```bash
# 診断スニペット用 helper（ステップ 0.6 (0) と同型 — 縮退時の WARNING 告知まで含めて同じ。
# Bash tool 呼び出し間でシェル状態は引き継がれないため、fire_out を表示する本ブロックでも
# 独立に読み込む）。
source {plugin_root}/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi

cc=$(bash {plugin_root}/hooks/flow-state.sh get --field cycle_count --default 0) || cc=0
case "$cc" in ''|*[!0-9]*) cc=0 ;; esac
raw_max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$raw_max" in ''|0|*[!0-9]*) max_cycles=5 ;; *) max_cycles=$raw_max ;; esac  # 検証済。ここは silent fallback

# 収束トレンド判定。永続レビュー JSON から現 run の per-cycle blocking 列を復元し、
# 発散していれば cycle 上限未到達でも発火させる。判定は helper に閉じており、LLM は verdict を
# 読むだけで数え上げを行わない（AC-5）。
# stderr は捨てずに素通しする（helper の WARNING は「なぜ判定できなかったか」の唯一の記録で、
# 捨てると判定不能が silent skip と区別できなくなる）。
trend_out=$(bash {plugin_root}/hooks/scripts/review-trend-divergence.sh \
  --pr {pr_number} --cycle-count "$cc"); trend_rc=$?
trend_verdict=$(printf '%s\n' "$trend_out" | sed -n 's/.*TREND_DIVERGENCE=\([a-z_]*\).*/\1/p' | tail -1)
trend_series=$(printf '%s\n' "$trend_out" | sed -n 's/.*[;[:space:]]trend=\([^;]*\).*/\1/p' | tail -1)
if [ "$trend_rc" -ne 0 ] || [ -z "$trend_verdict" ]; then
  # rc=2（引数不正 / jq 不在）や helper 不在（marketplace 版とローカル版の skew 等）。
  # 判定できないまま黙って通すと「発散検出が働いていない」ことが観測不能になるため loud にする。
  # 帰結は max_review_cycles による従来判定への縮退で、ループが止まらなくなるわけではない。
  echo "WARNING: 収束トレンド判定を実行できませんでした（rc=$trend_rc）。cycle 上限のみで判定します" >&2
  trend_verdict=unavailable
fi

# 発火理由を決める。**cycle 上限を先に評価する** — 両方成立しているとき、上限到達は
# 従来からの契約（AC-3 の保険）であり、そちらを理由として報告するほうが挙動の説明として正確。
cb_reason=""
if [ "$cc" -ge "$max_cycles" ] 2>/dev/null; then
  cb_reason=max-cycles
elif [ "$trend_verdict" = fire ]; then
  cb_reason=divergence
fi

if [ -n "$cb_reason" ]; then
  # 直前の [fix:pushed] が fix.md ステップ5.1 で set した継続 handoff (`/rite:pr-review {pr}`) を
  # default-clear する（`--handoff` を伴わない set は handoff を消す）。これをしないと、fire 後に
  # turn が終わったとき stop-loop-continuation.sh が残存 handoff を consume して `/rite:pr-review` を
  # 再注入し、サーキットブレーカーを無視してループが継続する。`[fix:error]` が set で handoff を
  # クリアして clean terminal になるのと同じ役割。
  # **counter はここではリセットしない**。リセットは発火が sentinel として記録される直前
  # （ステップ 6 の共有前段）まで遅らせる。ここで 0 に戻すと、6.1 / 6.2 が sentinel を emit する
  # 前に turn が終わった場合、発火の記録がどこにも残らないまま counter だけが 0 になり、同じ set が
  # handoff も消しているので Stop hook は停止を許可する。その後 /rite:recover は phase=review を
  # そのまま iterate へ routing するため、発火が 1 度も報告されないまま満額 max_review_cycles で
  # ループが再開する（＝ブレーカーの無効化）。counter を上限のまま残せば、その窓で中断しても
  # 次回ループ頭で必ず再発火する — 縮退が「停止側」に倒れる。
  # set の成否は HANDOFF_CLEAR marker に載せる（counter reset の成否は別軸で、ステップ 6 の
  # 共有前段が FIRE_RESET として emit する）。stderr は捨てずに変数へ受けて表示する。
  case "$cb_reason" in
    divergence) fire_desc="収束トレンドの発散を検出 (推移 $trend_series)" ;;
    *)          fire_desc="cycle 上限 $max_cycles 到達" ;;
  esac
  if fire_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set \
    --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
    --next "サーキットブレーカー発火 ($fire_desc)" 2>&1); then
    handoff_clear=ok
  else
    handoff_clear=failed
    echo "WARNING: サーキットブレーカー発火時の handoff クリアに失敗（handoff が残り Stop hook が /rite:pr-review を再注入してブレーカーを迂回する恐れ）" >&2
  fi
  # 診断の表示は rc に紐付けない（ステップ 0.6 の reset と同型）。flow-state.sh は rc=0 のまま
  # WARNING を出す経路を持つため、rc!=0 のときだけ表示するとブレーカー発火という最後の安全網の
  # 経路で診断が消える。neutralize_ctrl も同型（本ブロック冒頭で読み込み済み）。
  [ -n "$fire_out" ] && printf '%s\n' "$fire_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  # CB_REASON / TREND はステップ 6.2 の停止通知が「理由」行とトレンド推移の表示に使う（AC-4）。
  # ステップ 6 は別の Bash 呼び出しでシェル変数を引き継げないため marker で渡す。
  echo "[CONTEXT] ITERATE_CB=fire; cycle=$cc; max=$max_cycles; CB_REASON=$cb_reason; TREND=$trend_series; HANDOFF_CLEAR=$handoff_clear"
else
  new_cc=$((cc + 1))
  # counter increment（ブレーカーを前進させる主経路）の set も fail-observable にする。silent に
  # 失敗すると cycle_count が increment されず counter が stuck → ブレーカーが永久に発火せず
  # 無限ループ化する（fire 分岐の handoff クリア失敗と同種の「ブレーカー無効化」方向）。非ブロッキング。
  # 失敗時は marker に載せる値も前進させない（ステップ 0.6 の reset 分岐と同じ invariant —
  # marker の counter は常に実効（永続）counter と一致させる）。前進させると、永続 counter は
  # 据え置きなのに marker だけが毎 cycle 進み、観測者は counter 停滞と marker ずれを切り分け
  # られなくなる。
  if inc_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set \
    --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
    --next "review 実行中 (cycle $new_cc/$max_cycles)" --cycle-count "$new_cc" 2>&1); then
    inc_status=ok
  else
    inc_status=failed
    echo "WARNING: cycle counter increment に失敗（counter 未前進でブレーカーが発火せず無限ループ化の恐れ）" >&2
    new_cc=$cc
  fi
  # 表示は fire 分岐と同一形（毎 cycle 通る最頻経路なので、ここだけ中和を欠くと corrupt state
  # 診断の制御文字が最も高い頻度で端末へ素通しする）。
  [ -n "$inc_out" ] && printf '%s\n' "$inc_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "[CONTEXT] ITERATE_CB=ok; cycle=$new_cc; max=$max_cycles; TREND=$trend_series; TREND_VERDICT=$trend_verdict; INC=$inc_status"
fi
```

| `ITERATE_CB` marker | アクション |
|---------|-----------|
| `ok` | 発火条件のいずれにも該当せず。counter を +1 済。`/rite:pr-review` を invoke（下記）してステップ 2 へ |
| `fire` | 発火（`CB_REASON` に理由）。**review を invoke せず** サーキットブレーカー（ステップ 6）へ直行（mergeable 判定済 PR には発火しない = ステップ 2 で先に `[review:mergeable]` 終了するため到達しない） |

`CB_REASON` は発火理由で、ステップ 6.2 の停止通知の「理由」行を決める（sentinel 自体は理由に依らず不変 — ステップ 6 参照）:

| `CB_REASON` | 意味 |
|---|---|
| `divergence` | 収束トレンドが発散と判定された（`cycle_count < max_review_cycles` でも発火する）。無駄な cycle を早期に切る主経路 |
| `max-cycles` | `cycle_count >= max_review_cycles`。発散判定をすり抜けた遅い非収束を受け止める保険（両方成立する場合もこちらを理由として報告する） |

`TREND_VERDICT`（`ok` 分岐にのみ載る）はトレンド判定が下せたかの診断値。`ok`（収束中・下降中）/ `insufficient`（データ不足・データ異常で判定不能。理由は helper の stderr WARNING）/ `unavailable`（helper 自体を実行できなかった）を取る。`insufficient` / `unavailable` は発火しない側へ倒れ、`max_review_cycles` が従来どおり backstop として働く。

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

## ステップ 6: サーキットブレーカー（発火時のみ）

> **発火＝失敗・マージ不可（hard invariant）**: ブレーカー発火は「review⇄fix が非収束のまま上限に達した」という**失敗の機械的記録**であり、成功・完了ではない。本ステップ以降に `/rite:merge` 相当へ到達する分岐は **batch / 対話とも存在しない**（6.1 は制御を `/rite:batch-run` に返し、run 側は `[iterate:max-cycles-reached]` を受けて ready/merge/cleanup を**スキップ**して次 Issue へ進む。6.2 は停止通知を出して終了する）。発火を成功として報告してはならない。
>
> 停止通知に記す `/rite:ready {pr_number}` は、人間が draft PR をレビューに出すために**明示的に叩く経路外のアクション**であり、本ステップの自動フローが辿る分岐ではない（かつ `/rite:ready` は Ready 化のみでマージしない）。発火から自動的にマージへ至る経路が無いという上記 invariant はこれによって崩れない。
>
> 発火後にループを再開する唯一の経路は、人間が明示的に `/rite:iterate {pr}`（または `/rite:recover`）を再実行することである。counter は**ステップ 6 の共有前段**（発火が 6.1 / 6.2 の sentinel として記録される直前）でリセットするため、**その set が成功していれば**（`FIRE_RESET=ok`）再実行は即時再発火せず cycle 1 から再開する。失敗時（`FIRE_RESET=failed`）は counter が上限のまま残るため即再発火し、ステップ 6.2 が注意行と手動リセット手順を出す。共有前段に到達する前に turn が終わった場合は counter が上限のまま残るため、次回ループ頭で再発火する。ただし**共有前段の実行後・sentinel 出力前**の窓は残存し、そこで turn が終わると発火が無記録のまま予算が復活する（fire 分岐に reset を置く場合より窓は狭いが、消えてはいない）。

ステップ 1 で `ITERATE_CB=fire`（収束トレンドの発散 or `cycle_count >= max_review_cycles`。理由は同 marker の `CB_REASON`）となったときのみ到達する。**発火理由は本ステップの停止構造を変えない** — 変わるのは 6.1 / 6.2 の「理由」行の文面と、そこに併記するトレンド推移だけである（sentinel・handoff 契約・counter reset はいずれも不変）。まず batch 実行（`/rite:batch-run` 経由）か対話実行かを **自セッションの** run-queue（`run-queue-{session_id}.json`）から判定する。`/rite:batch-run` は駆動中に `active=true` を立て、cursor が処理中 Issue を指す。iterate は batch-run から**同一セッションで invoke される**ため、driving 中なら本 iterate の ambient session_id と run-queue の session_id は一致し、自セッションのキューだけを参照する（他セッションのキューは別ファイルのため構造的に読まない、Issue #1859 AC-2）。よって **`active == true` かつ** cursor の Issue が本 iterate の対象と一致すれば batch と判定する（`active` 条件は、停止済み dormant キューが cursor 一致だけで active batch と誤判定されるのを防ぐ。read-only 参照。`{issue_number}` はステップ 0 の marker 値をリテラル置換）:

```bash
# 診断スニペット用 helper（ステップ 0.6 (0) と同型 — 縮退時の WARNING 告知まで含めて同じ）。
source {plugin_root}/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi

state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
# 空値を sentinel に置き換える。rc 検査では救えない（resolver は cwd 削除時にも rc=0 で空文字を返す）。
# 空のまま marker に載せると、ステップ 6.2 の (b) が提示する `RITE_STATE_ROOT=` が flow-state.sh の
# `[ -n "${RITE_STATE_ROOT:-}" ]` 判定で「未設定」と**完全に同義**へ縮退し、(b) 自身が「省くと空振りする」
# と警告している当の空振りを、省いていないのに無言で起こす。しかも `flow-state.sh path` は state_root が
# 空でも rc=0 を返すため session_id は非空のまま残る（2 軸は独立）。sentinel にしておけば 6.2 の
# pre-fill 表が ROOT 側だけを解決手順へ置き換え、判明している session_id は保ったまま渡せる。
if [ -z "$state_root" ]; then
  echo "WARNING: state root を解決できませんでした（手動リセット手順が別ディレクトリを rc=0 のまま対象にする恐れがあるため、ステップ 6.2 は state root を埋め込んだコマンドではなく、人間が自分で state root を解決する代替手順に切り替えます）" >&2
  state_root=unresolved
fi
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
# cycle counter のリセット。**ステップ 1 の fire 分岐ではなくここで行う** — 直後の 6.1 / 6.2 が
# sentinel を emit するため、ここまで到達していれば発火は記録される。ここより手前で turn が
# 終わった場合は counter が上限のまま残り、次回ループ頭で再発火する（縮退が「停止側」に倒れる）。
# リセットしないと再実行が即再発火してループを再開する術が無くなるが、発火済みを別マーカーとして
# 覚えさせる設計は採らない（「発火したか」を上限値との相対比較で符号化することになり、
# max_review_cycles が invocation 間で変わると符号化が両方向に破綻する）。
# `--handoff` を伴わないため、ステップ 1 fire 分岐が消した handoff はクリアされたまま維持される。
# 成否は FIRE_RESET marker に載せる。失敗すると counter が上限のまま残り再実行が即再発火する
# （= 停止通知が約束する「再実行すればもう N cycle 回る」が偽になる）ため、ステップ 6.2 が
# これを読んで注意行 (b) を出し分ける。
if cb_reset_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set \
  --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "サーキットブレーカー発火 (counter reset 済。理由はステップ 1 の CB_REASON)" --cycle-count 0 2>&1); then
  fire_reset=ok
else
  fire_reset=failed
  echo "WARNING: サーキットブレーカー発火時の cycle counter リセットに失敗（counter が上限のまま残り、再実行しても即再発火する）" >&2
fi
# 診断の表示は rc に紐付けない（ステップ 0.6 / ステップ 1 の capture と同型）。
[ -n "$cb_reset_out" ] && printf '%s\n' "$cb_reset_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
# session_id を marker に載せる。ステップ 6.2 の注意行 (b) が人間へ提示する手動リセットコマンドは
# **`--session` を明示しないと別セッションの state を対象にしうる** — flow-state.sh の解決順は
# override → CLAUDE_CODE_SESSION_ID → CLAUDE_SESSION_ID → `.rite-session-id` で、agent の Bash tool は
# env var 経路、人間の端末は env 不在で `.rite-session-id` 経路になる。さらに session-start.sh は
# CLAUDE_CODE_SESSION_ID がある間 `.rite-session-id` を書かないため、Claude Code 配下では両者の
# 不一致が定常状態である。--session 無しのコマンドは rc=0 で「成功」しながら別 sid の state を
# 新規作成し、上限のまま止まっている当の counter は手つかずで残る。
# state_root も同じ理由で marker に載せる。sid を --session で固定しても、state root は
# `resolve_state_root` が cwd へフォールバックするため、人間が repo 外の cwd（marketplace install では
# コマンド文字列にプロジェクト参照が無く、新規端末の既定 cwd は $HOME = 非 git）で実行すると
# rc=0 のまま $cwd/.rite/sessions/ に別ファイルを作り、当の counter はやはり手つかずで残る。
# 2 軸のうち片方だけを塞いでも空振りは塞げない。
echo "[CONTEXT] ITERATE_CB_MODE=$cb_mode; issue={issue_number}; pr={pr_number}; FIRE_RESET=$fire_reset; SESSION_ID=$session_id; STATE_ROOT=$state_root"
```

| `ITERATE_CB_MODE` | アクション |
|---|---|
| `batch` | ステップ 6.1（failed sentinel emit）|
| `interactive` | ステップ 6.2（機械的停止通知）|

**両分岐は挙動として同構造**（failed 記録 + draft 残し + 停止通知 + handoff クリア維持 + 共有前段での cycle counter reset。人間への問い合わせは行わない）であり、差は次の 2 点だけである。なお共有前段の counter reset は batch 経路にも適用されるが、ステップ 6.1 のブロック自体は無変更であり Issue #2026 §4.2 の Non-Target に抵触しない（batch では従来も次 Issue のステップ 0.6 fresh 判定で同じ counter が除去されており、より早く掃除されるだけで安全側）:

1. **sentinel の消費者**: `[iterate:max-cycles-reached]` は `/rite:batch-run` が grep して当該 Issue を `failed[]` に記録し次 Issue へ進むために消費する。`[iterate:max-cycles-stopped]` は消費者を持たない iterate 内部完結の最終状態表示。
2. **`REFIRE=1` / `FIRE_RESET=failed` 注意行の有無**: ステップ 6.2（対話）のみが持つ。6.1（batch）は Issue #2026 §4.2 の Non-Target（MUST NOT modify）のため本スキルでは対称化しない。結果として batch では、前 Issue から漏れた stale counter の reset に失敗した場合、review を 1 cycle も回していない Issue が `failed[]` に「上限到達（非収束）」として記録されうる。対称化は別 Issue で扱う。

**ただし「同構造」なのは停止時の挙動であって、失敗記録の永続性ではない** — 対話側の failed 記録は永続化されない。共有前段の reset 成功後に残る state は `phase=review` / `cycle_count` キー削除 / `handoff` キー削除で、これは cycle 1 をこれから回す fresh な review と区別できない（唯一の差である `next_action` の文面は後続のどの `flow-state.sh set` でも上書きされる）。batch が `run-queue` の `failed[]` という外部の永続記録を持つのに対し、対話側は上記 1. のとおり消費者を持たない sentinel が最終状態表示として出るだけである。これは AC-2（再実行で counter がリセットされループが再開できる）が counter の破棄を要求することの帰結で、本 Issue のスコープでは意図した設計。

どちらの経路もマージには到達しない（上記 invariant）。

### ステップ 6.1: バッチ実行 — failed sentinel を emit

review を回さず、当該 Issue を非収束（failed）として `/rite:batch-run` に返す。`/rite:batch-run` はこの sentinel を受けて当該 Issue を failed 記録し、次の Issue へ進む（ready/merge/cleanup はスキップ、draft/open PR はレビュー待ちで残す）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない（`[fix:error]` が set で handoff をクリアして clean terminal になるのと同じ。以降は run の flat 構造 + HTML hint で継続）:

```
## /rite:iterate サーキットブレーカー発火（バッチ）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: {fire_reason_line}
- blocking 推移: {trend}
- 措置: 当該 Issue を failed 扱いとし、draft/open PR をレビュー待ちで残します（`/rite:batch-run` が残りキューを続行、最終 Issue なら完了通知へ）

<!-- [iterate:max-cycles-reached] -->
```

`{fire_reason_line}` / `{trend}` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=` / `TREND=` からリテラル置換する（`{max_review_cycles}` はステップ 0.6 の `ITERATE_CYCLE_MAX=`。置換表は 6.2 と共通で、下記「発火理由の文面」を参照）。

**sentinel は発火理由に依らず `[iterate:max-cycles-reached]` のまま**。`/rite:batch-run` はこの literal を grep して当該 Issue を `failed[]` に記録し cursor を前進させるため、理由別に sentinel を分けると batch が停止を検出できなくなる（sentinel 契約は不変に保つ）。理由の区別は上記「理由」行が担う。

制御を `/rite:batch-run` に戻す（run 側で cursor 前進）。

### ステップ 6.2: 対話実行 — 機械的停止通知を出力

`AskUserQuestion` は**使わない**。当該 PR を非収束（failed）として機械的に記録し、draft/open PR をレビュー待ちで残して停止する。6.1（batch）と同構造であり、品質ゲートの履行を人間の裁量に委ねない（発火は失敗であって、人間に選ばせて counter をリセットし続行できる例外を作らない）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない。

下記の停止通知を出力してループを終了する（`{max_review_cycles}` 等はリテラル置換する）:

```
## /rite:iterate サーキットブレーカー発火（対話・停止）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: {fire_reason_line}
- blocking 推移: {trend}
- 措置: 当該 PR を非収束として失敗記録し、draft/open PR をレビュー待ちで残します（マージには進みません）

再開方法:
- ループを再開する: /rite:iterate {pr_number} を明示的に再実行する（cycle counter がリセットされ、
  もう {max_review_cycles} cycle 回る）。/rite:recover 経由の再開も同じ経路
- Ready 化して人間のレビューに委ねる: /rite:ready {pr_number}

<!-- [iterate:max-cycles-stopped] -->
```

#### 発火理由の文面（6.1 / 6.2 共通の置換表）

`{fire_reason_line}` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=` で決める。`{trend}` は同 marker の `TREND=` の値（カンマ区切りの per-cycle blocking 件数）をそのまま使い、`→` 区切りへ整形して表示する（例: `TREND=3,7,7,4` → `3 → 7 → 7 → 4`）。**この推移行は省略しない** — 発火が「予算切れ」ではなく「構造的な発散の検出」であることを人間が読んで検証できる唯一の材料であり、AC-4 が通知への包含を要求している:

| `CB_REASON` | `{fire_reason_line}` |
|---|---|
| `divergence` | `review⇄fix ループの収束トレンドが発散（直近サイクルで過去の最良水準へ戻れず、下降もしていない）` |
| `max-cycles` | `review⇄fix cycle が上限 {max_review_cycles} に到達（発散判定をすり抜けた非収束）` |

`TREND=` が**空**のとき（トレンド判定が `insufficient` / `unavailable` に落ちた場合。`CB_REASON` は必ず `max-cycles` になる — `divergence` は判定が下りていなければ成立しないため）は、`- blocking 推移:` 行を「`- blocking 推移: 取得できませんでした（ステップ 1 の WARNING を参照）`」に差し替える。**行ごと省略してはならない** — 推移が無いことと推移を出し忘れたことが読み手から区別できなくなる。
ステップ 0.6 / ステップ 1 / **ステップ 6 共有前段**の `[CONTEXT]` marker を context で観測している場合、下記の条件で上記「理由」行の直後に注意行を追加する（§4.5 の error handling。同じ文面の停止通知が真の非収束と区別できなくなるのを防ぐ）。3 ステップすべてを観測対象に含めること — (b) が読む `FIRE_RESET` はステップ 6 共有前段が、(c) が読む `HANDOFF_CLEAR` はステップ 1 が emit する。値の照合は `;` 区切りの `KEY=VALUE` 単位で完全一致とする（値側は `failed` の部分一致が `failed-refire` / `failed-stale` の両方に当たり、キー側は `RESET` が `FIRE_RESET` の部分文字列になるため、どちらも部分一致で照合してはならない）。注意行および下記の差し替え行に含まれる `{plugin_root}` / `{pr_number}` / `{max_review_cycles}` / `{session_id}` / `{state_root}` はリテラル置換する（`{session_id}` / `{state_root}` はステップ 6 共有前段の `SESSION_ID=` / `STATE_ROOT=` marker の値。**どちらも値が得られないことがあり、その場合は (b) の pre-fill 表に従ってコマンドの当該部分だけを解決手順へ置き換える** — 空値や sentinel をそのまま埋めたコマンドは rc=0 のまま別の state を対象にして空振りするため）。**置換の対象は注意行の散文だけでなく、(b) が人間へ渡すすべての実行可能テキスト** — リセットコマンド本体・その手前の実在確認・pre-fill 表の案内文 — **に及ぶ**。人間の端末で live なシェル変数を前提にした記法（`$root` 等）は、その変数を同じ案内文の中で代入している箇所以外では使わない（未定義変数は空展開して確認や探索が黙って空振りする）。

**(a) `REFIRE=1`**（この起動では review を 1 回も回さずに発火した。前回の最終 cycle 途中で中断した場合の正常な発火と、counter リセット失敗による再発火の**両方**を含む — marker だけでは区別できない）:

```
- 注意: 起動時点で cycle counter が上限に達していたため、この起動では review を 1 回も回さずに発火しました（前回の最終 cycle 途中で中断していた場合はこれが正常な発火です）。ステップ 0.6 / ステップ 1 / ステップ 6 共有前段に WARNING が出ている場合は、その直後の flow-state.sh の診断を確認してください
```

`REFIRE=0`（起動時点の counter が上限未満）では review が実際に回ってから到達しているため**追加しない**。`RESET` の値（`failed-refire` / `failed-stale` / `ok` / `none`）は本条件に使わない — 発火時の phase は `review` / `fix` なので再実行はステップ 0.6 で resume 判定となり reset ブロックに入らず、即再発火する当の経路で `RESET=none` になるため。`RESET` は reset を試行した場合の結果を記録するもので、即再発火の判定には `REFIRE` を使う。

**(b) `FIRE_RESET=failed`**（ステップ 6 共有前段の set に失敗し counter がリセットされなかった）:

```
- 注意: 発火時の cycle counter リセットに失敗しました。**このまま再実行しても counter が上限のまま即再発火します**。次のコマンドで手動リセットしてから再実行してください（`--handoff` を伴わないため handoff のクリアも兼ねます）: `RITE_STATE_ROOT="{state_root}" bash "{plugin_root}"/hooks/flow-state.sh set --session {session_id} --phase review --next "cycle counter 手動リセット" --cycle-count 0`
```

`{state_root}` / `{session_id}` は marker の値で pre-fill する。**2 つは独立軸**で、どちらも「値が得られない」ことがある（`_resolve_session_id` は `STATE_ROOT` に依存しないため、state root が未解決でも session_id は判明している側が支配的）。**得られた側は必ず埋め、得られなかった側だけを解決手順に置き換える** — 判明している値を捨てて人間に探索させない:

| marker | コマンドに入れるもの |
|---|---|
| `STATE_ROOT=<実パス>` | `RITE_STATE_ROOT="<実パス>"` をそのまま埋める |
| `STATE_ROOT=unresolved` | 埋めず、代わりにこう案内する: 「**リポジトリのチェックアウト内で** `root=$(bash "{plugin_root}"/hooks/state-path-resolve.sh)` を実行し、`RITE_STATE_ROOT="$root"` として使ってください（repo 外の cwd では resolver が cwd を返して空振りします。`git rev-parse --show-toplevel` で代用しないこと — linked worktree では worktree root を返し、resolver が行う main checkout への unify が効きません）」 |
| `SESSION_ID=<実 UUID>` | `--session <実 UUID>` をそのまま埋める |
| `SESSION_ID=`（空） | 埋めず、代わりにこう案内する: 「`{state_root}/.rite/sessions/` の各 `*.flow-state` から `pr_number` が {pr_number} かつ `cycle_count` が {max_review_cycles} **以上**のものを探して `--session` に補ってください（**同一 `pr_number` の state が複数残ることがある**ため、複数該当したら `updated_at` が最新のものを採ります。`以上` なのは発火条件が `-ge` で、invocation 間で `max_review_cycles` を下げると `cycle_count > max` の state が等値比較では該当しなくなるため）」。**`{state_root}` が同時に未解決の場合のみ**、上表 `STATE_ROOT=unresolved` 行の案内で得た `$root` をこの位置に使う |

`SESSION_ID=` が空のまま `--session` を埋めると `--session --phase` となり `--phase` が session 値として食われて `ERROR: unknown option: review` で即失敗する。`STATE_ROOT=` が空や sentinel のまま `RITE_STATE_ROOT=` を埋めると、`flow-state.sh` の `[ -n ... ]` 判定で「未設定」と同義に縮退して cwd へフォールバックする。どちらも「渡したのに効かない」形の空振りなので、埋められない側は必ず上記の解決手順へ置き換える。

**実在確認をリセットコマンドの手前に置くこと**（注意行の中で、リセットコマンドより前の位置に 1 行として置く）: `[ -f "{state_root}/.rite/sessions/{session_id}.flow-state" ]` が偽なら state root か session_id が誤っている。**この 2 トークンもリセットコマンド本体と同じく pre-fill する**（shell 変数 `$root` を書いてはならない — `root` を代入するのは上表 `STATE_ROOT=unresolved` 行の案内文だけで、値が得られた支配的経路では人間の端末に `root` が存在せず、確認が常に偽になって正しい値を持つ人間を唯一の復旧手順から遠ざける）。この確認がないと `flow-state.sh set` は誤った root/session_id でも **rc=0・無出力**で新しい state file を作り、上限のまま止まっている本物の counter は手つかずで残る。しかも事後に `get --field cycle_count` を見ても、正しくリセットした場合（キー削除）と空振りした場合（新規 state にキーなし）が同じ結果を返すため**判別できない** — 実行前の確認だけが唯一の防護になる。

handoff 迂回のリスクは (b) には含めない。**counter reset の失敗と handoff クリアの失敗は独立した別 set の成否**であり、しかもステップ 6 共有前段の set は `--handoff` を伴わないため handoff を default-clear する（`flow-state.sh` の `cmd_set` は `jq` で state を再構築し、`--handoff` 未指定ならキー自体を書かない）。したがって `HANDOFF_CLEAR=ok` かつ `FIRE_RESET=failed` のとき handoff は既に消えており、(b) に迂回リスクを書くと存在しない障害へ人間を誘導する。迂回が実際に成立するのは**両方の set が失敗したとき**だけなので、独立した条件 (c) として出す:

**(c) `HANDOFF_CLEAR=failed` かつ `FIRE_RESET=failed`**（fire 分岐と共有前段の set が**どちらも**失敗し、継続 handoff が残存した）:

```
- 注意: 継続 handoff のクリアにも失敗しています。Stop hook が `/rite:pr-review` を再注入し、ブレーカーの cycle 判定を経由しないままレビュー/修正が続く可能性があります（再注入された `/rite:pr-review` は自身で次の handoff を張り直すため、モデルが `/rite:iterate` に戻るまで counter の制御外で進みます）。上記の手動リセットは handoff のクリアも兼ねるため、これを先に実行してください
```

`HANDOFF_CLEAR=failed` のみ（`FIRE_RESET=ok`）では**追加しない** — 共有前段の set が 2 度目の default-clear として働き handoff は消えているため、迂回は起きない。

**(b) は注意行の追加だけでは足りない。** 上記テンプレートの「再開方法」1 行目が約束する「cycle counter がリセットされ、もう {max_review_cycles} cycle 回る」は手動リセットを行うまで偽であり、注意行と同一通知内に並べると矛盾する 2 つの再開手順を人間に提示することになる（注意行は「理由」行の直後に入るため両者は数行しか離れていない）。よって **(b) を観測したときは、テンプレートの当該 1 行を次の 1 行へ差し替えて出力する**（追加ではなく置換）:

```
- ループを再開する: 上記の手動リセットを実行してから /rite:iterate {pr_number} を再実行する
  （リセット前に再実行すると即座に再発火する）。/rite:recover 経由の再開も同じ経路
```

差し替える単位は**「再開方法」の第 1 bullet 全体**（折り返しで 2 物理行にまたがる）であり、第 1 物理行だけを置き換えてはならない（残った折り返し行が孤立する）。

(a) のみを観測した場合はこの差し替えを**行わない**（(a) では counter はステップ 6 共有前段で正しくリセットされており、元の 1 行が真）。(a) / (b) / (c) は独立に評価するので、観測したものを **(a) → (b) → (c) の順に**追加し、差し替えは (b) を観測した場合のみ行う（(c) の本文は (b) 内の手動リセットコマンドを「上記の」で参照するため、順序を崩すと前方参照になる）。

---

## エラー時の方針

- ユーザーが Ctrl+C で中断した場合: flow-state に現 phase (review or fix) が残るので `/rite:recover` で本コマンドが再起動する (詳細な phase → command routing は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 5.3 を参照)
- `[fix:error]` 時: 自動継続せず必ず AskUserQuestion で確認 (silent regression 防止)
- reviewer が non-deterministic に振動 (毎 cycle で別の指摘) する場合: 収束トレンドの発散判定が先に発火し、それをすり抜けた場合も `safety.max_review_cycles`（既定 5）到達でサーキットブレーカーが発火する（ステップ 6）。batch / 対話とも人間に問わず機械的に停止し（発火＝失敗の記録）、`/rite:batch-run` バッチ実行は `[iterate:max-cycles-reached]` を emit して当該 Issue を failed 扱いにし次 Issue へ進み、対話実行は `[iterate:max-cycles-stopped]` の停止通知で終了する。再開は人間による `/rite:iterate {pr}` の明示的な再実行のみ。Ctrl+C による手動中断も従来どおり可能

---

## ループ継続・終了の構造的保証

継続点・終了点で sub-skill が one-shot handoff (`/rite:...` / `FINALIZE:{result}:{pr}`) を flow-state にセットし、turn 早期終了時は Stop hook (`stop-loop-continuation.sh`) が consume + prefix 分岐で停止を差し戻す。`[fix:error]` とサーキットブレーカー fire 分岐は handoff を持たない/能動クリアする (Stop hook は停止を許可)。機構の全体解説・sentinel → handoff 対応表・無限 block 防止の設計:
rationale: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism)

## 設計判断

- **blocking 指摘ゼロ（mergeable）到達が正常出口** — blocking の定義式は本ファイルに複製せず [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) を SoT とする（同 § は reviewer finding に閉じた canonical 式と fix loop 全体を対象とする consumer 式の差を「適用範囲」で意図的なスコープ差として定義している。本スキルはループ側なので後者に従い、実測の有無を判定できない指摘は blocking のまま扱う）。実測を伴わない指摘は non-blocking として `/rite:pr-review` ステップ 6.1.d の PR 記録コメント・ステップ 5.4 統合レポート・永続 JSON に記録されたまま残存するため、**非実測指摘が N 件残った状態でも `[review:mergeable]` に到達してループが正常終了しうる**（#2024）— 残存分は draft PR の人間レビューに委ねる設計。加えてサーキットブレーカーを唯一の自動安全網として持ち、reviewer の非決定的振動や非収束 PR による無限ループを構造的に防ぐ。同一 finding 検出 / quality signal escalation といった細粒度の安全網は依然として持たない（CLAUDE.md「シンプルさを死守」）
- **ブレーカーの発火条件は「発散」であって「予算切れ」ではない** — 主経路は収束トレンドの発散検出（`hooks/scripts/review-trend-divergence.sh`）で、`safety.max_review_cycles`（既定 5）はそれをすり抜ける遅い非収束を受け止める遠い backstop に格下げした。cycle 数上限だけでは努力と無駄を区別できない（健全に収束中でも上限で殺し、発散していても上限まで燃やす）ため、「品質を予算で縛らない・無駄は排除する」（CLAUDE.md プロジェクト原則）に反していた。判定は helper に閉じ LLM の裁量を介在させない。判定式は実運用で観測されたトラジェクトリで backtest して確定した定数であり、**窓幅や閾値を config キーにしない** — 調整の実需が観測されてから Issue を切って設定化する（`no_speculative_structure`）。判定式の較正根拠と意図した境界（最良水準での平坦は発火させない = false positive 回避）は helper の header が SoT
- **発火理由は停止構造を変えない** — sentinel（`[iterate:max-cycles-reached]` / `[iterate:max-cycles-stopped]`）・handoff クリア・counter reset はいずれも発火理由に依らず不変で、変わるのは停止通知の「理由」行と blocking 推移の表示だけである。sentinel を理由別に分けない理由は、`/rite:batch-run` が前者の literal を grep して failed 記録・cursor 前進を行う契約を壊さないため。名称が「max-cycles」のまま発散発火にも使われるのは軽微な misnomer だが、契約の安定を優先する
- **発火＝失敗の機械的記録（batch / 対話で同一）**: 発火時は両モードとも人間に問わず停止する（#2026）。導入時（#1701）は対話モードの UX として AskUserQuestion（継続 / 中止 / draft のまま停止）を残していたが、人間の裁量で counter をリセットして続行できる経路は「品質ゲートを機械的に履行する」方針に対する例外であり、人間エスカレーションは責任転嫁で終端にならない。継続は人間が明示的に `/rite:iterate {pr}` を再実行する経路のみに絞り、そのとき counter はステップ 6 の共有前段が既にリセットしている。`/rite:batch-run` バッチ実行は従来どおり failed 扱いで次 Issue へ自動遷移する（バッチ全体のストール防止）
- **cycle counter は flow-state に保持**: 専用 state file (`.rite/state/*.count` 等) は持たず、`cycle_count` を flow-state の merge-preserve フィールドとして永続化する（`worktree` と同じ additive パターン）。resume を跨いで継続し（AC-3）、fresh entry（phase が review/fix 以外）で 0 リセットして run バッチの Issue 間リークを防ぐ。加えて**発火が sentinel として記録される直前**（ステップ 6 の共有前段）で 0 にリセットする — リセットしないと再実行が即再発火してループを再開する術が無くなるが、発火後は継続 handoff が（ステップ 1 fire 分岐の set で）default-clear されて自動再入場の経路が消えるため、リセットしても自動継続は生じない。リセットを fire 分岐ではなく共有前段に置くのは、「発火は無記録・counter は 0」という最悪の組み合わせが成立する窓を狭めるため（共有前段より手前で turn が終わればこの窓では counter が上限のまま残り、次回ループ頭で再発火する）。**共有前段の実行後・sentinel 出力前の窓は残存する** — 完全な閉塞には sentinel 出力を Stop hook に強制させる handoff が要るが、その reason 文面の是正は Non-Target の `hooks/stop-loop-continuation.sh` 改修を伴うため別 Issue とする。「発火済み」を別マーカー（例: `cycle_count = max + 1`）として次回起動まで持ち越す設計は採らない。持ち越すと「発火したか」を `max_review_cycles` との相対比較で符号化することになり、同値が invocation 間で変わりうる（毎回 config から読み直す）ため符号化が両方向に破綻する（上限を下げれば未発火が発火済みと誤認され、上げれば発火済みが認識されない、#2026）。Stop hook の handoff とは独立（handoff は one-shot consume される継続マーカー、cycle_count は accumulate されるカウンタ）
- 別 Issue 化経路は廃止済み (commit 1a で fix.md Phase 4.3 削除) — 「別 Issue にスキップして loop 終了」の抜け穴は塞がれている
