---
type: "patterns"
title: "「N 種を禁止し行き先を示す」規則は禁止列挙と行き先を 1 つの対リストに畳む"
domain: "patterns"
promote: rite-plugin
description: "禁止する種別の列挙と、それぞれの行き先を別ブロックに書くと、両者は独立に編集できるため件数がずれる。対にして 1 箇所に書けば、片方だけ増える編集が構文的にできなくなる。"
created: "2026-08-02T11:59:42+09:00"
updated: "2026-08-02T11:59:42+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260802T014423Z-pr-2084.md"
  - type: "fixes"
    ref: "raw/fixes/20260802T014756Z-pr-2084.md"
tags: [documentation, enumeration-sync, structural-invariant]
confidence: high
---

# 「N 種を禁止し行き先を示す」規則は禁止列挙と行き先を 1 つの対リストに畳む

## 概要

「A・B・C をここに書くな。それぞれの行き先は X・Y だ」という形の規則を散文で書くとき、禁止側の列挙と行き先側の列挙を別の bullet / 段落に分けると、両者は独立に編集できるため件数がずれる。禁止 3 種に対し行き先 2 種、という非対称が初回コミットの時点で成立しうる。禁止と行き先を対にして 1 つのリストに畳めば、片方だけ増える編集が構文的にできなくなる。

## 詳細

### 発生事例（Issue テンプレートへの規則追加、cycle 1）

Issue テンプレート Section 9 に「Decision Log に載せないもの」の規則を追加した際、次の 2 bullet に分けて書いた:

- 禁止列挙: `Do NOT record work items, planned tests, or review-response notes` (3 種)
- 行き先: `Route them instead of dropping them: a test need → Section 6 の T-xx 行; the reason behind a fix → commit body` (2 種)

`Route them instead of dropping them` と宣言しながら `work items` の行き先が無い。両 reviewer が独立に同じ箇所を検出した。加えて禁止リスト第 3 要素の呼称が 3 箇所で 2 通り（`fix rationale` / `review-response notes` / `the reason behind a fix`）に割れており、**同じ規則を書いた 1 回のコミット内で既に不整合が成立していた**。

### なぜ分離すると必ずずれるか

禁止列挙と行き先列挙は「同じ集合を 2 回書く」構造になる。2 箇所に書かれた集合は、片方だけを編集する操作が常に文法的に valid なため、同期は書き手の注意だけが担保する。レビューサイクルで規則を足す・削る編集が入るたびにドリフト機会が発生し、しかも「宣言（全部ルーティングする）」と「実体（一部だけ）」の食い違いは読み手が両方を数え合わせないと見つからない。

### 対処

禁止と行き先を **1 つの対リスト** に畳む。各エントリが「禁止するもの → その行き先」の対を持てば、エントリを足すときに行き先を書かないという操作自体が不自然になり、件数のずれが構造的に起こり得なくなる:

```markdown
Do not record the work itself. Each kind has its own medium, so route rather than drop:
  - an open work item you have taken on → the work memory's plan-deviation log
  - a planned test → a new `T-xx` row in Section 6
  - a fix rationale, a review response included → the commit body
```

bullet 数はむしろ減る（分離時 2 bullet + 曖昧さ → 統合後 1 bullet + ネスト 3 行）。長大化する場合はネスト sub-bullet に組み替えれば、対の構造を保ったまま各行を短く保てる。

### 適用条件と例外

- 対象は「禁止する種別」と「その行き先」が 1:1 対応する規則。行き先が状況依存で 1:N になる場合は対リストに畳めないため、代わりに各行き先側に「どの種別を受けるか」を書いて逆向きの単一 SoT にする
- 呼称は対リスト内で 1 語に固定する。同一 bullet 内で `work items` → `a work item found during implementation` のように言い換えると、集合の同一性が読み手に伝わらない

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [state machine を 2 箇所で記述する場合は動作の文字列レベルで同期する](./state-machine-dual-location-sync.md)

## ソース

- [PR #2084 review results](../../raw/reviews/20260802T014423Z-pr-2084.md)
- [PR #2084 fix results](../../raw/fixes/20260802T014756Z-pr-2084.md)
