---
type: "anti-patterns"
title: "移植性のための外部コマンド差し替えは分岐を消さず「別の層」へ移動させる"
domain: "anti-patterns"
description: "GNU/BSD で挙動が割れるコマンドを別コマンドへ置き換えるとき、比較するのは「解決セマンティクス（何を返すか）」に偏りがちである。"
created: "2026-07-25T14:18:43Z"
updated: "2026-07-25T14:18:43Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260725T093800Z-pr-2017.md"
  - type: "fixes"
    ref: "raw/fixes/20260725T121640Z-pr-2017-macos.md"
tags: []
confidence: high
---

# 移植性のための外部コマンド差し替えは分岐を消さず「別の層」へ移動させる

## 概要

GNU/BSD で挙動が割れるコマンドを別コマンドへ置き換えるとき、比較するのは「解決セマンティクス（何を返すか）」に偏りがちである。しかし置換先のコマンドも独自のプラットフォーム分岐を持っており、それが **出力フォーマット規約**（末尾の区切り文字を付けるか）のような、レビューで意識されにくい層にあると、分岐は消えたのではなく観測しにくい場所へ移動しただけになる。移動先の分岐は元の分岐と同じ症状（対象プラットフォームでだけ機能が no-op する）を再現しうる。

## 詳細

### 実例: realpath → readlink

`pre-tool-edit-guard.sh` は最終要素 symlink を解決してから scope 判定する。当初の実装は `realpath` を使っていたが、GNU realpath は dangling な最終要素を許容し、BSD/macOS realpath はエラーにする。攻撃形の target（`.git/hooks/pre-commit` 等）は通常まだ存在しないため、**macOS では解決が常に空を返し、ガード全体が silent に no-op** していた。

修正は `realpath` を捨て、`readlink` でリンク先を辿って物理解決を後段の既存 walk（`[ -d ]` / `git -C` が chdir で解決する）に委ねる形にした。存在確認が不要になり、「dangling を解決できるか」という分岐は確かに消えた。

ところが `readlink` には別の分岐があった。**GNU readlink は出力末尾に改行を付け、macOS readlink は付けない。** 実装は「readlink は末尾に改行を 1 個付ける」前提で `${var%$'\n'}` の補正を入れていたため:

| readlink 実装 | 出力 | 補正後 | 判定 |
|---|---|---|---|
| GNU（Linux CI） | `target\n` + `\n` | `target\n` ✓ | deny |
| macOS | `target\n` | `target` ✗ | **allow** |

target 自身の末尾 LF を食い、解決結果が存在しないパスに着地して allow に倒れた。**元のバグと同じ症状（macOS でだけガードが無効化される）が、別のコマンドの別の規約で再現した。**

### なぜレビューで捕まらなかったか

このバグは 5 サイクル・4 名のレビュアー・20 種超の mutation を通過している。すべて Linux 上で実行されたためで、検出したのは CI の macOS leg だけだった。

分岐が「解決セマンティクス」層にあるうちはレビュアーの注意が向く（Issue 本文そのものが論点だったため）。しかし「出力の末尾に区切り文字が付くか」は、コマンドの機能仕様というより出力整形の話に見えるため、移植性レビューの観点から外れやすい。

### 対処

1. **置換先の出力規約も両プラットフォームで比較する。** 解決結果（何を返すか）だけでなく、出力フォーマット（末尾区切り文字・空出力の扱い・エラー時の stdout 有無）を man ページで突き合わせる。
2. **曖昧さは事後補正せず発生源で抑止する。** 「改行が付くか」に依存する補正（1 個剥がす）ではなく、`readlink -n`（GNU/BSD 双方が持つ）で区切り文字を出させない。依存そのものが消える。
3. **対象プラットフォームの挙動を shim して blocking gate 側に置く。** 移植性の修正は、対象プラットフォームで検証されて初めて意味を持つ。[対象プラットフォーム挙動を shim して blocking gate 側で pin する](../heuristics/portability-fix-needs-target-platform-shim-on-blocking-gate.md) を参照。

### 判別のヒント

「このコマンドが無い環境がある」（可用性の問題、fallback chain で解く）と、「このコマンドは両方にあるが振る舞いが違う」（規約の問題、フラグ指定や発生源抑止で解く）は別種である。前者は [cross-platform bash コマンドは fallback chain で portable 化する](../patterns/bash-portable-command-fallback.md) が扱う。本ページは後者で、しかも **移植性修正そのものが後者を新たに持ち込む** ケースを扱う。

## 関連ページ

- [cross-platform bash コマンドは fallback chain で portable 化する](../patterns/bash-portable-command-fallback.md)
- [sentinel でコマンド置換のバイト厳密性を守る](../patterns/sentinel-byte-exact-command-substitution-capture.md)
- [対象プラットフォーム挙動を shim して blocking gate 側で pin する](../heuristics/portability-fix-needs-target-platform-shim-on-blocking-gate.md)

## ソース

- [PR #2017 review results](../../raw/reviews/20260725T093800Z-pr-2017.md)
- [PR #2017 macOS readlink fix](../../raw/fixes/20260725T121640Z-pr-2017-macos.md)
