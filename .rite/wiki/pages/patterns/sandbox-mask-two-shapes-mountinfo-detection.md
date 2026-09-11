---
type: "patterns"
title: "sandbox の書込防止マスクは char device 形と ro bind mount 形の 2 形状があり、bind mount 形は mountinfo の mount point 完全一致で検知する"
domain: "patterns"
description: "Claude Code の sandbox が保護対象パスへ張る書込防止マスクには、`/dev/null` を重ねる character device 形と、既存の実ファイルを read-only で bind mount する形の 2 形状がある。後者は `ls` でも `test -c` でも通常ファイルに見えるため、`/proc/self/mountinfo` の field 5（mount point）との完全一致で判定する。`mountpoint -q` は版で rc が揺れ、`stat` の st_dev は親と同じ番号になるため一次判定に使えない。"
created: "2026-09-11T15:07:49Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-11T15:07:49Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260911T135916Z-pr-2690.md"
  - type: "fixes"
    resource: "raw/fixes/20260911T140326Z-pr-2690.md"
tags: ["sandbox", "bind-mount", "mountinfo", "worktree", "test-fixture"]
confidence: high
---

# sandbox の書込防止マスクは char device 形と ro bind mount 形の 2 形状があり、bind mount 形は mountinfo の mount point 完全一致で検知する

## 概要

Claude Code の sandbox が保護対象パスへ張る書込防止マスクには、`/dev/null` を重ねる character device 形と、既存の実ファイルを read-only で bind mount する形の 2 形状がある。後者は `ls` でも `test -c` でも通常ファイルに見えるため、`/proc/self/mountinfo` の field 5（mount point）との完全一致で判定する。`mountpoint -q` は版で rc が揺れ、`stat` の st_dev は親と同じ番号になるため一次判定に使えない。

## 詳細

**2 形状の観測**（同一セッションの実測）:

- 既存の実ファイル（git worktree の管理ディレクトリ配下 `config.worktree` / `commondir`、worktree に複製された `.claude/settings.local.json` 等）には、ファイル自体を read-only で bind mount する形が張られる。mountinfo には `.../config.worktree .../config.worktree ro,... - ext4 /dev/sdd` のように親と同じデバイスで載る
- 存在しない保護対象パス（シェル dotfile 等）や一部の管理ファイルには `/dev/null` の character device を重ねる形が張られる。こちらは `test -c` で真になる

`test -c` だけの検知は前者を「マスク無し」と誤判定し、その状態で `git worktree remove --force` を実行すると admin dir の再帰削除が `HEAD` を unlink した直後に EBUSY で止まり、`HEAD` だけ欠けた corpse が残る。

**判定手段の選び方**:

- 一次判定は `/proc/self/mountinfo` の field 5 とパスの完全一致。空白は mountinfo 側が `\040` にエスケープするため照合側も同じ表記へ寄せる。照合値を awk に渡すときは `-v` ではなく `ENVIRON` を使う（`-v` は `\040` を空白へ戻す）
- `mountpoint -q` は mountinfo が読めないときの代替に限る。util-linux 2.39 では「非 mountpoint の通常ファイル」で rc=32、「不在」で rc=1 を返し、版により 1 と 32 が揺れるため rc=0 のみを masked と読む。さらに util-linux の `mountpoint` は mountinfo が読めない環境では st_dev 比較へ内部 fallback し bind mount を検知できない
- `stat` の st_dev 比較は使えない。bind mount は親ディレクトリと同じデバイス番号を持つ
- 判定手段が両方ない環境は silent に「マスク無し」と扱わず WARNING を出す

**テスト fixture**:

- 実 mount はテストから張れない。mountinfo の参照パスを 1 変数（既定 `/proc/self/mountinfo`）に集約し、偽の mountinfo ファイルを指すことで実パーサを通した検証ができる。near-miss（admin dir 自体・prefix を共有するパス）を入れて完全一致を pin する
- character device 形は mknod（root 必須）ではなく `ln -s /dev/null <path>` で再現できる。`test -c` は symlink を辿るため真になる。「非 root で張れない」を理由に source-grep pin へ逃げない

## 関連ページ

- [セッション worktree + sandbox 環境の 3 つの罠: cwd 相対 write-allowlist・`.rite-plugin-root` のブランチ相違・`--show-toplevel` の誤解決](../heuristics/worktree-cwd-write-allowlist-and-plugin-root-staleness.md)
- [境界での無害化は下流ツールの別エスケープ意味論までは保証しない（quoted heredoc → awk -v 伝播）](../anti-patterns/sanitization-gap-downstream-tool-escape-semantics.md)

## ソース

- [レビュー結果](../../raw/reviews/20260911T135916Z-pr-2690.md)
- [fix 結果](../../raw/fixes/20260911T140326Z-pr-2690.md)
