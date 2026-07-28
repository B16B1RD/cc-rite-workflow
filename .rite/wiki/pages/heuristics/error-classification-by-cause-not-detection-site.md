---
type: "heuristics"
title: "エラーを 1 つの reason へ畳むときは「原因の類型」が同じかを確かめる — 復旧手順が違うなら分ける"
domain: "heuristics"
description: "「失敗したら空にする」型の慣用句（cmd 2>/dev/null || var=\"\"）は、呼び出し先の実行失敗と、実行は成功したが結果が期待と違うケースを同じ値へ畳む。両者の復旧手順が違う場合、畳んだ側は誤った復旧手順へ operator を誘導し、差し戻し機構を持つ設計では非収束ループになる。分類の境界は検出位置（exit code / コード上の場所）ではなく原因の類型で引く。"
created: "2026-07-28T21:30:00+09:00"
updated: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260728T100957Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T122258Z-pr-2038.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T070208Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260727T103843Z-pr-2038.md"
tags: []
confidence: high
---

# エラーを 1 つの reason へ畳むときは「原因の類型」が同じかを確かめる — 復旧手順が違うなら分ける

## 概要

`result=$(cmd 2>/dev/null) || result=""` は「失敗したら空にする」定番の書き方だが、**2 つの意味的に違う失敗を同じ値へ畳む**。

- **呼び出し先の実行失敗**（バイナリ不在 / 実行不能 / OOM）= 環境起因
- **呼び出しは成功したが結果が期待と違う** = 呼び出し側（caller）の契約違反

この 2 つは復旧手順が正反対のことがある。前者は「入力を作り直しても解消しない」、後者は「入力を作り直せば収束する」。畳んだ結果として後者の扱いに倒すと、環境起因の失敗に対して「入力を作り直してください」と案内し続けることになる。

差し戻し機構（gate が呼び出し側へ再実行を要求する設計）を持つ系では、これが**非収束ループ**に直結する。

## 詳細

### 具体例（PR #2038）

本文の最終非空行を jq で算出する経路で `2>/dev/null` + `|| _body_last_line=""` を使っていた。

```bash
# 畳んでいた実装
_body_last_line=$(jq -Rrs "$JQ_DEF"' last_content_line' < "$CONTENT_FILE" 2>/dev/null) || _body_last_line=""
if [ "$_body_last_line" != "$RECORD_SENTINEL" ]; then
  ... reason=body_sentinel_missing; retain_pending_marker=1   # ← 差し戻し
fi
```

jq が壊れている環境では `_body_last_line=""` になり、契約に完全適合した本文でも `body_sentinel_missing`（= caller 契約違反）と分類され、gate が毎 cycle 差し戻す。本文を作り直しても jq は直らないので**永久に収束しない**。

診断も誤りを断定していた。実際は sentinel と厳密一致していても `実際の最終非空行: ''` と表示し、「gh 認証 / network の問題ではありません」という原因と無関係な復旧手順を出していた。加えて `2>/dev/null` により jq の stderr が 1 行も残らず、真因を追う材料が消えていた。

### 対処

rc を等値検査から分離し、環境起因は専用の reason で「消す側」のバケットへ倒す。

```bash
if ! _body_last_line=$(jq -Rrs "$JQ_DEF"' last_content_line' < "$CONTENT_FILE" 2>"$err"); then
  _gh_err_detail                       # jq の stderr を開示する
  _record_env_failure_hint             # 原因に一致した案内（後述）
  reason=body_check_unavailable        # 専用 reason
  # retain_pending_marker は立てない = gate は差し戻さない
  exit 0
fi
```

### 併せて守るべき 3 点

1. **復旧案内も原因の類型ごとに分ける。** 既存の hint 関数を「文面がそれらしい」という理由で転用すると誤案内になる。PR #2038 では環境起因の経路が gh/IO 用の hint を呼び、「gh auth status / network / write 権限を確認し、レビューをやり直してください」と出力していた。同一ブロック内の「jq の実行環境側の問題です」と真正面から矛盾し、operator は先に読んだ誤りから確認を始める。**テストでは「正しい案内が出る」と「誤った案内が出ない」の両方向を pin する。**

2. **リファクタで stderr を握り潰していないか差分で確認する。** この `2>/dev/null` は述語を jq へ寄せるリファクタで**新規に付いた**もので、旧実装（`tr | grep | tail`）に stderr 抑止は無かった。観測性の後退はリファクタが持ち込みやすい。同じファイルの別経路（lookup 側 jq）は stderr を退避して開示する規律を持っており、非対称に気づく材料は差分の中にあった。

3. **分類の境界は「検出位置」で引かない。** exit code や「trap 設置の前か後か」で境界を引くと、同種の契約違反が検出位置の違いだけで機械強制から外れる。境界は原因（caller が直せるか / 直せないか）で引く。

### 新 reason を足すコスト

分類を分けると reason 語彙が増え、登録先も増える。PR #2038 では 6 箇所（helper docstring / reason 表 / Eval-order enumeration / Retained flag mapping / 共通エラー処理文書 / rationale 文書）への同時登録が必要だった。**登録先が多いこと自体は分けない理由にならない** — 畳んだままの非収束ループのほうが高くつく。ただし追加時は grep で全登録先を機械照合する。

## 関連ページ

- [`cmd > file || true` は no-match (rc=1) と書き込み失敗 (rc>=2) を混同する](../anti-patterns/cmd-redirect-or-true-conflates-nomatch-and-write-failure.md)
- [新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される](../anti-patterns/upstream-silent-path-defeats-new-logged-guard.md)
- [glob で集合を指すと集合の増減に silent に追随しない](../anti-patterns/glob-set-membership-silent-drift.md)

## ソース

- [PR #2038 fix results (cycle 5)](../../raw/fixes/20260728T100957Z-pr-2038.md)
- [PR #2038 fix results (cycle 6, final)](../../raw/fixes/20260728T122258Z-pr-2038.md)
- [PR #2038 fix results](../../raw/fixes/20260728T070208Z-pr-2038.md)
- [PR #2038 review results](../../raw/reviews/20260727T103843Z-pr-2038.md)
