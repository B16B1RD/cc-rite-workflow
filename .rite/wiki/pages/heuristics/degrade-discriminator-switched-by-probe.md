---
type: "heuristics"
title: "degrade する対象をテストするときは判別子を probe と連動させる — 片側の値で固定すると degrade 環境が恒久 RED になる"
domain: "heuristics"
description: "スクリプトが GNU ツール不在時に `n_stale=0` + rc 0 で短絡する設計だと、「0 件を期待する TC」は **degrade 経路でも PASS する**（vacuous green）。"
created: "2026-07-25T07:05:21Z"
updated: "2026-07-25T07:05:21Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260724T175144Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T184410Z-pr-2013.md"
  - type: "fixes"
    ref: "raw/fixes/20260724T193804Z-pr-2013.md"
tags: ["test", "vacuous-green", "fail-closed", "cross-platform", "degradation-contract"]
confidence: high
---

# degrade する対象をテストするときは判別子を probe と連動させる — 片側の値で固定すると degrade 環境が恒久 RED になる

## 概要

スクリプトが GNU ツール不在時に `n_stale=0` + rc 0 で短絡する設計だと、「0 件を期待する TC」は **degrade 経路でも PASS する**（vacuous green）。これを潰すために機械可読な判別子（`stale_check_ok=true`）を assert に加えるのは正しい。しかし **判別子を GNU 側の値で固定すると、degrade する環境そのもの（= その PR が緑化しようとしていた macOS）が必ず fail する**。「vacuous green を潰す」修正が「恒久 RED」に振れたら行き過ぎのサイン。

## 詳細

### 失敗の構造

```bash
# cycle 1 の修正: vacuous green を潰すつもりで判別子を GNU 側の値に固定
assert_contains "$out" "stale_check_ok=true"
```

これは GNU date のあるホストでしか成立しない。GNU date 非互換ホスト（BSD/macOS）では degrade 経路が `stale_check_ok=skipped_no_gnu_date` を返すため、テストが恒久的に赤くなる。

**判別すべきは「検証が走ったか」であって「GNU かどうか」ではない。**

### 正しい形

probe で期待値を切り替え、**degrade 側も degradation 契約を明示的に要求する**:

```bash
if date -d '1 day ago' >/dev/null 2>&1; then
  expected_discriminator="stale_check_ok=true"
else
  expected_discriminator="stale_check_ok=skipped_no_gnu_date"
fi
assert_contains "$out" "$expected_discriminator"
```

これで **両環境で fail-closed のまま緑になる**:

- GNU 環境: 検証が実際に走ったことを要求
- degrade 環境: degradation 契約（正しい理由で短絡したこと）を要求

どちらの環境でも「黙って 0 件を返した」状態は検出される。degrade 側を単に skip するのではなく **degradation 契約を pin する** のが要点で、これにより degrade 経路自体の regression も守られる。

### 一般化

| アンチパターン | 症状 |
|---|---|
| 判別子なし（`n_stale=0` だけを assert） | degrade 経路で vacuous green |
| 判別子を GNU 側で固定 | degrade 環境が恒久 RED |
| degrade 環境で TC ごと skip | degrade 経路の regression が無検出 |
| **probe で判別子を切り替え、両側を要求** | ✅ 両環境で fail-closed |

### 「期待値が degrade 時の出力と一致する TC」を全数洗い出す

skip ガードを入れる際は、**期待値が degrade 時の出力と一致する TC** を全数洗い出す必要がある。「0 件を期待する TC」は degrade 経路でも PASS してしまうため、環境依存 skip の台帳を作っても取りこぼす。機械可読な判別子を assert に加えて fail-closed にするのが唯一の構造的対策。

## 関連ページ

- [プラットフォーム skip を増やすなら「緑の意味」を痩せさせない skip 会計をセットで入れる](./skip-accounting-honest-green.md)
- [GNU ツールの代替 shim は exit code だけでなく期限・シグナル範囲まで契約を全部再現する](../patterns/gnu-tool-shim-full-contract-reproduction.md)
- [否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す](../patterns/negative-assertion-positive-control.md)

## ソース

- [PR #2013 review cycle 1 — 環境依存 skip の台帳は degrade 経路と同じ出力を返す TC を取りこぼす](../../raw/reviews/20260724T175144Z-pr-2013.md)
- [PR #2013 fix results (cycle 2) — 判別子を片側で固定すると degrade 環境を壊す](../../raw/fixes/20260724T184410Z-pr-2013.md)
- [PR #2013 fix results (cycle 3) — probe と連動させる canonical 形](../../raw/fixes/20260724T193804Z-pr-2013.md)
