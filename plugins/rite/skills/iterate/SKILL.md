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

> 実行入口と工程境界は [Host Runtime Contract](../../references/host-runtime-contract.md#入口と工程境界)、native Skill / Task がない場合の実行は [Host workflow operations](../../references/host-workflow-operations.md) に従う。nested 呼出しは caller の runtime 選択を引き継ぐ。

> セッション worktree 入場後にシェルブロックがホストの隔離ガードに拒否されたら、[共通作業先契約](../../references/git-worktree-patterns.md#host-worktree-execution) の「入場後のガード拒否の退路」に従う。

> **質問規律**: すべての質問・再試行判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。
>
> 実行開始時は [Autonomous Execution](../rite-workflow/references/autonomous-execution.md) を適用する。

`/rite:pr-review` ↔ `/rite:fix` を **blocking 指摘ゼロ（mergeable）になるまでループ** する（blocking の定義は [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) が SoT。実測なし（`measured=false`）と判定された指摘は non-blocking として記録されたまま残存し、`[review:mergeable]` に到達しうる。残件は完了通知前の 5.S が消化し、正常出口は未消化 0 件）。ただし **サーキットブレーカー** を備え、reviewer の非決定的な振動や非収束 PR による無限ループを構造的に防ぐ。やることは以下のシーケンシャルなタスク列:

0. flow-state から issue_number / branch_name を復元
0.6. cycle counter を初期化（fresh は 0 にリセット / resume は継続）+ `safety.max_review_cycles` を読込・検証
1. lost 修復ゲート（前 cycle JSON 不在なら即時保存 or counter 不前進の再レビュー）→ 発火条件チェック（収束トレンドの発散 / `max_review_cycles` 到達）→ 不成立なら counter を +1 して `/rite:pr-review` を invoke / 成立なら サーキットブレーカー（ステップ 6）へ
2. review sentinel を判定（`[review:mergeable]` → ステップ 5.S / `[review:fix-needed:N]` → ステップ 3 / error・不在 → 1 回自動再試行、再失敗時は停止）
3. `/rite:fix` を invoke
4. fix sentinel を判定（通常ループ: `[fix:pushed]` → ステップ 1 に戻る / `[fix:non-fatal-only]` / `[fix:replied-only]` → ステップ 5.S / `[fix:sweep-done]` → 完了前確認 / `[fix:cancelled-by-user]` → 終了 / error・不在 → 1 回自動再試行、再失敗時は停止。`--nb-sweep` 経由は 5.S 専用表 — ステップ 1 に戻らない）
5.S. `[review:mergeable]` / `[fix:non-fatal-only]` / `[fix:replied-only]` 後の NB digest sweep（対象 0 は no-op。同一 review JSON で 2 回禁止。新しい JSON は再 sweep する）。成功後は完了前確認へ
5. 完了前確認のあと完了通知を出す（目的逸脱時は出さない）
6. （発火時のみ）サーキットブレーカー: counter と停止理由を記録し、batch は `[iterate:max-cycles-reached]`、対話は `[iterate:max-cycles-stopped]` と停止通知を出して終了する

**サーキットブレーカーの発火条件は 2 つ**:

- **収束トレンドの発散**（主経路）: 永続レビュー JSON の per-cycle blocking 件数から `hooks/scripts/review-trend-divergence.sh` が発散を機械判定する。「直近 2 値がともに過去の最良水準を超え、かつ下降中でもない」を発散とし、**収束中のループは本判定では殺されない**（cycle 数上限は別条件として下記 2. のとおり働く）
- **`safety.max_review_cycles`（既定 15）到達**（保険）: 発散判定をすり抜ける非収束を受け止める backstop。`cc >= max_cycles` は trend 判定と**独立した発火条件**。**16 cycle 以上を要する収束中の run は既定値のままでも本経路で停止する**
rationale: references/rationale.md#circuit-breaker-conditions

ブレーカー発火は review⇄fix ループの停止 signal である。`review_run` がある現在の run は counter・根因観測・見直し履歴・停止理由を保持して終了する。同じ run の再起動で履歴を消さない。review / fix は invoke しない。以下に残る counter reset と fresh entry の手順は `review_run` がない legacy state に限る。

保存済みレビューの [停滞診断](../../references/review-stagnation.md) は、実作業時間または根因再発を契機に修正方針を見直す。証跡欠損・権限拒否・既存 breaker を優先し、時間だけでは停止しない。見直し後の非収束はステップ 6 の既存停止 sentinel に合流する。

途中で止まったら flow-state に現 phase (review or fix) が残るので `/rite:recover` で再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number (required)
**Output**: 完了通知（`[review:mergeable]` / `[fix:non-fatal-only]` 到達後 5.S sweep 完了（外向きは `[review:mergeable]`）or `[fix:replied-only]` 到達後 5.S sweep 完了（外向きも返信のみ） or `[fix:cancelled-by-user]` 中断 or サーキットブレーカー発火による停止（`[iterate:max-cycles-reached]` バッチ / `[iterate:max-cycles-stopped]` 対話。非収束による失敗で、マージには進まない）or sweep 失敗 `[iterate:nb-sweep-error]` or 5.S 後の目的逸脱 `[review:error]` + `[CONTEXT] REVIEW_STOP=purpose_unaligned`（完了通知へ進まない） or Ctrl+C 中断）。発火後に review / fix は invoke しない。再開は `review_run` が無い legacy state では `/rite:iterate` の明示再実行、`review_run` がある停止はステップ 6.2 の `{resume_routes}`（通常の再実行では新 run にならない）。

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
| `{cb_reason}` | 停止理由の**生値**（`max-cycles` / `divergence`）。供給元は ステップ 1 の `[CONTEXT] ITERATE_CB=fire` marker の `CB_REASON=` と、`review_run` がある run の発散停止を記録した ステップ 3 の規則の 2 つ（同節「`{resume_routes}`」参照）。ステップ 6 共有前段が flow-state へ書く `--stop-reason "circuit-breaker:{cb_reason}"` と `{resume_routes}` の分岐で使う（人間向けの文面は `{fire_reason_line}` が担う） |
| `{trend}` | ステップ 1 の `[CONTEXT] ITERATE_CB=fire` marker の `TREND=`（カンマ区切りの per-cycle blocking 件数）。停止通知では `→` 区切りへ整形して表示する。空のときの扱いは ステップ 6.2「発火理由の文面」を参照 |
| `{trend_reason}` | ステップ 1 の `[CONTEXT] ITERATE_CB=` marker の `TREND_REASON=`（helper が返した判定不能の理由。ステップ 6.2「発火理由の文面」の `max-cycles` 分岐と推移行の差し替えで使う） |
| `{cycle_count}` | flow-state `cycle_count` field（review-start で増加。`review_run` がある同一 run では完了・停止・recoverでも保持。以下の 0 リセット手順は legacy state 専用） |
| `{resume_routes}` | ステップ 6.2 停止通知の「再開方法」の行。ステップ 3 の `[CONTEXT] ITERATE_STAGNATION=` marker と `{cb_reason}` から 同節「`{resume_routes}`」表で決める（marker 不在の行も同表が持つ） |
| `{state_root}` | ステップ 6 共有前段の `[CONTEXT] STATE_ROOT=` marker の値（`hooks/state-path-resolve.sh` の解決結果。未解決時は sentinel `unresolved`）。ステップ 6.2 注意行 (b) の手動リセットコマンドでのみ使い、値が得られないときは同節の pre-fill 表に従って解決手順へ置き換える |
| `{session_id}` | ステップ 6 共有前段の `[CONTEXT] SESSION_ID=` marker の値（`flow-state.sh path` の basename）。用途と未解決時の扱いは `{state_root}` と同じ |
| `{nb_count}` | ステップ 5.0.2 の `ITERATE_NB_REMAINING` marker 値（overlay 後は 0。取得失敗は 5.S で停止しここへ来ない） |
| `{nb_record}` | 同 marker の `record=`（review JSON パス。失敗時は空） |
| `{nb_by_severity}` | 同 marker の `by_severity=`（`SEVERITY:count` のカンマ区切り。0 件 / 失敗時は空） |
| `{sweep_origin}` | ステップ 5.S へ入った通常ループの sentinel。sweep 内の sentinel で上書きしない |
| `{sweep_issued}` / `{sweep_recorded}` | ステップ 5.S の `NB_SWEEP_RESULT` / `ITERATE_NB_SWEEP=done` の `issued=` / `recorded=` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{action_items}` | 本ループの最終試行に残った、ユーザーの操作が必要な WARNING / ERROR。ステップ 5 / 6 の `要対応:` 欄へ転記する（0 件なら欄ごと省略） |

---

## ステップ 0: flow-state から issue_number / branch_name を復元

`{issue_number}` / `{branch_name}` は standalone 起動でも flow-state set 呼び出しで必須のため、本コマンド冒頭で flow-state から復元する。
rationale: references/rationale.md#step0-canonical-pattern

```bash
bash {plugin_root}/scripts/iterate-step.sh restore
```

LLM は `[CONTEXT] ITERATE_ISSUE` / `ITERATE_BRANCH` から値を読み、後続の flow-state.sh set 呼び出しで `--issue` / `--branch` に literal substitute する。値が空の場合は AskUserQuestion で「Issue 番号 / ブランチ名を入力 / 中止」を提示。

### ステップ 0.5: セッション worktree 健全性の保証（multi_session 有効時）

ループに入る前に、対象作業ブランチの session worktree を保証する。共通ヘルパー `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)）で検出・再構築する（`{issue_number}` / `{branch_name}` は ステップ 0 の `ITERATE_ISSUE` / `ITERATE_BRANCH` marker の値）:
rationale: references/rationale.md#worktree-ensure-preamble

```bash
bash {plugin_root}/scripts/iterate-step.sh ensure-worktree --issue {issue_number} --branch {branch_name}
```

> `--branch {branch_name}` を明示する（review/fix の `--branch {head_ref}` 渡しと対称）。`ITERATE_BRANCH` が空の場合は `--branch` ごと省略してよい（helper が ref 推定にフォールバックする）。

`[CONTEXT] WT_ENSURE=` marker の分岐は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 3.1.5 の **WT_ENSURE 分岐表（SoT）** に従う:

- `disabled` → worktree 操作は no-op、ステップ 0.6 の状態初期化へ。
共通作業先契約には `entry_phase=pr` / `pr_number={pr_number}` を渡す。state 不在時は実体・claim の照合後に初回記録してから厳密検証する。既存 state の不一致は上書きせず停止する。

- `already_in` → 共通作業先契約の所有権・branch・変更前検証を通し、同じ作業先で続行する。
- `reenter` / `reconstructed` → recover Phase 3.1.5 と[共通作業先契約](../../references/git-worktree-patterns.md#host-worktree-execution) に従い、marker の `path=` へ native / 検証済み代替で入場し、所有権・branch・変更前検証を通してステップ 0.6 へ。後続の全 shell・編集・検証・委譲をこの作業先に固定する。
- `residue` → AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` を表示）。
- `branch_absent` → 対象ブランチが実在しない。**develop 上で続行しない**。AskUserQuestion で「Issue 番号 / ブランチを確認して再実行 / 中止」を提示（誤再構築しない）。
- `failed` → 再構築失敗（helper rc=1, stderr に原因 + 復旧手順）。**silent fallback せず明示停止**。develop 上で review/fix を回さない。

> 各 review/fix cycle の入場でも `/rite:pr-review` / `/rite:fix` が同じ helper を通す。本ステップ 0.5 はループ全体の前段ゲート。

---

## ステップ 0.6: cycle counter の初期化 + max_review_cycles の検証

`review_run` があれば phase に依らず resume とし、counter と pin を保持する。停止済み run は `iterate-step.sh stagnation-route` で停止理由を報告し、fresh entry に変換しない。残る経路はステップ 6.2 の `{resume_routes}` が名指しする。以下の reset 診断表は legacy state のみが対象。

ループに入る前に、review⇄fix サーキットブレーカーの cycle counter を初期化し、上限値を検証する。counter は flow-state の `cycle_count` に永続化され、resume を跨いで継続する。
rationale: references/rationale.md#cycle-counter-init

`{issue_number}` / `{branch_name}` は ステップ 0 の `ITERATE_ISSUE` / `ITERATE_BRANCH` marker の値、`{pr_number}` は引数をリテラル置換する:

```bash
bash {plugin_root}/scripts/iterate-step.sh init-cycle --pr {pr_number} --issue {issue_number} --branch {branch_name}
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
| `1` | counter が上限以上のまま残っている。**ステップ 1 はこの起動で review を 1 回も回さずに fire する**（未完了の `review_cycle` は再開を優先し、発火しない） |

---

## ステップ 1: 発火条件チェック → /rite:pr-review を invoke

ループ頭で未完了の `review_cycle` を先に照合する。**凍結 context の HEAD が現 HEAD と一致する**同一 cycle の回収・保存・最終ゲートの再開は counter を進めず、lost / breaker を評価しない。HEAD 不一致の未完了 cycle は早期 exit せず後段へ落ち、lost / breaker の評価を受ける。新規 cycle と HEAD 不一致の再開は **lost 修復ゲートを先に**評価し、穴が無いときだけサーキットブレーカーの **2 つの発火条件** を評価する。ゲートが fire なら increment も次 cycle の review も始めない。ゲートが ok で発火条件がどちらも不成立なら `/rite:pr-review` を invoke し、名簿確定後の `review-start` に counter 更新と `phase=review` を委譲、いずれかが成立したらサーキットブレーカー（ステップ 6）へ分岐する:

1. **lost 修復ゲート** — helper の `lost=` が `0` より大きい（完了済み cycle に対して JSON 不足 = 増分）、または `cc>=1` かつ raw `lost=` 欠落かつ reason が `no_results_file` / `results_dir_missing` / `no_file_after_pin`（`_undecidable` は `lost=` を出さない）。次 cycle を始めず (a)/(b) へ。`cc=0` と `helper_unavailable` は発火させない
2. **収束トレンドの発散**（主経路）— `hooks/scripts/review-trend-divergence.sh` が永続レビュー JSON から現 run の per-cycle blocking 列を復元し発散と判定した場合。`cycle_count` が上限未満でも発火する
3. **`max_review_cycles` 到達**（保険）— 発散判定をすり抜けた非収束を受け止める backstop（既定 15 では 16 cycle 以上を要する収束中の run にも届きうる）
rationale: references/rationale.md#lost-repair-gate

`max_review_cycles` は marker 依存を避けるため config から silent 再読込する（検証・WARNING はステップ 0.6 で実施済）:

```bash
bash {plugin_root}/scripts/iterate-step.sh cycle-gate --pr {pr_number} --issue {issue_number} --branch {branch_name}
```

`ITERATE_RESUME_HEAD` は再開ガードの HEAD 照合結果。未完了 cycle が無い起動では emit されない:

| `ITERATE_RESUME_HEAD` | アクション |
|---|---|
| `match` | 凍結 context の HEAD と現 HEAD が一致。従来どおり `REVIEW_RESUME=1` で早期 exit する |
| `changed` | 不一致。早期 exit せず後段へ落ちる。`status=collecting` は直後に放棄を試みる（下記 `ITERATE_ABANDON`）。`status=completed` は ITERATE_CB 表の `changed` 行へ進む。`review-start` は保存済み receipt を要求し、`review_run` があれば加えて advance 条件（観測・検証済み修正・clean tree）を検査する。満たせば現 HEAD で新しい cycle を凍結し、不足すれば停止する |
| `undecidable` | 凍結 `commit_sha` 欠落（`reason=frozen_sha_missing`）または `git rev-parse HEAD` 失敗（`reason=git_head_failed`）。HEAD 変更と混同せず `exit 1` で停止する |

`ITERATE_ABANDON` は再開ガード直後の放棄の結果。`ITERATE_RESUME_HEAD=changed` かつ `status=collecting` のときだけ emit する。**lost 修復ゲートより前に評価する** — 後段に置くと前 cycle の JSON が残る経路で放棄されず、どの道も `review-start` の HEAD 一致要求で止まる:

| `ITERATE_ABANDON` | アクション |
|---|---|
| `done` | 証跡ゼロの cycle を放棄した。`review_cycle` は消え、counter・`review_run`・identity は保持される。後段は通常どおり進み、新しい cycle が現 HEAD を凍結する |
| `refused` | helper が放棄の前提を満たさず拒否した（証跡あり、名簿・context 不整合など）。診断を確認する。`review_cycle` は残るので後段の `review-start` が fail-loud で止める。`/rite:recover {issue_number}` で回収する |
| `unavailable` | helper 自体を実行できなかった（不在 / プラグイン破損 / 版 skew）。証跡の有無を判定できておらず放棄も再レビューも成立しないため、その場で `exit 1` する。この分岐は handoff の clear を試み、成否を `HANDOFF_CLEAR` に出す。`refused` にはこの marker は出ない |

| `ITERATE_LOST_GATE` | アクション |
|---------|-----------|
| `ok` | 穴なし。既存の `ITERATE_CB` 表へ |
| `fire` | 次 cycle の review を開始しない（`INC=held` = 永続 counter も marker の `cycle=` も据え置き）。下記 (a)/(b) へ。`ITERATE_CB=ok` は CB fire 回避用であり、次 cycle 開始を意味しない |

| 分岐 | 条件 | アクション |
|---------|-----------|
| (a) | `ABANDON=done` ではなく、直前 cycle のレビュー結果がセッションコンテキストに残存 | 同一 cycle の固定名簿・manifest・review_context が揃う場合だけ pr-review ステップ 6.1.a の `review-finish` で保存・検証する（旧結果でこれらが無い場合は (b)）。**成立は `JSON_SAVED=true`（helper の値域。`=1` ではない）**。成立なら下の `ITERATE_LOST_REPAIR=saved` を emit して**ステップ 1 の bash を再実行**。失敗は (b) |
| (b) | `ABANDON=done` / 残存しない / (a) 失敗 | 下の `ITERATE_LOST_REPAIR=rereview` を emit し、counter 不前進のまま `/rite:pr-review` を invoke。**保存成立の観測子は `JSON_SAVED=true` または `REVIEW_SAVE_JSON_OK=1`**（`[review:mergeable]` 素通しは batch が収束扱いするので使わない）。不成立は `ITERATE_LOST_REPAIR=failed` を emit し、iterate 失敗形で停止（新 CB sentinel は作らない。caller の既存「sentinel 不在 / `[review:error]` → 失敗停止」に倒す）。成立ならステップ 2 |

```bash
bash {plugin_root}/scripts/iterate-step.sh lost-repair --repair {repair} --cycle {cycle_count} --lost {lost}
```

`{repair}` は `saved` / `rereview` / `failed`。`failed` は (b) 後に `JSON_SAVED=true` も `REVIEW_SAVE_JSON_OK=1` も無いときだけ emit する。`{cycle_count}` はゲート発火時の `cycle=`（increment 前の永続値）。`{lost}` は同 marker の `lost=`。

| `ITERATE_CB` marker | アクション |
|---------|-----------|
| `ok` かつ `ITERATE_LOST_GATE=ok` かつ `ITERATE_RESUME_HEAD=changed` | `collecting` は `ITERATE_ABANDON=done` の場合だけ現 HEAD のレビューへ進み `/rite:pr-review` を invoke（下記）。`refused` なら回収する。`completed` は `review-start` の receipt・advance 条件を満たす場合だけ次 cycle へ進む。`/rite:pr-review` を invoke（下記） |
| `ok` かつ `ITERATE_LOST_GATE=ok` かつ HEAD 変更分岐以外 | 発火条件のいずれにも該当せず。counter 更新は `review-start` まで保留。`REVIEW_RESUME=1` なら同一 cycle を再開し、それ以外は新規 cycle として `/rite:pr-review` を invoke（下記）してステップ 2 へ |
| `ok` かつ `ITERATE_LOST_GATE=fire` | 上の lost-gate 表。(b) 以外で pr-review を invoke しない |
| `fire` | 発火（`CB_REASON` に理由）。**review を invoke せず** サーキットブレーカー（ステップ 6）へ直行（mergeable 判定済 PR には発火しない = ステップ 2 で先に `[review:mergeable]` 終了するため到達しない。lost-gate が fire のときは本行に到達しない） |

`CB_REASON` は発火理由で、ステップ 6.2 の停止通知の「理由」行を決める（sentinel 自体は理由に依らず不変 — ステップ 6 参照）:

| `CB_REASON` | 意味 |
|---|---|
| `divergence` | 収束トレンドが発散と判定された（`cycle_count < max_review_cycles` でも発火する）。無駄な cycle を早期に切る主経路 |
| `max-cycles` | `cycle_count >= max_review_cycles`。発散判定をすり抜けた非収束を受け止める保険（既定 15 では 16 cycle 以上を要する収束中の run にも届く。両方成立する場合もこちらを理由として報告する） |

`TREND_VERDICT` は**両分岐に載る**トレンド判定の診断値。`ok`（収束中・下降中）/ `fire`（発散）/ `insufficient`（データ不足・データ異常で判定不能）/ `unavailable`（helper 自体を実行できなかった）を取る。`insufficient` / `unavailable` は発火しない側へ倒れ、`max_review_cycles` が従来どおり backstop として働く。**`fire` 分岐にも載せる**のは、`CB_REASON=max-cycles` で停止したときに発散判定が下りていたのか未実施だったのかをステップ 6.2 が読み分ける必要があるため（下記 `TREND_REASON` と組で使う）。

`TREND_REASON` は helper が返した `reason=` の値で、**判定が下りなかったときにその理由を運ぶ唯一の経路**。helper は理由を stdout の `reason=` に載せるため、ここで抽出して marker に載せないと呼び出し側からは消える。主な値: `need_3_cycles`（現 run の結果が 3 件に満たない。全 run が cycle 2〜3 で必ず通る正常系）/ `no_file_after_pin`（run 開始点 pin より新しい結果が 0 件。**再実行直後の 1 cycle 目は正常系**で、全面不作動を疑うのは helper が stderr WARNING を併発したとき = `cycle_count>=1`）/ `run_boundary_unresolved`（実在数が `cycle_count` を超え、他 run の結果が混ざっている。pin が無い / 古い。誤発火を避けて判定を降ろした状態で、`RUN_SINCE_USED` が原因を示す）/ `no_results_file`・`results_dir_missing`（結果ディレクトリ自体を読めない = 発散検出の全面不作動。cycle_count>=1 なら helper が stderr にも WARNING を出す）/ `json_parse_failure`・`schema_version_unknown`・`scope_enum_violation`・`pr_number_mismatch`・`blocking_count_failed`（データ異常。いずれも helper の stderr WARNING に詳細）/ `helper_unavailable`（helper 自体を実行できなかった。上記 WARNING が対）/ 判定が下りた場合は `converging_or_descending`・`no_new_minimum_and_not_descending`。

`ITERATE_CB=ok` かつ `ITERATE_LOST_GATE=ok` かつ（HEAD 変更分岐以外、または `ITERATE_RESUME_HEAD=changed` かつ (`ITERATE_ABANDON=done` または `status=completed`)）のとき `/rite:pr-review` を invoke（`refused` は回収し、包括 invoke しない）:

```text
skill: rite:pr-review
args: "{pr_number}"
```

---

## ステップ 2: review sentinel を判定

`[review:error]` でも `review_run.current_decision.action=stop` が保存済みなら、ステップ 3 の `iterate-step.sh stagnation-route` を実行してステップ 6 へ進む。観測の保存・権限・入力エラーだけは既存のエラー処理に従う。非収束を再レビューで迂回しない。

| Sentinel | アクション |
|---------|-----------|
| `[review:mergeable]` | ステップ 5.S（NB digest sweep。完了通知の前） |
| `[review:fix-needed:N]` | ステップ 3 (fix invoke) へ |
| `[review:error]` + 行頭の `[CONTEXT] REVIEW_STOP=ac_unverified; ac={ids}` | 受入条件未検証の停止。再試行せず、下記の停止通知を出して終了する（成功 sentinel も新しい sentinel も出さない） |
| `[review:error]` + 行頭の `[CONTEXT] REVIEW_STOP=purpose_unaligned` | 5.S 後の目的逸脱。再試行せず終了する（成功 sentinel も新しい sentinel も出さない） |
| `[review:error]` | 可逆な再試行を推奨として 1 回だけ自動実行し、work memory の既存決定事項へ理由を記録する。再失敗なら停止 |
| sentinel 不在 | 可逆な再試行を推奨として 1 回だけ自動実行し、期待 sentinel と直近出力を既存 work memory へ記録する。再度不在なら停止 |

`REVIEW_STOP` は行頭 `[CONTEXT] ` の marker だけを判定に使う（診断文や引用の中の文字列では分岐しない）。同じ HEAD を再レビューしても観測できない AC は変わらないため再試行しない。停止通知は `state-path-resolve.sh` 基準の `.rite/review-results/{pr_number}-*.json` のうち最新のファイルの `acceptance_criteria` から `status == "unverified"` の行を読んで作る:

```
## /rite:iterate 停止（受入条件未検証）

- PR: #{pr_number}
- 未検証の受入条件: {ac_id} — {evidence}（1 行ずつ）
- 次の一手: 上記 AC を実環境で動作確認してください
```

---

## ステップ 3: /rite:fix を invoke

先に保存された停滞判定を読む。未完了レビューはステップ 1 の同 cycle 再開が先、証跡・保存・権限エラーは既存エラー経路が先である。`stop` なら `{cb_reason}=stagnation` としてステップ 6 へ進む。`replan` は fix の一括計画で範囲内代替を保存し、通常の scope gate へ戻る。

```bash
bash {plugin_root}/scripts/iterate-step.sh stagnation-route
```

`stop` の理由が既存の `max-cycles` / `divergence` なら、その値を `{cb_reason}` とする。それ以外は `stagnation`。`continue` / `replan` / `legacy` の場合だけ flow-state を `phase=fix` に更新し `/rite:fix` を invoke:

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

`[fix:error]` のときは再試行前に `iterate-step.sh stagnation-route` を実行する。`stop` なら `{cb_reason}=stagnation` でステップ 6 へ直行し、修正を再試行しない。それ以外のエラーだけ下表の1回再試行を適用する。

| Sentinel | アクション |
|---------|-----------|
| `[fix:pushed]` | ステップ 1 (cycle 上限チェック → review 再実行) に戻る — **ループ継続**（上限到達ならステップ 6 サーキットブレーカーへ） |
| `[fix:sweep-done]` | 完了前確認（目的整合）のあとステップ 5。**ステップ 1 に戻らない**（再フルレビュー禁止） |
| `[fix:pushed-wm-stale]` | ステップ 1 に戻る (WM stale 警告は表示するが loop は継続。上限チェックはステップ 1 が実施) |
| `[fix:non-fatal-only]` | ステップ 5.S（成功後に完了前確認）。**ステップ 1 に戻らない** |
| `[fix:replied-only]` | ステップ 5.S（成功後に完了前確認。返信のみで完了通知）。**ステップ 1 に戻らない** |
| `[fix:cancelled-by-user]` | **ループ終了**（ユーザーが fix.md 内 cancel 経路 — ステップ 1.4 Cancel option / Fast Path Cancel handoff 等 — で中止選択。`/rite:recover` で再開可） |
| `[fix:error]` | 可逆な再試行を推奨として 1 回だけ自動実行し、work memory の既存決定事項へ理由を記録する。再失敗なら停止 |
| sentinel 不在 | 可逆な再試行を推奨として 1 回だけ自動実行し、期待 sentinel・直近の fix 出力 100 行・flow-state phase を既存 work memory へ記録する。再度不在なら停止 |

> `--nb-sweep` 経由の戻りは本表を使わない。5.S 専用表（ステップ 1 に戻らない）だけを使う。

---

## ステップ 5.S: NB digest sweep

`[review:mergeable]` / `[fix:non-fatal-only]` / `[fix:replied-only]` 到達後・完了通知前に、未 sweep の最新 review JSON につき **1 回**。対象 0 件は no-op（fix を invoke しない）。同一 review JSON では 2 回 invoke しない。新しい JSON では再 sweep する。silent skip 禁止。Stop hook が `review:mergeable` / `fix:non-fatal-only` / `fix:replied-only` の FINALIZE で完了通知を求めても、5.S 未実施なら先に本ステップを実行する。成功後は完了前確認を経てからステップ 5 へ。Stop hook がステップ 5 を求めても完了前確認を飛ばさない。
rationale: references/rationale.md#nb-sweep-step

入口の通常ループ sentinel を `{sweep_origin}` として保持する。5.S 再入時も保持値を使い、内部の `[fix:sweep-done]` や handoff で上書きしない。

会話の `[CONTEXT] ITERATE_NB_SWEEP=done|noop` は観測用。skip 判定は done ファイル 1 行目の第 2 フィールドが最新 review JSON の basename と一致するときだけ（欠落は skip しない。下の bash）。marker 既出でも bash を省略しない。

```bash
bash {plugin_root}/scripts/iterate-step.sh nb-sweep-collect --pr {pr_number}
```

| `ITERATE_NB_SWEEP` | アクション |
|---|---|
| `skipped` | 完了前確認（目的整合）。collect / fix を invoke しない |
| `noop` | 完了前確認（目的整合）。fix を invoke しない |
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
| `[fix:sweep-done]` | 完了前確認（目的整合）。ステップ 1 に戻らない |
| `[fix:error]` / その他 / sentinel 不在 | `[iterate:nb-sweep-error]` で停止。完了通知へ進まない |

fix が emit した `[CONTEXT] NB_SWEEP_RESULT=done; issued=K; recorded=M` を読み、`ITERATE_NB_SWEEP=done` を同カウントで emit する。記録した basename が最新 JSON と違う、またはファイルが無いときは、collect と同じ選び方（`LC_ALL=C` sort の末尾）で 1 行目を `done <basename>` にする。既存の 2 行目が SHA なら残し、新しい SHA は足さない。basename が取れないときは範囲なしの行を残さない:

```bash
bash {plugin_root}/scripts/iterate-step.sh nb-sweep-record --pr {pr_number}
```

その後、完了前確認（目的整合）へ。

MUST NOT: 同一 review JSON で 5.S を 2 回走らせる。sweep でコードを修正・commit・push する。ステップ 1 に戻らない。

### 5.S 後の完了前確認（目的整合）

5.S 成功後・5.0.1 の前に、確認時点の `git rev-parse HEAD` と、その HEAD の PR base...HEAD 全差分を元 Issue の目的・非対象・ファイル役割と照合する。sweep 正本はコード変更・commit・push を禁止するが、最終 HEAD を推測で省略しない。整合の確認観点（指摘 0 件でも未説明なら逸脱）: 配置（証拠→PR details / 契約→規約 / Why→ソース / 再現→テスト）、規範の正の逆転・重複、根拠のない新制約、有用な契約・保守理由の保持。

| 結果 | 処置 |
|------|------|
| 整合 | ステップ 5（5.0 → 5.0.1）へ |
| 逸脱（親の発見。findings[] に無い、または未実測） | 5.0.1 を呼ばない。完了を未確認とする。受入条件未検証と同型で `flow-state.sh set` を `--handoff` なしで実行し FINALIZE を消す。`[CONTEXT] REVIEW_STOP=purpose_unaligned` と `[review:error]` で未完了停止。逸脱箇所・元要求・反証条件を既存 PR details に書く（新キーなし）。`/rite:iterate` 再実行だけで回復したとしない |

逸脱時は CB fire と同型の fenced bash を実行する（`--handoff` なし。新 sentinel は出さない）:

```bash
bash {plugin_root}/scripts/iterate-step.sh purpose-unaligned --pr {pr_number} --issue {issue_number} --branch {branch_name}
```

復帰は、保存済み実測 finding が既存 scope を満たすときだけ通常 `/rite:fix`。それ以外は次の統合担当が PR details の逸脱記録を全差分確認の入力にする（pr-review ステップ 5 の `### 仕様との整合性`）。同一 HEAD で pr-review を再 invoke して empty_diff→full の全員再起動にしない。`phase=pr` への set は一般回復に使わない。

MUST NOT: 親発見を finding ID として `/rite:fix` 2.1 へ足す。8.1 を上書きしない。ステップ 2 の汎用 `[review:error]` 再試行行にこの終端を載せない。成功を偽らない。同一 invoke の pr-review `[review:mergeable]` と `FINALIZE:review:mergeable` を iterate 成功と読まない。

---

## ステップ 5: 完了通知

> **構造的保証**: 終了 sentinel (`[fix:sweep-done]` / `[review:mergeable]` または `[fix:non-fatal-only]` 経由 5.S 完了 / `[fix:replied-only]` / `[fix:cancelled-by-user]`) 到達時、sub-skill が `FINALIZE:...` handoff をセットしており、`Stop` hook が本ステップの完了通知を出力せず turn を終えようとする停止を **1 回だけ** 差し戻す。`[review:mergeable]` / `[fix:non-fatal-only]` / `[fix:replied-only]` 単体では完了通知へ進まない（5.S が先）。`REVIEW_STOP=purpose_unaligned` のときは本ステップへ進まず完了通知を出さない。詳細は「ループ継続・終了の構造的保証」節を参照。完了通知は（目的逸脱停止を除き）必ず出力すること。

### ステップ 5.0: 一時残骸の最終回収 (terminal cleanup)

完了通知を出力する**前に**、本ループが残した一時ブランチ・worktree を回収する。本ループの終端で明示的に発火させ、回収の到達性を担保する。non-blocking — 失敗してもループ完了を妨げない:
rationale: references/rationale.md#terminal-cleanup-age-guard

```bash
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

これは正常終了・ユーザー中断の**両経路**で実行する (どちらの出口でも残骸の累積を防ぐ)。出力 status 行 (`[pr-cycle-cleanup] status=...`) はそのまま表示し、何を回収したかを可視化する。

> **24h age guard**: 直前に作った若い `rite-review-mutation-*` / `rite-revert-test-*` detached worktree はこの発火では消えず、次回 cleanup (24h 経過後) で回収される。即時 0 残骸ではなく **確実な最終回収**。

### ステップ 5.0.1: run を閉じる (cycle counter のリセット)

`review_run` がある現在の run は counter と履歴を維持する。正常終了では、全品質ゲートと 5.S の成功後に `review-close` で完了 context を保存する。これにより cleanup を行わない draft batch も次 Issue へ進める。完了記録の失敗は caller へ成功を返さず停止する。返信のみは `review-defer` で `deferred` として終了記録を保存し、中断は `retained` として未完了 run を閉じない。以下の reset の説明と失敗警告は legacy state に適用する。

完了通知を出力する**前に**、`cycle_count` を 0 にして run を明示的に閉じる。これをしないと終了経路
（`[review:mergeable]` / `[fix:non-fatal-only]` / `[fix:replied-only]` / `[fix:cancelled-by-user]`）はいずれも counter を残したまま
終わり、**同じ PR に対する次の `/rite:iterate` が resume と判定され、ステップ 0.6 の pin 更新に入らない**。
非ブロッキング — 失敗しても完了通知は出す。

**`--handoff` は既存値を読んで載せ直す**（省略すると handoff キーが消え、ステップ 5 冒頭の FINALIZE 差し戻し保証が通知前に失われる）。
**`--phase` も現在値を維持する**（ハードコードすると中断通知の「phase=fix のため fix invoke から再開」が偽になる）。
rationale: references/rationale.md#run-close-reset

```bash
bash {plugin_root}/scripts/iterate-step.sh run-close --pr {pr_number} --issue {issue_number} --branch {branch_name} --sweep-origin '{sweep_origin}'
```

| `ITERATE_RUN_CLOSE` | 意味 |
|---|---|
| `completed` | 検証済み完了 context と履歴を保持した。次 Issue への切替時に旧 run を履歴へ移し、新 run を開始できる。同じ Issue の再開では counter を維持する |
| `deferred` | 返信のみで draft を残す終了 context と理由を保存した。未解決指摘・判定・履歴を保持して default batch の次 Issue へ移れる。品質上の完了にはせず、merge モードの失敗扱いも変えない |
| `retained` | 現在の run の counter・観測・見直し履歴を保持した。既存の品質ゲートと完了 sentinel に従って caller へ戻る |
| `ok` | counter を 0 にして run を閉じた。次回起動は fresh entry となり pin が更新される |
| `failed` | リセットに失敗。次回起動は resume 判定となり前 run の pin を引き継ぐ（WARNING 済み）。`/rite:recover` で最後の未完了工程を再開する。未完了 review の counter reset は拒否される |

### ステップ 5.0.2: 未処理 non-blocking 件数（`[review:mergeable]` 完了通知用）

5.S overlay。残件欄は **0 件固定**（JSON の `non_blocking_findings[]` は消化前の値のまま残るので数えない）。取得失敗は 5.S で `[iterate:nb-sweep-error]` 停止済みでここへ来ない。
rationale: references/rationale.md#nb-remaining-notice

```bash
bash {plugin_root}/scripts/iterate-step.sh nb-remaining
```

| 5.S marker | 完了通知 |
|---|---|
| `ITERATE_NB_SWEEP=noop` | 0 件テンプレ。消化内訳行は出さない |
| `ITERATE_NB_SWEEP=done`（`NB_SWEEP_RESULT=done`） | 0 件テンプレ + `- sweep: issued={sweep_issued} / recorded={sweep_recorded}` |
| `ITERATE_NB_SWEEP=skipped` | kind（1 行目の第 1 フィールド。emit 済み `kind=`）が `noop` なら 0 件テンプレ（digest 行なし）。`done` なら 0 件テンプレ + digest 行（件数が取れなければ 0） |
| `ITERATE_NB_SWEEP=failed` | 到達不能（5.S で停止） |

非 0 件テンプレ / 「取得失敗」テンプレは overlay 後到達不能。

`{action_items}`（ステップ 5 の 4 テンプレとステップ 6.1 / 6.2 の停止通知に共通）: 本ループの bash 出力に残った WARNING / ERROR のうち、ユーザーが操作しない限り残り続ける行を 1 行ずつ列挙する。最終試行と重複の判定は [Autonomous Execution](../rite-workflow/references/autonomous-execution.md) に従う。成功した迂回・リトライは載せない。**0 件なら `要対応:` 行ごと省略する**。

### sweep 後の終了理由

5.S の `done` / `noop` / `skipped` は消化の成功だけを表す。内部の `[fix:sweep-done]` から mergeable を推定せず、保持した入口で通知を選ぶ。

| `{sweep_origin}` | 5.S 成功後の外向き sentinel / 完了通知 |
|---|---|
| `[fix:replied-only]` | `[fix:replied-only]`（返信のみ。mergeable へ昇格しない） |
| `[review:mergeable]` / `[fix:non-fatal-only]` | `[review:mergeable]` |
| 欠落 / その他 | `[iterate:nb-sweep-error]` で停止。終了理由を推測しない |

### 正常終了 (`[review:mergeable]`)

`[review:mergeable]` sentinel 文字列は変えない。`[fix:non-fatal-only]` 経由も **5.S が `done` / `noop` / `skipped` で成功した後だけ**、同じテンプレを使い外向きに `[review:mergeable]` を返す（batch-run の既存成功経路へ戻す）。その場合の終了理由は `fix:non-fatal-only → 5.S 完了` とし、残件 0 件と sweep 内訳は上表どおり必ず通知する。sweep 失敗時は `[iterate:nb-sweep-error]` のまま停止し、成功 sentinel を返さない。

**0 件** (`ITERATE_NB_SWEEP=noop`):

```
## /rite:iterate 完了

- PR: #{pr_number}
- 終了理由: review:mergeable
- ブランチ: {branch_name}
- 未処理 non-blocking: 0 件

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

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

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

次のステップ:
- Ready 化: /rite:ready {pr_number}
- マージ (Ready 後): /rite:merge {pr_number}

flow-state は phase={review|fix} のままです。`/rite:ready` 実行時に phase=ready に遷移します。
```

### 正常終了 (`[fix:replied-only]`)

5.S 成功後も外向きに `[fix:replied-only]` を返す。batch-run は既存どおり `--merge` なら非収束として停止、default なら draft を残す。sweep 内訳はステップ 5.0.2 と同じ条件で添える。

```
## /rite:iterate 完了

- PR: #{pr_number}
- 終了理由: fix:replied-only
- ブランチ: {branch_name}

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

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

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

再開方法:
- /rite:recover で本コマンドが再起動 (flow-state phase=fix のため fix invoke から再開)
- 手動で /rite:iterate {pr_number} を再実行することも可
```

---

## ステップ 6: サーキットブレーカー（発火時のみ）

`review_run` がある場合は共有ブロックの先行分岐で `active=false` と停止理由を保存し、counter・観測・見直し履歴を保持する。以下の reset・手動リセット・fresh run 再開の説明は legacy state のみ。現在の run の停止通知には `/rite:recover {issue_number}` で保存済み原因と証跡を確認する手順を出し、counter削除やReady直行を案内しない。根本原因・要件変更を解決するまで同じ停止判定を維持する。

> **停止 invariant**: 発火後は review / fix を invoke せず、停止 sentinel と通知を出して終了する。発火そのものから Ready / merge へ直行する分岐は存在しない。counter reset は次の明示的な再実行を可能にする処理であり、この起動でループを再開する許可ではない。
rationale: references/rationale.md#circuit-breaker-stop-invariant

ステップ 1 で `ITERATE_CB=fire`（収束トレンドの発散 or `cycle_count >= max_review_cycles`。理由は同 marker の `CB_REASON`）となったときのみ到達する。**発火理由は本ステップの停止構造を変えない** — 変わるのは 6.1 / 6.2 の「理由」行の文面とトレンド推移だけである（sentinel・handoff 契約・counter reset は不変）。batch / 対話は **自セッションの** run-queue（`run-queue-{session_id}.json`）から判定する。**`active == true` かつ** cursor の Issue が本 iterate の対象と一致すれば batch（read-only。`{issue_number}` はステップ 0 の marker 値をリテラル置換）:
rationale: references/rationale.md#cb-mode-and-reset

```bash
bash {plugin_root}/scripts/iterate-step.sh breaker --pr {pr_number} --issue {issue_number} --branch {branch_name} --cb-reason {cb_reason}
```

共有前段の atomic set が失敗した場合は、その WARNING（`サーキットブレーカー発火時の cycle counter リセットと stop_reason 永続化に失敗`）を停止通知の注意行判定に使う。`ITERATE_CB_MODE` は停止先の選択だけを担い、成功・失敗によってループへ戻らない。

| `ITERATE_CB_MODE` | アクション |
|---|---|
| `batch` | ステップ 6.1（failed sentinel emit）|
| `interactive` | ステップ 6.2（機械的停止通知）|

**両分岐は挙動として同構造**（failed 記録 + draft 残し + 停止通知 + handoff クリア維持 + 共有前段での cycle counter reset。人間への問い合わせは行わない）。差は次の 2 点だけ:

1. **sentinel の消費者**: `[iterate:max-cycles-reached]` は `/rite:batch-run` が grep して当該 Issue を `failed[]` に記録しバッチを停止する。`[iterate:max-cycles-stopped]` は消費者を持たない iterate 内部完結の最終状態表示。
2. **`REFIRE=1` / 共有前段の atomic set 失敗 注意行の有無**: ステップ 6.2（対話）のみが持つ。6.1（batch）は対称化しない。

**失敗停止の理由は両モードで永続化する** — 共有前段の reset 成功後は `stop_reason=circuit-breaker:{cb_reason}` を同じ atomic set で残す。`stop_reason` は後続の通常 `flow-state.sh set` が default-clear する。

どちらの経路もマージには到達しない（上記 invariant）。

STATE_ROOT が `unresolved` の場合は両モードの停止通知に「状態ファイルの更新先を確認できません。チェックアウト内で state root を解決してから状態を確認してください」を添える。停止 sentinel は省略しない。

### ステップ 6.1: バッチ実行 — failed sentinel

review を回さず、当該 Issue を非収束（failed）として `/rite:batch-run` に返す。`/rite:batch-run` はこの sentinel を受けて当該 Issue を failed 記録し、cursor を保持してバッチを停止する（ready/merge/cleanup はスキップ、draft/open PR はレビュー待ちで残す）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない（`[fix:error]` が set で handoff をクリアして clean terminal になるのと同じ。以降は run のステップ 8 で停止処理）:

```
## /rite:iterate サーキットブレーカー発火（バッチ）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: {fire_reason_line}
- blocking 推移: {trend}
- 措置: 当該 Issue を failed 扱いとし、draft/open PR をレビュー待ちで残します（`/rite:batch-run` も停止し、後続 Issue は開始しません）

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

再開方法: `review_run` が無い legacy state では /rite:iterate {pr_number} を明示再実行する。`review_run` がある停止は通常の再実行では新 run にならない。発散なら限定 retry、回数上限を含む既知 breaker の completed 停止は明示承認の `review-restart`（契約は 6.2 と [review-stagnation.md](../../references/review-stagnation.md)）。

<!-- [iterate:max-cycles-reached] -->
```

`{fire_reason_line}` / `{trend}` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=` / `TREND=` からリテラル置換する（`{max_review_cycles}` はステップ 0.6 の `ITERATE_CYCLE_MAX=`。置換表は 6.2 と共通で、下記「発火理由の文面」を参照）。

**sentinel は発火理由に依らず `[iterate:max-cycles-reached]` のまま**。`/rite:batch-run` はこの literal を grep して当該 Issue を `failed[]` に記録してバッチを停止するため、理由別に sentinel を分けると batch が停止を検出できなくなる（sentinel 契約は不変に保つ）。理由の区別は上記「理由」行が担う。

制御を `/rite:batch-run` に戻す（run 側で cursor を保持して停止）。

### ステップ 6.2: 対話実行 — 機械的停止

`AskUserQuestion` は**使わない**。当該 PR を非収束（failed）として機械的に記録し、draft/open PR をレビュー待ちで残して停止する。6.1（batch）と同構造であり、品質ゲートの履行を人間の裁量に委ねない（発火は失敗であって、人間に選ばせて counter をリセットし続行できる例外を作らない）。継続 handoff はステップ 1 fire 分岐の `flow-state.sh set`（`--handoff` なし）で既に default-clear 済みのため、ここでは追加の handoff 操作をしない。

下記の停止通知を出力してループを終了する（`{max_review_cycles}` 等はリテラル置換する）:

```
## /rite:iterate サーキットブレーカー発火（対話・停止）

- PR: #{pr_number}（Issue #{issue_number}）
- 理由: {fire_reason_line}
- blocking 推移: {trend}
- 措置: 当該 PR を非収束として失敗記録し、draft/open PR をレビュー待ちで残します（マージには進みません）

（転記すべき行があるときのみ、以下 2 行）
要対応:
{action_items}

再開方法:
{resume_routes}
- Ready 化して人間のレビューに委ねる: /rite:ready {pr_number}

<!-- [iterate:max-cycles-stopped] -->
```

#### `{resume_routes}`（6.2 のみ）

停止した run に残る経路は「抜ける」、`divergence` 限定の「戻る」、既知 breaker の completed 停止に対する明示承認の「新 run」の 3 本で、どれも通常 iterate / recover では停止理由を消さない。契約の SoT は [review-stagnation.md 停止後の退路と再開](../../references/review-stagnation.md#停止後の退路と再開)。

分岐は marker だけで行う。flow-state を読み直して条件を作らない。`ITERATE_STAGNATION` は ステップ 3 の `iterate-step.sh stagnation-route` が emit するが、**ステップ 1 の fire 分岐はステップ 3 を通らずステップ 6 へ直行する**ため、この marker が出ないまま本節に到達する起動がある。既定は `legacy` ではなく marker 不在の行が担う:

| `ITERATE_STAGNATION` | `{cb_reason}` | `{resume_routes}` |
|---|---|---|
| `legacy` | 任意 | 下記「legacy 再開」1 行のみ |
| それ以外（`stop` / `continue` / `replan` / marker 不在） | `divergence` | 下記「戻る」「抜ける」「新 run」 |
| それ以外（同上） | `max-cycles` | 下記「抜ける」「新 run」 |
| それ以外（同上） | 上記以外 | 下記「抜ける」1 行のみ |

marker 不在を `legacy` に倒さない。
rationale: references/rationale.md#resume-routes-no-state-read

`{cb_reason}` の供給元は 2 つある。ステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=` と、`review_run` がある run で発散停止を `observe()` が記録した場合のステップ 3 の規則（同ステップの「`stop` の理由が既存の `max-cycles` / `divergence` なら、その値を `{cb_reason}` とする」）。後者の iteration ではステップ 1 が `ITERATE_CB=ok` を出すため、前者だけを見ると発散停止で「戻る」行が落ちる。

`divergence` で「戻る」行を出すときに、権利が既に使用済みかどうかは判定しない（そのための marker を増やさない）。使用済みなら `review-retry` 自身が拒否する。
rationale: references/rationale.md#resume-routes-no-state-read

「戻る」の行（`divergence` のみ）:

```
- この PR の修復を 1 巡だけ試す: 全 blocking 指摘に修正計画と検証項目を対応付けたうえで
  `bash "{plugin_root}"/hooks/flow-state.sh review-retry --plan <一括修正計画の絶対パス> --issue <最新 Issue JSON の絶対パス>` を実行する
  （run 生涯 1 回。計画が blocking を覆えない・HEAD や receipt が動いている・権利が使用済みなら拒否される。
  許可されるのは fix → 検証 → review の 1 巡で、その review に blocking が残れば同じ理由で再停止する）
```

`{plugin_root}` は解決済み絶対パスへリテラル置換する（注意行 (b) と同じ形。配布先の plugin root は人間が推測できない）。`--session` は付けない — `cmd_review_cycle` は session override を受け付けない。

「抜ける」の行（全停止理由で共通）:

```
- この PR を停止のまま残して別 Issue へ移る: そのまま /rite:open <別 Issue 番号> を実行する
  （停止した run は status・stop_reason・観測・cycle counter ごと履歴へ退避される。前段の ownership
  cleanup は要らない）
- 退避したこの PR へ戻る: /rite:open {issue_number} の後に /rite:iterate {pr_number} を実行する
  （退避した run がそのまま復元されるので停止は往復で消えない。復元後も停止したままで通常の
  phase 更新は拒否される。同一 run を進めるのは再試行権を発行できるときだけで、発行できるのは
  circuit-breaker:divergence に限る。既知 breaker の completed 停止なら、下の明示承認
  review-restart で新しい run を始めてもよい）
```

「新 run」の行（`divergence` / `max-cycles`）:

```
- この停止 run への明示承認で新しい run を始める:
  `bash "{plugin_root}"/hooks/flow-state.sh review-restart --selection <名簿 JSON の絶対パス> --expected-run-id <停止した run_id> --approval <今回の承認 JSON の絶対パス>`
  （名簿は `review_cycle.selected_reviewers` の dump。`run_id` は停止時の `.review_run.run_id`。
  承認 JSON の必須フィールドは [review-stagnation.md](../../references/review-stagnation.md#停止後の退路と再開)。
  `--session` は付けない。旧 run は reason・要求時刻・対象 context ごと保管する。通常の iterate / recover / 自動再試行では呼ばない。
  collecting・未知の停止理由・未 close の clock は拒否する。tracked 差分も gitignore 対象外の
  未追跡ファイルも無い作業ツリーが必須）
```

「legacy 再開」の行（`ITERATE_STAGNATION=legacy` のみ）:

```
- ループを再開する: /rite:iterate {pr_number} を明示的に再実行する（cycle counter と run 開始点が
  リセットされ、新しい run として cycle 1 を full scope で回る。再び発散すればブレーカーは上限を
  待たずに再発火する）。/rite:recover 経由の再開も同じ経路
```

#### 発火理由の文面（6.1 / 6.2 共通の置換表）

`{fire_reason_line}` はステップ 1 の `ITERATE_CB=fire` marker の `CB_REASON=` で決める。`{trend}` は同 marker の `TREND=` の値（カンマ区切りの per-cycle blocking 件数）をそのまま使い、`→` 区切りへ整形して表示する（例: `TREND=3,7,7,4` → `3 → 7 → 7 → 4`）。**この推移行は省略しない**。

`max-cycles` の文面は **`TREND_VERDICT` で分岐する**（上限到達と発散判定は独立に成立しうる）:
rationale: references/rationale.md#notice-trend-and-notes

| `CB_REASON` | `TREND_VERDICT` | `{fire_reason_line}` |
|---|---|---|
| `stagnation` | 任意 | `方針見直し後も同じ根因が再発し進展がない、または範囲内代替で解決できない（詳細は review_run.current_decision.reasons）` |
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

#### `{action_items}` 追加項目（ステップ 6.2 のみ）

以下の (a) / (b) / (c) による `{action_items}` への反映と「再開方法」第 1 bullet の差し替えは **ステップ 6.2（対話）専用**。上記「発火理由の文面」の置換表までが 6.1 / 6.2 共通である。

ステップ 0.6 / ステップ 1 の `[CONTEXT]` marker と **ステップ 6 共有前段**の WARNING を観測している場合、下記の条件で各行を `{action_items}` へ反映する。(a) は末尾へ追加する。(b) / (c) は対応する raw WARNING の項目を詳細な復旧項目で置換し、raw 項目が無い場合だけ末尾へ追加する。raw WARNING と詳細な復旧項目を両方残してはならない。「理由」行の直後には追加しない。3 ステップすべてを観測対象に含める — (b) は共有前段の atomic set 失敗 WARNING、(c) の `HANDOFF_CLEAR` はステップ 1。marker 値の読み取りは `marker_get`（[`lib/context-marker.sh`](../../hooks/scripts/lib/context-marker.sh)）の契約に従う。**marker 値の照合**は `;` 区切りの `KEY=VALUE` 単位の**完全一致**（部分一致は禁止）。追加行と差し替え行の `{plugin_root}` / `{pr_number}` / `{max_review_cycles}` / `{session_id}` / `{state_root}` はリテラル置換する（値が得られない側は (b) の pre-fill 表で解決手順へ置き換える）。**置換の対象は (b) が人間へ渡すすべての実行可能テキスト**に及ぶ。人間の端末で live なシェル変数を前提にした記法（`$root` 等）は、同じ案内文の中で代入している箇所以外では使わない。

**(a) `REFIRE=1`**（この起動では review を 1 回も回さずに発火した。前回の最終 cycle 途中で中断した場合の正常な発火と、counter リセット失敗による再発火の**両方**を含む — marker だけでは区別できない）:

```
- 注意: 起動時点で cycle counter が上限に達していたため、この起動では review を 1 回も回さずに発火しました（未完了の `review_cycle` がある場合はこの経路へ入らず再開します）。ステップ 0.6 / ステップ 1 / ステップ 6 共有前段に WARNING が出ている場合は、その直後の flow-state.sh の診断を確認してください
```

`REFIRE=0` では**追加しない**。`RESET` の値は本条件に使わない — 即再発火の判定には `REFIRE` を使う。

**(b) 共有前段の atomic set 失敗**（ステップ 6 共有前段の atomic set に失敗し、counter のリセットと `stop_reason` の永続化がどちらも行われなかった）:

```
- 注意: 発火時の cycle counter リセットと `stop_reason` の永続化に失敗しました。**このまま再実行しても counter と run 開始点が更新されず即再発火し、次セッションの案内ではこの失敗停止を通常の中断と区別できません**（`max-cycles` 発火なら counter が上限のまま、`divergence` 発火なら counter が 0 に戻らずステップ 0.6 の pin 更新経路に入らないため helper が同じ列を読み直します）。次のコマンドで手動リセットしてから再実行してください（`--handoff` を伴わないため handoff のクリアも兼ねます）: `reset_phase=$(RITE_STATE_ROOT="{state_root}" bash "{plugin_root}"/hooks/flow-state.sh get --session {session_id} --field phase --default pr) && RITE_STATE_ROOT="{state_root}" bash "{plugin_root}"/hooks/flow-state.sh set --session {session_id} --phase "$reset_phase" --next "cycle counter 手動リセット" --cycle-count 0`
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

**(b) は `{action_items}` 内の raw WARNING を詳細な復旧項目へ置換するだけでは足りない。** **(b) を観測したときは、テンプレートの当該 1 行を次の 1 行へ差し替えて出力する**（追加ではなく置換）:

```
- ループを再開する: 上記の手動リセットを実行してから /rite:iterate {pr_number} を再実行する
  （リセット前に再実行すると即座に再発火する）。/rite:recover 経由の再開も同じ経路
```

差し替える単位は**`{resume_routes}` が出した「legacy 再開」の bullet 全体** — `- ループを再開する:` で始まる行から、次に `- ` で始まる行が現れる直前までの全行 — であり、第 1 物理行だけを置き換えてはならない。**物理行数を数えて指定しないこと**。

**この差し替えは `{resume_routes}` が「legacy 再開」を出したときだけ行う。** 「抜ける」「戻る」を出した run では `- ループを再開する:` の行が出力されない。その場合は差し替えず、(b) の手動リセットは `{action_items}` の注意行だけで案内する。
rationale: references/rationale.md#resume-routes-no-state-read

(a) のみを観測した場合はこの差し替えを**行わない**。(a) / (b) / (c) は独立に評価し、観測したものを **(a) → (b) → (c) の順に**反映する。(a) は末尾へ追加し、(b) / (c) は上記の raw WARNING 置換規則に従う。差し替えは (b) を観測した場合のみ行う。

---

## エラー時の方針

- ユーザーが Ctrl+C で中断した場合: flow-state に現 phase (review or fix) が残るので `/rite:recover` で本コマンドが再起動する (詳細な phase → command routing は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 5.3 を参照)
- ステップ 0.6 / 1 が `pr_number が数値に置換されていません` の ERROR で止まった場合: marker を待たずに停止し、PR 番号を数値で置換して当該ステップから再実行する
- `[fix:error]` 時: [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従い 1 回だけ自動再試行し、再失敗時は停止する
- reviewer が non-deterministic に振動する場合: 収束トレンドの発散または `safety.max_review_cycles`（既定 15）到達でステップ 6 に進み、人間に問わず停止する。batch は `[iterate:max-cycles-reached]` で当該 Issue を failed 扱いにしてバッチを停止し、対話は `[iterate:max-cycles-stopped]` で終了する。再開は `review_run` がない legacy state では `/rite:iterate {pr_number}` の明示的な再実行、`review_run` がある run ではステップ 6.2 の `{resume_routes}` が名指しする経路で行う。

---

## ループ継続・終了の構造的保証

継続点・終了点で sub-skill が one-shot handoff (`/rite:...` / `FINALIZE:{result}:{pr}`) を flow-state にセットし、turn 早期終了時は Stop hook (`stop-loop-continuation.sh`) が consume + prefix 分岐で停止を差し戻す。`[fix:error]` とサーキットブレーカー fire 分岐は handoff を持たない/能動クリアする (Stop hook は停止を許可)。機構の全体解説・sentinel → handoff 対応表・無限 block 防止の設計:
rationale: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism)

## 設計判断

- **blocking 指摘ゼロ（mergeable）、または非 fatal のみを移送後に 5.S で消化した状態が正常出口** — blocking の定義式は本ファイルに複製せず [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) を SoT とする。**非実測指摘が N 件残った状態でも `[review:mergeable]` に到達しうる** — 残存分の消化は完了通知前の 5.S（`/rite:fix --nb-sweep`）が担い、人間の draft レビューに委ねない。正常出口は未消化 0 件
- **ブレーカーの発火条件は「発散」であって「予算切れ」ではない** — 主経路は収束トレンドの発散検出、`safety.max_review_cycles`（既定 15）は backstop。**窓幅や閾値を config キーにしない**
- **発火理由は停止 routing を変えない** — sentinel（`[iterate:max-cycles-reached]` / `[iterate:max-cycles-stopped]`）は理由に依らず不変
- **発火後は停止** — batch は failed、対話は機械的に停止。legacy の再実行は fresh entry。停止した `review_run` の full scope は明示承認の `review-restart` が担う。
- **cycle counter は flow-state に保持** — 専用 state file は持たない。resume 跨ぎ継続、fresh entry で 0 リセット。発火直前（ステップ 6 共有前段）と正常終了時（ステップ 5.0.1）でも 0 に戻す
- 人間が skip → 別 Issue で loop 終了する経路は閉じた。残存 non-blocking の消化は機械 routing（完了通知前の 5.S `/rite:fix --nb-sweep` と、cleanup の follow-up Issue 起票）が担う
rationale: references/rationale.md#design-decisions
