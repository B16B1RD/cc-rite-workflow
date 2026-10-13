---
type: "patterns"
title: "pin を足す「前」に mutation を当てると、pin の要否と有効性を分離して判定できる"
domain: "patterns"
description: "修正を入れたあと回帰 pin を書くとき、**mutation を当てる順序**で得られる情報が変わる。"
created: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260728T100957Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T122258Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T095536Z-pr-3440.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T10:30:31Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T10:30:31Z" }
---

# pin を足す「前」に mutation を当てると、pin の要否と有効性を分離して判定できる

## 概要

修正を入れたあと回帰 pin を書くとき、**mutation を当てる順序**で得られる情報が変わる。

- **pin を書いてから mutation**: 落ちれば「pin は有効」だが、**元から既存 assertion が検出できていた可能性**を排除できない。冗長な pin を作っても気づけない
- **mutation を先に当てる**: 素通りすれば pin が必要、落ちれば既存層で足りていて pin 不要。**要否と有効性が分離して判定できる**

「pin を追加したら mutation で落ちることを確認する」という規約は広く採られるが、順序を明示しないと後者の情報が失われる。

## 詳細

### 実例（cycle 5）

診断行の文字化けを直した（`neutralize_ctrl` を `--c0-only` へ変更）。この時点で mutation を当てた。

```
M-ED 診断を既定モードへ戻す: PASS: 398  FAIL: 0     ← 検出されない
```

**既存 400 assertion のどれもこの退行を捕まえなかった。** そこで pin（TC-4.11l: 診断行に日本語がそのまま現れる）を追加してから再実測した。

```
M-ED 診断を既定モードへ戻す: PASS: 399  FAIL: 1     ← 検出される
```

もし pin を先に書いていたら「落ちた = よし」で終わり、その pin が本当に必要だったのかは分からないままだった。

### 派生: positive/negative の両方向を pin する

同じ PR で、追加した pin 自体に別の穴が見つかった。

TC-4.11l は「日本語がそのまま出る」ことだけを assert していたため、**無害化処理を丸ごと外す退行では落ちない**（素通しでも日本語はそのまま出るため）。無害化の存在を pin するには「無害化されるべき入力（ESC 等の C0 制御文字）が実際に `?` 化される」ことを assert する必要がある。

```
通過すべきものが通る (日本語)     ← positive
潰されるべきものが潰される (ESC)  ← negative
```

**この 2 つは別の pin**であり、片方だけでは「フラグが honor されている」ことしか固定しない。

「対称化」を謳う変更（corrupt 側で WARNING が発火し、happy-path 側では発火しない）も同じ型で、発火側だけの assert は「無条件に emit する」変異に識別力 0 になる（既存 103 assert が全 PASS だった実測）。非発火側を negative assert で別に pin し、無条件 emit 変異で非発火側が、emit 削除変異で発火側が、それぞれ別々に落ちることを両方向で確かめる。次の 2 点も要る。

- 発火側と非発火側の grep は同一の文言で対にする（文言 drift による片側の取りこぼしを防ぐ）。
- sibling script を source する hook の変異体は `/tmp` ではなく `hooks/` ツリー内に置く（相対 path の source 解決が壊れるため）。

### 派生: 閾値には境界値の fixture を置く

同 PR で `legacy_orphan_count -gt 0` の pin が、fixture を「0 件」と「3 件」しか持たなかったため、閾値を `-gt 1` に退行させても緑のままだった。しかも**境界値 1 は migration の支配的ケース**（旧形式の記録が 1 本残っている状態）で、そこが無音になると運用への案内が届かない。

**閾値を書いたら、その閾値ちょうどの入力を fixture にする。**

閾値の境界 TC は次の条件で組む。fixture の `filler N` の N は、SUT のカウント定義（fence 行や heredoc body を数えるか）と 1 行ずれると境界が無意味になるため、実機で逆算して検算する。

- 測定対象のシグナルを単独の結果決定要因にする（他のシグナルを固定し、対象の発火有無だけが exit code を決める構成）。
- 閾値未満（24 行: 非検知・ラベル非出力）と閾値ちょうど（25 行: 検知とラベル付き値 `long-block(25)` まで assert）を別 TC にする。後者は行カウントの回帰も固定する。

### 適用の型

```
1. 修正を入れる
2. 隔離コピー (cp -r / git worktree add --detach) に mutation を当てる
3. 落ちる  → 既存層で足りている。pin は不要（冗長 pin を作らない）
   素通り → pin を追加し、同じ mutation で落ちることを再実測する
4. positive / negative の両方向が要るかを確認する
5. 閾値があれば境界値の fixture を足す
```

mutation は必ず**隔離コピー**で当て、無害な変更で落ちないこと（negative control）を併置する。

### fix の前後 2 点で同じ変異を回す

（→ mutation-prove-new-pin に統合: 修正前後の 2 点に同じ変異を当てる。検査名の表示有無など読みやすさの差は別改善）

## 関連ページ

- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](./absence-pin-base-present-head-absent-single-line.md)
- [検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する](./detection-mutation-strictness-symmetry.md)
- [cycle が進んでも findings が減らないときは点修正をやめて構造を疑う](../heuristics/non-converging-review-loop-suspect-structure.md)

## ソース

- [fix 結果](../../raw/fixes/20260728T100957Z-pr-2038.md)
- [fix 結果](../../raw/fixes/20260728T122258Z-pr-2038.md)
- [fix 前後の 2 点で変異を回して追加テストの検出力を確かめたレビュー結果](../../raw/reviews/20260929T095536Z-pr-3440.md)
