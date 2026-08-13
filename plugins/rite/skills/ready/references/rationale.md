# /rite:ready — 設計理由

`skills/ready/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## standalone-confirm

Ready 化は外部公開状態を変える。e2e 本経路では orchestrator が既に確認済みなので二度目は
Simplification Charter の重複 confirmation。side path / `active=false` / helper 失敗は fail-safe
で standalone 確認へ倒す。「silent confirm」より「silent skip」を避ける。

`flow-state.sh` の `--default ""` は stored false と missing の両方を `""` にする。`[ "$active" =
"true" ]` の AND だけが安全。`[ x = "false" ]` は禁止（flow-state.sh の caveat）。legacy
`phase5_post_*` は現 writer が無く、pre-v3 残渣の resume 互換のため whitelist に残す。

## bang-backtick-hard-gate

lint の bang-backtick は warning（`[lint:success]` を保つ）。本ゲートは同じパターンで Ready 遷移を
**止める**。lint は早期注意、こちらは Ready 直前の最終 hard gate。invocation failure は可逆診断
なので orchestrator が 1 回 retry し、2 回目で `[ready:error]`。未検証の force-continue は出さない。

## ready-error-phase

`phase=pr` に書くと recover が `/rite:open` ステップ 6 へ戻り、既存 PR に対して `/rite:pr-create`
を再 invoke する。専用 `ready_error` なら `/rite:ready` へ戻れる。

## projects-delegate

旧 ready.md の multi-stage inline pipeline は substep 間で LLM attention が切れ、Status が
In Progress のまま残る事象があった。`projects-status-update.sh` に委譲する。`auto_add: false` は
ready 時点では open ステップ 2.4 が既に登録済みのため。query は `repository(owner:)` 形式
（User / Organization 透過）。旧 inline の `user(login:)` + Organization fallback は不要になった。

## no-silent-skip-status

旧仕様は `skipped_not_in_project` / `failed` を silent skip し、observation が残らず Status が
In Progress に滞留した。両経路は必ず `WARNING` を stderr に出す。Ready 遷移自体は Phase 3 で完了
済みなので Status 失敗は non-blocking。

## no-handoff

ready はループの出口であり、ユーザー判断で merge へ進む。継続保証は flow-state の `next_action`
（resume 用）に委ねる。詳細: stop-loop-continuation-contract.md。

## returned-to-caller

旧 `ready:completed` は *terminating the workflow* と読まれ、LLM turn-boundary heuristic が誤発火
する。HTML コメント化で user-visible 末端と caller signal を分離する。e2e で完了レポートを出すと
caller と二重になる。

## error-count-reset

`error_count` は reserved/legacy schema slot で production reader が無い。transition で 0 に戻し、
stale count を運ばない。
