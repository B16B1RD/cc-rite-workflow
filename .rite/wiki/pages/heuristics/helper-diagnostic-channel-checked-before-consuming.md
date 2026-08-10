---
type: "heuristics"
title: "helper を新しく消費するコードは、診断がどのチャネルに載るかを先に確認して既存消費者と同じ転記をする"
domain: "heuristics"
promote: rite-plugin
description: "helper が失敗理由を stdout の構造化戻り値にだけ載せ自身の stderr へは何も書かない場合、呼び出し側が成否フィールドだけを読むと失敗理由が全出力から消え、既に書いてある stderr 診断分岐が到達不能な死枝になる。"
created: "2026-08-10T05:20:00+09:00"
updated: "2026-08-10T05:20:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260810T035844Z-pr-2227.md"
  - type: "fixes"
    ref: "raw/fixes/20260810T040721Z-pr-2227.md"
tags: []
confidence: high
---

# helper を新しく消費するコードは、診断がどのチャネルに載るかを先に確認して既存消費者と同じ転記をする

## 概要

helper が失敗理由を stdout の構造化戻り値にだけ載せ自身の stderr へは何も書かない場合、呼び出し側が成否フィールドだけを読むと失敗理由が全出力から消え、既に書いてある stderr 診断分岐が到達不能な死枝になる。helper を新しく消費するコードを書くときは、その helper が診断をどのチャネルに載せるかを実装で先に確認し、既存の消費者と同じ転記をする。

## 詳細

### 事象

`projects-status-update.sh` は non_blocking の handled failure を stdout の JSON で返し、失敗理由を `.warnings[]` にのみ載せる。自身の stderr へは何も書かない。ある呼び出し側は戻り値の `.result` だけを読んで分岐しており、`.warnings[]` を読んでいなかった。

結果、その呼び出し側の failure 分岐には手動対処コマンドを案内する stderr 出力が既に書かれていたにもかかわらず、**失敗理由そのものはどこにも出なかった**。分岐は到達するが、分岐が伝えるべき情報を持っていない。診断分岐が「あるのに機能しない」状態で、コードを読むだけでは欠落に見えない。

同 helper の他の消費者 4 箇所はすべて `.warnings[]` を stderr へ転記していた。逸脱していたのは 1 箇所だけで、非対称は消費者を新しく足した側に生じていた。

### なぜ「先に確認する」が効くか

診断チャネルの設計は helper ごとに違う。

- 自身の stderr に書く helper（呼び出し側は何もしなくても診断が出る）
- stdout の構造化戻り値にだけ載せる helper（呼び出し側が転記しないと診断が消える）
- 両方に出す helper（呼び出し側が転記すると二重に出る）

呼び出し側のコードを書くときに前提にできる既定値は存在しない。にもかかわらず「失敗したら stderr に何か出るだろう」という暗黙の前提でコードを書くと、2 番目の helper に対してだけ静かに壊れる。壊れ方が「診断分岐は書いてあるが中身が空」なので、コードレビューでも実行時のパス通過でも気づきにくい。

確認の順序は次の 2 つで足りる。

1. helper の実装を読み、handled failure のときに何をどのチャネルへ出すかを見る
2. 同じ helper の既存消費者を 1 つ読み、その転記を写す

2 が特に効く。既存消費者が複数あるなら、それらは helper の契約に対する動く仕様であり、新規消費者だけが違う読み方をしているなら非対称は新規側にある。

### 関連する失敗形

同じ helper の戻り値を巡っては、`status_json=$(bash script.sh) || status_json=""` の形で **helper が既に stdout へ出した診断 JSON を空文字列で上書きして破棄する**失敗も観測されている。こちらは「読まない」ではなく「読んだものを捨てる」形だが、結果は同じで失敗理由が全出力から消える。戻り値の一部にしか診断が載らない helper は、消費側の小さな書き方の差で診断がゼロになる。

## 関連ページ

- [`cmd=$(...) || cmd=""` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする](../anti-patterns/command-substitution-fallback-discards-diagnostic-json.md)
- [新規 lint helper は findings→stdout / summary→stderr(log()) の出力チャネル規約を兄弟 helper に揃える](../patterns/lint-helper-output-channel-convention.md)
- [共有リソースの type/名前空間を再利用する新機能は、既存消費者のコード内契約（コメント明示の不変条件）を見落として生存中のリソースを破壊しうる](../anti-patterns/shared-resource-type-reuse-without-consumer-contract-check.md)

## ソース

- [PR #2227 review results](../../raw/reviews/20260810T035844Z-pr-2227.md)
- [PR #2227 fix results](../../raw/fixes/20260810T040721Z-pr-2227.md)
