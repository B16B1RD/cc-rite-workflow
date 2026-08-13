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
既定経路は unhealthy / pending / 分類不能を fail-closed で停止する。mixed pending+unknown を
pending に落とすと `--force-ci` で unknown を迂回できるため unknown を先に判定する。
