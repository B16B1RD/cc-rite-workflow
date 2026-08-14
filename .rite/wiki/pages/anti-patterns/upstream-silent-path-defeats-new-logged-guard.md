---
type: "anti-patterns"
title: "新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される"
domain: "anti-patterns"
description: "「silent skip 禁止 — スキップは WARNING で可視化する」という MUST 要件に対して logged ガードを新設しても、**同じ判定条件（例: 24h age guard）を持つ既存の silent continue が制御フロー上流に残っている**と、実運用で最も起きやすい入力がそちらに先に吸われ、新設ガードは到達不能になる。"
created: "2026-07-21T18:30:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260721T171603Z-pr-1959.md"
  - type: "fixes"
    resource: "raw/fixes/20260721T172102Z-pr-1959.md"
  - type: "fixes"
    resource: "raw/fixes/20260721T173955Z-pr-1959.md"
  - type: "fixes"
    resource: "raw/fixes/20260731T021333Z-pr-2070.md"
tags: ["silent-skip", "guard-ordering", "visibility", "case-arm-enumeration"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-01T00:21:06+09:00" }
---

# 新設 logged ガードの上流に同一判定の silent 経路が残ると支配的入力で可視化が無効化される

## 概要

「silent skip 禁止 — スキップは WARNING で可視化する」という MUST 要件に対して logged ガードを新設しても、**同じ判定条件（例: 24h age guard）を持つ既存の silent continue が制御フロー上流に残っている**と、実運用で最も起きやすい入力がそちらに先に吸われ、新設ガードは到達不能になる。起点事例で corpse 用 logged age guard を Gate 2 の後段に置いたところ、Gate 2 free 経路の既存 silent continue（同一 24h 判定）が claim-free の fresh corpse（cleanup が claim を無条件 release するため実運用の支配形）を先に握り潰し、2 reviewer が独立に runtime 再現で検出した。

## 詳細

### 失敗の構造

1. 新カテゴリ（corpse）の skip を可視化する logged ガードを追加する
2. しかし既存の case 分岐（free/stale/other/own/`*` の 5 arm）のうち一部 arm に同一条件の silent continue が残っている
3. 実運用の支配的入力（claim-free）が silent arm に先に到達 → stderr 出力ゼロで skip → MUST 違反
4. cycle 1 で free arm を直しても、cycle 2 で live claim (other/own) arm の silent continue が同型で再指摘された

### Canonical Fix

- **silent 側の条件を新カテゴリ除外で絞る**: `if [ "$_corpse" -eq 0 ] && [ <既存条件> ]; then continue; fi` — 新カテゴリだけを後段の logged ガードへ fall-through させる 1 条件追加が最小・外科的（既存経路の挙動は不変）
- **skip 経路の全数列挙**: 「可視化 MUST」対応時は、対象カテゴリが到達しうる skip 経路（case 文の全 arm + 前段ゲート群）を guard の発火順序込みで列挙し、各経路に WARNING があるかを 1 つずつ確認する。1 arm だけ直すと残りが次 cycle で再指摘される
- **エラー分岐の対称性**: 同種失敗（rm -rf 失敗）が対象別（working tree / admin dir）に別分岐へ落ちる場合、片方に手動コマンドを付けたらもう片方にも付ける

### 検証パターン

修正の pin は「支配的入力の fixture（claim ファイル削除 + fresh）で stderr が非空」を assert する behavioral テストで行う。survival assert だけでは silent skip と logged skip を区別できない。

## 関連ページ

- [前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する](../anti-patterns/silent-precondition-omit-disables-and-defense-chain.md)
- [Test が early exit 経路で silent pass する false-positive](../anti-patterns/test-false-positive-early-exit.md)
- [位置決めを外部データから取る設計で「取れなかったら既定値を仮定する」と、無言の縮退になる](./guessed-default-position-creates-silent-degradation.md)

## 追記: 「ガードに到達しない入口」を別途たどる

後続の別 PR では、欠損を露出する仕組みを作っても**その仕組みに到達しない経路**が 3 つ残っていた。いずれも「ガードの外側で件数が減る」形である — 除外フィルタが判定より前段にあって落とした行が計数にも欠損報告にも現れない、ヘッダー判定がデータ行を飲み込む、母数を作る多段パイプが無検査。**ガードを足したら「そのガードに到達しない入口が残っていないか」を別途たどる**必要がある。

同時に観測された 2 点。**除外規則の適用位置は意味を変える** — TODO/FIXME 除外を行単位の前段で行うと、コードスパン内に引用されただけの TODO でも行ごと落ちる。コードスパンのマスク（引用は主張ではない）より後に判定すると引用が救われる。前段の除外は「安い」が、後段のマスクと組み合わせたときの順序が結果を決める。そして**上流ガードと同一の regex を下流で再判定する分岐は到達不能になる** — `match()` を副作用（RSTART 設定）目的で呼ぶ場合は、rc 判定を残さず呼び出しだけにする。

## ソース

- [PR #1959 review cycle 1 (free-claim fresh corpse の silent skip 検出)](../../raw/reviews/20260721T171603Z-pr-1959.md)
- [PR #1959 fix cycle 1 (silent continue の非 corpse 限定化)](../../raw/fixes/20260721T172102Z-pr-1959.md)
- [PR #1959 fix cycle 2 (Gate 2 全 arm の可視化完遂)](../../raw/fixes/20260721T173955Z-pr-1959.md)
- [PR #2070 fix results — ガードに到達しない 3 経路](../../raw/fixes/20260731T021333Z-pr-2070.md)
