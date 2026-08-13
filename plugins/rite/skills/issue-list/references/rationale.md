# /rite:issue-list — 設計理由

`skills/issue-list/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## projects-fetch-delegate

Projects 全 item の取得は `projects-items-fetch.sh` に委譲する。固定 `--limit` は 100/500 件超を
silent truncation していた。helper 不在も旧実装と同じ sentinel に倒し、Status 列なし表示へ
fallback する。全経路 exit 0（non-blocking）は一覧表示自体を止めないため。
