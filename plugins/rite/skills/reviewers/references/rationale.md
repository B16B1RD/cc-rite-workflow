# reviewers — 設計理由

`skills/reviewers/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## missing-row-gap

`reviewer-registry-drift-check.sh` は agents/ ⇔ Type Identifiers の同期を機械検査する。**欠落**行は
logic-selected reviewer と区別できないため、CONTRIBUTING.md のチェックリストで人手確認する。

## doc-file-patterns-sot

Technical Writer 行の File Patterns が `doc_file_patterns` の SoT。`pr-review` ステップ 1.2.7 は
この行を読むので、複製リストが drift しない。

## code-quality-co-reviewer

fenced code を含む Prompt Engineer 対象には埋め込みコードの品質レビューが要る。sole reviewer
guard は単一 reviewer の盲点（cross-file inconsistency、欠落更新）を防ぐ。Code Quality 自身が
sole のときは追加しない（fallback の二重化を避ける）。

## finding-quality-location

Finding Quality Policy の本文は `_reviewer-base.md` が SoT。本ファイルへ複製すると reviewer
prompt と drift する。`Verification:` は inclusion gate と直交し、再現または failing test の有無を
記録するだけで、報告可否は変えない。

## incremental-mandatory-merge

`incremental` では前サイクル blocking を出した reviewer を `selection_type: mandatory` として合流
させる。Phase 5 が落とさないことを保証しているのは `mandatory` のみ。

## phase5-cap

レビューコストは reviewer 数に比例する（各 reviewer が fact_check と debate を回す）。Phase 4 の
後に cap を掛けるのは、cap が minimum floor や `mandatory` を破らないため。mandatory が cap を
超えるときは cap を譲る。sole-reviewer guard の floor も cost cap では上書きしない。

## complexity-lane-bound

`light` レーンは *upper* bound だけを狭める。mandatory 保証と effective floor は評価が後なので、
`light` でも 3 を超えて spawn しうる（mandatory 4 は 4 のまま）。bound をここに置くのは
`effective_max` 解決を一箇所に保つため。第二の narrowing は floors と mandatory 保護を再実装
することになる。値 3・境界 `{XS, S}`・新 floor を置かない理由は complexity-lane.md。

## generator-critic

Generator = `pr-review` ステップ 4、Critic = ステップ 5。本スキルは選定と横断テーブルだけを持ち、
実行は pr-review に委ねる。
