# /rite:issue-cancel — 設計理由

`skills/issue-cancel/SKILL.md` から退避した rationale（設計理由・背景・過去の判断）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・marker 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## human-initiated-only

中止するかどうかは要件側の判断であって、実装側の観測から導けない。「レビューが収束しない」「実装が難しい」
は中止の理由ではなく作業の状態にすぎず、そこから自律的に中止へ倒す経路を作ると、人間が持つべき要件判断が
assistant 側へ移る。人間の役割を「要件・仕様を伝える」と「完成品を動かして動作チェックする」の 2 点に保つ
ため、起動は明示指示に限る。

中止した Issue の復帰（reopen）経路も同じ理由で作らない。実需が存在しないうちに用意する拡張点は、将来
使われないまま仕様を重くする。

## no-reconfirm

理由を取得した時点で「破棄する」という判断は済んでいる。その後の各手順（PR クローズ・ブランチ削除・
worktree 削除）で個別に確認を挟むと、人間の品質判断を工程の途中に常駐させることになり、1 回の中止に
複数回の応答を要求する。確認はワークフローの入口 1 箇所に集約する。

同じ理由で、`in_worktree` かつ dirty な作業ツリーでも stash 確認を出さない。中止経路で捨てようとしている
のはまさにその未コミット変更であり、`/rite:cleanup` の dirty 確認（マージ済みの作業を守る目的）とは前提が
逆になる。

## order-invariant

`post-compact.sh` の PR Status reconciliation は「open かつ `isDraft=false` の PR」に発火し、対応する
Issue の board Status を `In Review` へ寄せる。Status を `Cancelled` にしてから PR を閉じる順序では、
その間に compact が走ると Status が `In Review` へ引き戻される窓が開く。PR を先に閉じればこの発火条件が
消えるため、順序そのものが窓を塞ぐ機構になる。

PR クローズが失敗した場合に Status だけ進めると、同じ窓が開いたまま「board は Cancelled、PR は open」
という不整合が残る。フォールバックせずエラーで止めるのは、この不整合を見過ごさないため。

## helper-delegation

worktree 退出・ブランチ削除・PR-specific state 削除は `/rite:cleanup` から helper へ抽出済みで、
live-cwd guard・sandbox マスク検知・squash 残渣の扱い・remote ref の完全一致検証といった非自明な判断を
内側に持っている。中止経路へ bash を複製すると、これらの判断が片方だけ更新される drift 源になる。
中止側は helper の呼び出しと marker の解釈だけを持つ。

## force-delete-no-ask

`cleanup-branch-delete.sh` は `--pr-merged false` に対し `BRANCH_DELETE_UNMERGED=1` を emit し、
`/rite:cleanup` 側はこれを「未マージの作業を誤って消さない」ための確認に接続している。中止経路では前提が
逆で、未マージであることは異常ではなく中止の定義そのもの。ここで確認を挟むと「ブランチが残らない」という
中止の完了条件をユーザーの再応答に依存させることになるため、marker を受けて強制削除へ直行する。

`BRANCH_DELETE_DEFERRED=1`（別セッションが作業ツリーを使用中 / sandbox マスク）は別で、これは削除が
Git 構造上できない状態を指す。強制しても壊すだけなので残置として報告する。

## keep-wm-replica

ローカルの `.rite/work-memory/issue-{N}.md` は削除するが、Issue コメント側の replica は残す。ローカル
ファイルは再生成される作業状態のキャッシュで、中止後に残しても `post-tool-wm-sync.sh` が別 Issue の作業へ
混ぜ込む余地を作るだけ。一方 Issue コメントは「何をどこまでやって、なぜやめたか」を後から追える唯一の
場所であり、中止理由コメントと同じ場所に置いておくのが自然。

## no-wiki-ingest

Wiki に置くのはプロジェクトドメインの経験則で、個別 Issue の中止理由はそこに昇格する種類の知見ではない。
中止のたびに raw source を積むと、Wiki が「やらなかったことの記録」で薄まる。中止理由は Issue コメントに
残り、必要なら後から人間が Wiki へ昇格させられる。

## no-parent-propagation

**子 → 親**: 親の auto-close は「全子 Issue が CLOSED」を条件に発火する。`Cancelled` の子も GitHub 上は
CLOSED なので、素直に配線すると「1 件も完成していないのに全子 CLOSED」で親が `Done` になりうる。中止は
完了ではないため、子の中止からは親の Tasklist 更新も Status 更新も auto-close も行わない。親の完了判定は
`/rite:cleanup` / `/rite:issue-close` の経路が持ち続ける。

**親 → 子**: 親を中止しても子を自動中止しない。子ごとに中止の妥当性は異なり、まとめて葬ると個々の判断が
記録されない。各 Issue の中止は明示指示で行う。
