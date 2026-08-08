---
type: "anti-patterns"
title: "安全側へ倒れる fail-safe は、倒れた事実が観測されない限り機能の恒久的不作動を隠す"
domain: "anti-patterns"
description: "fail-safe が「フル装備側」へ倒れる設計は、縮退しても実行時エラーが出ず CI も緑のままなので、機能が一度も発動していないことを示す信号がどこにも残らない。PR #2142 では GNU 拡張の sed 式が BSD で無警告に不一致となり、reason は complexity_absent（= 起票者の不備）を表示し続けた。fail-safe は「倒れた事実が観測値として記録されるか」と「reason が原因を正しく帰属するか」を同時に設計しないと、安全側の縮退が恒久的な不作動になる。"
created: "2026-08-08T14:00:41+09:00"
updated: "2026-08-08T14:00:41+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260807T235335Z-pr-2142.md"
  - type: "fixes"
    ref: "raw/fixes/20260808T001157Z-pr-2142.md"
tags: ["fail-safe", "silent-failure", "observability", "portability", "diagnostics"]
confidence: high
---

# 安全側へ倒れる fail-safe は、倒れた事実が観測されない限り機能の恒久的不作動を隠す

## 概要

「情報が欠ければ従来のフル装備へ倒す」型の fail-safe は、倒れた向きが安全側であるがゆえに**壊れていることを誰にも伝えない**。実行時エラーが出ず、出力も従来どおりで、CI も緑のまま通る。結果として、新機能が一度も発動しないまま「実装済み」として扱われる。

PR #2142 では XS/S 軽量レーンの判定 helper が `sed` の GNU 拡張（`\b` 単語境界）に依存しており、BSD/macOS では無警告で不一致になった。倒れた先は `full`（フル装備 = 安全側）で、CI の macOS leg は `continue-on-error`、reason 表示は `complexity_absent` だった。**この 3 つが揃うと「機能が動いていない」ことを示す信号がゼロになる**。

## 詳細

### 恒久的不作動を隠す 3 条件

1. **倒れた向きが安全側**: 従来挙動へ戻るだけなので、出力の差分から異常を推定できない
2. **失敗が例外にならない**: 正規表現の不一致は「該当なし」であってエラーではない。ツールの exit code も 0
3. **reason が原因を誤帰属する**: 「値が読めなかった」と「値が書かれていなかった」を同じ reason に潰すと、環境起因の失敗が **Issue 起票者の不備**として表示される

3 番目が最も厄介で、診断そのものが調査を誤った方向へ誘導する。運用者は起票テンプレートの記入漏れを探し続け、実装の移植性欠陥にはたどり着かない。

### 設計時に併せて決めること

- **倒れた事実が観測値として残るか**: reason ごとの発火件数が記録されれば、`complexity_absent` が母集団の 100% を占める異常として現れる。fail-safe の marker は「静かに正しく動いた」ことの証明ではなく、**効果計測の分母**として設計する
- **reason が原因を正しく帰属するか**: 少なくとも「情報が本当に無い」と「あるが解釈できない」を別の診断行に分ける。後者だけが対象を名指しできる
- **CI が当該経路を実際に通るか**: `continue-on-error` の leg でしか再現しない欠陥は、CI が緑であることを根拠にしてはならない

### 「WARNING を loud にする」根拠は実測してから置く

本 PR では全 reason に WARNING を出す根拠として「この値は rite が作る全 Issue に必ずある」と書いたが、実測すると 60 件中 23 件（38%）が持たなかった。前提が偽だと WARNING が定常出力になり、actionable なケースが noise に埋もれる。loud を維持するなら、根拠は「必ずある」ではなく**実測可能な別の理由**（倒れた事実が効果計測の分母になる、など）に置き換える。

## 関連ページ

- [resolver / helper 失敗時の silent fallback は debug log で観測性を確保する](../patterns/silent-fallback-observability-via-debug-log.md)
- [抽出述語の厳格化は「壊れた入力」と「入力なし」を同一経路へ畳み、fail-loud を構造的に壊す](./strict-predicate-collapses-broken-into-absent.md)
- [観測母集団を確認してから仕様上の前提へ昇格する](../heuristics/observed-population-check-before-promoting-to-spec-premise.md)

## ソース

- [PR #2142 review results](../../raw/reviews/20260807T235335Z-pr-2142.md)
- [PR #2142 fix results](../../raw/fixes/20260808T001157Z-pr-2142.md)
