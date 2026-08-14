---
type: "anti-patterns"
title: "オプションを常に明示するテストは、既定値解決という最も壊れやすい経路を丸ごと素通りさせる"
domain: "anti-patterns"
description: "helper のテストがすべての TC でオプションを明示すると、production が実際に通る「オプション省略時の既定値解決」経路にテストが 1 本も当たらない。"
created: "2026-08-07T07:56:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260806T153014Z-pr-2126.md"
  - type: "fixes"
    resource: "raw/fixes/20260806T181047Z-pr-2126-c5.md"
  - type: "reviews"
    resource: "raw/reviews/20260807T011214Z-pr-2130.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T18:40:00+09:00" }
---

# オプションを常に明示するテストは、既定値解決という最も壊れやすい経路を丸ごと素通りさせる

## 概要

helper のテストがすべての TC でオプションを明示すると、production が実際に通る「オプション省略時の既定値解決」経路にテストが 1 本も当たらない。既定解決は state root の解決・設定ファイルの読取・pin ファイルの参照など外部環境に依存する最も壊れやすい部分なのに、そこを無効化しても全スイート green のまま通る。

## 詳細

PR #2126 で同じ欠陥が **cycle 1 と cycle 5 の 2 回**、別々のオプションについて検出された。

**cycle 1**: helper の全 14 テストが `--results-dir` を明示していたが、consumer（skill 側）の実呼び出しは `--pr {n}` のみ。既定解決（`state-path-resolve.sh` 経由で main checkout の state root を導出する経路）を壊しても全件 green だった。セッション worktree から実行したとき main checkout 側の保存先を見失う、という multi-session 特有の失敗がテストで守られていなかった。

**cycle 5**: 同じ helper に後から `--since` を足し、run 開始点 pin による絞り込みを実装した。追加した TC は 3 ケースすべてで `--since` を明示していたが、consumer は相変わらず `--pr {n}` のみで呼ぶ。**pin ファイルを読む既定経路のコードを丸ごと削除しても 4 スイート全部が green のまま**だった（隔離 worktree での変異実験で確認）。しかも「consumer は `--pr` のみで呼ぶ」ことは契約テストが literal で pin していたため、既定経路への依存は契約として固定されているのにテストが無いという非対称になっていた。

**PR #2130 での 3 度目**: 同じ helper に 8.0.4 positive 検査を足した PR で、また再発した。helper のテストは全 leg で `--results-dir` / `--since` を明示していたが、**本番の呼び出しはどちらも渡さない**。既定解決経路（run pin の読み取り）を壊す変異が無検出で通った。cycle 1 のレビューで独立に検出され、教訓は「parameterized 表面を網羅しても、production が実際に使う唯一の引数形を通らなければ配線は pin されていない」と定式化された。**同一 helper で 3 PR 連続の再発**であり、個別の見落としではなく、テストを書く姿勢そのものが生む構造的欠陥であることを示す。

**なぜ繰り返すか**: テストを書くとき、fixture を制御したいので引数を明示するのが自然だからである。`--results-dir "$TEST_DIR/..."` と書けば hermetic になり、環境に依存しない。その hermeticity が、まさに production だけが通る経路を排除する。

**対処**:

0. **「本番が実際に使う唯一の引数形」を通す arm を必ず 1 本置く**（PR #2130 での定式化）。これは下記 1〜4 の要約であり、他をすべて忘れてもこれだけは残す
1. helper に新しいオプションを足したら、**そのオプションを省略した TC を 1 本足す**。既定値がどこから来るかを fixture 側で用意する（テスト用の state root に pin ファイルや設定ファイルを置く）
2. consumer の呼び出し形を grep して、**実際に渡している引数の集合**を確認する。テストがその集合と一致する形を最低 1 本持つこと
3. 既定解決に複数の分岐（ファイルあり / 無し / 読めない）があるなら、それぞれに TC を置く。「省略した TC が 1 本ある」だけでは、分岐のうち 1 本しか守らない
4. 契約テストが consumer の呼び出し literal を pin しているなら、**その literal が既定経路への依存を宣言している**と読む。宣言に対応する挙動テストがあるかを確認する

**判定の目安**: テストスイートを開いて、helper 呼び出し行のオプションが全 TC で同一なら疑う。production の呼び出し形が grep で 1 件も出てこないなら確定。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](./test-pin-protection-theater.md)

## ソース

- [PR #2126 fix results](../../raw/fixes/20260806T153014Z-pr-2126.md)
- [PR #2126 fix results (cycle 5)](../../raw/fixes/20260806T181047Z-pr-2126-c5.md)
- [PR #2130 review results (同一 helper で 3 度目の再発)](../../raw/reviews/20260807T011214Z-pr-2130.md)
