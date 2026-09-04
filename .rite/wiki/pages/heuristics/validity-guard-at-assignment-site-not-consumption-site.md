---
type: "heuristics"
title: "値の妥当性ガードは消費する場所ではなく値が入る場所に置く — 空値と未指定が sentinel を共有すると消費側のガードは不発する"
domain: "heuristics"
description: "「引数を黙って無視しない」ためのガードを、その値を使う分岐に置くと、明示的な空値が「未指定」と同じ sentinel（空文字）に落ちるため不発する。ガードを値が変数に入る地点へ移すと、消費側の複数分岐に開いていた穴が同時に閉じる。"
created: "2026-08-13T19:20:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260813T081206Z-pr-2304.md"
  - type: "fixes"
    resource: "raw/fixes/20260813T081923Z-pr-2304.md"
  - type: "reviews"
    resource: "raw/reviews/20260813T090426Z-pr-2304.md"
tags: ["guard", "fail-loud", "sentinel", "bash", "getopts"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-13T19:20:00+09:00" }
---

# 値の妥当性ガードは消費する場所ではなく値が入る場所に置く — 空値と未指定が sentinel を共有すると消費側のガードは不発する

## 概要

「引数を黙って無視しない」ためのガードを、その値を使う分岐に置くと、明示的な空値が「未指定」と同じ sentinel（空文字）に落ちるため不発する。ガードを値が変数に入る地点へ移すと、消費側の複数分岐に開いていた穴が同時に閉じる。

新設したガードが defect class の**隣接メンバー**を取りこぼす形は、ガードの述語ではなく**ガードの位置**が原因のことがある。述語を足して塞ぐ前に、判定を上流へ動かせないかを見る。

## 詳細

### 観測された症状

シーン連結スクリプトに「シーン探索先を指す `-d` を preset 以外で黙って無視しない」ガードを足した。

```bash
# ❌ 消費する場所に置いたガード
[ -z "$scene_dir" ] || { echo "assemble: -d は -P と併用してください" >&2; exit 1; }
```

`-d ""` を渡すと `scene_dir` は空文字になる。この述語では「`-d` が未指定」と「`-d` に空文字が明示された」が区別できず、ガードは通過する。同時に preset 側の既定値代入も

```bash
[ -n "$scene_dir" ] || scene_dir="out"
```

で空文字を既定値へ silent 置換していた。したがって `-d "$EN_DIR"` の `EN_DIR` が空だと、**日本語素材から組んだ動画が `-en` の名前で exit 0 完成する**。下流の fail-loud 検査（シーン存在・宣言尺・フレーム周期・BGM 尺・出力実尺照合・可聴性）は素材の言語を見ないので全部通る。

### 対処

ガードを getopts の解析時点、つまり値が変数に入る地点へ移す。

```bash
d) [ -n "$OPTARG" ] || { echo "assemble: -d に空のディレクトリは指定できません" >&2; exit 1; }
   scene_dir="$OPTARG" ;;
```

1 行で、消費側の 2 つの分岐（preset 側の既定値代入と非 preset 側の併用チェック）に開いていた穴が同時に閉じる。以降 `scene_dir` が空文字になる経路は「`-d` 未指定」だけになり、消費側の `-z` 述語が意図どおりの意味を回復する。

### 見分け方

新しいガードを書いたら、次を確認する。

1. **その述語が使う sentinel は、区別したい 2 状態で共有されていないか。** bash の未設定変数と空文字は既定で同じ `-z` に落ちる。区別が必要なら消費地点では表現できない
2. **同じ変数を読む分岐は他にいくつあるか。** 2 つ以上あるなら、各分岐にガードを複製するのではなく代入地点へ 1 本置く
3. **不正値が下流の fail-loud 検査を全部通り抜けないか。** 通り抜けるなら、それは「壊れた成果物が正常終了で完成する」経路であり、ガードの位置を上流へ動かす強い理由になる

3 が成立する系では、ガードの位置を誤ったコストが「エラーが出ない」ではなく「間違った成果物が出る」になる。

## 関連ページ

- [ガードの述語は「守りたい状態」そのものを測る — 存在ではなく内容を測る](./guard-predicate-measures-the-protected-state.md)
- [fail-loud ガードは同じ帰結を持つ全出口に張る（症状側から出口を網羅する）](./fail-loud-guard-covers-all-sibling-exits.md)
- [bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す](../patterns/bash-initial-value-aligns-with-allowed-values.md)

## ソース

- [`-d ""` でガードが不発する経路を検出](../../raw/reviews/20260813T081206Z-pr-2304.md)
- [getopts 解析時点へガードを移して両分岐の穴を同時に閉じた](../../raw/fixes/20260813T081923Z-pr-2304.md)
- [「新設 guard が defect class の隣接メンバーを取りこぼす」反復形の総括](../../raw/reviews/20260813T090426Z-pr-2304.md)
