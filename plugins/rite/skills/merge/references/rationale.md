# /rite:merge — 設計理由

`skills/merge/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## no-flow-state-prereq

flow-state は離散コマンド運用（`/clear` 毎）では writer（`/rite:open`）と reader（本スキル）が別
セッションになり常に空を読む。前提チェックを設けると不在を異常扱いしてしまう。

## rematch-once

`gh pr view` の mergeable 計算は数秒〜数十秒遅延する。自動 sleep / 自動再判定ループは iterate の
review⇄fix とは別経路で、こちらは 1 回のみの再判定に留める（ping-pong 防止）。

## merge-only

cleanup を呼び出さない（`pr.auto_cleanup_after_merge` 等の設定キーも追加しない）。マージ完了時点
では `phase=ready` のまま。`completed` への遷移は `/rite:cleanup` 末尾で行う。

## merge-method

squash を禁じて merge commit でマージするリポジトリがある（作業ブランチのコミット SHA を出典として
残すため）。squash 固定だとそこでは `/rite:merge` を使えず、人が rite の外でマージすることになる。
そのため `merge.method` で `squash` / `merge` を選べるようにし、キーが無い設定は従来どおり squash にする。

`rebase` は受け付けない。マージコミットが作られないので件名・本文の規約を適用する先が無く、
別の設計が要るため。不正値を squash に倒すと、merge commit を求めるリポジトリで黙って squash して
しまうので、helper は exit 1 で止める。

方式は helper の出力を `--{merge_method}` へ literal substitute して渡す。シェル変数の形にすると、
実行前 guard が merge の argv を静的に確かめられなくなる。

develop → main の昇格を検証する `release-promotion-verify.sh` は squash 由来のコミットだけを前提にするが、
これは plugin 自身のリリース手順専用で、配布先の `merge.method` とは関係しない。

rite の外でマージした PR も、`/rite:cleanup <branch>` を実行すれば先送りした欠陥を follow-up に起票する。
cleanup は PR の `mergedAt` と元 Issue の Decision Log だけを読み、`/rite:merge` を通ったかを見ない。

## stderr-split

`2>&1` で stdout merge すると warning が混在し原因診断が困難になる。成功時の warning surface を
then-branch に閉じるのは、失敗時 else の head と二重出力になるため。

## ci-gate-at-merge

Ready 化は CI 完了前にも行う操作なので変更しない。`--force-ci` は緊急時の明示的 override。
既定経路は unhealthy / 分類不能を fail-closed で停止する。pending は待ち loop（`ci-wait-bounded`）
で完了を待ってから同じ分類へ合流する。mixed
pending+unknown を pending に落とすと `--force-ci` で unknown を迂回できるため unknown を先に判定する。

## ci-wait-bounded

CI 実行待ち（分単位）は mergeable 再計算遅延（秒単位、`rematch-once`）とは別問題。iterate の
最終 push 直後に ready → merge すると checks が pending のまま来ることが構造的に起きる。

待ちは merge スキルのステップ 1 に置き、1 block の待機を 540 秒で区切る。Bash ツール最大
600 秒に収めるため（`timeout: 600000`）であり、CI の所要時間の上限ではない。pending なら
継続 sentinel で同じ block を再実行し、完了まで待つ。総上限・設定キーは追加しない。
CI 側の `timeout-minutes` による cancel も完了状態として既存分類で停止する。間隔 15 秒。
background 実行は採らない。`gh pr checks --watch` は使わず既存 jq 分類を
再評価する（checks 0 件・exit code 8 の吸収と分類の二重化を避ける）。混在 pending+FAILURE は
fail-fast せず `!= pending` まで待つ。unknown は待ちを打ち切る。`--force-ci` では待たない。
