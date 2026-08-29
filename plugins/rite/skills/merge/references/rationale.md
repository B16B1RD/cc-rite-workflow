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

## squash-hardcoded

`pr.merge_strategy` 等を追加すると将来対応スキャフォルディングになる。`merge` / `rebase` に
変えたい場合は本ファイルを直接編集する。

## stderr-split

`2>&1` で stdout merge すると warning が混在し原因診断が困難になる。成功時の warning surface を
then-branch に閉じるのは、失敗時 else の head と二重出力になるため。

## ci-gate-at-merge

Ready 化は CI 完了前にも行う操作なので変更しない。`--force-ci` は緊急時の明示的 override。
既定経路は unhealthy / 分類不能を fail-closed で停止する。pending は待ち loop（`ci-wait-bounded`）
で完了を待ってから同じ分類へ合流し、上限到達でまだ pending なら fail-closed。mixed
pending+unknown を pending に落とすと `--force-ci` で unknown を迂回できるため unknown を先に判定する。

## ci-wait-bounded

CI 実行待ち（分単位）は mergeable 再計算遅延（秒単位、`rematch-once`）とは別問題。iterate の
最終 push 直後に ready → merge すると checks が pending のまま来ることが構造的に起きる。

待ちは merge スキルのステップ 1 に 1 bash block として置く。上限 540 秒は Bash ツール最大
600 秒に収めるため（`timeout: 600000`）。間隔 15 秒。設定キーは追加しない。LLM による
block 再実行や background 実行は採らない。`gh pr checks --watch` は使わず既存 jq 分類を
再評価する（checks 0 件・exit code 8 の吸収と分類の二重化を避ける）。混在 pending+FAILURE は
fail-fast せず `!= pending` まで待つ。unknown は待ちを打ち切る。`--force-ci` では待たない。
