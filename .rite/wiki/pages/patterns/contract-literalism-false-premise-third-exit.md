---
type: "patterns"
title: "契約が誤った前提の上に書かれていたときは dispatch を契約どおり保ち、前提の訂正と未決判断を別チャネルへ出す"
domain: "patterns"
description: "Issue の契約が事実誤認の上に建っていると分かったとき、実装を「正しい方」へ勝手に寄せるのでも黙って契約に従うのでもない第三の出口がある: dispatch は契約どおりに保ち、誤った前提は Decision Log に訂正として記録し、未決の設計判断は WARNING で可視化して判断待ちにする。"
promote: rite-plugin
created: "2026-08-31T14:09:34Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-31T14:09:34Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260831T072532Z-pr-2494.md"
  - type: "reviews"
    resource: "raw/reviews/20260831T071720Z-pr-2494.md"
tags: ["contract-literalism", "decision-log", "fail-loud", "spec-premise", "agent-protocol"]
confidence: medium
---

# 契約が誤った前提の上に書かれていたときは dispatch を契約どおり保ち、前提の訂正と未決判断を別チャネルへ出す

## 概要

Issue の契約が事実誤認の上に建っていると分かったとき、選択肢は「契約を無視して正しいと思う実装にする」と「黙って契約に従う」の 2 つだけに見える。どちらも情報を失う。第三の出口がある: **dispatch は契約どおりに保ち、誤った前提は Decision Log に訂正として記録し、未決の設計判断は WARNING で可視化して判断待ちにする**。

## 詳細

起点事例では、Issue が「外部 API の enum は 2 値」という誤った前提の上に dispatch 表を定義していた。実際には 4 値あり、うち 1 つは表のどの行にも該当しなかった。ここで取れる出口は 3 つある:

| 出口 | 何を失うか |
|------|-----------|
| 実装を「正しい方」へ寄せる | 契約の権威が消える。次の読者は仕様と実装のどちらを信じるか判断できない。未決の設計判断を実装者が独断で決めたことも記録に残らない |
| 黙って契約に従う | 誤った前提が生き残り、次の変更も同じ前提の上に積まれる。該当しない値が沈黙で誤配される |
| **第三の出口** | 何も失わない — 契約の権威は保たれ、前提の誤りは訂正として残り、未決は未決として見える |

### 第三の出口の構成要素

1. **dispatch は契約どおりに保つ**: 仕様が書いた分岐は書いたとおりに実装する。実装者の判断で宛先を変えない
2. **誤った前提は Decision Log へ訂正として記録する**: 「Issue の §X が主張する前提は事実と異なる」を、その根拠（実測した値域など）とともに残す。Issue 本文を書き換えるのではなく、決定の履歴として追記する
3. **未決の設計判断は WARNING で可視化する**: 契約が宛先を決めていない値は、catch-all で黙って流さず「この値には mapped な宛先が無い」と名指しで警告する。**未決を沈黙で埋めると、次の読者には決定済みに見える**
4. **未決の判断は後続 Issue として切り出す**: 判断そのものは本 PR のスコープ外。切り出しておけば、判断が要るという事実が消えない

### 適用の見分け

この出口が要るのは「契約が**事実誤認**の上にある」場合に限る。契約が事実として正しく、単に実装者の好みと違うだけなら契約に従う（Contract Literalism）。逆に前提の誤りが契約の目的そのものを無効化するなら、実装せずに仕様の見直しへ差し戻す。第三の出口は**前提は間違っているが契約の目的は依然として有効**という中間帯のためにある。

### 未決を沈黙で埋めない

3 の系として: 隣接する分岐が WARNING を出しているのに 1 つの枝だけ無言、という**沈黙の非対称**は「その枝は考えて無言にしたのか、考えていないのか」を読者に区別させない。未決なら未決と書く（[prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する](../anti-patterns/catch-all-case-arm-absorbs-future-prefix.md)）。

## 関連ページ

- [外部 API の enum を散文へ写す前に値域を introspection で実測する](../heuristics/external-api-enum-domain-introspect-before-prose.md)
- [prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する](../anti-patterns/catch-all-case-arm-absorbs-future-prefix.md)

## ソース

- [PR #2494 fix results — contract literalism と仕様の前提崩壊の切り分け](../../raw/fixes/20260831T072532Z-pr-2494.md)
- [PR #2494 review results — 前提の誤りを 5 reviewer が独立に検出](../../raw/reviews/20260831T071720Z-pr-2494.md)
