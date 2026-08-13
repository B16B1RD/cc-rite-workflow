# /rite:learn — 設計理由

`skills/learn/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## vibe-coding

rite は実装の多くを Claude が書くため、「動くからマージする」= 自分で書いていない変更を理解しない
まま取り込む vibe coding が起きやすい。hooks / skills の変更は他作業に即波及するため、理解の
取りこぼしのコストが高い。解説して終わりにせず、本人が自力で説明できる状態をゴールにする。

## issue-pr-number-space

GitHub では Issue と PR が単一の番号空間を共有する。番号トークン `#N` はどちらか一方を一意に指す。
network / auth / rate-limit 等の一時障害を not-found と同一視すると Issue へ誤分類するため、失敗
種別を区別する。完了セッションは merged 済みが多いため PR 探索は `--state all` が必須。

## no-flow-state

learn は Issue→PR の状態機械の外側にある終端 ritual。後段に連鎖しないため、flow-state 系
sentinel（`returned-to-caller` 等）や `flow-state.sh` は呼ばない。
