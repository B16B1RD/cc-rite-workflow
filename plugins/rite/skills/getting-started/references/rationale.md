# /rite:getting-started — 設計理由

`skills/getting-started/SKILL.md` から退避した rationale（設計理由・背景・過去の障害）。本体は各該当箇所に
`rationale: references/rationale.md#<anchor>` の 1 行ポインタだけを残す。

ここにあるのは **why** のみ。分岐表・sentinel 一覧・bash ブロックといった実行時に必要な機械
インターフェースは本体が SoT であり、本ファイルへ複製しない。

## on-demand-multisession

Phase 4.5 は通常の onboarding には出さない。複数セッションを聞かれたときだけ出す。初回案内に
入れるとセットアップの本筋が埋もれる。

## ssh-alias-gh-repo-view

origin が `git@github.com-work:owner/repo.git` のような SSH host alias だと、GitHub リポジトリ
でも `gh repo view` が `none of the git remotes configured...` で失敗する。rite の各スキルは
`git-remote.sh` で remote URL を直接パースするため動作する。setup は非空 remote に対して新規
リポジトリ作成を提案しない。

## upgrade-delegate

`--upgrade` の手順・preview/confirm・back-add の詳細は `/rite:setup` が SoT。本スキルは「いつ
走らせるか」とコマンド名だけを案内し、upgrade 手順を複製しない。
