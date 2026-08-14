---
title: "0 件 finding = 正常終了として受容する (false-positive 回避義務)"
domain: "heuristics"
description: "累積対策 PR の review-fix loop で reviewer が「真に finding が無いときに何か挙げないと bias と見なされる」と感じる認知傾向は、fractal pattern が完全収束した cycle で **false-positive を意図的に作る** 経路となり review-fix loop を永久化させる。"
promote: rite-plugin
created: "2026-05-26T05:00:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260526T041118Z-pr-1146.md"
  - type: "reviews"
    resource: "raw/reviews/20260526T034356Z-pr-1146.md"
  - type: "reviews"
    resource: "raw/reviews/20260722T080039Z-pr-1969-mergeable.md"
tags: ["reviewer-discipline", "false-positive-prevention", "fractal-pattern-convergence", "doc-heavy-review", "loop-termination"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-22T08:20:00+00:00" }
---

# 0 件 finding = 正常終了として受容する (false-positive 回避義務)

## 概要

累積対策 PR の review-fix loop で reviewer が「真に finding が無いときに何か挙げないと bias と見なされる」と感じる認知傾向は、fractal pattern が完全収束した cycle で **false-positive を意図的に作る** 経路となり review-fix loop を永久化させる。`0 件 = 正常終了` を恐れない姿勢を canonical 化することで、収束相での無理な finding 捏造を抑制する。

## 詳細

### 観察された事象（cycle 6 → cycle 8）

累積 44 回目相当 (Doc-Heavy PR の 8 cycle 収束) で reviewer が明示した文言:

> 「fractal pattern が ほぼ収束、次 cycle で完全 0 件到達が現実的に視野」 (cycle 6 表現)
> 「真に finding がないときに何か挙げないと bias」を抑制し、0 件 = 正常終了を恐れない姿勢が loop 永久化を回避 (cycle 8 確認)

cycle 1-7 で累計 11 件の指摘を順次対応 (cycle 2: 4 件 → cycle 3: 2 件 → cycle 5: 7 件 → cycle 7: 1 件) し、cycle 8 で **両 reviewer (tech-writer + code-quality) とも finding 0 件**、Doc-Heavy mode 5 カテゴリ verification protocol で全 PASS、code-quality 機械検証で全 9 項目 + 未検証領域 sweep で 0 件確認。この時点で fractal pattern (累積対策 PR で fix 自体が drift を導入するパターン) が完全収束したと判定される。

### false-positive 捏造の認知バイアス源

- **「reviewer は何か挙げるべき」前提**: review という作業に対する「何かを言わなければ仕事をしていない」という認知バイアス
- **直前 cycle で findings があった**: cycle N-1 で finding 検出した reviewer は cycle N でも同 depth の検出を期待し、無理に nit-level 指摘を生成する経路
- **「自分が見落としている可能性」防衛**: 0 件と宣言することへの心理的抵抗 (後で別 reviewer が finding を出したら自分の判断が問われる)

### canonical 対策

| 規範 | 適用タイミング |
|------|--------------|
| **明示的な収束宣言**: cycle N-1 で「次 cycle で完全 0 件到達が現実的に視野」と reviewer が明言した場合、cycle N で 0 件を出すこと自体に正当性がある | 累積対策 PR の収束相 (cycle 5+) |
| **healthy self-assessment の明示**: 「全 5 カテゴリ verification を実行した結果 0 件」と明示し、scan の網羅性と finding の絶対数を分離して報告 | 全 cycle |
| **未検証領域 sweep の追加 step**: 0 件宣言前に「cycle 1-N で touch されていない領域」を最後に sweep し、その結果も合わせて報告 | 0 件宣言 cycle |
| **複数 reviewer 独立 0 件は強い convergence signal**: 2+ reviewer 独立に 0 件かつ全 5 カテゴリ verification PASS が揃えば mergeable 判定 | 累積対策 PR の最終 cycle |

### 拒否される false-positive パターン

以下は意図的に「挙げない」ことが canonical:

- **既に nit-noted に降格された LOW × current-pr の再蒸し返し** (`auto_demote_low: true` 設定下)
- **fingerprint suppression 対象の指摘の再生成**
- **「念のため」「将来 risk」のみを根拠とする hypothetical finding** (cf. [`observed-likelihood-gate-with-evidence-anchors.md`](./observed-likelihood-gate-with-evidence-anchors.md))
- **同 finding の rewording で見かけ上の件数を作る** (1 finding を 2 表現で書き直す)

### 累積対策 PR の理想的収束パターン

各 cycle で異なる箇所が detect される fractal pattern (cycle 2-6) が、系統的修正 (cycle 5 の line ref 統一・行数実値化・セクション補完一括対応) + 末端 nit (cycle 7 commit date) を経て cycle 7-8 で完全収束する軌跡が canonical:

```
cycle 1: 5 findings (HIGH×1 + MEDIUM×1 + LOW×3 auto-demoted)
cycle 2: 4 findings (cycle 1 fix-introduced regression)
cycle 3: 2 findings
cycle 5: 7 findings (systemic 化対応)
cycle 7: 1 finding (末端 nit)
cycle 8: 0 findings (完全収束、mergeable)
```

同型 issue を ad-hoc 修正ではなく systemic 化して一斉対応するアプローチが収束を加速する。

## 関連ページ

- [累積対策 PR の review-fix loop で fix 自体が drift を導入する](../anti-patterns/fix-induced-drift-in-cumulative-defense.md)
- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](./observed-likelihood-gate-with-evidence-anchors.md)
- [Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない](./respect-reviewer-no-action-recommendation.md)
- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)

## ソース

- [PR #1146 cycle 8 review (8 cycle 完全収束 / mergeable / false-positive 回避義務)](../../raw/reviews/20260526T041118Z-pr-1146.md)
- [PR #1146 cycle 6 review (収束相の visibility)](../../raw/reviews/20260526T034356Z-pr-1146.md)
- [PR #1969 cycle 6/mergeable review (5 reviewer 全員「評価: 可」、指摘 0 件で 5-cycle 収束、cycle 5 finding の正しい解消を確認した上での 0 件到達)](../../raw/reviews/20260722T080039Z-pr-1969-mergeable.md)
