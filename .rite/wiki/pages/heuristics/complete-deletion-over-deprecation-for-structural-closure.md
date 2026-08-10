---
title: "Legacy field の「deprecate + 残置」よりも「完全削除」が構造的閉塞を実現する"
domain: "heuristics"
description: "Refactor で命名衝突 / semantic 混在を解消する際に「legacy field を deprecate ラベル付きで残置」する戦略は、definition の二重化が解消されないため [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) を review-fix loop 内で再生産する。"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/heuristics/complete-deletion-over-deprecation-for-structural-closure.md"
created: "2026-05-18T09:00:00Z"
updated: "2026-05-18T09:00:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260518T084056Z-pr-1043-cycle4-mergeable.md"
  - type: "reviews"
    ref: "raw/reviews/20260518T075850Z-pr-1043.md"
tags: []
confidence: high
---

# Legacy field の「deprecate + 残置」よりも「完全削除」が構造的閉塞を実現する

## 概要

Refactor で命名衝突 / semantic 混在を解消する際に「legacy field を deprecate ラベル付きで残置」する戦略は、definition の二重化が解消されないため [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) を review-fix loop 内で再生産する。逆に「legacy field を完全削除 + disambiguation note も同時に簡素化」する構造的戦略は、対称化責務そのものを消滅させ収束を実現する。cycle 1-4 で実測 — cycle 1-3 で「deprecate + 残置」を採用したことで textual contradiction が連続 3 回再発し、cycle 4 で「完全削除」に転換した瞬間に 0 findings へ収束した。

## 詳細

### 事象 — 累積 35 回目相当の cycle 1-4 の収束軌跡 (CRITICAL+HIGH のみ)

```
cycle 1 (7) → cycle 2 (3) → cycle 3 (2) → cycle 4 (0 = mergeable)
```

全 findings 集計では `18 → 14 → 4 → 0` の shrinking-cycle pattern を示すが、CRITICAL+HIGH 級だけで見ると cycle 1-3 では「同型 anti-pattern が同章内で複数箇所違反」する self-violation cascade が連続再発した。cycle 4 で legacy field 自体の完全削除に転換し、即座に 0 findings に収束。

### 戦略の対比

| 戦略 | 動作 | 結果 |
|------|------|------|
| **A: deprecate + 残置** | Legacy field (例: `recommendation_issue_candidates`) を `deprecated, do not use` コメント付きで温存し、新 field (例: `candidate_count`) を導入する | Definition が二重化されたまま残り、reviewer が「両 field の semantic 関係が不明確」「片方の sentinel emit が legacy 経由 / 片方が新規経由」など textual contradiction を毎 cycle 再検出。fix 自身が同型の対称化漏れを生む再帰的 anti-pattern (=[Recursive Recurrence in Fix Layer](../anti-patterns/asymmetric-fix-transcription.md)) を引き起こす |
| **B: 完全削除 + note 簡素化** | Legacy field を removed-in-this-PR として完全削除し、関連する disambiguation note (「legacy と新の混同を避けよ」等) も同時に簡素化する | 対称化対象そのものが消滅するため [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の発火条件 (= 同形 idiom の複数箇所共存) を構造的に閉塞。reviewer が検出できる drift の絶対数が物理的に減少 |

### 選択基準 — 「deprecate + 残置」を採用してよいケース

- 外部 caller (別 plugin / 外部リポジトリ) が legacy field に依存しており、breaking change を回避する必要がある場合
- Migration window を設けて段階的に caller を更新する公開 API の場合

それ以外の internal refactor では **B (完全削除) を first choice にすべき**。「とりあえず残しておこう」「将来の参照のため」といった justification は cycle 数を膨張させる主要因。

### Why — Recursive Recurrence in Fix Layer との関係

[`Recursive Recurrence in Fix Layer`](../anti-patterns/asymmetric-fix-transcription.md) は「fix のために導入した anchor literal / convention 自身が次 cycle の新規 drift 源になる」failure mode。本 heuristic は、その fix-induced drift の **構造的閉塞戦略** として機能する: deprecate ラベルや disambiguation note は「人間 (LLM) に注意を要求する mitigation」だが、完全削除は「対称化対象を消滅させる structural mitigation」である。後者は LLM の attention budget に依存しないため、累積対策 PR で **fix-induced drift cascade を断ち切る canonical strategy** となる。

### Dogfooding evidence — Mechanical gate の必要性

累積 35 回目相当は「`/rite:pr:review` Phase 7 の AskUserQuestion 起動を機械的 gate 化する」meta-PR でもあった。cycle 1-3 で「deprecate + 残置」戦略により self-violation cascade を 3 回連続で踏んだ実測は、本 PR が導入する mechanical gate の前提仮定 ("prose enforcement only では silent skip が必ず発生する") を逆説的に裏付ける dogfooding 観察となった。**累積対策 PR が解決対象の anti-pattern を fix 自身で再現する経験は、その mechanical gate の必要性の最も強い証拠**。

### Detection Heuristic

| Signal | 解釈 |
|--------|------|
| Cycle 1 で「両 field の semantic 関係を明示する disambiguation note」追加 fix が出た | Strategy A 採用の予兆 — cycle 2-3 で同型違反の再発を予測すべき |
| Cycle N で reviewer が「legacy / 新 の混在経路」を complete deletion 候補として提案した | Strategy B への転換が必要 — 残置戦略を継続すると cycle 数が膨張する |
| Cycle 3+ で CRITICAL/HIGH の同型 finding が再発し続ける | Strategy A の限界点 — 即座に B に切り替える decision を下す |

### Mitigation — 契約として明示化する

- Refactor PR で deprecate label を導入する際は、**移行計画 (deletion target cycle / deletion PR Issue 番号)** を本文に明記する
- Cycle 3 で legacy 関連 finding が同型再発した場合、cycle 4 では `deprecate → delete` への戦略転換を AskUserQuestion で提案する
- 完全削除戦略採用時は、関連する disambiguation note / migration guide も同 PR で同時に削除する (「note だけ残す」は asymmetric fix transcription そのもの)

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [Aggregate Recommendation Label による action 要求の silent skip](../anti-patterns/aggregate-recommendation-label-evasion.md)

## ソース

- [PR #1043 cycle 4 mergeable + 4 cycle dogfooding lessons](../../raw/reviews/20260518T084056Z-pr-1043-cycle4-mergeable.md)
- [PR #1043 cycle 1 review (self-referential failure mode 起点)](../../raw/reviews/20260518T075850Z-pr-1043.md)
