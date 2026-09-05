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

> **質問規律**: すべての質問・再試行判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。
>
> 実行開始時は [Autonomous Execution](../rite-workflow/references/autonomous-execution.md) を適用する。

`/rite:pr-review` ↔ `/rite:fix` を **blocking 指摘ゼロ（mergeable）になるまでループ** する（blocking の定義は [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) が SoT。実測なし（`measured=false`）と判定された指摘は non-blocking として記録されたまま残存し、`[review:mergeable]` に到達しうる。残件は完了通知前の 5.S が消化し、正常出口は未消化 0 件）。ただし **サーキットブレーカー** を備え、reviewer の非決定的な振動や非収束 PR による無限ループを構造的に防ぐ。やることは以下のシーケンシャルなタスク列:

0. flow-state から issue_number / branch_name を復元
0.6. cycle counter を初期化（fresh は 0 にリセット / resume は継続）+ `safety.max_review_cycles` を読込・検証
1. lost 修復ゲート（前 cycle JSON 不在なら即時保存 or counter 不前進の再レビュー）→ 発火条件チェック（収束トレンドの発散 / `max_review_cycles` 到達）→ 不成立なら counter を +1 して `/rite:pr-review` を invoke / 成立なら サーキットブレーカー（ステップ 6）へ
2. review sentinel を判定（`[review:mergeable]` → ステップ 5.S / `[review:fix-needed:N]` → ステップ 3 / error・不在 → 1 回自動再試行、再失敗時は停止）
3. `/rite:fix` を invoke
4. fix sentinel を判定（通常ループ: `[fix:pushed]` → ステップ 1 に戻る / `[fix:sweep-done]` → ステップ 5 / `[fix:replied-only]` `[fix:cancelled-by-user]` → 終了 / error・不在 → 1 回自動再試行、再失敗時は停止。`--nb-sweep` 経由は 5.S 専用表 — ステップ 1 に戻らない）
5.S. `[review:mergeable]` 後の NB digest sweep（対象 0 は no-op。同一 PR で 2 回禁止）
5. 完了通知を出す
6. （発火時のみ）サーキットブレーカー: counter と停止理由を記録し、batch は `[iterate:max-cycles-reached]`、対話は `[iterate:max-cycles-stopped]` と停止通知を出して終了する

**サーキットブレーカーの発火条件は 2 つ**:

- **収束トレンドの発散**（主経路）: 永続レビュー JSON の per-cycle blocking 件数から `hooks/scripts/review-trend-divergence.sh` が発散を機械判定する。「直近 2 値がともに過去の最良水準を超え、かつ下降中でもない」を発散とし、**収束中のループは本判定では殺されない**（cycle 数上限は別条件として下記 2. のとおり働く）
- **`safety.max_review_cycles`（既定 15）到達**（保険）: 発散判定をすり抜ける非収束を受け止める backstop。`cc >= max_cycles` は trend 判定と**独立した発火条件**。**16 cycle 以上を要する収束中の run は既定値のままでも本経路で停止する**
rationale: references/rationale.md#circuit-breaker-conditions

ブレーカー発火は review⇄fix ループの停止 signal である。発火後は counter を 0 に戻し停止理由を記録して終了する。review / fix は invoke しない。再開はユーザーによる `/rite:iterate` の明示的な再実行に委ね、fresh entry で run 開始点を更新し full scope から始める。cycle_count は flow-state に永続化され resume を跨いで継続する。

途中で止まったら flow-state に現 phase (review or fix) が残るので `/rite:recover` で再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number (required)
**Output**: 完了通知（`[review:mergeable]` 到達後 5.S sweep 完了 or `[fix:replied-only]` 終了 or `[fix:cancelled-by-user]` 中断 or サーキットブレーカー後の full review 不成立（`[iterate:max-cycles-reached]` バッチ / `[iterate:max-cycles-stopped]` 対話。非収束による失敗で、マージには進まない）or sweep 失敗 `[iterate:nb-sweep-error]` or Ctrl+C 中断）。ブレーカー後の full review が返した mergeable / fix-needed は通常 routing に合流する。

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

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
| `{max_review_cycles}` | `safety.max_review_cycles` in `rite-config.yml`（既定 15、無効値は既定へフォールバック）。**発散判定をすり抜けた非収束を受け止める backstop**（既定 15 では 16 cycle 以上を要する収束中の run にも上限として働く） |
| `{fire_reason_line}` | ステップ 6.1 / 6.2 の「理由」行。ステップ 1 の `[CONTEXT] ITERATE_CB=fire` marker の `CB_REASON=` から ステップ 6.2「発火理由の文面」表で決める |
| `{cb_reason}` | ステップ 1 の `[CONTEXT] ITERATE_CB=fire` marker の `CB_REASON=` の**生値**（`max-cycles` / `divergence`）。ステップ 6 共有前段が flow-state へ書く `--stop-reason "circuit-breaker:{cb_reason}"` でのみ使う（人間向けの文面は `{fire_reason_line}` が担う） |
| `{trend}` | ステップ 1 の `[CONTEXT] ITERATE_CB=fire` marker の `TREND=`（カンマ区切りの per-cycle blocking 件数）。停止通知では `→` 区切りへ整形して表示する。空のときの扱いは ステップ 6.2「発火理由の文面」を参照 |
| `{trend_reason}` | ステップ 1 の `[CONTEXT] ITERATE_CB=` marker の `TREND_REASON=`（helper が返した判定不能の理由。ステップ 6.2「発火理由の文面」の `max-cycles` 分岐と推移行の差し替えで使う） |
| `{cycle_count}` | flow-state `cycle_count` field（review⇄fix cycle の消化数。ステップ 1 で increment、fresh entry で 0 リセット。発火時はステップ 6 の共有前段が、正常終了時はステップ 5.0.1 が 0 にリセットする） |
| `{state_root}` | ステップ 6 共有前段の `[CONTEXT] STATE_ROOT=` marker の値（`hooks/state-path-resolve.sh` の解決結果。未解決時は sentinel `unresolved`）。ステップ 6.2 注意行 (b) の手動リセットコマンドでのみ使い、値が得られないときは同節の pre-fill 表に従って解決手順へ置き換える |
| `{session_id}` | ステップ 6 共有前段の `[CONTEXT] SESSION_ID=` marker の値（`flow-state.sh path` の basename）。用途と未解決時の扱いは `{state_root}` と同じ |
| `{nb_count}` | ステップ 5.0.2 の `ITERATE_NB_REMAINING` marker 値（overlay 後は 0。取得失敗は 5.S で停止しここへ来ない） |
| `{nb_record}` | 同 marker の `record=`（review JSON パス。失敗時は空） |
| `{nb_by_severity}` | 同 marker の `by_severity=`（`SEVERITY:count` のカンマ区切り。0 件 / 失敗時は空） |
| `{sweep_issued}` / `{sweep_recorded}` | ステップ 5.S の `NB_SWEEP_RESULT` / `ITERATE_NB_SWEEP=done` の `issued=` / `recorded=` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |

---

## ステップ 0: flow-state から issue_number / branch_name を復元

`{issue_number}` / `{branch_name}` は standalone 起動でも flow-state set 呼び出しで必須のため、本コマンド冒頭で flow-state から復元する。
rationale: references/rationale.md#step0-canonical-pattern

```bash
# marker の emit / 照合は共有関数 marker_emit / marker_get が所有する。書式・行頭アンカー・
# 複数行耐性・branch スコープ・recency の契約は hooks/tests/context-marker.test.sh が SoT
# （本ファイルに散文で書き戻さないこと）。読み込めないときは縮退させない — marker が出なければ
# LLM の routing が成立せず、無言で進むと develop 上で誤ったループを回しうる。
# Bash tool 呼び出し間でシェル状態は引き継がれないため、marker を扱う各ブロックで独立に読み込む。
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

iterate_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "") || iterate_issue=""
iterate_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "") || iterate_branch=""
marker_emit ITERATE_ISSUE "$iterate_issue" "ITERATE_BRANCH=$iterate_branch"
```

LLM は `[CONTEXT] ITERATE_ISSUE` / `ITERATE_BRANCH` から値を読み、後続の flow-state.sh set 呼び出しで `--issue` / `--branch` に literal substitute する。値が空の場合は AskUserQuestion で「Issue 番号 / ブランチ名を入力 / 中止」を提示。

### ステップ 0.5: セッション worktree 健全性の保証（multi_session 有効時 / AC-2）

ループに入る前に、対象作業ブランチの session worktree を保証する。共通ヘルパー `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)）で検出・再構築する（`{issue_number}` / `{branch_name}` は ステップ 0 の `ITERATE_ISSUE` / `ITERATE_BRANCH` marker の値）:
rationale: references/rationale.md#worktree-ensure-preamble

```bash
bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue {issue_number} --branch {branch_name}
```

> `--branch {branch_name}` を明示する（review/fix の `--branch {head_ref}` 渡しと対称）。`ITERATE_BRANCH` が空の場合は省略してよい（helper が ref 推定にフォールバックする）。

`[CONTEXT] WT_ENSURE=` marker の分岐は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 3.1.5 の **WT_ENSURE 分岐表（SoT）** に従う:

- `disabled` / `already_in` → no-op、ステップ 1 へ。
- `reenter` / `reconstructed` → `EnterWorktree` ツールを `path: {path}`（marker の `path=` 値）で呼び出してからステップ 1 へ。`reconstructed` は helper が `git worktree add` 済み。EnterWorktree 失敗時の切り分けは recover.md Phase 3.1.5 / /rite:open Step 2.3-W と同じ（silent に新規扱いしない）。
- `residue` → AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` を表示）。
- `branch_absent` → 対象ブランチが実在しない。**develop 上で続行しない**。AskUserQuestion で「Issue 番号 / ブランチを確認して再実行 / 中止」を提示（誤再構築しない）。
- `failed` → 再構築失敗（helper rc=1, stderr に原因 + 復旧手順）。**silent fallback せず明示停止**。develop 上で review/fix を回さない。

> 各 review/fix cycle の入場でも `/rite:pr-review` / `/rite:fix` が同じ helper を通す。本ステップ 0.5 はループ全体の前段ゲート。

---

## ステップ 0.6: cycle counter の初期化 + max_review_cycles の検証

ループに入る前に、review⇄fix サーキットブレーカーの cycle counter を初期化し、上限値を検証する。counter は flow-state の `cycle_count` に永続化され、resume を跨いで継続する（AC-3）。
rationale: references/rationale.md#cycle-counter-init

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
# marker の emit / 照合は共有関数が所有する（ステップ 0 と同型。契約の SoT は
# hooks/tests/context-marker.test.sh）。neutralize_ctrl と違い縮退させない — 診断の読みやすさが
# 落ちるのと marker が消えるのとでは帰結が異なり、後者は LLM の routing 自体を壊す。
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

# ⚠ 下行はテスト hooks/tests/max-review-cycles-default.test.sh が awk 抽出アンカーとして参照する。変更時はテスト側の awk パターンも同時更新すること
# (1) max_review_cycles を rite-config.yml から読取・検証（AC-4）。無効値（0 以下 / 非数値）は WARNING + 既定値 15
raw_max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$raw_max" in
  '')            max_cycles=15 ;;                                  # キー欠落 = 既定（正常系、WARNING なし）
  0|*[!0-9]*)    max_cycles=15; echo "WARNING: safety.max_review_cycles='$raw_max' は無効（0 以下 / 非数値）。既定値 15 を使用します" >&2 ;;
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

# (3) run 開始点 pin の記録。`cur_cc == 0` = この起動から新しい run が始まる（fresh entry /
#     発火後の再実行 / batch の次 Issue）。その時点で存在する最新の結果ファイル basename を
#     `.rite/state/review-run-since-{pr}.txt` に記録し、以降の cycle では helper がそれより
#     新しいファイルだけを現 run とみなす。同一 PR の過去 run の JSON は cleanup（マージ後）
#     まで残るため、pin が無いと前 run の件数を現 run の列の先頭として読む。
#     **cycle_count を run 境界に使わない理由**は helper header の「Why run 境界に run-start pin を
#     使うか」を SoT とする（保存失敗と review 中断で「現 run のファイル数 == cycle_count」の
#     前提が破れる）。pin は counter と独立なのでその 2 経路で破れない。
#     resume（`cb_mode_init=resume` かつ counter が残っている）では既存 pin をそのまま使う —
#     上書きすると resume のたびに run が切り直され、それまでの列が消える。
#     **判定は `cur_cc == 0` 単独ではなく `fresh || cur_cc == 0` の選言**。`cur_cc == 0` だけだと
#     「新しい run か」の proxy にしかならず、fresh entry で counter reset が失敗した経路
#     （上の `failed-stale` / `failed-refire`。marker 整合のため意図的に `cur_cc` を 0 に落とさない）
#     で proxy が壊れる。そこで pin を据え置くと、ステップ 1 は stale pin を `--since` に、残存
#     counter を `--cycle-count` に渡すため helper の stale pin guard の前提条件（`since` が空
#     または `cycle_count == 0`）が揃わず素通りし、**前 run の列を含む混合列で発火する**
#     （AC-1 の否定方向）。選言にすれば fresh 側で必ず pin を張り直すので、その経路自体が消える
#     （reset 失敗分岐に pin 削除を複製する必要はない）。`cur_cc == 0` 側の項は resume 経路の
#     ステップ 5.0.1 / ステップ 6 共有前段が counter を 0 にして run を閉じた直後の起動
#     （phase 維持のため resume 判定になる）を拾うために残す。
#     非ブロッキング: pin を書けなくても helper は pin 無し（全件を 1 本の列として読む）へ
#     縮退するだけで、ループは止まらない。ただし縮退は WARNING で告知する。
run_since_status=none
if [ "$cb_mode_init" = fresh ] || [ "$cur_cc" -eq 0 ] 2>/dev/null; then
  # `2>/dev/null` は付けない — resolver は git 内外どちらでも rc=0 / 非空を返す設計なので、
  # ここに落ちるのは **helper 自体を実行できない場合（プラグイン破損 / 版 skew、rc=127）だけ**。
  # その唯一の原因を示すのは bash の `No such file or directory` であり、抑止すると原因が消える
  # （ステップ 1 側と同じ論拠）。正常系の stderr は実測 0 バイトなのでノイズは増えない。
  pin_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || pin_root=""
  if [ -z "$pin_root" ]; then
    echo "WARNING: state-path-resolve.sh を実行できませんでした（プラグインの破損 / 版 skew）。run 開始点 pin を記録できないため、発散判定は前 run の JSON を含んだ列を読んで判定を降ろします" >&2
    run_since_status=unresolved-root
  else
    rm -f "$pin_root/.rite/state/nb-sweep-done-{pr_number}.txt"
    pin_file="$pin_root/.rite/state/review-run-since-{pr_number}.txt"
    # 現時点で最新の結果ファイル basename（1 件も無ければ空 = pin 無し = 全件が現 run）。
    # ソート順は helper 側の選別と揃える（LC_ALL=C 昇順 = 時系列昇順）。
    pin_value=$(find "$pin_root/.rite/review-results" -maxdepth 1 -type f -name "{pr_number}-*.json" 2>/dev/null \
      | LC_ALL=C sort | tail -1)
    [ -n "$pin_value" ] && pin_value=$(basename "$pin_value")
    if mkdir -p "$pin_root/.rite/state" 2>/dev/null && printf '%s\n' "$pin_value" > "$pin_file" 2>/dev/null; then
      # 空 pin（結果ファイルが 1 件も無い = 新規 PR）は「境界を張った」とは意味が違う。
      # ステップ 1 は空 pin を読むと `--since ""` を渡し helper は全件読みへ倒れるため、
      # `ok` と同じ値にすると「正常」と読めてしまう。別値にして観測側で切り分ける。
      if [ -n "$pin_value" ]; then run_since_status=ok; else run_since_status=ok-empty; fi
    else
      # 書けなかった pin をそのまま残さない。ステップ 1 は「ファイルが存在するか」しか見ないため、
      # 前 run の pin が残っていると現 run の 2 cycle 目以降でそれを `--since` に渡してしまう。残る pin は
      # **前 run の開始点**（前 run の 0.6 が書いた値。指しているのは前々 run の最終ファイル）なので、
      # 「pin より新しいファイル」は前 run と現 run の結果を連結した列になる。helper の stale pin guard は `[ -z "$since" ] || cycle_count == 0`
      # を前提条件に持つため、pin が非空かつ 2 cycle 目以降ではこの列がそのまま判定にかかり、前 run の
      # 最良水準が `prefix_min` に居座る（実測: `5,3,1,0,8,8` は cycle 6 で fire）— 健全な run を殺す方向
      # (AC-1 の否定) の縮退になる。pin を消せば ステップ 1 の `absent` 経路 → `--since ""` となり、
      # 前 run の結果が同居している限り `実在数 > cycle_count` が必ず成立して guard の連言が揃い、
      # 既存の fail-loud 経路 `run_boundary_unresolved` へ倒れる（同居が無ければ全件 = 現 run なので
      # そのまま読んで正しい）。新しい fallback ではなく、用意済みの loud 経路へ到達させる措置。
      # `2>/dev/null` は付けない (cycle 4 で helper の find から外したのと同じ論拠 — rm が
      # EROFS / EACCES / immutable のどれで失敗したかが消える)。**削除の成否で縮退の向きが
      # 逆になる**ため、marker と WARNING を rm の rc で分ける。
      if rm -f "$pin_file"; then
        echo "WARNING: run 開始点 pin を書き込めませんでした ($pin_file)。stale pin を削除したため、発散判定は run 境界を確定できず判定を降ろします (max_review_cycles の backstop に委ねられます)" >&2
        run_since_status=write-failed
      else
        echo "WARNING: run 開始点 pin を書き込めず、stale pin の削除にも失敗しました ($pin_file)。残った pin は前 run の開始点なので、発散判定は前 run と現 run を連結した列を読み誤発火しえます。手動で削除してください" >&2
        run_since_status=write-failed-pin-retained
      fi
    fi
  fi
fi
marker_emit ITERATE_CYCLE_MAX "$max_cycles" "ITERATE_CYCLE=$cur_cc" "ITERATE_CYCLE_MODE=$cb_mode_init" \
  "RESET=$reset_status" "REFIRE=$cb_will_refire" "RUN_SINCE=$run_since_status"
```

`ITERATE_CYCLE_MAX` / `ITERATE_CYCLE` を retain してステップ 1 の上限チェックに渡す。

`RESET` は reset を**試行した場合**の診断値。**停止通知の注意行の条件には使わない**（条件は `REFIRE` と共有前段の atomic set 失敗 WARNING）:
rationale: references/rationale.md#reset-refire-run-since

| `RESET` | 意味 |
|---|---|
| `none` | reset 不要だった（counter が既に 0、または resume 継続） |
| `ok` | counter を 0 にリセット済み |
| `failed-refire` | reset が失敗し counter が**上限以上**のまま残存（`cycle_count >= max_review_cycles`）。ステップ 1 で即座にブレーカーが再発火する。WARNING と flow-state.sh の診断（helper が出力していれば）は emit 済み。停止通知の注意行は本値ではなく **`REFIRE=1`** が条件（reset を試行しない resume 経路でも即再発火しうるため） |
| `failed-stale` | **stale counter 除去**（`0 < cycle_count < max_review_cycles`。run バッチの Issue 間リーク等）の reset が失敗し counter が残存。上限未満なので即座には再発火せず、残 cycle が目減りした状態でループが回る。ステップ 6 の停止通知に注意行は**含めない**（含めると真の非収束停止に「review は 1 cycle も回っていません」という偽の説明が付く） |

`REFIRE` は**この起動でステップ 1 が review を回さずに fire するか**の述語で、ステップ 6.2 の注意行 (a) の条件そのもの:

`RUN_SINCE` は run 開始点 pin の記録結果。**pin が無い / 古いと発散判定は run 境界を確定できず判定を降ろす**（helper の `run_boundary_unresolved`）。`unresolved-root` / `write-failed` は**停止側**（判定を降ろす）。`write-failed-pin-retained` だけが**誤発火側**。`RESET=failed-stale` / `failed-refire` は本記録側の縮退を生まない（ゲートが `fresh || cur_cc == 0` の選言）。`ok-empty` は pin 不在と同じ扱いで、実在数が counter を超えた時点で判定が降りる:

| `RUN_SINCE` | 意味 |
|---|---|
| `none` | 記録を試行していない（resume かつ `cycle_count > 0` = run 継続中。既存 pin をそのまま使う） |
| `ok` | pin を記録した。以降の cycle は現 run のファイルだけを読む |
| `ok-empty` | 結果ファイルが 1 件も無い状態で pin を記録した（新規 PR）。pin 値は空で helper は pin 不在と同一に扱う。前 run が存在しないので誤った列は読まないが、**counter skew が 1 度起きるとその run の残り cycle で判定が降りる** |
| `unresolved-root` | state root を解決できず pin を記録できなかった。WARNING 済み |
| `write-failed` | pin ファイルを書けず、stale pin の**削除には成功した**。ステップ 1 は `absent` 経路へ倒れ、前 run の結果が同居していれば `run_boundary_unresolved` で判定を降ろす。WARNING 済み |
| `write-failed-pin-retained` | pin ファイルを書けず、stale pin の**削除にも失敗した**（read-only FS / immutable）。前 run の pin が残るため誤発火しうる唯一の値。WARNING が手動削除を案内する |

`RUN_SINCE_USED`（ステップ 1、両分岐に載る）は**実際に helper へ渡した pin の由来**（記録側 `RUN_SINCE` と独立に失敗しうる）:

| `RUN_SINCE_USED` | 意味 |
|---|---|
| `pin` | pin ファイルを読んで `--since` に渡した（正常） |
| `absent` | pin ファイルが無い、**または中身が空**（0.6 が `ok-empty` を記録した新規 PR）で空文字を渡した。前 2 者は WARNING 済み、空 pin 経路は WARNING を出さない |
| `unresolved-root` | state root を解決できず空文字を渡した。WARNING 済み |

`LOST`（両分岐に載る）は helper が返した `lost=` の値で、**cycle_count に対して失われた結果の件数**（保存失敗 / review 中断）。`0` 以外なら判定に使われた列に穴があり、ステップ 6.2 の推移行はその旨を併記する。同じ値がステップ 1 の修復ゲート入力になる（注記の文面・算出は変えない）。

| `REFIRE` | 意味 |
|---|---|
| `0` | 起動時点の counter が上限未満、または reset に成功して 0 に戻った。ステップ 1 は review を回してから進む |
| `1` | counter が上限以上のまま残っている。**ステップ 1 はこの起動で review を 1 回も回さずに fire する**（前回の最終 cycle 途中での中断からの正常な発火と、counter リセット失敗による再発火の両方を含む） |

---

## ステップ 1: 発火条件チェック → /rite:pr-review を invoke

ループ頭で **lost 修復ゲートを先に**評価し、穴が無いときだけサーキットブレーカーの **2 つの発火条件** を評価する。ゲートが fire なら increment も次 cycle の review も始めない。ゲートが ok で発火条件がどちらも不成立なら counter を +1 して `phase=review` に更新後 `/rite:pr-review` を invoke、いずれかが成立したらサーキットブレーカー（ステップ 6）へ分岐する:

1. **lost 修復ゲート** — helper の `lost=` が `0` より大きい（完了済み cycle に対して JSON 不足 = 増分）、または `cc>=1` かつ raw `lost=` 欠落かつ reason が `no_results_file` / `results_dir_missing` / `no_file_after_pin`（`_undecidable` は `lost=` を出さない）。次 cycle を始めず (a)/(b) へ。`cc=0` と `helper_unavailable` は発火させない
2. **収束トレンドの発散**（主経路）— `hooks/scripts/review-trend-divergence.sh` が永続レビュー JSON から現 run の per-cycle blocking 列を復元し発散と判定した場合。`cycle_count` が上限未満でも発火する
3. **`max_review_cycles` 到達**（保険）— 発散判定をすり抜けた非収束を受け止める backstop（既定 15 では 16 cycle 以上を要する収束中の run にも届きうる）
rationale: references/rationale.md#lost-repair-gate

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
# marker の emit / 照合の共有関数（ステップ 0 / 0.6 と同型。本ブロックは emit と照合の両方で使う）。
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit・照合できないため中止します" >&2; exit 1; }

cc=$(bash {plugin_root}/hooks/flow-state.sh get --field cycle_count --default 0) || cc=0
case "$cc" in ''|*[!0-9]*) cc=0 ;; esac
raw_max=$(awk '/^safety:/{s=1;next} s&&/^[a-zA-Z]/{exit} s&&/^[[:space:]]+max_review_cycles:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*max_review_cycles:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
case "$raw_max" in ''|0|*[!0-9]*) max_cycles=15 ;; *) max_cycles=$raw_max ;; esac  # 検証済。ここは silent fallback

# 収束トレンド判定。永続レビュー JSON から現 run の per-cycle blocking 列を復元し、
# 発散していれば cycle 上限未到達でも発火させる。判定は helper に閉じており、LLM は verdict を
# 読むだけで数え上げを行わない（AC-5）。
# `--since` にはステップ 0.6 が記録した run 開始点 pin を渡す（run 境界の決定はこれが担う。
# cycle_count は helper 側で「結果が失われた」診断にしか使われない）。pin ファイルが無ければ
# 空文字を渡す = 全件を 1 本の列として読む（pin 導入前の run への後方互換）。
# stderr は捨てずに素通しする（helper の WARNING はデータ異常の原因を示す唯一の記録）。
# pin の解決失敗と pin ファイル不在は**別の縮退**なので別値で報告する。どちらも helper へ空文字を
# 渡す（= 全件を 1 本の列として読む）が、その帰結は「他 run の混入」であり、helper 側の
# `run_boundary_unresolved` guard が捕まえるまで境界が失われている状態にある。無音で倒れると
# ステップ 0.6 が同じ失敗に WARNING を出しているのに、実際に helper へ渡す値を決める側だけが
# 何も残さないという非対称になる。`2>/dev/null` も付けない（原因が消える）。
pin_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || pin_root=""
run_since=""
run_since_used=pin
if [ -z "$pin_root" ]; then
  run_since_used=unresolved-root
  echo "WARNING: state-path-resolve.sh を実行できませんでした（プラグインの破損 / 版 skew）。run 開始点 pin を読めないため、発散判定は run 境界を確定できず判定を降ろします（max_review_cycles の backstop のみが働きます）" >&2
elif [ ! -f "$pin_root/.rite/state/review-run-since-{pr_number}.txt" ]; then
  run_since_used=absent
  echo "WARNING: run 開始点 pin が未記録です（ステップ 0.6 の書き込み失敗、または pin 導入前から継続中の run）。前 run の結果が同居していれば発散判定は判定を降ろします" >&2
else
  run_since=$(head -1 "$pin_root/.rite/state/review-run-since-{pr_number}.txt" | tr -d '[:space:]')
  if [ -z "$run_since" ]; then
    # pin ファイルはあるが中身が空（結果 0 件の新規 PR で記録された pin）。helper へ渡る値は
    # 不在時と同一（全件読み）なので、marker も `absent` と同義にして「pin を使えている」と
    # 名乗らせない。新規 PR では前 run が存在しないため実害は無いが、観測値は実態に合わせる。
    run_since_used=absent
  fi
fi
trend_out=$(bash {plugin_root}/hooks/scripts/review-trend-divergence.sh \
  --pr {pr_number} --cycle-count "$cc" --since "$run_since"); trend_rc=$?
# helper の出力から marker を読む。値の切り出しは marker_get が所有する — 行頭アンカー
# （helper の WARNING が marker 文字列を引用しても拾わない）・複数行 stderr 混入への耐性・
# 同一 KEY の recency・field 名のトークン完全一致は関数側の契約で、その SoT は
# hooks/tests/context-marker.test.sh。`reason` の値域や `trend` の区切りをここで文字クラスとして
# 書き直さないこと — 呼び出し側が値域を写すと helper が値を増やすたびに切り詰めが起きる
# （例: `[a-z_]` は `need_3_cycles` を `need_` にする）。値域を知るのは helper だけでよい。
trend_verdict=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE)
trend_series=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE --field trend)
# helper が判定不能の理由を載せる `reason=` は stdout にしか出ない。抽出して marker に載せないと、
# 「発散検出が全面不作動」と「まだ 3 cycle 目に達していない正常系」が呼び出し側から区別できない。
trend_reason=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE --field reason)
# 失われた結果の件数。列に穴があることを停止通知まで運ぶ（欠落は verdict を反転させうるため、
# 合成された推移を実測として描画させない）。`lost=` を出さないのは `_undecidable` 経路だけで、
# `need_3_cycles` は部分列とともに出す（差し替えと併記が同時成立する — ステップ 6.2 参照）。
# ゲートは raw を見る。coerce は注記 (`LOST=`) 用で、空を 0 に潰すと本 Issue の主シナリオ
# （cc>=1 かつ JSON 0 件）が fire しない。
trend_lost_raw=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE --field lost)
trend_lost=$trend_lost_raw
case "$trend_lost" in ''|*[!0-9]*) trend_lost=0 ;; esac
if [ "$trend_rc" -ne 0 ] || [ -z "$trend_verdict" ]; then
  # rc=2（引数不正 / jq 不在）や helper 不在（marketplace 版とローカル版の skew 等）。
  # 判定できないまま黙って通すと「発散検出が働いていない」ことが観測不能になるため loud にする。
  # 帰結は max_review_cycles による従来判定への縮退で、ループが止まらなくなるわけではない。
  echo "WARNING: 収束トレンド判定を実行できませんでした（rc=$trend_rc）。cycle 上限のみで判定します" >&2
  trend_verdict=unavailable
  trend_reason=helper_unavailable
  trend_lost=0
fi

# lost 修復ゲート。次 cycle の increment / review / CB 発火より先に評価する。
# `lost > 0` = 完了済み cycle に対して JSON が不足（増分）。helper の lost= をそのまま使う。
# `_undecidable` は lost= を出さないため、cc>=1 かつ raw 欠落かつデータ不在 reason でも fire。
# helper_unavailable は発火させない（判定不能を修復ゲートへ倒すと再レビュー空転する）。
lost_gate=ok
if [ "$trend_lost" -gt 0 ] 2>/dev/null; then
  lost_gate=fire
elif [ "$cc" -ge 1 ] 2>/dev/null && [ -z "$trend_lost_raw" ] && [ "$trend_reason" != "helper_unavailable" ]; then
  case "$trend_reason" in
    no_results_file|results_dir_missing|no_file_after_pin) lost_gate=fire ;;
  esac
fi

# 発火理由を決める。**cycle 上限を先に評価する** — 両方成立しているとき、上限到達は
# 従来からの契約（AC-3 の保険）であり、そちらを理由として報告するほうが挙動の説明として正確。
# lost ゲートが fire のときは下の分岐で CB を保留する（本算出は行わないわけではない）。
cb_reason=""
if [ "$cc" -ge "$max_cycles" ] 2>/dev/null; then
  cb_reason=max-cycles
elif [ "$trend_verdict" = fire ]; then
  cb_reason=divergence
fi

if [ "$lost_gate" = fire ]; then
  # increment しない（marker の cycle は永続 counter と一致 = INC=held）。
  # ITERATE_CB=ok を載せるのは既存 CB 表の fire 分岐に落とさないため。
  # review invoke は ITERATE_LOST_GATE 表が決める（本 marker の ok を「次 cycle 開始」と読まない）。
  # `--handoff` なしの set で直前 [fix:pushed] の継続 handoff を default-clear する。
  # `--cycle-count` は付けない（INC=held）。CB fire 分岐と同型。
  if fire_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set \
    --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
    --next "lost 修復ゲート発火 (JSON 欠落 lost=$trend_lost)" 2>&1); then
    handoff_clear=ok
  else
    handoff_clear=failed
    echo "WARNING: lost 修復ゲート発火時の handoff クリアに失敗（handoff が残り Stop hook が /rite:pr-review を再注入してゲートを迂回する恐れ）" >&2
  fi
  [ -n "$fire_out" ] && printf '%s\n' "$fire_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  marker_emit ITERATE_LOST_GATE fire "lost=$trend_lost" "cycle=$cc" "max=$max_cycles" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=held" "HANDOFF_CLEAR=$handoff_clear"
  marker_emit ITERATE_CB ok "cycle=$cc" "max=$max_cycles" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=held"
elif [ -n "$cb_reason" ]; then
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
  # 共有前段が WARNING として表示する）。stderr は捨てずに変数へ受けて表示する。
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
  marker_emit ITERATE_LOST_GATE ok "lost=$trend_lost" "cycle=$cc" "max=$max_cycles" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=none"
  marker_emit ITERATE_CB fire "cycle=$cc" "max=$max_cycles" "CB_REASON=$cb_reason" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "HANDOFF_CLEAR=$handoff_clear"
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
  marker_emit ITERATE_LOST_GATE ok "lost=$trend_lost" "cycle=$new_cc" "max=$max_cycles" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=$inc_status"
  marker_emit ITERATE_CB ok "cycle=$new_cc" "max=$max_cycles" \
    "TREND=$trend_series" "TREND_VERDICT=$trend_verdict" "TREND_REASON=$trend_reason" \
    "LOST=$trend_lost" "RUN_SINCE_USED=$run_since_used" "INC=$inc_status"
fi
```

| `ITERATE_LOST_GATE` | アクション |
|---------|-----------|
| `ok` | 穴なし。既存の `ITERATE_CB` 表へ |
| `fire` | 次 cycle の review を開始しない（`INC=held` = 永続 counter も marker の `cycle=` も据え置き）。下記 (a)/(b) へ。`ITERATE_CB=ok` は CB fire 回避用であり、次 cycle 開始を意味しない |

| 分岐 | 条件 | アクション |
|---------|-----------|
| (a) | 直前 cycle のレビュー結果がセッションコンテキストに残存 | pr-review ステップ 6.1.a と同じ手順（timestamp sentinel + Write tmpfile + `bash {plugin_root}/hooks/review-result-save.sh --pr {pr_number} --content-file <tmp>`）で即時保存。**成立は `JSON_SAVED=true`（helper の値域。`=1` ではない）**。成立なら下の `ITERATE_LOST_REPAIR=saved` を emit して**ステップ 1 の bash を再実行**。失敗は (b) |
| (b) | 残存しない / (a) 失敗 | 下の `ITERATE_LOST_REPAIR=rereview` を emit し、counter 不前進のまま `/rite:pr-review` を invoke。**保存成立の観測子は `JSON_SAVED=true` または `REVIEW_SAVE_JSON_OK=1`**（`[review:mergeable]` 素通しは batch が収束扱いするので使わない）。不成立は `ITERATE_LOST_REPAIR=failed` を emit し、iterate 失敗形で停止（新 CB sentinel は作らない。caller の既存「sentinel 不在 / `[review:error]` → 失敗停止」に倒す）。成立ならステップ 2 |

```bash
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }
marker_emit ITERATE_LOST_REPAIR "{repair}" "cycle={cycle_count}" "lost={lost}"
```

`{repair}` は `saved` / `rereview` / `failed`。`failed` は (b) 後に `JSON_SAVED=true` も `REVIEW_SAVE_JSON_OK=1` も無いときだけ emit する。`{cycle_count}` はゲート発火時の `cycle=`（increment 前の永続値）。`{lost}` は同 marker の `lost=`。

| `ITERATE_CB` marker | アクション |
|---------|-----------|
| `ok` かつ `ITERATE_LOST_GATE=ok` | 発火条件のいずれにも該当せず。counter を +1 済。`/rite:pr-review` を invoke（下記）してステップ 2 へ |
| `ok` かつ `ITERATE_LOST_GATE=fire` | 上の lost-gate 表。(b) 以外で pr-review を invoke しない |
| `fire` | 発火（`CB_REASON` に理由）。**review を invoke せず** サーキットブレーカー（ステップ 6）へ直行（mergeable 判定済 PR には発火しない = ステップ 2 で先に `[review:mergeable]` 終了するため到達しない。lost-gate が fire のときは本行に到達しない） |

`CB_REASON` は発火理由で、ステップ 6.2 の停止通知の「理由」行を決める（sentinel 自体は理由に依らず不変 — ステップ 6 参照）:

| `CB_REASON` | 意味 |
|---|---|
| `divergence` | 収束トレンドが発散と判定された（`cycle_count < max_review_cycles` でも発火する）。無駄な cycle を早期に切る主経路 |
| `max-cycles` | `cycle_count >= max_review_cycles`。発散判定をすり抜けた非収束を受け止める保険（既定 15 では 16 cycle 以上を要する収束中の run にも届く。両方成立する場合もこちらを理由として報告する） |

`TREND_VERDICT` は**両分岐に載る**トレンド判定の診断値。`ok`（収束中・下降中）/ `fire`（発散）/ `insufficient`（データ不足・データ異常で判定不能）/ `unavailable`（helper 自体を実行できなかった）を取る。`insufficient` / `unavailable` は発火しない側へ倒れ、`max_review_cycles` が従来どおり backstop として働く。**`fire` 分岐にも載せる**のは、`CB_REASON=max-cycles` で停止したときに発散判定が下りていたのか未実施だったのかをステップ 6.2 が読み分ける必要があるため（下記 `TREND_REASON` と組で使う）。

`TREND_REASON` は helper が返した `reason=` の値で、**判定が下りなかったときにその理由を運ぶ唯一の経路**。helper は理由を stdout の `reason=` に載せるため、ここで抽出して marker に載せないと呼び出し側からは消える。主な値: `need_3_cycles`（現 run の結果が 3 件に満たない。全 run が cycle 2〜3 で必ず通る正常系）/ `no_file_after_pin`（run 開始点 pin より新しい結果が 0 件。**再実行直後の 1 cycle 目は正常系**で、全面不作動を疑うのは helper が stderr WARNING を併発したとき = `cycle_count>=1`）/ `run_boundary_unresolved`（実在数が `cycle_count` を超え、他 run の結果が混ざっている。pin が無い / 古い。誤発火を避けて判定を降ろした状態で、`RUN_SINCE_USED` が原因を示す）/ `no_results_file`・`results_dir_missing`（結果ディレクトリ自体を読めない = 発散検出の全面不作動。cycle_count>=1 なら helper が stderr にも WARNING を出す）/ `json_parse_failure`・`schema_version_unknown`・`scope_enum_violation`・`pr_number_mismatch`・`blocking_count_failed`（データ異常。いずれも helper の stderr WARNING に詳細）/ `helper_unavailable`（helper 自体を実行できなかった。上記 WARNING が対）/ 判定が下りた場合は `converging_or_descending`・`no_new_minimum_and_not_descending`。

`ITERATE_CB=ok` かつ `ITERATE_LOST_GATE=ok` のとき `/rite:pr-review` を invoke:

```text
skill: rite:pr-review
args: "{pr_number}"
```

---

## ステップ 2: review sentinel を判定

| Sentinel | アクション |
|---------|-----------|
| `[review:mergeable]` | ステップ 5.S（NB digest sweep。完了通知の前） |
| `[review:fix-needed:N]` | ステップ 3 (fix invoke) へ |
| `[review:error]` | 可逆な再試行を推奨として 1 回だけ自動実行し、work memory の既存決定事項へ理由を記録する。再失敗なら停止 |
| sentinel 不在 | 可逆な再試行を推奨として 1 回だけ自動実行し、期待 sentinel と直近出力を既存 work memory へ記録する。再度不在なら停止 |

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
| `[fix:sweep-done]` | ステップ 5（完了通知）。**ステップ 1 に戻らない**（再フルレビュー禁止） |
| `[fix:pushed-wm-stale]` | ステップ 1 に戻る (WM stale 警告は表示するが loop は継続。上限チェックはステップ 1 が実施) |
| `[fix:replied-only]` | **ループ終了**（reply のみで完結） |
| `[fix:cancelled-by-user]` | **ループ終了**（ユーザーが fix.md 内 cancel 経路 — ステップ 1.4 Cancel option / Fast Path Cancel handoff 等 — で中止選択。`/rite:recover` で再開可） |
| `[fix:error]` | 可逆な再試行を推奨として 1 回だけ自動実行し、work memory の既存決定事項へ理由を記録する。再失敗なら停止 |
| sentinel 不在 | 可逆な再試行を推奨として 1 回だけ自動実行し、期待 sentinel・直近の fix 出力 100 行・flow-state phase を既存 work memory へ記録する。再度不在なら停止 |

> `--nb-sweep` 経由の戻りは本表を使わない。5.S 専用表（ステップ 1 に戻らない）だけを使う。

---

## ステップ 5.S: NB digest sweep

`[review:mergeable]` 到達後・完了通知前に **1 回**。対象 0 件は no-op（fix を invoke しない）。同一 PR の本 run で 2 回 invoke しない。silent skip 禁止。Stop hook が mergeable FINALIZE で完了通知を求めても、5.S 未実施なら先に本ステップを実行する。
rationale: references/rationale.md#nb-sweep-step

会話の `[CONTEXT] ITERATE_NB_SWEEP=done|noop` は観測用。skip 判定はファイル存在のみ（下の bash）。marker 既出でも bash を省略しない。

```bash
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; echo "[iterate:nb-sweep-error]"; exit 1; }
nb_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || nb_root=""
if [ -z "$nb_root" ]; then
  echo "ERROR: state-path-resolve が空を返した。NB sweep 対象を取得できない" >&2
  marker_emit ITERATE_NB_SWEEP failed "reason=state_root_unresolved"
  echo "[iterate:nb-sweep-error]"
  exit 1
fi
nb_done_file="$nb_root/.rite/state/nb-sweep-done-{pr_number}.txt"
if [ -f "$nb_done_file" ]; then
  skipped_kind=$(head -1 "$nb_done_file" | tr -d '[:space:]')
  case "$skipped_kind" in
    done|noop) ;;
    *) skipped_kind=done ;;
  esac
  marker_emit ITERATE_NB_SWEEP skipped "reason=already_done" "kind=$skipped_kind"
else
collect_err=$(mktemp "${TMPDIR:-/tmp}/rite-nb-sweep-collect-XXXXXX") || { echo "ERROR: mktemp failed" >&2; echo "[iterate:nb-sweep-error]"; exit 1; }
collect_out=$(bash {plugin_root}/hooks/scripts/nb-sweep-collect.sh --pr {pr_number} --state-root "$nb_root" 2>"$collect_err") || collect_rc=$?
collect_rc=${collect_rc:-0}
cat "$collect_err" >&2
rm -f -- "$collect_err"
status=$(printf '%s' "$collect_out" | jq -r '.status // empty' 2>/dev/null) || status=""
count=$(printf '%s' "$collect_out" | jq -r '.count // empty' 2>/dev/null) || count=""
case "$collect_rc:$status" in
  0:empty)
    mkdir -p "$nb_root/.rite/state" || true
    source {plugin_root}/hooks/gitignore-ensure.sh
    if ! _ensure_dir_gitignore "$nb_root/.rite/state"; then
      echo "WARNING: $nb_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
      [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
    fi
    if ! printf 'noop\n' > "$nb_done_file"; then
      echo "WARNING: nb-sweep-done marker を書けませんでした ($nb_done_file)。次回 5.S は再実行されます" >&2
      rm -f "$nb_done_file"
    fi
    marker_emit ITERATE_NB_SWEEP noop "count=0"
    ;;
  0:ok)
    marker_emit ITERATE_NB_SWEEP pending "count=${count:-}"
    ;;
  *)
    echo "ERROR: NB sweep collect failed (rc=$collect_rc status=${status:-})" >&2
    marker_emit ITERATE_NB_SWEEP failed "rc=$collect_rc" "status=${status:-}"
    echo "[iterate:nb-sweep-error]"
    exit 1
    ;;
esac
fi
```

| `ITERATE_NB_SWEEP` | アクション |
|---|---|
| `skipped` | ステップ 5（完了通知）。collect / fix を invoke しない |
| `noop` | ステップ 5（完了通知）。fix を invoke しない |
| `pending` | `/rite:fix --nb-sweep` を invoke |
| `failed` | `[iterate:nb-sweep-error]` で停止。完了通知へ進まない |

`pending` のとき:

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase fix --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "NB digest sweep"
```

```text
skill: rite:fix
args: "--nb-sweep {pr_number}"
```

`--nb-sweep` の戻りはステップ 4 の汎用表を使わず、ステップ 1 に戻らない:

| Sentinel | アクション |
|---------|-----------|
| `[fix:sweep-done]` | ステップ 5（完了通知）。ステップ 1 に戻らない |
| `[fix:error]` / その他 / sentinel 不在 | `[iterate:nb-sweep-error]` で停止。完了通知へ進まない |

fix が emit した `[CONTEXT] NB_SWEEP_RESULT=done; issued=K; recorded=M` を読み、`ITERATE_NB_SWEEP=done` を同カウントで emit する。ファイル未作成なら書く:

```bash
nb_root=$(bash {plugin_root}/hooks/state-path-resolve.sh) || nb_root=""
nb_done_file="$nb_root/.rite/state/nb-sweep-done-{pr_number}.txt"
if [ -n "$nb_root" ] && [ ! -f "$nb_done_file" ]; then
  mkdir -p "$nb_root/.rite/state" || true
  source {plugin_root}/hooks/gitignore-ensure.sh
  if ! _ensure_dir_gitignore "$nb_root/.rite/state"; then
    echo "WARNING: $nb_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
    [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
  fi
  if ! printf 'done\n' > "$nb_done_file"; then
    echo "WARNING: nb-sweep-done marker を書けませんでした ($nb_done_file)" >&2
    rm -f "$nb_done_file"
  fi
fi
```

その後ステップ 5 へ。

MUST NOT: 同一 PR で 5.S を 2 回走らせる。sweep でコードを修正・commit・push する。

---

## ステップ 5: 完了通知

> **構造的保証**: 終了 sentinel (`[fix:sweep-done]` / `[review:mergeable]` 経由 5.S 完了 / `[fix:replied-only]` / `[fix:cancelled-by-user]`) 到達時、sub-skill が `FINALIZE:...` handoff をセットしており、`Stop` hook が本ステップの完了通知を出力せず turn を終えようとする停止を **1 回だけ** 差し戻す。`[review:mergeable]` 単体では完了通知へ進まない（5.S が先）。詳細は「ループ継続・終了の構造的保証」節を参照。完了通知は必ず出力すること。

### ステップ 5.0: 一時残骸の最終回収 (terminal cleanup)

完了通知を出力する**前に**、本ループが残した一時ブランチ・worktree を回収する。本ループの終端で明示的に発火させ、回収の到達性を担保する (AC-2)。non-blocking — 失敗してもループ完了を妨げない (AC-5):
rationale: references/rationale.md#terminal-cleanup-age-guard

```bash
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

これは正常終了・ユーザー中断の**両経路**で実行する (どちらの出口でも残骸の累積を防ぐ)。出力 status 行 (`[pr-cycle-cleanup] status=...`) はそのまま表示し、何を回収したかを可視化する。

> **24h age guard**: 直前に作った若い `rite-review-mutation-*` / `rite-revert-test-*` detached worktree はこの発火では消えず、次回 cleanup (24h 経過後) で回収される。即時 0 残骸ではなく **確実な最終回収**。

### ステップ 5.0.1: run を閉じる (cycle counter のリセット)

完了通知を出力する**前に**、`cycle_count` を 0 にして run を明示的に閉じる。これをしないと終了 3 経路
（`[review:mergeable]` / `[fix:replied-only]` / `[fix:cancelled-by-user]`）はいずれも counter を残したまま
終わり、**同じ PR に対する次の `/rite:iterate` が resume と判定され、ステップ 0.6 の pin 更新に入らない**。
非ブロッキング — 失敗しても完了通知は出す。

**`--handoff` は既存値を読んで載せ直す**（省略すると handoff キーが消え、ステップ 5 冒頭の FINALIZE 差し戻し保証が通知前に失われる）。
**`--phase` も現在値を維持する**（ハードコードすると中断通知の「phase=fix のため fix invoke から再開」が偽になる）。
rationale: references/rationale.md#run-close-reset

```bash
# 診断スニペット用 helper（ステップ 0.6 (0) / ステップ 1 と同型。Bash tool 呼び出し間でシェル状態は
# 引き継がれないため独立に読み込む）。
source {plugin_root}/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# marker の emit / 照合の共有関数（ステップ 0 / 0.6 / 1 と同型）。
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

close_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default review) || close_phase=review
close_handoff=$(bash {plugin_root}/hooks/flow-state.sh get --field handoff --default "") || close_handoff=""
if [ -n "$close_handoff" ]; then
  close_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set \
    --phase "$close_phase" --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
    --next "run 終了 (cycle counter reset)" --cycle-count 0 --handoff "$close_handoff" 2>&1); close_rc=$?
else
  close_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set \
    --phase "$close_phase" --issue {issue_number} --branch "{branch_name}" --pr {pr_number} \
    --next "run 終了 (cycle counter reset)" --cycle-count 0 2>&1); close_rc=$?
fi
if [ "$close_rc" -eq 0 ]; then
  run_close=ok
else
  run_close=failed
  echo "WARNING: 完了時の cycle counter リセットに失敗しました。次回 /rite:iterate が resume と判定され、run 開始点 pin が更新されないまま前 run の結果を読みます。残存 counter が上限以上なら次回起動は review を 1 度も回さずに発火します" >&2
fi
[ -n "$close_out" ] && printf '%s\n' "$close_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
marker_emit ITERATE_RUN_CLOSE "$run_close" "phase=$close_phase"
```

| `ITERATE_RUN_CLOSE` | 意味 |
|---|---|
| `ok` | counter を 0 にして run を閉じた。次回起動は fresh entry となり pin が更新される |
| `failed` | リセットに失敗。次回起動は resume 判定となり前 run の pin を引き継ぐ（WARNING 済み）。`/rite:recover` で再開する前に手動で `--cycle-count 0` を打つとよい |

### ステップ 5.0.2: 未処理 non-blocking 件数（`[review:mergeable]` 完了通知用）

5.S overlay。残件欄は **0 件固定**（JSON の `non_blocking_findings[]` は消化前の値のまま残るので数えない）。取得失敗は 5.S で `[iterate:nb-sweep-error]` 停止済みでここへ来ない。
rationale: references/rationale.md#nb-remaining-notice

```bash
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }
marker_emit ITERATE_NB_REMAINING 0 "status=ok" "record=" "by_severity=" "overlay=sweep"
```

| 5.S marker | 完了通知 |
|---|---|
| `ITERATE_NB_SWEEP=noop` | 0 件テンプレ。消化内訳行は出さない（AC-4） |
| `ITERATE_NB_SWEEP=done`（`NB_SWEEP_RESULT=done`） | 0 件テンプレ + `- sweep: issued={sweep_issued} / recorded={sweep_recorded}` |
| `ITERATE_NB_SWEEP=skipped` | ファイル 1 行目が `noop` なら 0 件テンプレ（digest 行なし）。`done` なら 0 件テンプレ + digest 行（件数が取れなければ 0） |
| `ITERATE_NB_SWEEP=failed` | 到達不能（5.S で停止） |

非 0 件テンプレ / 「取得失敗」テンプレは overlay 後到達不能。

### 正常終了 (`[review:mergeable]`)

`[review:mergeable]` sentinel 文字列は変えない。

**0 件** (`ITERATE_NB_SWEEP=noop`):

```
## /rite:iterate 完了

- PR: #{pr_number}
- 終了理由: review:mergeable
- ブランチ: {branch_name}
- 未処理 non-blocking: 0 件

次のステップ:
- Ready 化: /rite:ready {pr_number}
- マージ (Ready 後): /rite:merge {pr_number}

flow-state は phase={review|fix} のままです。`/rite:ready` 実行時に phase=ready に遷移します。
```

**0 件 + digest** (`ITERATE_NB_SWEEP=done`):

```
## /rite:iterate 完了

- PR: #{pr_number}
- 終了理由: review:mergeable
- ブランチ: {branch_name}
- 未処理 non-blocking: 0 件
- sweep: issued={sweep_issued} / recorded={sweep_recorded}

次のステップ:
- Ready 化: /rite:ready {pr_number}
- マージ (Ready 後): /rite:merge {pr_number}

flow-state は phase={review|fix} のままです。`/rite:ready` 実行時に phase=ready に遷移します。
```

### 正常終了 (`[fix:replied-only]`)

```
## /rite:iterate 完了

- PR: #{pr_number}
- 終了理由: fix:replied-only
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

> **停止 invariant**: 発火後は review / fix を invoke せず、停止 sentinel と通知を出して終了する。発火そのものから Ready / merge へ直行する分岐は存在しない。counter reset は次の明示的な再実行を可能にする処理であり、この起動でループを再開する許可ではない。
rationale: references/rationale.md#circuit-breaker-stop-invariant

ステップ 1 で `ITERATE_CB=fire`（収束トレンドの発散 or `cycle_count >= max_review_cycles`。理由は同 marker の `CB_REASON`）となったときのみ到達する。**発火理由は本ステップの停止構造を変えない** — 変わるのは 6.1 / 6.2 の「理由」行の文面とトレンド推移だけである（sentinel・handoff 契約・counter reset は不変）。batch / 対話は **自セッションの** run-queue（`run-queue-{session_id}.json`）から判定する。**`active == true` かつ** cursor の Issue が本 iterate の対象と一致すれば batch（read-only。`{issue_number}` はステップ 0 の marker 値をリテラル置換）:
rationale: references/rationale.md#cb-mode-and-reset

```bash
# 診断スニペット用 helper（ステップ 0.6 (0) と同型 — 縮退時の WARNING 告知まで含めて同じ）。
source {plugin_root}/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi
# marker の emit / 照合の共有関数（ステップ 0 / 0.6 / 1 / 5.0.1 と同型）。
source {plugin_root}/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした（プラグインの破損 / 版 skew）。marker を emit できないため中止します" >&2; exit 1; }

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
# リセットしないと再実行が即再発火してループを再開する術が無くなる。発火済みを `cycle_count` の
# 相対値（例: max + 1）で符号化する設計は採らない — max_review_cycles が invocation 間で変わると
# 符号化が両方向に破綻するため、上限値から独立した文字列の `stop_reason` を下の同一 set で記録する。
# `--handoff` を伴わないため、ステップ 1 fire 分岐が消した handoff はクリアされたまま維持される。
# 失敗は共有前段の WARNING に載せる。失敗すると counter が上限のまま残り再実行が即再発火する
# （= 停止通知が約束する「再実行すれば新しい run として cycle 1 から回る」が偽になる）ため、
# ステップ 6.2 がこれを読んで注意行 (b) を出し分ける。
# `--stop-reason`は「発火した」という事実の durable な記録で、次セッションの
# `session-start.sh` がブレーカー失敗停止と Ctrl+C 中断を区別するために読む。**counter reset と同じ
# set に載せる**のが要点で、ステップ 1 の fire 分岐に書いても本 set（`--stop-reason` なし）が
# default-clear で消してしまう。ここに置くことで、上のコメントが言う「前段〜sentinel 間で turn が
# 終わる窓」でも発火の記録だけは残る（従来はこの窓で counter が 0 に戻り発火が無記録だった）。
# `{cb_reason}` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=`（`max-cycles` / `divergence`）を
# リテラル置換する。**上限値そのものは埋めない** — `max_review_cycles` は invocation ごとに config から
# 読み直されるため、state に焼くと設定変更で符号化が破綻する（counter reset を選んだのと同じ理由）。
if cb_reset_out=$(LC_ALL=C bash {plugin_root}/hooks/flow-state.sh set \
  --phase review --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "サーキットブレーカー発火: 停止通知を出し、明示的な /rite:iterate 再実行を待つ" --cycle-count 0 \
  --stop-reason "circuit-breaker:{cb_reason}" 2>&1); then
  :
else
  echo "WARNING: サーキットブレーカー発火時の cycle counter リセットと stop_reason 永続化に失敗（counter が上限のまま残り、次セッションでは通常の中断と区別できない）" >&2
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
marker_emit ITERATE_CB_MODE "$cb_mode" "issue={issue_number}" "pr={pr_number}" \
  "SESSION_ID=$session_id" "STATE_ROOT=$state_root"
```

共有前段の atomic set が失敗した場合は、その WARNING（`サーキットブレーカー発火時の cycle counter リセットと stop_reason 永続化に失敗`）を停止通知の注意行判定に使う。`ITERATE_CB_MODE` は停止先の選択だけを担い、成功・失敗によってループへ戻らない。

| `ITERATE_CB_MODE` | アクション |
|---|---|
| `batch` | ステップ 6.1（failed sentinel emit）|
| `interactive` | ステップ 6.2（機械的停止通知）|

**両分岐は挙動として同構造**（failed 記録 + draft 残し + 停止通知 + handoff クリア維持 + 共有前段での cycle counter reset。人間への問い合わせは行わない）。差は次の 2 点だけ:

1. **sentinel の消費者**: `[iterate:max-cycles-reached]` は `/rite:batch-run` が grep して当該 Issue を `failed[]` に記録し次 Issue へ進む。`[iterate:max-cycles-stopped]` は消費者を持たない iterate 内部完結の最終状態表示。
2. **`REFIRE=1` / 共有前段の atomic set 失敗 注意行の有無**: ステップ 6.2（対話）のみが持つ。6.1（batch）は対称化しない。

**失敗停止の理由は両モードで永続化する** — 共有前段の reset 成功後は `stop_reason=circuit-breaker:{cb_reason}` を同じ atomic set で残す。`stop_reason` は後続の通常 `flow-state.sh set` が default-clear する。

どちらの経路もマージには到達しない（上記 invariant）。

STATE_ROOT が `unresolved` の場合は両モードの停止通知に「状態ファイルの更新先を確認できません。チェックアウト内で state root を解決してから状態を確認してください」を添える。停止 sentinel は省略しない。

### ステップ 6.1: バッチ実行 — failed sentinel

review を回さず、当該 Issue を非収束（failed）として `/rite:batch-run` に返す。`/rite:batch-run` はこの sentinel を受けて当該 Issue を failed 記録し、次の Issue へ進む（ready/merge/cleanup はスキップ、draft/open PR はレビュー待ちで残す）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない（`[fix:error]` が set で handoff をクリアして clean terminal になるのと同じ。以降は run の flat 構造 + HTML hint で継続）:

```
## /rite:iterate サーキットブレーカー発火（バッチ）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: {fire_reason_line}
- blocking 推移: {trend}
- 措置: 当該 Issue を failed 扱いとし、draft/open PR をレビュー待ちで残します（`/rite:batch-run` が残りキューを続行、最終 Issue なら完了通知へ）

再開方法: /rite:iterate {pr_number} を明示的に再実行する（fresh entry として run 開始点を更新し full scope から始める）。

<!-- [iterate:max-cycles-reached] -->
```

`{fire_reason_line}` / `{trend}` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=` / `TREND=` からリテラル置換する（`{max_review_cycles}` はステップ 0.6 の `ITERATE_CYCLE_MAX=`。置換表は 6.2 と共通で、下記「発火理由の文面」を参照）。

**sentinel は発火理由に依らず `[iterate:max-cycles-reached]` のまま**。`/rite:batch-run` はこの literal を grep して当該 Issue を `failed[]` に記録し cursor を前進させるため、理由別に sentinel を分けると batch が停止を検出できなくなる（sentinel 契約は不変に保つ）。理由の区別は上記「理由」行が担う。

制御を `/rite:batch-run` に戻す（run 側で cursor 前進）。

### ステップ 6.2: 対話実行 — 機械的停止

`AskUserQuestion` は**使わない**。当該 PR を非収束（failed）として機械的に記録し、draft/open PR をレビュー待ちで残して停止する。6.1（batch）と同構造であり、品質ゲートの履行を人間の裁量に委ねない（発火は失敗であって、人間に選ばせて counter をリセットし続行できる例外を作らない）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない。

下記の停止通知を出力してループを終了する（`{max_review_cycles}` 等はリテラル置換する）:

```
## /rite:iterate サーキットブレーカー発火（対話・停止）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: {fire_reason_line}
- blocking 推移: {trend}
- 措置: 当該 PR を非収束として失敗記録し、draft/open PR をレビュー待ちで残します（マージには進みません）

再開方法:
- ループを再開する: /rite:iterate {pr_number} を明示的に再実行する（cycle counter と run 開始点が
  リセットされ、新しい run として cycle 1 を full scope で回る。再び発散すればブレーカーは上限を待たずに
  再発火する）。/rite:recover 経由の再開も同じ経路
- Ready 化して人間のレビューに委ねる: /rite:ready {pr_number}

<!-- [iterate:max-cycles-stopped] -->
```

#### 発火理由の文面（6.1 / 6.2 共通の置換表）

`{fire_reason_line}` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=` で決める。`{trend}` は同 marker の `TREND=` の値（カンマ区切りの per-cycle blocking 件数）をそのまま使い、`→` 区切りへ整形して表示する（例: `TREND=3,7,7,4` → `3 → 7 → 7 → 4`）。**この推移行は省略しない**。

`max-cycles` の文面は **`TREND_VERDICT` で分岐する**（上限到達と発散判定は独立に成立しうる）:
rationale: references/rationale.md#notice-trend-and-notes

| `CB_REASON` | `TREND_VERDICT` | `{fire_reason_line}` |
|---|---|---|
| `divergence` | （必ず `fire`） | `review⇄fix ループの収束トレンドが発散（直近サイクルで過去の最良水準へ戻れず、下降もしていない）` |
| `max-cycles` | `ok` | `review⇄fix cycle が上限 {max_review_cycles} に到達（発散判定は実行され、発散ではないと結論）` |
| `max-cycles` | `fire` | `review⇄fix cycle が上限 {max_review_cycles} に到達（収束トレンドの発散も同時に検出）` |
| `max-cycles` | `insufficient` / `unavailable` | `review⇄fix cycle が上限 {max_review_cycles} に到達（発散判定は未実施 — {trend_reason}）` |

`{trend_reason}` はステップ 1 の `TREND_REASON=` marker の値をそのままリテラル置換する（`need_3_cycles` / `no_results_file` / `helper_unavailable` 等。値の一覧はステップ 1 の `TREND_REASON` 説明を参照）。

**`- blocking 推移:` 行の差し替え条件は `TREND_VERDICT` であって `TREND=` の空判定ではない。** `TREND_VERDICT` が `ok` / `fire` 以外のときは、推移行を次へ差し替える:

```
- blocking 推移: 判定未実施（{trend_reason}）
```

**行ごと省略してはならない**。`TREND_VERDICT` が `ok` / `fire` のときは `TREND=` の値を `→` 区切りで整形して表示する。

**`LOST` が `0` 以外のときは推移行に欠落を併記する**（例: `- blocking 推移: 5 → 9 → 9（1 cycle 分の結果が欠落）`）。**差し替えと併記は同時に成立しうる**。その場合は**差し替えを先に行い、差し替えた行に併記する**: `- blocking 推移: 判定未実施（need_3_cycles・1 cycle 分の結果が欠落）`。

#### 注意行（ステップ 6.2 のみ）

以下の (a) / (b) / (c) と「再開方法」第 1 bullet の差し替えは **ステップ 6.2（対話）専用**。上記「発火理由の文面」の置換表までが 6.1 / 6.2 共通である。

ステップ 0.6 / ステップ 1 の `[CONTEXT]` marker と **ステップ 6 共有前段**の WARNING を観測している場合、下記の条件で「理由」行の直後に注意行を追加する。3 ステップすべてを観測対象に含める — (b) は共有前段の atomic set 失敗 WARNING、(c) の `HANDOFF_CLEAR` はステップ 1。marker 値の読み取りは `marker_get`（[`lib/context-marker.sh`](../../hooks/scripts/lib/context-marker.sh)）の契約に従う。**marker 値の照合**は `;` 区切りの `KEY=VALUE` 単位の**完全一致**（部分一致は禁止）。注意行と差し替え行の `{plugin_root}` / `{pr_number}` / `{max_review_cycles}` / `{session_id}` / `{state_root}` はリテラル置換する（値が得られない側は (b) の pre-fill 表で解決手順へ置き換える）。**置換の対象は (b) が人間へ渡すすべての実行可能テキスト**に及ぶ。人間の端末で live なシェル変数を前提にした記法（`$root` 等）は、同じ案内文の中で代入している箇所以外では使わない。

**(a) `REFIRE=1`**（この起動では review を 1 回も回さずに発火した。前回の最終 cycle 途中で中断した場合の正常な発火と、counter リセット失敗による再発火の**両方**を含む — marker だけでは区別できない）:

```
- 注意: 起動時点で cycle counter が上限に達していたため、この起動では review を 1 回も回さずに発火しました（前回の最終 cycle 途中で中断していた場合はこれが正常な発火です）。ステップ 0.6 / ステップ 1 / ステップ 6 共有前段に WARNING が出ている場合は、その直後の flow-state.sh の診断を確認してください
```

`REFIRE=0` では**追加しない**。`RESET` の値は本条件に使わない — 即再発火の判定には `REFIRE` を使う。

**(b) 共有前段の atomic set 失敗**（ステップ 6 共有前段の atomic set に失敗し、counter のリセットと `stop_reason` の永続化がどちらも行われなかった）:

```
- 注意: 発火時の cycle counter リセットと `stop_reason` の永続化に失敗しました。**このまま再実行しても counter と run 開始点が更新されず即再発火し、次セッションの案内ではこの失敗停止を通常の中断と区別できません**（`max-cycles` 発火なら counter が上限のまま、`divergence` 発火なら counter が 0 に戻らずステップ 0.6 の pin 更新経路に入らないため helper が同じ列を読み直します）。次のコマンドで手動リセットしてから再実行してください（`--handoff` を伴わないため handoff のクリアも兼ねます）: `RITE_STATE_ROOT="{state_root}" bash "{plugin_root}"/hooks/flow-state.sh set --session {session_id} --phase review --next "cycle counter 手動リセット" --cycle-count 0`
```

`{state_root}` / `{session_id}` は marker の値で pre-fill する。**2 つは独立軸**で、どちらも「値が得られない」ことがある（`_resolve_session_id` は `STATE_ROOT` に依存しないため、state root が未解決でも session_id は判明している側が支配的）。**得られた側は必ず埋め、得られなかった側だけを解決手順に置き換える** — 判明している値を捨てて人間に探索させない:

| marker | コマンドに入れるもの |
|---|---|
| `STATE_ROOT=<実パス>` | `RITE_STATE_ROOT="<実パス>"` をそのまま埋める |
| `STATE_ROOT=unresolved` | 埋めず、代わりにこう案内する: 「**リポジトリのチェックアウト内で** `root=$(bash "{plugin_root}"/hooks/state-path-resolve.sh)` を実行し、`RITE_STATE_ROOT="$root"` として使ってください（repo 外の cwd では resolver が cwd を返して空振りします。`git rev-parse --show-toplevel` で代用しないこと — linked worktree では worktree root を返し、resolver が行う main checkout への unify が効きません）」 |
| `SESSION_ID=<実 UUID>` | `--session <実 UUID>` をそのまま埋める |
| `SESSION_ID=`（空） | 埋めず、代わりにこう案内する: 「`{state_root}/.rite/sessions/` の各 `*.flow-state` から `pr_number` が {pr_number} **かつ `cycle_count` が 1 以上**のものを探して `--session` に補ってください（**同一 `pr_number` の state が複数残ることがある**ため、複数該当したら `updated_at` が最新のものを採ります。`updated_at` まで同値で並ぶ場合は `next_action` が「サーキットブレーカー発火」で始まる方を採ります）」。**`cycle_count` を `max_review_cycles` と比較しないこと** — `divergence` 発火はステップ 1 が上限を先に評価する構造上つねに `cycle_count < max_review_cycles` で成立するため、上限との比較を条件にすると発散発火が残した state に対して解が空集合になり、この復旧手順そのものが行き止まりになる。**一方 `cycle_count >= 1` は両発火理由に共通で成立し**（`divergence` は `1 <= cc < max`、`max-cycles` は `cc == max`）、正常終了・fresh entry の state は 0 またはキー欠落なので、fail-safe を保ったまま候補を絞れる。**`{state_root}` が同時に未解決の場合のみ**、上表 `STATE_ROOT=unresolved` 行の案内で得た `$root` をこの位置に使う |

埋められない側は必ず上記の解決手順へ置き換える。

**実在確認をリセットコマンドの手前に置くこと**: `[ -f "{state_root}/.rite/sessions/{session_id}.flow-state" ]` が偽なら state root か session_id が誤っている。**この 2 トークンもリセットコマンド本体と同じく pre-fill する**（shell 変数 `$root` を書いてはならない — `root` を代入するのは上表 `STATE_ROOT=unresolved` 行の案内文だけ）。

handoff 迂回のリスクは (b) には含めない。迂回が成立するのは**両方の set が失敗したとき**だけなので、独立した条件 (c) として出す:

**(c) `HANDOFF_CLEAR=failed` かつ 共有前段の atomic set 失敗**（fire 分岐と共有前段の set が**どちらも**失敗し、継続 handoff が残存した）:

```
- 注意: 継続 handoff のクリアにも失敗しています。Stop hook が `/rite:pr-review` を再注入し、ブレーカーの cycle 判定を経由しないままレビュー/修正が続く可能性があります（再注入された `/rite:pr-review` は自身で次の handoff を張り直すため、モデルが `/rite:iterate` に戻るまで counter の制御外で進みます）。上記の手動リセットは handoff のクリアも兼ねるため、これを先に実行してください
```

`HANDOFF_CLEAR=failed` のみ（共有前段の atomic set 成功）では**追加しない** — 共有前段の set が 2 度目の default-clear として働き handoff は消えているため、迂回は起きない。

**(b) は注意行の追加だけでは足りない。** **(b) を観測したときは、テンプレートの当該 1 行を次の 1 行へ差し替えて出力する**（追加ではなく置換）:

```
- ループを再開する: 上記の手動リセットを実行してから /rite:iterate {pr_number} を再実行する
  （リセット前に再実行すると即座に再発火する）。/rite:recover 経由の再開も同じ経路
```

差し替える単位は**「再開方法」の第 1 bullet 全体** — `- ループを再開する:` で始まる行から、次に `- ` で始まる行が現れる直前までの全行 — であり、第 1 物理行だけを置き換えてはならない。**物理行数を数えて指定しないこと**。

(a) のみを観測した場合はこの差し替えを**行わない**。(a) / (b) / (c) は独立に評価し、観測したものを **(a) → (b) → (c) の順に**追加する。差し替えは (b) を観測した場合のみ行う。

---

## エラー時の方針

- ユーザーが Ctrl+C で中断した場合: flow-state に現 phase (review or fix) が残るので `/rite:recover` で本コマンドが再起動する (詳細な phase → command routing は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 5.3 を参照)
- `[fix:error]` 時: [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従い 1 回だけ自動再試行し、再失敗時は停止する
- reviewer が non-deterministic に振動する場合: 収束トレンドの発散または `safety.max_review_cycles` 到達でステップ 6 に進み、人間に問わず停止する。batch は `[iterate:max-cycles-reached]` で当該 Issue を failed 扱いにして次へ進み、対話は `[iterate:max-cycles-stopped]` で終了する。再開は `/rite:iterate {pr_number}` の明示的な再実行で行う。

---

## ループ継続・終了の構造的保証

継続点・終了点で sub-skill が one-shot handoff (`/rite:...` / `FINALIZE:{result}:{pr}`) を flow-state にセットし、turn 早期終了時は Stop hook (`stop-loop-continuation.sh`) が consume + prefix 分岐で停止を差し戻す。`[fix:error]` とサーキットブレーカー fire 分岐は handoff を持たない/能動クリアする (Stop hook は停止を許可)。機構の全体解説・sentinel → handoff 対応表・無限 block 防止の設計:
rationale: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism)

## 設計判断

- **blocking 指摘ゼロ（mergeable）到達が正常出口** — blocking の定義式は本ファイルに複製せず [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) を SoT とする。**非実測指摘が N 件残った状態でも `[review:mergeable]` に到達しうる** — 残存分の消化は完了通知前の 5.S（`/rite:fix --nb-sweep`）が担い、人間の draft レビューに委ねない。正常出口は未消化 0 件
- **ブレーカーの発火条件は「発散」であって「予算切れ」ではない** — 主経路は収束トレンドの発散検出、`safety.max_review_cycles`（既定 15）は backstop。**窓幅や閾値を config キーにしない**
- **発火理由は停止 routing を変えない** — sentinel（`[iterate:max-cycles-reached]` / `[iterate:max-cycles-stopped]`）は理由に依らず不変
- **発火後は停止** — batch は failed、対話は機械的に停止。再実行時の fresh entry が full scope を担う。
- **cycle counter は flow-state に保持** — 専用 state file は持たない。resume 跨ぎ継続（AC-3）、fresh entry で 0 リセット。発火直前（ステップ 6 共有前段）と正常終了時（ステップ 5.0.1）でも 0 に戻す
- 別 Issue 化経路は廃止済み — 「別 Issue にスキップして loop 終了」の抜け穴は塞がれている
rationale: references/rationale.md#design-decisions
