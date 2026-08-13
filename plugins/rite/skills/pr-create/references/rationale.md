# /rite:pr-create — 設計理由

`skills/pr-create/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## bang-backtick-gate

lint Phase 3.5 は同一パターンを warning として記録するだけで `[lint:success]` を保つ。本ゲートは
提出直前の hard gate で、同じパターンが残っていると PR 変異を止める。早期の heads-up と最終
block を分離しないと、warning を見たまま提出してしまう。

bash 本体は `skills/ready/SKILL.md` §1.0 と同期する。片方だけ直すと Wiki 経験則
「Asymmetric Fix Transcription（対称位置への伝播漏れ）」が再発する。

exit 1 のあと本スキルの結果パターンは出ない。orchestrator は missing-result-pattern として扱い、
`[pr-create-failed]` には倒さない。検出（rc=1）は「コードを直す」通常経路なので
`BANG_BACKTICK_CHECK_INVOCATION_FAILED` を立てない。立てるのは script 不在 / 起動失敗（rc=2）
だけで、運用者が手動 triage する。

## no-head-diff-fallback

`HEAD` 差分へ黙って倒すと、ベースブランチとの差分ではない要約が PR 本文に入る。取得不能は
エラーで止める。

## issue-accountability-never-skip

E2E でも未対応問題の検証を省くと、`issue_accountability` が「確認は standalone だけ」に縮退する。
対象外 / 既存問題は対応しない理由にならない。5 件以上の一括は UX 用の固定閾値で、config 化は
しない（実需が出てから）。

## no-bash-grep-wm

`grep -A` 等の行数制限つき抽出は、要確認事項セクションが長いと途中で切れる。本文全体を読んで
節を特定する。

## impl-notes-for-reviewers

Plan Deviation Log と Decision Log を PR 本文へ要約するのは、レビュアーが diff だけから
unknowns を再導出しなくてよいようにするため。両ソース 0 件なら節ごと省略する — 空見出しは
「判断が無かった」ではなく「書き忘れた」に見える。

E2E の 30 呼び出しは PR 作成単体の軽量最適化、orchestrator 側 50 はフル緩和。閾値を混ぜると
単独作成でも本文が削られすぎる。

## push-no-upstream

`-u` は sandbox 有効環境で upstream tracking の `.git/config` 書込が拒否される。`gh pr create`
は `--head` でブランチを明示するため tracking に依存しない。

## three-stage-protocol

title / body をインライン heredoc・インライン `--title` で bash に埋め込むと、特殊文字を含む
長文でツールコール解析が malform し、エラーなく無言でターンが終わる。workdir 確保 → Write
tool で raw ファイル化 → 変数 / `--body-file` 経由、の 3 段は title 特殊文字を bash ブロックに
一切インライン展開しないため、この Cause B を構造的に除く。

signal-specific trap は (C) 自身の中断だけをカバーする。3 段は別プロセスに跨るため、
malformed tool-call で (A) 確保後・(C) 到達前に無言終了した orphan（Cause A: harness /
transport 側ゆらぎ、rite では除去不能）は trap では救えない。能動的 GC は
`pr-cycle-cleanup.sh` Step 3 の 24h age ガード。空 title / 空 body は動的生成なので対称に
ガードする。`{PR_CREATE_WORKDIR}` を冒頭で shell 変数へ束縛するのは、placeholder 置換漏れ時の
`rm -rf "{...}"` 誤動作を防ぐため。

## wm-two-step

Phase 3.5 は PR 作成直後に `phase=pr` だけを先に書く。4.1.2 の詳細更新が失敗しても、相転移は
残る。4.1.2 の timestamp が 3.5 を上書きするのは意図どおり。

## missing-sentinel-recovery

Cause A（harness / transport のゆらぎ）は rite 側では消せない。本スキルは flow-state を持たず
caller が `phase` を保持するため、missing-sentinel 検出と `/rite:recover` 再開は orchestrator
の責務。3 段プロトコルは Cause B（インライン heredoc / 特殊文字 title）の発生確率を下げる
だけで、Cause A 自体は残る。
