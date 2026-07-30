---
title: "Enum 拡張時は few-shot example で全 enum 値の使用例を網羅する (calibration coverage gap 防止)"
domain: "heuristics"
created: "2026-05-18T15:50:00+09:00"
updated: "2026-05-19T08:00:33Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260518T062827Z-pr-1039.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T065513Z-pr-1056.md"
  - type: "reviews"
    ref: "raw/reviews/20260519T073950Z-pr-1059.md"
tags: ["enum-extension", "few-shot-calibration", "reviewer-skill-sot", "coverage-gap", "scope-column", "severity-levels", "recommendation-column-consistency"]
confidence: medium
---

# Enum 拡張時は few-shot example で全 enum 値の使用例を網羅する (calibration coverage gap 防止)

## 概要

LLM agent が参照する calibration source (few-shot example / output template) に新規 enum 値を導入する際、**全 enum 値の使用例を 1 件以上含める**こと。一部の値だけ example を作ると、agent が未掲載の値の使い方を学習できず、出力時に silent drop / 誤分類する経路を生む。`severity-extension-closed-loop-verification` が扱う「実装層 6 段階 (read/write/parse/measure)」と直交する **calibration 層**の網羅性を担保する heuristic。

## 詳細

### 発生事例（scope 列 5 列化と few-shot example の coverage gap）

Issue #1016 で reviewer findings table に `scope` 列を追加 (schema 1.1.0、enum 3 値: `current-pr` / `follow-up` / `nit-noted`)。PR #1037/#1039 では `plugins/rite/skills/reviewers/references/finding-examples.md` の 6 few-shot example を 4 列→5 列に同期したが、**6 example すべてに `current-pr` scope を埋込み**、`follow-up` / `nit-noted` の使用例は導入されなかった。

| Calibration source | Few-shot example | Enum 値の coverage |
|--------------------|------------------|-------------------|
| `finding-examples.md` (6 example) | Example 1 (HIGH/security) → `current-pr` | ❌ `follow-up` example 0 件 |
| | Example 2 (HIGH/perf) → `current-pr` | ❌ `nit-noted` example 0 件 |
| | Example 3 (MEDIUM/prompt) → `current-pr` | |
| | Weak Example 1 (HIGH) → `current-pr` | |
| | Improved version (HIGH) → `current-pr` | |
| | Borderline (LOW) → `current-pr` | (本来は `nit-noted` がデフォルトの可能性あり — strict reading で指摘) |

PR #1039 code-quality reviewer 指摘 (推奨事項): 「6 つの finding 例すべてが `current-pr` を使用し、`follow-up` / `nit-noted` の使用例が皆無。Few-shot calibration の観点では、`Scope Assignment Flowchart` が 3 値を定義している以上、各値について 1 例ずつ Few-shot を持たせると LLM の scope assignment 精度が向上する可能性がある」

### 既存ページとの差分

- `severity-extension-closed-loop-verification.md` は severity 等級 (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW) 拡張時の **実装層 6 段階** (reviewer guidance / write spec / JSON schema / read parser / extract regex / measure dict) の verify を扱う
- 本 heuristic はその直交軸として **calibration source の coverage 層** を扱う。実装層をすべて通しても calibration が古い enum 値だけしか持たないと agent が新規値を学習せず、silent fallback で旧値に rounding する経路が残る

### 適用範囲

| Enum 種類 | Calibration source | Coverage を担保すべき場所 |
|----------|---------------------|----------------------|
| severity (Severity Levels) | reviewer skill files / `_reviewer-base.md` Output Format example | 各等級 1 件以上の finding example |
| scope (Scope Assignment) | `finding-examples.md` few-shot 例 | `current-pr` / `follow-up` / `nit-noted` 各 1 件以上 |
| status (review-result-schema) | reviewer template / fix.md case 例 | `open` / `fixed` / `replied` / `deferred` 各 1 件以上 (将来 status 書き戻しが実装される際) |
| 他の単純 enum | template / few-shot 例の全箇所 | 全 enum 値 1 件以上 |

### Coverage 検証 heuristic

新規 enum 値導入 PR の **acceptance criteria 候補** として以下を追加すること:

```
- [ ] few-shot example で全 enum 値 ({v1}, {v2}, {v3}) が 1 件以上使用されている
- [ ] enum 値の選定根拠 (Assignment Flowchart / Decision Matrix) が calibration source からリンク可能
- [ ] 各 example の severity × enum 組み合わせが forbidden cell matrix に抵触していない
```

### 不採用の選択肢 (scope 外)

PR #1039 の scope では「全 enum 値の few-shot 追加」は **本 PR の scope 外** (`current-pr` への 5 列形式統一が主目的) として follow-up Issue 候補に降格された。これは「機械的同期 → 設計改善は別 PR」という scope discipline (本 PR は drift 解消のみ、calibration enhancement は別途) を保つための判断であり、本 heuristic は次回の calibration enhancement Issue 起票時に適用する。

### Successful prevention case の累積実証

PR #1039 の follow-up として起票された Issue #1041 で、本 heuristic を直接 acceptance criteria に転記し、PR #1056 (`docs(reviewer): finding-examples.md の few-shot に follow-up / nit-noted scope の使用例を追加`) で 2 example を追加 (Example 4: MEDIUM × `follow-up`、Example 5: LOW × `nit-noted`)。0 blocking finding / 1 cycle 即時 mergeable で収束し、本 heuristic が「直前 PR で記録 → 翌 PR で適用 → 想定通り収束」という最短経路の **successful prevention case** を実測した。

同時に PR #1056 review で観察された sub-pattern:

- **Calibration source の再帰的品質要請** (self-referential quality): calibration source は **理想形** を示すべきで、Weak Example で批判した failure mode を good example が繰り返してはならない。PR #1056 review では「Weak Example 1 で EXAMPLE 欠落を批判している file 自身が新規 Example 4 で同じ failure mode を踏みかけた」観察が行われ、本 heuristic を適用する enum 拡張 PR では「new example が同 file 内の Weak Example で批判される failure mode を含まない」ことも併せて verify すべき (recursion 防止)。
- **non-Hypothetical-Exception reviewer 選定の明示記載**: forbidden cell matrix を伴う enum (severity × scope 等) で example を作る際、reviewer-type × enum 値の許容組合せが forbidden cell に該当する場合は「なぜこの reviewer-type を選んだか」を example 内に明示的に記述する (例: `"frontend reviewer is used deliberately — the four Hypothetical Exception reviewers (security/database/devops/dependencies) are prohibited from emitting scope=nit-noted"`)。LLM 学習で許容組合せを decisive に伝達する canonical pattern。

### PR #1059 (self-referential consistency completion via concrete code snippet)

PR #1056 review で 2 reviewer (prompt-engineer / code-quality) が独立に「Example 4 Recommendation 列は散文のみで終わっており、Example 1 (`z.object({ email: z.string().email() })`) / Example 2 (`WHERE project_id IN (...)`) のような concrete code snippet が欠落」と検出し、Issue #1057 に follow-up として起票。PR #1059 で 1 行差分の minimal-diff doc PR (Example 4 Recommendation 列に `parseCurrency(raw: string): Money` API シグネチャと `const amount = parseCurrency(rawValue)` call-site collapse 例を追記) を実装、0 blocking finding / 1 cycle 即時 mergeable で収束した。

本サイクルで確認された追加観察:

- **Self-referential consistency completion の最小実装単位**: calibration source 内の「style 不整合」(本件では Recommendation 列の prose vs inline-code 混在) は **1 行差分** で完全に解消可能なケースがあり、scope 列 / severity 列のような構造変更を伴わない doc PR では 1 cycle 収束が定常状態となる（2 PR 連続で実測）。
- **LOW × nit-noted finding を介した self-referential failure mode 検出 → 修正 → 0-finding 完了の 1 サイクル**: PR #1059 cycle 1 では 1 件の LOW × nit-noted (`src/utils/money.ts` 言及が抽出先と pattern reference で重複) が検出されたが reviewer 自身が「対応不要」「Example 2 の `task.ts:80` 重複 pattern に倣っている」と明記したため [Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない](./respect-reviewer-no-action-recommendation.md) に従い replied-only で処理、loop 再発火なし。
- **Successful prevention case の連続再現**: PR #1037/#1039 (heuristic 記録) → PR #1056 (follow-up 適用、2 examples 追加) → PR #1059 (self-referential consistency 完成、concrete code snippet 追記) の 3 PR 連鎖は、本 heuristic が「直前 PR で記録 → 翌 PR で部分適用 → 翌々 PR で完全適用」という段階的 application path も観測可能であることを示す。各段階で 0 blocking / 1 cycle 収束。

## 関連ページ

- [Severity 等級拡張は read/write/parse/measure の closed-loop 6 段階を verify する](../heuristics/severity-extension-closed-loop-verification.md)

## ソース

- [PR #1039 review results](../../raw/reviews/20260518T062827Z-pr-1039.md)
- [PR #1056 review results](../../raw/reviews/20260519T065513Z-pr-1056.md)
- [PR #1059 review results](../../raw/reviews/20260519T073950Z-pr-1059.md)
