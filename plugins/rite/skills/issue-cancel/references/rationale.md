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

## branch-first-pr-lookup

`gh pr list` には「この Issue に紐づく PR」を引く手段が無い。`--search "linked:issue:{N}"` の
`linked:issue` は GitHub 検索の boolean qualifier で「Issue をリンクしているか」しか意味せず、`:{N}` は
黙って捨てられる。存在しない Issue 番号を渡しても同じ集合が返る。`--head` は exact-match フィルタで
ワイルドカードを解釈しないため、`"*issue-{N}*"` は常に空を返す。どちらも「絞り込めていないのに
成功して見える」ため、返り値を判定表にそのまま載せると無関係な merged PR で「完了済み」と誤判定する。

確実なのは実ブランチ名を先に確定させて exact `--head` で引く経路だけなので、ブランチ解決を PR 検索の前に
置く。ブランチが確定しない場合は `--state all` で取得してから body の closing keyword で client-side に
絞る（`/rite:issue-close` が持つ経路と同じ）。絞り込み前の集合を判定に使わないことが要点。

## issue-scoped-identity

`/rite:cleanup` は「対象 Issue == 現在のセッション」を前提にでき、`flow-state.sh get` も
`cleanup-worktree-detect.sh` の `in_worktree` 判定もその前提の上で正しい。どちらも `--issue` を取らず、
現セッションの記録／現 cwd だけを見る。

`/rite:issue-cancel` は Issue 番号を**引数で**受ける最初の入口なので、その前提が崩れる。Issue A の
worktree に居るセッションから Issue B を中止すると、identity 検証を挟まない限り Issue A のブランチと
worktree が削除対象になる。しかも `cleanup-branch-delete.sh` はリモート削除の可否を
`--branch-identity-verified` 一本で決めるため、誤った `true` はリモート ref まで消す。

そこで 2 箇所で Issue 番号に束縛する: flow-state は `issue_number` を併せて読んで一致時のみ採用し、
worktree は detect が返したパス末尾が `issue-{N}` であることを確認してから remove へ進む。どちらも
不一致なら「削除しない」側へ倒す — 削除は不可逆で、判定不能のまま進む理由が無い。

## reason-file-outside-worktree

中止理由は不可逆な破棄操作の唯一の監査記録なので、書いた場所が消える経路を残せない。Phase 4.2 は
セッション worktree を削除するため、理由ファイルを worktree 配下に置くと Phase 1 と Phase 6 の間で
ファイルごと消える。`cat` の rc を捨てていれば空文字のままクローズが成立し、「理由の無い中止」が
成功として記録される。

置き場所を `${TMPDIR:-/tmp}` に固定し、読み出し側で rc と空値の両方を fail-loud にする。前者だけでは
0 バイトのファイルを通し、後者だけでは読めなかったことと空だったことを区別できない。

## force-delete-no-ask

`cleanup-branch-delete.sh` が `BRANCH_DELETE_UNMERGED=1` を emit したとき、`/rite:cleanup` 側はこれを
「未マージの作業を誤って消さない」ための確認に接続している。中止経路では前提が逆で、未マージであることは
異常ではなく中止の定義そのもの。ここで確認を挟むと「ブランチが残らない」という中止の完了条件を
ユーザーの再応答に依存させることになるため、marker を受けて強制削除へ直行する。

ただし強制削除するのは **`BRANCH_DELETE_UNMERGED=1` を実際に観測したときだけ**。同 helper は
`BRANCH_CHECK_FAILED`（refname 不正 / marker デリミタ混入 / ref-store エラー）や `BRANCH_DELETE_FAILED`
も emit し、これらは「helper が判定できずに削除を試行しなかった」状態を指す。marker を見ずに
`git branch -D` へ直行すると、helper が fail-fast で弾いた入力クラスをそのままシェルへ渡すことになり、
呼び出し側が helper の防御を無効化する。`BRANCH_DELETE_DEFERRED`（別セッションが作業ツリーを使用中 /
sandbox マスク）も同様に、削除が Git 構造上できない状態なので強制しても壊すだけ。

強制削除そのものも helper と同じ形（`-D -- "$branch"`）で書く。`--` は `pr-cycle-cleanup.sh` が
defense-in-depth の不変条件として明文化しており、quote と併せて 1 トークンで済む。

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
