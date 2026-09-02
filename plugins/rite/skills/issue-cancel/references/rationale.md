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

順序を固定する理由は AC-4 である。PR クローズが失敗したまま Status を `Cancelled` へ進めると、
board は終端・PR は open の不整合が残る。フォールバックせずエラーで止めるのは、この不整合を
見過ごさないため。PR クローズを先に置き、失敗したら Status も Issue クローズも後片付けも行わない。

`post-compact.sh` の PR Status reconciliation は `gh pr view --json isDraft` が `false` であること
だけを見る。GitHub の OPEN/CLOSED は見ない。CLOSED かつ未マージでも `isDraft=false` のまま
view できる。終端 Status（`Done` / `Cancelled`）は `In Review` へ引き戻さない。したがって
「PR を先に閉じれば発火条件が消える」「Status を先に `Cancelled` にすると compact が引き戻す」
はいずれも実装と一致しない。順序の why をその窓に載せない。

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
置く。ブランチが確定しない場合の取得経路は [issue-scoped-pr-lookup](#issue-scoped-pr-lookup) が扱う。
どちらの経路でも、絞り込み前の集合を判定に使わないことが要点。

client-side を closing keyword で絞る点は `/rite:issue-close` にも同じ経路がある。ただし**同 skill の
取得側は本節が退けた `--search "linked:issue:{N}"` と glob `--head` をいまも使っており、そこは踏襲しない**
（取得側まで含めて先例として引くと、誤った形へ読者を誘導する）。

## issue-scoped-pr-lookup

ブランチが確定しないときの取得を `gh pr list --state all --limit N` に置くと、**`--search` と同じ
「絞り込めていないのに成功して見える」欠陥を窓の形で持ち込む**。`--limit` は Issue でスコープする手段では
なく取得件数の上限で、返るのは作成日降順の最新 N 件にすぎない。実測すると、本プラグインのリポジトリでは
100 件の窓が遡れるのは直近の数週間分にとどまり、それ以前にマージされた PR は窓の外へ落ちる。

この fallback が発火するのはブランチを解決できないとき、つまりマージ後にブランチが消えている典型状況で、
窓外に落ちる確率が最も高い条件と一致する。絞り込み結果 0 件を「PR が無い」と読むと、マージ済みの作業を
持つ Issue を `NOT_PLANNED` で葬る。

**「窓の飽和を検出して止める」では解けない**。実測すると本リポジトリでは `--limit 100` が常に 100 件を
返す（PR 総数が窓を超えて久しい）。飽和を停止条件にすると fallback 経路が恒真で止まり、着手前の Issue —
`/rite:issue-cancel` の主対象 — を一切中止できなくなる。窓を前提にする限り、停止条件は「安全側に倒す」
つもりで主経路を殺す方向にしか働かない。

そこで**窓を持たない Issue スコープの取得**へ替える。Issue timeline の `cross-referenced` /
`connected` イベントは当該 Issue を参照した PR を件数上限なしで返す（実測: 100 件窓の遥か外にある
古い Issue でも、それを閉じたマージ済み PR が返る）。timeline は closing keyword を伴わない単なる言及も
含むため、client-side の closing keyword / `headRefName` 絞り込みはそのまま残す — 変わったのは
**候補集合の作り方だけ**で、判定表に載せる前の絞り込み規則は不変。

これで 0 件は「関連 PR が無い」という実際の観測になり、fail-loud は `gh api` の取得失敗だけを条件に
できる（0 件と取得失敗を同じ値へ畳まない）。GraphQL の `closedByPullRequestsReferences` も検討したが、
closing keyword でリンク済みの open PR を持つ Issue に対して実測で空配列を返したため採らない。

## timeline-rc-capture-first

上の fail-loud は「`gh api` の取得失敗だけを条件にする」ことで成立するが、`gh api ... | sort -un` の形で
書くとその条件が構造的に成立しない。command substitution の rc はパイプ**最終段**のもので、`sort` は空入力
でも 0 を返すため、`gh api` が 404 / 認証失敗 / レート制限で落ちても rc は 0 になる。埋め込み bash block は
Bash tool 呼び出しごとに fresh shell（`pipefail` OFF）で起動するので、この経路は既定で開いている。結果、
取得失敗が候補 0 件へ畳まれ、まさに `#issue-scoped-pr-lookup` が塞いだはずの「マージ済みの作業を
`NOT_PLANNED` で葬る」に戻る。

そこで rc を持つコマンドをパイプから外し、`_tl_raw=$(gh api ...)` で先に rc を確定させてから整形する
（capture-first）。`set -o pipefail` を block 冒頭に置く形でも rc は伝播するが、rc 保持コマンドを単体に
する形なら pipefail の有無に依存しない。stderr を退避して ERROR 行へ載せるのは、取得失敗の**理由**が
`gh` の stderr にしか無いため。

`select(.pull_request != null)` を truthiness へ替えるのは可読性の問題ではない。`hooks/pre-tool-bash-guard.sh`
の `jq-not-equal-null` パターンが `!= null` を含む Bash 呼び出しを**実行前に deny** するため、書いたとおりに
一度も走らない。`.pull_request` は object なので `select(.pull_request)` と等価で、`references/gh-cli-patterns.md`
も同形を推奨形として規定している。

## helper-marker-not-rc

`cleanup-pr-state-purge.sh` は「全運用経路で rc=0」の非ブロッキング契約を持ち、部分失敗（rm 失敗・内側
helper 起動失敗）を `REVIEW_CLEANUP_PARTIAL_FAILURE=1` marker でのみ通知する。呼び出し側が rc だけを見ると
その通知経路が丸ごと落ちて残置が完了として報告される — 「後片付け helper の失敗は non-blocking。WARNING を
出して続行し、Phase 7 に未完了として列挙する」という本スキル自身の宣言が、この経路について空文になる。

判定を marker へ移すのは新しい機構ではなく、同じ helper を呼ぶ `skills/cleanup/SKILL.md` の
`{review_cleanup_check}` が既に採っている形の継承である。

**判定を bash の捕捉層に持たせない**のが要点。`err=$(mktemp) || err=""` → `2>"${err:-/dev/null}"` →
`[ -n "$err" ] && grep -q ...` の形は、mktemp が失敗した瞬間に (a) helper の stderr を marker ごと捨て、
(b) 判定を短絡し、(c) `else` の「成功」へ落ちる。塞ごうとした当の欠陥——観測できていない状態を成功として
報告する——を、観測手段を確保するはずの層が再生産する。4.3 が「marker 不在は削除成功ではなく実行結果を
確認できていないことを意味する」と書いた規約は、捕捉に失敗した経路でこそ効かねばならない。sibling が
stderr を素通しして判定を読み手に委ねているのは、捕捉層を持たなければこの縮退が存在しないためである。

## reap-has-no-failure-marker

`flow-state.sh reap-issue` は同じ非ブロッキング契約を持つが、**失敗専用の通知チャネルを持たない**。
`WARNING: reap-issue:` は「stale flow-state (active=true) を見つけた」という成功経路の告知にも使われ、
直後の非 active 化が成功しても出力に残る。`/rite:issue-cancel` は 4.6 より前に flow-state を非 active 化
しない（4.5 の `cleanup-work-memory.sh` は close mode で flow-state を触らない）ため、着手後の中止では
この告知行が必ず出る。接頭辞の有無を部分失敗の判別子に採ると、成功した回収を毎回「残置」と報告し、
真の部分失敗が常時 ON の告知に埋もれる。

失敗語彙（`lock 回収失敗` / `読み取り失敗` / `deactivate failed` / `非 active 化失敗`）を列挙して一致させる
形は採らない。helper 側に 5 種目が増えた時点で一致しなくなり、静かに「成功」へ戻る — 4.4 で塞いだのと
同じ欠陥クラスの再導入になる。`skills/cleanup/SKILL.md` の同じ呼び出しが出力判定を採らず rc のみに留めて
いるのは、この非対称を踏まえた選択とみなせる。恒久策は helper 側に失敗専用 marker を持たせることだが、
`flow-state.sh` は他スキルからも呼ばれる共有 helper であり本スキルの守備範囲ではない。

## identity-promotion-headref-only

`{branch_identity_verified}` は `cleanup-branch-delete.sh` が**リモート ref を消してよいか**を決める唯一の
ゲートである。body の `Closes #{N}` だけで一致した PR の `headRefName` をこの flag ごと採ると、本文に
たまたま当該 Issue を引いた無関係な PR のブランチがリモートごと消える。ローカルと違い checkout 状態にも
守られず、不可逆。

identity の昇格は `headRefName` 自身が `issue-{issue_number}-` を含むときに限る。body-only 一致の PR は
`{pr_number}` としては採用してよい（PR クローズと state purge の対象にはなる）が、ブランチの同定には
使わない。

## headref-charset-binding

`{branch_name}` は Phase 4.3 の fenced bash に `--branch "{branch_name}"` / `git branch -D -- "{branch_name}"`
として literal substitute される。二重引用符と `--` は **argv 分割にしか効かない** — `$(...)` とバッククォートは
シェルがその引用符の内側でも展開するため、`feat/issue-2493-$(...)` の形の名前が入るだけで開発者セッションで
任意コマンドが走る。`git check-ref-format` は防波堤にならない（実測: `refs/heads/feat/issue-2493-$(id)` は rc=0。
rc=1 になるのは空白を含む場合など ref 名として不正なときだけ）。helper 側のデリミタ検査・値検査はすべて
**展開後の値**にしか走らないので、束縛は値がテンプレートへ入る前に置くほかない。

束縛を producer ごとに並べないのは、危険が値の出どころではなく consumer の側にあるため。fork の
`headRefName` だけが第三者制御だと考えるのは誤りで、2.2 のローカルブランチ検索も
`git branch --list "*issue-N-*"` の一意候補をそのまま採るので、`gh pr checkout` 等で fork の head 名が
ローカル branch として実在すれば同じ値が同じ consumer へ届く（実測で再現済み）。producer 側に個別検査を
並べる形は、経路が 1 本増えるたびに検査が漏れる。

**適用点は「Phase 2 の後置条件」ではなく「値を `{branch_name}` に代入する時点」**。consumer は Phase 4.3 の
fenced bash だけではなく **2.3 の `gh pr list --head "{branch_name}"` も含み、後者は Phase 2 の内側にある**。
後置条件は定義上それより前の置換を遡って守れないため、節末に 1 本置く形では 2.3 の consumer が未検査の値を
受け取る。代入時点に置けば、合流点の 1 本という利点（producer 追加のたびに検査が漏れない）を保ったまま、
consumer の位置に依存しなくなる。

非一致を `{branch_identity_verified}=false` へ倒すのは、既存の「identity 未確定ならブランチに触れない」経路と
同じ帰結へ合流させるため。新しい停止経路も新しい報告スロットも足さない。

## closed-state-reason-branch

`CLOSED` を単一の分岐にすると、`Closes #N` のマージで GitHub が自動クローズした `stateReason: COMPLETED` の
Issue が、中止用の経路へ系統的に流れ込む。2.3 が持つ「マージ済みの作業を NOT_PLANNED で葬らない」ガードは
2.2 / 2.3 の内側にあるため、`CLOSED` で短絡するとその**ガードが本来狙うケースこそ**素通りする。

`projects-status-update.sh` は `fieldValues` を読まない（read-before-write ガードが無い）ため、board の `Done`
行はそのまま `Cancelled` へ落ちる。さらに `projects-board-drift-check.sh` は終端 Status の行を drift 母集団から
除外するので、この誤記録は rite 側の reconciler では二度と戻らない。`references/projects-integration.md` の
Rule 1（終端 Status の行を反対側へ引きずらない）の vice-versa 側そのものになる。

`NOT_PLANNED` 側の帰結（Phase 3 / Phase 4 / Phase 6 をスキップし Phase 5 だけを実行する）は変えない。
Issue の受入基準が「既に CLOSED の Issue に対しては board Status の同期のみを行う」と定めているため、
分岐の追加は `stateReason` による行き先の判別に限る。

`NOT_PLANNED` 以外を停止に倒し「警告して続行」にしないのは、`Done` の上書きが operator の判断を復元不能に
潰すため。fail-loud が可能な場所で fallback を選ぶ理由が無い。

## classification-class-predicate

4.2.0 のガードは当初 detect の分類値を見て、危険値（`unknown` / `in_worktree_unrecorded`）を名指しする
否定形で書いていた。名指しの外側（marker 不在で空文字に倒れる経路）が「path が空 = 記録なし」へ落ち、
ブランチ削除まで続行した。証明された正常値の列挙へ反転しても、detect が見えない対象 worktree は
`none` のままスキップされ、`undetermined` は teardown を止めたまま Phase 5 / Phase 6 を通常実行した。

閉じたあとの再実行は `CLOSED` + `NOT_PLANNED` が Phase 4 をスキップするので、復旧経路として使えない。
そこで確認できない入力は残らず `blocked` へ落とし、**Phase 5 / Phase 6 の前に fail-loud で止める**。
Issue が OPEN のまま残るので、main checkout からの再実行が Phase 4 に届く。

`in_worktree_unrecorded` は分類できている値である。畳む理由は帰結が同じ——`ExitWorktree` で
main checkout へ退出できない——ことであって、分類不能だからではない。canonical な分岐基準は
sibling の `skills/cleanup/SKILL.md`（「分岐の基準は「worktree 内か」ではなく「`ExitWorktree` で
main checkout へ退出できるか」」）。cleanup 側は委譲後も Issue を閉じるが、中止側は閉じると
再実行が届かないため、同じ不能を fail-loud に倒す。

## step-order-as-sections

手順の順序を「判定表 1 セル内の番号付きリスト」で表すと、2 つの壊れ方をする。セル内で順番を入れ替えても
行番号が動かないので**テストの順序 pin が効かない**。そして隣接行が「1〜2 をスキップ」のように序数で
参照していると、片方の行にステップを 1 つ挿入しただけで**参照先が黙ってずれる**。実際、Issue 束縛ガードを
`in_worktree` 行の手順 1 に挿入したことで `in_main` 行の「1〜2 をスキップ」がガードごと飛ばす意味になり、
ガードが最も必要な経路から外れた。

そこで `detect` → ガード → `ExitWorktree` → `remove` をそれぞれ独立したサブセクションにした。順序は
見出し行の並びで表れるので行番号で pin でき、全経路が通るべきガードは判定表の外の無条件前段に置ける。
隣接行への序数参照は使わず、スキップ対象は手順名で書く。

## write-vs-bash-path

skill に新しくパスを書くときは「**Bash がこれを展開するのか、Write が literal に消費するのか**」を毎回
問う。`${TMPDIR:-/tmp}/...` を Write ツールの書き出し先に渡すと展開されず、bash 側で展開される読み出しと
別の場所を指す。逆に `git branch -D -- "{branch_name}"` の `{branch_name}` は placeholder の literal
substitute なので、二重引用符の中でも `$(...)` が展開される。

同じ問いを反対方向に間違えた 2 件が 1 つの cycle で同時に入った。パスは bash で marker として実パスを
出し、その値をリテラル置換して Write へ渡す（`pr-review` の `{review_tmp_dir}` と同型）。

## issue-scoped-identity

`/rite:cleanup` は「対象 Issue == 現在のセッション」を前提にでき、`flow-state.sh get` も
`cleanup-worktree-detect.sh` の `in_worktree` 判定もその前提の上で正しい。どちらも `--issue` を取らず、
現セッションの記録／現 cwd だけを見る。

`/rite:issue-cancel` は Issue 番号を**引数で**受ける最初の入口なので、その前提が崩れる。Issue A の
worktree に居るセッションから Issue B を中止すると、identity 検証を挟まない限り Issue A のブランチと
worktree が削除対象になる。しかも `cleanup-branch-delete.sh` はリモート削除の可否を
`--branch-identity-verified` 一本で決めるため、誤った `true` はリモート ref まで消す。

そこで 2 箇所で Issue 番号に束縛する: flow-state は `issue_number` を併せて読んで一致時のみ採用し、
worktree は `git worktree list --porcelain` の末尾セグメントが `issue-{N}` である path だけを
remove 対象にする。detect の戻り値は「cwd が対象の中にいるか / `ExitWorktree` で退出できるか」
の判定にだけ使う。現セッションの path が別 Issue なら、その path は消さない — 削除は不可逆で、
判定不能のまま進む理由が無い。

## target-worktree-discovery

detect helper は現セッションの flow-state と cwd だけを見る。`/rite:cleanup` は「対象 == 現セッション」
を前提にできるが、`/rite:issue-cancel` は Issue 番号を引数で受ける。main の新規セッションから
着手後の Issue を中止すると detect は `none` を返し、規約パス `{worktree_base}/issue-{N}` に
残っている worktree を見逃す。ブランチは `git branch --list` で Issue に束縛して探すのに、
worktree だけがカレントセッションの拒否で終わる非対称になる。

発見は `git worktree list --porcelain` の末尾セグメント完全一致に置く。登録済み worktree だけが
`git worktree remove` の対象であり、未登録の残骸ディレクトリを規約パスで拾っても helper は
消せない。suffix 照合にしないのは `issue-24931` を `issue-2493` に一致させないため。

cwd がその path の中にいて `CLEANUP_WT` が `in_worktree` でないときは `ExitWorktree` が no-op
になる（path 入場。cleanup と同じ観測）。ここで teardown をスキップして Issue を閉じると、
再実行は AC-6 の冪等経路（Phase 4 skip）に落ち、worktree もブランチも残る。不能なら
Phase 5 / Phase 6 の前に止めて Issue を OPEN のまま残すほかない。

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

強制削除そのものも quote + `--` の形で書く。`--` は `pr-cycle-cleanup.sh` が defense-in-depth の
不変条件として明文化しており、1 トークンで word splitting・glob・option injection を塞げる。

**ただしこれは helper と「同じ形」ではない**。helper の `-D -- "$branch"` は**変数参照**なので値の
再展開が起きないが、本体の `-D -- "{branch_name}"` は placeholder の **literal substitute** であり、
二重引用符の中でも `$(...)` は展開される。安全性の水準は helper と同一ではなく、埋め込む値が
`git check-ref-format` を通る範囲に限られることに依存している。helper へ force モードを足して値を引数で
渡せばこの差は消えるが、`cleanup-branch-delete.sh` は本 Issue の Non-Target Files であり、変更は
`/rite:cleanup` 側へ波及する。

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
