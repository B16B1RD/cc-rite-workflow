---
type: "heuristics"
title: "1 つの skip ガードの背後に AC の全カバレッジを置かない — permission 非依存の失敗誘発で床を残す"
domain: "heuristics"
description: "書き込み失敗のような異常系を検証する TC は `chmod` で権限を落として作ることが多く、権限操作が効かない環境（root / WSL2 DrvFs / overlay マウント）向けに skip ガードを付ける。"
created: "2026-08-06T02:49:27Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260806T010533Z-pr-2120.md"
  - type: "fixes"
    resource: "raw/fixes/20260806T002741Z-pr-2120.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T02:49:27Z" }
---

# 1 つの skip ガードの背後に AC の全カバレッジを置かない — permission 非依存の失敗誘発で床を残す

## 概要

書き込み失敗のような異常系を検証する TC は `chmod` で権限を落として作ることが多く、権限操作が効かない環境（root / WSL2 DrvFs / overlay マウント）向けに skip ガードを付ける。実測では **ある AC を検証する 2 つの TC が両方とも同じ `chmod` プローブの else 側にあり、プローブが skip するホストでは AC のカバレッジが皆無**になっていた。しかも skip は FAIL ではないので、結果表示（`PASS n / FAIL 0`）からは判別できない。

## 詳細

### 失敗の構造

```
if chmod で権限を落とせる環境か？
  ├─ yes → TC-A（権限で失敗させる）
  │        TC-B（権限で失敗させる）      ← AC のカバレッジはここだけ
  └─ no  → 両方 skip                     ← AC のカバレッジ 0、しかも緑
```

skip ガード自体は正しい（効かない環境で FAIL させても意味がない）。問題は **同じガードの背後に AC の全 TC を置いたこと**である。ガードが 1 つでも、その配下が AC の全体なら実質的な単一障害点になる。

### 対策 — permission 非依存の失敗誘発を 1 本混ぜる

権限に依存しない失敗の作り方があるなら、そちらを選ぶと skip ガードの背後に隠れないカバレッジが残る。

| 誘発方法 | 起きるエラー | 権限依存 |
|---|---|---|
| `chmod` で書き込み権限を落とす | EACCES | あり（root / DrvFs / overlay で無効） |
| パスを **regular file** で塞ぐ | ENOTDIR | なし（POSIX 全域で確実） |
| パスを **ディレクトリ** で塞ぐ | EISDIR | なし（同上） |

同じ事例では cycle 2 で 1 本目を ENOTDIR 方式へ、cycle 3 で 2 本目を EISDIR 方式へ移し、**プローブが skip するホストでも AC の床が 2 本残る**状態にした。

**「権限に依存しない失敗の作り方があるなら、そちらを選ぶ」** — これは移植性の話であると同時に、カバレッジが skip の影に隠れないための構造の話でもある。

### 検証法 — skip ガードを skip 側に固定して mutation を当てる

穴の存在は通常の実行では見えない。**skip ガードを skip 側に強制した状態で mutation を当てる**と一発で出る。

```
修正前: skip 固定 + mutation → PASS 191 / FAIL 0   （素通り = カバレッジ 0）
修正後: skip 固定 + mutation → FAIL 2              （床が残っている）
```

**skip ガードを持つ TC を書いたら、この「skip 固定 + mutation」を必ず一度実行する。**

### 兄弟が pin されているほど穴は見つけにくい

同 PR では、同一 helper 内の 3 つの失敗分岐のうち 2 つが pin 済みで、1 つが未 pin だった。**カバレッジの穴は「全部未 pin」より「大半が pin 済み」の方が発見しにくい** — テストファイルを読むと該当セクションが充実して見えるためである。

発見は mutation でしか行えない（各分岐の WARNING を 1 つずつ削除してスイートが green のまま通るかを見る）。本ケースでは 2 reviewer が独立に同じ mutation を実行して同じ穴を報告した。

## 関連ページ

- [プラットフォーム skip を増やすなら「緑の意味」を痩せさせない skip 会計をセットで入れる](./skip-accounting-honest-green.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](./mutation-testing-measures-assertion-strength.md)
- [2 つの値が一致することの assert は、その値の書式を pin しない](../patterns/mutual-consistency-assert-does-not-pin-format.md)

## ソース

- [2 本目を EISDIR 方式へ移し床を 2 本確保](../../raw/fixes/20260806T010533Z-pr-2120.md)
- [ENOTDIR 方式の導入と未 pin 分岐の発見](../../raw/fixes/20260806T002741Z-pr-2120.md)
