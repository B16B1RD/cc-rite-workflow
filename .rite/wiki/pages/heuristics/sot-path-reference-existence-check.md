---
title: "SoT 文書の path 参照は本 PR マージ時点の origin/develop で existence check する"
domain: "heuristics"
created: "2026-04-29T02:55:00+00:00"
updated: "2026-04-29T02:55:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260428T171940Z-pr-705.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T173005Z-pr-705-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T172314Z-pr-705.md"
tags: ["sot-document", "path-reference", "broken-ref", "self-violation", "cross-pr-fragility", "identifier-consistency"]
confidence: high
---

# SoT 文書の path 参照は本 PR マージ時点の origin/develop で existence check する

## 概要

新規 SoT (Single Source of Truth) 文書を作成する際、文書内部から他リポジトリ要素 (file path / skill 名 / canonical 文書) への参照を含める場合は、参照先の存在を **本 PR がマージされる時点の origin/develop** で機械的に検証する。並行する未マージ PR / 撤去済み artifact / canonical でない出典への参照は、SoT を最初の bad example にする (原則 6 「Comment Rot is CRITICAL」の自己違反)。あわせて、SoT 内部で原則 ID 等の identifier を short form と canonical form で混在させると、後続 Issue で grep anchor として使う際の drift 源になる。

## 詳細

### PR #705 で実測した 4 失敗形態

PR #705 (コメントベストプラクティス SoT 新設 MVP) cycle 1 review で 6 findings (HIGH 2 + MEDIUM 3 + LOW 1) として一斉 surface した:

| # | failure mode | 具体例 | 修正方針 |
|---|--------------|--------|---------|
| 1 | broken whitelist references | Whitelist テーブルの出典 path が現状 repo に存在しない / 撤去済みファイルを指す (3 entries) | (a) 撤去済み: Whitelist から削除し Note で歴史的経緯のみ残す / (b) 存在しない skill: 実体が存在する canonical 文書に出典変更 / (c) canonical でない出典: 真の canonical 文書を採用 |
| 2 | PR cross-reference fragility | Bad/Good 例が **未マージ PR (#688)** 由来のコードを参照 → 本 PR マージ時点で「実プロジェクト由来」が空になる | 「未マージ branch である事実を脚注で明示し、引用の意図を Bad 例として独立化」 |
| 3 | identifier 表記揺れ | 原則 ID (`no_line_reference` vs `no_line_or_cycle_reference`) が同ファイル内で揺れ → grep anchor の drift 源 | 「原則一覧テーブル」の表記を canonical として全文中で統一 |
| 4 | regex character class incompleteness | shell プロジェクトはハイフン含み file 名が一般的 (`_emit-cross-session-incident.sh`) → `[a-z_]` のみは false negative | `[a-zA-Z0-9_./-]` 等で hyphen + Capital + 数字 + path separator を許容 |

### 自己違反の構造的特徴

SoT 文書は本来「他箇所が違反していないかを検査する基準」として作成されるが、新規 SoT 自身がその基準を満たさない self-violation pattern が surface しやすい。原因は:

- **作成時点と参照時点のずれ**: SoT を書く時点では parallel 進行中の PR が「将来 develop に入る前提」で参照されるが、SoT 自身がマージされた時点ではまだ未マージ
- **canonical 文書の混在**: 「それっぽい URL / file path」を hallucinate してしまうリスク。anchor / Phase 番号 / heading 文字列で参照し、必要なら `wc -l` + `sed -n` で実在検証
- **identifier の自然な揺れ**: 原則 ID を「短く呼びたい」自然な傾向と「canonical form を保ちたい」rigidity の衝突

### 検証方法

新規 SoT が PR review に入る前に、以下の機械検証を mandatory 化:

```bash
# 1. SoT 内に出現する全 path 参照を抽出
grep -oE '`[a-zA-Z0-9_./-]+\.(md|sh|json|yml)`' path/to/sot.md \
  | sort -u > /tmp/sot-paths.txt

# 2. 各 path が origin/develop に存在するか確認
while read -r p; do
  bare=$(echo "$p" | tr -d '`')
  if ! git ls-tree origin/develop --name-only -r | grep -qFx "$bare"; then
    echo "BROKEN: $bare"
  fi
done < /tmp/sot-paths.txt
```

未マージ PR に依存する Bad/Good 例は (a) 別 file/branch から自己完結する例に書き換える、または (b) 「PR #N の commit `<hash>` 時点の状態を引用 (post-merge 不整合は意図的)」と脚注で明示する。

### 適用フェーズ表と Where to Apply の双方向整合 (PR #705 cycle 2 で追加)

SoT 文書には「適用フェーズ」概要表 (どの phase でこの原則が enforce されるか) と、各原則の「Where to Apply」具体化セクションが含まれる場合がある。両者は **双方向に整合** させる必要がある:

- **概要表 → Where to Apply**: 表で宣言された phase が、各原則の Where to Apply 節に列挙されている
- **Where to Apply → 概要表**: Where to Apply 節で言及された phase が、表に登録されている

両方が揃わない場合、表は **dead spec** 化 (declared but unobserved) し、新規読者は「表に書いてあるのに具体化がない → 未実装の宣言」と誤読する。表と具体化セクションのいずれかを更新する PR では、必ず双方向整合を確認する。

PR #705 cycle 2 では cycle 1 で broken-ref / 表記揺れ / regex の defect を一括解消した直後、内部矛盾 (適用フェーズ vs Where to Apply) が cycle 2 で初検出された。MVP スコープを尊重しつつ「未定義であることを明示する Note」で透明化する選択肢も canonical (cf. [Prose-only design](../anti-patterns/prose-design-without-backing-implementation.md))。

### 3 cycle 収束パターン (PR #705)

```
cycle 1 (6 findings) → cycle 2 (1 finding) → cycle 3 (0 findings, mergeable)
```

- cycle 1: broken-ref / 表記揺れ / regex の defect を一括解消
- cycle 2: 内部矛盾 (概要表 vs Where to Apply) の 1 finding (MEDIUM)
- cycle 3: 全 reviewer 合意の指摘事項ゼロに収束 + dogfooding self-apply validated

新規 SoT は最初から完全ではなく、3 cycle 程度の review-fix で収束する想定で書くと scope が現実的になる。

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](../anti-patterns/hallucinated-canonical-reference.md)
- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](./identity-reference-documentation-unification.md)
- [Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く](./design-doc-current-head-verification.md)

## ソース

- [PR #705 cycle 1 review (6 findings: broken-ref / 表記揺れ / regex incompleteness)](../../raw/reviews/20260428T171940Z-pr-705.md)
- [PR #705 cycle 2 review (内部矛盾: 適用フェーズ vs Where to Apply)](../../raw/reviews/20260428T173005Z-pr-705-cycle2.md)
- [PR #705 cycle 1 fix (broken-ref 3 件 / cross-PR fragility / identifier / regex 全 6 解消)](../../raw/fixes/20260428T172314Z-pr-705.md)
