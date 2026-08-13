# /rite:template-reset — 設計理由

`skills/template-reset/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## github-target-scope

`github` ターゲットは `.github/` の 4 ファイルに限定する。部分選択（Issue のみ / PR のみ）を出すと
SoT の 4 ファイルセットが欠けた状態で終わる。Phase 3.1.0 のあと legacy 3.1 / 3.2 / 3.3 へ進むと
inline テンプレートと `templates/pr/generic.md` が GitHub テンプレート SoT を上書きする。

## approved-replacement

symlink / canonical-parent ガードと tempfile → `mv` の atomic replace は、setup Phase 4.2 の
no-clobber 生成とは意図的に異なる。既存ファイルをユーザー確認なしで壊さないため、コピー未完了時は
旧 destination を残す。

## mkdir-order

`mkdir -p` は親ディレクトリを自動作成するので順序は不要。明示列挙は意図の可視化だけ。
