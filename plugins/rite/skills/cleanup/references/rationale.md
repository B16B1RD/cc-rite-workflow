# /rite:cleanup — 設計理由

`skills/cleanup/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## follow-up-before-archive

archive より前に起票するのは、転記元 JSON がまだ元の場所にあるうちに読むため。archive を
維持する (D-04) のは、follow-up body は共有記録だが JSON は機械可読のローカル保全かつ起票
失敗時の受け皿だから。同定不能時に起票しないのは、重複 spam が取り返しつかない一方、失敗は
WARNING から手動復旧できるから (D-03)。helper は API 失敗でも exit 0 のため、失敗の一次信号は
`FOLLOW_UP_ISSUE` だけである。完了報告がこれを見ず `REVIEW_CLEANUP_PARTIAL_FAILURE` だけを見ると、
起票失敗が「なし」に倒れる。marker 不在を成功と読まない規約はステップ 5 と同型。

## reverify-no-extract-marker

6.0.V の抽出が成功しても marker を出さないのは、抽出だけを示す marker が「判定に到達しなかった」
経路で最後の marker として残り、ステップ 12 の **marker 不在の fail-loud 分岐を迂回させる**ため。
判定未到達はその分岐が「実施結果を確認できませんでした」として捕まえる状態であり、抽出 marker が
あるとそこへ落ちず、判定表のどの行にも一致しない未定義状態になる。0 件のときは finding が
1 行も出力されないので、抽出 marker があるとそれが必ず終端になる。
値を `done_extract` にすると `done` の接頭辞にもなり、判定表を前方一致で読む消費者に対して
`done` 行へ吸われる第 2 の欠陥面を作る。成功の signal は判定を終えた `done` 1 本に絞り、
marker 皆無は「節ごと未実行 or 判定未到達」として fail-loud に扱う（ステップ 12 の marker 不在分岐）。

## pr-merged-default

`{pr_merged}` を全経路で既定するのは、ステップ 4-W の worktree パス manifest 記録とステップ 5 の
ブランチ削除（squash 残渣の強制削除 / 遅延ブランチの manifest 記録）が未定義値を参照しないため。
`mergedAt` 非 null 以外（未マージ PR の強制クリーンアップ、PR 未検出でブランチ削除を選んだ経路）を
`false` に倒すのは、未マージ作業を reap 対象に混ぜないため。

## tasklist-parent-verify

GitHub code search は `[` / `]` を無視しほぼ全 Issue を返す。`--jq '.[0]'` で先頭を盲目採用すると
standalone closing Issue が自分自身や無関係 Issue を親と誤検出する。複数候補 + 自己除外 + body
再検証は #1629 で close.md / projects-integration.md §2.4.7.1 に入ったループと同じ方針。

## wm-source-content

PostToolUse hook が作る空 stub（`phase: init`・進捗セクションなし）はファイルとして存在する。
存在検査だけだと stub を採用してしまい Issue コメント側 fallback が発火しない（存在と成功を同一視
しないため）。#2141。

## cleanup-source-label

`source: "cleanup"` は将来 metrics 集計で起点 caller を区別するための識別子。`残作業` label の
事前作成は `gh issue create --label X` が X 未存在時に Issue creation 自体を fail させるため。

## exitworktree-delegation

分岐の基準を「worktree 内か」ではなく ExitWorktree 可否にしたのは #2133。path 入場
（`in_worktree_unrecorded`）では ExitWorktree が no-op になり、main checkout 操作が harness の
worktree 隔離ガードに拒否される（実測）。ガードが拒否するのは Bash ツール呼び出しのコマンド文字列
に直接 `cd` / `git -C` を書く形であり、helper 内部の `cd` は拒否されない（ステップ 7 の
`pr-cycle-cleanup.sh` は内部で main checkout へ `cd` できている）。helper へ閉じ込めれば自動化
できる余地は残るが、それは「worktree 内から全項目を完走させる」という現行設計の Non-goal。
ガード迂回は設計違反 — ガードは正当に機能している。

## helper-rc-capture

ステップ 4-W の 2 呼び出し（detect / remove）とステップ 6 の state purge —— 計 3 つの helper
境界は、いずれも「marker が出なければ完了扱い」に倒れる消費側と対になっている（ステップ 12 の `{session_worktree_check}` は
`WORKTREE_REMOVE_*` 不在を削除成功と読み、`{review_cleanup_check}` の state 削除側も同様）。この
規約は helper が**起動すらしなかった**場合に破れる — `{plugin_root}` の未解決置換・helper 欠落
（rc=127）、helper 非可読（rc=126）、引数不正（rc=2）ではプロセスが marker を 1 本も出さない。
抽出前はインライン bash だったためこの経路自体が存在せず、必ず marker を出すか実際に処理するかの
どちらかだった。よって呼び出し側で rc を捕捉し、既存の失敗 marker へ変換する。helper が内側の
archive helper に対して既に採っている形を、抽出で新設した外側の境界にも適用しているだけで、
判定表そのものは変えない。

ステップ 6.0（follow-up Issue 起票、`_fu_rc`）も同じ rc → marker の形を採るが、本 anchor の
対象には数えない。消費側が marker 不在を「完了」と読まないため、上記の規約破れが起きないため。
なお `cleanup-session-worktree-teardown.sh` 内で内側の分類 helper を呼ぶ境界も同型の扱いにして
あり（失敗を `none` ではなく `CLEANUP_WT=unknown` へ寄せる）、外側と内側で「分類不能」の表現を
揃えている — `none` は消費側が唯一「行ごと省略」に routing する値なので、そこへ落とすと検出失敗が
報告から消える。

## live-cwd-self-exclusion

自セッションを live-cwd から除外しないと、ステップ 2 の `ExitWorktree(keep)` が no-op / 失敗に
終わった経路で自セッションを「live」と誤検出し、cleanup 自身を理由に削除をブロックする。
全プロセスを列挙する `worktree-live-cwd.sh` 自体は変えず、self-exclusion は
`worktree-foreign-cwd.sh` に閉じる。

## session-worktree-reap

`--type session_worktree`（`worktree` ではない）にするのは、`worktree` type が Step 4.5 の
ungated reap（dirty チェックのみ、claim / self-exclusion / live-cwd ガード無し）の EPHEMERAL
tmp artifact 専用契約を持つため。session worktree のパスを混ぜると Step 4.5 が Step 5 の保護
ゲートを経ずに生存中の worktree を reap しうる。`session_worktree` type の Step 4.5 arm は
reap せず、消滅済みなら stale 参照を drop し、存在すれば verbatim 保持して Step 5 に委ねる。
実 reap の消費は Step 5 の gated bypass のみ。

admin dir 半壊（corpse）では checkout 中 branch を git で解決できず、pr-cycle-cleanup.sh Step 5
のブランチ名 manifest bypass（#1966）が構造的に効かない。パス自体を事前記録すれば corpse age
guard が 24h 待ちをバイパスできる。記録は `{pr_merged}=true` のときのみ（AC-4: 未マージ PR の
強制 cleanup では記録しない）。record 自体は non-blocking 契約（rite-tmp-artifact.sh）。

## main-root-cd

worktree 自己削除後は harness の cwd 追跡のみが main へ移り、この Bash 永続シェルの cwd は削除
済み worktree に残る。ステップ 4 の base 更新はこの main_root へ明示的に cd して実行する必要が
ある。`git worktree list --porcelain` の先頭 worktree entry は常に main checkout（git の仕様上
保証）なので、削除がまだ起きていない 4-W 時点で取得すれば cwd の状態に関わらず正しい値が取れる。

## base-update-classify

dirty な基点ブランチを黙って上書きしないため。破棄・stash は必ずユーザー確認を挟み、無確認の
破壊的操作をしない。分類を安全側（divergent）へ倒す根拠 — staged / untracked は working tree
比較で内容検証できない、tree 全体比較はマージが追加した無関係ファイルまで D として数える、
非 -z 出力は quotePath が pathspec 不一致を引き起こす — はステップ 4 bash 内コメントが SoT。

## remote-delete-markers

成功側も positive marker を出すのは、marker 不在を「削除成功」の符号化に使わないため（#2016）。
不在を成功と読むと、本ブロックがそもそも実行されなかった経路・出力が compact で失われた経路と
削除成功が区別できず、consumer が不在を根拠に完了と断定する。全経路が marker を持てば、marker
不在は「実行結果を確認できていない」という別の意味だけを持つ（`{base_update_check}` と同形）。

`git ls-remote --heads` は ref 不在でも rc=0（空 stdout）を返すため `&&` では「存在するときだけ
削除する」ガードにならない。`--exit-code` で不在を rc=2 として判別する。pattern は full refname
でも tail 一致であり、rc=0 のあとに stdout の ref 名が完全一致することを検証しないと、対象が
不在でも削除経路へ入り偽の残作業と必ず失敗する処方を報告する。削除先も namespace 修飾する —
非修飾の dst は remote の全 namespace に解決され、同名タグを削除しうる（実測。共有リモートの
タグ削除は不可逆）。

## review-run-since-sweep

`review-run-since-{pr}.txt` は `/rite:iterate` の収束トレンド判定が現 run の境界に使う pin
（iterate ステップ 0.6 が書き、ステップ 1 が `--since` で helper へ渡す）。残しても次 run の
開始時に上書きされるので害はないが、参照先が消えた孤児を PR ごとに積み上げない。

## nb-sweep-done-sweep

`nb-sweep-done-{pr}.txt` は 5.S 再入の権威（会話 marker は観測用）。寿命は本 run — 0.6 の
`fresh || cur_cc == 0` で消し、cleanup でも回収する。cleanup まで残すと再 iterate と
post-breaker 5.S が skip され、未消化 0 の再保証が死ぬ。

## wiki-worktree-persist

`.rite/wiki-worktree/` は再作成コストが高く各 PR cycle を跨いで保持する永続 worktree。

## projects-status-inline

過去に multi-stage inline pipeline で LLM の attention が sub-step 間で途切れ Status 更新が
silent skip する事象が確認されている（`skills/ready/SKILL.md` Phase 4.2 と同一原因）。参照のみ
に留めず本ステップに直接 inline する。

## wiki-push-batch

ingest.md はページ更新のたびに push していた旧挙動を、raw source ごとに commit のみ行い ingest
フロー末尾で 1 回だけ push する方式に変更した（#1941 / AC-1）。`push=failed` 部分文字列検出は
そのまま機能する — 集約 push が失敗した場合も、その 1 回の push 結果として ingest の stdout に
同じ文字列が現れるため、本ステップの検出ロジック自体の変更は不要（ローカル commit は保持され、
次回 ingest が自動で flush を試みる — AC-2 / SHOULD）。

## wm-dual-finalize

ステップ 11 で Work Memory final update と State reset の両方を実行しないと、Issue comment は
最終化されるがローカル file は永続蓄積し `post-tool-wm-sync.sh` が次セッションで file を再生成
する race 経路が開く。

## returned-to-caller

旧 `cleanup:completed` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、
cleanup → wiki-ingest → wiki-lint のネストで lint 直後に turn が暗黙終了する事象が複数回再発
した。`returned-to-caller` で terminal vocabulary を構造的に排除する。

## marker-scope-recency

`/rite:batch-run --merge` は同一セッション内で Issue ごとに `/rite:cleanup` をループ invoke
するため、先行 Issue が残した marker が後続 Issue の判定時にも文脈へ残る。marker 名までしか
一致条件に含めないと、リモート側は失敗ルールを先頭に評価する設計上、stale な失敗が自分の成功
marker を必ず上書きする。評価順序の入れ替えは解にならない — 成功を先頭にすると今度は stale な
成功が実失敗を握り潰し、塞いだ false-success そのものになる。

`branch=` は同一ブランチに対する cleanup 再実行を識別できない（1 回目がネットワーク断で
`CHECK_FAILED` を残し、原因解消後の 2 回目が `ALREADY_ABSENT` を出す場合、両者の `branch=` は
一致する）。recency（最後の出現をルール評価より前に選ぶ）が無いと、失敗ルール先頭評価の設計上、
前回実行の失敗が今回の成功を決定的に上書きする。

## marker-data-delimiter

行頭一致だけでは足りない — 複数行テキストの 2 行目以降は列 0 に着地するため、その中の
`[CONTEXT] ` 行は行頭一致を突破する。照合規約をサイト列挙ではなく begin/end 形で定義するのは、
サイトを増やすたびに列挙更新を忘れて契約とコードが drift するのを防ぐため。デリミタは可読性の
補助であり、data 自身が終端行を騙る経路を塞ぐ security boundary はインデント（列 0 に到達しない
こと）の側にある。fallback を非アンカーで判定すると先行ルールの否定にならず、行中に marker
断片が現れた入力でどのルールにも一致しない未定義状態が生じる。

## review-cleanup-reasons

行を presence 検査にしてあるので「上から評価し最初の一致」が実際に効く（実失敗と判定不能が同一
run で共起しても 1 行目が先に一致する）。`_gitignore_failure` は `cause=jq_rc_<n>` と同じく
summary の `failed` には数えられない（ファイル自体は処理済み）が、除外の欠落は退避した全文が
`git add -A` で公開リポジトリへ入る経路そのもので、放置してよい informational ではない。
`cause=jq_rc_<n>` を `x` に倒すのは、helper がこれを「退避自体は成功しうるので `failed` には
数えない」と定義し summary も `failed=0` を返すため。`.corrupt-*` を「判定不能 → 退避」経路へ
載せた以上 corrupt を持つ PR は毎回この reason を出すので、失敗扱いのままだと存在しない手動
対応を促し続ける。一方 `cause=jq_missing` は環境不備で、放置すると本来削除されるべき JSON まで
無判定で退避され続ける。

## outstanding-checkbox

付記文の絵文字 prefix は表示上の飾りに過ぎず（`{local_branch_check}` の
`BRANCH_DELETE_FAILED` / `BRANCH_DELETE_UNMERGED` のように prefix を伴わない実失敗付記も
存在する）、チェックボックス自体の空欄/`x`こそが「未完了か否か」の一次情報である。prefix 一致
方式は bare-text 付記を取りこぼす。この統一により、prefix の有無に関わらず全 check の実失敗・
残作業を漏れなく拾い、かつ legitimate skip（`x` 判定）は自然に除外される。

## wikichain-terminal-clear

ステップ 12 末尾の set は `--handoff` を持たないため、ステップ 9 でセットした
`WIKICHAIN:cleanup:{pr_number}` handoff を default-clear する。チェーン完走 = gate 解除。
チェーン途中で turn が閉じた場合のみ Stop hook が handoff を consume して継続を差し戻す。
