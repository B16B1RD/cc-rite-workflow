# rite-workflow — 設計理由

`skills/rite-workflow/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## sentinel-naming

旧 `:completed` 形式は LLM の turn-boundary heuristic と衝突し、caller skill の次 step を skip して
turn が暗黙終了する事象を構造的に誘発する（実測）。`:returned-to-caller` は「caller に return した
= caller の次 step に進む」という semantic に置換することで terminal vocabulary を構造的に排除する。
各 emit site では sentinel 直前に `<!-- skill return signal: caller must continue next step -->` を
併記して active disambiguation を提供する。

`create.md` の `[create:returned-to-caller:{N}]` は他 sub-skill の return tag と異なり create.md 内
で完結する terminal sentinel である（create は orchestrator から sub-skill として呼ばれず、継続
すべき caller skill を持たない）。`:returned-to-caller` という命名は全 producer 統一形式であり、
create に caller skill が存在することを意味しない（hook / grep 契約のため必須）。

## task-tracking-threshold

閾値を「3 step 以上」とするのは、2 step 以下の skill は単一 turn 内で逐次実行する想定で TaskList
管理の overhead が利点を上回らないため。nested 時の二重 TaskCreate は最内側 sentinel を turn 終了
と誤認する事故を招く。

## four-command-split

`/rite:issue-start` は 4 つの単機能コマンドに分解された。implicit-stop 対策の hook 群
（`auto-fire-step0.sh` / `stop-create-interview-block.sh` / `verify-terminal-output.sh`）は撤去済み。
現行の continuation enforcement は Layer 3 caller-continuation hints + Layer 4a/4b orchestrator-side
reinforcements + flat sequential structure による（旧 Layer 1 prompt contract は cleanup.md flat 化と
同時に物理排除済）。

## incident-emit-removed

旧 auto-registration（`workflow-incident-emit.sh` sentinel + `/rite:issue-start` 検出 +
`workflow_incident:` config key）は単層の plain-stderr 設計に置換した。失敗は可視だが Issue 自動
登録はせず、ユーザーが起票するかを決める。
