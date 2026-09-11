# /rite:issue-implement — 設計理由

`skills/issue-implement/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。レーン境界の設計根拠は
`skills/pr-review/references/complexity-lane.md` が SoT。

## complexity-read-once

Complexity を 5.1.0.1 と 5.1.0.8 で別々に body から読むと、片方だけが片方の記法に対応する
drift が起きる（受理する記法と探索順の SoT は `skills/pr-review/references/complexity-lane.md`。
本節では列挙しない — 記法が増えるたびに 2 箇所を同期する義務が生まれるため）。5.0.C の
helper 1 回が両ゲートへ供給する。

## fail-safe-orientation

レビュー側の `full` は「reviewer を減らさない」= 安全側。本ゲートの `full` は「並列
sub-agent を許可する」= 攻撃側。Complexity を読めなかった Issue を `full` に含めると、不明な
まま並列が走る。判定キーは `COMPLEXITY_LANE=full` 単独ではなく `complexity=` の存在。

## tdd-green-reuse

5.0.T が独自の test runner を持つと、`commands.test` の解釈と失敗時の戻り先が 5.1.0.6 と
二重管理になる。per-behavior Green は実行手順だけ再利用し、rounds 予算と「失敗で 5.1 へ戻る」
は pre-commit のフルゲートが 1 回だけ持つ。TDD 中の並列は Red/Green 状態を共有しない
Refactor 作業に限る — 1 テスト 1 サイクルを崩さないため。

## adaptive-no-fixed-checklist

固定の手順表・閾値は、列挙外の状況で判断を硬直させる。記録義務だけ残し、膨らみの判断は計画
粒度との乖離に置く。

## doc-impact-no-defer

ドキュメント drift を別 Issue に回すと `issue_accountability` に反し、tech-writer レビューが
1 周余分に回る。AskUserQuestion も使わない — 実装と同じコミットで直すのが最安。迷ったら
stale として更新する（過剰更新は drift 放置より安い）。`*.md` glob 決め打ちは拡張子なし
README を取りこぼす。

## production-constraint-churn

過剰生産物は次サイクルの churn の燃料になる（実測: 1 行の設定変更に対して +250 行を生産し、
説明的散文が 2 サイクル分の指摘を生んだ）。follow-up Issue へ回すと削られず残る。削除を
silent にすると「なぜ説明が無いのか」を追えなくなる。

## test-file-discipline

5.1.0.8 の新規テストファイル抑制は light レーン（XS/S）の生産量制約であり、M+ では新規
ファイルを禁じない。抑制を M+ に広げると「新規テストファイルは M+ の装備」というレーン
境界の二値を壊す。全レーンに置くのは規模規律（1 挙動 1 テスト・隣接と同規模・scratch を
残さない・既存 suite 追記優先）であり、light レーンの抑制表は不変。scratch 削除を silent
にすると「なぜそのテストが無いのか」を追えなくなる。

## git-add-dot-sandbox

sandbox 有効環境では read-deny 対象の home dotfile が character-special device としてマスクされ
untracked 表示される。`git add .` はそれらを拾って
`can only add regular files, symbolic links or git-directories` で hard fail する。明示パスだけ
渡す。

## push-no-upstream

`-u` は sandbox 環境で upstream tracking の `.git/config` 書込が拒否される。

## body-file-not-var

`--body "$var"` は Issue body 全体を変数経由で送り、特殊文字・長さで消失・断片置換が起きる。
`--body-file` + 一時ファイルの 3-step（fetch → Write 全文 → apply）が唯一の安全経路。Write が
差分行だけだと他 section が消える。

## parent-step1-no-exit-trap

Step 1 は独立した Bash 呼び出しなので、そこで EXIT trap を掛けると Step 1 終了時に tempfile が
消え、Step 2 の Read が空になる。cleanup は成功時 Step 3、失敗時はその場。

## lint-atomic-pair

commit/push のあと lint を呼ばずに止まると、open のステップ 5 が `[lint:*]` を観測できず
フローが切れる。「次のステップ」案内でユーザーに戻すのは、本スキルが programmatic 専用である
契約に反する。flow-state 書き込みと Skill invoke は対で、片方だけでは再開不能になる。
