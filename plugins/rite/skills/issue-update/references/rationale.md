# /rite:issue-update — 設計理由

`skills/issue-update/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## auto-vs-manual

作業メモリは open / pr-create / pr-review / fix / cleanup / lint が自動更新する。本コマンドは
決定事項・補足・特定時点の進捗・次セッションへの手渡しだけを手動で足す。

## format-compat

v1（`### 進捗`）と v2（`### 進捗サマリー`）が混在する。読取は両対応、更新は既存形式を維持
（強制 migration しない）、新規作成だけ v2。

## reread-before-write

Phase 1 で読んだ内容は context compaction で捨てられうる。Phase 3.1 で再読し、全体を記憶から
再構成しない。変更対象セクションだけを書き換える。

## public-comment

作業メモリは Issue コメントとして公開される。公開リポジトリでは第三者に見える。
