---
type: "heuristics"
title: "静的 pin が壊れたら期待値を書き写す前に、pin が観測する表現を不変部分へ寄せられないか検討する"
domain: "heuristics"
description: "producer 側のリテラルを変えたとき、そのリテラルを字面で照合していた consumer 側の静的 pin だけが壊れることがある。実行経路は完全に不変なので動作確認では検出できず、期待値へ新しい表現を書き写す最小パッチは同じ誤報の再発構造を残す。"
created: "2026-08-13T19:20:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260813T081206Z-pr-2304.md"
  - type: "fixes"
    resource: "raw/fixes/20260813T081923Z-pr-2304.md"
  - type: "reviews"
    resource: "raw/reviews/20260813T090426Z-pr-2304.md"
tags: ["pin", "static-assert", "producer-consumer", "brittleness", "refactor"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-13T19:20:00+09:00" }
---

# 静的 pin が壊れたら期待値を書き写す前に、pin が観測する表現を不変部分へ寄せられないか検討する

## 概要

producer 側のリテラルを変えたとき、そのリテラルを字面で照合していた consumer 側の静的 pin だけが壊れることがある。実行経路は完全に不変なので動作確認では検出できず、期待値へ新しい表現を書き写す最小パッチは同じ誤報の再発構造を残す。

pin が **守る対象**（保ちたい不変量）と pin が **観測する表現**（今そこにある書き方）は別物である。壊れた pin を直すときは、まず観測面を不変部分だけに絞れないかを見る。絞れるなら、それは期待値の更新より小さく、次の表現変更に対して構造的に強い。

## 詳細

### 観測された症状

シーン連結スクリプトの preset 配列を `"out/NN.mp4"` から `"$scene_dir/NN.mp4"` へ変えた。契約チェックスクリプトはこの配列を **awk でテキストとして抽出し**、期待値の文字列列と等値比較していた。順序 pin は必ず失敗するようになり、`npm run check` が `&&` 連鎖の第 1 段で死んで決定論チェックまで到達しなくなった。4 レビュアーが独立に同じ file:line へ収束した。

pin が守りたかったのは **M1〜M7 の並び順とファイル名の契約**である。しかし観測していたのはパス文字列全体で、そこには探索先ディレクトリという偶有的な情報が混ざっていた。壊れたのは契約ではなく、契約を近似していた表現のほうだった。

### 2 つの直し方

| 方向 | 変更 | 次に表現を変えたとき |
|---|---|---|
| 期待値の書き写し | 期待値へ `$scene_dir/` を追記する | 同じ誤報が再発する |
| 観測面の絞り込み | 比較を basename 列へ寄せ、期待値から接頭辞を落とす | 影響しない |

採用したのは後者。awk の抽出に `sub(/^.*\//, "")` を足し、期待値から探索先の接頭辞を除いた。守る対象（順序とファイル名）は変わらず、観測する表現からパスの可変部分が消えた。

### 見分け方

pin が壊れたとき、次を順に問う。

1. **実行経路は変わったか。** 変わっていないのに pin だけが落ちたなら、それは仕様違反の検出ではなく pin の脆さである
2. **落ちた原因の文字列は、pin が守りたい性質の一部か。** パスの接頭辞・変数名・探索先ディレクトリのような偶有的な表現なら、観測面から外せる可能性が高い
3. **外した後も、守りたい違反を kill できるか。** 順序を入れ替えた変異・ファイル名を変えた変異を当てて実測する。kill できなくなったなら絞りすぎである

3 の実測を省くと、pin を「壊れなくする」つもりで「何も守らなくする」ことになる。絞り込みは必ず変異注入とセットで確定する。

### 適用範囲

本ヒューリスティックが効くのは、consumer がソースを**テキストとして**読む静的 pin に限る。実行結果を比較する動的テストが producer の変更で落ちたときは、まず仕様変更の妥当性を疑う（観測面の絞り込みは後）。

## 関連ページ

- [pin literal は「その行に固有」を grep -c で確かめ、変異注入で kill を実測してから確定する](../patterns/pin-literal-uniqueness-verified-by-mutation.md)
- [静的 pin は禁止表記の denylist ではなく、成立させたい性質の allowlist で書く](./static-pin-semantic-allowlist-not-notation-denylist.md)
- [pin を足す「前」に mutation を当てると、pin の要否と有効性を分離して判定できる](../patterns/mutation-before-pin-separates-necessity-from-efficacy.md)

## ソース

- [PR #2304 review results (cycle 1: preset 配列変更で順序 pin が破壊された)](../../raw/reviews/20260813T081206Z-pr-2304.md)
- [PR #2304 fix results (basename 比較へ寄せて接頭辞依存を外した)](../../raw/fixes/20260813T081923Z-pr-2304.md)
- [PR #2304 review results (cycle 4: 「pin の対象と pin の表現を分離できていない」という 3 cycle 通底の総括)](../../raw/reviews/20260813T090426Z-pr-2304.md)
