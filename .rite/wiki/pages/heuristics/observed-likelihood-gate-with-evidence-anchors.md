---
title: "Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格"
domain: "heuristics"
promote: rite-plugin
created: "2026-04-16T19:37:16Z"
updated: "2026-07-14T07:35:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260416T031452Z-pr-540.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T173035Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T043538Z-pr-589.md"
  - type: "reviews"
    ref: "raw/reviews/20260502T155859Z-pr-779.md"
  - type: "reviews"
    ref: "raw/reviews/20260505T095516Z-pr-834.md"
  - type: "reviews"
    ref: "raw/reviews/20260709T104501Z-pr-1812.md"
  - type: "reviews"
    ref: "raw/reviews/20260713T051932Z-pr-1847-cycle3.md"
  - type: "reviews"
    ref: "raw/reviews/20260713T223454Z-pr-1852.md"
tags: ["review", "severity", "likelihood-evidence", "cross-validation", "hypothetical", "literal-output-contract", "finding-quality-guardrail"]
confidence: high
---

# Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格

## 概要

reviewer が finding を HIGH/MEDIUM/LOW で提出する際、Likelihood-Evidence anchor（tool=Read/Grep, path=..., line=... の形式）を伴わない場合は自動的に「推奨事項」に降格させる gate を適用する。これにより憶測ベースの findings を severity から分離し、fix 対象を客観的根拠のあるものに集中できる。

## 詳細

### Anchor フォーマット

```
Likelihood-Evidence: tool=Read, path=plugins/rite/hooks/scripts/wiki-ingest-commit.sh, line=341
Likelihood-Evidence: tool=Grep, pattern='if ! .*; then$', path=plugins/rite/, matches=3
```

- `tool`: 検出に使用したツール (`Read` / `Grep` / `Bash`)
- `path`: 対象ファイルパス（相対）
- `line` または `pattern`: 具体的な位置または検索条件
- `matches`: grep 時の件数

### 降格のルーティング

| 降格理由 | severity | 扱い |
|--------------|---------|------|
| anchor 提示あり | CRITICAL/HIGH/MEDIUM/LOW | fix 対象 |
| anchor なし、推測のみ | — | 推奨事項（fix 対象外、discussion のみ） |
| Hypothetical（将来の他 Phase 変更に依存する仮定的リスク） | — | 推奨事項（現状コードで発火しないため fix 対象外） |

初期の適用例では 2 件の finding が「Observed Likelihood Gate により推奨事項に降格」され、severity distribution は `HIGH: 0, MEDIUM: 0` に収束した。Hypothetical 降格の実測例では error-handling reviewer の HIGH 指摘 2 件が「Likelihood-Evidence anchor 欠落 + Hypothetical（Phase 5.1 将来変更に依存）」のため Phase 5.3.0 safety net で機械的降格され、同じく `HIGH: 0, MEDIUM: 0` に収束。Hypothetical 降格は anchor 欠落と独立した orthogonal な降格軸として加えるのが canonical（Claude Code の Bash tool は invocation ごとに独立 shell を生成するため、bash fenced block 終了で trap 自動 cleanup される事実が降格根拠となった）。

charter 5 自問「既に承認された判断を再確認しない」の適用 PR レビューでは 11 findings (HIGH 5 / MEDIUM 4 / LOW 4) が検出されたが、Phase 5.3.0 Observed Likelihood Gate 適用後、全 finding が Likelihood-Evidence anchor 欠落で推奨事項降格 (9 件) または削除 (4 件) され `HIGH/MEDIUM/LOW: 0` に収束した。注目点は **2 reviewer による cross-validation 合意 (AskUserQuestion 4 選択肢の routing 未定義) でも literal anchor を伴わなければ降格対象になる**こと — cross-validation boost (上記 triple cross-validation 表) は anchor 提示が前提であり、cross-validation だけでは anchor 欠落を補わない。reviewer 内容の妥当性 (AskUserQuestion routing 未定義は実装上事実) と severity 判定 (anchor 欠落で降格) は orthogonal で、後述する literal output contract の重要性をさらに強化する empirical 証拠となった。

### Triple Cross-validation による severity boost

複数の reviewer が同一箇所を anchor 付きで独立検出した場合、severity を boost する:

| 独立検出人数 | boost 条件 | 例 |
|------------|-----------|---|
| 2 人 (double) | MEDIUM → HIGH | cross-validation boost 実測の cycle 5 F-01 (error-handling HIGH + code-quality LOW → HIGH 合意) |
| 3 人 (triple) | HIGH → HIGH (固定) / 高確度扱い | 同事例の cycle 3 F-01 (prompt-engineer + code-quality + error-handling) |

triple 合意は recurring pattern の可能性が高いため、fix 時に「他の類似箇所が無いか」を grep で網羅確認する合図になる。

### 憶測ベース findings のリスク

anchor を伴わない finding は以下のリスクを持つ:

- 実装を grep せず推測で書かれているため、fix 対象が存在しないケースあり
- 別 reviewer が同じ推測で overlapping finding を書くと false consensus が形成される
- fix 側が anchor の不在を気付かず wild goose chase する

このため evidence anchor を「findings 提出の必須フォーマット」として明示化する設計が有効。

### Reviewer literal output contract の重要性

literal anchor 欠落の実測で観測した sub-pattern: **reviewer がレビュー本文中に Likelihood-Evidence 相当の記述を持っていても、`Likelihood-Evidence:` という literal anchor を含めていなければ Phase 5.3.0 で mechanical 降格される**。

同事例では prompt-engineer が以下のような構造を持つ MEDIUM finding を返した:

- file:line に具体位置を提示 (`SKILL.md:21-28`)
- 内容 (WHAT) と影響 (WHY) を明確に記述
- 推奨対応 (FIX) を具体的に提示

しかし **`Likelihood-Evidence: tool=...` の literal 記述が無かった** ため、`pr/review.md` Phase 5.3.0 の mechanical safety net が「anchor 欠落」と判定し推奨事項に降格 → 結果として `[review:mergeable]` (0 blocking findings) と判定された。

#### Canonical 対策

reviewer agent file (`agents/{type}-reviewer.md`) の Output Format 例 / Detection Process 指示で、`Likelihood-Evidence:` literal を **finding template の必須フィールド** として明示する:

```markdown
| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| HIGH | src/foo.ts:42 | ... 内容 ... <br> Likelihood-Evidence: tool=Read, path=src/foo.ts, line=42 | ... 推奨 ... |
```

reviewer 側 prompt template の改修と、Phase 5.3.0 mechanical gate の literal grep 仕様を pair で同期させることで、本 sub-pattern の silent 降格 (= reviewer の判定品質と無関係に finding が消える経路) を解消できる。

#### 影響の orthogonality

本 sub-pattern と Hypothetical 降格軸は orthogonal — reviewer 内容の構造的問題 (literal anchor 欠落) と reviewer 判定の論理的問題 (現状コード非依存の仮定的リスク) は別軸で処理されるため、両 gate を独立に通過する必要がある。

### 第3の orthogonal 軸: 推奨文の self-declared 不要性 (Finding Quality Guardrail bikeshedding filter)

self-declared 不要性の実測 (cycle 3) で観測した sub-pattern: reviewer が finding を LOW severity・`scope: current-pr` として指摘事項テーブルに記載していても、その **推奨対応欄の文面自体が「必須ではない」「本 PR のスコープ外」と明記している** 場合、orchestrator は `_reviewer-base.md` の Finding Quality Guardrail（Category 1: Bikeshedding — 「project convention 違反を指摘できない限り filter」）を適用して non-blocking な推奨事項として扱ってよい。

これは anchor 欠落 (構造的問題) でも Hypothetical (論理的問題) でもない **第3の軸**: reviewer 自身の文面が示す「対応の要否」に関する自己矛盾（severity/scope 列は blocking を示すが、推奨対応の自然言語記述は non-blocking を示す）を検出する。判定基準は機械的 grep ではなく、推奨文中の「不要」「必須ではない」「スコープ外」等のキーワードの有無。

適用時の注意: この軸は severity が LOW（またはそれに準じる低確信度）の場合にのみ適用し、CRITICAL/HIGH の finding を推奨文の言い回しだけで降格させてはならない（severity 自体は reviewer の技術判断であり、本軸はあくまで「reviewer 自身が non-blocking と結論している」ことの明示的シグナルを拾うものであるため）。

### 第4の orthogonal 軸: 独立レビュアーの非裏付け + worst-case と severity の不整合（cycle 3）

非裏付けの実測 (cycle 3) で観測した sub-pattern: 単一 reviewer（error-handling）が anchor 付きで HIGH finding を提出したが、**同一箇所を独立に精査した別 reviewer（prompt-engineer）が全分岐をトレースした上で「可」（指摘なし）と明示的に判定していた**。この非裏付け（non-corroboration）自体が、Critic フェーズで severity を再検討する signal として機能する。

判定の根拠は 2 点の複合:

1. **独立レビュアーによる明示的非裏付け**: cross-validation は通常「複数 reviewer が同一箇所を独立検出したら severity boost」という一方向の運用だが、逆方向（一方が明確に「問題なし」と判定した）も証拠として使ってよい。ただし、これは anchor 欠落や Hypothetical のような機械的 gate とは異なり、**Critic の判断**（Debate Phase を経る、または明示的な対比評価）を要する
2. **Worst-case と severity の不整合**: 当該 finding の対象コードパスが `non_blocking: true` の警告表示止まりであり、実際に発火しても「ユーザーに警告が出るだけ」で処理は継続する設計だった。worst-case が non-blocking warning に留まるコードパスに HIGH（ブロッキング相当）の severity をつけることは、severity 定義（実際の影響範囲）と矛盾するシグナルとして扱える

適用条件（濫用防止）: 本軸は「他 reviewer の非裏付け」単独では発動しない。**worst-case のブラスト半径が small/non-blocking であることの独立確認**とセットで初めて Critic 判断の根拠として十分になる。CRITICAL/HIGH の finding を単に「他が見つけなかったから」だけで降格させてはならない（false negative の見逃しリスクがあるため、severity 自体は reviewer 個々の技術判断を尊重しつつ、対比評価の記録を残す）。

### 再検証サイクルでの重複降格 — 既 Issue 化済み finding は再 Issue 化せず Decision Log 記録に留める

重複降格の実測では review-fix ループ cycle2（検証レビュー）で、tech-writer が cycle1 と同一の pre-existing finding（旧ファイル名の残存参照）を再度検出した。cycle1 では当該 finding から follow-up Issue が既に切り出し済みだったため、cycle2 での再検出は `Likelihood-Evidence:` anchor 欠落により本 gate で機械的に推奨事項へ降格され、`[review:mergeable]` に収束した。

ここでの追加の運用判断は「anchor 欠落による降格」自体は既存パターンの再現だが、**降格後の後処理**として「同一 finding が既に別 Issue 化済みであることを確認し、Step 7 トリアージで重複 Issue を再作成せず作業メモリの Decision Log にのみ記録する」という点。降格 gate は fix-needed → mergeable の収束を保証するが、Issue 台帳の重複防止は呼び出し側 (Step 7 トリアージ) の責務であり、cycle をまたいで同じ finding が浮上するたびに新規 Issue を作らないための明示的な既存 Issue 確認ステップが必要になる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [`cmd=$(...) || cmd=""` は非ゼロ終了時に stdout 済みの診断 JSON を空文字列で上書きする](../anti-patterns/command-substitution-fallback-discards-diagnostic-json.md)

## ソース

- [PR #540 review (Observed Likelihood Gate 実装例、2 件降格)](../../raw/reviews/20260416T031452Z-pr-540.md)
- [PR #548 cycle 3 review (triple cross-validation boost)](../../raw/reviews/20260416T173035Z-pr-548.md)
- [PR #589 review (Hypothetical 降格軸の追加実証 — HIGH x2 → 推奨事項降格)](../../raw/reviews/20260419T043538Z-pr-589.md)
- [PR #779 review (literal anchor 欠落で MEDIUM → 推奨事項降格、reviewer literal output contract の重要性実証)](../../raw/reviews/20260502T155859Z-pr-779.md)
- [PR #834 review (11 findings 全降格 — cross-validation 合意でも literal anchor 欠落は補えない実証)](../../raw/reviews/20260505T095516Z-pr-834.md)
- [PR #1812 review cycle 3 (推奨文の self-declared 不要性による第3の orthogonal 降格軸)](../../raw/reviews/20260709T104501Z-pr-1812.md)
- [PR #1847 review cycle 3 (独立レビュアーの明示的非裏付け + non-blocking worst-case の不整合による第4の orthogonal 降格軸)](../../raw/reviews/20260713T051932Z-pr-1847-cycle3.md)
- [PR #1852 review cycle 2 (再検証サイクルでの重複降格 — 既 Issue 化済み finding は Decision Log 記録に留める)](../../raw/reviews/20260713T223454Z-pr-1852.md)
