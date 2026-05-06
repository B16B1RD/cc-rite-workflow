---
title: "Asymmetric Fix Transcription の解決は両側修正 (Option A) より hub 化 + 責務分離文書化 (Option B) を選ぶ"
domain: "heuristics"
created: "2026-05-06T04:50:00Z"
updated: "2026-05-06T04:50:00Z"
sources:
  - type: "retrospectives"
    ref: "raw/retrospectives/20260506T040636Z-issue-851.md"
  - type: "reviews"
    ref: "raw/reviews/20260506T035708Z-pr-858.md"
tags: ["asymmetric-fix-transcription", "hub-creation", "single-source-of-truth", "responsibility-separation", "structural-drift-prevention", "option-selection-meta-heuristic"]
confidence: medium
---

# Asymmetric Fix Transcription の解決は両側修正 (Option A) より hub 化 + 責務分離文書化 (Option B) を選ぶ

## 概要

[Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) (対称位置への伝播漏れ) を解決する際、自然な選択肢は (A) 両側に同じ参照や fix を追加して symmetry を物理的に保つことだが、これは将来の drift 経路を温存する。代替案として (B) 一方を **hub (Single Source of Truth)** と宣言し、もう一方の責務範囲を明示的に narrow して「両者は別 layer の責務」と文書化することで、symmetry 自体を構造的に不要にできる。Option B は (a) DRY 違反を回避し、(b) 「将来同類の drift を提案する人」を SoT 行を通じて構造的に retract できるため、累積防御の収束効率が高い。

## 詳細

### 発生状況の例 (Issue #851)

`commands/issue/create-interview.md` の line 307 が Output rules の SoT で、line 27/247 にある bash block コメントは line 307 で定義された rule を参照する。PR #850 で line 307 に新しい test references を追加した際、line 27/247 の bash block コメントへの逆参照伝播を忘れた典型的な Asymmetric Fix Transcription pattern が発生。

### 2 つの解決オプション

| オプション | 内容 | 長期コスト |
|---|---|---|
| **Option A — 両側修正 (symmetric replication)** | line 27/247 の bash block コメントにも line 307 と同じ test references を追加し、3 箇所で同期維持 | 同期させる site が N 増えるごとに drift 発生確率が線形 (場合により組合せ的) に増加。N=3 でも drift で N+1 cycle の review-fix loop に膨らむ実例 (PR #548 の `21→17→2→7→3→0`) |
| **Option B — hub 化 + 責務分離文書化** | line 307 を「両 test の hub」と明示し、bash block コメント側 (line 27/247) は責務 (bash 引数 symmetry) のみ inline 言及。HTML literal symmetry など他の test 参照は **本セクションを single source として参照する責務分離**を明示的に文書化 | 同期 site 数を 1 に削減。さらに「責務分離の文書」自体が、将来 bash block コメントへ test references を追加しようとする drift 提案を **SoT 行を通じて構造的に retract** する。drift 経路を物理的に閉塞 |

### Option B が構造的に優位な理由

1. **DRY 違反の回避**: Option A は同じ意味を 3 箇所に literal copy する DRY 違反。Option B は 1 hub に集約。
2. **drift 経路の物理的閉塞**: 単に hub 化するだけでなく「bash block 側コメントは bash 引数 symmetry のみを inline 言及し、HTML literal symmetry は本セクションを single source として参照する責務分離を維持」という **責務範囲の明示文書** がカギ。これにより将来「両側にも書こう」という refactor 提案は、SoT 文書を読んだ瞬間に「責務分離契約に反する」と判定可能になり、drift が proposal 段階で止まる。
3. **minimal-diff doc PR で完結**: Option B の実装は 1 line edit (line 307 prose の hub 明示追加) で済むため、PR #858 のように 1 line minimal-diff doc PR として fast-track 可能。

### Option B 採用時の落とし穴 (PR #862 で実測)

Option B の hub 化は新しい SoT を作るため、**hub 自身の構造**が後続の review 対象になる。PR #858 で line 307 prose に hub 明示を 1 line 追加したところ、parenthetical 末尾の `):` が「半角 `)` + 半角 `:`」と「list 始端 colon」を兼ねる二重役割となり、style drift として LOW 推奨で再指摘された。これは hub 化の効果を否定するものではなく、**hub 行の prose 構造そのものが新たな品質ゲート対象になる**ことを示している。Option B の採用判断と並行して、hub 行の prose style (parenthetical 構造、style 統一) も style guide 対象に含めるべき。

### Option B 採用の判断基準

以下を全て満たすケースで Option B を選ぶ:

1. **hub 化対象の概念が単一 source-of-truth として記述可能**: 例 — test references / API 契約 / state machine 定義。物理的に分散せざるを得ない値 (例: 各 phase の literal 数値) には不適。
2. **責務分離が自然言語で明示記述可能**: 「A は X のみ、B は Y のみ参照」のような 1-2 文で記述できる責務分割であること。記述に複数段落必要なら hub 化のメリットは薄い (読者が責務境界を即座に理解できないため drift 防止効果が落ちる)。
3. **caller / consumer 数が小さく追跡可能**: 数百の caller がある場合は両側修正でも管理コストは同等になり、hub 化の delta 価値が減衰する。

### 実測収束 (Issue #851 → PR #858 → 関連 LOW 推奨 #859/#860/#861)

- **PR #858** (Option B 実装) — 1 line 最小差分 doc PR、両 reviewer (prompt-engineer + code-quality) で 0 blocking findings、merge 完了
- **PR #862** (PR #858 で導入された hub 行 prose の style 統一) — `**Output rules** (...):` parenthetical を `**Output rules**:` 独立行スタイルに分解、0 findings
- **scope 外 LOW 推奨を別 Issue 化** — prompt-engineer reviewer の 3 件の LOW 推奨は scope を超えるため #859/#860/#861 として登録。doc PR でも `rejected(scope-creep)` 判断ではなく followup-issue 化で記録する規律を維持

### Mitigation — Option B 採用 PR の review checklist

1. **hub 行の prose style verification**: hub を新設する 1-line doc PR では、追加した行の parenthetical / colon / 強調記号の二重役割が起きていないかを sibling site (同 file 内の他 SoT 行) と比較
2. **責務分離記述の grep 可能化**: 「本セクションを single source として参照する」のような責務分離宣言は grep 可能な canonical phrase で書く (将来 lint pattern として再利用可能)
3. **既存 test の baseline 維持**: doc PR でも関連 test (本ケースでは `4-site-symmetry.test.sh` / `caller-html-literal-symmetry.test.sh`) を実行し、test の grep pin が prose 文字列に依存していないかを確認

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [DRIFT-CHECK ANCHOR は semantic name で参照する (line 番号 literal 不使用)](../patterns/drift-check-anchor-semantic-name.md)
- [State Machine の dual-location 同期は SoT 化で構造的に閉塞する](../patterns/state-machine-dual-location-sync.md)
- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](./identity-reference-documentation-unification.md)

## ソース

- [Issue #851 close retrospective (Option B hub 化採用の判断記録)](raw/retrospectives/20260506T040636Z-issue-851.md)
- [PR #858 review (1-line minimal-diff doc PR で SoT 化を実装、0 blocking findings)](raw/reviews/20260506T035708Z-pr-858.md)
