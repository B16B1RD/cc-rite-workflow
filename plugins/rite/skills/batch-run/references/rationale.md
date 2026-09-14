# /rite:batch-run — 設計理由

`skills/batch-run/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## default-draft

デフォルトは各 Issue を open→iterate まで進めて draft PR を残し、自動 merge しない安全側に倒して
人間のレビューを待つ。`ready→merge→cleanup` は `--merge` の明示オプトインに限る。merge→cleanup
の意図が名前で明示されることを重視した（D-01）。

## breaker-stop

iterate は収束トレンドの発散検出、または `safety.max_review_cycles` 到達（backstop）で
`[iterate:max-cycles-reached]` を emit する。**sentinel は発火理由に依らず同一の literal**。run 側
は理由を区別しない — 理由別に sentinel を分けると grep 契約が壊れる（名称の `max-cycles` は発散
発火に対しては misnomer だが、契約の安定を優先）。発火は当該 Issue を完了できなかった失敗であり、後続へ進む根拠にはならない。cursor を保持してバッチを停止し、明示再開で当該 Issue から復帰する。

## resume-stage-dispatch

停止報告は引数省略の `/rite:batch-run` で残りを再開できると案内するが、ステップ 1 が
`RUN_NEXT=process` を出すと無条件に open を呼んでいた。open の resume 表は PR 作成より後の phase
（review / fix / ready / cleanup）を扱わない設計のため、それらで止まった Issue は open が完了通知を
出さずに戻り、run は open 失敗として同じ Issue で再び止まる。案内と実挙動が食い違う。

振り分けは run 側に置く。phase→スキルの対応は recover Phase 5.3 が SoT で、run は phase→自分の
ステップへの入口だけを持つ（表を複製しない）。evaluate は run 起動あたり 1 回に限る — ループ再入の
時点では直前の Issue の cleanup が flow-state を `active=false` にしており、Issue 不一致 / 非 active
ガードで常に open に落ちるため評価しても結果が変わらない。無条件に open へ進めば bash の実行と
marker の読み取りを Issue ごとに省ける。
phase=`ready` は ready 化が完了した状態で、`/rite:ready` は既に Ready の PR に対して sentinel を出さずに
終了する。ready を再 invoke すると run は sentinel 不在を失敗と読んで同じ Issue で再停止するため、
merge から続ける。`ready_error` だけを ready の再試行に振る。
`ingest` は recover 5.3 が `/rite:wiki-ingest` の再呼び出しに対応付けており、run のステップに
対応が無い。cleanup 全体の再実行は wiki-ingest 以外の副作用（Projects Status / Issue close の再試行）を
伴うため、推測せず停止して recover に委ねる。
段階を決められない状態（読み出し失敗・壊れた state ファイル・PR 番号なし・未知 phase）は既定で
open へ倒さず停止する。`flow-state.sh get` は JSON 破損でも default を返して rc=0 で戻るため、
読み出し失敗の判定は state ファイルを直接 `jq -e .` で検査する。
default モードで ready / merge / cleanup 段階に達していた場合は、そのモードが ready 以降を実行しない
契約に合わせ、draft を残したまま cursor を前進させる。

## no-handoff

flow-state の `handoff` は単一フィールド + default-clear で、iterate / cleanup が内部で排他使用
する。run が割り込むと sub-skill の継続保証（Stop hook 差し戻し）が壊れる。継続は flat step 構造
に委ねる。デフォルトモードは ready を経由しないため、iterate の残存 FINALIZE は次 Issue の open
（`flow-state.sh set`）が default-clear し、最後の Issue 分のみステップ 7 の `consume-handoff` で
消費する。

Stop hook の batch watchdog は handoff フィールドではなく自セッションの run-queue を読む別軸
である。handoff が非空なら既存の prefix 分岐が先に block し、watchdog は評価しない。handoff が
空で run-queue が `active:true` かつ未完了のときだけ停止を差し戻す。batch-run は handoff を
set しない契約のまま。

## session-scoped-queue

run-queue はファイル名に `session_id` を含めてセッションごとに物理分離する。候補比較: (A)
ファイル名スコープ化 / (B) 単一ファイル + 所有者検証 / (C) 持続ロック のうち、セッションごとに独立したキューを並行して持てるのは
A のみ。flow-state・issue-claim・worktree がすべて per-session である既存アーキテクチャと対称。
session_id 解決不可で global `run-queue.json` へフォールバックすると複数セッションが同じ queue を
上書きする。再開が session_id スコープに厳格化されるトレードオフは、flow-state の phase 解決も
元々 same-session 前提のため一貫性の回復。旧 global `run-queue.json` は新コードから拾わない
（移行コードは書かない）。

## no-dedicated-helper

run-queue は bash の `jq` 直接操作で完結する。各セッションが自分のファイルを順次書くため
atomic は `jq → 一時ファイル → mv` で十分。

## recover-batch-continue

当初は recover.md を変更しない方針だったが、真の active batch 中断を recover 自身が検出できない
と、個別復帰後に残りキューが取り残される。継続時の分岐ロジックは本ファイルのステップ 3-8 の表を
参照する形にとどめ、recover.md 側には複製しない。

## replied-only-mode

`--merge` では mergeable 未到達とみなし merge 前に停止する（未解決指摘の握り潰し防止）。
デフォルトでは merge しないため即停止は不要で、draft を残し「未解決指摘あり」を明示して次へ進める。

## pre-summary-no-ask

サマリは通知のみ。AskUserQuestion を挟むと無確認自律の開始を妨げる。目安時間は件数
ベースの粗い目安であり正確な実行時間予測ではない。

## cursor-not-success

`RUN_ADVANCE` の件数は「キューを進めた件数」であり成功件数ではない。デフォルトモードの
`[fix:replied-only]` もこの前進 bash を通る。サーキットブレーカーは前進しない。内訳はステップ 7 の完了通知。
