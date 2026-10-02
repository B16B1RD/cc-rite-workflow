# /rite:workflow — 設計理由

`skills/workflow/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## main-checkout-untouched

rite は main checkout のブランチを切り替えない。例外は、Issue 自身のブランチが clean な main checkout に
残っているときだけで、session entry gate が `branch.base` へ切り替えて worktree へ移る。multi_session 時の
作業はセッション worktree 内で進行し、中断後は `/rite:recover` がその worktree へ再入場する（消失していれば
ブランチから再構築）。main checkout のカレントブランチは base のままにしておく。

## status-language-invariant

Status 値（Todo, In Progress 等）は GitHub Projects の設定値をそのまま使うため、言語設定に
依らず共通。
