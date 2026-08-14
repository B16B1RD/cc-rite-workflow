---
type: "heuristics"
title: "エラーを 1 つの reason へ畳むときは「原因の類型」が同じかを確かめる — 復旧手順が違うなら分ける"
domain: "heuristics"
description: "`result=$(cmd 2>/dev/null) || result=\"\"` は「失敗したら空にする」定番の書き方だが、**2 つの意味的に違う失敗を同じ値へ畳む**。"
created: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260728T100957Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T122258Z-pr-2038.md"
  - type: "fixes"
    resource: "raw/fixes/20260728T070208Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260727T103843Z-pr-2038.md"
  - type: "reviews"
    resource: "raw/reviews/20260805T022816Z-pr-2112.md"
  - type: "fixes"
    resource: "raw/fixes/20260805T025341Z-pr-2112.md"
  - type: "reviews"
    resource: "raw/reviews/20260813T090426Z-pr-2304.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-13T19:20:00+09:00" }
---

# エラーを 1 つの reason へ畳むときは「原因の類型」が同じかを確かめる — 復旧手順が違うなら分ける

## 概要

`result=$(cmd 2>/dev/null) || result=""` は「失敗したら空にする」定番の書き方だが、**2 つの意味的に違う失敗を同じ値へ畳む**。

- **呼び出し先の実行失敗**（バイナリ不在 / 実行不能 / OOM）= 環境起因
- **呼び出しは成功したが結果が期待と違う** = 呼び出し側（caller）の契約違反

この 2 つは復旧手順が正反対のことがある。前者は「入力を作り直しても解消しない」、後者は「入力を作り直せば収束する」。畳んだ結果として後者の扱いに倒すと、環境起因の失敗に対して「入力を作り直してください」と案内し続けることになる。

差し戻し機構（gate が呼び出し側へ再実行を要求する設計）を持つ系では、これが**非収束ループ**に直結する。

## 詳細

### 具体例

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

1. **復旧案内も原因の類型ごとに分ける。** 既存の hint 関数を「文面がそれらしい」という理由で転用すると誤案内になる。起点事例では環境起因の経路が gh/IO 用の hint を呼び、「gh auth status / network / write 権限を確認し、レビューをやり直してください」と出力していた。同一ブロック内の「jq の実行環境側の問題です」と真正面から矛盾し、operator は先に読んだ誤りから確認を始める。**テストでは「正しい案内が出る」と「誤った案内が出ない」の両方向を pin する。**

2. **リファクタで stderr を握り潰していないか差分で確認する。** この `2>/dev/null` は述語を jq へ寄せるリファクタで**新規に付いた**もので、旧実装（`tr | grep | tail`）に stderr 抑止は無かった。観測性の後退はリファクタが持ち込みやすい。同じファイルの別経路（lookup 側 jq）は stderr を退避して開示する規律を持っており、非対称に気づく材料は差分の中にあった。

3. **分類の境界は「検出位置」で引かない。** exit code や「trap 設置の前か後か」で境界を引くと、同種の契約違反が検出位置の違いだけで機械強制から外れる。境界は原因（caller が直せるか / 直せないか）で引く。

### 逆向きの過剰修正 — 分けるのは診断であって帰結ではない

reason を分ける規律は、**帰結（action）まで理由ごとに分ける**方向へ過剰修正しやすい。PR #2112 でその実害が出た。

id が指す先を取得できない理由のうち、404（削除済み）だけを「新規作成する（recreate）」として他の失敗理由と別の帰結にしたところ、3 つの実害が出た。

- 本文照合が実在の canonical を見つけていても無視して 2 通目を作る
- 0 件 cycle で収束クリアが成立しない
- list lookup の失敗と重なると degraded 判定が非対称になり、縮退が転記条件のどれにも載らない

いずれも「新分岐は既存の counter・marker・転記条件のどれとも交差しない」という暗黙の前提が破れた形である。**帰結を 1 つ増やすと、周辺状態との交差の数だけガードが要る。**

修正は **ガードを 3 本足すのではなく分岐を 1 本削除する**方向を採った（simplification-first）。理由（reason）は復旧手順が違うので 8 種に分けたまま残し、**帰結（action）だけを 1 種に畳んだ**。この分離が効くのは、reason が増えても交差の組合せが増えないためである。

規律を 1 文にすると次になる。

> **分けるのは診断であって帰結ではない。** reason は復旧手順の数だけ分ける。action は、周辺状態との交差を全部埋められる数だけしか持てない。

分岐を 1 本足したら、**既存の観測 marker の発火条件マトリクスに新分岐の行を足して空欄が無いか確認する**。埋められない空欄が出たら、それはガードを足すサインではなく分岐を畳むサインである。

### 畳んだ else が「事実に反する原因」を名乗る

同じ穴は、新設した契約ケースの診断でも開く。日英 2 系統のレンダリング先を検証するケースで、

- **`-P -d out/en` が非ゼロ終了した**（連結そのものが失敗）
- **実行は成功したが完了診断が出ていない**（連結は通ったが観測できない）

を同じ `else` へ落とし、後者で「連結できません」という**事実に反する原因**を表示していた。同ファイルの冒頭コメントが「(1) を満たすが (2) を満たさない場合は『契約が壊れた』ではなく『契約を検証できなかった』——見出しを分けないと初回実行者が誤った原因を読む」と明文で禁じていた形そのものだった。

**規約を書いた本人が、その規約の直下に新しい分岐を足すときに違反する。** 分岐を足す編集では、同一ファイル内の既存の分類規約を読み直してから `else` の中身を書く。畳んだ結果として名乗る原因が、その経路で実際に起きたことと一致するかを 1 つずつ確かめる。

### 新 reason を足すコスト

分類を分けると reason 語彙が増え、登録先も増える。起点事例では 6 箇所（helper docstring / reason 表 / Eval-order enumeration / Retained flag mapping / 共通エラー処理文書 / rationale 文書）への同時登録が必要だった。**登録先が多いこと自体は分けない理由にならない** — 畳んだままの非収束ループのほうが高くつく。ただし追加時は grep で全登録先を機械照合する。

## 関連ページ

- [`cmd > file || true` は no-match (rc=1) と書き込み失敗 (rc>=2) を混同する](../anti-patterns/cmd-redirect-or-true-conflates-nomatch-and-write-failure.md)
- [新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される](../anti-patterns/upstream-silent-path-defeats-new-logged-guard.md)
- [glob で集合を指すと集合の増減に silent に追随しない](../anti-patterns/glob-set-membership-silent-drift.md)

## ソース

- [PR #2038 fix results (cycle 5)](../../raw/fixes/20260728T100957Z-pr-2038.md)
- [PR #2038 fix results (cycle 6, final)](../../raw/fixes/20260728T122258Z-pr-2038.md)
- [PR #2038 fix results](../../raw/fixes/20260728T070208Z-pr-2038.md)
- [PR #2038 review results](../../raw/reviews/20260727T103843Z-pr-2038.md)
- [PR #2112 review results（新分岐 recreate が既存の観測機構と交差して 3 つの無音縮退を生んだことを検出）](../../raw/reviews/20260805T022816Z-pr-2112.md)
- [PR #2112 fix results（ガードを 3 本足さず分岐を 1 本削除し、reason 8 種に対し action を 1 種へ畳んだ）](../../raw/fixes/20260805T025341Z-pr-2112.md)
- [PR #2304 review results (cycle 3 で新設した契約ケースが「非ゼロ終了」と「完了診断なし」を同じ else へ畳んだ)](../../raw/reviews/20260813T090426Z-pr-2304.md)
