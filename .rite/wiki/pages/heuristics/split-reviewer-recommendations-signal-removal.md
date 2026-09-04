---
type: "heuristics"
title: "修正案が「一方の失敗モードを他方と交換する」形に割れたら、その機構は測るべき量を測っていない"
domain: "heuristics"
description: "レビュー指摘に対する修正案が複数出て、どれも「誤発火を減らすと見逃しが増える／見逃しを減らすと誤発火が増える」形にしかならないとき、選ぶべきなのはどの案でもない。"
created: "2026-08-01T00:21:06+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260731T135712Z-pr-2074.md"
  - type: "fixes"
    resource: "raw/fixes/20260731T060927Z-pr-2070.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-01T00:21:06+09:00" }
---

# 修正案が「一方の失敗モードを他方と交換する」形に割れたら、その機構は測るべき量を測っていない

## 概要

レビュー指摘に対する修正案が複数出て、どれも「誤発火を減らすと見逃しが増える／見逃しを減らすと誤発火が増える」形にしかならないとき、選ぶべきなのはどの案でもない。その機構が測っている量が、守りたい性質と対応していないという診断である。**推奨が割れること自体を撤去の signal として読む**。

## 詳細

起点事例では「機構の追加で塞いだ穴が、次 cycle でその機構自体の穴になる」が 3 巡続いた。cycle 1 の fail-open 修正 → その修正がサブシェルで exit していた欠陥 → cycle 2 に追加した routing 行が正常系で誤発火 → cycle 3 の集約 hard fail が[両方向に壊れる](../anti-patterns/loose-detector-predicate-promoted-to-stop-condition.md)。cycle 3 でレビュアーの推奨が 3 案に割れたことが、機構ごと削除する判断の決め手になった。削除に舵を切ってから収束が始まり、cycle 4 で HIGH / CRITICAL がゼロになっている。

そこから 2 つの運用規則が導ける。

1. **同一 PR 内で前 cycle の fix が指摘された場合、追加パッチを既定選択にしない**。Simplification-First の escalation trigger としてこの条件は実効性がある。
2. **1 句追記で済む指摘でも、hoist / 削除案を一度は評価し、退けた理由を残す**。同時期の別 PR では (a) 契約を共通セクションへ hoist して複製を一本化する案を「新構造の持ち込みと 4 箇所書き換え」を理由に、(b) 規範文自体を削除して事実記述だけ残す案を「設計意図の喪失」を理由に退け、いずれも退けた理由を commit message に明示した。

なお、撤去が正解でも**本筋の是正まで捨ててはならない**。起点事例は機構を撤去したうえで、本来必要だった設計変更（3 値モデル化）を別 Issue へ切り出している。

**適用条件**: レビュー cycle で同一機構への指摘が 2 回以上続いたとき、またはレビュアーの推奨が 3 案以上に割れたとき。

## 関連ページ

- [緩い検出述語の出力を停止条件へ昇格させてはならない](../anti-patterns/loose-detector-predicate-promoted-to-stop-condition.md)
- [強制層の機械化は裁量を消すが依存を消さない](./mechanization-moves-dependency-not-removes-it.md)

## ソース

- [fix 結果](../../raw/fixes/20260731T135712Z-pr-2074.md)
- [fix 結果](../../raw/fixes/20260731T060927Z-pr-2070.md)
