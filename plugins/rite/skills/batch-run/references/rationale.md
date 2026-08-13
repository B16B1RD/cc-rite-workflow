# /rite:batch-run — 設計理由

`skills/batch-run/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## default-draft

デフォルトは各 Issue を open→iterate まで進めて draft PR を残し、自動 merge しない安全側に倒して
人間のレビューを待つ。`ready→merge→cleanup` は `--merge` の明示オプトインに限る。merge→cleanup
の意図が名前で明示されることを重視した（D-01）。

## breaker-not-stop

iterate は収束トレンドの発散検出、または `safety.max_review_cycles` 到達（backstop）で
`[iterate:max-cycles-reached]` を emit する。**sentinel は発火理由に依らず同一の literal**。run 側
は理由を区別しない — 理由別に sentinel を分けると grep 契約が壊れる（名称の `max-cycles` は発散
発火に対しては misnomer だが、契約の安定を優先）。非収束 1 件でバッチ全体がストールするのを防ぐ。

## no-handoff

flow-state の `handoff` は単一フィールド + default-clear で、iterate / cleanup が内部で排他使用
する。run が割り込むと sub-skill の継続保証（Stop hook 差し戻し）が壊れる。継続は flat step 構造
に委ねる。デフォルトモードは ready を経由しないため、iterate の残存 FINALIZE は次 Issue の open
（`flow-state.sh set`）が default-clear し、最後の Issue 分のみステップ 7 の `consume-handoff` で
消費する。

## session-scoped-queue

run-queue はファイル名に `session_id` を含めてセッションごとに物理分離する。候補比較: (A)
ファイル名スコープ化 / (B) 単一ファイル + 所有者検証 / (C) 持続ロック のうち、AC-1 を満たすのは
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

サマリは通知のみ。AskUserQuestion を挟むと無確認自律の開始を妨げる（AC-3）。目安時間は件数
ベースの粗い目安であり正確な実行時間予測ではない。

## cursor-not-success

`RUN_ADVANCE` の件数は「キューを進めた件数」であり成功件数ではない。サーキットブレーカーや
`[fix:replied-only]` もこの前進 bash を通る。内訳はステップ 7 の完了通知。
