---
title: "SoT 文書の path 参照は本 PR マージ時点の origin/develop で existence check する"
domain: "heuristics"
description: "新規 SoT (Single Source of Truth) 文書を作成する際、文書内部から他リポジトリ要素 (file path / skill 名 / canonical 文書) への参照を含める場合は、参照先の存在を **本 PR がマージされる時点の origin/develop** で機械的に検証する。"
created: "2026-04-29T02:55:00+00:00"
updated: "2026-06-10T01:03:44Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260610T010210Z-pr-1342.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T171940Z-pr-705.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T173005Z-pr-705-cycle2.md"
  - type: "fixes"
    ref: "raw/fixes/20260428T172314Z-pr-705.md"
  - type: "reviews"
    ref: "raw/reviews/20260504T040112Z-pr-801.md"
  - type: "fixes"
    ref: "raw/fixes/20260504T040558Z-pr-801.md"
  - type: "reviews"
    ref: "raw/reviews/20260523T144332Z-pr-1102.md"
  - type: "reviews"
    ref: "raw/reviews/20260529T072948Z-pr-1190.md"
tags: ["sot-document", "path-reference", "broken-ref", "self-violation", "cross-pr-fragility", "identifier-consistency", "relative-path-depth"]
confidence: high
---

# SoT 文書の path 参照は本 PR マージ時点の origin/develop で existence check する

## 概要

新規 SoT (Single Source of Truth) 文書を作成する際、文書内部から他リポジトリ要素 (file path / skill 名 / canonical 文書) への参照を含める場合は、参照先の存在を **本 PR がマージされる時点の origin/develop** で機械的に検証する。並行する未マージ PR / 撤去済み artifact / canonical でない出典への参照は、SoT を最初の bad example にする (原則 6 「Comment Rot is CRITICAL」の自己違反)。あわせて、SoT 内部で原則 ID 等の identifier を short form と canonical form で混在させると、後続 Issue で grep anchor として使う際の drift 源になる。

## 詳細

### 起点事例で実測した 4 失敗形態

起点事例 (コメントベストプラクティス SoT 新設 MVP) の cycle 1 review で 6 findings (HIGH 2 + MEDIUM 3 + LOW 1) として一斉 surface した:

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

### 適用フェーズ表と Where to Apply の双方向整合（cycle 2 で追加）

SoT 文書には「適用フェーズ」概要表 (どの phase でこの原則が enforce されるか) と、各原則の「Where to Apply」具体化セクションが含まれる場合がある。両者は **双方向に整合** させる必要がある:

- **概要表 → Where to Apply**: 表で宣言された phase が、各原則の Where to Apply 節に列挙されている
- **Where to Apply → 概要表**: Where to Apply 節で言及された phase が、表に登録されている

両方が揃わない場合、表は **dead spec** 化 (declared but unobserved) し、新規読者は「表に書いてあるのに具体化がない → 未実装の宣言」と誤読する。表と具体化セクションのいずれかを更新する PR では、必ず双方向整合を確認する。

起点事例の cycle 2 では cycle 1 で broken-ref / 表記揺れ / regex の defect を一括解消した直後、内部矛盾 (適用フェーズ vs Where to Apply) が cycle 2 で初検出された。MVP スコープを尊重しつつ「未定義であることを明示する Note」で透明化する選択肢も canonical (cf. [Prose-only design](../anti-patterns/prose-design-without-backing-implementation.md))。

### 3 cycle 収束パターン

```
cycle 1 (6 findings) → cycle 2 (1 finding) → cycle 3 (0 findings, mergeable)
```

- cycle 1: broken-ref / 表記揺れ / regex の defect を一括解消
- cycle 2: 内部矛盾 (概要表 vs Where to Apply) の 1 finding (MEDIUM)
- cycle 3: 全 reviewer 合意の指摘事項ゼロに収束 + dogfooding self-apply validated

新規 SoT は最初から完全ではなく、3 cycle 程度の review-fix で収束する想定で書くと scope が現実的になる。

### 逆方向: broken reference の修正 PR でも引用先実在性を事前確認する

逆方向適用事例 (`phase-mapping.md` の broken cross-reference 修正 doc PR) は本経験則の **逆方向の適用** を実測した: 新規 SoT 作成時の existence check だけでなく、**既に壊れている参照を修正する PR** でも、修正後参照先 (resume.md Phase 3.5 cross-check / Phase 5.3 mapping) の実在を Read tool で事前確認することが 0 blocking finding / 1 cycle 着地に直結した。`phase-mapping.md` が `commands/resume.md` の存在しない「Phase 3.2 legacy alias 表」を SoT として参照していた broken reference を、実在する Phase 3.5 / Phase 5.3 参照に書き換えた。両 reviewer (prompt-engineer / code-quality) が修正後参照の実在を Read で independently verify。

このケースが示すのは、本経験則の検証手順 (引用先 SoT を Read tool で verify) は「reference を新規に書く時」だけでなく「broken reference を直す時」にも同じ rigour で適用すべきという点である。修正対象が壊れている事実は、修正後の参照先まで自動的に正しいことを保証しない。

加えて逆方向適用事例で観測された **pre-existing 同型 broken reference の残存**: 同じ「Phase 3.2 legacy table」への broken 参照が `sub-skill-return-protocol.md` / `docs/SPEC.md` / `docs/SPEC.ja.md` にも残存していることが調査で surface した (本 PR scope 外として別途調査推奨)。これは [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の broken-reference 版であり、1 箇所の broken ref を直す際に同型参照を repo 全体で `grep` して残存件数を確認する pre-flight が canonical 対策となる。

### relative reference の検証は『file 存在』だけでなく『depth-aware な相対 path 解決』まで含む

relative reference 事例 (`commands/pr/open.md` ステップ3.5 の dangling reference `references/issue-body-checklist.md` を実在の `../../references/gh-cli-patterns.md#safe-checklist-operation-patterns` へ差し替える doc PR) は、本経験則の逆方向を再実測しつつ、**relative reference 特有の検証軸**を追加した: 0 blocking finding / 1 cycle 着地で、両 reviewer (prompt-engineer + code-quality) が以下 4 点を機械検証した:

1. **file 存在**: 差し替え先 `plugins/rite/references/gh-cli-patterns.md` の実在 (find / test -e)
2. **anchor 一致**: `## Safe Checklist Operation Patterns` 見出しが GitHub slug 規則で `#safe-checklist-operation-patterns` に一致 (唯一見出し)
3. **相対 path 解決**: `readlink -f` で `commands/pr/open.md` から `../../references/` が canonical target に byte-identical に解決
4. **codebase 全体での anchor 一貫性**: 同一 anchor が `checklist-auto-check.md` の既存参照と一致

この (3) が relative reference 固有の検証軸である。SoT の path 参照が **bare** (`references/foo.md`) の場合は「plugin-root 起点なら解決するが file 居場所からは解決しない」曖昧さを持ち、**relative** の場合は file の depth に応じて prefix を使い分ける必要がある:

| file の位置 (rite/ からの depth) | 正しい `references/` への相対 prefix |
|---|---|
| `commands/{X}/foo.md` (depth-2) | `../../references/` |
| `commands/{X}/references/foo.md` (depth-3) | `../../../references/` |

bare `references/` と depth 別 relative prefix の混在が drift 源になる。reviewer は副次的に pre-existing な同型不整合を 2 件検出した: (1) `commands/pr/open.md` L137/L141 が bare `references/...`、(2) `commands/pr/references/archive-procedures.md` L260/L333 が depth-3 から `../../references/` で broken (正しくは `../../../references/`)。これらは Issue scope 外として boundary 推奨に分類され、follow-up Issue (「rite command/reference ファイルの参照パス drift を一括解消」) として切り出した — line 99 の「同型参照を repo 全体で grep して残存件数を確認する」canonical 対策 ([Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の broken-reference 版) を実運用した実例。

教訓: relative reference を含む doc を書く / 直すときの existence check は、`git ls-tree` での file 存在確認に加えて、**参照元 file の depth から相対 prefix が正しく解決するか** (`readlink -f` / `cd $(dirname) && ls $ref`) と **anchor slug が target 見出しに実在するか** (`grep -E '^##+ '`) の 3 点をセットで verify する。

### 適用例: 委譲後 cross-ref drift 修正の 3 点検証（1 行 docs 修正、1 cycle mergeable）

helper 委譲後に stale 化した cross-ref を更新する 1 行 docs PR で、2 reviewer (prompt-engineer / code-quality) が以下の 3 点検証で cycle 1 mergeable を判定:

1. **新参照の実在性**: 更新後の見出し参照が対象ファイルの実見出しと文字列レベルで完全一致すること + 委譲先 script の実在を Read/Grep で確認
2. **旧参照の stale 性 (revert test)**: revert すると stale 参照が復活する = 本 diff 由来の修正として正当
3. **同型 stale の残存 grep**: 旧表記パターンを repo 全体で grep し、他ファイルが既に委譲後形式へ更新済みであることを確認

委譲 refactor の後追い docs 修正はこの 3 点で検証が完結する — existence check (本ページの主題) を「参照先見出しの文字列一致」まで強めるのが委譲後 drift 修正の決め手。

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)
- [fix コメント / commit message で hallucinated canonical reference を生成する](../anti-patterns/hallucinated-canonical-reference.md)
- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](./identity-reference-documentation-unification.md)
- [Design doc は現 HEAD の SoT (registration / writer-reader grep) を verify してから書く](./design-doc-current-head-verification.md)

## ソース

- [PR #705 cycle 1 review (6 findings: broken-ref / 表記揺れ / regex incompleteness)](../../raw/reviews/20260428T171940Z-pr-705.md)
- [PR #705 cycle 2 review (内部矛盾: 適用フェーズ vs Where to Apply)](../../raw/reviews/20260428T173005Z-pr-705-cycle2.md)
- [PR #705 cycle 1 fix (broken-ref 3 件 / cross-PR fragility / identifier / regex 全 6 解消)](../../raw/fixes/20260428T172314Z-pr-705.md)
- [PR #801 review (新規 reference の inter-file anchor `./complexity-gate.md#complexity-gate-section-inclusion` が target ファイルに存在せず、両 reviewer (prompt-engineer + code-quality) で cross-validated。経験則: 新規 anchor 記述前に `grep -E '^##+ ' <target>` で実在 heading slug を検証してから書く)](../../raw/reviews/20260504T040112Z-pr-801.md)
- [PR #801 fix (broken anchor 解消、grep ベースの heading slug 検証を anchor 記述前 pre-flight check として明示化)](../../raw/fixes/20260504T040558Z-pr-801.md)
- [PR #1102 review (phase-mapping.md の broken cross-reference 修正 doc PR、0 blocking findings / 1 cycle 着地。修正後参照先 (resume.md Phase 3.5 / Phase 5.3) の実在を両 reviewer が Read で independently verify。同型 broken ref が sub-skill-return-protocol.md / docs/SPEC.md / docs/SPEC.ja.md に pre-existing 残存)](../../raw/reviews/20260523T144332Z-pr-1102.md)
- [PR #1190 review (commands/pr/open.md ステップ3.5 の dangling reference 差し替え doc PR、0 blocking / 1 cycle 着地。relative reference の depth-aware path 解決検証 (`../../references/` depth-2 / `../../../references/` depth-3) + anchor slug 実在 + codebase 一貫性の 4 点機械検証。pre-existing 同型不整合 2 件を follow-up Issue #1191 に切り出し)](../../raw/reviews/20260529T072948Z-pr-1190.md)
- [PR #1342 review results — 委譲後 cross-ref drift 修正を 3 点検証 (実在性 / stale 性 / 同型残存 grep) で 1 cycle mergeable 判定](../../raw/reviews/20260610T010210Z-pr-1342.md)
