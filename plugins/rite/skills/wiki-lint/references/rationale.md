# /rite:wiki-lint — 設計理由

`skills/wiki-lint/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。番号参照の検出設計（走査範囲・
除外・正規化）は既存の `descriptive-refs-rationale.md` が SoT。

## helper-delegation

機械判定可能なカテゴリを helper に委譲し、件数を marker block + `[CONTEXT]` で emit するのは、
LLM が bash を実行せず 0 件と推測報告する経路を構造的に消すため。欠落概念の集合構築 helper
（`wiki-lint-skipped-refs.sh` / `wiki-lint-source-refs.sh`）と同じ保証。

## fail-loud-contract

原則 exit 0 の非ブロッキング契約と両立する fail-fast は、設定ミス / 実装ミスを silent に通過
させないための設計判断。未知の `branch_strategy`・placeholder 残留・`lib/wiki-config.sh` の
source 失敗、および自動矛盾検査の入力・読み出し・比較の未完了が対象。

## wiki-config-opt-out

本ファイルは ingest と対称な `parse_wiki_scalar` 委譲の lenient 2-arm 経路（opt-out
default）。helper 不在で設定を判定できていないときに無効扱いへ倒すのは silent default そのもの。

## empty-lists-keep-7-5

両方空でステップ 7.5 まで skip すると、wiki 初期化直後や `git ls-tree` 失敗時に `index.md` の
指摘が無言で 0 件になる。`index.md` / `log.md` は単独で走査対象になりうる。

## skip-sot-raw-frontmatter

(Sub-3) で skip SoT が `log.md` から raw frontmatter（`ingest_status: skipped`）へ移行した。
enum 名 `log_read_ok` は stdout 契約のため据え置き、値は raw 走査状態を表す。

## marker-unreceived-io-error

helper 不在 / marker 未受信で当該集合を空と同視すると、skip 済み raw が `missing_concept` に
誤計上される、あるいは真の欠落判定が false positive になる。`io_error` を明示してステップ 9.1
の false positive note を展開する。

## pages-list-pollution

HEREDOC に `.rite/wiki/raw/...` 行を含めると helper の partial pollution gate が fail-fast する。
旧 silent `missing_concept` 誤分類の再発防止契約。

## descriptive-refs-surface

Wiki は番号の受け皿ではなく経験則を Why 散文で残す場であり、Comment Best Practices SoT の適用
スコープが Wiki ページを含む。対象はページ本文だけでなく `## ソース` 節の bullet、`index.md` の
エントリサマリー、`log.md` に及ぶ — どれも読者が開く永続成果物で、番号がそこにあれば Wiki の中の
番号である。検出文法は `number-reference-check.sh` に委譲し、本ステップも helper もコピーを
持たない。番号の定義がリポジトリで 1 箇所なら、Wiki だけが別の基準で clean を名乗ることがない。

## descriptive-refs-issues-exception

本ステップを `issues[]` に転記すると数百ページ分の検出詳細行が
`{issues_list_formatted}` を埋め、`n_warnings` に加算されない指標が warning 一覧を占有する。
もう 1 つの informational 指標 `unregistered_raw` はステップ 6.3 で `issues[]` に記録され
ステップ 9.1 の `### 未登録 raw（skip 済）` グループとして出力される（対象外にしてはならない）。

## descriptive-refs-note-unread

note を兄弟 enum と同じく件数の直後に置くのは、読出失敗由来の `0` や部分欠損した集計を
「解消済み」と読ませないため。

## lint-action-machine

`lint:clean` / `lint:warning` の判定を LLM 解釈から切り離し、bash で機械的に決定して stdout に
emit する。ステップ 8.3 の `{log_entry}` 組み立てはこの emit 値を single source of truth として
参照する。

## okf-log-append

同日内の追記位置を ingest ステップ 7 と揃え、bullet 順序を実行者非依存にする。log.md は表形式
より追記順を保ちやすい OKF 形式へ移行した。

## returned-to-caller

旧 `lint:completed:auto` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、
caller skill（ingest 等）の次 step を skip して turn が暗黙終了する事象が複数回再発した。
`returned-to-caller` は「caller に return した = caller の次 step に進む」という semantic に
置換することで、terminal vocabulary を構造的に排除する。

## log-commit-helper

commit 処理を SKILL.md の fenced bash に書くと、実行のたびに LLM が literal substitute しながら
長い複数文ブロックを流すことになり、heredoc も 2 つ抱える。session worktree の隔離ガードは git を
含む複数文ブロックを拒否するため、そのままでは退路（scratch へ書き出して実行）経由になる。本体を
helper に移し、SKILL.md は top-level の 1 文で呼ぶ。commit メッセージはシェルを通すと展開・引用の
事故が起きるため、Write でファイルに書いて `--message-file` で渡す。rc=6（sandbox-mask）の再実行は
helper 呼び出しの 1 文だけを繰り返せば済むよう、そのときだけ helper がメッセージファイルを残す
（Edit からやり直すと log.md に二重に追記される）。

## two-stage-auto-comparison

自動取り込みでは全分類の全要約を照合する。分類は「推奨・避ける・経験則」という種類で
話題ではなく、矛盾しやすい patterns と anti-patterns の組が同じ分類に入らないため、
分類で絞ると逆の主張を拾えない。要約は index から既に読んでおり、増えるのは判定する
組の数だけで、論点の異なる本文を読まないことで全ページ同士の繰り返し比較を省く。タイトルやタグの一致だけでは逆の結論や
言い換えを落とすため、要約を変更本文の論点・条件と意味的に照合し、曖昧なら候補へ残す。
候補の本文は全件読んで条件と詳細を確かめる。候補数の上限を設けると、同じ論点なのに
検査されないページが生まれるので件数で打ち切らない。手動は全体を検査する。

対象・候補・除外・本文比較済みの件数を照合するのは、要約の照合や途中までの比較を
「矛盾検出完了」と誤認させないため。入力や索引が欠けたときに空として続行すると、
検査されていない経験則を「問題なし」で通すため、理由を出して呼出元も停止する。
自動の比較証跡は commit 済み log の本文を読み戻して確かめる。既存 helper は
手動の非ブロッキング契約で commit 失敗にも exit 0 を返すため、終了コードだけでは
保存を確認できない。自動だけ保存できなければ停止し、手動の契約と helper 自体は維持する。

## open-contradictions-carry

自動の比較は今回変更したページを起点に候補を選ぶため、一度検出した矛盾は、そのページが
変わらない限り次回の比較集合に入らない。検出した組を lint エントリに固定書式の行で残し、
次回の自動比較がその行を読んで件数へ載せることで、解消されるまで報告し続ける。lint の
エントリは毎回その時点で数えた矛盾をすべて書くので、直近のエントリが未解消の一覧になり、
解消済みを打ち消す別の記録を持たなくてよい。

両ページとも変わっていない組は本文を比べ直さずに引き継ぐ。同じ本文を毎回判定し直すと、
判定の揺れで「矛盾なし」に落ちる回が生まれ、未解消の矛盾が黙って消える。本文が変わった
ときだけ判定し直し、ページが消えた組は矛盾が成り立たないので外す。人が統合した組は、
手動の全ページ比較がその時点の矛盾をすべて書き直すことで記録から外れる。

読出は helper に任せ、commit 済みの log.md だけを読む。log.md は日付節が新しい順で、
同じ日の中は後から書いた行ほど下にあるため、「直近のエントリ」の特定は並びの規則に
依存し、LLM の読み取りでは揺れる。commit に失敗したエントリは記録として扱わない。
bullet の `contradictions=` と行数が合わないときに止まるのは、行の書き漏らしを
少ない件数として通さないためである。
