---
title: "References 抽出時は引用先 SoT の内容を Read tool で verify する"
domain: "heuristics"
created: "2026-05-04T05:30:00+00:00"
updated: "2026-05-14T01:25:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260504T050342Z-pr-802.md"
  - type: "fixes"
    ref: "raw/fixes/20260504T050654Z-pr-802.md"
  - type: "reviews"
    ref: "raw/reviews/20260506T162735Z-pr-868.md"
  - type: "fixes"
    ref: "raw/fixes/20260506T163131Z-pr-868.md"
  - type: "reviews"
    ref: "raw/reviews/20260513T080326Z-pr-947.md"
  - type: "fixes"
    ref: "raw/fixes/20260513T080706Z-pr-947-fix-cycle-1.md"
  - type: "reviews"
    ref: "raw/reviews/20260514T010100Z-pr-950.md"
  - type: "fixes"
    ref: "raw/fixes/20260514T010559Z-pr-950.md"
tags: ["cross-file-reference", "test-docstring", "comment-rot", "canonical-reference-note"]
confidence: high
---

# References 抽出時は引用先 SoT の内容を Read tool で verify する

## 概要

Refactor 系 PR で `commands/issue/references/` に新規ファイルを抽出する際、引用先 references ファイルに書かれている Issue 番号や AC phrase を **推測ベースで関連付けると silent factual divergence を生む**。引用前に Read tool で引用先 SoT の該当箇所を verify することで、読者が末尾誘導された SoT で乖離内容を見つける UX 問題を回避する。

## 詳細

PR シリーズ 8/8 で 2 つの failure mode が cycle 1 で同時に検出され、いずれも root cause は「**引用先 SoT の内容を verify せず推測で関連付けた**」こと:

1. **factual divergence**: 新規 `bulk-create-pattern.md` で他 references (`regression-history.md` / `sub-skill-handoff-contract.md`) の Issue 番号を引用したが、引用先 references の実際の content と乖離していた。読者が末尾誘導された SoT 先で「言及されているはずの内容が見つからない」UX 障害を起こす。

2. **context-bleeding (理由付け文)**: NFR-2 (本体保持) の根拠として `create.md` 本体由来の **AC-3 grep 4 phrase** を `create-decompose.md` の references 抽出文で引用したが、対象ファイル (`create-decompose.md`) には該当 phrase が存在しない。理由付けは **対象ファイルの実 invariant** に基づくべき (本 PR 例: `create-decompose.md` の AC-1 enforcement boundary)。

### 適用ルール

- **新規 references ファイルで Issue 番号 / AC phrase を引用する場合**、引用先 SoT (regression-history.md / sub-skill-handoff-contract.md 等) の該当箇所を Read tool で verify してから引用する
- **理由付け文を書く場合**、引用元 (`create.md` 等の他ファイル) 由来の invariant を引用しない。対象ファイルの実 invariant のみ参照する
- **共進化する sibling 系ファイル間の docstring / コメントで cross-reference を書く場合**、どちらが canonical reference の owner なのかを **`grep -nF` で実 invariant を確認してから** 記述する (cycle 1 の実測: lint test の docstring が「Same policy as ...」の owner を反転して記述する Comment Rot を test reviewer が `grep -nF` で検出 → fix 側も同じ手順で修正方向を decisive に決定可能)
- 推測ベースの関連付けは silent factual divergence を生むため、Read tool / `grep -nF` による verify を必須化する

### 関連 failure mode

- 引用先 SoT の path 存在のみ check する `sot-path-reference-existence-check.md` heuristic は **存在チェックのみ** で content fidelity は保証しない。本 heuristic は content の verify まで踏み込む補完的な原則。
- **test docstring の sibling cross-reference 反転** は同じ「Read tool / grep verify 不在」の root cause を共有する。lint test ファイルが pair で sibling 関係にある場合 (例: `caller-html-literal-symmetry.test.sh` ↔ `caller-html-literal-symmetry-decompose-register.test.sh`)、片方が「Same policy as the other」と記述した時にどちらが policy owner なのか docstring 上で反転しやすい。reviewer の Likelihood-Evidence (`grep -nF`) anchor を信頼して即座に修正方向を決定できる。

### PR #947 観測 (canonical-reference NOTE 生成への再帰適用)

`references/wiki-patterns.md` に F-14 fix 操作契約への参照 NOTE を追加した PR #947 で本 heuristic の典型的な適用漏れが cycle 1 で再発した:

- **誤参照**: NOTE 内で「canonical source = `ingest.md` Phase 4.3」と記述したが、引用先 `ingest.md` 内には複数の canonical 宣言が共存しており (Phase 4.3 = 値決定手順 canonical / Phase 5.3 = F-14 fix fallback 動作 canonical / L569 = dual-site 維持備考)、Issue #945 Option 3 提案が示していた canonical は **Phase 5.3** だった。
- **2 reviewer cross-validation**: tech-writer (Doc-Heavy 昇格) + code-quality (sole reviewer guard) が独立に同一の canonical-source mismatch を検出し、HIGH 1 件で cross-validate。Doc-Heavy mode + sole reviewer guard のペアが極小 docs PR (元は 2 行追加) でも有効に機能した実証例。
- **適用拡張**: 本 heuristic は references 抽出 refactor だけでなく **canonical-reference NOTE 生成全般** に適用される。NOTE 内で「X が canonical」と書く前に、引用先ファイルの canonical 宣言箇所を Read tool で verify し、自分が指したい semantic に対応する canonical はどれかを必ず確認する。同一ファイル内に複数の canonical 宣言が共存しうる構造的曖昧性を考慮すること。

### PR #950 観測 (SoT 抽出 = canonical 整合化の opportunity)

start.md Phase 5.5.2 / 5.2.1 / 2.4 を 3 references へ抽出した PR (シリーズ E) の cycle 1 review で、refactor 移管前から既に canonical (`gh-cli-patterns.md`) と乖離していた「Use Python」表現の inherited mismatch が検出された。本 heuristic の対称的な insight として:

- **inherited mismatch detection**: 大規模 refactor で SoT を新規 reference に移管する時、本体側が canonical (gh-cli-patterns.md 等) と長期に drift していた表現を新 reference にコピーすると drift が固定化する。Read tool での verify は新規追加だけでなく **移管 content と canonical の照合** にも適用する
- **canonical 整合化の opportunity**: SoT 抽出は単なる移管作業ではなく、本体が長期に蓄積した inherited mismatch を canonical (gh-cli-patterns.md 等) に整合させる **能動的な機会**として活用する。「移管前の状態を忠実にコピーする」ではなく「移管時に canonical との整合性を verify し乖離があれば同 cycle で修正する」を default 方針とする
- **review-fix loop efficiency**: PR #950 では本対応により cycle 1 で 3 finding (2 MEDIUM + 1 LOW) → cycle 2 で 0 blocking finding という収束を達成。inherited mismatch を別 Issue 化せず本 PR scope 内で fix することで loop 効率を最大化

## 関連ページ

- [SoT Path Reference Existence Check](../heuristics/sot-path-reference-existence-check.md)
- [Fix 修正コメント自身が canonical convention を破る self-drift](../anti-patterns/fix-comment-self-drift.md)
- [同一手順が複数 site に分散する場合は片方を canonical source と宣言する](../patterns/canonical-source-declaration-for-multi-site-procedure.md)

## ソース

- [PR #802 review (cycle 1)](../../raw/reviews/20260504T050342Z-pr-802.md)
- [PR #802 fix (cycle 1)](../../raw/fixes/20260504T050654Z-pr-802.md)
- [PR #868 review (cycle 1)](../../raw/reviews/20260506T162735Z-pr-868.md)
- [PR #868 fix](../../raw/fixes/20260506T163131Z-pr-868.md)
- [PR #947 review (cycle 1)](../../raw/reviews/20260513T080326Z-pr-947.md)
- [PR #947 fix (cycle 1)](../../raw/fixes/20260513T080706Z-pr-947-fix-cycle-1.md)
- [PR #950 review (inherited mismatch "Use Python" 文言を SoT 抽出時の cross-reference verify で検出)](../../raw/reviews/20260514T010100Z-pr-950.md)
- [PR #950 cycle 1 fix (inherited mismatch を canonical gh-cli-patterns.md に整合化、SoT 抽出と同 cycle で対応)](../../raw/fixes/20260514T010559Z-pr-950.md)
