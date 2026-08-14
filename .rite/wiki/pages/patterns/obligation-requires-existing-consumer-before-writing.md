---
type: "patterns"
title: "記録義務を規約に書く前に、その記録先を読む consumer が実在するかを grep で確かめる"
domain: "patterns"
description: "「条件 X に当たる指摘は filter する。"
created: "2026-08-03T00:55:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260802T141413Z-pr-2092.md"
  - type: "fixes"
    resource: "raw/fixes/20260802T141842Z-pr-2092.md"
  - type: "reviews"
    resource: "raw/reviews/20260802T145006Z-pr-2092.md"
  - type: "fixes"
    resource: "raw/fixes/20260802T145247Z-pr-2092.md"
  - type: "reviews"
    resource: "raw/reviews/20260802T150522Z-pr-2092.md"
tags: ["producer-consumer", "obligation-design", "compensating-control", "prompt-engineering"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-03T00:55:00+09:00" }
---

# 記録義務を規約に書く前に、その記録先を読む consumer が実在するかを grep で確かめる

## 概要

「条件 X に当たる指摘は filter する。ただし記録は残す」という設計は、**記録先に consumer がいて初めて成立する**。起点事例では reviewer 契約に「実測付きでも filter してよい」抑止経路を新設し、その唯一の補償制御として既存の `監査ログ` 節への記録を課したが、その節を読む consumer がプラグイン内に 1 つも存在しなかった（`grep -rn 監査ログ` が出力テンプレート・収集ステップ・schema のいずれにも 0 hit）。

義務を書いても記録は破棄され、しかも**義務違反すら検出されない**。兄弟セクションはいずれも「出力テンプレートに欄がある + 収集される + 空のときの扱いが定義済み」の 3 点を満たしていたが、当該節だけがすべてを欠いていた。

## 詳細

**なぜ規約を読むだけでは気づけないか**

- 義務側（「記録せよ」）を読んでも、記録先が読まれるかはわからない
- 記録先の定義（「reviewer は `監査ログ` 節に列挙してよい」）を読んでも、そこに義務が向いているかはわからない
- 両者は同じファイル内にあっても数十行離れており、突き合わせは人間の照合作業になる

判明したのは `grep -rn <記録先> <consumer が居るはずのディレクトリ群>` という **1 コマンドの実測**によってのみだった。

**確認すべき 3 点（兄弟セクションが満たしている契約）**

1. 出力テンプレートに欄があるか（reviewer/agent が実際に受け取る prompt に節が定義されているか）
2. 収集ステップが読むか（orchestrator が結果を統合する際に当該節を parse するか）
3. 空のときの扱いが定義されているか（「該当なしの場合はセクション自体を省略する」等）

3 点すべてを欠く節へ MUST を課すと、履行が観測不能な義務になる。post-condition 検出（`grep -qE '^### <節名>'` 等）を持つ節だけが silent non-compliance を検出できる。

**既存セクションへの迂回が機能するかは出力経路まで辿る**

「新機構を足さず、既に収集される別セクションへ差し替える」案は一見合理的だが、**「収集される」と「人間に届く」は別**である。起点事例では代替案として挙がった `推奨事項` 節が、E2E 出力最小化で省略され、`design_confirmation` 分類は triage の候補抽出からも除外されるため、既定構成では人間に到達しないことが判明した。省略禁止の carve-out を明示的に持つ節だけが後者を満たす。

**受け皿を新設できない場合の着地**

受け皿の新設が Issue の MUST NOT（新機構の追加）に抵触する場合、義務を書くのではなく**義務ごと撤回**し、未達となった受入基準を follow-up Issue へ切り出す。その Issue には「この PR の merge がどういう窓を開けるか」（先行して filter だけが有効になる期間、その間に失われる記録の性質）まで書く。Issue を立てるだけでは「対応した」ことにならない。

**関連する自己抵触**

consumer のない記録先を義務化することは、「実需の Issue がない構造は追加しない」型の原則そのものへの違反にあたる。新しい原則を導入する PR では、その原則で自分の diff を 1 度レビューすると同時に検出できる。

## 関連ページ

- [新設した出力フィールドは producer と consumer の両側を pin する — consumer が表なら行単位で pin する](../patterns/new-output-field-pin-producer-and-consumer.md)
- [canonical 例を持つ SoT は「例が自身の enforcer を通る」ことを実測で確かめる](../patterns/canonical-example-must-pass-its-own-enforcer.md)

## ソース

- [PR #2092 review results (cycle 1)](../../raw/reviews/20260802T141413Z-pr-2092.md)
- [PR #2092 fix results (cycle 1)](../../raw/fixes/20260802T141842Z-pr-2092.md)
- [PR #2092 review results (cycle 3)](../../raw/reviews/20260802T145006Z-pr-2092.md)
- [PR #2092 fix results (cycle 3)](../../raw/fixes/20260802T145247Z-pr-2092.md)
- [PR #2092 review results (cycle 4, converged)](../../raw/reviews/20260802T150522Z-pr-2092.md)
