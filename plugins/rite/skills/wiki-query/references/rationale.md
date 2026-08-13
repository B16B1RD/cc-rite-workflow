# /rite:wiki-query — 設計理由

`skills/wiki-query/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## wiki-config-probe

ステップ 1.1 の YAML 読みは UX 用の早期メッセージ専用 probe。真の採用は `wiki-query-inject.sh` 内の
`_extract_yaml_value` が行う。ingest ステップ 1.1 と同形の lenient パーサだが、ここで厳密パースして
も helper と二重管理になるだけなので簡易のまま置く。

## other-choice

`AskUserQuestion` は選択式 UI のため、フリーテキスト入力には Other を使う。`issue-edit` Phase 2.1 と
同じパターン。

## warning-only-not-match

index に登録行はあるが Pass 1 が候補を抽出できない（カタログ形式のドリフト等）とき、helper は
警告 1 行だけを出す。経験則は 1 件も注入されていないのでマッチ有りと扱わない。本コマンドは
stderr を捨てない唯一の経路なので、同趣旨の WARNING が stderr にも出る。
