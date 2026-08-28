# /rite:iterate — 設計理由

`skills/iterate/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## circuit-breaker-conditions

収束トレンド判定式の較正根拠（7 本のトラジェクトリによる backtest — 受入基準の契約値 3 本 /
実 run から復元した 3 本 / escape 節を守る合成列 1 本）は helper の header が SoT で、各列の出所は
helper のテストが持つ。

`cc >= max_cycles` を先に評価するのは、両立時にどちらを `CB_REASON` として報告するかを決めるため
だけであり、独立性そのものは変えない。backstop を残す以上、16 cycle 以上を要する収束中の run は
既定値のままでもこの経路で停止する。引き上げ前の 5 では 6 cycle 以上を要する収束中の run を殺して
いた — backtest の `12,5,3,2,2` がその形で、cycle 5 時点でも blocking が 2 件残っている。

既定値を 15 へ引き上げた実測起点は run `8,5,4,6,3` で、収束トレンド判定が**判定の下りた head では
一度も発散と判定しなかった**にもかかわらず、cycle 5 完了時点（`cycle_count == 5`、cycle 6 のループ
頭）で backstop が発火した。この実測では判定は現 run の結果が 3 件揃うまで降りる — どの reason で
降りるかは results dir と run 開始点 pin の状態で分かれるため、内訳は本体ステップ 1 の
`TREND_REASON` 説明を参照。`10,9,8,7,6` は「漸減が続くが 0 に達しない」escape 節の対象で、本経路へ
委ねること自体が設計どおりの帰着（AC-3）であり過剰発火例ではない。既定 15 は「引き上げ前の 5 が
実測で不足したことへの暫定対応」で、最適値は運用データで再評価する。

cycle 数上限は努力と無駄を区別できない — 健全に収束中のループも残り数件のところで予算切れになり、
発散しているループも上限まで燃やしてしまう（どちらも実運用で観測済み）。「品質を予算で縛らない・
無駄は排除する」（CLAUDE.md プロジェクト原則）に従い、切るのは発散であって収束に向かう実サイクル
ではない。

## step0-canonical-pattern

`{issue_number}` / `{branch_name}` の復元をスキル冒頭に置くのは、standalone 起動でも
`flow-state.sh set` が両フィールドを必須とするため。skills/open/SKILL.md Step 0 の canonical
pattern（一行 + `|| var=""` fallback）と対称化する。

## worktree-ensure-preamble

ループ前に session worktree を保証しないと、worktree 不在（resume / context 圧縮 / 別セッション
跨ぎで欠落）のまま review/fix を invoke し、メインツリー（develop）上で PR 変更を読めないまま
degraded に回り続ける。`--branch` 明示は helper の issue-N ref 推定を避け、同一 issue に複数
ブランチがある場合でも対象を決定的に選ぶ。

各 review/fix cycle の入場でも `/rite:pr-review` / `/rite:fix` が同じ helper を通すため、cycle
途中で worktree が失われても次 cycle 頭で再保証される。ステップ 0.5 はループ全体の前段ゲート。

## cycle-counter-init

counter を flow-state の `cycle_count` に置くのは resume 跨ぎ継続（AC-3）のため。fresh / resume
判定を phase で分けるのは、run バッチで前 Issue の counter が同一セッション flow-state に
merge-preserve され次 Issue に漏れるのを防ぐため。発火時はステップ 6 共有前段が 0 に戻すので、
発火後の再実行は本ステップで何もしなくても cycle 1 から再開する（override を持たない）。

## reset-refire-run-since

`RESET` は reset を試行した場合の診断値であり、停止通知の注意行の条件には使わない。条件は
`REFIRE` と `FIRE_RESET`。`failed-stale` に注意行を付けると、真の非収束停止に「review は 1 cycle
も回っていません」という偽の説明が付く。

`REFIRE` を reset 試行前の値で立て、成功時に落とすのは、`ITERATE_CYCLE=0; REFIRE=1` という
自己矛盾 marker を出さないため。失敗時に `cur_cc` を 0 に落とさないのも同じ invariant の鏡像。

run 開始点 pin を `cycle_count` ではなく独立ファイルにする理由は helper header の「Why run 境界に
run-start pin を使うか」が SoT。保存失敗と review 中断で「現 run のファイル数 == cycle_count」が
破れる。判定を `fresh || cur_cc == 0` の選言にするのは、fresh で reset が失敗した経路（marker
整合のため `cur_cc` を 0 に落とさない）で pin を据え置くと、ステップ 1 が stale pin と残存
counter を同時に渡し helper の stale pin guard 前提が揃わず、前 run を含む混合列で発火するため
（AC-1 の否定）。`cur_cc == 0` 側の項は、ステップ 5.0.1 / ステップ 6 が counter を 0 にして run
を閉じた直後の起動（phase 維持のため resume 判定になる）を拾う。

pin 書き込み失敗時に残った pin を消すのは、残る pin が前 run の開始点であり「pin より新しい
ファイル」が前 run + 現 run の連結列になるため。helper の stale pin guard は空 since または
`cycle_count == 0` が前提なので、非空 pin かつ 2 cycle 目以降ではその列が判定にかかり、前 run の
最良水準が `prefix_min` に居座る（実測: `5,3,1,0,8,8` は cycle 6 で fire）。pin を消せば
`absent` → `--since ""` となり、前 run が同居していれば `実在数 > cycle_count` で用意済みの
`run_boundary_unresolved` へ倒れる。

`RUN_SINCE`（記録側）と `RUN_SINCE_USED`（消費側）を分けるのは、0.6 で記録に成功しても resume した
別プロセスが state root を解決できなければ消費側だけ失敗しうるため。`write-failed-pin-retained`
だけが誤発火側で、それ以外の縮退は「判定を降ろす」（停止側）。

## fire-no-counter-reset

ステップ 1 の fire 分岐で counter をリセットしないのは、6.1 / 6.2 が sentinel を emit する前に
turn が終わると発火の記録が残らないまま counter だけ 0 になり、同じ set が handoff も消すので
Stop hook が停止を許可するため。その後 recover は phase=review のまま iterate へ戻し、発火が
1 度も報告されないまま満額でループが再開する。counter を上限のまま残せば、その窓で中断しても
次回ループ頭で再発火する — 縮退が停止側に倒れる。

直前の `[fix:pushed]` が残した継続 handoff を default-clear しないと、fire 後に turn が終わった
とき stop-loop-continuation.sh が `/rite:pr-review` を再注入し、サーキットブレーカーを無視して
ループが続く。

increment 失敗時に marker の counter を前進させないのは、永続 counter は据え置きなのに marker
だけが進むと、観測者が停滞とずれを切り分けられなくなるため。

## terminal-cleanup-age-guard

`pr-cycle-cleanup.sh` は review 開始時にも走るが、それは各 review **開始時** の発火であり、
**最後の** review/fix cycle が残した残骸を sweep する後続 review が存在しない。終端で明示発火
させ、回収の到達性を担保する。

`rite-review-mutation-*` / `rite-revert-test-*` detached worktree は cross-session in-flight
保護のため mtime 24h 未満は保護される。よって本ループが直前に作った若い worktree はこの発火では
消えず、次回 cleanup（24h 経過後）で確実に回収される。即時 0 残骸ではなく **確実な最終回収**
を担保する設計。即時回収には reviewer 側の session-scoped 記録が必要だが reviewer
（`agents/_reviewer-base.md`）は当時の Non-Target。

## run-close-reset

終了 3 経路はいずれも counter を残したまま終わるため、同じ PR への次の `/rite:iterate` が
resume と判定され、ステップ 0.6 の pin 更新（`cur_cc == 0`）に入らない。新しい run が前 run の
pin を使い続け、helper は「pin より新しいファイル」= 前 run の結果を現 run の列として読む。前
run の最良水準（`[review:mergeable]` 出口なら 0）が現 run の `prefix_min` に持ち込まれる。害は
「必ず殺される」ではなく「前 run の最良水準が居座り、以後の平坦・反転が過剰に発散と判定される」
こと — escape 節 (2) が効くため単調下降を続ける健全な run は stale pin があっても本判定では
切られない（実測: `5,3,1,0,8,4,2` は最後まで `ok`）。発火するのは新 run の 2 値目が下降しない
場合で、最小例は `5,3,1,0,8,8`（`fire_at=6`）。

`--handoff` を既存値で載せ直すのは、省略すると `flow-state.sh set` が handoff キーを削除し、
ステップ 5 冒頭の FINALIZE 差し戻し保証が通知前に失われるため。ステップ 1 fire 分岐が
「sentinel 前に counter を 0 にすると発火が無記録になる」として reset を遅らせているのと同型
の窓。`--phase` をハードコードすると `[fix:cancelled-by-user]` / `[fix:replied-only]` で
`fix` → `review` に書き換わり、中断通知の「phase=fix のため fix invoke から再開」が偽になる。

## cb-mode-and-reset

`/rite:batch-run` は駆動中に `active=true` を立て、cursor が処理中 Issue を指す。iterate は
batch-run から同一セッションで invoke されるため、ambient session_id と run-queue の
session_id は一致し、自セッションのキューだけを参照する。`active` 条件は、停止済み dormant
キューが cursor 一致だけで active batch と誤判定されるのを防ぐ。

counter reset をステップ 1 fire ではなく共有前段で行うのは、直後の 6.1 / 6.2 が sentinel を
emit するため。ここより手前で turn が終わった場合は counter が上限のまま残り、次回ループ頭で
再発火する。発火済みを `cycle_count` の相対値（例: max + 1）で符号化しない — 
`max_review_cycles` が invocation 間で変わると両方向に破綻するため、上限から独立した文字列の
`stop_reason` を同じ set で記録する。`--stop-reason` をステップ 1 fire 分岐に書くと本 set
（`--stop-reason` なし）が default-clear で消す。post-breaker full review が成功してループが
継続した場合は、後続の set が default-clear するため stale な失敗記録は残らない。上限値その
ものは埋め込まない。

`session_id` / `state_root` を marker に載せるのは、注意行 (b) の手動リセットが `--session`
なし・repo 外 cwd で rc=0 のまま別ファイルを作り、当の counter が手つかずで残るため。2 軸の
片方だけを塞いでも空振りは塞げない。空の state_root を sentinel にするのは、resolver が cwd
削除時にも rc=0 で空文字を返し、`RITE_STATE_ROOT=` が未設定と同義へ縮退するため。

## post-breaker-invariant

ブレーカー発火だけで成功・完了と判定してはならない。差分スコープ外の盲点を検査する full
review を 1 回実行し、その finding の有無を既存の review routing が判定する。発火そのものから
Ready / merge へ直行する分岐は存在しない。停止通知に記す `/rite:ready` は人間が明示的に叩く
経路外のアクションであり、本ステップの自動フローが辿る分岐ではない。

`FIRE_RESET=ok` のとき共有前段と同じ Bash block 内で pin を更新するのは、
`review-cycle-scope.sh` が pin より新しい JSON が 0 件のとき `REVIEW_CYCLE_SCOPE=full;
reason=no_prev_json` を返すため。次の `/rite:pr-review` が差分スコープへ戻る経路を機械的に
閉じる。

両分岐は挙動として同構造で、差は sentinel の消費者と対話側だけが持つ注意行の 2 点。共有前段
の counter reset は batch 経路にも適用されるが、ステップ 6.1 のブロック自体は無変更であり
当時の Non-Target に抵触しない（batch では従来も次 Issue のステップ 0.6 fresh 判定で同じ
counter が除去されており、より早く掃除されるだけで安全側）。batch で stale counter の reset
に失敗した場合、review を 1 cycle も回していない Issue が `failed[]` に「上限到達（非収束）」
として記録されうる。対称化は別 Issue。

失敗停止の理由は両モードで永続化する。対話側も `session-start.sh` / `/rite:recover` から
fresh review や Ctrl+C 中断と区別できる。`stop_reason` は後続の通常 set が default-clear
するため、新しい run の進行後まで stale に残らない。

## notice-trend-and-notes

推移行を省略しないのは、発火が「予算切れ」ではなく「構造的な発散の検出」であることを人間が
読んで検証できる唯一の材料であり、AC-4 が通知への包含を要求しているため。上限到達だけを見て
「発散判定をすり抜けた」と書くと、両方成立時や 3 cycle 未満の未実施時に事実に反する。

差し替え条件を `TREND=` の空判定にしないのは、`need_3_cycles` だけが部分トレンドを非空で返す
ため。空判定では差し替えが効かず、判定にかけていない推移を判定済みデータとして描画する。
行ごと省略すると、推移が無いことと出し忘れたことが区別できなくなる。`LOST` 併記は、欠落が
verdict を反転させうるため合成された推移を実測として提示しないため。

注意行の値照合を完全一致にするのは、部分一致だと `failed` ⊂ `failed-refire` /
`failed-stale`、`write-failed` ⊂ `write-failed-pin-retained` の衝突組が本ファイルに live な
ため。値側規約の所有者は `context-marker.sh` header の rule 5。

`RESET` を即再発火の判定に使わないのは、発火時の phase が `review` / `fix` なので再実行は
resume 判定となり reset ブロックに入らず、即再発火する当の経路で `RESET=none` になるため。

(b) に handoff 迂回を書かないのは、counter reset 失敗と handoff クリア失敗が独立した別 set
であり、共有前段の set は `--handoff` を伴わないため handoff を default-clear するから。
迂回が成立するのは両方の set が失敗したときだけなので独立条件 (c)。

(b) 観測時に再開方法第 1 bullet を差し替えるのは、テンプレートが約束する「cycle 1 から回る」
が手動リセットまで偽であり、注意行と並べると矛盾する 2 つの再開手順を提示するため。差し替え
単位を物理行数で指定しないのは、文面が変わるたびに行数が drift し、孤立行禁止を破る指示に
なるため。(a) のみでは差し替えない — (a) では counter は共有前段で正しくリセットされており
元の 1 行が真。(c) は (b) 内の手動リセットを「上記の」で参照するため、順序を崩すと前方参照
になる。

`SESSION_ID` が空のまま `--session` を埋めると `--session --phase` となり即失敗する。
`STATE_ROOT` が空や sentinel のまま埋めると cwd へフォールバックする。実在確認をリセット
コマンドの手前に置くのは、誤った root/session_id でも `flow-state.sh set` が rc=0・無出力で
新しい state を作り、事後の `get --field cycle_count` では正しくリセットした場合（キー削除）
と空振り（新規 state にキーなし）が同じ結果を返すため。

`cycle_count` を設定上限と比較しないこと — 発散発火はつねに上限未満で成立するため、比較を
条件にすると発散発火が残した state に対して解が空集合になる。`cycle_count >= 1` は両発火理由
に共通で、正常終了・fresh entry の state は 0 またはキー欠落なので候補を絞れる。

## lost-repair-gate

`LOST=N` 注記は観測であり、次 cycle の開始を止めない。保存ステップの脱落は全ホストで実測される普遍現象で、注記のまま進むと trend が穴あきの列を実測として読む。修復が安価なのは「結果がまだセッションコンテキストに残っている」境界だけで、そこを過ぎると再レビュー以外に穴を埋める手段がない。

ゲートを increment / CB より前に置くのは、次 cycle を始める前が唯一の遮断点だから。CB を先に評価すると、穴あき列で発火理由が確定し、修復の機会を失う。`lost > 0` を増分とするのは、本ゲート導入後は穴を抱えたまま進めないため「前回からの増加」と「現在の不足」が一致するから。helper に `lost_delta` を足さない — 既存 `lost=` で足り、返却値の追加は必要時だけという契約に従う。

(a) を既存 `review-result-save.sh` に閉じるのは、必須フィールド・schema 検証を二重実装しないため。虚偽保存のうち形式不合格は helper が弾き、形式合格の捏造だけが残る — merge ゲートと同じ受容済みトレードオフ。(a) の成功条件は helper の値域 `JSON_SAVED=true`（`=1` ではない）。(b) で counter を進めないのは、再レビューが「次 cycle」ではなく「当該 cycle のやり直し」だから。marker の `cycle=` を永続 counter に一致させたまま `INC=held` とするのは、既存の counter invariant（marker と永続値が一致）を壊さないため。

(b) 後の成立観測は `JSON_SAVED=true` / `REVIEW_SAVE_JSON_OK=1`。`[review:mergeable]` は使わない — 未保存のまま素通しすると batch が収束扱いする。不成立は `ITERATE_LOST_REPAIR=failed` を出して iterate 失敗形で止める。新しい停止 sentinel は作らない — caller（batch-run）の既存「sentinel 不在 / `[review:error]` → 失敗停止」に倒す。

fire 分岐でも `--handoff` なしの `flow-state.sh set` を呼ぶのは、直前 `[fix:pushed]` の継続 handoff が残ると Stop hook が `/rite:pr-review` を再注入し、ゲートを迂回するため。`--cycle-count` は付けない（INC=held）。

`_undecidable` は `lost=` を出さない。coerce で空を 0 にすると `cc>=1` かつ JSON 0 件（`no_results_file` / `results_dir_missing` / `no_file_after_pin`）でゲートが発火しない。helper の lost 算出は変えない — 消費側が raw 欠落 + 当該 reason + `cc>=1` で fire する。`cc=0` と `helper_unavailable` は発火させない。

8.0.4（pr-review 内）と LOST 注記は触らない。ゲートは境界に足す層であり、内側の保存ゲートや観測注記の置換ではない。

## design-decisions

blocking の定義式は本ファイルに複製せず severity-levels.md の実測必須ゲートを SoT とする。
同節は reviewer finding に閉じた canonical 式と fix loop 全体を対象とする consumer 式の差を
「適用範囲」で意図的なスコープ差として定義している。本スキルはループ側なので後者に従い、
実測の有無を判定できない指摘は blocking のまま扱う。実測を伴わない指摘は non-blocking として
記録されたまま残存するため、非実測指摘が残った状態でも `[review:mergeable]` に到達する。
残存分の消化は完了通知前の 5.S（`/rite:fix --nb-sweep`）が担い、人間の draft レビューに委ねない。
細粒度の安全網（同一 finding
検出 / quality signal escalation）は持たない（CLAUDE.md「シンプルさを死守」）。

主経路を発散検出にし、cycle 数上限を backstop へ格下げしたのは、cycle 数上限だけでは努力と
無駄を区別できないため。判定は helper に閉じ LLM の裁量を介在させない。判定式は実運用
トラジェクトリで backtest して確定した定数であり、窓幅や閾値を config キーにしない — 調整の
実需が観測されてから Issue を切って設定化する（`no_speculative_structure`）。較正根拠と意図
した境界（最良水準での平坦は発火させない = false positive 回避）は helper の header が SoT。
既定 15 の根拠は #2129 D-02。

発火理由は post-breaker routing を変えない。sentinel は理由に依らず不変で、`/rite:batch-run`
の failed 記録契約を保つ。

cycle counter は専用 state file を持たず、flow-state の merge-preserve フィールドとして
永続化する（`worktree` と同じ additive パターン）。リセット経路は fresh entry / 発火時 /
正常終了時の 3 つ。共有前段は counter reset と `stop_reason` を同じ atomic set に載せるため、
共有前段の実行後・sentinel 出力前に turn が終わっても発火理由は durable に残る。Stop hook の
handoff とも独立（handoff は one-shot consume される継続マーカー、cycle_count は accumulate
されるカウンタ、`stop_reason` は次の通常 set まで残る失敗理由）。

別 Issue 化経路は廃止済み — 「別 Issue にスキップして loop 終了」の抜け穴は塞がれている。

## nb-remaining-notice

完了通知の残件欄をテンプレート必須欄にするのは、LLM の自発的補足と Stop hook 差し戻し再出力の
両方で欄が脱落する実測があるため。5.S overlay 後は残件 0 固定（JSON の配列長は消化前の値）。
取得失敗は 5.S の fail-loud で停止し、完了通知へ進まない。0 件でも欄は省略しない。
`done` のときだけ消化内訳行を足し、`noop` は従来の 0 件通知のまま（AC-4）。
`[review:mergeable]` sentinel は下流 routing が依存するので変えない。
replied-only / 中断 / サーキットブレーカーのテンプレートは対象外。

## nb-sweep-step

`[review:mergeable]` を完了へ直結しないのは、残存 NB を人間消化に残す運用を構造的に閉じるため。
consume を `/rite:fix --nb-sweep` に閉じるのは、既存 1.0.1 flag parse と修正実装を再利用し、
iterate 本体に三択を複製しないため。`[fix:sweep-done]` を `[fix:pushed]` と分けるのは、後者が
ステップ 1 へ戻ってフルレビューを起こす契約だから（MUST NOT）。JSON 取得失敗を完了通知の
「取得失敗」欄にしないのは、未消化のまま正常出口へ進む経路そのものが本 Issue の対象だから。
one-shot は sweep 後の新規 class-B を Issue 化に固定して 2 周目を作らない収束保証。
6.1.d 本文へ `### 却下台帳` を足すのは新チャネル禁止（既存コメントの拡張）。次 cycle の
`{rejected_ledger}` 注入は 6.1.d rewrite が台帳を消すと無意味になるため、merge-into helper
が count 行直前へ機械 splice する。

再入の権威を会話 marker に置かないのは、`[fix:pushed]` でステップ 1 に戻ったあとに marker が
見えなくなり 5.S が再走する実測があるため。会話 marker 既出を skip 条件に残すと、0.6 が
ファイルを消した同一会話の再 iterate で AC-7 の再 sweep が死ぬ。`.rite/state/nb-sweep-done-{pr}.txt` の存在が
skip（中身 1 行は完了通知の noop/done 出し分け）。書込直前に既存 `_ensure_dir_gitignore` を
呼ぶのは、setup の dir_entry が `.rite/state/` を含まない消費者が `git add -A` で skip 権威
ファイルを stage する穴を、setup 再実行に依存せず塞ぐため。新 helper は増やさない。失敗は
WARNING で続行し、偽 skip はしない。寿命は本 run — 0.6 の
`fresh || cur_cc == 0`（pin 書換と同条件）で消し、cleanup でも回収する。cleanup まで残すと
再 iterate と post-breaker 5.S が skip され未消化 0 の再保証が死ぬ。write 失敗時は `rm -f`
してファイル非存在として本体へ（偽 skip 禁止）。`--nb-sweep` 戻りはステップ 4 汎用表を使わず、
`[fix:pushed]` / `[fix:pushed-wm-stale]` / `[fix:replied-only]` でもステップ 1 に戻らない。
