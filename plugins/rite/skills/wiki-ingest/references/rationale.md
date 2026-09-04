# /rite:wiki-ingest — 設計理由

`skills/wiki-ingest/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## wiki-config-opt-out

ステップ 1.1 はプローブ用で、helper 解決失敗だけ fail-fast、値欠落は `${var:-default}` で吸収する。
そのためここでは `set -euo pipefail` を付けない。strict mode は commit 経路（ステップ 5.1 / 5.2）
で宣言する。

本ファイルは `lib/wiki-config.sh` の `parse_wiki_scalar` を直接呼ぶ lenient 2-arm 経路（inject.sh
と同型の opt-out default ファミリ）。trigger.sh は意図的に strict 3-arm fail-fast で別経路 —
分散実装の完全一覧と設計差異は wiki-patterns の SoT 節。helper 不在で設定を判定できていないのに
opt-out default で「Wiki 無効」と報告するのは、この Issue が潰した誤報告パターンの再演になる。

## plugin-root-literal-embed

ステップ 1.3 の `wiki-worktree-setup.sh` が `$plugin_root` に依存するため、Wiki 初期化判定より前に
解決する。Claude Code の Bash ツール間でシェル変数は保持されないので、以降のブロックは
`plugin_root` / `branch_strategy` / `wiki_branch` / `wiki_worktree_abs` をリテラル埋め込みする。

## cwd-independent-worktree

絶対パス基点にすると、セッション worktree から起動しても共有 root の wiki worktree 一箇所に
解決される（multi-session design §9 / AC-5）。`{wiki_worktree_abs}` が空の縮退（旧バージョン互換）
だけ相対パス `.rite/wiki-worktree` を許す。

## session-lock-mkdir

`flock` は複数 Bash 呼び出しに跨る ingest を守れない。持続的 mkdir lock の stale 判定は保持
セッションの flow-state liveness（`active=true` ∧ `updated_at` 2h 以内）を流用する
（multi-session design §9）。`concurrent_ingest` 時に新しい回収機構を作らないのは、pending raw
が wiki branch に残り次回 ingest が冪等に回収する（AC-4）ため。

## informational-counters

`n_unregistered_raw` は意図的に経験則化しなかった件数、`n_dedup_removed` は index 自己修復で
回収した重複行の件数、`n_stale` は経過時間の計上（詳細は [#n-unregistered-not-warning](#n-unregistered-not-warning)）
であり、いずれも警告ではない。`auto_lint=false` で 8.2-8.5 が skip されても
ステップ 2.1 で 0 初期化済みなら、ステップ 9 の placeholder 残留は起きない。

## dev-tree-drift

`separate_branch` では Raw Source は wiki ブランチ上にあり、dev 側 `.rite/wiki/raw/` は通常存在
しない。存在チェックは旧 stash+checkout 経路のマイグレーション残骸を拾うためで、本 Ingest では
処理しない。

## knowledge-routing

rite 挙動・スキル記述法の知見を Wiki に留置したままだと、マーケットプレイス配布先では不活性に
なる（CLAUDE.md「知見のルーティング」）。環境非依存なら `promote: rite-plugin`、環境固有なら
一般化してから昇格するか、一般化できなければ domain 知見として Wiki に残す。機械検出可能
（2.6）と両方に該当する場合は 2.6 が優先し、ページを作らない — `promote` はページ作成時のみ。

## detector-candidate

2.6 はフラグ付けのみでアクション決定はしない。正例は trap 順序の静的検査・mktemp 無音化の
lint 化、負例はブランチ戦略の運用判断・ドメイン固有の文脈知識。ステップ 9 の検出器化候補列挙は
人間が Issue 化を判断する材料で、`promote: rite-plugin` タグと同型の役割。

## summary-provenance

Issue / PR 番号は出典の識別子であって概念の理由を説明しない。番号が担っていた観測事実・条件・
因果は自己完結した散文にし、provenance は `sources` に分離する。`description` を更新しないと
ステップ 6 helper が既存サマリー列を保持し、同源テキストが drift する。

## okf-migrate-on-first-touch

版数検査と一括 migration を ingest 冒頭（lock 取得後）に置くのは、配布先 bundle の移行を手動
script 実行前提にしないため。`wiki.enabled: false` では 1.1 で既に return 済みなので helper は
呼ばれない。helper 失敗時に `okf_version` を bump しないのは、途中失敗の再実行を冪等に完走
させるため。

## source-ref-path-form

raw frontmatter の `source_ref`（PR 識別子、例: `pr-1143`）を page の `sources[].resource` に転記する
と、同名 placeholder と raw フィールドの dual-use で drift する。lint は `resource` をファイルパス
形式で raw と突合するため、PR 識別子だと raw→page 追跡が切れ false `missing_concept` を量産する。
概念は Wiki anti-pattern `placeholder-dual-use-resolution-drift`（wiki ブランチ上の経験則。
develop ツリーには実体なし）。

## related-page-literal

4.3 を 5.3 表より優先するのは、矛盾時に値決定手順の SoT を一つに閉じるため。index 側のセル
区切りエスケープとリンク構文中和（`](` の `]` → `&#93;`）は同定述語が読む先頭リンクを title
が詐称できないようにする表記上の措置であり、転記すると frontmatter `title` との literal 一致
が壊れる。空 placeholder のままにすると Markdown リンク `[]()` が破綻する。

## skip-no-index-update

skip 決定の Raw Source には helper が必須とする page metadata（title / domain / slug / updated /
confidence）が無い。raw 由来の値で代用すると実在しないパスを指す登録行が新規追加され、孤児
検出のシグナルを汚す。

## commit-msg-three-sites

5.1 と 5.2 は独立した bash block で、Bash ツール間にシェル状態は継承されない。両サイトで
canonical と literal 一致させ、サイト識別子（`ステップ 5.{X}`）だけ置換する。template 変更時に
3 箇所を同時更新しないと drift する。

## push-defer-1941

複数 raw source のループ内で raw ごとに push すると、SSH host alias 環境で毎回 sandbox バイパス
が必要になり、同一 push の短時間重複実行も起きていた。ステップ 5.1 は `--commit-only`、Lint
`--auto` も同様に commit のみ積み、ステップ 8.6 で全処理後に 1 回だけ push する（AC-1: 1 ingest
フローで `git push origin {wiki_branch}` は最大 1 回）。`same_branch` の push は PR ブランチの
通常 push に含まれ、このフローの管轄外。`push=no-op` は push すべき commit が無かっただけで
失敗ではない。

## confidence-literal

page-template.md の `confidence: medium` はリテラル値。placeholder 走査の誤置換を避けるため
展開表とは別管理し、Write 後に Edit で判定値へ置換する。

## index-quoted-heredoc

frontmatter は LLM 生成テキストで引用符・バックスラッシュ・`$(...)` を含みうる。double-quote
されたシェル語へ直接置換すると値の `"` でクォートが閉じ、後続がコマンドとして実行される
（fix スキルと同旨）。quoted heredoc は終端子行と一致しない限りシェル解釈を抑制するが、値が
複数行、またはある行が終端子 `WIU_EOF` と完全一致すると heredoc が早期終了する。6 つの
heredoc が同じ終端子を共有するため後続の `wiu_*=$(cat <<'WIU_EOF'` が再度開き、helper 呼び出し
行も正常に走って rc=0 + 3 marker 揃いの成功に見える。block 内のシェルは parse 済みで手遅れ
なので、ゲートは substitute 時点の LLM 責務。helper 側 C0 検査は「この bash を実行できた場合」
にしか効かない。

## index-axes-independent

`row_action` と `stats_sync` を first-match で打ち切ると、同時に出ている他方の WARNING 表示
指示に到達しない。`stats_sync=synced` の部分未同期は WARNING の有無だけでは判定できない —
同じ呼び出しで重複中止 WARNING も stderr に出るため、完全同期を部分未同期と誤報告する。
重複中止は `row_action=aborted_duplicate` 行が受け持つ。統計可視化の追加機構（専用 lint /
marker attest / サイクル gating）は helper ヘッダが「実装しない」と明記している。

既存ページの更新失敗は登録行が旧値のまま残り、Lint のどの観点にも載らない。表示した
ERROR / WARNING が唯一のシグナルなのでステップ 9 の未完了事項へ集約する。

## skip-cycle-no-3a

全 Raw Source が skip のサイクルではステップ 6 が 1 度も走らず、helper Procedure 3a（重複回収）
も走らない。docstring の「毎回実行」は呼び出しごとの意味で、呼び出し自体の有無はステップ
5.0 手順 6 の条件が決める。`same_branch` および `{wiki_worktree_abs}` 空の縮退は相対パスなので、
ステップ 3 と同じく dev ツリー root を cwd とする前提。前提が崩れると helper は index.md 不在
の exit 1 で fail-loud に止まる。

## log-human-only

log.md は人間向けの変更履歴。skip 等の機械可読状態は raw frontmatter の `ingest_status` が
SoT で、本ログには保持しない。

## auto-lint-inline-parser

ステップ 8.1 の awk は位置パラメータを参照しない bare regex 形のため、Skill loader の展開を
受けず helper へ委譲しなくても壊れない（検出は `dollar-zero-check.sh`）。ステップ 1.1 は
`parse_wiki_scalar` へ委譲済み。1.1 の旧形（awk で行全体を参照する形）をここへ持ち込むと
恒偽化する。8.6 を skip しないのは、5.1 で `--commit-only` 積んだ commit の push が
`auto_lint` の有無に依らず必須だから。

## lint-parser-first-line

ステップ 8.3 の parser は 1 行目の `^Lint: contradictions=` regex のみに依存する。2 行目以降の
disambiguator 追加は互換性に影響しない。全行 scan + 最初の match は、lint 側の preamble /
debug / banner 混入に対する resilience。stdout 空は lint 契約（0 件でも `Lint:` 1 行必須）に
反する異常経路（syntax error / 未捕捉 fatal / SIGPIPE / OOM）。lint 総出力は 3 行でも、parser
が依存するのは `^Lint:` の data 行だけ。format mismatch を silent に 0 件と誤認しないために
anomaly 計上する。

Skill ツール呼び出しはシェル exit code を返さない。以降の「stdout」は Skill 応答テキストを
指し、lint 内部の中間出力（`pages_list=` 等）ではない。

## n-unregistered-not-warning

skip 済み raw を警告に数えると、skip 運用が膨らむほど `n_warnings` が無意味に肥大する。

陳腐化（`n_stale`）も同じ理由で加算しない。ただし肥大の源は運用量ではなく述語の性質にある —
陳腐化は経過時間の計上であってページの正しさとは独立で、内容が正しく直す必要のなかったページ
ほど古くなる。`generated.at` は最終内容変更時刻なので、内容を変えずに日付だけ進めて解消する
のは provenance の捏造にあたり、正規の解消手段が存在しない。

どちらも `{wiki_warnings_line}` の内訳には現れない。表示先は完了レポート内で、`n_stale` は
`Lint 結果:` 行（ステップ 8.4 で定義）、`n_unregistered_raw` は同行と未登録 raw 専用行。

## lock-release-failsafe

lock を保持し続けると他セッションの ingest が `concurrent_ingest` で skip され続ける。万一
解放を逃しても次回 ingest が stale 判定で回収する fail-safe はあるが、正常系では明示解放する。

## outstanding-no-new-store

Wiki push の未完了は `{wiki_push_line}` と同じ marker を再評価するだけで、新しい記録先は持た
ない。local commit 自体が durable な記録であり、次回 ingest のステップ 8.6 が自動で flush を
試みる。marker なしを「失敗なし」と断定しないのは、未確認と成功を混同しないため。

## returned-to-caller

旧 `ingest:completed` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、
caller skill（cleanup / open 等）の次 step を skip して turn が暗黙終了する事象が複数回再発
した。`returned-to-caller` は「caller に return した = caller の次 step に進む」というネスト
構造を semantic に内包し、terminal vocabulary を構造的に排除する。bare bracket は同じ heuristic
誤発火のため禁止で、HTML コメント形式のみ許容する。

<a id="numref-precommit"></a>

## numref-precommit

Raw Source は出典なので番号を持ち、そこから読解して書く過程で番号が Wiki 側へ転記される。
ステップ 8 の wiki-lint は読み取り専用の informational 指標で書き込みを止めないため、
混入を止められるのは書き込み側だけである。だから検査は commit の直前に置く。

対象を `.rite/wiki` 配下の未 commit 差分にし、列挙もラベルも git に決めさせるのは、
ゲートの判定基準をゲートされる側が選べる形にしないため。対象・ラベル・本文のどれか一つでも
実行者が選べると、選び損ねた回だけ検査が素通りし、しかもその回が「検査済み」として commit へ進む。
差分から取れば渡る対象は git が返す実体になる。

ただし `git diff` は追跡済みパスしか比較しない。新規ページは Write した時点では untracked で
差分に現れず、`git add` は commit ステップまで走らない。そのままだと **新規ページ — Raw Source
から読解して書く量が最も多く、番号混入の主経路 — が 1 行も検査されないまま `clean` になる**。
だから走査の直前に intent-to-add (`git add -N`) を挟む。index にはエントリだけが載り
`git diff --cached` は空のままで、commit まで進んだ回は commit ステップが同じ範囲を stage し
直すため後段への影響もない。hit / error で停止した回はエントリが残るが、次回実行の
`add -N` が冪等に上書きする。

残存の**列挙**に `ls-files --others --ignored` を使うのは、これが「実際に走査へ載らなかった
ファイル」を直接返すのに対し、`check-ignore` はパターンの照合結果しか返さず、negation の
重ね合わせでは「ignore されているか」の判定が一意にならないため。

一方、列挙で ignore 済みが確定した後の**原因の名指し**には `check-ignore -v` を使う。この
時点では判定は済んでおり、必要なのは「どの .gitignore のどの行が効いたか」だけなので、
上記の非決定性の caveat は効かない。`gitignore-health-check.sh` へ委譲しないのは、同 helper が
`rite-config.yml` と state_root を前提に別ツリーを見るため、`separate_branch` では走査対象の
worktree を一度も見ずに終わる（返るのは別ツリーの findings）。止めた人に Hint が渡らない。

走査範囲を `--path .rite/wiki` で絞るのは、走査範囲と commit 範囲を一致させるため。
`same_branch` では走査ツリーが dev repo root になるので、絞らないと Wiki と無関係な未 commit
変更の番号で `hit` が出る。その `hit` は Wiki の書き直しでは消せないため、手当ての手順を持たない
停止になる。

ページだけでなく `index.md` のエントリ行と `log.md` の bullet も同じ 1 回で通す。
`log.md` の番号はほとんどが skip 理由や更新説明の散文由来で、ページだけを見ると素通りする。

