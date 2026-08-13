# /rite:wiki-init — 設計理由

`skills/wiki-init/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## gitignore-negation

`.rite/wiki/` が `.gitignore` にあると、`same_branch` では `git add .rite/wiki/` が "paths are
ignored" で hard fail する。negation を対話的に追記して未然に防ぐ。separate_branch は worktree
経路なので `.gitignore` の影響を受けない。

consumer project は `# <<< gitignore-wiki-section-end (anchor / F-09 対応)` を持たない
（templates/ に該当 .gitignore が無く、setup / gitignore-health-check も inject しない）。anchor
不在で Edit すると `old_string not found` になるため early skip + 手動追記案内へ倒す。

## variable-literal-embed

Claude Code の Bash ツール間でシェル変数は保持されない。ステップ 1.2 / 2.1 の値は後続ブロックの
冒頭でリテラル再定義する。

## gitkeep

`pages/{patterns,heuristics,anti-patterns}/` は初期状態でファイルを持たない。`.gitkeep` が無いと
`/rite:wiki-ingest` が page を書くとき親ディレクトリ不在で Write が失敗する。導入前に init した
wiki ブランチは `.gitkeep` を持たないため、3.5.1 の冪等 migration で補完する。worktree 経由で
commit するため dev ブランチの HEAD は動かない。

## worktree-setup-nonblocking

`separate_branch` で wiki ブランチ作成直後に `.rite/wiki-worktree/` を作る。ingest が dev ブランチ
を離れずに wiki ツリーへ Write/Edit できるようにするため。worktree 作成失敗は init 全体を失敗
させない（ingest 前に手動作成すれば足りる）。

## verify-negation-nonblocking

`--verify-negation` は post-injection 専用。plugin_root 解決失敗も verification skip してステップ
2 へ進む（ステップ 3.1 の git add で改めてエラーが出る）。probe の親ディレクトリは rmdir せず
残し、後続のディレクトリ作成と衝突しない。
