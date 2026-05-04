---
title: "Sub-Issue series で AC 緩和が発生したら設計 doc 側にも back-propagation する"
domain: "heuristics"
created: "2026-05-04T11:20:00Z"
updated: "2026-05-04T11:20:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260504T105615Z-pr-813.md"
  - type: "fixes"
    ref: "raw/fixes/20260504T110207Z-pr-813-cycle2.md"
tags: ["design-doc", "ac-relaxation", "back-propagation", "umbrella-issue", "sub-issue-series"]
confidence: high
---

# Sub-Issue series で AC 緩和が発生したら設計 doc 側にも back-propagation する

## 概要

Umbrella Issue 配下の Sub-Issue series で各 PR の AC (例: 行数目標) が user 承認のもと段階的に緩和された場合、Umbrella 起点の設計ドキュメント (`docs/designs/...`) の goal-setting 記述にも back-propagation する運用が必要。最初の Sub-Issue で AC 緩和が landed した瞬間に design doc 側を更新しないと、後続 Sub-Issue が「設計 doc の当初目標」と「直前 PR の実着地」のどちらを参照すべきか曖昧になり、reviewer が「目標未達」として誤検出する経路を生む。

## 詳細

### 観測

- **PR #809 (累積 1 回目)**: Umbrella #804 配下、`create-interview.md` 511 → 目標 ≤200 行を user 承認のもと ≤350 に緩和、331 行で着地 (-35%)。設計 doc `docs/designs/refactor-create-mds-body-slimdown.md` 側の goal-setting (≤200/≤300/≤300) は未更新のまま
- **PR #813 (累積 2 回目)**: 同 Umbrella 配下、`create-decompose.md` 661 → 目標 ≤300 行を ≤500 → ≤510 に段階的緩和、506 行で着地 (-23%)。**直前 PR で同パターンが起きたにもかかわらず design doc が未更新で再発**。3 reviewer のうち 1 人が「設計 doc の goal-setting と実着地の乖離」を MEDIUM finding として独立検出

### Why

- Umbrella 設計 doc の goal-setting は **Sub-Issue 着工前の理想値**であり、protected 区域 (NFR-2 等) と SPEC-OUT-OF-SCOPE 制約 (新規 references 作成禁止 / references 側 modify 禁止) の組み合わせで構造的に達成困難なケースが多い ([圧縮 refactor の AC は protected 区域 + scope 制約から逆算して決める](compression-refactor-ac-vs-structural-constraint.md) 参照)
- 各 Sub-Issue 着工時に grep evidence で逆算 → user 承認 → AC 緩和 という運用が確立しているが、**緩和結果が Umbrella 設計 doc 側に shed されない** と、次 Sub-Issue の reviewer / 着工者が「当初目標」を引きずって作業する silent regression が発生する
- 関連: [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の系列 — 「fix を 1 箇所に適用したとき同パターンを持つ対称位置に伝播させ忘れる」failure mode の運用層拡張。fix 対象が「コード bash literal」ではなく「メタ contract レイヤー (FR ⇔ Risks ⇔ P-id 採番表 ⇔ design doc goal)」に拡張された PR #792 累積 18 回目と同型構造

### Canonical 対策

**Sub-Issue series PR の最初の AC 緩和着地時 checklist** (Sub-Issue 1 つ目で発生したら必ず実施):

1. **Umbrella Issue body**: 「Sub-Issues」テーブルの「complexity」列 / 「目標行数」列を実着地値に更新する
2. **Design doc** (`docs/designs/<topic>.md`): 「目標行数」「ゴール」セクションを実着地値 + AC 緩和の経緯 (protected 区域比率 / scope 制約 / 兄弟 PR 達成率を転用できない理由) に更新する
3. **後続 Sub-Issue body**: 同 series の次の Sub-Issue body にも「PR #N (1 つ目) で AC を ≤X に緩和、本 Sub-Issue も同方針で着工」を明記する

**最も効果的なタイミング**: 1 つ目の Sub-Issue PR の cycle 1 fix で AC 緩和が確定した直後。merge 後の次 Sub-Issue 着工までに back-propagation を完了させると、reviewer が「目標未達」として再検出するコストが消滅する (PR #813 では merge 直前まで未更新で reviewer 1 人が MEDIUM 検出した実測)。

### 検出 heuristic

新規 Sub-Issue PR の着工時に reviewer が以下を grep verify する:

```bash
# 直近 Sub-Issue (兄弟 PR) で AC 緩和が起きていないか確認
git log --oneline --grep="AC.*緩和" --grep="緩和.*着地" -i origin/develop | head -10

# 設計 doc の goal-setting が直近 PR と整合しているか確認
grep -nE "目標.*[0-9]+.*行|≤[0-9]+" docs/designs/<topic>.md
```

設計 doc 側に「(PR #X で ≤Y に緩和)」のような追記が直近 PR の merged date 以降に存在するかで back-propagation の有無を機械検証できる。

## 関連ページ

- [圧縮 refactor の AC は protected 区域 + scope 制約から逆算して決める](compression-refactor-ac-vs-structural-constraint.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [PR シリーズ間で stub 残置 markdown formatting を踏襲する](../patterns/pr-series-stub-format-consistency.md)

## ソース

- [PR #813 review results (3 reviewer 一致 — design doc goal-setting stale, MEDIUM)](raw/reviews/20260504T105615Z-pr-813.md)
- [PR #813 fix cycle 2 (AC 段階的緩和 ≤300 → ≤500 → ≤510 の累積実測、design doc 側 back-propagation を canonical 対策として確立)](raw/fixes/20260504T110207Z-pr-813-cycle2.md)
