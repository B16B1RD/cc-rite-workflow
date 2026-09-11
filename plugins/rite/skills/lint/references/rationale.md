# /rite:lint — 設計理由

`skills/lint/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。チェックごとの検出根拠は
[plugin-checks-rationale.md](plugin-checks-rationale.md) が SoT。

## skip-entirely-display-only

E2E の "Skip entirely" は人間向けサマリー表示だけを省く。lint 実行や work memory 更新まで省くと、
時間・context を理由にした品質スキップになる。出力最小化と処理省略を同一視しない。

## no-direct-pr-create

本スキルが `rite:pr-create` を直接呼ぶと、caller のチェックリスト確認（open ステップ 4.4 /
sentinel 消費 5.1）を迂回し、未完了タスクのまま PR が作られる。sentinel を出して caller に
返すのが唯一の継続契約。

## no-silent-head-fallback

`HEAD` 差分やプロジェクト全体へ黙って倒すと、lint スコープがユーザーの知らない範囲に広がる。
ベースブランチ不在はエラーで止める。差分ゼロの全体チェックは警告を出してから行う。

## no-duplicate-test-in-e2e

open → implement の Test Verification Gate が既に通っているのに lint が再実行すると、同じ
`commands.test` を二重に燃やす。会話 context に成功結果があるときだけ再利用する。

## descriptive-number-blocking

generic loop の `--all` findings は warning のまま `[lint:success]` を保つ（progressive cleanup）。
追加行の裸 number-ref だけは blocking — `number-reference-check.sh --diff`（Phase 3.5 preamble）。
番号を本文に戻す退行を「後で直す」と残すと number-free 面がすぐに崩れる。
diff が読めない（rc=2）も「見ていないのに success」になるため同じ error 経路へ倒す。

## findings-are-warnings

プラグイン自己検査は CI ゲートではない。warning を error に昇格すると、marketplace 利用者の
通常フローが内部 cleanup で止まる。appendix が `warning` と `error`（起動失敗）を同じ形で出す
のは、exit 2 を黙って落とさないため。

## defense-in-depth-state

結果パターンを出す前に flow-state を書くのは、fork 復帰後に LLM が空転して Stop hook を
迂回したターン強制終了でも、再開用の `next_action` が残るようにするため。

`error_count` は現状 reader の無い予約スロット。毎回 0 に戻すのは、stale 件数を次 phase へ
持ち越さないため。

## checklist-guard

open ステップ 5 が `[lint:*]` を消費してから ステップ 6 で PR を作る。lint 側に PR 作成を
持たせないのは、チェックリスト未完のまま提出する抜け穴を構造的に閉じるため。
