---
title: "委譲表現を含む fix は次サイクルで PARTIAL fix として再指摘される"
domain: "anti-patterns"
created: "2026-05-03T18:46:59Z"
updated: "2026-05-03T18:46:59Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260503T182831Z-pr-799-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260503T181256Z-pr-799.md"
  - type: "fixes"
    ref: "raw/fixes/20260503T181755Z-pr-799.md"
tags: ["partial-fix", "review-fix-loop", "delegation", "scope-deferral", "cycle-spanning"]
confidence: high
---

# 委譲表現を含む fix は次サイクルで PARTIAL fix として再指摘される

## 概要

cycle 1 fix で「呼び出し側責務」「caller 側で対応」「同様の修正を別 site で」のような **委譲表現 (delegation phrase)** を使うと、caller 側 / 別 site 側の実装が同 PR 内で完成しないまま「方針宣言だけ」が landed する。次サイクルで reviewer が caller 側の未完成を検出し PARTIAL fix として再指摘されるため、review-fix loop が予期せず 1 cycle 増える。fix を出す側は「reference 側を修正したから caller 側はあとで」「同じパターンの sibling site は別 Issue で」と書きたい誘惑に抗い、**caller / sibling site 両側の実装契約を同 cycle で完成させる**ことを default とする。

## 詳細

### 発生事例 (PR #799 cycle 1 → cycle 2)

PR #799 cycle 1 で reviewer が「canonical reference (`broken-ref-resolution.md`) が要求する precondition 変数 (pages_list_normalized / wiki_root) を caller (`lint.md`) で生成する Phase が無い」と CRITICAL 指摘した。fix 側は cycle 1 で:

- reference 側に「呼び出し側責務として ... を生成する」という prose を追加
- caller (lint.md) 側の Phase 7.x には実装を入れない (同 PR の scope 外と判断)

→ cycle 2 review で同 reviewer が「reference は修正されたが caller 側で precondition が未生成 → reference の bash sample が動作しない PARTIAL fix」と再指摘し、cycle 3 で caller 側の Phase 追加を実施。結果として review-fix loop が 1 cycle 余分に必要となった。

### 失敗の構造

1. **scope 圧力**: PR が膨らむのを避けたい author bias で「reference 側だけ完成、caller 側は別 PR で」と判断
2. **委譲表現の安全錯覚**: 「呼び出し側責務」「同様」と prose で書くと「将来の caller 修正で完了する」気分になり当面の fix verdict が出る
3. **review-fix loop での顕在化**: 次 cycle reviewer が caller 側の bash 実装 / Phase 番号 / 変数生成箇所を読み「reference の precondition が未満たし」と発見
4. **PARTIAL fix 認定 → +1 cycle**: 「方針は正しいが scope が足りない」として再指摘され追加 cycle が必要

### 委譲表現のシグナル語彙

以下の表現が prose / commit message / PR description / コメントに含まれる場合は要警戒:

| 表現 | risk |
|-----|------|
| 「呼び出し側責務」「caller responsibility」 | caller 側の実装契約を同 PR で書かないと未完成 |
| 「同様 (同型) の修正は別 site で」「mirror 後発」 | sibling site の修正が landed しない |
| 「将来の PR で `<flag>` 化」「v0.X.0 で本実装」 | feature flag / phase 化で永続的に未実装 |
| 「reference を整備したから caller は読めば自動的に follow」 | reference 単独では caller 行動を保証しない |
| 「TODO: 後続 cycle で対応」 (fix 内コメント) | review が高確率で再指摘 |

### 委譲を許容する例外条件

委譲が正当化されるのは以下 3 条件すべてを満たす場合:

1. **明示的な別 Issue 化**: 委譲先の作業が別 Issue として登録され番号が prose / commit に書かれている (例: 「#587 で対応」)
2. **scope 上の必然性**: 同 PR で完成させると review-fix loop が回りきらない大きさ (例: 5 sites 以上の sibling 修正)
3. **完了条件の機械化**: 委譲先 Issue の completion criteria が `grep` で確定的に検証できる形で書かれている

これらが揃わない委譲は、次 cycle で PARTIAL fix として戻ってくる確率が高い。

### canonical fix flow

委譲したくなる衝動を感じた時点で、以下 3 択のいずれかを選ぶ:

- **A. 同 cycle で完成** (推奨): caller 側 / sibling site 側を同 PR で実装する
- **B. 別 Issue + minimal PR**: 委譲先を別 Issue として登録し、後続 minimal PR (1-2 行 diff) で短時間レビューで解消する flow に乗せる ([scope 外 drift → 別 Issue 化 → 後続 minimal PR で解消する canonical flow](../patterns/canonical-reference-sample-code-strict-sync.md) 参照)
- **C. fix を出さない**: 同 PR で完成も別 Issue 化もできないなら、当該 finding は本 cycle で fix verdict を出さず reviewer に「scope 外として保留」を交渉する

### 学習

「呼び出し側責務」「同様」のような委譲表現は **prose-only design pattern** の一種で、対応する実装契約 (caller / sibling site の bash 実装、Phase 番号、変数生成箇所) が同 PR 内に存在しない場合 silent regression を起こす。**散文で宣言した設計は対応する実装契約がなければ機能しない** ([prose-design-without-backing-implementation](./prose-design-without-backing-implementation.md)) と同型の失敗モードで、cycle 境界で顕在化する sub-pattern。

## 関連ページ

- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](../patterns/canonical-reference-sample-code-strict-sync.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](./fix-comment-self-drift.md)

## ソース

- [PR #799 review (cycle 1 — reference precondition 乖離 CRITICAL 指摘)](../../raw/reviews/20260503T181256Z-pr-799.md)
- [PR #799 fix (cycle 1 — reference のみ修正、caller 側未完成)](../../raw/fixes/20260503T181755Z-pr-799.md)
- [PR #799 fix (cycle 3 — cycle 2 PARTIAL 指摘を受け caller + reference 両側完成)](../../raw/fixes/20260503T182831Z-pr-799-cycle3.md)
