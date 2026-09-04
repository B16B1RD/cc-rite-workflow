# /rite:wiki-lint — 設計理由

`skills/wiki-lint/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。説明的番号参照の検出設計（走査範囲・
除外・正規化）は既存の `descriptive-refs-rationale.md` が SoT。

## helper-delegation

機械判定可能なカテゴリを helper に委譲し、件数を marker block + `[CONTEXT]` で emit するのは、
LLM が bash を実行せず 0 件と推測報告する経路を構造的に消すため。欠落概念の集合構築 helper
（`wiki-lint-skipped-refs.sh` / `wiki-lint-source-refs.sh`）と同じ保証。

## fail-loud-contract

原則 exit 0 の非ブロッキング契約と両立する fail-fast は、設定ミス / 実装ミスを silent に通過
させないための設計判断。未知の `branch_strategy`・placeholder 残留・`lib/wiki-config.sh` の
source 失敗が対象。

## wiki-config-opt-out

本ファイルは ingest と対称な `parse_wiki_scalar` 委譲の lenient 2-arm 経路（opt-out
default）。helper 不在で設定を判定できていないときに無効扱いへ倒すのは silent default そのもの。

## empty-lists-keep-7-5

両方空でステップ 7.5 まで skip すると、wiki 初期化直後や `git ls-tree` 失敗時に `index.md` の
指摘が無言で 0 件になる。`index.md` は単独で走査対象になりうる。

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
