---
type: "heuristics"
title: "対象プラットフォーム挙動を shim して blocking gate 側で pin する"
domain: "heuristics"
description: "移植性の修正を non-blocking な対象プラットフォーム leg だけに委ねると、退行が merge を止められない。対象の挙動（コマンドの出力規約・存在可否）を shim で再現する TC を blocking gate 側に置けば、Linux CI でも同じ分岐を踏める。shim が効いていることを assert する floor を必ず添える。"
created: "2026-07-25T14:18:43Z"
updated: "2026-07-25T14:18:43Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260725T100748Z-pr-2017-cycle2.md"
tags: []
confidence: high
---

# 対象プラットフォーム挙動を shim して blocking gate 側で pin する

## 導入判断

- **使う**: 修正対象が特定プラットフォーム固有の挙動差（コマンドの出力規約・存在可否・上限値）で、そのプラットフォームの CI leg が `continue-on-error` などで非ブロッキングなとき
- **使わない**: 差異がプラットフォームではなくデータ依存のとき（通常の TC で表現できる）。また対象挙動を忠実に再現できないとき（不正確な shim は偽の安心を生む）

## 概要

移植性の修正は、対象プラットフォームで検証されて初めて意味を持つ。しかし対象 leg が非ブロッキングだと、そこでの失敗は merge を止められず、修正が退行しても気付けない。対象の挙動を shim で再現する TC を **blocking gate 側**（通常は Linux）に置けば、両方の意味で守られる: 対象 leg は実挙動を、blocking gate は退行を捕まえる。

## 詳細

### 実例

`realpath` の GNU/BSD 差（dangling な最終要素を解決できるか）を除去する修正で、退行 pin を次の shim で置いた:

```bash
# BSD セマンティクス: 全要素が実在しないとエラー
cat > "$shimdir/realpath" <<SHIM
#!/bin/bash
for a in "\$@"; do
  case "\$a" in -*) continue ;; esac
  [ -e "\$a" ] || exit 1
done
exec "$REAL_REALPATH" "\$@"
SHIM
```

GNU realpath 下では旧実装も新実装も同じ結果を返すため、この shim が無いと「realpath 依存に戻す」変更が blocking gate を素通りする。mutation で実証済み: 旧実装へ差し戻すと shim 下の 2 assertion だけが落ちる。

同 PR では `readlink` の末尾改行差についても同型の shim を追加した（perl でリンクを raw に読み、区切り文字なしで出力する）。

### shim には必ず floor を添える

shim が PATH に載っていなければ、その TC は blocking gate 側の通常挙動を再確認するだけの重複になり、退行を検出しない。**shim が実際に効いていることを assert する**:

```bash
# 対象挙動が観測できることを先に確認する
if PATH="$shimdir:$PATH" realpath "$dangling_link" >/dev/null 2>&1; then
  fail "shim が効いていない — 以降の assertion は vacuous"
else
  pass "shim is in effect"
fi
```

floor の probe には **検証対象そのものを使わない**。区切り文字の有無を検証する shim の floor を `$(cmd)` で判定すると、コマンド置換が検証対象のバイトを剥がして常に「効いている」と判定する。sentinel 経由で受けるか、probe 用に別の入力（末尾が検証対象バイトでない値）を使う。

### 実バイナリへの委譲を保つ

shim は対象挙動を再現する薄いラッパにとどめ、それ以外は実バイナリに `exec` で委譲する。全面的に振る舞いを置き換えると、同じコマンドを使う無関係な経路（本例では `hook-preamble.sh` の realpath 呼び出し）を壊し、TC が「別の理由で」通ってしまう。実バイナリのパスは shim を張る **前に** `command -v` で捕捉しておく。

### 非ブロッキング leg の扱い

対象 leg を blocking へ昇格するかは別の判断で、本ヒューリスティクスの範囲外。ただし「非ブロッキングだから対象での失敗は無視してよい」ではない — PR #2017 では対象 leg（macOS）の失敗が、blocking gate と 5 サイクルのレビューを通過した実バグを唯一検出した。非ブロッキング leg の赤は、merge を止めないだけで、読む価値は blocking gate と変わらない。

## 関連ページ

- [移植性のための外部コマンド差し替えは分岐を消さず「別の層」へ移動させる](../anti-patterns/external-command-swap-relocates-platform-divergence.md)
- [GNU ツールの代替 shim は exit code だけでなく期限・シグナル範囲まで契約を全部再現する](../patterns/gnu-tool-shim-full-contract-reproduction.md)
- [否定形の assert は前提条件が崩れると fail-silent になる](../anti-patterns/negative-assertion-vacuous-without-precondition-floor.md)

## ソース

- [PR #2017 review results (cycle 2)](../../raw/reviews/20260725T100748Z-pr-2017-cycle2.md)
