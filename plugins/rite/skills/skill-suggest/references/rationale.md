# /rite:skill-suggest — 設計理由

`skills/skill-suggest/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## glob-not-find

Glob ツールは Claude Code の標準ファイル探索で、パターンマッチが単純かつ速い。Bash `find` は
サンドボックスと quoting の揺れが大きいため使わない。

## no-numeric-score

数値スコアや重み付け表は、そこにないコンテキストで提案を硬直させる。観点表に載らない作業
（wiki 作業中・hooks 修正中など）でも、作業内容とスキルの目的が噛み合うなら提案する。
