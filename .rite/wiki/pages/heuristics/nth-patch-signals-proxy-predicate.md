---
type: "heuristics"
title: "同じ機構への N 回目のパッチは、その機構が依拠する述語が proxy である信号"
domain: "heuristics"
description: "累積対策 PR で「前 cycle の fix が触った箇所」への指摘が来たとき、同じ機構にもう 1 枚パッチを足す前に、その機構の発火/適用を決めている述語が『測りたいもの』そのものか『手近な相関値（proxy）』かを疑う。proxy を実際の述語へ置き換えると、パッチが必要だった経路がまとめて消えることがある。PR #2099 では pin 更新ゲートの `cur_cc == 0` が「新しい run か」の proxy で、reset 失敗時に相関が切れて誤発火経路を生んでいた。`fresh || cur_cc == 0` の選言へ替えるだけで、cycle 4 が塞いだ経路と cycle 5 で見つかった同型経路の両方が機構追加ゼロで閉じた。"
created: "2026-08-04T15:54:17+09:00"
updated: "2026-08-04T15:54:17+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260804T060209Z-pr-2099.md"
  - type: "fixes"
    ref: "raw/fixes/20260804T060834Z-pr-2099.md"
tags: []
confidence: medium
---

# 同じ機構への N 回目のパッチは、その機構が依拠する述語が proxy である信号

## 概要

review-fix loop で「前 cycle の fix が導入・変更した箇所」への指摘を受けたとき、既定の反応は同じ機構へのパッチ追加になりやすい。だがその反復自体が、機構の発火/適用を決めている述語が **proxy（測りたいものと相関するだけの手近な値）** であることの信号でありうる。proxy は相関が切れる条件で必ず破れ、破れた分だけ「例外経路へのパッチ」が要求されつづける。パッチを 1 枚足す前に述語そのものを疑うと、パッチが必要だった経路の族ごと消えることがある。

`/rite:fix` の Simplification-First Response Principle が定める Escalation trigger（同一 PR の前 cycle の fix が触った箇所への指摘では、追加パッチを既定選択にしない）を、実際に何を疑えばよいかまで具体化したもの。

## 詳細

### 起点事例（PR #2099 / Issue #2088）

`/rite:iterate` のサーキットブレーカーを cycle 数上限から収束トレンドの発散検出へ移す PR。ステップ 0.6 が run 開始点 pin を更新するゲートは `cur_cc == 0`（cycle counter がゼロ）だった。

このゲートが本当に表現したかったのは「**これは新しい run か**」である。`cur_cc == 0` はその proxy にすぎない。相関が切れるのは fresh entry で counter reset が失敗した経路で、そこでは marker の自己矛盾を避けるため意図的に `cur_cc` を 0 に落とさない設計になっていた。結果として:

- fresh entry なのにゲートに入らない → pin が前 run のまま据え置かれる
- ステップ 1 はその stale pin を `--since` に、残存 counter を `--cycle-count` に渡す
- helper の stale pin guard は前提条件（`since` が空 **または** `cycle_count == 0`）の連言が揃わず素通りする
- 新 run が前 run の blocking 列を含む混合列で判定・発火する（守りたかった false positive がそのまま起きる）

cycle 4 は同じ縮退クラスのうち「pin 書込失敗」経路だけを `rm -f` + WARNING + marker の追加で塞いだ。cycle 5 のレビューは (a) その `rm -f` 自体の失敗サブ経路で WARNING が矛盾する、(b) 構造的に同型の counter reset 失敗経路が未処理、の 2 件を返した。**1 つの縮退クラスに対して 3 経路あるうち 1 経路しか塞げていなかった**。

ここで reset 失敗分岐にも `rm -f` を複製するのが「N 回目のパッチ」。実際に採ったのは述語の是正で、ゲートを

```
cur_cc == 0            →  cb_mode_init == fresh  ||  cur_cc == 0
```

の選言に替えた。fresh 側の項が入ることで counter reset の成否に依らず新 run では必ず pin を張り直すため、経路 (b) は**パッチを 1 行も足さずに消えた**。`cur_cc == 0` の項を残すのは、ステップ 5.0.1 / ステップ 6 共有前段が counter を 0 にして run を閉じた直後の起動（phase 維持のため resume 判定になる）を拾うため。

### 判定手順

1. 指摘が「同一 PR の前 cycle の fix が導入・変更した箇所」に当たるかを確認する（description が cycle を名指ししていなくても、`git log -p` で当該行の由来を辿れば分かる）
2. 当たるなら、その機構の**発火条件 / 適用条件を決めている述語**を書き出す
3. その述語が「本当に測りたい性質」そのものか、相関する別の観測値かを問う
4. proxy なら、相関が切れる条件を列挙する。**その列挙が、これまでパッチを当ててきた例外経路の一覧と一致するなら proxy 確定**
5. 実際の述語へ置き換える。既存経路が落ちないよう、proxy が拾っていた範囲は選言などで明示的に保つ

### proxy を疑うべき兆候

- 同じ機構に 2 枚以上のパッチが当たっている
- 各パッチの分岐条件が「〜が失敗した場合」「〜が取れなかった場合」の形で、実質「相関が切れた場合」を列挙している
- 述語に使っている値が、コメントで「〜のとき 0 になる」「〜を意味する」と**別の言葉で説明されている**（説明に出てくる言葉のほうが本来の述語）
- その値を意図的に更新しない分岐が設計上存在する（PR #2099 の「marker 整合のため `cur_cc` を 0 に落とさない」がこれ）

### 適用範囲と限界

- 述語の是正は**既存経路の挙動を変えうる**。proxy が拾っていた範囲を洗い出し、選言 / 条件追加で明示的に保つこと。PR #2099 では `cur_cc == 0` の項を落とすと run-close 直後の resume 起動で pin が更新されなくなる回帰が入るところだった
- すべての反復パッチが proxy 由来ではない。真に独立した例外が複数ある場合もあり、その場合は個別対応が正しい。判定手順 4（相関が切れる条件の列挙 ≡ 既存パッチの一覧）が識別子になる
- 手順書（SKILL.md 等）の bash block に対しては述語の是正が 1 行で済むことが多く、コストが低い。実装コードでは呼び出し側への波及を確認すること

## 関連ページ

- [ガードの precondition に代理値を使うと、守るべき経路でだけ無効化される](../anti-patterns/guard-precondition-proxy-value-silent-where-needed.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)

## ソース

- [PR #2099 review results (cycle 5)](../../raw/reviews/20260804T060209Z-pr-2099.md)
- [PR #2099 fix results (cycle 5)](../../raw/fixes/20260804T060834Z-pr-2099.md)
