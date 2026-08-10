---
type: "patterns"
title: "sentinel でコマンド置換のバイト厳密性を守る"
domain: "patterns"
description: "`var=$(cmd)` はコマンド出力の **末尾の改行を全て** 除去する。"
created: "2026-07-25T14:18:43Z"
updated: "2026-07-25T14:18:43Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260725T094630Z-pr-2017.md"
tags: []
confidence: high
---

# sentinel でコマンド置換のバイト厳密性を守る

## 概要

`var=$(cmd)` はコマンド出力の **末尾の改行を全て** 除去する。値そのものが改行で終わりうる場合（改行を含むファイル名、リンク先パス等）、この除去は silent なデータ破壊になる。セキュリティガードのように「評価したパス」と「実際に使われるパス」が一致していることが前提の処理では、この 1 バイトのずれが判定の反転に直結する。

## 詳細

### 何が起きるか

```bash
# リンク先が "y<LF>" というファイル名を指している
_lt=$(readlink "$link")     # → "y"  (末尾 LF が消える)
```

呼び出し側は `y` を評価するが、カーネルは `y<LF>` を辿る。両者が別のファイルを指すため、パスの所属で許可/拒否を決める処理は誤った側に倒れる。起点事例ではこれが「隔離ワークツリー内に着地したので許可」→ 実際の書き込みは親リポジトリの `.git` に着弾、という形で成立した（`origin/develop` では deny、修正版では allow という逆転を実測）。

### sentinel 方式

出力の末尾を非改行バイトにしてから剥がす:

```bash
_lt=$(readlink -n "$path" 2>/dev/null && printf 'X') || _lt=""
_lt=${_lt%X}
```

`printf 'X'` により捕捉文字列は必ず `X` で終わるので、コマンド置換は何も除去しない。`%X` で sentinel だけを外せば元のバイト列が丸ごと残る。

**`&&` の位置が重要**: コマンドが失敗したら sentinel も出力されず `||` 側が発火するので、失敗検出と両立する。`set -euo pipefail` 下でも `||` リストの非終端要素なので ERR trap を誤発火させない。

### 区切り文字は発生源で抑止する

sentinel だけでは足りない場合がある。上例の `-n` がそれで、これが無いと捕捉は「値 + コマンドが付けた改行 + sentinel」になり、**その改行を 1 個剥がすべきか否かがプラットフォーム依存になる**（GNU readlink は付ける、macOS readlink は付けない）。事後に補正するのではなく、区切り文字を出させないフラグで曖昧さを消す。同型のフラグ: `readlink -n` / `printf` の改行なし書式 / `find -print0` + `xargs -0`。

### パス分割にもコマンド置換を使わない

同じ理由で `$(dirname "$path")` も末尾 LF を落とす。パラメータ展開に置き換える:

```bash
case "$target" in
  /*) ;;
  *)  target="${base%/*}/$target" ;;   # $(dirname "$base") ではなく
esac
```

`$base` が常に絶対パス（スラッシュを含む）と保証できるなら `${base%/*}` で足りる。ルート直下（`/foo`）では展開結果が空文字列になり `"/target"` となるが、これは `dirname` の意図（`/` + `target`）と一致する。

### 適用する前に

すべてのコマンド置換を sentinel 化する必要はない。判断基準は **値が末尾に改行を持ちうるか**:

- 持ちうる: ファイル名・パス・ユーザー入力由来の文字列を返すコマンド（`readlink` / `basename` / `dirname` / `cat`）
- 持たない: 数値・ハッシュ・固定書式トークンを返すコマンド（`wc -l` / `sha1sum` / `git rev-parse`）

後者を sentinel 化すると可読性のコストだけが残る。

### 検証

この分岐は Linux 上のテストだけでは pin できない場合がある（GNU の付ける改行が補正と打ち消し合って通ってしまう）。対象プラットフォームの挙動を shim して blocking gate 側で検証すること。

## 関連ページ

- [移植性のための外部コマンド差し替えは分岐を消さず「別の層」へ移動させる](../anti-patterns/external-command-swap-relocates-platform-divergence.md)
- [対象プラットフォーム挙動を shim して blocking gate 側で pin する](../heuristics/portability-fix-needs-target-platform-shim-on-blocking-gate.md)

## ソース

- [PR #2017 fix results](../../raw/fixes/20260725T094630Z-pr-2017.md)
